import { supabase } from './supabaseClient.js';
import { state, getActiveLeague, fmtMoney } from './state.js';

const SLOTS_TOTAL = 10;
const NOM_SECONDS = 30;
const BID_SECONDS = 20;

let draftChannel = null;
let clockInterval = null;
let selfHealing = false;
let onDraftChanged = () => {};

export function onDraftUpdate(callback) {
  onDraftChanged = callback;
}

export async function loadHorses() {
  // Supabase caps a single request at its configured max rows (1000 by
  // default) — with ~9,000 horses that silently truncated the pool to
  // roughly the first two letters of the alphabet. Page through it all.
  const pageSize = 1000;
  const all = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase.from('horses').select('*').order('name').range(from, from + pageSize - 1);
    if (error) {
      console.error('Could not load horses', error);
      break;
    }
    all.push(...data);
    if (data.length < pageSize) break;
  }
  state.horses = all;
  state.horsesById = new Map(state.horses.map((h) => [h.id, h]));
}

export async function loadDraftState(leagueId) {
  const { data, error } = await supabase.from('league_draft_state').select('*').eq('league_id', leagueId).single();
  if (error) {
    console.error('Could not load draft state', error);
    return;
  }
  state.draftState = data;
}

export async function loadDraftPicks(leagueId) {
  const { data, error } = await supabase
    .from('league_draft_picks')
    .select('*, profiles(username, display_name)')
    .eq('league_id', leagueId)
    .order('picked_at', { ascending: false });
  if (error) {
    console.error('Could not load draft picks', error);
    return;
  }
  state.draftPicks = data || [];
}

