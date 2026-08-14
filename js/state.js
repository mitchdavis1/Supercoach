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
  realtimeChannel: null,
};

export function horseName(id) {
  const h = state.horsesById.get(id);
  return h ? h.name : 'Unknown horse';
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
