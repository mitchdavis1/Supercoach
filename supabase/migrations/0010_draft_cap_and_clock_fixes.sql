-- Two fixes to the draft engine:
--
-- 1. place_bid() never checked whether the bidder's own stable was already
--    full before accepting a bid — league_budget()'s max_bid alone doesn't
--    block this, since a full reserve of $0 for zero remaining slots still
--    permits a max_bid up to the whole remaining cap-space. This let a
--    manager win an 11th horse. Now rejected up front via remaining_slots.
--
-- 2. Bid clock 10s -> 20s, nomination clock 20s -> 30s, across start_draft,
--    advance_draft_if_expired, and nominate_horse.

create or replace function public.start_draft(p_league_id uuid)
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
      and not exists (
        select 1 from public.league_draft_picks p
        where p.league_id = p_league_id and p.horse_id = h.id
      )
    order by random()
    limit 1;

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

create or replace function public.nominate_horse(p_league_id uuid, p_horse_id uuid)
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

create or replace function public.place_bid(p_league_id uuid, p_bid_amount int default null)
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