export function subscribeToDraft(leagueId) {
  if (draftChannel) supabase.removeChannel(draftChannel);
  draftChannel = supabase
    .channel(`draft-${leagueId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'league_draft_state', filter: `league_id=eq.${leagueId}` }, refreshDraft)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'league_draft_picks', filter: `league_id=eq.${leagueId}` }, refreshDraft)
    .subscribe();

  startClock(leagueId);
}

async function refreshDraft() {
  const league = getActiveLeague();
  if (!league) return;
  await Promise.all([loadDraftState(league.id), loadDraftPicks(league.id)]);
  onDraftChanged();
}

function startClock(leagueId) {
  if (clockInterval) clearInterval(clockInterval);
  clockInterval = setInterval(async () => {
    const s = state.draftState;
    if (!s) return;
    const deadline = s.status === 'nominating' ? s.nomination_deadline : s.status === 'bidding' ? s.bid_deadline : null;
    updateClockUI(s, deadline);
    if (deadline && new Date(deadline).getTime() <= Date.now() && !selfHealing) {
      selfHealing = true;
      try {
        await supabase.rpc('advance_draft', { p_league_id: leagueId });
      } finally {
        selfHealing = false;
      }
    }
  }, 1000);
}

function updateClockUI(draftState, deadline) {
  const ring = document.getElementById('draftClockRing');
  const val = document.getElementById('draftClockVal');
  if (!ring || !val) return;
  const total = draftState.status === 'nominating' ? NOM_SECONDS : BID_SECONDS;
  const secondsLeft = deadline ? Math.max(0, Math.ceil((new Date(deadline).getTime() - Date.now()) / 1000)) : 0;
  const pct = Math.max(0, Math.min(100, (secondsLeft / total) * 100));
  ring.style.setProperty('--pct', pct + '%');
  ring.classList.toggle('urgent', secondsLeft <= 5);
  val.textContent = secondsLeft + 's';
}

function myPicks(leagueId, userId) {
  return state.draftPicks.filter((p) => p.league_id === leagueId && p.user_id === userId);
}

function budgetFor(userId) {
  const spent = state.draftPicks.filter((p) => p.user_id === userId).reduce((sum, p) => sum + p.price_paid, 0);
  return 100 - spent;
}

function maxBidFor(userId) {
  const picksCount = state.draftPicks.filter((p) => p.user_id === userId).length;
  const reserve = Math.max(0, SLOTS_TOTAL - picksCount - 1) * 1;
  return Math.max(0, budgetFor(userId) - reserve);
}

export async function startDraft() {
  const league = getActiveLeague();
  if (!league) return;
  const { error } = await supabase.rpc('start_draft', { p_league_id: league.id });
  if (error) {
    alert(error.message);
    return;
  }
  await refreshDraft();
}

export async function nominateHorse(horseId) {
  const league = getActiveLeague();
  if (!league) return;
  const { error } = await supabase.rpc('nominate_horse', { p_league_id: league.id, p_horse_id: horseId });
  if (error) alert(error.message);
}

export async function placeYourBid(amount) {
  const league = getActiveLeague();
  if (!league) return;
  const { error } = await supabase.rpc('place_bid', { p_league_id: league.id, p_bid_amount: amount ?? null });
  if (error) alert(error.message);
}

export function placeCustomBid() {
  const input = document.getElementById('customBidInput');
  if (!input || !input.value) return;
  placeYourBid(parseInt(input.value, 10));
}

export function filterNominationList() {
  renderNominationList();
}

function availableHorses() {
  const pickedIds = new Set(state.draftPicks.map((p) => p.horse_id));
  return state.horses.filter((h) => h.status === 'active' && !pickedIds.has(h.id));
}

export function renderDraftPage() {
  const league = getActiveLeague();
  const container = document.getElementById('draftBody');
  const startBtn = document.getElementById('draftStartBtn');
  if (!container) return;

  if (!league) {
    container.innerHTML = '<div class="draft-lot-empty">Join or create a league first — head to the Join A League tab.</div>';
    if (startBtn) startBtn.style.display = 'none';
    return;
  }

  const s = state.draftState;
  if (!s) {
    container.innerHTML = '<div class="draft-lot-empty">Loading draft…</div>';
    return;
  }

  updateHeroStats();

  if (s.status === 'idle') {
    if (startBtn) startBtn.style.display = 'inline-block';
    container.innerHTML = draftIdleHTML(league);
    return;
  }

  if (startBtn) startBtn.style.display = 'none';

  if (s.status === 'complete') {
    container.innerHTML = draftCompleteBannerHTML() + draftSummaryHTML();
    return;
  }

  container.innerHTML = draftLayoutHTML(league, s);
  if (s.status === 'nominating' && s.current_nominator_user_id === state.session.user.id) {
    renderNominationList();
  }
}

function updateHeroStats() {
  if (!state.session) return;
  const budgetEl = document.getElementById('draftYourBudget');
  const slotsEl = document.getElementById('draftYourSlots');
  const picks = myPicks(state.activeLeagueId, state.session.user.id);
  if (budgetEl) budgetEl.textContent = '$' + budgetFor(state.session.user.id);
  if (slotsEl) slotsEl.textContent = `${picks.length}/${SLOTS_TOTAL}`;
}

function draftIdleHTML(league) {
  const isManager = league.manager_user_id === state.session.user.id;
  let gate = '';
  if (!league.scheduled_draft_at && !isManager) {
    gate = `<div class="draft-lot-empty">Your league manager hasn't scheduled the draft yet.</div>`;
  } else if (league.scheduled_draft_at && new Date(league.scheduled_draft_at) > new Date() && !isManager) {
    gate = `<div class="draft-lot-empty">The draft is scheduled for ${new Date(league.scheduled_draft_at).toLocaleString()} — it hasn't started yet.</div>`;
  } else {
    gate = `<div class="draft-lot-empty">Everything's ready — click <strong>Start Draft</strong> above when your league is ready to go.</div>`;
  }
  return `<div class="draft-lot-card">${gate}</div>`;
}

function draftLayoutHTML(league, s) {
  return `
    <div class="draft-layout">
      <div>
        ${draftLotCardHTML(league, s)}
      </div>
      <div>
        ${draftBoardHTML(league)}
        ${draftLogHTML()}
      </div>
    </div>`;
}

