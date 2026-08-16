-- Admin testing utility — wipes one league's draft picks, stables, and
-- transfers, and resets its draft_state back to 'idle' so the draft can be
-- re-run from scratch. Scoped to a single league (by code) rather than a
-- global reset, since an admin may have multiple leagues and shouldn't be
-- able to nuke someone else's in-progress draft by accident.

create function public.reset_league_draft(p_league_code text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_league public.leagues;
begin
  perform public.require_admin();

  select * into v_league from public.leagues where code = upper(trim(p_league_code));
  if not found then
    raise exception 'No league found with that code';
  end if;

  delete from public.transfers where league_id = v_league.id;
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
$$;

grant execute on function public.reset_league_draft(text) to authenticated;
