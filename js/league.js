import { supabase } from './supabaseClient.js';
import { state, getActiveLeague } from './state.js';

let onLeaguesChanged = () => {};
let membersChannel = null;

export function onLeagueUpdate(callback) {
  onLeaguesChanged = callback;
}

export async function loadMyLeagues() {
  const { data, error } = await supabase
    .from('league_members')
    .select('league_id, team_name, leagues(*)')
    .eq('user_id', state.session.user.id);

  if (error) {
    console.error('Could not load leagues', error);
    return;
  }

  state.leagues = (data || [])
    .filter((row) => row.leagues)
    .map((row) => ({ ...row.leagues, team_name: row.team_name }));

  if (!state.activeLeagueId || !state.leagues.some((l) => l.id === state.activeLeagueId)) {
    const saved = localStorage.getItem('ss_active_league_id');
    state.activeLeagueId = state.leagues.some((l) => l.id === saved) ? saved : (state.leagues[0]?.id || null);
  }

  if (state.activeLeagueId) {
    localStorage.setItem('ss_active_league_id', state.activeLeagueId);
    await loadLeagueMembers(state.activeLeagueId);
    subscribeToMembership(state.activeLeagueId);
  }

  onLeaguesChanged();
}

export async function loadLeagueMembers(leagueId) {
  const { data, error } = await supabase
    .from('league_members')
    .select('user_id, team_name, joined_at, profiles(username, display_name)')
    .eq('league_id', leagueId)
    .order('joined_at', { ascending: true });

  if (error) {
    console.error('Could not load league members', error);
    return;
  }
  state.members = data || [];
}

function subscribeToMembership(leagueId) {
  if (membersChannel) supabase.removeChannel(membersChannel);
  membersChannel = supabase
    .channel(`league-members-${leagueId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'league_members', filter: `league_id=eq.${leagueId}` }, async () => {
      await loadLeagueMembers(leagueId);
      onLeaguesChanged();
    })
    .subscribe();
}

export function setActiveLeague(leagueId) {
  state.activeLeagueId = leagueId;
  localStorage.setItem('ss_active_league_id', leagueId);
  loadLeagueMembers(leagueId).then(onLeaguesChanged);
  subscribeToMembership(leagueId);
}

export async function createLeague() {
  const nameInput = document.getElementById('createLeagueName');
  const name = nameInput ? nameInput.value.trim() : '';
  if (!name) {
    alert('Give your league a name.');
    return;
  }
  const { data, error } = await supabase.rpc('create_league', { p_name: name, p_scheduled_draft_at: null });
  if (error) {
    alert(error.message);
    return;
  }
  await loadMyLeagues();
  setActiveLeague(data.id);
}

export async function joinLeagueByCode() {
  const codeInput = document.getElementById('joinLeagueCode');
  const teamInput = document.getElementById('joinLeagueTeamName');
  const code = codeInput ? codeInput.value.trim() : '';
  if (!code) {
    alert('Enter a league code.');
    return;
  }
  const { data, error } = await supabase.rpc('join_league', {
    p_code: code,
    p_team_name: teamInput ? teamInput.value.trim() || null : null,
  });
  if (error) {
    alert(error.message);
    return;
  }
  await loadMyLeagues();
  setActiveLeague(data.id);
}

export async function scheduleDraft() {
  const league = getActiveLeague();
  const input = document.getElementById('scheduleDraftInput');
  if (!league || !input || !input.value) return;
  const iso = new Date(input.value).toISOString();
  const { error } = await supabase.from('leagues').update({ scheduled_draft_at: iso }).eq('id', league.id);
  if (error) {
    alert(error.message);
    return;
  }
  await loadMyLeagues();
}

export async function leaveLeague(leagueId) {
  if (!confirm('Leave this league?')) return;
  const { error } = await supabase
    .from('league_members')
    .delete()
    .eq('league_id', leagueId)
    .eq('user_id', state.session.user.id);
  if (error) {
    alert(error.message);
    return;
  }
  if (state.activeLeagueId === leagueId) {
    state.activeLeagueId = null;
    localStorage.removeItem('ss_active_league_id');
  }
  await loadMyLeagues();
}

export function fmtLeagueDateTime(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('en-AU', {
    timeZone: 'Australia/Melbourne',
    day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit',
  });
}

export function renderLeaguePage() {
  const container = document.getElementById('leagueContainer');
  if (!container) return;

  if (!state.leagues.length) {
    container.innerHTML = `
      <div class="league-card">
        <div class="league-card-header">🔗 Join or Create a League</div>
        <label class="join-label">League Code</label>
        <input class="join-input" id="joinLeagueCode" placeholder="e.g. 7F3KQ2" style="text-transform:uppercase;" />
        <label class="join-label">Your Team Name (optional)</label>
        <input class="join-input" id="joinLeagueTeamName" placeholder="e.g. The Flemington Faithful" />
        <button class="join-btn" onclick="joinLeagueByCode()">Join League</button>
        <div class="join-divider"><div class="join-divider-line"></div><div class="join-divider-text">or</div><div class="join-divider-line"></div></div>
        <label class="join-label">New League Name</label>
        <input class="join-input" id="createLeagueName" placeholder="e.g. The Spring Carnival Syndicate" />
        <button class="join-btn" onclick="createLeague()">Create League</button>
      </div>`;
    return;
  }

  const league = getActiveLeague();
  if (!league) {
    container.innerHTML = '<div class="league-empty-state">Pick a league to view it.</div>';
    return;
  }

  const isManager = league.manager_user_id === state.session.user.id;
  const leagueSwitcher = state.leagues.length > 1
    ? `<select class="schedule-input" onchange="setActiveLeague(this.value)" style="margin-bottom:12px;">
        ${state.leagues.map((l) => `<option value="${l.id}" ${l.id === league.id ? 'selected' : ''}>${escapeHtml(l.name)}</option>`).join('')}
      </select>`
    : '';

  const membersHtml = state.members.map((m) => `
    <div class="league-member-row">
      <div class="league-member-avatar">👤</div>
      <div class="league-member-name">${escapeHtml(m.profiles?.display_name || m.profiles?.username || 'Member')}${m.user_id === league.manager_user_id ? '<span class="league-manager-badge">Manager</span>' : ''}</div>
    </div>`).join('');

  const scheduleHtml = isManager
    ? `<div class="schedule-row">
        <input class="schedule-input" type="datetime-local" id="scheduleDraftInput" />
        <button class="draft-start-btn" onclick="scheduleDraft()">Set Draft Time</button>
      </div>`
    : '';

  container.innerHTML = `
    ${leagueSwitcher}
    <div class="league-hero">
      <div class="league-hero-name">${escapeHtml(league.name)}</div>
      <div class="league-hero-code-row">
        <span class="league-code-chip">${league.code}</span>
        <span class="league-hero-sub">Share this code so friends can join</span>
      </div>
      <div class="schedule-status ${league.scheduled_draft_at ? 'set' : ''}" style="margin-top:12px;">
        ${league.scheduled_draft_at ? 'Draft scheduled: ' + fmtLeagueDateTime(league.scheduled_draft_at) : 'No draft time scheduled yet'}
      </div>
      ${scheduleHtml}
    </div>
    <div class="league-card">
      <div class="league-card-header">👥 Members (${state.members.length})</div>
      ${membersHtml}
    </div>
    <span class="league-leave-link" onclick="leaveLeague('${league.id}')">Leave this league</span>
  `;
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}
