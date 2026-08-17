-- "Starred" horses — admin-curated subset of the pool (via the Data Import
-- page), shown by default in the draft nomination panel instead of an
-- unsearched slice of ~9,000 names, and preferred by auto-nomination when a
-- manager's nomination clock expires (falls back to the full active pool if
-- nothing is starred, so an uncurated pool never deadlocks the draft).

alter table public.horses add column is_starred boolean not null default false;
create index horses_starred_idx on public.horses (is_starred) where is_starred;

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
