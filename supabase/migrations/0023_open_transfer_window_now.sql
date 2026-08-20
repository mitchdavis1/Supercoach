-- Revert the season schedule so the first transfer window opens now (this
-- Mon-Fri) rather than waiting until after Memsie Stakes Day (next
-- weekend). Shift the existing 9 weeks up to week_number 3-11 (same
-- calendar dates/labels, just renumbered) and insert two new windows in
-- front of them: this week and next week.
--
-- week_number is a primary key, so shift via a temporary offset to avoid a
-- collision between the old and new numbering while the UPDATE is running.
update public.season_weeks set week_number = week_number + 100;
update public.season_weeks set week_number = week_number - 98;

update public.season_weeks set label = 'Week 3 — Memsie–Makybe Diva' where week_number = 3;
update public.season_weeks set label = 'Week 4' where week_number = 4;
update public.season_weeks set label = 'Week 5' where week_number = 5;
update public.season_weeks set label = 'Week 6' where week_number = 6;
update public.season_weeks set label = 'Week 7' where week_number = 7;
update public.season_weeks set label = 'Week 8' where week_number = 8;
update public.season_weeks set label = 'Week 9' where week_number = 9;
update public.season_weeks set label = 'Week 10' where week_number = 10;
update public.season_weeks set label = 'Week 11' where week_number = 11;

insert into public.season_weeks (week_number, label, opens_at, closes_at) values
  (1, 'Week 1', '2026-08-20T00:00:00Z', '2026-08-21T07:00:00Z'),
  (2, 'Week 2', '2026-08-24T00:00:00Z', '2026-08-28T07:00:00Z');
