import { supabase } from './supabaseClient.js';
import { state, getActiveLeague, fmtMoney, earnedForStableRow } from './state.js';
import { loadLeagueMembers } from './league.js';

// Scoring: a horse scores 100% of what it's earned since joining this
// stable (see earnedForStableRow in state.js — not its raw cumulative
// total, which would otherwise hand a traded-in horse's pre-trade earnings
// to its new owner). Plus banked_earnings — money already locked in from
// horses traded away earlier in the season, which stays with the manager
// permanently. Ported from computeMyLeaderboardScore() — summed across the
// whole stable, no per-week breakdown (the prototype never actually
// implemented weekly scoring; the leaderboard's "Filter by week" selector
// is preserved as a UI affordance but full-season is the only figure
// that's real).

export async function loadPrizemoney() {
  // Same cap as horses (see loadHorses() in draft.js) — a single request
  // maxes out at 1000 rows. The prizemoney table crossed that threshold
  // partway through the season, which silently dropped every horse past
  // row 1000 from scoring with no error, no matter how correct their
  // imported total was. Page through it all.
  const pageSize = 1000;
  const all = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase.from('prizemoney').select('horse_id, total_prizemoney').range(from, from + pageSize - 1);
    if (error) {
      console.error('Could not load prizemoney', error);
      break;
    }
    all.push(...data);
    if (data.length < pageSize) break;
  }
  state.prizemoneyByHorse = new Map(all.map((p) => [p.horse_id, Number(p.total_prizemoney)]));
}

export async function loadFuturesOdds() {
  // Same 1000-row cap as above — futures_odds is nowhere near it yet, but
  // paginate now rather than waiting to rediscover this a third time.
  const pageSize = 1000;
  const all = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase.from('futures_odds').select('horse_id, race_name, odds').range(from, from + pageSize - 1);
    if (error) {
      console.error('Could not load futures odds', error);
      break;
    }
    all.push(...data);
    if (data.length < pageSize) break;
  }
  const byHorse = new Map();
  all.forEach((f) => {
    if (!byHorse.has(f.horse_id)) byHorse.set(f.horse_id, []);
    byHorse.get(f.horse_id).push({ race_name: f.race_name, odds: f.odds != null ? Number(f.odds) : null });
  });
  byHorse.forEach((markets) => markets.sort((a, b) => (a.odds ?? Infinity) - (b.odds ?? Infinity)));
  state.futuresByHorse = byHorse;
}

function scoreForStable(stableRows, bankedEarnings) {
  const fromHorses = stableRows.reduce((total, s) => total + earnedForStableRow(s), 0);
  return fromHorses + (Number(bankedEarnings) || 0);
}

// Shared by every events-model reader (the leaderboard below, and My
// League's team/history view in inplay.js) — the one place that
// implements "sum of prizemoney_events for this ownership period, clipped
// to the league's game window." Returns every ownership_periods row for
// the league (past AND current — a manager's full-season total needs
// both), each with its `earned` amount attached. No separate
// banked_earnings concept exists for 'events' leagues: since periods are
// closed out with an end_date rather than deleted, summing every period
// a manager has ever held already gives the correct full-season figure.
export async function loadEventsOwnershipPeriods(leagueId) {
  const { data: periods, error } = await supabase
    .from('ownership_periods')
    .select('id, user_id, horse_id, start_date, end_date')
    .eq('league_id', leagueId);
  if (error) {
    console.error('Could not load ownership periods', error);
    return [];
  }

  const { data: windowRow } = await supabase
    .from('league_game_window')
    .select('window_start, window_end')
    .eq('league_id', leagueId)
    .maybeSingle();
  const windowStart = windowRow?.window_start ?? null;
  const windowEnd = windowRow?.window_end ?? null;
  const inWindow = (d) => (!windowStart || d >= windowStart) && (!windowEnd || d <= windowEnd);

  const horseIds = [...new Set((periods || []).map((p) => p.horse_id))];
  const events = await fetchPrizemoneyEventsForHorses(horseIds);
  const eventsByHorse = new Map();
  events.forEach((e) => {
    if (!eventsByHorse.has(e.horse_id)) eventsByHorse.set(e.horse_id, []);
    eventsByHorse.get(e.horse_id).push(e);
  });

  return (periods || []).map((p) => {
    const earned = (eventsByHorse.get(p.horse_id) || [])
      .filter((e) => e.race_date >= p.start_date && (!p.end_date || e.race_date < p.end_date) && inWindow(e.race_date))
      .reduce((total, e) => total + Number(e.stake), 0);
    return { ...p, earned };
  });
}

// Paginated the same way as loadPrizemoney() (Supabase caps a single
// request at 1000 rows), and chunked into batches of 200 horse_ids per
// request since a huge .in() filter list doesn't scale forever either.
async function fetchPrizemoneyEventsForHorses(horseIds) {
  if (horseIds.length === 0) return [];
  const all = [];
  const chunkSize = 200;
  for (let i = 0; i < horseIds.length; i += chunkSize) {
    const chunk = horseIds.slice(i, i + chunkSize);
    const pageSize = 1000;
    for (let from = 0; ; from += pageSize) {
      const { data, error } = await supabase
        .from('prizemoney_events')
        .select('horse_id, race_date, stake')
        .in('horse_id', chunk)
        .range(from, from + pageSize - 1);
      if (error) {
        console.error('Could not load prizemoney events', error);
        break;
      }
      all.push(...data);
      if (data.length < pageSize) break;
    }
  }
  return all;
}