function draftSummaryHTML() {
  const byUser = new Map();
  state.draftPicks.forEach((p) => {
    if (!byUser.has(p.user_id)) byUser.set(p.user_id, []);
    byUser.get(p.user_id).push(p);
  });

  const teams = state.members.map((m) => {
    const picks = (byUser.get(m.user_id) || []).slice().sort((a, b) => b.price_paid - a.price_paid);
    const spent = picks.reduce((sum, p) => sum + p.price_paid, 0);
    return { m, picks, spent };
  });

  const teamCard = ({ m, picks, spent }) => `
    <div class="draft-summary-team">
      <div class="draft-summary-team-header">
        <span>${escapeHtml(m.profiles?.display_name || m.profiles?.username)}</span>
        <span class="draft-summary-team-spent">$${spent} / $100</span>
      </div>
      <div class="draft-summary-team-body">
        ${picks.map((p) => `
          <div class="draft-summary-row">
            <strong>${escapeHtml(state.horsesById.get(p.horse_id)?.name || '')}</strong>
            <span class="draft-summary-price">$${p.price_paid}</span>
          </div>`).join('') || '<div class="draft-summary-empty">No horses</div>'}
      </div>
    </div>`;

  return `
    <div class="draft-summary">
      <div class="draft-summary-header">🏁 Draft Summary — ${state.draftPicks.length} horses drafted</div>
      <div class="draft-summary-grid">${teams.map(teamCard).join('')}</div>
    </div>`;
}

