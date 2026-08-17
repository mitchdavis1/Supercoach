-- Prizemoney baseline + banking. Raw cumulative prizemoney totals only mean
-- "what you earned" if you've owned the horse all season. A horse traded in
-- would otherwise bring its whole season's prior earnings with it (unearned
-- by the new owner), and a horse traded out would otherwise vanish from its
-- former owner's score retroactively, including what they earned while they
-- owned it. Fixed by:
--   - every stable row gets a baseline_prizemoney, snapshotted at the moment
--     the horse joined that stable (draft award or transfer-in) — a
--     manager's live score from a horse they hold is its current cumulative
--     total minus that baseline, never the raw total;
--   - when a horse leaves a stable, the delta it earned while owned
--     (current total minus its baseline) is banked permanently into that
--     league_members row's banked_earnings, which survives the horse
--     leaving and is never touched again by future roster changes.

alter table public.stables add column baseline_prizemoney numeric not null default 0;
alter table public.league_members add column banked_earnings numeric not null default 0;

-- Both tables have a permissive "update your own row" RLS policy with no
-- column restriction, and Supabase grants table-wide UPDATE to authenticated
-- by default — so without this, a client could directly rewrite these new
-- columns (or paid_price) and fabricate their own leaderboard score.
-- baseline_prizemoney/banked_earnings must only ever move through
-- execute_transfer()'s SECURITY DEFINER transaction, which runs as the
-- function owner and isn't subject to these grants.
revoke update on public.stables from authenticated;
grant update (is_captain, is_vice_captain) on public.stables to authenticated;

revoke update on public.league_members from authenticated;
grant update (team_name) on public.league_members to authenticated;

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
    else
      update public.league_draft_state set
        status = 'nominating',
        nominator_index = v_next_idx,
        current_nominator_user_id = v_next_user,
        current_lot_horse_id = null,
        current_bid = null,
        current_bidder_user_id = null,
        bid_count = 0,
        nomination_deadline = now() + interval '30 seconds',
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

create or replace function public.execute_transfer(p_league_id uuid, p_horse_out_id uuid, p_horse_in_id uuid)
returns public.transfers
language plpgsql
security definer set search_path = public
as $$
declare
  v_week public.season_weeks;
  v_out public.stables;
  v_transfer public.transfers;
  v_horse_out_total numeric;
  v_horse_in_total numeric;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  select * into v_week from public.get_current_week();
  if not found then
    if exists (select 1 from public.season_weeks where closes_at > now()) then
      raise exception 'The transfer window is currently closed — check the Stable Transfer page for when it reopens';
    else
      raise exception 'The season is over — no more transfers can be made';
    end if;
  end if;

  select * into v_out from public.stables
  where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_out_id
  for update;

  if not found then
    raise exception 'You do not own that horse in this league';
  end if;

  if p_horse_in_id = p_horse_out_id then
    raise exception 'Choose a different horse to transfer in';
  end if;

  if not exists (select 1 from public.horses where id = p_horse_in_id and status = 'active') then
    raise exception 'That horse is not available';
  end if;

  v_horse_out_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = p_horse_out_id), 0);
  v_horse_in_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = p_horse_in_id), 0);

  begin
    delete from public.stables
    where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_out_id;

    update public.league_members
    set banked_earnings = banked_earnings + (v_horse_out_total - v_out.baseline_prizemoney)
    where league_id = p_league_id and user_id = auth.uid();

    insert into public.stables (league_id, user_id, horse_id, is_captain, is_vice_captain, paid_price, baseline_prizemoney)
    values (p_league_id, auth.uid(), p_horse_in_id, v_out.is_captain, v_out.is_vice_captain, null, v_horse_in_total);

    insert into public.transfers (league_id, user_id, week_number, horse_out_id, horse_in_id)
    values (p_league_id, auth.uid(), v_week.week_number, p_horse_out_id, p_horse_in_id)
    returning * into v_transfer;
  exception
    when unique_violation then
      if sqlerrm like '%stables%' then
        raise exception 'That horse was just taken by another manager in this league';
      else
        raise exception 'You have already used your transfer for %', v_week.label;
      end if;
  end;

  return v_transfer;
end;
$$;
