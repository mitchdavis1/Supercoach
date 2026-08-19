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

  const myId = state.session.user.id;
  const [{ data: acceptances }, { data: leagueStables }] = await Promise.all([
    supabase.from('acceptances').select('*'),
    supabase.from('stables').select('*').eq('league_id', league.id),
  ]);

  const acceptanceByHorse = new Map((acceptances || []).map((a) => [a.horse_id, a]));
  const memberById = new Map(state.members.map((m) => [m.user_id, m]));

  const racingRows = (leagueStables || [])
    .map((s) => ({ s, horse: state.horsesById.get(s.horse_id), acc: acceptanceByHorse.get(s.horse_id) }))
    .filter((r) => r.acc);

  const mine = racingRows.filter((r) => r.s.user_id === myId).sort(byDateThenVenue);
  const others = racingRows
    .filter((r) => r.s.user_id !== myId)
    .sort((a, b) => ownerName(memberById, a.s.user_id).localeCompare(ownerName(memberById, b.s.user_id)) || byDateThenVenue(a, b));

  const notRacing = state.stable.filter((s) => !acceptanceByHorse.get(s.horse_id));

  const bankedEarnings = Number(memberById.get(myId)?.banked_earnings) || 0;
  const totalScore = state.stable.reduce((sum, s) => sum + earnedForStableRow(s), bankedEarnings);

  const tableHeader = `
    <div class="league-acc-row header">
      <span>Date</span><span>Venue</span><span>Horse</span><span>Team</span>
    </div>`;

  const row = ({ s, horse, acc }) => {
    const isMine = s.user_id === myId;
    return `
      <div class="league-acc-row ${isMine ? 'mine' : ''}">
        <span class="league-acc-date">${fmtAccDate(acc.race_date)}</span>
        <span class="league-acc-venue">${escapeHtml(acc.venue || '—')}${acc.race_number ? ' R' + acc.race_number : ''}</span>
        <span class="league-acc-horse">${horse?.emoji || '🐎'} ${escapeHtml(horse?.name || 'Horse')}</span>
        <span class="league-acc-team">${escapeHtml(ownerName(memberById, s.user_id))}${isMine ? ' <span class="league-acc-you-badge">You</span>' : ''}</span>
      </div>`;
  };

  const notRacingCard = (s) => {
    const horse = state.horsesById.get(s.horse_id);
    return `
      <div class="inplay-card na-card">
        <div class="inplay-avatar na">${horse?.emoji || '🐎'}</div>
        <div>
          <div class="inplay-horse-name">${escapeHtml(horse?.name || 'Horse')}</div>
          <div class="inplay-horse-meta">${escapeHtml(horse?.trainer || '')}</div>
        </div>
      </div>`;
  };

  container.innerHTML = `
    <div class="inplay-hero">
      <div class="inplay-hero-dot"></div>
      <div class="inplay-hero-info">
        <div class="inplay-hero-label">${escapeHtml(league.name)}</div>
        <div class="inplay-hero-title">League Acceptances</div>
        <div class="inplay-hero-sub">${racingRows.length} horses accepted across the league this week</div>
      </div>
      <div class="inplay-hero-score">
        <div class="inplay-hero-pts">${fmtMoney(totalScore)}</div>
        <div class="inplay-hero-pts-label">your season total</div>
      </div>
    </div>

    <div class="inplay-section-header"><span>🏇 Your Acceptances</span><span class="inplay-section-count">${mine.length}</span></div>
    <div class="league-acc-table">
      ${mine.length ? tableHeader : ''}
      ${mine.map(row).join('') || '<div class="league-acc-empty">None of your horses are accepted this week</div>'}
    </div>

    <div class="inplay-section-header"><span>🏆 Other Managers' Acceptances</span><span class="inplay-section-count">${others.length}</span></div>
    <div class="league-acc-table">
      ${others.length ? tableHeader : ''}
      ${others.map(row).join('') || '<div class="league-acc-empty">No other horses accepted this week</div>'}
    </div>

    <div class="inplay-section-header"><span>💤 Your Horses Not Racing</span><span class="inplay-section-count">${notRacing.length}</span></div>
    <div class="inplay-grid">${notRacing.map(notRacingCard).join('') || '<div class="league-acc-empty">All your horses are racing this week</div>'}</div>
  `;
}

function byDateThenVenue(a, b) {
  return (a.acc.race_date || '').localeCompare(b.acc.race_date || '') || (a.acc.venue || '').localeCompare(b.acc.venue || '');
}

function ownerName(memberById, userId) {
  const m = memberById.get(userId);
  return m?.profiles?.display_name || m?.profiles?.username || 'Manager';
}

function fmtAccDate(d) {
  if (!d) return '—';
  const dt = new Date(d + 'T00:00:00');
  return isNaN(dt) ? d : dt.toLocaleDateString('en-AU', { weekday: 'short', day: 'numeric', month: 'short' });
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
