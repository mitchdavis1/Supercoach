-- Extend the season schedule two more weeks, through Melbourne Cup week
-- and beyond, so the transfer window keeps running to Saturday 14
-- November rather than stopping after week 11. Same Monday 10am / Saturday
-- 8:30am AEDT cadence, derived from week 11's own timestamps (no DST
-- transition between now and mid-November, so a flat 7/14-day shift is
-- exact).
insert into public.season_weeks (week_number, label, opens_at, closes_at)
select 12, 'Week 12', opens_at + interval '7 days', closes_at + interval '7 days'
from public.season_weeks where week_number = 11;

insert into public.season_weeks (week_number, label, opens_at, closes_at)
select 13, 'Week 13', opens_at + interval '14 days', closes_at + interval '14 days'
from public.season_weeks where week_number = 11;
