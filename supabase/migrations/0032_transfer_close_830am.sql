-- Transfer window close time: Saturday 10am -> Saturday 8:30am. A fixed
-- 1.5-hour pull-forward applied uniformly to every week's closes_at — safe
-- across AEST/AEDT weeks since it's just an earlier instant on the same
-- already-correctly-localised Saturday, no DST boundary involved.
update public.season_weeks set closes_at = closes_at - interval '1 hour 30 minutes';
