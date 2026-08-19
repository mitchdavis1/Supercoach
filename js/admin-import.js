import { supabase } from './supabaseClient.js';
import { state } from './state.js';

// Header/column detection ported verbatim from the prototype: scan the
// first 15 rows for one containing a cell matching /horse/i, then find each
// field's column by its own keyword regex — tolerant of real-world export
// formats without requiring exact column names.

function findHeaderRow(rows) {
  for (let i = 0; i < Math.min(rows.length, 15); i++) {
    const row = rows[i];
    if (row && row.some((c) => typeof c === 'string' && /horse/i.test(c))) return i;
  }
  return -1;
}

function colIndex(headerRow, pattern) {
  for (let i = 0; i < headerRow.length; i++) {
    if (typeof headerRow[i] === 'string' && pattern.test(headerRow[i])) return i;
  }
  return -1;
}

function readWorkbookFile(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const data = new Uint8Array(e.target.result);
        const wb = XLSX.read(data, { type: 'array', cellDates: true });
        const sheet = wb.Sheets[wb.SheetNames[0]];
        const rows = XLSX.utils.sheet_to_json(sheet, { header: 1, raw: true, defval: '' });
        resolve(rows);
      } catch (err) {
        reject(err.message || 'Could not read that file.');
      }
    };
    reader.onerror = () => reject('Could not read that file.');
    reader.readAsArrayBuffer(file);
  });
}

function renderResult(targetId, html, isError) {
  const el = document.getElementById(targetId);
  if (!el) return;
  el.innerHTML = `<div class="admin-result ${isError ? 'err' : 'ok'}">${html}</div>`;
}

export async function handleHorsePoolFile() {
  const input = document.getElementById('horsePoolFileInput');
  const file = input?.files?.[0];
  if (!file) return;

  try {
    const rows = await readWorkbookFile(file);
    const headerIdx = findHeaderRow(rows);
    if (headerIdx === -1) throw 'Could not find a header row containing a "horse" column.';
    const header = rows[headerIdx];
    const horseCol = colIndex(header, /horse/i);
    const trainerCol = colIndex(header, /trainer/i);
    const keyRacesCol = colIndex(header, /key.?race/i);
    const tagsCol = colIndex(header, /tag/i);
    const notesCol = colIndex(header, /note/i);

    const dataRows = rows.slice(headerIdx + 1).filter((r) => r && r[horseCol] !== '' && r[horseCol] != null);
    const payload = dataRows.map((r) => ({
      name: String(r[horseCol]).trim(),
      trainer: trainerCol > -1 ? String(r[trainerCol] || '').trim() : null,
      key_races: keyRacesCol > -1 ? String(r[keyRacesCol] || '').split(',').map((s) => s.trim()).filter(Boolean) : [],
      tags: tagsCol > -1 ? String(r[tagsCol] || '').split(',').map((s) => s.trim()).filter(Boolean) : [],
      notes: notesCol > -1 ? String(r[notesCol] || '').trim() : null,
    }));

    const { data, error } = await supabase.rpc('import_horse_pool', { p_rows: payload });
    if (error) throw error.message;

    renderResult('horsePoolImportResult', `<span class="admin-result-stat">${data.created} created</span><span class="admin-result-stat">${data.matched} matched</span> out of ${data.total} rows.`, false);
    await refreshAfterImport();
  } catch (err) {
    renderResult('horsePoolImportResult', String(err), true);
  }
}

export async function handleAcceptancesFile() {
  const input = document.getElementById('acceptancesFileInput');
  const file = input?.files?.[0];
  if (!file) return;

  try {
    const rows = await readWorkbookFile(file);
    const headerIdx = findHeaderRow(rows);
    if (headerIdx === -1) throw 'Could not find a header row containing a "horse" column.';
    const header = rows[headerIdx];
    const horseCol = colIndex(header, /horse/i);
    const venueCol = colIndex(header, /venue/i);
    const raceCol = colIndex(header, /race/i);
    const dateCol = colIndex(header, /date/i);

    const dataRows = rows.slice(headerIdx + 1).filter((r) => r && r[horseCol] !== '' && r[horseCol] != null);
    const payload = dataRows.map((r) => ({
      name: String(r[horseCol]).trim(),
      venue: venueCol > -1 ? String(r[venueCol] || '').trim() : null,
      race_number: raceCol > -1 ? String(r[raceCol] || '').replace(/[^0-9]/g, '') : null,
      race_date: dateCol > -1 ? fmtImportDate(r[dateCol]) : null,
    }));

    const { data, error } = await supabase.rpc('import_acceptances', { p_rows: payload });
    if (error) throw error.message;

    renderResult('acceptancesImportResult', `<span class="admin-result-stat">${data.rows_imported} runners set for this week</span> (replaces the previous list).`, false);
    await refreshAfterImport();
  } catch (err) {
    renderResult('acceptancesImportResult', String(err), true);
  }
}

