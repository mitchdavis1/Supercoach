// Pure date/sum logic for the 'events' scoring model — no Supabase import,
// no DOM, so this is directly unit-testable with plain Node (see
// test/events-scoring.test.js) as well as usable from scoring.js in the
// browser. Keeping this logic in one place means the test suite exercises
// the exact same code the app runs, not a re-implementation that could
// silently drift from it.

// Sum of `stake` for events on this horse whose race_date falls inside
// the ownership period [start_date, end_date) — end_date null means still
// held — further clipped to [windowStart, windowEnd] if either is given
// (the league's admin-configured game window; dates outside it are kept
// in prizemoney_events but never count toward a score). All dates are
// plain 'YYYY-MM-DD' strings, which compare correctly with ordinary
// string comparison.
export function sumStakeForPeriod(events, period, windowStart, windowEnd) {
  return events
    .filter((e) => e.horse_id === period.horse_id)
    .filter((e) => e.race_date >= period.start_date && (!period.end_date || e.race_date < period.end_date))
    .filter((e) => (!windowStart || e.race_date >= windowStart) && (!windowEnd || e.race_date <= windowEnd))
    .reduce((total, e) => total + Number(e.stake), 0);
}

// Attaches `earned` to every period (see loadEventsOwnershipPeriods() in
// scoring.js) — the shared building block for both the leaderboard
// (sums every period, past and current) and the per-horse "currently
// held" display (filters to end_date == null afterward).
export function attachEarnedToPeriods(periods, events, windowStart, windowEnd) {
  return periods.map((p) => ({ ...p, earned: sumStakeForPeriod(events, p, windowStart, windowEnd) }));
}
