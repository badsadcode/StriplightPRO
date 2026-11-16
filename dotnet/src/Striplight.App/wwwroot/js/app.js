// Striplight PRO — page controller. Wires the app bar, tool rail, inspector panels,
// strip view and frame preview to the .NET host through the bridge. The host owns the
// project; this page keeps a copy of the frame list for drawing and sends every edit back.

import { call, on, inHost } from './bridge.js';
import { StripView, hasTone } from './stripView.js';
import { initNotes, setNotes, flushNotes } from './notes.js';
import { hydrateIcons } from './icons.js';
import { initSegmented, initRanges, paintRange } from './ui.js';
import { Scrubber } from './scrubber.js';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

hydrateIcons();
initSegmented($('#ovr-rotation'));
initSegmented($('#proc-rotation'));
initRanges();

// Report script errors to the host (shown in the smoke test, harmless otherwise).
window.addEventListener('error', (e) => {
  if (inHost) call('app.log', { message: `${e.message} @ ${e.filename}:${e.lineno}` }).catch(() => {});
});

// ------------------------------------------------------------------ state

const state = {
  session: null,        // SessionDto from the host
  settings: null,       // AppSettings
  imageVersion: 1,
  detecting: false,
  exporting: false,
  exportPaused: false,
  smoke: false,
};

const view = new StripView($('#strip-canvas'), {
  onSelectionChanged: () => { refreshFramesPanel(); scrubber.invalidate(); },
  onPageChanged: () => { refreshPager(); scrubber.invalidate(); },
  onHover: (t) => { $('#status-hover').textContent = t; },
  onFramesEdited: (indices) => patchFrames(indices),
  onFrameCreated: (frame) => addFrame(frame),
  onOpenFrame: (idx) => openFrameModal(idx),
  onContextMenu: (x, y) => showContextMenu(x, y),
  onDismissMenus: () => hideContextMenu(),
  onZoomRequest: (z) => setZoom(z),
});
const scrubber = new Scrubber($('#scrubber'), view);

// ------------------------------------------------------------------ helpers

function toast(message, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  $('#toast-host').append(el);
  setTimeout(() => el.remove(), kind === 'error' ? 9000 : 4500);
}

function status(text) { $('#status-main').textContent = text; }

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  view.refreshTheme();
  scrubber.invalidate();
  document.querySelector('#notes-editor .toastui-editor-defaultUI')?.classList.toggle('toastui-editor-dark', theme !== 'light');
}

function setBusy() {
  document.querySelector('.statusbar').classList.toggle('busy', state.detecting || state.exporting);
}

/** Runs a host command and shows failures as an error toast. */
async function run(cmd, args) {
  try {
    return await call(cmd, args);
  } catch (err) {
    toast(err.message, 'error');
    throw err;
  }
}

