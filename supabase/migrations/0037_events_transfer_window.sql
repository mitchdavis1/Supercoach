-- ============================================================================
-- Events-model transfer window: Monday 10:00 to Friday 20:00, processed at
-- close, effective the following Saturday.
-- ============================================================================
-- Legacy leagues keep using the hand-curated season_weeks calendar and
-- get_current_week() exactly as before — untouched by this migration.
-- Events leagues instead get a COMPUTED weekly window (no per-week row to
-- maintain): every calendar week's Monday 10:00 through Friday 20:00 in
-- the league's configured timezone convention (kept as Australia/Melbourne
-- throughout, per the brief's own "AEDT" wording), closing/processing at
-- Friday 20:00 with the resulting transfer taking effect the following
-- Saturday — so Friday's races stay with the outgoing owner and Saturday
-- onward belongs to the incoming one.

-- Monday (as a date) of the ISO week containing p_date.
create or replace function public.events_week_start(p_date date)
returns date
language sql
immutable
as $$
  select p_date - (extract(isodow from p_date)::int - 1);
$$;

-- A gap-free, strictly increasing integer id for a given week's Monday —
-- deliberately NOT isoyear*100+isoweek, which jumps backwards across a
-- year boundary (week 52 of one year can sort below week 1 of the next).
-- Anchored to 2000-01-03, a Monday, so this is just "weeks since then."
create or replace function public.events_week_number(p_week_start date)
returns int
language sql
immutable
as $$
  select ((p_week_start - date '2000-01-03') / 7)::int;
$$;

create or replace function public.events_window_bounds(p_week_start date, out window_open timestamptz, out window_close timestamptz)
language sql
immutable
as $$
  select
    (p_week_start::timestamp + interval '10 hours') at time zone 'Australia/Melbourne',
    (p_week_start::timestamp + interval '4 days 20 hours') at time zone 'Australia/Melbourne';
$$;

