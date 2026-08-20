-- Replace first-come-first-served weekly transfers with a waiver-order
-- system, matching standard fantasy-sport waivers:
--
--   - A manager transferring a horse out picks up to 3 incoming horses in
--     priority order, instead of instantly claiming one.
--   - Nothing happens until the window closes (Friday 5pm AEDT, was 7pm —
--     tightened by 2 hours here). At that point every league with a
--     completed draft processes its pending requests in waiver-order:
--     each manager gets their highest-priority pick that's still
--     unclaimed (by an earlier manager's already-processed request this
--     same run); if all 3 of their picks are already gone, their
--     transfer is simply rejected — no partial/fallback claim.
--   - The order itself rotates every week regardless of whether a manager
--     submitted a request: whoever was 1st drops to last, everyone else
--     moves up one. This is a deliberate simplification of "standard"
--     waivers (which usually only move whoever *won* a claim) — spelled
--     out explicitly by the product owner.
--   - Starting order is set once, when a league's draft completes: most
--     remaining cap space first, ties broken randomly.
--
-- Like the draft clock, processing is self-healing rather than cron-driven
-- — process_league_waivers_if_due() runs opportunistically (from
-- submit_waiver_request, and from a check_league_waivers() RPC the client
-- calls on every Stable Transfer page visit/poll) rather than on a
-- schedule. See README's design notes.

update public.season_weeks set closes_at = closes_at - interval '2 hours';

-- ============================================================================
-- WAIVER ORDER — current per-league rotation, one row per member
-- ============================================================================

create table public.league_waiver_order (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  position int not null,
  primary key (league_id, user_id),
  unique (league_id, position) deferrable initially deferred
);

alter table public.league_waiver_order enable row level security;

create policy "waiver order is viewable by league members"
  on public.league_waiver_order for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = league_waiver_order.league_id and lm.user_id = auth.uid()
    )
  );

-- No direct insert/update/delete policies: writes happen only inside
-- initialize_league_waiver_order() and process_league_waivers_if_due().

-- ============================================================================
-- WAIVER REQUESTS — one submission per manager per week, up to 3 priorities
-- ============================================================================

create table public.waiver_requests (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  week_number int not null,
  horse_out_id uuid not null references public.horses(id),
  choice_1_horse_id uuid not null references public.horses(id),
  choice_2_horse_id uuid references public.horses(id),
  choice_3_horse_id uuid references public.horses(id),
  status text not null default 'pending' check (status in ('pending', 'fulfilled', 'rejected')),
  resulting_horse_in_id uuid references public.horses(id),
  submitted_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (league_id, user_id, week_number)
);

create index waiver_requests_league_week_idx on public.waiver_requests (league_id, week_number);

alter table public.waiver_requests enable row level security;

create policy "waiver requests are viewable by their own submitter"
  on public.waiver_requests for select
  to authenticated
  using (user_id = auth.uid());

-- No direct insert/update/delete policies: writes happen only inside
-- submit_waiver_request() and process_league_waivers_if_due().

-- ============================================================================
-- WAIVER RUNS — marks a (league, week) as already processed
-- ============================================================================

create table public.league_waiver_runs (
  league_id uuid not null references public.leagues(id) on delete cascade,
  week_number int not null,
  processed_at timestamptz not null default now(),
  primary key (league_id, week_number)
);

alter table public.league_waiver_runs enable row level security;

create policy "waiver runs are viewable by league members"
  on public.league_waiver_runs for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = league_waiver_runs.league_id and lm.user_id = auth.uid()
    )
  );

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

drop function if exists public.execute_transfer(uuid, uuid, uuid);

