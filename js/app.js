import { state } from './state.js';
import { initAuth, handleSignIn, handleJoin, logout, switchAuthTab, handleForgotPassword, handleSetNewPassword } from './auth.js';
import { loadMyLeagues, onLeagueUpdate, createLeague, joinLeagueByCode, scheduleDraft, leaveLeague, setActiveLeague, renderLeaguePage } from './league.js';
import { loadHorses, loadDraftState, loadDraftPicks, subscribeToDraft, onDraftUpdate, startDraft, nominateHorse, placeYourBid, placeCustomBid, filterNominationList, renderDraftPage } from './draft.js';
import { loadStable, renderMyStablePage } from './stable.js';
import { selectTransferOut, selectChoice, filterReplacements, submitWaiverRequest, loadTransferContext, renderTransferPage, startTransferPolling, stopTransferPolling } from './transfers.js';
import { loadPrizemoney, renderLeaderboard, setLbRound } from './scoring.js';
import { renderInPlay } from './inplay.js';
import { handleHorsePoolFile, handleAcceptancesFile, handleResultsFile, handleStarredHorsesFile, resetImportedData, resetLeagueDraft, renderAdminStats, filterHorseCurationList, toggleHorseStar, forceConfirmEmail, sendPasswordReset } from './admin-import.js';

const PAGES = ['myteam', 'draft', 'transfer', 'leaderboard', 'rules', 'joinleague', 'inplay', 'dataimport'];
let activePage = 'draft';

window.switchAuthTab = switchAuthTab;
window.handleSignIn = handleSignIn;
window.handleJoin = handleJoin;
window.handleForgotPassword = handleForgotPassword;
window.handleSetNewPassword = handleSetNewPassword;
window.logout = logout;
window.showPage = showPage;
window.createLeague = createLeague;
window.joinLeagueByCode = joinLeagueByCode;
window.scheduleDraft = scheduleDraft;
window.leaveLeague = leaveLeague;
window.setActiveLeague = switchActiveLeague;
window.startDraft = startDraft;
window.nominateHorse = nominateHorse;
window.placeYourBid = placeYourBid;
window.placeCustomBid = placeCustomBid;
window.filterNominationList = filterNominationList;
window.selectTransferOut = selectTransferOut;
window.selectChoice = selectChoice;
window.filterReplacements = filterReplacements;
window.submitWaiverRequest = submitWaiverRequest;
window.setLbRound = setLbRound;
window.handleHorsePoolFile = handleHorsePoolFile;
window.handleAcceptancesFile = handleAcceptancesFile;
window.handleResultsFile = handleResultsFile;
window.handleStarredHorsesFile = handleStarredHorsesFile;
window.resetImportedData = resetImportedData;
window.resetLeagueDraft = resetLeagueDraft;
window.filterHorseCurationList = filterHorseCurationList;
window.forceConfirmEmail = forceConfirmEmail;
window.sendPasswordReset = sendPasswordReset;
window.toggleHorseStar = toggleHorseStar;

function showPage(page) {
  activePage = page;
  PAGES.forEach((p) => {
    document.getElementById('page-' + p)?.classList.remove('active');
    document.getElementById('nav-' + p)?.classList.remove('active');
  });
  document.getElementById('page-' + page)?.classList.add('active');
  document.getElementById('nav-' + page)?.classList.add('active');
  if (page === 'transfer') startTransferPolling(); else stopTransferPolling();
  renderActivePage();
}

async function switchActiveLeague(leagueId) {
  setActiveLeague(leagueId);
  await Promise.all([
    loadDraftState(leagueId),
    loadDraftPicks(leagueId),
    loadStable(leagueId),
  ]);
  subscribeToDraft(leagueId);
  renderLeaguePage();
  await renderActivePage();
}

async function renderActivePage() {
  if (activePage === 'leaderboard') await renderLeaderboard();
  if (activePage === 'transfer') { await loadTransferContext(); renderTransferPage(); }
  if (activePage === 'inplay') await renderInPlay();
  if (activePage === 'draft') renderDraftPage();
  if (activePage === 'dataimport') await renderAdminStats();
  if (activePage === 'joinleague') renderLeaguePage();
  if (activePage === 'myteam') renderMyStablePage();
}

async function onSignedIn() {
  document.getElementById('authGate').style.display = 'none';
  document.getElementById('appShell').style.display = 'block';
  document.getElementById('userBadgeName').textContent = state.profile?.display_name || state.profile?.username || '';

  const adminNav = document.getElementById('nav-dataimport');
  if (adminNav) adminNav.style.display = state.profile?.is_admin ? '' : 'none';

  await loadHorses();
  await loadPrizemoney();
  await loadMyLeagues();

  if (state.activeLeagueId) {
    await Promise.all([
      loadDraftState(state.activeLeagueId),
      loadDraftPicks(state.activeLeagueId),
      loadStable(state.activeLeagueId),
    ]);
    subscribeToDraft(state.activeLeagueId);
  }

  showPage('draft');
}

function onSignedOut() {
  document.getElementById('authGate').style.display = 'flex';
  document.getElementById('appShell').style.display = 'none';
}

onLeagueUpdate(() => {
  if (activePage === 'draft' || activePage === 'joinleague') renderActivePage();
});

onDraftUpdate(() => {
  if (activePage === 'draft') renderDraftPage();
});

initAuth((session) => {
  if (session) {
    onSignedIn();
  } else {
    onSignedOut();
  }
});