export async function handleResultsFile() {
  const input = document.getElementById('resultsFileInput');
  const file = input?.files?.[0];
  if (!file) return;

  try {
    const rows = await readWorkbookFile(file);
    const headerIdx = findHeaderRow(rows);
    if (headerIdx === -1) throw 'Could not find a header row containing a "horse" column.';
    const header = rows[headerIdx];
    const horseCol = colIndex(header, /horse/i);
    const prizeCol = colIndex(header, /prize/i);
    if (prizeCol === -1) throw "Could not find a prizemoney column — name it something containing 'prize'.";

    const dataRows = rows.slice(headerIdx + 1).filter((r) => r && r[horseCol] !== '' && r[horseCol] != null);
    const payload = dataRows.map((r) => ({
      name: String(r[horseCol]).trim(),
      total_prizemoney: String(r[prizeCol] ?? ''),
    }));

    const { data, error } = await supabase.rpc('import_prizemoney', { p_rows: payload });
    if (error) throw error.message;

    renderResult('resultsImportResult', `<span class="admin-result-stat">${data.rows_imported} horses updated</span> — this REPLACES each horse's cumulative total, it does not add to it.`, false);
    await refreshAfterImport();
  } catch (err) {
    renderResult('resultsImportResult', String(err), true);
  }
}

export async function handleStarredHorsesFile() {
  const input = document.getElementById('starredHorsesFileInput');
  const file = input?.files?.[0];
  if (!file) return;

  try {
    const rows = await readWorkbookFile(file);
    const headerIdx = findHeaderRow(rows);
    if (headerIdx === -1) throw 'Could not find a header row containing a "horse" column.';
    const header = rows[headerIdx];
    const horseCol = colIndex(header, /horse/i);

    const dataRows = rows.slice(headerIdx + 1).filter((r) => r && r[horseCol] !== '' && r[horseCol] != null);
    const payload = dataRows.map((r) => ({ name: String(r[horseCol]).trim() }));

    const { data, error } = await supabase.rpc('import_starred_horses', { p_rows: payload });
    if (error) throw error.message;

    const unmatchedHtml = data.unmatched.length
      ? `<div class="admin-new-list">${data.unmatched.length} name(s) didn't match a horse already in your pool (check for typos): ${data.unmatched.map(escapeHtml).join(', ')}</div>`
      : '';
    renderResult(
      'starredImportResult',
      `<span class="admin-result-stat">${data.newly_starred} newly starred</span><span class="admin-result-stat">${data.already_starred} already starred</span><span class="admin-result-stat">${data.unmatched.length} unmatched</span> out of ${data.total} names.${unmatchedHtml}`,
      false
    );

    const { loadHorses } = await import('./draft.js');
    await loadHorses();
    renderStarredCount();
    renderHorseCurationList();
  } catch (err) {
    renderResult('starredImportResult', String(err), true);
  }
}

export async function resetImportedData() {
  if (!confirm('Clear every horse, acceptance, and prizemoney total added via import? This cannot be undone.')) return;
  const { error } = await supabase.rpc('reset_imported_data');
  if (error) {
    alert(error.message);
    return;
  }
  await refreshAfterImport();
}

export async function resetLeagueDraft() {
  const input = document.getElementById('resetLeagueCodeInput');
  const code = input?.value?.trim();
  if (!code) return;
  if (!confirm(`Reset the draft for league "${code.toUpperCase()}"? This deletes all drafted horses, stables, and transfers for that league so it can be re-drafted. This cannot be undone.`)) return;

  const { error } = await supabase.rpc('reset_league_draft', { p_league_code: code });
  if (error) {
    renderResult('resetLeagueResult', error.message, true);
    return;
  }
  renderResult('resetLeagueResult', `League "${code.toUpperCase()}" draft has been reset — ready to start again.`, false);
}

async function refreshAfterImport() {
  const { loadHorses } = await import('./draft.js');
  await loadHorses();
  await renderAdminStats();
}