function draftLotCardHTML(league, s) {
  const myTurn = s.current_nominator_user_id === state.session.user.id;

  if (s.status === 'nominating') {
    if (myTurn) {
      return `
        <div class="draft-lot-card">
          <div class="draft-lot-top">
            <div class="draft-clock-ring urgent" id="draftClockRing"><span id="draftClockVal">${NOM_SECONDS}s</span></div>
            <div class="draft-lot-info">
              <div class="draft-lot-name">Your turn to nominate</div>
              <div class="draft-lot-meta">Pick a horse below to open it for bidding at $1</div>
            </div>
          </div>
          <div class="draft-nominate-panel">
            <input class="draft-nominate-search" placeholder="Search horses…" oninput="filterNominationList()" id="nominateSearch" />
            <div class="draft-nominate-list" id="nominateList"></div>
          </div>
        </div>`;
    }
    return `
      <div class="draft-lot-card">
        <div class="draft-waiting">
          <div class="draft-waiting-dot"></div>
          Waiting on ${memberName(s.current_nominator_user_id)} to nominate a horse…
          <span id="draftClockVal" style="margin-left:auto;font-weight:800;color:#E8007D;"></span>
        </div>
        <div id="draftClockRing" style="display:none;"></div>
      </div>`;
  }

  if (s.status === 'bidding') {
    const horse = state.horsesById.get(s.current_lot_horse_id);
    const iAmLeading = s.current_bidder_user_id === state.session.user.id;
    const nextAmt = (s.current_bid || 0) + 1;
    return `
      <div class="draft-lot-card">
        <div class="draft-lot-top">
          <div class="draft-clock-ring" id="draftClockRing"><span id="draftClockVal">${BID_SECONDS}s</span></div>
          <div class="draft-lot-avatar">${horse?.emoji || '🐎'}</div>
          <div class="draft-lot-info">
            <div class="draft-lot-name">${escapeHtml(horse?.name || 'Horse')}</div>
            <div class="draft-lot-meta">${escapeHtml(horse?.trainer || '')}</div>
          </div>
        </div>
        <div class="draft-bid-row">
          <div>
            <div class="draft-current-bid-val">$${s.current_bid}</div>
            <div class="draft-current-bid-by">Bid by <strong>${memberName(s.current_bidder_user_id)}</strong></div>
          </div>
          <div class="draft-bid-actions">
            <button class="draft-bid-chip primary" ${iAmLeading ? 'disabled' : ''} onclick="placeYourBid()">Bid $${nextAmt}</button>
            <input class="draft-custom-bid" type="number" id="customBidInput" placeholder="Custom $" min="${nextAmt}" />
            <button class="draft-bid-chip" ${iAmLeading ? 'disabled' : ''} onclick="placeCustomBid()">Place</button>
          </div>
        </div>
        <div class="draft-max-bid-hint">Your max bid: $${maxBidFor(state.session.user.id)}</div>
        ${iAmLeading ? `<div class="draft-you-winning">✅ You're the highest bidder</div>` : `<div class="draft-you-outbid">You need to bid to stay in this lot</div>`}
        ${draftFuturesHTML(s.current_lot_horse_id)}
      </div>`;
  }

  return `<div class="draft-lot-card"><div class="draft-lot-empty">—</div></div>`;
}

function renderNominationList() {
  const list = document.getElementById('nominateList');
  if (!list) return;
  const search = (document.getElementById('nominateSearch')?.value || '').toLowerCase();
  const pool = availableHorses();

  if (!search) {
    const starred = pool.filter((h) => h.is_starred);
    list.innerHTML = starred.map(nominationRowHTML).join('') ||
      `<div class="draft-waiting">No horses are starred yet — search above, or ask your admin to star some in Data Import so they show up here by default.</div>`;
    return;
  }

  const horses = pool.filter((h) => h.name.toLowerCase().includes(search)).slice(0, 200);
  list.innerHTML = horses.map(nominationRowHTML).join('') || '<div class="draft-waiting">No horses match your search</div>';
}

function nominationRowHTML(h) {
  return `
    <div class="draft-nom-row" onclick="nominateHorse('${h.id}')">
      <div class="spr-avatar horse">${h.emoji || '🐎'}</div>
      <div class="spr-info">
        <div class="spr-name">${escapeHtml(h.name)}</div>
        <div class="spr-meta">${escapeHtml(h.trainer || '')}</div>
      </div>
    </div>`;
}

function draftBoardHTML(league) {
  const rows = state.members.map((m) => {
    const picks = state.draftPicks.filter((p) => p.user_id === m.user_id);
    const isYou = m.user_id === state.session.user.id;
    const onClock = state.draftState?.current_nominator_user_id === m.user_id && state.draftState?.status === 'nominating';
    return `
      <div class="draft-team-card ${isYou ? 'you' : ''} ${onClock ? 'on-clock' : ''}">
        <div class="draft-team-avatar spr-avatar horse">👤</div>
        <div class="draft-team-info">
          <div class="draft-team-name">${escapeHtml(m.profiles?.display_name || m.profiles?.username)}${onClock ? '<span class="draft-onclock-badge">On the clock</span>' : ''}</div>
          <div class="draft-team-sub">${picks.length}/${SLOTS_TOTAL} horses</div>
        </div>
        <div class="draft-team-right">
          <div class="draft-team-budget">$${budgetFor(m.user_id)}</div>
          <div class="draft-team-slots">cap left</div>
        </div>
      </div>`;
  }).join('');

  return `
    <div class="draft-board">
      <div class="draft-board-header"><span>👥 Draft Board</span></div>
      <div class="draft-board-body">${rows}</div>
    </div>`;
}

function draftLogHTML() {
  const rows = state.draftPicks.slice(0, 30).map((p) => `
    <div class="draft-log-row">
      <span>${escapeHtml(p.profiles?.display_name || p.profiles?.username)}</span>
      <span>won</span>
      <strong>${escapeHtml(state.horsesById.get(p.horse_id)?.name || '')}</strong>
      <span class="draft-log-price">$${p.price_paid}</span>
    </div>`).join('');
  return `
    <div class="draft-log">
      <div class="draft-log-header">📜 Draft Log</div>
      <div class="draft-log-body">${rows || '<div class="draft-log-row">No horses drafted yet</div>'}</div>
    </div>`;
}

function draftCompleteBannerHTML() {
  return `
    <div class="draft-complete-banner">
      <div style="font-family:'Anton',Impact,sans-serif;font-size:22px;">🏁 Draft Complete!</div>
      <div>Your stable is set — head to My Stable to check it out.</div>
      <button class="draft-import-btn" onclick="showPage('myteam')">View My Stable</button>
    </div>`;
}

function draftFuturesHTML(horseId) {
  const markets = state.futuresByHorse.get(horseId);
  if (!markets?.length) return '';
  return `
    <div class="draft-futures">
      <div class="draft-futures-label">🔮 Futures Markets</div>
      <div class="draft-futures-list">
        ${markets.map((m) => `<div class="draft-futures-chip">${escapeHtml(m.race_name)}<strong>${m.odds != null ? '$' + m.odds : '—'}</strong></div>`).join('')}
      </div>
    </div>`;
}

function memberName(userId) {
  if (!userId) return '—';
  if (userId === state.session?.user?.id) return 'You';
  const m = state.members.find((x) => x.user_id === userId);
  return m ? (m.profiles?.display_name || m.profiles?.username) : 'A manager';
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
