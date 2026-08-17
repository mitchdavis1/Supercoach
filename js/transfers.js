import { supabase } from './supabaseClient.js';
import { state, getActiveLeague } from './state.js';

let transferOutId = null;
let transferInId = null;
let leagueOwnedHorseIds = new Set();
let currentWeek = null;
let nextWeek = null;
let transferLog = [];

export async function loadTransferContext() {
  const league = getActiveLeague();
  if (!league) return;

  const [{ data: weeks }, { data: owned }, { data: log }] = await Promise.all([
    supabase.from('season_weeks').select('*').order('week_number'),
    supabase.from('stables').select('horse_id, user_id').eq('league_id', league.id),
    supabase
      .from('transfers')
      .select('*, profiles(username, display_name)')
      .eq('league_id', league.id)
      .order('transferred_at', { ascending: false })
      .limit(30),
  ]);

  // A week is "current" only while its trading window is actually open
  // (Monday 10am -> Friday 7pm) — there's a real closed period between
  // windows now, not just whichever deadline happens to be soonest.
  const nowMs = Date.now();
  const allWeeks = weeks || [];
  currentWeek = allWeeks.find((w) => new Date(w.opens_at).getTime() <= nowMs && nowMs < new Date(w.closes_at).getTime()) || null;
  nextWeek = currentWeek ? null : allWeeks.find((w) => new Date(w.opens_at).getTime() > nowMs) || null;

  leagueOwnedHorseIds = new Set((owned || []).filter((s) => s.user_id !== state.session.user.id).map((s) => s.horse_id));
  transferLog = log || [];
}

export function selectTransferOut(horseId) {
  transferOutId = transferOutId === horseId ? null : horseId;
  transferInId = null;
  renderTransferPage();
}

export function selectTransferIn(horseId) {
  transferInId = transferInId === horseId ? null : horseId;
  renderTransferPage();
}

export function filterReplacements() {
  renderInPanel();
}

export async function confirmTransfer() {
  const league = getActiveLeague();
  if (!league || !transferOutId || !transferInId) return;
  const { error } = await supabase.rpc('execute_transfer', {
    p_league_id: league.id,
    p_horse_out_id: transferOutId,
    p_horse_in_id: transferInId,
  });
  if (error) {
    alert(error.message);
    return;
  }
  transferOutId = null;
  transferInId = null;
  const { loadStable, renderMyStablePage } = await import('./stable.js');
  await loadStable(league.id);
  renderMyStablePage();
  await loadTransferContext();
  renderTransferPage();
}

function fmtMelb(iso) {
  return new Date(iso).toLocaleString('en-AU', { timeZone: 'Australia/Melbourne', weekday: 'short', hour: 'numeric', minute: '2-digit', day: 'numeric', month: 'short' });
}

export function renderTransferPage() {
  const league = getActiveLeague();
  const weekPill = document.getElementById('currentWeekPill');
  const deadlineDisplay = document.getElementById('currentDeadlineDisplay');
  const statusDot = document.getElementById('weekStatusDot');
  const statusText = document.getElementById('weekStatusText');
  const allowanceDisplay = document.getElementById('transferAllowanceDisplay');

  if (!league) {
    document.getElementById('transferCurrentStable').innerHTML = '<div class="transfer-empty">Join a league to make transfers.</div>';
    document.getElementById('transferInPanel').innerHTML = '';
    return;
  }

  const stableComplete = state.stable.length >= 10;
  const usedThisWeek = transferLog.some((t) => currentWeek && t.week_number === currentWeek.week_number && t.user_id === state.session.user.id);
  const canTransfer = stableComplete && !!currentWeek && !usedThisWeek;

  if (weekPill) weekPill.textContent = currentWeek ? currentWeek.label : nextWeek ? nextWeek.label : 'Season closed';
  if (deadlineDisplay) {
    deadlineDisplay.textContent = currentWeek
      ? `Closes ${fmtMelb(currentWeek.closes_at)}`
      : nextWeek
      ? `Opens ${fmtMelb(nextWeek.opens_at)}`
      : '—';
  }
  if (statusDot) statusDot.classList.toggle('closed', !canTransfer);
  if (statusText) {
    statusText.textContent = !currentWeek ? (nextWeek ? 'Window closed' : 'Season closed') : usedThisWeek ? 'Transfer used' : !stableComplete ? 'Stable incomplete' : 'Open';
    statusText.classList.toggle('closed', !canTransfer);
  }
  if (allowanceDisplay) allowanceDisplay.textContent = canTransfer ? '1' : '0';

  renderCurrentStable(canTransfer);
  renderInPanel();
  renderConfirmStrip();
  renderTransferLog();
}

