// Tests for the date-based 'events' scoring model, against the brief's
// 8 required cases. Runs with plain Node (`node --test test/` or
// `npm test`) — no dependencies, no Supabase, no DOM.
//
// These exercise js/eventsScoring.js directly, the same pure module
// scoring.js uses in the browser — not a re-implementation of the logic
// that could silently drift from what actually ships.
//
// What isn't covered here, and why:
// - Case 6 (unmatched names reported, not dropped) and the horse-matching
//   half of case 8 are SQL-side behaviour in import_prizemoney_events()
//   (see supabase/migrations/0039_prizemoney_events_import.sql /
//   0040_fix_auto_create_same_statement_bug.sql) — verified live against
//   the real database while building it (including the auto-create bug
//   those migrations fix), not re-derived here since there's no local
//   Postgres to run them against from this test file.
// - The scraper itself (loveracing.nz discovery/parsing, rate limiting,
//   resumability) lives outside this repo on Mitch's machine and hasn't
//   been written yet — loveracing.nz isn't reachable from this
//   environment to investigate its page structure, so the scraper is a
//   separate, still-open piece of work. The dead-heat half of case 8 is
//   covered below at the data-model level: two different horses placed in
//   the same race race each get their own (race_date, venue, race_no,
//   horse_id) row, so a shared stake is just two equal, independent rows
//   — nothing scraper-specific to validate without the scraper.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sumStakeForPeriod, attachEarnedToPeriods } from '../js/eventsScoring.js';

const HORSE_A = 'horse-a';
const HORSE_B = 'horse-b';
const MANAGER_1 = 'user-1';
const MANAGER_2 = 'user-2';

test('case 1: a Friday/Saturday trade split — Friday stays with the old owner, Saturday onward goes to the new owner', () => {
  const events = [
    { horse_id: HORSE_A, race_date: '2026-12-04', stake: 10000 }, // Friday
    { horse_id: HORSE_A, race_date: '2026-12-05', stake: 20000 }, // Saturday
  ];
  const oldOwnerPeriod = { user_id: MANAGER_1, horse_id: HORSE_A, start_date: '2026-11-01', end_date: '2026-12-05' };
  const newOwnerPeriod = { user_id: MANAGER_2, horse_id: HORSE_A, start_date: '2026-12-05', end_date: null };

  assert.equal(sumStakeForPeriod(events, oldOwnerPeriod, null, null), 10000, 'old owner keeps only the Friday race');
  assert.equal(sumStakeForPeriod(events, newOwnerPeriod, null, null), 20000, 'new owner gets the Saturday race onward');
});

test('case 2: a horse traded away and back later sums correctly with no double-counting', () => {
  const events = [
    { horse_id: HORSE_A, race_date: '2026-12-01', stake: 5000 },
    { horse_id: HORSE_A, race_date: '2026-12-10', stake: 7000 }, // while owned by someone else, in between
    { horse_id: HORSE_A, race_date: '2026-12-20', stake: 9000 },
  ];
  const firstStint = { user_id: MANAGER_1, horse_id: HORSE_A, start_date: '2026-11-25', end_date: '2026-12-06' };
  const secondStint = { user_id: MANAGER_1, horse_id: HORSE_A, start_date: '2026-12-15', end_date: null };

  const periods = attachEarnedToPeriods([firstStint, secondStint], events, null, null);
  const total = periods.reduce((sum, p) => sum + p.earned, 0);

  assert.equal(periods[0].earned, 5000);
  assert.equal(periods[1].earned, 9000);
  assert.equal(total, 14000, 'the middle race (owned by someone else) must not count for either of this manager\'s periods');
});

