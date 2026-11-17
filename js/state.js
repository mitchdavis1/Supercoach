// Shared, mutable app state. Every module reads/writes this same object
// instead of keeping its own copies, so a realtime update in one place
// (e.g. draft.js) is immediately visible to another (e.g. app.js's header).

export const state = {
  session: null,
  profile: null,          // row from public.profiles for the signed-in user
  leagues: [],             // [{ ...leagues row, team_name }] the user belongs to
  activeLeagueId: null,
  horses: [],              // full horse catalog, cached after first load
  horsesById: new Map(),
  draftState: null,        // current league_draft_state row
  draftPicks: [],           // league_draft_picks rows for the active league
  stable: [],               // stables rows for the active league + current user
  members: [],              // league_members rows (+profile) for the active league
  acceptances: [],
  prizemoneyByHorse: new Map(),
  futuresByHorse: new Map(), // horse_id -> [{race_name, odds}], sorted shortest-odds first
  eventsEarnedByHorse: new Map(), // horse_id -> earned-in-window since its CURRENT open ownership_periods row started (scoring_model = 'events' leagues only — see loadEventsOwnershipPeriods() in scoring.js)
  realtimeChannel: null,
};

export function horseName(id) {
  const h = state.horsesById.get(id);
  return h ? h.name : 'Unknown horse';
}

// A horse only scores what it's earned since joining this stable — not its
// raw cumulative total, which would otherwise hand a traded-in horse's
// pre-trade earnings to its new owner. baseline_prizemoney is snapshotted
// server-side at draft/transfer time (see process_league_waivers_if_due());
// earnings banked from horses traded away live on league_members.banked_earnings,
// separately from any single horse.
//
// Floored at 0: a horse's cumulative prizemoney should only ever go up in
// reality, but an admin re-importing a corrected (lower) total for a horse —
// or, in testing, uploading two files with inconsistent numbers for the same
// horse — would otherwise make it look like the horse "un-won" money while
// held, dragging a manager's score negative for something that never
// happened. Zero is the honest floor: "earned nothing new," not "lost."
export function earnedForStableRow(s) {
  const raw = state.prizemoneyByHorse.get(s.horse_id) || 0;
  return Math.max(0, raw - (Number(s.baseline_prizemoney) || 0));
}

// Events-model equivalent of earnedForStableRow, for a league on
// scoring_model = 'events' (NZ season onward). There's no baseline/banking
// here — eventsEarnedByHorse is already the correct in-window sum for
// whoever currently holds the horse, computed from dated
// prizemoney_events against that horse's open ownership_periods row (see
// loadEventsOwnershipPeriods() in scoring.js). A horse can only be
// actively held by one manager per league at a time, so horse_id alone is
// an unambiguous key here.
export function earnedForStableRowEvents(s) {
  return Number(state.eventsEarnedByHorse.get(s.horse_id)) || 0;
}

// Dispatches to the right earned-calculation for the active league's
// scoring_model, so callers don't each need their own branch.
export function getEarnedForStableRow(s, league) {
  return league?.scoring_model === 'events' ? earnedForStableRowEvents(s) : earnedForStableRow(s);
}

export function fmtMoney(n) {
  const v = Number(n) || 0;
  if (Math.abs(v) >= 1_000_000) return '$' + (v / 1_000_000).toFixed(2).replace(/\.00$/, '') + 'M';
  if (Math.abs(v) >= 1_000) return '$' + (v / 1_000).toFixed(0) + 'K';
  return '$' + v.toFixed(v % 1 === 0 ? 0 : 2);
}

export function getActiveLeague() {
  return state.leagues.find((l) => l.id === state.activeLeagueId) || null;
}