create function public.initialize_league_waiver_order(p_league_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if exists (select 1 from public.league_waiver_order where league_id = p_league_id) then
    return;
  end if;

  insert into public.league_waiver_order (league_id, user_id, position)
  select p_league_id, ranked.user_id, ranked.rn
  from (
    select
      lm.user_id,
      row_number() over (
        order by (100 - coalesce(picks.spent, 0)) desc, random()
      ) as rn
    from public.league_members lm
    left join (
      select user_id, sum(price_paid) as spent
      from public.league_draft_picks
      where league_id = p_league_id
      group by user_id
    ) picks on picks.user_id = lm.user_id
    where lm.league_id = p_league_id
  ) ranked;
end;
$$;

create function public.process_league_waivers_if_due(p_league_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_draft_done_at timestamptz;
  v_week record;
  v_order uuid[];
  v_new_order uuid[];
  v_user uuid;
  v_req public.waiver_requests;
  v_out public.stables;
  v_out_found boolean;
  v_horse_out_total numeric;
  v_choice_total numeric;
  v_choice uuid;
  v_awarded uuid;
  i int;
begin
  if not exists (select 1 from public.league_waiver_order where league_id = p_league_id) then
    return;
  end if;

  select max(picked_at) into v_draft_done_at from public.league_draft_picks where league_id = p_league_id;

  for v_week in
    select * from public.season_weeks sw
    where sw.closes_at <= now()
      and (v_draft_done_at is null or sw.opens_at > v_draft_done_at)
      and not exists (
        select 1 from public.league_waiver_runs r
        where r.league_id = p_league_id and r.week_number = sw.week_number
      )
    order by sw.week_number asc
  loop
    select array_agg(user_id order by position) into v_order
    from public.league_waiver_order where league_id = p_league_id;

    if v_order is not null then
      foreach v_user in array v_order loop
        select * into v_req from public.waiver_requests
        where league_id = p_league_id and user_id = v_user and week_number = v_week.week_number and status = 'pending'
        for update;

        if found then
          select * into v_out from public.stables
          where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id
          for update;
          v_out_found := found;

          v_awarded := null;
          foreach v_choice in array array_remove(array[v_req.choice_1_horse_id, v_req.choice_2_horse_id, v_req.choice_3_horse_id], null) loop
            if exists (select 1 from public.horses where id = v_choice and status = 'active')
               and not exists (select 1 from public.stables where league_id = p_league_id and horse_id = v_choice) then
              v_awarded := v_choice;
              exit;
            end if;
          end loop;

          if v_awarded is not null and v_out_found then
            v_horse_out_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = v_req.horse_out_id), 0);
            v_choice_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = v_awarded), 0);

            delete from public.stables
            where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id;

            update public.league_members
            set banked_earnings = banked_earnings + (v_horse_out_total - v_out.baseline_prizemoney)
            where league_id = p_league_id and user_id = v_user;

            insert into public.stables (league_id, user_id, horse_id, paid_price, baseline_prizemoney)
            values (p_league_id, v_user, v_awarded, null, v_choice_total);

            insert into public.transfers (league_id, user_id, week_number, horse_out_id, horse_in_id)
            values (p_league_id, v_user, v_week.week_number, v_req.horse_out_id, v_awarded);

            update public.waiver_requests
            set status = 'fulfilled', resulting_horse_in_id = v_awarded, processed_at = now()
            where id = v_req.id;
          else
            update public.waiver_requests
            set status = 'rejected', processed_at = now()
            where id = v_req.id;
          end if;
        end if;
      end loop;
    end if;

    if v_order is not null and array_length(v_order, 1) > 0 then
      v_new_order := v_order[2:array_length(v_order, 1)] || v_order[1:1];
      for i in 1..array_length(v_new_order, 1) loop
        update public.league_waiver_order
        set position = i
        where league_id = p_league_id and user_id = v_new_order[i];
      end loop;
    end if;

    insert into public.league_waiver_runs (league_id, week_number) values (p_league_id, v_week.week_number);
  end loop;
end;
$$;

