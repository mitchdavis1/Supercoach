-- Remove Captain/Vice-Captain entirely. Every horse now scores at a flat
-- 1x — no more doubling, no more designation, no more carry-over-on-trade
-- logic for it. This also sidesteps the historical-captain-tracking gap
-- flagged in the prizemoney baseline/banking migration (captain doubling
-- applying to whoever holds the role now rather than who held it when
-- each dollar was earned) since there's no more doubling to misattribute.

drop function if exists public.set_captain(uuid, uuid);
drop function if exists public.set_vice_captain(uuid, uuid);
drop policy if exists "owners can set captain/vice-captain on their own horses" on public.stables;

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

    insert into public.stables (league_id, user_id, horse_id, paid_price, baseline_prizemoney)
    values (p_league_id, auth.uid(), p_horse_in_id, null, v_horse_in_total);

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

alter table public.stables drop column is_captain;
alter table public.stables drop column is_vice_captain;
