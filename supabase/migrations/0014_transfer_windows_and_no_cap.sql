-- 1. Real trading windows: Monday 10am -> Friday 7pm, Melbourne local time
--    (correctly AEST/AEDT per date), instead of a single "deadline" with no
--    opening — previously "current week" was just whichever deadline was
--    soonest, so transfers were effectively open continuously with no
--    closed period at all.
-- 2. Transfers no longer carry over the outgoing horse's draft-day price
--    onto the incoming horse — the salary cap only ever applied during the
--    live auction draft; once that's over, dollar value has no bearing on
--    who can trade for what.

alter table public.season_weeks rename column deadline to closes_at;
alter table public.season_weeks add column opens_at timestamptz;

update public.season_weeks set opens_at = '2026-08-31T00:00:00Z', closes_at = '2026-09-04T09:00:00Z' where week_number = 1;
update public.season_weeks set opens_at = '2026-09-07T00:00:00Z', closes_at = '2026-09-11T09:00:00Z' where week_number = 2;
update public.season_weeks set opens_at = '2026-09-14T00:00:00Z', closes_at = '2026-09-18T09:00:00Z' where week_number = 3;
update public.season_weeks set opens_at = '2026-09-21T00:00:00Z', closes_at = '2026-09-25T09:00:00Z' where week_number = 4;
update public.season_weeks set opens_at = '2026-09-28T00:00:00Z', closes_at = '2026-10-02T09:00:00Z' where week_number = 5;
update public.season_weeks set opens_at = '2026-10-11T23:00:00Z', closes_at = '2026-10-16T08:00:00Z' where week_number = 6;
update public.season_weeks set opens_at = '2026-10-18T23:00:00Z', closes_at = '2026-10-23T08:00:00Z' where week_number = 7;
update public.season_weeks set opens_at = '2026-10-25T23:00:00Z', closes_at = '2026-10-30T08:00:00Z' where week_number = 8;
update public.season_weeks set opens_at = '2026-11-08T23:00:00Z', closes_at = '2026-11-13T08:00:00Z' where week_number = 9;

alter table public.season_weeks alter column opens_at set not null;

create or replace function public.get_current_week()
returns public.season_weeks
language sql
stable
as $$
  select * from public.season_weeks where now() >= opens_at and now() < closes_at order by week_number asc limit 1;
$$;

alter table public.stables alter column paid_price drop not null;

create or replace function public.execute_transfer(p_league_id uuid, p_horse_out_id uuid, p_horse_in_id uuid)
returns public.transfers
language plpgsql
security definer set search_path = public
as $$
declare
  v_week public.season_weeks;
  v_out public.stables;
  v_transfer public.transfers;
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

  begin
    delete from public.stables
    where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_out_id;

    insert into public.stables (league_id, user_id, horse_id, is_captain, is_vice_captain, paid_price)
    values (p_league_id, auth.uid(), p_horse_in_id, v_out.is_captain, v_out.is_vice_captain, null);

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
