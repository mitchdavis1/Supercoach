-- Admin testing utility — wipes all recorded prizemoney totals AND resets
-- every stable row's baseline_prizemoney and every league's banked_earnings
-- back to zero, across every league. Scoped globally rather than per-league
-- because prizemoney itself is global (shared) data: resetting only the
-- totals while leaving stale baselines/banked amounts in place elsewhere
-- would just recreate the same mismatch this exists to fix (see the
-- Sass Appeal case — baseline snapshotted from an earlier test import,
-- current total from a later one, producing an impossible negative delta).
-- Use when prior prizemoney uploads were test/placeholder data and you want
-- the next real cumulative file to start genuine scoring from a clean zero
-- for every manager and every currently-held horse.

create function public.reset_prizemoney_tracking()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  perform public.require_admin();

  delete from public.prizemoney where true;
  update public.stables set baseline_prizemoney = 0;
  update public.league_members set banked_earnings = 0;
end;
$$;

grant execute on function public.reset_prizemoney_tracking() to authenticated;
