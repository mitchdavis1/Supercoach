-- Restore a continuous week-to-week transfer cadence. The original season
-- schedule (written before the waiver system existed) had two deliberate
-- "bye week" gaps — no transfer window at all for one week at a time,
-- timed around the Cox Plate/Melbourne Cup carnival weeks having their own
-- feature-race Friday rather than the regular weekly one. That design is
-- no longer wanted: pull every week from the first gap onward back by 7
-- days, and everything after the second gap back by a further 7 (14 total),
-- closing both gaps while preserving each week's Monday 10am / Saturday
-- 8:30am local time exactly (a flat day-interval shift is safe here since
-- neither shift crosses a DST boundary — both ends of each move fall after
-- daylight saving already started on 4 Oct).
update public.season_weeks set opens_at = opens_at - interval '7 days', closes_at = closes_at - interval '7 days'
where week_number in (8, 9, 10);

update public.season_weeks set opens_at = opens_at - interval '14 days', closes_at = closes_at - interval '14 days'
where week_number = 11;
