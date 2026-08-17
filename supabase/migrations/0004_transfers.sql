-- Transfers — one horse swap per league member per week.
--
-- The salary cap only ever applied during the live auction draft — once
-- that's over, dollar value has no bearing on who can trade for what, so
-- the incoming horse's paid_price is always null (not carried over from the
-- outgoing horse). Captain/VC status still carries over to the incoming
-- horse if the outgoing horse held it — both ported from confirmTransfer()
-- in the prototype, minus the now-removed cap carryover.
--
-- Prizemoney baseline + banking: raw cumulative prizemoney totals only mean
-- "what you earned" if you've owned the horse all season. A horse traded in
-- would otherwise bring its whole season's prior earnings with it (unearned
-- by the new owner), and a horse traded out would otherwise vanish from its
-- former owner's score retroactively, including what they earned while they
-- owned it. Fixed by:
--   - every stable row has a baseline_prizemoney, snapshotted at the moment
--     the horse joined that stable (draft award or transfer-in) — a
--     manager's live score from a horse they hold is its current cumulative
--     total minus that baseline, never the raw total;
--   - when a horse leaves a stable, the delta it earned while owned
--     (current total minus its baseline) is banked permanently into that
--     league_members row's banked_earnings, which survives the horse
--     leaving and is never touched again by future roster changes.
--
-- Atomicity/first-come-first-served comes from two unique constraints doing
-- real work inside one transaction: stables(league_id, horse_id) means a
-- second manager racing for the same incoming horse gets a unique_violation,
-- and transfers(league_id, user_id, week_number) means a second attempt at
-- your own weekly transfer also fails outright — no read-then-write gap.

create function public.execute_transfer(p_league_id uuid, p_horse_out_id uuid, p_horse_in_id uuid)
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

grant execute on function public.execute_transfer(uuid, uuid, uuid) to authenticated;