function debounce(fn, ms) {
  let t = 0;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

function setBar(id, done, total) {
  $(id).style.width = `${total > 0 ? Math.min(100, (done / total) * 100) : 0}%`;
}

const hasRoll = () => !!state.session;
const selection = () => [...view.selected].sort((a, b) => a - b);
const frameKey = (f) => `${f.leadEdge}:${f.trailEdge}:${f.leftEdge}:${f.rightEdge}`;
const fileName = (p) => (p || '').split(/[\\/]/).pop();

function setDirty(d) {
  if (state.session) state.session.dirty = d;
  $('#dirty-dot').hidden = !d;
}

function refreshEnabled() {
  const roll = hasRoll(), sel = view.selected.size > 0;
  $$('[data-needs-roll]').forEach((el) => { el.disabled = !roll; });
  $$('[data-needs-sel]').forEach((el) => { el.disabled = !roll || !sel; });
  $('#det-run').disabled = !roll || state.detecting;
  $('#det-cancel').disabled = !state.detecting;
  $('#exp-start').disabled = !roll || state.exporting;
  $('#exp-pause').disabled = !state.exporting;
  $('#exp-stop').disabled = !state.exporting;
  setBusy();
}

// ------------------------------------------------------------------ session

function applySession(s) {
  state.session = s;
  state.imageVersion = s.imageVersion;
  view.imageVersion = s.imageVersion;
  view.setRoll(s.roll, s.frames);
  $('#empty-state').hidden = true;
  $('#viewbar').hidden = false;
  $('#viewer-foot').hidden = false;
  $('.roll-name').textContent = s.roll.rollName || 'Untitled roll';
  $('.roll-name').title = s.projectPath || s.idfPath || '';
  $('#roll-meta').hidden = false;
  refreshRollMeta();
  setDirty(s.dirty);

  // Detect defaults from the roll
  $('#det-threshold').value = s.roll.detectionThreshold;
  $('#det-minw').value = s.roll.detectMinWidth;
  $('#det-minl').value = s.roll.detectMinLength;
  $('#det-from').value = 1;
  $('#det-from').max = $('#det-to').max = s.roll.stripCount;
  $('#det-to').value = s.roll.stripCount;

  loadProcess(s.process);
  loadExport(s.export, s.defaultOutputRoot);
  setNotes(s.notes);
  refreshFramesPanel();
  refreshPager();
  refreshEnabled();
  scrubber.invalidate();
  status(`Opened ${fileName(s.projectPath || s.idfPath)}`);
  $('#strip-canvas').focus();
}

function refreshRollMeta() {
  if (!state.session) return;
  const r = state.session.roll;
  $('#roll-meta').textContent = `${r.stripCount.toLocaleString()} strips · ${view.frames.length.toLocaleString()} frames`;
}

async function openProject(path = '') {
  const s = await run('project.open', { path });
  if (s) applySession(s);
}

async function openDemo() {
  status('Preparing the demo roll…');
  const s = await run('project.demo');
  if (s) {
    applySession(s);
    toast('Demo roll opened. Try Detect, Adjust and Export, or drag frames around.', 'ok');
  }
}

async function save(as = false) {
  if (!hasRoll()) return;
  await flushNotes();
  await flushExportSettings();
  const r = await run(as ? 'project.saveAs' : 'project.save');
  if (!r) return;
  if (!r.dirty) {
    setDirty(false);
    state.session.projectPath = r.path;
    $('.roll-name').title = r.path;
    toast(`Saved ${fileName(r.path)}`, 'ok');
  }
}

function renderRecent() {
  const list = $('#recent-list');
  list.replaceChildren();
  const items = state.settings?.recentProjects || [];
  $('#recent-wrap').hidden = items.length === 0;
  for (const p of items) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    const name = document.createElement('span');
    name.className = 'r-name';
    name.textContent = fileName(p);
    const path = document.createElement('span');
    path.className = 'r-path';
    path.textContent = p;
    b.title = p;
    b.append(name, path);
    b.addEventListener('click', () => openProject(p));
    li.append(b);
    list.append(li);
  }
}

// ------------------------------------------------------------------ frames

/** Replaces the page's frame list and keeps the selection on the same frames. */
function applyFrames(frames, keepKeys) {
  const keys = new Set(keepKeys ?? selection().map((i) => frameKey(view.frames[i])));
  state.session.frames = frames;
  const keep = [];
  frames.forEach((f, i) => { if (keys.has(frameKey(f))) keep.push(i); });
  view.setFrames(frames, keep);
  refreshFramesPanel();
  refreshRollMeta();
  scrubber.invalidate();
}

async function patchFrames(indices) {
  const keys = selection().map((i) => frameKey(view.frames[i]));
  const changes = indices.map((i) => ({ index: i, frame: view.frames[i] }));
  try {
    applyFrames(await call('frames.patch', { changes }), keys);
  } catch (err) {
    toast(err.message, 'error');
  }
}

async function addFrame(frame) {
  const r = await run('frames.add', { frame });
  applyFrames(r.frames, []);
  view.select(r.index);
}

async function frameCommand(cmd, extra = {}) {
  const r = await run(cmd, { indices: selection(), ...extra });
  applyFrames(r);
}

/** Merge / combine / split: the host returns the frames to keep selected. */
async function frameTool(cmd, extra = {}) {
  const r = await run(cmd, { indices: selection(), ...extra });
  applyFrames(r.frames, []);
  view.setFrames(r.frames, r.select);
  refreshFramesPanel();
}

async function undo() {
  const r = await call('frames.undo').catch((e) => { toast(e.message); return null; });
  if (!r) return;
  applyFrames(r.frames, []);
  status(`Undone · ${r.remaining} more step${r.remaining === 1 ? '' : 's'} available`);
}

/** F / G: jump to the next / previous folder marker (wraps around, like Lazarus). */
function jumpMarker(forward) {
  const frames = view.frames, n = frames.length;
  if (!n) return;
  const sel = selection();
  let from = sel.length === 1 ? sel[0] : -1;
  if (from < 0) {
    // start from the current page
    const first = view.firstStrip * state.session.roll.lengthLines;
    from = frames.findIndex((f) => f.leadEdge >= first);
    from = from < 0 ? n - 1 : forward ? from - 1 : from;
  }
  for (let k = 1; k <= n; k++) {
    const i = (((forward ? from + k : from - k) % n) + n) % n;
    if (frames[i].isMarker) { view.select(i); view.revealFrame(i); return; }
  }
  toast('No folder markers on this roll.');
}

