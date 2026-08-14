-- League lifecycle: creation, joining, and budget accounting.
-- All security-definer so the client never has to be trusted with the
-- code-uniqueness check or membership insert as two separate round trips.

-- ----------------------------------------------------------------------------
-- generate_league_code — 6-char uppercase alphanumeric, retried until unique
-- ----------------------------------------------------------------------------

create function public.generate_league_code()
returns text
language plpgsql
as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I ambiguity
  code text;
  exists_already boolean;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    end loop;
    select exists(select 1 from public.leagues l where l.code = code) into exists_already;
    exit when not exists_already;
  end loop;
  return code;
end;
$$;

-- ----------------------------------------------------------------------------
-- create_league — creates the league, seeds draft_state, adds manager as member
-- ----------------------------------------------------------------------------

create function public.create_league(p_name text, p_scheduled_draft_at timestamptz default null)
returns public.leagues
language plpgsql
security definer set search_path = public
as $$
declare
  v_league public.leagues;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'League name is required';
  end if;

  insert into public.leagues (code, name, manager_user_id, scheduled_draft_at)
  values (public.generate_league_code(), trim(p_name), auth.uid(), p_scheduled_draft_at)
  returning * into v_league;

  insert into public.league_members (league_id, user_id)
  values (v_league.id, auth.uid());

  insert into public.league_draft_state (league_id, status)
  values (v_league.id, 'idle');

  return v_league;
end;
$$;

-- ----------------------------------------------------------------------------
-- join_league — looks up by shareable code, adds membership if not already in
-- ----------------------------------------------------------------------------

create function public.join_league(p_code text, p_team_name text default null)
returns public.leagues
language plpgsql
security definer set search_path = public
as $$
declare
  v_league public.leagues;
begin
  select * into v_league from public.leagues where code = upper(trim(p_code));
  if not found then
    raise exception 'No league found with that code';
  end if;

  insert into public.league_members (league_id, user_id, team_name)
  values (v_league.id, auth.uid(), p_team_name)
  on conflict (league_id, user_id) do update set team_name = coalesce(excluded.team_name, public.league_members.team_name);

  return v_league;
end;
$$;

-- ----------------------------------------------------------------------------
-- league_budget — spent/remaining/maxBid for one member of one league's draft
--
-- maxBid = budget - reserve, where budget = $100 - spent, and reserve holds
-- back $1 for every OTHER empty slot (10 total, no bench) so a member can
-- never bid themselves out of being able to fill their whole stable.
-- ----------------------------------------------------------------------------

create function public.league_budget(p_league_id uuid, p_user_id uuid)
returns table (spent int, picks_count int, budget int, remaining_slots int, max_bid int)
language plpgsql
stable
security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  return query
  with p as (
    select coalesce(sum(price_paid), 0)::int as spent, count(*)::int as picks_count
    from public.league_draft_picks
    where league_id = p_league_id and user_id = p_user_id
  )
  select
    p.spent,
    p.picks_count,
    (100 - p.spent) as budget,
    (10 - p.picks_count) as remaining_slots,
    greatest((100 - p.spent) - greatest(10 - p.picks_count - 1, 0), 0) as max_bid
  from p;
end;
$$;

grant execute on function public.generate_league_code() to authenticated;
grant execute on function public.create_league(text, timestamptz) to authenticated;
grant execute on function public.join_league(text, text) to authenticated;
grant execute on function public.league_budget(uuid, uuid) to authenticated;
