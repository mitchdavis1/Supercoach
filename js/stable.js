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

  const rows = state.stable.map((s) => {
    const horse = state.horsesById.get(s.horse_id);
    const earned = earnedForStableRow(s);
    return `
      <div class="team-slot filled">
        <div class="slot-avatar horse">${horse?.emoji || '🐎'}</div>
        <div class="slot-info">
          <div class="slot-name">${escapeHtml(horse?.name || 'Horse')}</div>
          <div class="slot-meta">${s.paid_price != null ? `$${s.paid_price} paid · ` : ''}${fmtMoney(earned)} earned</div>
        </div>
      </div>`;
  }).join('');

  container.innerHTML = `<div class="section-header">Your Stable (${state.stable.length}/10)</div>${rows}`;

  renderFuturesTile();
}

function renderFuturesTile() {
  const tile = document.getElementById('myteamFuturesTile');
  if (!tile) return;

  const groups = state.stable
    .map((s) => ({ horse: state.horsesById.get(s.horse_id), markets: state.futuresByHorse.get(s.horse_id) }))
    .filter((g) => g.horse && g.markets?.length);

  tile.innerHTML = `
    <div class="futures-tile-header">🔮 Futures Watch</div>
    <div class="futures-tile-body">
      ${groups.map((g) => `
        <div class="futures-horse-group">
          <div class="futures-horse-name">${escapeHtml(g.horse.name)}</div>
          ${g.markets.map((m) => `
            <div class="futures-row">
              <span class="futures-race">${escapeHtml(m.race_name)}</span>
              <span class="futures-odds">${m.odds != null ? '$' + m.odds : '—'}</span>
            </div>`).join('')}
        </div>`).join('') || '<div class="futures-empty">None of your horses are in a futures market yet.</div>'}
    </div>`;
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