async function deleteSelected(askConfirm = true) {
  const n = view.selected.size;
  if (!n) return;
  if (askConfirm && n > 20 && !confirm(`Delete ${n} frames?`)) return;
  const r = await run('frames.delete', { indices: selection() });
  applyFrames(r, []);
  status(`Deleted ${n} frame${n === 1 ? '' : 's'}`);
}

function nextAbnormal() {
  const frames = view.frames;
  if (!frames.length) return;
  const start = selection().at(-1) ?? -1;
  for (let k = 1; k <= frames.length; k++) {
    const i = (start + k) % frames.length;
    if (frames[i].isOversized || frames[i].isUndersized) {
      view.select(i);
      view.revealFrame(i);
      return;
    }
  }
  toast('No odd-size frames on this roll.');
}

function refreshFramesPanel() {
  const frames = view.frames;
  $('#stat-frames').textContent = frames.length.toLocaleString();
  $('#stat-markers').textContent = frames.filter((f) => f.isMarker).length.toLocaleString();
  $('#stat-abnormal').textContent = frames.filter((f) => f.isOversized || f.isUndersized).length.toLocaleString();
  $('#stat-selected').textContent = view.selected.size.toLocaleString();
  refreshEnabled();

  const sel = selection();
  const card = $('#frame-info');
  if (sel.length !== 1) { card.hidden = true; return; }
  const i = sel[0], f = frames[i], ll = state.session.roll.lengthLines;
  const rows = [
    ['Lead → trail', `${f.leadEdge.toLocaleString()} → ${f.trailEdge.toLocaleString()}`],
    ['Strips', `${Math.floor(f.leadEdge / ll) + 1} – ${Math.floor(f.trailEdge / ll) + 1}`],
    ['Left → right', `${f.leftEdge} → ${f.rightEdge}`],
    ['Size', `${f.trailEdge - f.leadEdge} × ${f.rightEdge - f.leftEdge} px`],
  ];
  if (f.hasOverride) rows.push(['Orientation', `${f.rotation}°${f.flipH ? ' · mirrored' : ''}${f.negative ? ' · negative' : ''}`]);
  if (hasTone(f)) rows.push(['Tone', 'own values (from file)']);
  card.replaceChildren();
  const title = document.createElement('div');
  title.className = 'fc-title';
  title.textContent = `Frame ${i + 1} of ${frames.length}`;
  if (f.isMarker) {
    const chip = document.createElement('span');
    chip.className = 'chip chip-warn';
    chip.textContent = 'Folder start';
    title.append(chip);
  }
  card.append(title);
  for (const [k, v] of rows) {
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.textContent = v;
    card.append(dt, dd);
  }
  card.hidden = false;
  updateExportExample();
}

// ------------------------------------------------------------------ pager & view

function refreshPager() {
  const pages = view.pageCount;
  // Auto mode and the fit-to-width limit change these behind the user's back: show the real values.
  if (document.activeElement !== $('#strips-per-row')) $('#strips-per-row').value = view.stripsPerRow;
  $('#zoom-out').textContent = `${Math.round(view.effectiveZoom * 100)}%`;
  $('#page-input').value = pages ? view.page + 1 : 1;
  $('#page-input').max = Math.max(1, pages);
  $('#page-count').textContent = `/ ${pages}`;
}

const sendView = debounce(async () => {
  const r = await call('view.set', {
    stripsPerRow: view.stripsPerRow, zoom: view.zoom,
    rotateCw: $('#rotate-cw').checked, frameFillOpacity: view.fillOpacity, autoStrips: view.autoStrips,
    showStripNumbers: view.showStripNumbers,
  }).catch((e) => toast(e.message, 'error'));
  if (r) { state.imageVersion = r.imageVersion; view.setImageVersion(r.imageVersion); }
}, 200);

function setZoom(z) {
  z = Math.max(0.25, Math.min(4, z));
  $('#zoom').value = Math.round(z * 100);
  paintRange($('#zoom'));
  $('#zoom-out').textContent = `${Math.round(z * 100)}%`;
  view.setView({ zoom: z });
  sendView();
}

$('#zoom').addEventListener('input', (e) => setZoom(e.target.value / 100));
$('#strips-per-row').addEventListener('change', (e) => {
  $('#auto-strips').checked = false;
  view.setView({ stripsPerRow: Number(e.target.value) || 4, autoStrips: false });
  sendView();
});
$('#strip-numbers').addEventListener('change', (e) => {
  view.setView({ showStripNumbers: e.target.checked });
  sendView();
});
$('#auto-strips').addEventListener('change', (e) => {
  view.setView({ autoStrips: e.target.checked });
  sendView();
});
$('#rotate-cw').addEventListener('change', () => {
  view.setView({ rotateCw: $('#rotate-cw').checked }); // frame boxes flip with the image
  sendView();
});
$('#page-input').addEventListener('change', (e) => view.gotoPage((Number(e.target.value) || 1) - 1));

