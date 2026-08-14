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

export async function resetImportedData() {
  if (!confirm('Clear every horse, acceptance, and prizemoney total added via import? This cannot be undone.')) return;
  const { error } = await supabase.rpc('reset_imported_data');
  if (error) {
    alert(error.message);
    return;
  }
  await refreshAfterImport();
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
}

function fmtImportDate(v) {
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (!v) return null;
  const parsed = new Date(v);
  return isNaN(parsed) ? null : parsed.toISOString().slice(0, 10);
}