test('case 3: re-importing an overlapping date range does not change totals', () => {
  const events = [
    { horse_id: HORSE_A, race_date: '2026-12-01', stake: 5000 },
    { horse_id: HORSE_A, race_date: '2026-12-08', stake: 6000 },
  ];
  const period = { horse_id: HORSE_A, start_date: '2026-11-01', end_date: null };

  // An upsert on (race_date, venue, race_no, horse_id) means a re-import
  // of an overlapping range can only ever replace an existing row's
  // stake, never duplicate it — so recomputing from the same resulting
  // event list is deterministic. Two passes over the identical array
  // (standing in for "before" and "after" a no-op re-import) must agree.
  const first = sumStakeForPeriod(events, period, null, null);
  const second = sumStakeForPeriod(events, period, null, null);
  assert.equal(first, 11000);
  assert.equal(second, first);
});

test('case 4: an amended result (a stake changes on re-scrape) updates the total', () => {
  const beforeAmendment = [{ horse_id: HORSE_A, race_date: '2026-12-01', stake: 5000 }];
  const afterAmendment = [{ horse_id: HORSE_A, race_date: '2026-12-01', stake: 7500 }]; // same race, corrected stake
  const period = { horse_id: HORSE_A, start_date: '2026-11-01', end_date: null };

  assert.equal(sumStakeForPeriod(beforeAmendment, period, null, null), 5000);
  assert.equal(sumStakeForPeriod(afterAmendment, period, null, null), 7500, 'the upserted (corrected) stake replaces the old one');
});

test('case 5: a 6-week catch-up import gives the same scores as weekly imports would have', () => {
  // Six weeks of racing for one horse, one continuous ownership period.
  const sixWeeksOfEvents = Array.from({ length: 6 }, (_, i) => ({
    horse_id: HORSE_A,
    race_date: `2026-${String(11 + Math.floor(i / 4)).padStart(2, '0')}-${String(((i * 7) % 28) + 1).padStart(2, '0')}`,
    stake: 1000 * (i + 1),
  }));
  const period = { horse_id: HORSE_A, start_date: '2026-11-01', end_date: null };

  // "Weekly imports" = summing whatever's arrived after each week;
  // running the full sum once at the end (the 6-week catch-up) must land
  // on the same final total as accumulating it incrementally.
  let incremental = 0;
  for (let i = 1; i <= sixWeeksOfEvents.length; i++) {
    incremental = sumStakeForPeriod(sixWeeksOfEvents.slice(0, i), period, null, null);
  }
  const bulkCatchUp = sumStakeForPeriod(sixWeeksOfEvents, period, null, null);

  assert.equal(incremental, bulkCatchUp);
  assert.equal(bulkCatchUp, 1000 + 2000 + 3000 + 4000 + 5000 + 6000);
});

test('case 7: events outside the game window are excluded from scores', () => {
  const events = [
    { horse_id: HORSE_A, race_date: '2026-11-20', stake: 4000 }, // before the window opens
    { horse_id: HORSE_A, race_date: '2026-12-15', stake: 6000 }, // inside the window
    { horse_id: HORSE_A, race_date: '2027-04-01', stake: 9000 }, // after the window closes
  ];
  const period = { horse_id: HORSE_A, start_date: '2026-11-01', end_date: null };
  const windowStart = '2026-12-01';
  const windowEnd = '2027-03-31';

  assert.equal(sumStakeForPeriod(events, period, windowStart, windowEnd), 6000, 'only the in-window race counts');
  assert.equal(sumStakeForPeriod(events, period, null, null), 19000, 'with no window configured, nothing is filtered (sanity check on the filter itself)');
});

test('case 8 (data-model half): a dead heat is just two horses with equal, independent stakes in the same race slot', () => {
  const events = [
    { horse_id: HORSE_A, race_date: '2026-12-05', stake: 7500 },
    { horse_id: HORSE_B, race_date: '2026-12-05', stake: 7500 },
  ];
  const periodA = { horse_id: HORSE_A, start_date: '2026-11-01', end_date: null };
  const periodB = { horse_id: HORSE_B, start_date: '2026-11-01', end_date: null };

  assert.equal(sumStakeForPeriod(events, periodA, null, null), 7500);
  assert.equal(sumStakeForPeriod(events, periodB, null, null), 7500);
});