// ------------------------------------------------------------------ adjust panel

const QUANTUM = { contrast: [-128, 255, 64], brightness: [-128, 127, 0], gamma: [-255, 255, 0] };
const STRIPLIGHT = { contrast: [-100, 100, 0], brightness: [-100, 100, 0], gamma: [10, 300, 100] };
const isQuantum = (m) => m === 1 || m === 4;
const isAdaptive = (m) => m >= 5 && m <= 8;

const slider = (key) => $(`.slider[data-key="${key}"]`);
const sliderInputs = (el) => [el.querySelector('input[type=range]'), el.querySelector('input[type=number]')];

function setSlider(key, value, range) {
  const [r, n] = sliderInputs(slider(key));
  if (range) for (const i of [r, n]) { i.min = range[0]; i.max = range[1]; }
  r.value = n.value = value;
  paintRange(r);
}

function getSlider(key) { return Number(sliderInputs(slider(key))[1].value) || 0; }

function applyRanges(method, resetValues) {
  const ranges = isQuantum(method) ? QUANTUM : STRIPLIGHT;
  for (const k of ['contrast', 'brightness', 'gamma']) {
    setSlider(k, resetValues ? ranges[k][2] : getSlider(k), ranges[k]);
  }
  slider('strength').hidden = !isAdaptive(method);
  $('#tone-hint').textContent = isAdaptive(method)
    ? 'Adaptive methods analyse each frame on export. The strips show a per-strip approximation, so use Preview (Enter) for the exact result. The sliders apply after the adaptive step.'
    : isQuantum(method) ? 'Quantum ranges: contrast 64 and gamma 0 are neutral.' : '';
}

function loadProcess(p) {
  $('#tone-method').value = p.method;
  applyRanges(p.method, false);
  setSlider('contrast', p.contrast);
  setSlider('brightness', p.brightness);
  setSlider('gamma', p.gamma);
  setSlider('strength', p.strength);
  setSlider('sharpness', p.sharpness);
  $('#sharp-mode').value = p.sharpnessMode;
  $$('#tone-flags input').forEach((c) => { c.checked = (p.flags & Number(c.value)) !== 0; });
  $('#proc-rotation').value = p.rotation;
  $('#proc-mirror').checked = p.mirror;
  $('#proc-negative').checked = p.negative;
  $('#tone-on-strips').checked = p.previewOnStrips;
}

function gatherProcess() {
  return {
    method: Number($('#tone-method').value),
    flags: $$('#tone-flags input').reduce((acc, c) => acc | (c.checked ? Number(c.value) : 0), 0),
    contrast: getSlider('contrast'),
    brightness: getSlider('brightness'),
    gamma: getSlider('gamma'),
    strength: getSlider('strength'),
    sharpness: getSlider('sharpness'),
    sharpnessMode: Number($('#sharp-mode').value),
    rotation: Number($('#proc-rotation').value),
    mirror: $('#proc-mirror').checked,
    negative: $('#proc-negative').checked,
    previewOnStrips: $('#tone-on-strips').checked,
  };
}

const sendProcess = debounce(async () => {
  if (!hasRoll()) return;
  const r = await call('process.set', gatherProcess()).catch((e) => toast(e.message, 'error'));
  if (r) { state.imageVersion = r.imageVersion; view.setImageVersion(r.imageVersion); }
}, 180);

let lastMethod = 0;
$('#tone-method').addEventListener('focus', (e) => { lastMethod = Number(e.target.value); });
$('#tone-method').addEventListener('change', (e) => {
  const m = Number(e.target.value);
  applyRanges(m, isQuantum(m) !== isQuantum(lastMethod)); // switching slider families resets to neutral
  lastMethod = m;
  sendProcess();
});
$$('.slider').forEach((el) => {
  const [r, n] = sliderInputs(el);
  r.addEventListener('input', () => { n.value = r.value; sendProcess(); });
  n.addEventListener('change', () => {
    n.value = Math.max(Number(n.min), Math.min(Number(n.max), Number(n.value) || 0));
    r.value = n.value;
    paintRange(r);
    sendProcess();
  });
});
$$('#tone-flags input, #sharp-mode, #proc-rotation, #proc-mirror, #proc-negative, #tone-on-strips')
  .forEach((el) => el.addEventListener('change', sendProcess));

// ------------------------------------------------------------------ detect panel

