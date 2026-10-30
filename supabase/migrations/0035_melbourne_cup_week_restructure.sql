-- Melbourne Cup week restructuring. The upcoming window needs to open this
-- evening (ahead of Cup day) and close Tuesday morning, then the window
-- after that opens two days late (Wednesday instead of Monday) but closes
-- on the normal Saturday 8:30am slot, after which the schedule resumes as
-- normal. No DST boundary crossed by any of this (AEDT the whole way).

-- Free up week_number 13 by shifting it up first, avoiding a PK collision
-- with the old week 12 that's about to take slot 13.
update public.season_weeks
set week_number = 14, label = 'Week 14'
where week_number = 13;

-- Old week 12 becomes week 13: same close (Sat 7 Nov 8:30am), later open.
update public.season_weeks
set week_number = 13,
    label = 'Week 13',
    opens_at = (timestamp '2026-11-04 10:00:00') at time zone 'Australia/Melbourne'
where week_number = 12;

-- New interim Melbourne Cup window takes the now-free week_number 12.
insert into public.season_weeks (week_number, label, opens_at, closes_at)
values (
  12,
  'Week 12 — Melbourne Cup',
  (timestamp '2026-10-30 17:00:00') at time zone 'Australia/Melbourne',
  (timestamp '2026-11-03 08:30:00') at time zone 'Australia/Melbourne'
);

-- Shorten week 11's close to the instant the new window opens, so there's
-- no overlap and no gap between the two.
update public.season_weeks
set closes_at = (timestamp '2026-10-30 17:00:00') at time zone 'Australia/Melbourne'
where week_number = 11;
