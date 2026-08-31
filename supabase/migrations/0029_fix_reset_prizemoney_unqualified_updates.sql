-- Same pg_safeupdate protection as 0025, this time tripped by an unqualified
-- UPDATE rather than DELETE — "UPDATE requires a WHERE clause". Fix: `where
-- true`, which still updates every row but satisfies the safeguard.

create or replace function public.reset_prizemoney_tracking()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  perform public.require_admin();

  delete from public.prizemoney where true;
  update public.stables set baseline_prizemoney = 0 where true;
  update public.league_members set banked_earnings = 0 where true;
end;
$$;