async function detect() {
  if (!hasRoll() || state.detecting) return;
  const stripCount = state.session.roll.stripCount;
  const args = {
    threshold: Number($('#det-threshold').value),
    minWidth: Number($('#det-minw').value),
    minLength: Number($('#det-minl').value),
    stripFrom: Math.max(0, (Number($('#det-from').value) || 1) - 1),
    stripTo: Math.min(stripCount - 1, (Number($('#det-to').value) || stripCount) - 1),
    // Insets are counted from stored column 0, which is the bottom of the screen in the
    // default CCW orientation and the top in CW mode. The fields are labelled as seen on screen.
    leftInset: Number($(view.rotateCw ? '#det-left' : '#det-right').value) || 0,
    rightInset: Number($(view.rotateCw ? '#det-right' : '#det-left').value) || 0,
    useToneSliders: $('#det-tone').checked,
  };
  state.detecting = true;
  refreshEnabled();
  setBar('#det-bar', 0, 1);
  $('#det-status').textContent = 'Starting…';
  try {
    const r = await call('detect.run', args);
    applyFrames(r.frames, []);
    const msg = r.found < 0 ? 'Detection cancelled' : `Found ${r.found.toLocaleString()} frames`;
    $('#det-status').textContent = msg;
    setBar('#det-bar', 1, 1);
    status(msg);
  } catch (err) {
    $('#det-status').textContent = err.message;
    toast(err.message, 'error');
  } finally {
    state.detecting = false;
    refreshEnabled();
  }
}

on('detect.progress', (p) => {
  setBar('#det-bar', p.currentStrip, p.totalStrips);
  $('#det-status').textContent =
    `Strip ${p.currentStrip.toLocaleString()} of ${p.totalStrips.toLocaleString()} · ${p.framesFound.toLocaleString()} frames` +
    (p.stripsMissing ? ` · ${p.stripsMissing} previews missing` : '');
});

// ------------------------------------------------------------------ export panel

function loadExport(e, defaultRoot) {
  $('#exp-root').value = e.outputRoot || '';
  $('#exp-root').placeholder = defaultRoot;
  $('#exp-mode').value = e.namingMode;
  $('#exp-prefix').value = e.prefix;
  $('#exp-digits').value = e.fileDigits;
  $('#exp-sep').checked = e.separateFolders;
  $('#exp-archive').value = e.archiveList.replace(/\r\n/g, '\n');
  $('#exp-quality').value = e.quality;
  $('#exp-workers').value = e.workers;
  $('#exp-cache').value = e.stripCacheLimit;
  $('#exp-progressive').checked = e.progressive;
  $('#exp-skip').checked = e.skipExisting;
  $('#exp-fallback').checked = e.allowPreviewFallback;
  $('#exp-temp').checked = e.localTempStage;
  refreshNamingMode();
  updateExportExample();
}

function gatherExport() {
  return {
    outputRoot: $('#exp-root').value.trim(),
    namingMode: Number($('#exp-mode').value),
    prefix: $('#exp-prefix').value,
    fileDigits: Number($('#exp-digits').value) || 5,
    separateFolders: $('#exp-sep').checked,
    archiveList: $('#exp-archive').value,
    quality: Number($('#exp-quality').value) || 100,
    workers: Number($('#exp-workers').value) || 4,
    stripCacheLimit: Number($('#exp-cache').value) || 8,
    progressive: $('#exp-progressive').checked,
    skipExisting: $('#exp-skip').checked,
    allowPreviewFallback: $('#exp-fallback').checked,
    localTempStage: $('#exp-temp').checked,
    scope: $('input[name=exp-scope]:checked').value,
    indices: selection(),
  };
}

function refreshNamingMode() {
  const archive = $('#exp-mode').value === '1';
  const d = Math.max(1, Math.min(12, Number($('#exp-digits').value) || 5));
  $('#exp-digits-example').textContent = `e.g. ${'1'.padStart(d, '0')}, ${'12'.padStart(d, '0')}`;
  $('#exp-archive-wrap').hidden = !archive;
  $('#exp-quantum').hidden = archive;
}

async function updateExportExample() {
  if (!hasRoll() || !view.frames.length) { $('#exp-example').textContent = ''; return; }
  const index = selection()[0] ?? 0;
  const r = await call('export.preview', { ...gatherExport(), index }).catch(() => null);
  const el = $('#exp-example');
  if (!r) return;
  // Archive method: one list row is needed per folder (marker). Show the count so a gap is seen before exporting.
  const archive = $('#exp-mode').value === '1';
  const short = archive && r.rows < r.folders;
  el.classList.toggle('error', !!r.error || short);
  const counts = archive ? `\n${r.folders} folder${r.folders === 1 ? '' : 's'} · ${r.rows} list row${r.rows === 1 ? '' : 's'}${short ? ' (rows missing)' : ''}` : '';
  el.textContent = (r.error ? r.error : `Frame ${index + 1} → ${r.path}`) + counts;
}

