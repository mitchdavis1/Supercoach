-- Backfill league_waiver_order for leagues whose draft completed before the
-- waiver system (0021) existed. initialize_league_waiver_order() only ever
-- ran automatically at the moment a draft transitioned to 'complete' — any
-- league already complete when 0021 was applied was silently skipped, and
-- process_league_waivers_if_due() no-ops for a league with no waiver order,
-- so those leagues' transfers would never process. One-time, idempotent
-- (initialize_league_waiver_order() itself is a no-op if rows already
-- exist), safe to keep in the migration history for a fresh install too.

do $$
declare
  v_league record;
begin
  for v_league in
    select lds.league_id
    from public.league_draft_state lds
    where lds.status = 'complete'
      and not exists (select 1 from public.league_waiver_order lwo where lwo.league_id = lds.league_id)
  loop
    perform public.initialize_league_waiver_order(v_league.league_id);
  end loop;
end $$;
