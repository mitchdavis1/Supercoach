import { supabase } from './supabaseClient.js';
import { state, getActiveLeague } from './state.js';

let transferOutId = null;
let choiceIds = [null, null, null];
let leagueOwnedHorseIds = new Set();
let seasonWeeks = [];
let currentWeek = null;
let nextWeek = null;
let transferLog = [];
let waiverOrder = [];
let myRequest = null; // this user's request for the currently-open week, if any
let lastOutcome = null; // this user's most recently processed (fulfilled/rejected) request
let pollInterval = null;

export async function loadTransferContext(syncSelection = true) {
  const league = getActiveLeague();
  if (!league || !state.session) return;

  await supabase.rpc('check_league_waivers', { p_league_id: league.id }).catch(() => {});

  const [{ data: weeks }, { data: owned }, { data: log }, { data: order }, { data: myRequests }] = await Promise.all([
    supabase.from('season_weeks').select('*').order('week_number'),
    supabase.from('stables').select('horse_id, user_id').eq('league_id', league.id),
    supabase.from('transfers').select('*, profiles(username, display_name)').eq('league_id', league.id).order('transferred_at', { ascending: false }).limit(30),
    supabase.from('league_waiver_order').select('*, profiles(username, display_name)').eq('league_id', league.id).order('position'),
    supabase.from('waiver_requests').select('*').eq('league_id', league.id).eq('user_id', state.session.user.id).order('week_number', { ascending: false }).limit(2),
  ]);

  const nowMs = Date.now();
  seasonWeeks = weeks || [];
  currentWeek = seasonWeeks.find((w) => new Date(w.opens_at).getTime() <= nowMs && nowMs < new Date(w.closes_at).getTime()) || null;
  nextWeek = currentWeek ? null : seasonWeeks.find((w) => new Date(w.opens_at).getTime() > nowMs) || null;

  leagueOwnedHorseIds = new Set((owned || []).filter((s) => s.user_id !== state.session.user.id).map((s) => s.horse_id));
  transferLog = log || [];
  waiverOrder = order || [];

  myRequest = currentWeek ? (myRequests || []).find((r) => r.week_number === currentWeek.week_number) || null : null;
  lastOutcome = (myRequests || []).find((r) => r.status !== 'pending') || null;

  // Background polling refreshes read-only data (order/log/outcome) without
  // clobbering a selection the user is still mid-way through choosing —
  // only re-sync from the server on the initial page-enter load and right
  // after a submit, when there's nothing unsaved to lose.
  if (syncSelection) {
    if (myRequest) {
      transferOutId = myRequest.horse_out_id;
      choiceIds = [myRequest.choice_1_horse_id, myRequest.choice_2_horse_id, myRequest.choice_3_horse_id];
    } else {
      transferOutId = null;
      choiceIds = [null, null, null];
    }
  }

  const { loadStable } = await import('./stable.js');
  await loadStable(league.id);
}

export function startTransferPolling() {
  stopTransferPolling();
  pollInterval = setInterval(async () => {
    try {
      await loadTransferContext(false);
    } catch (e) {
      console.error('Could not refresh transfer context', e);
    }
    renderTransferPage();
  }, 30000);
}

export function stopTransferPolling() {
  if (pollInterval) clearInterval(pollInterval);
  pollInterval = null;
}

export function selectTransferOut(horseId) {
  if (transferOutId === horseId) {
    transferOutId = null;
  } else {
    transferOutId = horseId;
    choiceIds = [null, null, null];
  }
  renderTransferPage();
}

export function selectChoice(horseId) {
  const idx = choiceIds.indexOf(horseId);
  if (idx !== -1) {
    choiceIds.splice(idx, 1);
    choiceIds.push(null);
  } else {
    const emptyIdx = choiceIds.indexOf(null);
    if (emptyIdx === -1) return;
    choiceIds[emptyIdx] = horseId;
  }
  renderTransferPage();
}

export function filterReplacements() {
  renderInPanel(canEditNow());
}

export async function submitWaiverRequest() {
  const league = getActiveLeague();
  if (!league || !transferOutId || !choiceIds[0]) return;
  const { error } = await supabase.rpc('submit_waiver_request', {
    p_league_id: league.id,
    p_horse_out_id: transferOutId,
    p_choice_1: choiceIds[0],
    p_choice_2: choiceIds[1],
    p_choice_3: choiceIds[2],
  });
  if (error) {
    alert(error.message);
    return;
  }
  await loadTransferContext();
  renderTransferPage();
}

function canEditNow() {
  return state.stable.length >= 10 && !!currentWeek;
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
  const canEdit = canEditNow();

  if (weekPill) weekPill.textContent = currentWeek ? currentWeek.label : nextWeek ? nextWeek.label : 'Season closed';
  if (deadlineDisplay) {
    deadlineDisplay.textContent = currentWeek
      ? `Closes ${fmtMelb(currentWeek.closes_at)}`
      : nextWeek
      ? `Opens ${fmtMelb(nextWeek.opens_at)}`
      : '—';
  }
  if (statusDot) statusDot.classList.toggle('closed', !canEdit);
  if (statusText) {
    statusText.textContent = !currentWeek
      ? (nextWeek ? 'Window closed' : 'Season closed')
      : !stableComplete
      ? 'Stable incomplete'
      : myRequest
      ? 'Request submitted — editable until deadline'
      : 'Open';
    statusText.classList.toggle('closed', !canEdit);
  }
  if (allowanceDisplay) allowanceDisplay.textContent = canEdit ? '1' : '0';

  renderOutcomeBanner();
  renderWaiverOrder();
  renderCurrentStable(canEdit);
  renderPrioritySlots(canEdit);
  renderInPanel(canEdit);
  renderSubmitStrip();
  renderTransferLog();
}