// Populates state.eventsEarnedByHorse for the active league's CURRENTLY
// held horses only (open ownership_periods rows) — the per-horse display
// used by stable.js and inplay.js, mirroring how prizemoneyByHorse backs
// the legacy earnedForStableRow().
export async function loadEventsEarnings(leagueId) {
  const periods = await loadEventsOwnershipPeriods(leagueId);
  state.eventsEarnedByHorse = new Map(
    periods.filter((p) => p.end_date == null).map((p) => [p.horse_id, p.earned])
  );
}

export async function renderLeaderboard() {
  const league = getActiveLeague();
  const heroRank = document.getElementById('lbHeroRank');
  const heroName = document.getElementById('lbHeroName');
  const heroPts = document.getElementById('lbHeroPts');
  const rowsContainer = document.getElementById('lbRows');
  if (!rowsContainer) return;

  if (!league) {
    rowsContainer.innerHTML = '<div class="league-empty-state" style="padding:40px;">Join a league to see a leaderboard.</div>';
    return;
  }

  // banked_earnings only reaches state.members via a realtime subscription
  // (see subscribeToMembership() in league.js) — fine while the tab stays
  // connected, but a waiver run processing while the tab was backgrounded
  // or briefly disconnected leaves it stale with no visible error. Refetch
  // it fresh here too, same as stables below, so the leaderboard is always
  // correct without requiring a manual reload.
  await loadLeagueMembers(league.id);

  const rows = league.scoring_model === 'events'
    ? await computeEventsLeaderboardRows(league)
    : await computeLegacyLeaderboardRows(league);
  rows.sort((a, b) => b.score - a.score);

  const me = rows.find((r) => r.userId === state.session.user.id);
  const myRank = rows.findIndex((r) => r.userId === state.session.user.id) + 1;

  if (heroRank) heroRank.textContent = me ? '#' + myRank : '#—';
  if (heroName) heroName.textContent = getActiveLeague()?.name || '—';
  if (heroPts) heroPts.textContent = fmtMoney(me?.score || 0);

  rowsContainer.innerHTML = rows.map((r, i) => {
    const isMe = r.userId === state.session.user.id;
    const rank = i + 1;
    const posClass = rank === 1 ? 'gold' : rank === 2 ? 'silver' : rank === 3 ? 'bronze' : '';
    return `
      <div class="lb-row ${isMe ? 'me' : ''}">
        <div class="lb-pos ${posClass} ${isMe ? 'me-pos' : ''}">${rank}</div>
        <div class="lb-avatar" style="background:#FFF0F8;color:#E8007D;">${(r.name || '?')[0].toUpperCase()}</div>
        <div class="lb-user-info">
          <div class="lb-username ${isMe ? 'me-label' : ''}">${escapeHtml(r.name)}</div>
          <div class="lb-team-name">${escapeHtml(r.teamName || '')}</div>
        </div>
        <div class="lb-score-col"><div class="lb-pts">${fmtMoney(r.score)}</div><div class="lb-pts-label">${r.stableCount}/10 horses</div></div>
        <div class="lb-change eq">—</div>
      </div>`;
  }).join('') || '<div class="league-empty-state" style="padding:40px;">No members yet</div>';
}

async function computeLegacyLeaderboardRows(league) {
  // Same staleness risk as banked_earnings above: prizemoneyByHorse is
  // only loaded once at sign-in and after an admin runs an import (see
  // refreshAfterImport() in admin-import.js). Refetch it fresh here too.
  await loadPrizemoney();

  const { data: allStables, error } = await supabase.from('stables').select('*').eq('league_id', league.id);
  if (error) {
    console.error('Could not load league stables', error);
    return [];
  }

  const byUser = new Map();
  (allStables || []).forEach((s) => {
    if (!byUser.has(s.user_id)) byUser.set(s.user_id, []);
    byUser.get(s.user_id).push(s);
  });

  return state.members.map((m) => {
    const stable = byUser.get(m.user_id) || [];
    return {
      userId: m.user_id,
      name: m.profiles?.display_name || m.profiles?.username || 'Manager',
      teamName: m.team_name,
      score: scoreForStable(stable, m.banked_earnings),
      stableCount: stable.length,
    };
  });
}

async function computeEventsLeaderboardRows(league) {
  const [periods, { data: allStables, error }] = await Promise.all([
    loadEventsOwnershipPeriods(league.id),
    supabase.from('stables').select('user_id').eq('league_id', league.id),
  ]);
  if (error) console.error('Could not load league stables', error);

  const stableCounts = new Map();
  (allStables || []).forEach((s) => stableCounts.set(s.user_id, (stableCounts.get(s.user_id) || 0) + 1));

  const scoreByUser = new Map();
  periods.forEach((p) => scoreByUser.set(p.user_id, (scoreByUser.get(p.user_id) || 0) + p.earned));

  return state.members.map((m) => ({
    userId: m.user_id,
    name: m.profiles?.display_name || m.profiles?.username || 'Manager',
    teamName: m.team_name,
    score: scoreByUser.get(m.user_id) || 0,
    stableCount: stableCounts.get(m.user_id) || 0,
  }));
}

export function setLbRound() {
  // Weekly scoring isn't tracked server-side yet (matches the prototype,
  // where this was a no-op stub) — full-season is the only real figure.
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