function renderCurrentStable(canTransfer) {
  const container = document.getElementById('transferCurrentStable');
  if (!container) return;
  container.innerHTML = state.stable.map((s) => {
    const horse = state.horsesById.get(s.horse_id);
    const isOut = transferOutId === s.horse_id;
    const locked = !canTransfer;
    return `
      <div class="stable-player-row ${isOut ? 'selecting-out' : ''} ${locked ? 'locked' : ''}" onclick="${locked ? '' : `selectTransferOut('${s.horse_id}')`}">
        <div class="spr-avatar horse">${horse?.emoji || '🐎'}</div>
        <div class="spr-info">
          <div class="spr-name">${escapeHtml(horse?.name || 'Horse')}</div>
          <div class="spr-meta">${s.paid_price != null ? `$${s.paid_price} paid` : 'Free transfer'}</div>
        </div>
        ${isOut ? '<span class="out-badge">OUT</span>' : ''}
      </div>`;
  }).join('') || '<div class="transfer-empty">No horses yet</div>';
}

function renderInPanel() {
  const panel = document.getElementById('transferInPanel');
  if (!panel) return;

  if (!transferOutId) {
    panel.innerHTML = `<div class="transfer-empty"><div class="transfer-empty-icon">👆</div>Select a horse to transfer out first</div>`;
    return;
  }

  const search = (document.getElementById('replacementSearch')?.value || '').toLowerCase();
  const currentIds = new Set(state.stable.map((s) => s.horse_id));
  const pool = state.horses
    .filter((h) => h.status === 'active' && !currentIds.has(h.id) && !leagueOwnedHorseIds.has(h.id))
    .filter((h) => h.name.toLowerCase().includes(search))
    .sort((a, b) => a.name.localeCompare(b.name))
    .slice(0, 200);

  panel.innerHTML = `
    <input class="replacement-search" id="replacementSearch" placeholder="Search horses…" oninput="filterReplacements()" value="${search}" />
    <div class="replacement-list">
      ${pool.map((h) => `
        <div class="replacement-row ${transferInId === h.id ? 'selecting-in' : ''}" onclick="selectTransferIn('${h.id}')">
          <div class="spr-avatar horse">${h.emoji || '🐎'}</div>
          <div class="spr-info"><div class="spr-name">${escapeHtml(h.name)}</div><div class="spr-meta">${escapeHtml(h.trainer || '')}</div></div>
          ${transferInId === h.id ? '<span class="in-badge">IN</span>' : ''}
        </div>`).join('') || '<div class="transfer-empty">No horses match</div>'}
    </div>`;
}

function renderConfirmStrip() {
  const strip = document.getElementById('transferConfirmStrip');
  if (!strip) return;
  if (!transferOutId || !transferInId) {
    strip.style.display = 'none';
    return;
  }
  strip.style.display = 'flex';
  const outHorse = state.horsesById.get(transferOutId);
  const inHorse = state.horsesById.get(transferInId);
  document.getElementById('confirmChipOut').textContent = outHorse?.name || '';
  document.getElementById('confirmChipIn').textContent = inHorse?.name || '';
  document.getElementById('confirmBudgetNote').textContent = 'No $ value on transfers — the cap only applied during the draft';
}

function renderTransferLog() {
  const list = document.getElementById('transferLogList');
  if (!list) return;
  if (!transferLog.length) {
    list.innerHTML = `<div class="transfer-empty" style="padding:20px"><div class="transfer-empty-icon">📋</div>No transfers made yet this season</div>`;
    return;
  }
  list.innerHTML = transferLog.map((t) => `
    <div class="log-row">
      <span class="log-week">Week ${t.week_number}</span>
      <span>${escapeHtml(t.profiles?.display_name || t.profiles?.username)}</span>
      <span class="log-out">${escapeHtml(state.horsesById.get(t.horse_out_id)?.name || '')}</span>
      <span class="log-arrow">→</span>
      <span class="log-in">${escapeHtml(state.horsesById.get(t.horse_in_id)?.name || '')}</span>
      <span class="log-date">${new Date(t.transferred_at).toLocaleDateString()}</span>
    </div>`).join('');
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
