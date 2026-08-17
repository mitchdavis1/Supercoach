import { supabase } from './supabaseClient.js';
import { state, getActiveLeague, fmtMoney, earnedForStableRow } from './state.js';

export async function renderInPlay() {
  const container = document.getElementById('inplayContent');
  if (!container) return;

  const league = getActiveLeague();
  if (!league || !state.stable.length) {
    container.innerHTML = `
      <div class="inplay-no-stable">
        <div class="inplay-no-stable-icon">🏇</div>
        <div class="inplay-no-stable-title">No stable yet</div>
        <div class="inplay-no-stable-sub">Join a league and win horses in the Draft Room to see them here.</div>
      </div>`;
    return;
  }

  const { data: acceptances } = await supabase.from('acceptances').select('*');
  const acceptanceByHorse = new Map((acceptances || []).map((a) => [a.horse_id, a]));

  const racing = [];
  const notRacing = [];
  state.stable.forEach((s) => {
    const horse = state.horsesById.get(s.horse_id);
    const acc = acceptanceByHorse.get(s.horse_id);
    (acc ? racing : notRacing).push({ s, horse, acc });
  });

  const bankedEarnings = Number(state.members.find((m) => m.user_id === state.session.user.id)?.banked_earnings) || 0;
  const totalScore = state.stable.reduce((sum, s) => sum + earnedForStableRow(s), bankedEarnings);

  const card = ({ s, horse, acc }) => {
    const earned = earnedForStableRow(s);
    return `
      <div class="inplay-card ${acc ? 'racing' : 'na-card'}">
        <div class="inplay-avatar ${acc ? '' : 'na'}">${horse?.emoji || '🐎'}</div>
        <div>
          <div class="inplay-horse-name">${escapeHtml(horse?.name || 'Horse')}</div>
          <div class="inplay-horse-meta">${escapeHtml(horse?.trainer || '')}</div>
        </div>
        <div class="inplay-race-col">
          ${acc ? `<div class="inplay-race-name">${escapeHtml(acc.venue || '')} R${acc.race_number ?? ''}</div>` : `<div class="inplay-race-na">Not accepted this week</div>`}
        </div>
        <div></div>
        <div class="inplay-score-col">
          <div class="inplay-earned ${earned ? '' : 'zero'}">${fmtMoney(earned)}</div>
          <div class="inplay-earned-label">earned by you</div>
        </div>
      </div>`;
  };

  container.innerHTML = `
    <div class="inplay-hero">
      <div class="inplay-hero-dot"></div>
      <div class="inplay-hero-info">
        <div class="inplay-hero-label">${escapeHtml(league.name)}</div>
        <div class="inplay-hero-title">My Stable — This Week</div>
        <div class="inplay-hero-sub">${racing.length} of ${state.stable.length} horses accepted to race this week</div>
      </div>
      <div class="inplay-hero-score">
        <div class="inplay-hero-pts">${fmtMoney(totalScore)}</div>
        <div class="inplay-hero-pts-label">season total</div>
      </div>
    </div>

    <div class="inplay-section-header"><span>🏇 Racing This Week</span><span class="inplay-section-count">${racing.length}</span></div>
    <div class="inplay-grid">${racing.map(card).join('') || '<div class="transfer-empty">None of your horses are accepted this week</div>'}</div>

    <div class="inplay-section-header"><span>💤 Not Racing</span><span class="inplay-section-count">${notRacing.length}</span></div>
    <div class="inplay-grid">${notRacing.map(card).join('')}</div>
  `;
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
