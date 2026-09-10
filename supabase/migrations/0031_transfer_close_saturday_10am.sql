-- Transfer window close time: Friday 5pm -> Saturday 10am. A fixed 17-hour
-- shift (17:00 -> 24:00 is 7h, +10h to reach 10:00 next day = 17h) applied
-- uniformly to every week's closes_at — safe across both AEST and AEDT
-- weeks since it doesn't cross a DST transition, just moves the same
-- already-correctly-localised instant later by a fixed duration.
update public.season_weeks set closes_at = closes_at + interval '17 hours';
