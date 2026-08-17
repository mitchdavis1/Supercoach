import { supabase } from './supabaseClient.js';
import { state, getActiveLeague, fmtMoney, earnedForStableRow } from './state.js';

// Scoring: a horse scores 100% of what it's earned since joining this
// stable (see earnedForStableRow in state.js — not its raw cumulative
// total, which would otherwise hand a traded-in horse's pre-trade earnings
// to its new owner); the Captain's contribution is doubled. Plus
// banked_earnings — money already locked in from horses traded away
// earlier in the season, which stays with the manager permanently. Ported
// from computeMyLeaderboardScore() — summed across the whole stable, no
// per-week breakdown (the prototype never actually implemented weekly
// scoring; the leaderboard's "Filter by week" selector is preserved as a
// UI affordance but full-season is the only figure that's real).

export async function loadPrizemoney() {
  const { data, error } = await supabase.from('prizemoney').select('horse_id, total_prizemoney');
  if (error) {
    console.error('Could not load prizemoney', error);
    return;
  }
  state.prizemoneyByHorse = new Map((data || []).map((p) => [p.horse_id, Number(p.total_prizemoney)]));
}

function scoreForStable(stableRows, bankedEarnings) {
  const fromHorses = stableRows.reduce((total, s) => {
    const earned = earnedForStableRow(s);
    return total + (s.is_captain ? Math.round(earned * 2) : earned);
  }, 0);
  return fromHorses + (Number(bankedEarnings) || 0);
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

  const { data: allStables, error } = await supabase.from('stables').select('*').eq('league_id', league.id);
  if (error) {
    console.error('Could not load league stables', error);
    return;
  }

  const byUser = new Map();
  (allStables || []).forEach((s) => {
    if (!byUser.has(s.user_id)) byUser.set(s.user_id, []);
    byUser.get(s.user_id).push(s);
  });

  const rows = state.members.map((m) => {
    const stable = byUser.get(m.user_id) || [];
    const captainHorse = stable.find((s) => s.is_captain);
    return {
      userId: m.user_id,
      name: m.profiles?.display_name || m.profiles?.username || 'Manager',
      teamName: m.team_name,
      score: scoreForStable(stable, m.banked_earnings),
      topHorse: captainHorse ? state.horsesById.get(captainHorse.horse_id)?.name : null,
      stableCount: stable.length,
    };
  }).sort((a, b) => b.score - a.score);

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
        <div class="lb-picks">${r.topHorse ? `<span class="lb-pick-chip captain">${escapeHtml(r.topHorse)} ⭐</span>` : '<span class="lb-pick-chip">No captain set</span>'}</div>
        <div class="lb-score-col"><div class="lb-pts">${fmtMoney(r.score)}</div><div class="lb-pts-label">${r.stableCount}/10 horses</div></div>
        <div class="lb-change eq">—</div>
      </div>`;
  }).join('') || '<div class="league-empty-state" style="padding:40px;">No members yet</div>';
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
