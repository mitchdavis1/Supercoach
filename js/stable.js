import { supabase } from './supabaseClient.js';
import { state, getActiveLeague, earnedForStableRow } from './state.js';

export async function loadStable(leagueId) {
  if (!leagueId || !state.session) {
    state.stable = [];
    return;
  }
  const { data, error } = await supabase
    .from('stables')
    .select('*')
    .eq('league_id', leagueId)
    .eq('user_id', state.session.user.id);
  if (error) {
    console.error('Could not load stable', error);
    return;
  }
  state.stable = data || [];
}

export async function setCaptain(horseId) {
  const league = getActiveLeague();
  if (!league) return;
  const { error } = await supabase.rpc('set_captain', { p_league_id: league.id, p_horse_id: horseId });
  if (error) {
    alert(error.message);
    return;
  }
  await loadStable(league.id);
  renderMyStablePage();
}

export async function setViceCaptain(horseId) {
  const league = getActiveLeague();
  if (!league) return;
  const { error } = await supabase.rpc('set_vice_captain', { p_league_id: league.id, p_horse_id: horseId });
  if (error) {
    alert(error.message);
    return;
  }
  await loadStable(league.id);
  renderMyStablePage();
}

export function renderMyStablePage() {
  const container = document.getElementById('myteamContainer');
  const budgetDisplay = document.getElementById('budgetDisplay');
  const budgetBar = document.getElementById('budgetBar');
  if (!container) return;

  const league = getActiveLeague();
  const spent = state.stable.reduce((sum, s) => sum + (s.paid_price || 0), 0);
  if (budgetDisplay) budgetDisplay.textContent = '$' + spent;
  if (budgetBar) {
    const pct = Math.min(100, (spent / 100) * 100);
    budgetBar.style.width = pct + '%';
    budgetBar.classList.toggle('danger', pct > 90);
  }

  if (!league) {
    container.innerHTML = `<div class="league-empty-state">Join or create a league to build your stable — head to the Join A League tab.</div>`;
    return;
  }

  if (!state.stable.length) {
    container.innerHTML = `<div class="league-empty-state">You haven't won any horses yet — head to the Draft Room.<br/><button class="myteam-cta-btn" onclick="showPage('draft')">Go to Draft Room</button></div>`;
    return;
  }

  const rows = state.stable
    .slice()
    .sort((a, b) => (b.is_captain - a.is_captain) || (b.is_vice_captain - a.is_vice_captain))
    .map((s) => {
      const horse = state.horsesById.get(s.horse_id);
      const earned = earnedForStableRow(s);
      const scored = s.is_captain ? earned * 2 : earned;
      return `
        <div class="team-slot filled ${s.is_captain ? 'captain' : ''} ${s.is_vice_captain ? 'vc' : ''}">
          <span class="slot-role-label ${s.is_captain ? 'cap' : s.is_vice_captain ? 'vc' : 'open'}">${s.is_captain ? 'C' : s.is_vice_captain ? 'VC' : ''}</span>
          <div class="slot-avatar horse">${horse?.emoji || '🐎'}</div>
          <div class="slot-info">
            <div class="slot-name">${escapeHtml(horse?.name || 'Horse')}${s.is_captain ? '<span class="captain-badge">Captain</span>' : ''}${s.is_vice_captain ? '<span class="vc-badge">VC</span>' : ''}</div>
            <div class="slot-meta">${s.paid_price != null ? `$${s.paid_price} paid · ` : ''}${fmtMoney(scored)} ${s.is_captain ? '(Captain ×2)' : 'earned'}</div>
          </div>
          <button class="set-captain-btn" style="display:inline-block;" onclick="setCaptain('${s.horse_id}')" title="Set Captain">⭐</button>
          <button class="set-vc-btn" style="display:inline-block;" onclick="setViceCaptain('${s.horse_id}')" title="Set Vice Captain">🎖️</button>
        </div>`;
    }).join('');

  container.innerHTML = `<div class="section-header">Your Stable (${state.stable.length}/10)</div>${rows}`;
}

function fmtMoney(n) {
  const v = Number(n) || 0;
  if (Math.abs(v) >= 1_000_000) return '$' + (v / 1_000_000).toFixed(2).replace(/\.00$/, '') + 'M';
  if (Math.abs(v) >= 1_000) return '$' + (v / 1_000).toFixed(0) + 'K';
  return '$' + v.toFixed(0);
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