function flushExportSettings() {
  return hasRoll() ? call('export.settings', gatherExport()).catch(() => {}) : Promise.resolve();
}

const exportChanged = debounce(() => { flushExportSettings(); updateExportExample(); }, 400);
$$('[data-panel=export] input, [data-panel=export] select, [data-panel=export] textarea').forEach((el) => {
  el.addEventListener(el.tagName === 'TEXTAREA' || el.type === 'text' ? 'input' : 'change', () => {
    refreshNamingMode();
    exportChanged();
  });
});

async function exportStart() {
  if (!hasRoll() || state.exporting) return;
  const args = gatherExport();
  if (args.scope === 'selected' && !args.indices.length) { toast('Select frames to export first.', 'error'); return; }
  $('#exp-failures').replaceChildren();
  setBar('#exp-bar', 0, 1);
  try {
    const r = await call('export.start', args);
    state.exporting = true;
    state.exportPaused = false;
    $('#exp-pause span').textContent = 'Pause';
    $('#exp-status').textContent = `Exporting ${r.jobs.toLocaleString()} frames to ${r.outputRoot}`;
    view.frames.forEach((f) => { f.isExported = false; });
    view.invalidate();
    refreshEnabled();
  } catch (err) {
    $('#exp-status').textContent = err.message;
    toast(err.message, 'error');
  }
}

const exportCounts = { exported: 0, skipped: 0, failed: 0 };
on('export.progress', (p) => {
  if (p.done === 1) Object.assign(exportCounts, { exported: 0, skipped: 0, failed: 0 });
  exportCounts[p.outcome.toLowerCase()]++;
  setBar('#exp-bar', p.done, p.total);
  $('#exp-status').textContent =
    `${p.done.toLocaleString()} of ${p.total.toLocaleString()} · ${exportCounts.exported} exported · ` +
    `${exportCounts.skipped} skipped · ${exportCounts.failed} failed`;
  if (p.outcome === 'Exported' && view.frames[p.frameIdx]) {
    view.frames[p.frameIdx].isExported = true;
    view.invalidate();
    scrubber.invalidate();
  }
  if (p.outcome === 'Failed') addFailure(p.frameIdx, p.error);
});

on('export.done', (d) => {
  state.exporting = false;
  refreshEnabled();
  const msg = d.fatal ? `Export stopped: ${d.fatal}`
    : `${d.cancelled ? 'Export stopped' : 'Export finished'}: ${d.exported} exported, ${d.skipped} skipped, ` +
      `${d.failed} failed in ${d.seconds.toFixed(1)} s`;
  $('#exp-status').textContent = msg;
  toast(msg, d.failed || d.fatal ? 'error' : 'ok');
  status(msg);
});

function addFailure(frameIdx, error) {
  const li = document.createElement('li');
  li.textContent = `Frame ${frameIdx + 1}: ${error}`;
  li.title = 'Show this frame';
  li.addEventListener('click', () => { view.select(frameIdx); view.revealFrame(frameIdx); });
  $('#exp-failures').append(li);
}

// ------------------------------------------------------------------ preview window

/** Opens (or reuses) the separate preview window on a frame. */
function openFrameModal(idx) {
  if (!view.frames[idx]) return;
  view.select(idx);
  call('preview.open', { index: idx }).catch((e) => toast(e.message, 'error'));
}

on('preview.selected', (d) => {
  if (!view.frames[d.index]) return;
  view.select(d.index);
  view.revealFrame(d.index);
});

// The preview window changed frames (orientation, marker): fetch the list again.
on('frames.changed', async (d) => {
  if (d?.source !== 'preview' || !hasRoll()) return;
  const frames = await call('frames.list').catch(() => null);
  if (frames) applyFrames(frames);
});

// ------------------------------------------------------------------ context menu

function showContextMenu(x, y) {
  const m = $('#context-menu');
  m.hidden = false;
  const vw = $('#viewer').clientWidth, vh = $('#viewer').clientHeight;
  m.style.left = `${Math.min(x, vw - m.offsetWidth - 8)}px`;
  m.style.top = `${Math.min(y, vh - m.offsetHeight - 8)}px`;
}

function hideContextMenu() { $('#context-menu').hidden = true; }

$('#context-menu').addEventListener('click', (e) => {
  const b = e.target.closest('[data-ctx]');
  if (!b) return;
  hideContextMenu();
  ({
    preview: () => openFrameModal(selection()[0]),
    marker: () => frameCommand('frames.toggleMarker'),
    clearOverrides: () => frameCommand('frames.clearOverrides'),
    delete: deleteSelected,
  })[b.dataset.ctx]?.();
});
document.addEventListener('pointerdown', (e) => { if (!e.target.closest('#context-menu')) hideContextMenu(); });