export async function renderAdminStats() {
  const horsesEl = document.getElementById('adminStatHorses');
  const racingEl = document.getElementById('adminStatRacing');
  const earningEl = document.getElementById('adminStatEarning');
  if (!horsesEl) return;

  const [{ count: horseCount }, { count: raceCount }, { count: earnCount }] = await Promise.all([
    supabase.from('horses').select('*', { count: 'exact', head: true }),
    supabase.from('acceptances').select('*', { count: 'exact', head: true }),
    supabase.from('prizemoney').select('*', { count: 'exact', head: true }).gt('total_prizemoney', 0),
  ]);

  horsesEl.textContent = horseCount ?? 0;
  racingEl.textContent = raceCount ?? 0;
  earningEl.textContent = earnCount ?? 0;

  renderStarredCount();
  renderHorseCurationList();
  await renderAccountsList();
}

async function renderAccountsList() {
  const list = document.getElementById('accountsList');
  if (!list) return;

  const { data, error } = await supabase.rpc('admin_list_accounts');
  if (error) {
    list.innerHTML = `<div class="draft-waiting">${escapeHtml(error.message)}</div>`;
    return;
  }

  list.innerHTML = (data || []).map((u) => `
    <div class="admin-horse-row">
      <span class="admin-horse-name">${escapeHtml(u.username)}${u.is_admin ? ' <span style="color:#E8007D;">(admin)</span>' : ''}</span>
      <span class="admin-horse-trainer">${escapeHtml(u.email)}</span>
      <span style="font-size:9px;font-weight:800;text-transform:uppercase;color:${u.email_confirmed_at ? '#2a9a50' : '#cc3344'};white-space:nowrap;">${u.email_confirmed_at ? 'Confirmed' : 'Unconfirmed'}</span>
      ${!u.email_confirmed_at ? `<button class="admin-star-btn" style="font-size:10px;" onclick="forceConfirmEmail('${u.id}')" title="Force confirm email — unblocks sign-in with their existing password">✅ Confirm</button>` : ''}
      <button class="admin-star-btn" style="font-size:10px;" onclick="sendPasswordReset('${escapeHtml(u.email)}')" title="Send password reset email">✉️ Reset</button>
    </div>`).join('') || '<div class="draft-waiting">No accounts yet</div>';
}

export async function forceConfirmEmail(userId) {
  if (!confirm("Force-confirm this account's email? They'll be able to sign in immediately with their existing password.")) return;
  const { error } = await supabase.rpc('admin_confirm_email', { p_user_id: userId });
  if (error) {
    alert(error.message);
    return;
  }
  await renderAccountsList();
}

export async function sendPasswordReset(email) {
  if (!confirm(`Send a password reset email to ${email}?`)) return;
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin + window.location.pathname,
  });
  if (error) {
    alert(error.message);
    return;
  }
  alert('Password reset email sent.');
}

function renderStarredCount() {
  const el = document.getElementById('adminStarredCount');
  if (!el) return;
  el.textContent = state.horses.filter((h) => h.is_starred).length;
}

export function filterHorseCurationList() {
  renderHorseCurationList();
}

function renderHorseCurationList() {
  const list = document.getElementById('horseCurationList');
  if (!list) return;
  const search = (document.getElementById('horseCurationSearch')?.value || '').toLowerCase();
  const pool = search
    ? state.horses.filter((h) => h.name.toLowerCase().includes(search)).slice(0, 300)
    : state.horses.filter((h) => h.is_starred);

  list.innerHTML = pool.map((h) => `
    <div class="admin-horse-row">
      <span class="admin-horse-name">${escapeHtml(h.name)}</span>
      <span class="admin-horse-trainer">${escapeHtml(h.trainer || '')}</span>
      <button class="admin-star-btn ${h.is_starred ? 'starred' : ''}" onclick="toggleHorseStar('${h.id}')">${h.is_starred ? '★' : '☆'}</button>
    </div>`).join('') || (search
      ? '<div class="draft-waiting">No horses match your search</div>'
      : '<div class="draft-waiting">No starred horses yet — search above and star a few dozen to build the draft room\'s default list.</div>');
}

export async function toggleHorseStar(horseId) {
  const horse = state.horses.find((h) => h.id === horseId);
  if (!horse) return;
  const next = !horse.is_starred;

  const { error } = await supabase.from('horses').update({ is_starred: next }).eq('id', horseId);
  if (error) {
    alert(error.message);
    return;
  }

  horse.is_starred = next;
  renderStarredCount();
  renderHorseCurationList();
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s ?? '';
  return div.innerHTML;
}

function fmtImportDate(v) {
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (!v) return null;
  const parsed = new Date(v);
  return isNaN(parsed) ? null : parsed.toISOString().slice(0, 10);
}
