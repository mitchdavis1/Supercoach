-- Server-authoritative auction draft engine.
--
-- Economics carried over exactly from the prototype (src-supercoach-v5.html):
--   - $100 salary cap, 10 horses per stable, no bench
--   - every horse opens the auction at a $1 bid, placed automatically in the
--     nominator's name the instant they nominate
--   - bid clock is 20s and RESETS on every accepted bid (soft close)
--   - nomination clock is 30s; on expiry the on-the-clock manager
--     auto-nominates a random available horse (not a skip/pass)
--   - minimum raise is $1, but a manager may jump straight to any higher
--     amount as long as it's within their max bid
--   - maxBid = budget - reserve, where reserve = $1 for every OTHER empty
--     slot (10 total, minus horses already won, minus the slot being bid on)
--
-- Every mutating action funnels through advance_draft_if_expired() first so
-- an expired clock is always resolved server-side before any new action is
-- allowed to proceed — this is what makes the clock authoritative even
-- though there's no separate scheduled job ticking it.

create table public.season_weeks (
  week_number int primary key,
  label text not null,
  deadline timestamptz not null
);

-- Spring Racing Carnival 2026 schedule, Friday 5pm AEDT deadlines,
-- carried over verbatim from the prototype's TRANSFER_WEEKS constant.
insert into public.season_weeks (week_number, label, deadline) values
  (1, 'Week 1 — Memsie–Makybe Diva', '2026-09-04T07:00:00Z'),
  (2, 'Week 2', '2026-09-11T07:00:00Z'),
  (3, 'Week 3', '2026-09-18T07:00:00Z'),
  (4, 'Week 4', '2026-09-25T07:00:00Z'),
  (5, 'Week 5', '2026-10-02T07:00:00Z'),
  (6, 'Week 6', '2026-10-16T07:00:00Z'),
  (7, 'Week 7', '2026-10-23T07:00:00Z'),
  (8, 'Week 8', '2026-10-30T07:00:00Z'),
  (9, 'Week 9', '2026-11-13T07:00:00Z');

alter table public.season_weeks enable row level security;

create policy "season weeks are viewable by any authenticated user"
  on public.season_weeks for select
  to authenticated
  using (true);

create function public.get_current_week()
returns public.season_weeks
language sql
stable
as $$
  select * from public.season_weeks where deadline > now() order by week_number asc limit 1;
$$;

grant execute on function public.get_current_week() to authenticated;

-- ----------------------------------------------------------------------------
-- start_draft — gating logic ported verbatim from startDraft() in the prototype
-- ----------------------------------------------------------------------------

create function public.start_draft(p_league_id uuid)
returns public.league_draft_state
language plpgsql
security definer set search_path = public
as $$
declare
  v_league public.leagues;
  v_state public.league_draft_state;
  v_is_manager boolean;
  v_order uuid[];
begin
  select * into v_league from public.leagues where id = p_league_id;
  if not found then
    raise exception 'League not found';
  end if;

  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  v_is_manager := (v_league.manager_user_id = auth.uid());

  select * into v_state from public.league_draft_state where league_id = p_league_id for update;
  if v_state.status <> 'idle' then
    raise exception 'The draft has already started';
  end if;

  if v_league.scheduled_draft_at is null and not v_is_manager then
    raise exception 'Your league manager hasn''t scheduled the draft yet';
  end if;

  if v_league.scheduled_draft_at is not null and v_league.scheduled_draft_at > now() and not v_is_manager then
    raise exception 'The draft is scheduled for % — it hasn''t started yet', v_league.scheduled_draft_at;
  end if;

  if not exists (select 1 from public.horses where status = 'active') then
    raise exception 'There are no horses in the pool yet — import a horse list before starting a draft';
  end if;

  select array_agg(user_id order by joined_at) into v_order
  from public.league_members where league_id = p_league_id;

  update public.league_draft_state set
    status = 'nominating',
    nominator_order = v_order,
    nominator_index = 0,
    current_nominator_user_id = v_order[1],
    current_lot_horse_id = null,
    current_bid = null,
    current_bidder_user_id = null,
    bid_count = 0,
    nomination_deadline = now() + interval '30 seconds',
    bid_deadline = null,
    updated_at = now()
  where league_id = p_league_id
  returning * into v_state;

  return v_state;
end;
$$;

-- ----------------------------------------------------------------------------
-- advance_draft_if_expired — resolves an expired nomination/bid clock.
-- Called internally by nominate_horse/place_bid before they act, and exposed
-- directly as advance_draft() so a client (or a poller) can tick the clock
-- even when nobody is actively bidding.
-- ----------------------------------------------------------------------------