// ------------------------------------------------------------------ tabs

function showTab(name) {
  $$('.rail [data-tab]').forEach((t) => t.setAttribute('aria-selected', String(t.dataset.tab === name)));
  $$('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== name; });
  if (name === 'notes') initNotes($('#notes-editor'));
  if (name === 'export') updateExportExample();
}
$$('.rail [data-tab]').forEach((tab) => tab.addEventListener('click', () => showTab(tab.dataset.tab)));

// ------------------------------------------------------------------ commands

const commands = {
  open: () => openProject(),
  demo: openDemo,
  save: () => save(false),
  saveAs: () => save(true),
  first: () => view.gotoPage(0),
  prev: () => view.gotoPage(view.page - 1),
  next: () => view.gotoPage(view.page + 1),
  last: () => view.gotoPage(view.pageCount - 1),
  zoomIn: () => setZoom(view.zoom * 1.15),
  zoomOut: () => setZoom(view.zoom / 1.15),
  selectAll: () => view.selectAll(),
  selectPage: () => view.selectPage(),
  selectNone: () => view.selectNone(),
  nextAbnormal,
  toggleMarker: () => frameCommand('frames.toggleMarker'),
  merge: () => frameTool('frames.merge'),
  combine: () => frameTool('frames.combine'),
  split: () => frameTool('frames.split', { parts: Number($('#split-parts').value) || 2 }),
  toggleSuggested: () => {
    const sel = selection();
    if (sel.length !== 1) { toast('Select exactly one frame to toggle its suggestion.'); return; }
    return frameCommand('frames.toggleSuggested', { index: sel[0] });
  },
  undo,
  theme: async () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    applyTheme(next);
    await call('app.setTheme', { theme: next }).catch(() => {});
  },
  previewFrame: () => { const i = selection()[0]; if (i !== undefined) openFrameModal(i); },
  deleteSelected,
  clearMarkers: async () => {
    if (!confirm('Remove every folder marker on this roll?')) return;
    applyFrames(await run('frames.clearMarkers'));
  },
  applyOverride: () => frameCommand('frames.setOverride', {
    rotation: Number($('#ovr-rotation').value), flipH: $('#ovr-mirror').checked, negative: $('#ovr-negative').checked,
  }),
  clearOverrides: () => frameCommand('frames.clearOverrides'),
  detect,
  detectCancel: () => call('detect.cancel'),
  toneReset: () => {
    const m = Number($('#tone-method').value);
    applyRanges(m, true);
    setSlider('strength', 50);
    $$('#tone-flags input').forEach((c) => { c.checked = false; });
    sendProcess();
  },
  pickFolder: async () => {
    const p = await run('dialog.pickFolder', { initial: $('#exp-root').value || $('#exp-root').placeholder });
    if (p) { $('#exp-root').value = p; exportChanged(); }
  },
  openFolder: () => run('shell.openFolder', { path: $('#exp-root').value || $('#exp-root').placeholder }),
  exportStart,
  prepareFolders: async () => {
    const r = await run('export.prepareFolders', gatherExport());
    toast(`Created ${r.created} folder${r.created === 1 ? '' : 's'} in ${r.root}`, 'ok');
  },
  exportPause: async () => {
    state.exportPaused = !state.exportPaused;
    await call(state.exportPaused ? 'export.pause' : 'export.resume');
    $('#exp-pause span').textContent = state.exportPaused ? 'Resume' : 'Pause';
  },
  exportStop: () => call('export.cancel'),
  shortcuts: () => { $('#shortcuts-modal').hidden = false; },
  shortcutsClose: () => { $('#shortcuts-modal').hidden = true; },
};

document.addEventListener('click', (e) => {
  if (e.target.id === 'shortcuts-modal') { commands.shortcutsClose(); return; }
  const el = e.target.closest('[data-cmd]');
  if (!el || el.disabled) return;
  const fn = commands[el.dataset.cmd];
  if (fn) Promise.resolve(fn()).catch(() => {});
});

// ------------------------------------------------------------------ keyboard

function typing(e) {
  return e.target.closest('input, textarea, select, [contenteditable="true"], .toastui-editor-defaultUI');
}