function renderOutcomeBanner() {
  const el = document.getElementById('waiverOutcomeBanner');
  if (!el) return;
  if (!lastOutcome) {
    el.style.display = 'none';
    return;
  }
  const weekLabel = seasonWeeks.find((w) => w.week_number === lastOutcome.week_number)?.label || `Week ${lastOutcome.week_number}`;
  const outHorse = state.horsesById.get(lastOutcome.horse_out_id);
  el.style.display = 'flex';
  if (lastOutcome.status === 'fulfilled') {
    const inHorse = state.horsesById.get(lastOutcome.resulting_horse_in_id);
    el.className = 'waiver-outcome-banner won';
    el.innerHTML = `✅ ${escapeHtml(weekLabel)}: your waiver claim was successful — <strong>${escapeHtml(outHorse?.name || '')}</strong> → <strong>${escapeHtml(inHorse?.name || '')}</strong>`;
  } else {
    el.className = 'waiver-outcome-banner rejected';
    el.innerHTML = `❌ ${escapeHtml(weekLabel)}: none of your picks were available — no transfer was made`;
  }
}

function renderWaiverOrder() {
  const el = document.getElementById('waiverOrderList');
  const title = document.getElementById('waiverOrderTitle');
  if (title) {
    const label = currentWeek ? currentWeek.label : nextWeek ? nextWeek.label : null;
    title.textContent = label
      ? `Waiver Order for ${label} — rotates every week regardless of use`
      : 'Waiver Order — rotates every week regardless of use';
  }
  if (!el) return;
  if (!waiverOrder.length) {
    el.innerHTML = `<div class="transfer-empty" style="padding:16px">Waiver order is set once your league's draft is complete.</div>`;
    return;
  }
  const myId = state.session.user.id;
  el.innerHTML = waiverOrder.map((w) => `
    <div class="waiver-order-row ${w.user_id === myId ? 'you' : ''}">
      <span class="waiver-order-pos">${w.position}</span>
      <span class="waiver-order-name">${escapeHtml(w.profiles?.display_name || w.profiles?.username)}${w.user_id === myId ? ' <span class="league-acc-you-badge">You</span>' : ''}</span>
    </div>`).join('');
}

function renderCurrentStable(canEdit) {
  const container = document.getElementById('transferCurrentStable');
  if (!container) return;
  container.innerHTML = state.stable.map((s) => {
    const horse = state.horsesById.get(s.horse_id);
    const isOut = transferOutId === s.horse_id;
    const locked = !canEdit;
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

function renderPrioritySlots(canEdit) {
  const el = document.getElementById('waiverPrioritySlots');
  if (!el) return;
  if (!transferOutId) {
    el.innerHTML = '';
    return;
  }
  el.innerHTML = [0, 1, 2].map((i) => {
    const horseId = choiceIds[i];
    const horse = horseId ? state.horsesById.get(horseId) : null;
    return `
      <div class="waiver-slot ${horse ? 'filled' : ''}">
        <span class="waiver-slot-label">Priority ${i + 1}${i > 0 ? ' (backup)' : ''}</span>
        ${horse
          ? `<span class="waiver-slot-horse">${horse.emoji || '🐎'} ${escapeHtml(horse.name)}</span><button class="waiver-slot-clear" ${canEdit ? '' : 'disabled'} onclick="selectChoice('${horseId}')">✕</button>`
          : `<span class="waiver-slot-empty">—</span>`}
      </div>`;
  }).join('');
}

function renderInPanel(canEdit) {
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
    <input class="replacement-search" id="replacementSearch" placeholder="Search horses…" oninput="filterReplacements()" value="${escapeHtml(search)}" />
    <div class="replacement-list">
      ${pool.map((h) => {
        const slot = choiceIds.indexOf(h.id);
        const disabled = !canEdit || (slot === -1 && !choiceIds.includes(null));
        return `
        <div class="replacement-row ${slot !== -1 ? 'selecting-in' : ''} ${disabled ? 'cant' : ''}" onclick="${disabled ? '' : `selectChoice('${h.id}')`}">
          <div class="spr-avatar horse">${h.emoji || '🐎'}</div>
          <div class="spr-info"><div class="spr-name">${escapeHtml(h.name)}</div><div class="spr-meta">${escapeHtml(h.trainer || '')}</div></div>
          ${slot !== -1 ? `<span class="in-badge">P${slot + 1}</span>` : ''}
        </div>`;
      }).join('') || '<div class="transfer-empty">No horses match</div>'}
    </div>`;
}

function renderSubmitStrip() {
  const strip = document.getElementById('transferConfirmStrip');
  if (!strip) return;
  if (!transferOutId || !choiceIds[0]) {
    strip.style.display = 'none';
    return;
  }
  strip.style.display = 'flex';
  const outHorse = state.horsesById.get(transferOutId);
  document.getElementById('confirmChipOut').textContent = outHorse?.name || '';
  document.getElementById('confirmChipIn').textContent = choiceIds.filter(Boolean).map((id) => state.horsesById.get(id)?.name).filter(Boolean).join(' → ');
  document.getElementById('confirmBudgetNote').textContent = myRequest
    ? 'Editing your submitted request — changes apply until the deadline'
    : "Decided by waiver order if others want the same horse";
  const btn = document.getElementById('confirmTransferBtn');
  if (btn) btn.textContent = myRequest ? 'Update Waiver Request' : 'Submit Waiver Request';
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