create function public.advance_draft_if_expired(p_league_id uuid)
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
    -- Prefer the admin-curated starred pool for auto-nomination (it's the
    -- same set shown by default in the nomination UI); fall back to the
    -- full active pool if no starred horses are left undrafted.
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

    insert into public.stables (league_id, user_id, horse_id, paid_price)
    values (p_league_id, v_state.current_bidder_user_id, v_state.current_lot_horse_id, v_state.current_bid);

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

create function public.advance_draft(p_league_id uuid)
returns public.league_draft_state
language sql
security definer set search_path = public
as $$
  select public.advance_draft_if_expired(p_league_id);
$$;

-- ----------------------------------------------------------------------------
-- nominate_horse — only the current nominator may call, and only during
-- 'nominating'. Opens the lot with the nominator as the automatic $1 bidder,
-- exactly like openLotForBidding() in the prototype.
-- ----------------------------------------------------------------------------

create function public.nominate_horse(p_league_id uuid, p_horse_id uuid)
returns public.league_draft_state
language plpgsql
security definer set search_path = public
as $$
declare
  v_state public.league_draft_state;
begin
  perform public.advance_draft_if_expired(p_league_id);

  select * into v_state from public.league_draft_state where league_id = p_league_id for update;

  if v_state.status <> 'nominating' then
    raise exception 'It is not time to nominate a horse right now';
  end if;

  if v_state.current_nominator_user_id <> auth.uid() then
    raise exception 'It is not your turn to nominate';
  end if;

  if not exists (select 1 from public.horses where id = p_horse_id and status = 'active') then
    raise exception 'That horse is not available';
  end if;

  if exists (select 1 from public.league_draft_picks where league_id = p_league_id and horse_id = p_horse_id) then
    raise exception 'That horse has already been drafted';
  end if;

  update public.league_draft_state set
    current_lot_horse_id = p_horse_id,
    current_bid = 1,
    current_bidder_user_id = auth.uid(),
    bid_count = 1,
    status = 'bidding',
    bid_deadline = now() + interval '20 seconds',
    updated_at = now()
  where league_id = p_league_id
  returning * into v_state;

  return v_state;
end;
$$;

-- ----------------------------------------------------------------------------
-- place_bid — minimum raise is $1 above current_bid, but a manager may name
-- any higher amount up to their max bid. Resets the 20s bid clock on success.
-- A bidder whose stable is already full (10/10) cannot bid — league_budget()
-- alone doesn't block this, since a full reserve of $0 for zero remaining
-- slots still allows a max_bid up to the full remaining cap-space.
-- ----------------------------------------------------------------------------

create function public.place_bid(p_league_id uuid, p_bid_amount int default null)
returns public.league_draft_state
language plpgsql
security definer set search_path = public
as $$
declare
  v_state public.league_draft_state;
  v_bid int;
  v_max_bid int;
  v_remaining_slots int;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  perform public.advance_draft_if_expired(p_league_id);

  select * into v_state from public.league_draft_state where league_id = p_league_id for update;

  if v_state.status <> 'bidding' then
    raise exception 'There is no active lot to bid on right now';
  end if;

  if v_state.current_bidder_user_id = auth.uid() then
    raise exception 'You are already the highest bidder on this lot';
  end if;

  select remaining_slots, max_bid into v_remaining_slots, v_max_bid from public.league_budget(p_league_id, auth.uid());

  if v_remaining_slots <= 0 then
    raise exception 'Your stable is already full — you cannot bid on more horses';
  end if;

  v_bid := coalesce(p_bid_amount, v_state.current_bid + 1);

  if v_bid <= v_state.current_bid then
    raise exception 'Your bid must be higher than the current bid of $%', v_state.current_bid;
  end if;

  if v_bid > v_max_bid then
    raise exception 'That bid exceeds your maximum of $% once reserve for your remaining slots is held back', v_max_bid;
  end if;

  update public.league_draft_state set
    current_bid = v_bid,
    current_bidder_user_id = auth.uid(),
    bid_count = v_state.bid_count + 1,
    bid_deadline = now() + interval '20 seconds',
    updated_at = now()
  where league_id = p_league_id
  returning * into v_state;

  return v_state;
end;
$$;

grant execute on function public.start_draft(uuid) to authenticated;
grant execute on function public.advance_draft(uuid) to authenticated;
grant execute on function public.nominate_horse(uuid, uuid) to authenticated;
grant execute on function public.place_bid(uuid, int) to authenticated;