document.addEventListener('keydown', (e) => {
  const ctrl = e.ctrlKey || e.metaKey;
  const k = e.key.toLowerCase();
  if (ctrl && k === 'o') { e.preventDefault(); commands.open(); return; }
  if (ctrl && k === 's') { e.preventDefault(); save(e.shiftKey); return; }

  if (!$('#shortcuts-modal').hidden) {
    if (e.key === 'Escape' || e.key === '?') commands.shortcutsClose();
    return;
  }
  if (typing(e)) return;
  if (e.key === '?') { commands.shortcuts(); return; }
  if (!hasRoll()) return;

  // Shortcuts follow the Lazarus edition (A marker, D delete, X/C pages, F/G markers, E/J/S, Z, Ctrl+Z/A/D).
  if (ctrl) {
    const fn = { z: undo, a: () => view.selectAll(), d: () => view.selectNone() }[k];
    if (fn) { e.preventDefault(); fn(); }
    return;
  }
  if (e.altKey) return;
  const sel = view.selected.size > 0;
  const map = {
    escape: () => { if (!view.cancelDrag()) view.selectNone(); hideContextMenu(); },
    delete: () => deleteSelected(true),
    d: () => sel && deleteSelected(false),
    a: () => sel && frameCommand('frames.toggleMarker'),
    m: () => sel && frameCommand('frames.toggleMarker'),
    e: () => sel && commands.merge(),
    j: () => sel && commands.combine(),
    s: () => sel && commands.split(),
    z: () => commands.toggleSuggested(),
    f: () => jumpMarker(true),
    g: () => jumpMarker(false),
    enter: () => commands.previewFrame(),
    c: commands.next, pagedown: commands.next,
    x: commands.prev, pageup: commands.prev,
    home: commands.first, end: commands.last,
    '+': commands.zoomIn, '=': commands.zoomIn, '-': commands.zoomOut,
  };
  const fn = map[k];
  if (fn) { e.preventDefault(); fn(); }
});

// ------------------------------------------------------------------ host events

on('project.dirty', setDirty);
on('toast', (m) => toast(m));
on('theme.changed', (d) => { if (document.documentElement.dataset.theme !== d.theme) applyTheme(d.theme); });
on('preview.closed', () => $('#strip-canvas').focus());

// ------------------------------------------------------------------ smoke self-test (CI only)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

window.__striplightSelfTest = async () => {
  const result = { ok: false, frames: view.frames.length };
  try {
    for (let i = 0; i < 40 && [...view.images.values()].some((e) => e.state === 'loading'); i++) await sleep(250);
    result.stripImagesLoaded = [...view.images.values()].filter((e) => e.state === 'ok').length;
    showTab('notes');
    await sleep(400);
    result.notesEditor = !!document.querySelector('#notes-editor .toastui-editor-defaultUI');
    showTab('frames');
    // The preview window reports back when its image has loaded.
    const loaded = new Promise((resolve) => on('preview.loaded', (d) => resolve(d.ok)));
    openFrameModal(Math.min(2, view.frames.length - 1));
    result.previewWindowLoaded = await Promise.race([loaded, sleep(25000).then(() => false)]);
    // Light theme renders without errors too.
    applyTheme('light');
    await sleep(300);
    result.ok = result.frames > 0 && result.stripImagesLoaded > 0 && result.notesEditor && result.previewWindowLoaded;
  } catch (err) {
    result.error = String(err);
  }
  await call('smoke.result', result);
};

window.__striplightSelfTestCleanup = () => {
  applyTheme('dark');
  call('preview.close').catch(() => {});
  showTab('process');
};

// ------------------------------------------------------------------ start-up

async function init() {
  refreshEnabled();
  if (!inHost) {
    status('Open this page through StriplightPRO.exe — it needs the desktop host.');
    return;
  }
  const info = await run('app.init');
  state.settings = info.settings;
  state.smoke = !!info.smoke;
  $('#tone-method').replaceChildren(...info.toneMethods.map((name, i) => new Option(name, String(i))));
  $('#status-engine').textContent = `v${info.version} · ${info.turboJpeg}`;
  document.title = `Striplight PRO ${info.version}`;

  const s = info.settings;
  $('#strips-per-row').value = s.stripsPerRow;
  $('#rotate-cw').checked = s.rotateCw;
  $('#zoom').value = Math.round(s.zoom * 100);
  paintRange($('#zoom'));
  $('#zoom-out').textContent = `${Math.round(s.zoom * 100)}%`;
  $('#auto-strips').checked = s.autoStrips;
  $('#strip-numbers').checked = s.showStripNumbers;
  applyTheme(s.theme || 'dark');
  view.setView({ stripsPerRow: s.stripsPerRow, zoom: s.zoom, fillOpacity: s.frameFillOpacity, rotateCw: s.rotateCw, autoStrips: s.autoStrips, showStripNumbers: s.showStripNumbers });
  applyRanges(0, true);
  renderRecent();
  if (info.session) applySession(info.session);
  if (state.smoke) call('app.ready').catch(() => {});
}

init().catch((err) => status(err.message));