-- Events-model equivalent of process_league_waivers_if_due(): walks every
-- computed week from the league's game-window start (or its draft
-- completion date, if later) up to the current week, processing each one
-- whose Friday 8pm close has passed and that hasn't been recorded yet —
-- so a tab reconnecting after Mitch has gone several weeks without
-- opening the app still catches up correctly, one week at a time, same
-- as the legacy function's loop over due season_weeks rows.
--
-- The only structural difference from the legacy function: instead of
-- banking (current_total - baseline) into league_members.banked_earnings
-- and snapshotting a new baseline_prizemoney, this closes out the
-- outgoing horse's open ownership_periods row (end_date = the following
-- Saturday) and opens a new one for the incoming horse starting that same
-- Saturday. stables keeps being the live current-roster table exactly as
-- before — only ownership_periods is new here.
create or replace function public.process_events_waivers_if_due(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_window public.league_game_window;
  v_draft_done_date date;
  v_walk_week_start date;
  v_current_week_start date;
  v_week_number int;
  v_window_close timestamptz;
  v_effective_date date;
  v_order uuid[];
  v_new_order uuid[];
  v_user uuid;
  v_req public.waiver_requests;
  v_out public.stables;
  v_out_found boolean;
  v_awarded uuid;
  v_choice uuid;
  i int;
begin
  if not exists (select 1 from public.league_waiver_order where league_id = p_league_id) then
    return;
  end if;

  select * into v_window from public.league_game_window where league_id = p_league_id;
  if not found then
    return; -- admin hasn't configured this league's game window yet
  end if;

  select max(picked_at)::date into v_draft_done_date from public.league_draft_picks where league_id = p_league_id;

  v_current_week_start := public.events_week_start((now() at time zone 'Australia/Melbourne')::date);
  v_walk_week_start := public.events_week_start(greatest(v_window.window_start, coalesce(v_draft_done_date, v_window.window_start)));

  while v_walk_week_start <= v_current_week_start loop
    v_week_number := public.events_week_number(v_walk_week_start);
    select bounds.window_close into v_window_close from public.events_window_bounds(v_walk_week_start) bounds;
    v_effective_date := v_walk_week_start + 5; -- the following Saturday

    if v_window_close <= now()
       and not exists (select 1 from public.league_waiver_runs r where r.league_id = p_league_id and r.week_number = v_week_number)
    then
      select array_agg(user_id order by position) into v_order
      from public.league_waiver_order where league_id = p_league_id;

      if v_order is not null then
        foreach v_user in array v_order loop
          select * into v_req from public.waiver_requests
          where league_id = p_league_id and user_id = v_user and week_number = v_week_number and status = 'pending'
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
              update public.ownership_periods
              set end_date = v_effective_date
              where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id and end_date is null;

              delete from public.stables
              where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id;

              insert into public.stables (league_id, user_id, horse_id, paid_price, baseline_prizemoney)
              values (p_league_id, v_user, v_awarded, null, 0);

              insert into public.ownership_periods (league_id, user_id, horse_id, start_date, end_date)
              values (p_league_id, v_user, v_awarded, v_effective_date, null);

              insert into public.transfers (league_id, user_id, week_number, horse_out_id, horse_in_id)
              values (p_league_id, v_user, v_week_number, v_req.horse_out_id, v_awarded);

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

        v_new_order := v_order[2:array_length(v_order, 1)] || v_order[1:1];
        for i in 1..array_length(v_new_order, 1) loop
          update public.league_waiver_order
          set position = i
          where league_id = p_league_id and user_id = v_new_order[i];
        end loop;
      end if;

      insert into public.league_waiver_runs (league_id, week_number) values (p_league_id, v_week_number);
    end if;

    v_walk_week_start := v_walk_week_start + 7;
  end loop;
end;
$function$;

-- submit_waiver_request() and check_league_waivers() now branch on the
-- league's scoring_model so js/transfers.js needs no changes at all — it
-- already just calls these two RPCs generically.

create or replace function public.submit_waiver_request(p_league_id uuid, p_horse_out_id uuid, p_choice_1 uuid, p_choice_2 uuid DEFAULT NULL::uuid, p_choice_3 uuid DEFAULT NULL::uuid)
returns waiver_requests
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_league public.leagues;
  v_week_number int;
  v_window_open timestamptz;
  v_window_close timestamptz;
  v_week public.season_weeks;
  v_req public.waiver_requests;
  v_week_start date;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  select * into v_league from public.leagues where id = p_league_id;

  if v_league.scoring_model = 'events' then
    perform public.process_events_waivers_if_due(p_league_id);

    v_week_start := public.events_week_start((now() at time zone 'Australia/Melbourne')::date);
    v_week_number := public.events_week_number(v_week_start);
    select bounds.window_open, bounds.window_close into v_window_open, v_window_close
    from public.events_window_bounds(v_week_start) bounds;

    if not (now() >= v_window_open and now() < v_window_close) then
      raise exception 'The transfer window is currently closed — it reopens Monday 10am and closes Friday 8pm';
    end if;
  else
    perform public.process_league_waivers_if_due(p_league_id);

    select * into v_week from public.get_current_week();
    if not found then
      if exists (select 1 from public.season_weeks where closes_at > now()) then
        raise exception 'The transfer window is currently closed — check the Stable Transfer page for when it reopens';
      else
        raise exception 'The season is over — no more transfers can be made';
      end if;
    end if;
    v_week_number := v_week.week_number;
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
  values (p_league_id, auth.uid(), v_week_number, p_horse_out_id, p_choice_1, p_choice_2, p_choice_3)
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
$function$;

create or replace function public.check_league_waivers(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_model text;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  select scoring_model into v_model from public.leagues where id = p_league_id;
  if v_model = 'events' then
    perform public.process_events_waivers_if_due(p_league_id);
  else
    perform public.process_league_waivers_if_due(p_league_id);
  end if;
end;
$function$;

-- Draft award: open an ownership_periods row too, for events leagues
-- only. Start date is the game window's start, or the day this horse was
-- actually awarded if the draft finishes after the window has already
-- opened (greatest() ignores a null window_start if the admin somehow
-- hasn't configured one yet, falling back to the award date rather than
-- erroring mid-draft).
create or replace function public.advance_draft_if_expired(p_league_id uuid)
returns league_draft_state
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state public.league_draft_state;
  v_random_horse uuid;
  v_next_idx int;
  v_next_user uuid;
  v_attempts int := 0;
  v_team_count int;
  v_pool_empty boolean;
  v_scoring_model text;
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

    select scoring_model into v_scoring_model from public.leagues where id = p_league_id;
    if v_scoring_model = 'events' then
      insert into public.ownership_periods (league_id, user_id, horse_id, start_date, end_date)
      values (
        p_league_id, v_state.current_bidder_user_id, v_state.current_lot_horse_id,
        greatest(
          (select window_start from public.league_game_window where league_id = p_league_id),
          (now() at time zone 'Australia/Melbourne')::date
        ),
        null
      );
    end if;

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
$function$;

-- Admin-only: flip a league onto the events model and set its game
-- window. Separate from create_league() (which stays simple/user-facing,
-- always creating a 'legacy' league by default) since only an admin
-- should be deciding this, and typically right after creating the league
-- but before anyone drafts.
create or replace function public.admin_set_league_scoring_model(p_league_id uuid, p_scoring_model text, p_window_start date default null, p_window_end date default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.require_admin();

  if p_scoring_model not in ('legacy', 'events') then
    raise exception 'Invalid scoring model: %', p_scoring_model;
  end if;

  update public.leagues set scoring_model = p_scoring_model where id = p_league_id;

  if p_scoring_model = 'events' then
    if p_window_start is null or p_window_end is null then
      raise exception 'An events league needs both a window start and end date';
    end if;
    insert into public.league_game_window (league_id, window_start, window_end)
    values (p_league_id, p_window_start, p_window_end)
    on conflict (league_id) do update set window_start = excluded.window_start, window_end = excluded.window_end;
  end if;
end;
$function$;

-- reset_league_draft() already wipes stables/transfers/waiver state for
-- testing — extend it to also clear ownership_periods (the only change
-- from its existing body), so a re-drafted events league doesn't inherit
-- stale periods from a previous attempt.
create or replace function public.reset_league_draft(p_league_code text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_league public.leagues;
begin
  perform public.require_admin();

  select * into v_league from public.leagues where code = upper(trim(p_league_code));
  if not found then
    raise exception 'No league found with that code';
  end if;

  delete from public.transfers where league_id = v_league.id;
  delete from public.waiver_requests where league_id = v_league.id;
  delete from public.league_waiver_order where league_id = v_league.id;
  delete from public.league_waiver_runs where league_id = v_league.id;
  delete from public.ownership_periods where league_id = v_league.id;
  delete from public.stables where league_id = v_league.id;
  delete from public.league_draft_picks where league_id = v_league.id;

  update public.league_draft_state set
    status = 'idle',
    nominator_order = '{}',
    nominator_index = 0,
    current_nominator_user_id = null,
    current_lot_horse_id = null,
    current_bid = null,
    current_bidder_user_id = null,
    bid_count = 0,
    nomination_deadline = null,
    bid_deadline = null,
    updated_at = now()
  where league_id = v_league.id;
end;
$function$;