create function public.check_league_waivers(p_league_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;
  perform public.process_league_waivers_if_due(p_league_id);
end;
$$;

grant execute on function public.check_league_waivers(uuid) to authenticated;

create function public.submit_waiver_request(
  p_league_id uuid,
  p_horse_out_id uuid,
  p_choice_1 uuid,
  p_choice_2 uuid default null,
  p_choice_3 uuid default null
)
returns public.waiver_requests
language plpgsql
security definer set search_path = public
as $$
declare
  v_week public.season_weeks;
  v_req public.waiver_requests;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  perform public.process_league_waivers_if_due(p_league_id);

  select * into v_week from public.get_current_week();
  if not found then
    if exists (select 1 from public.season_weeks where closes_at > now()) then
      raise exception 'The transfer window is currently closed — check the Stable Transfer page for when it reopens';
    else
      raise exception 'The season is over — no more transfers can be made';
    end if;
  end if;

  if not exists (select 1 from public.stables where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_out_id) then
    raise exception 'You do not own that horse in this league';
  end if;

  if p_choice_1 is null then
    raise exception 'Choose at least one horse to transfer in';
  end if;

  if p_choice_3 is not null and p_choice_2 is null then
    raise exception 'Fill priority 2 before priority 3';
  end if;

  if p_choice_1 = p_horse_out_id or p_choice_2 = p_horse_out_id or p_choice_3 = p_horse_out_id then
    raise exception 'Your incoming picks must be different from the horse you''re transferring out';
  end if;

  if p_choice_2 is not null and p_choice_2 = p_choice_1 then
    raise exception 'Your incoming picks must all be different horses';
  end if;
  if p_choice_3 is not null and (p_choice_3 = p_choice_1 or p_choice_3 = p_choice_2) then
    raise exception 'Your incoming picks must all be different horses';
  end if;

  if exists (
    select 1 from unnest(array[p_choice_1, p_choice_2, p_choice_3]) c(id)
    where c.id is not null and (
      not exists (select 1 from public.horses where id = c.id and status = 'active')
      or exists (select 1 from public.stables where league_id = p_league_id and horse_id = c.id)
    )
  ) then
    raise exception 'One of your picks is not available — it may already be held in this league';
  end if;

  insert into public.waiver_requests (league_id, user_id, week_number, horse_out_id, choice_1_horse_id, choice_2_horse_id, choice_3_horse_id)
  values (p_league_id, auth.uid(), v_week.week_number, p_horse_out_id, p_choice_1, p_choice_2, p_choice_3)
  on conflict (league_id, user_id, week_number)
  do update set
    horse_out_id = excluded.horse_out_id,
    choice_1_horse_id = excluded.choice_1_horse_id,
    choice_2_horse_id = excluded.choice_2_horse_id,
    choice_3_horse_id = excluded.choice_3_horse_id,
    status = 'pending',
    resulting_horse_in_id = null,
    processed_at = null,
    submitted_at = now()
  returning * into v_req;

  return v_req;
end;
$$;

grant execute on function public.submit_waiver_request(uuid, uuid, uuid, uuid, uuid) to authenticated;

-- advance_draft_if_expired: initialize the waiver order the moment a
-- league's draft finishes, in both branches that can mark it complete.
create or replace function public.advance_draft_if_expired(p_league_id uuid)
returns public.league_draft_state
language plpgsql
security definer set search_path = public
as $$
declare
  v_state public.league_draft_state;
  v_random_horse uuid;
  v_next_idx int;
  v_next_user uuid;
  v_attempts int := 0;
  v_team_count int;
  v_pool_empty boolean;
begin
  select * into v_state from public.league_draft_state where league_id = p_league_id for update;
  if not found or v_state.status not in ('nominating', 'bidding') then
    return v_state;
  end if;

  if v_state.status = 'nominating' and v_state.nomination_deadline is not null and v_state.nomination_deadline <= now() then
    select h.id into v_random_horse
    from public.horses h
    where h.status = 'active'
      and h.is_starred
      and not exists (
        select 1 from public.league_draft_picks p
        where p.league_id = p_league_id and p.horse_id = h.id
      )
    order by random()
    limit 1;

    if v_random_horse is null then
      select h.id into v_random_horse
      from public.horses h
      where h.status = 'active'
        and not exists (
          select 1 from public.league_draft_picks p
          where p.league_id = p_league_id and p.horse_id = h.id
        )
      order by random()
      limit 1;
    end if;

    if v_random_horse is null then
      update public.league_draft_state set status = 'complete', updated_at = now()
      where league_id = p_league_id returning * into v_state;
      perform public.initialize_league_waiver_order(p_league_id);
      return v_state;
    end if;

    update public.league_draft_state set
      current_lot_horse_id = v_random_horse,
      current_bid = 1,
      current_bidder_user_id = v_state.current_nominator_user_id,
      bid_count = 1,
      status = 'bidding',
      bid_deadline = now() + interval '20 seconds',
      updated_at = now()
    where league_id = p_league_id
    returning * into v_state;

    return v_state;
  end if;

  if v_state.status = 'bidding' and v_state.bid_deadline is not null and v_state.bid_deadline <= now() then
    insert into public.league_draft_picks (league_id, user_id, horse_id, price_paid)
    values (p_league_id, v_state.current_bidder_user_id, v_state.current_lot_horse_id, v_state.current_bid);

    insert into public.stables (league_id, user_id, horse_id, paid_price, baseline_prizemoney)
    values (
      p_league_id, v_state.current_bidder_user_id, v_state.current_lot_horse_id, v_state.current_bid,
      coalesce((select total_prizemoney from public.prizemoney where horse_id = v_state.current_lot_horse_id), 0)
    );

    v_team_count := array_length(v_state.nominator_order, 1);
    v_next_idx := v_state.nominator_index;

    select not exists (
      select 1 from public.horses h
      where h.status = 'active'
        and not exists (
          select 1 from public.league_draft_picks p
          where p.league_id = p_league_id and p.horse_id = h.id
        )
    ) into v_pool_empty;

    v_next_user := null;
    if not v_pool_empty then
      while v_attempts < v_team_count loop
        v_next_idx := (v_next_idx + 1) % v_team_count;
        v_attempts := v_attempts + 1;
        select order_idx.uid into v_next_user
        from (select v_state.nominator_order[v_next_idx + 1] as uid) order_idx
        where (
          select count(*) from public.league_draft_picks p
          where p.league_id = p_league_id and p.user_id = order_idx.uid
        ) < 10;
        exit when v_next_user is not null;
      end loop;
    end if;

    if v_next_user is null then
      update public.league_draft_state set
        status = 'complete',
        current_lot_horse_id = null,
        current_bid = null,
        current_bidder_user_id = null,
        bid_count = 0,
        updated_at = now()
      where league_id = p_league_id
      returning * into v_state;
      perform public.initialize_league_waiver_order(p_league_id);
    else
      update public.league_draft_state set
        status = 'nominating',
        nominator_index = v_next_idx,
        current_nominator_user_id = v_next_user,
        current_lot_horse_id = null,
        current_bid = null,
        current_bidder_user_id = null,
        bid_count = 0,
        nomination_deadline = now() + interval '20 seconds',
        bid_deadline = null,
        updated_at = now()
      where league_id = p_league_id
      returning * into v_state;
    end if;

    return v_state;
  end if;

  return v_state;
end;
$$;
