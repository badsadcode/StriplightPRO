// Striplight PRO — page controller. Wires the toolbar, side panels, strip view and
// frame preview to the .NET host through the bridge. The host owns the project; this
// page keeps a copy of the frame list for drawing and sends every edit back.

import { call, on, inHost } from './bridge.js';
import { StripView, hasTone } from './stripView.js';
import { initNotes, setNotes, flushNotes } from './notes.js';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

// ------------------------------------------------------------------ state

const state = {
  session: null,        // SessionDto from the host
  settings: null,       // AppSettings
  imageVersion: 1,
  detecting: false,
  exporting: false,
  exportPaused: false,
};

const view = new StripView($('#strip-canvas'), {
  onSelectionChanged: () => refreshFramesPanel(),
  onPageChanged: () => refreshPager(),
  onHover: (t) => { $('#status-hover').textContent = t; },
  onFramesEdited: (indices) => patchFrames(indices),
  onFrameCreated: (frame) => addFrame(frame),
  onOpenFrame: (idx) => openFrameModal(idx),
  onContextMenu: (x, y) => showContextMenu(x, y),
  onDismissMenus: () => hideContextMenu(),
  onZoomRequest: (z) => setZoom(z),
});

// ------------------------------------------------------------------ helpers

function toast(message, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  $('#toast-host').append(el);
  setTimeout(() => el.remove(), kind === 'error' ? 9000 : 4500);
}

function status(text) { $('#status-main').textContent = text; }

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

const hasRoll = () => !!state.session;
const selection = () => [...view.selected].sort((a, b) => a - b);
const frameKey = (f) => `${f.leadEdge}:${f.trailEdge}:${f.leftEdge}:${f.rightEdge}`;

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
}

// ------------------------------------------------------------------ session

function applySession(s) {
  state.session = s;
  state.imageVersion = s.imageVersion;
  view.imageVersion = s.imageVersion;
  view.setRoll(s.roll, s.frames);
  $('#empty-state').hidden = true;
  $('#legend').hidden = false;
  $('.roll-name').textContent = s.roll.rollName || 'Untitled roll';
  $('.roll-name').title = s.projectPath || s.idfPath || '';
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
  status(`${s.roll.stripCount.toLocaleString()} strips · ${s.frames.length.toLocaleString()} frames · ${s.projectPath || s.idfPath}`);
  $('#strip-canvas').focus();
}

async function openProject(path = '') {
  const s = await run('project.open', { path });
  if (s) applySession(s);
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
    toast(`Saved ${r.path.split(/[\\/]/).pop()}`, 'ok');
  }
}

function renderRecent() {
  const list = $('#recent-list');
  list.replaceChildren();
  for (const p of state.settings?.recentProjects || []) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.textContent = p;
    b.title = p;
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

async function deleteSelected() {
  const n = view.selected.size;
  if (!n) return;
  if (n > 20 && !confirm(`Delete ${n} frames?`)) return;
  const r = await run('frames.delete', { indices: selection() });
  applyFrames(r, []);
  status(`Deleted ${n} frame${n === 1 ? '' : 's'}.`);
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
  toast('No odd-size frames.');
}

function refreshFramesPanel() {
  const frames = view.frames;
  $('#stat-frames').textContent = frames.length.toLocaleString();
  $('#stat-markers').textContent = frames.filter((f) => f.isMarker).length.toLocaleString();
  $('#stat-abnormal').textContent = frames.filter((f) => f.isOversized || f.isUndersized).length.toLocaleString();
  $('#stat-selected').textContent = view.selected.size.toLocaleString();
  refreshEnabled();

  const sel = selection();
  const info = $('#frame-info');
  if (sel.length !== 1) { info.textContent = ''; return; }
  const i = sel[0], f = frames[i], ll = state.session.roll.lengthLines;
  const lines = [
    `Frame ${i + 1} of ${frames.length}`,
    `Lead / trail   ${f.leadEdge} – ${f.trailEdge}  (strips ${Math.floor(f.leadEdge / ll) + 1}–${Math.floor(f.trailEdge / ll) + 1})`,
    `Left / right   ${f.leftEdge} – ${f.rightEdge}`,
    `Size           ${f.trailEdge - f.leadEdge} × ${f.rightEdge - f.leftEdge} px`,
  ];
  if (f.isMarker) lines.push('Folder marker');
  if (f.hasOverride) lines.push(`Own orientation: ${f.rotation}°${f.flipH ? ', mirrored' : ''}${f.negative ? ', negative' : ''}`);
  if (hasTone(f)) lines.push('Own tone values (from QuantumScan / Lazarus edition)');
  info.textContent = lines.join('\n');
  updateExportExample();
}

// ------------------------------------------------------------------ pager & view

function refreshPager() {
  const pages = view.pageCount;
  $('#page-input').value = pages ? view.page + 1 : 1;
  $('#page-input').max = Math.max(1, pages);
  $('#page-count').textContent = `/ ${pages}`;
}

const sendView = debounce(async () => {
  const r = await call('view.set', {
    stripsPerRow: view.stripsPerRow, zoom: view.zoom,
    rotateCw: $('#rotate-cw').checked, frameFillOpacity: view.fillOpacity,
  }).catch((e) => toast(e.message, 'error'));
  if (r) { state.imageVersion = r.imageVersion; view.setImageVersion(r.imageVersion); }
}, 200);

function setZoom(z) {
  $('#zoom').value = Math.round(z * 100);
  $('#zoom-out').textContent = `${Math.round(z * 100)}%`;
  view.setView({ zoom: z });
  sendView();
}

$('#zoom').addEventListener('input', (e) => setZoom(e.target.value / 100));
$('#strips-per-row').addEventListener('change', (e) => {
  view.setView({ stripsPerRow: Number(e.target.value) || 4 });
  sendView();
});
$('#rotate-cw').addEventListener('change', sendView);
$('#page-input').addEventListener('change', (e) => view.gotoPage((Number(e.target.value) || 1) - 1));

// ------------------------------------------------------------------ process panel

const QUANTUM = { contrast: [-128, 255, 64], brightness: [-128, 127, 0], gamma: [-255, 255, 0] };
const STRIPLIGHT = { contrast: [-100, 100, 0], brightness: [-100, 100, 0], gamma: [10, 300, 100] };
const isQuantum = (m) => m === 1 || m === 4;
const isAdaptive = (m) => m >= 5 && m <= 8;

function slider(key) { return $(`.slider[data-key="${key}"]`); }

function setSlider(key, value, range) {
  const el = slider(key);
  const [r, n] = el.querySelectorAll('input');
  if (range) {
    for (const i of [r, n]) { i.min = range[0]; i.max = range[1]; }
  }
  r.value = n.value = value;
}

function getSlider(key) { return Number(slider(key).querySelector('input[type=number]').value) || 0; }

function applyRanges(method, resetValues) {
  const ranges = isQuantum(method) ? QUANTUM : STRIPLIGHT;
  for (const k of ['contrast', 'brightness', 'gamma']) {
    setSlider(k, resetValues ? ranges[k][2] : getSlider(k), ranges[k]);
  }
  slider('strength').hidden = !isAdaptive(method);
  $('#tone-hint').textContent = isAdaptive(method)
    ? 'Adaptive: export analyses each frame. On the strips it runs per strip, so use Preview frame for the exact result. Sliders below apply after the adaptive step.'
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
  const [r, n] = el.querySelectorAll('input');
  r.addEventListener('input', () => { n.value = r.value; sendProcess(); });
  n.addEventListener('change', () => {
    n.value = Math.max(Number(n.min), Math.min(Number(n.max), Number(n.value) || 0));
    r.value = n.value;
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
    leftInset: Number($('#det-left').value) || 0,
    rightInset: Number($('#det-right').value) || 0,
    useToneSliders: $('#det-tone').checked,
  };
  state.detecting = true;
  refreshEnabled();
  $('#det-progress').value = 0;
  $('#det-status').textContent = 'Starting…';
  try {
    const r = await call('detect.run', args);
    applyFrames(r.frames, []);
    const msg = r.found < 0 ? 'Detection cancelled.' : `Found ${r.found.toLocaleString()} frames.`;
    $('#det-status').textContent = msg;
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
  $('#det-progress').max = p.totalStrips;
  $('#det-progress').value = p.currentStrip;
  $('#det-status').textContent =
    `Strip ${p.currentStrip.toLocaleString()} / ${p.totalStrips.toLocaleString()} · ${p.framesFound.toLocaleString()} frames` +
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
  $('#exp-archive-wrap').hidden = !archive;
  $('#exp-quantum').hidden = archive;
}

async function updateExportExample() {
  if (!hasRoll() || !view.frames.length) { $('#exp-example').textContent = ''; return; }
  const index = selection()[0] ?? 0;
  const r = await call('export.preview', { ...gatherExport(), index }).catch(() => null);
  const el = $('#exp-example');
  if (!r) return;
  el.classList.toggle('error', !!r.error);
  el.textContent = r.error ? r.error : `Frame ${index + 1} → ${r.path}`;
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
  $('#exp-progress').value = 0;
  try {
    const r = await call('export.start', args);
    state.exporting = true;
    state.exportPaused = false;
    $('#exp-pause').textContent = 'Pause';
    $('#exp-progress').max = r.jobs;
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
  $('#exp-progress').max = p.total;
  $('#exp-progress').value = p.done;
  $('#exp-status').textContent =
    `${p.done.toLocaleString()} / ${p.total.toLocaleString()} · ${exportCounts.exported} exported · ` +
    `${exportCounts.skipped} skipped · ${exportCounts.failed} failed`;
  if (p.outcome === 'Exported' && view.frames[p.frameIdx]) {
    view.frames[p.frameIdx].isExported = true;
    view.invalidate();
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

// ------------------------------------------------------------------ frame preview modal

let modalIdx = -1;

async function openFrameModal(idx) {
  const f = view.frames[idx];
  if (!f) return;
  modalIdx = idx;
  $('#frame-modal').hidden = false;
  $('#frame-modal-title').textContent = `Frame ${idx + 1} of ${view.frames.length}${f.isMarker ? ' · folder marker' : ''}`;
  $('#frame-modal-loading').hidden = false;
  $('#frame-modal-loading').textContent = 'Building frame…';
  const img = $('#frame-modal-img');
  img.hidden = true;
  img.onload = () => { $('#frame-modal-loading').hidden = true; img.hidden = false; };
  img.onerror = () => { $('#frame-modal-loading').textContent = 'Could not build this frame (missing strips or preview).'; };
  // Geometry is part of the URL so an edited frame is never served from the image cache.
  img.src = `https://img.striplight/frame/${idx}?v=${state.imageVersion}&g=${frameKey(f)}:${f.rotation}:${f.hasOverride}`;
  view.select(idx);
  view.revealFrame(idx);
  const r = await call('export.preview', { ...gatherExport(), index: idx }).catch(() => null);
  $('#frame-modal-path').textContent = r?.path ? `→ ${r.path}` : (r?.error || '');
}

function closeFrameModal() {
  $('#frame-modal').hidden = true;
  modalIdx = -1;
  $('#strip-canvas').focus();
}

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

// ------------------------------------------------------------------ commands

const commands = {
  open: () => openProject(),
  save: () => save(false),
  saveAs: () => save(true),
  first: () => view.gotoPage(0),
  prev: () => view.gotoPage(view.page - 1),
  next: () => view.gotoPage(view.page + 1),
  last: () => view.gotoPage(view.pageCount - 1),
  selectAll: () => view.selectAll(),
  selectPage: () => view.selectPage(),
  selectNone: () => view.selectNone(),
  nextAbnormal,
  toggleMarker: () => frameCommand('frames.toggleMarker'),
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
  exportPause: async () => {
    state.exportPaused = !state.exportPaused;
    await call(state.exportPaused ? 'export.pause' : 'export.resume');
    $('#exp-pause').textContent = state.exportPaused ? 'Resume' : 'Pause';
  },
  exportStop: () => call('export.cancel'),
  modalPrev: () => modalIdx > 0 && openFrameModal(modalIdx - 1),
  modalNext: () => modalIdx < view.frames.length - 1 && openFrameModal(modalIdx + 1),
  modalMarker: async () => {
    const idx = modalIdx;
    await frameCommand('frames.toggleMarker');
    openFrameModal(idx);
  },
  modalClose: closeFrameModal,
};

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-cmd]');
  if (!el || el.disabled) return;
  const fn = commands[el.dataset.cmd];
  if (fn) Promise.resolve(fn()).catch(() => {});
});

// ------------------------------------------------------------------ tabs

$$('.tabs [data-tab]').forEach((tab) => tab.addEventListener('click', () => {
  $$('.tabs [data-tab]').forEach((t) => t.setAttribute('aria-selected', String(t === tab)));
  $$('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== tab.dataset.tab; });
  if (tab.dataset.tab === 'notes') initNotes($('#notes-editor'));
  if (tab.dataset.tab === 'export') updateExportExample();
}));

// ------------------------------------------------------------------ keyboard

function typing(e) {
  const t = e.target;
  return t.closest('input, textarea, select, [contenteditable="true"], .toastui-editor-defaultUI');
}

document.addEventListener('keydown', (e) => {
  const ctrl = e.ctrlKey || e.metaKey;
  if (ctrl && e.key.toLowerCase() === 'o') { e.preventDefault(); commands.open(); return; }
  if (ctrl && e.key.toLowerCase() === 's') { e.preventDefault(); save(e.shiftKey); return; }

  if (!$('#frame-modal').hidden) {
    if (e.key === 'Escape') closeFrameModal();
    else if (e.key === 'ArrowLeft') commands.modalPrev();
    else if (e.key === 'ArrowRight') commands.modalNext();
    else if (e.key.toLowerCase() === 'm') commands.modalMarker();
    return;
  }
  if (typing(e) || !hasRoll()) return;

  switch (e.key) {
    case 'Escape': if (!view.cancelDrag()) view.selectNone(); hideContextMenu(); break;
    case 'Delete': deleteSelected(); break;
    case 'm': case 'M': if (view.selected.size) frameCommand('frames.toggleMarker'); break;
    case 'Enter': commands.previewFrame(); break;
    case 'PageDown': commands.next(); break;
    case 'PageUp': commands.prev(); break;
    case 'Home': commands.first(); break;
    case 'End': commands.last(); break;
    case '+': case '=': setZoom(Math.min(4, view.zoom * 1.1)); break;
    case '-': setZoom(Math.max(0.25, view.zoom / 1.1)); break;
    case 'a': case 'A': if (ctrl) { e.preventDefault(); view.selectAll(); } break;
    default: return;
  }
  e.preventDefault();
});

// ------------------------------------------------------------------ host events

on('project.dirty', setDirty);
on('toast', (m) => toast(m));

// ------------------------------------------------------------------ start-up

async function init() {
  refreshEnabled();
  if (!inHost) {
    status('Open this page through StriplightPRO.exe — it needs the desktop host.');
    return;
  }
  const info = await run('app.init');
  state.settings = info.settings;
  $('#tone-method').replaceChildren(...info.toneMethods.map((name, i) => new Option(name, String(i))));
  $('#status-engine').textContent = `v${info.version} · ${info.turboJpeg}`;
  document.title = `Striplight PRO ${info.version}`;

  const s = info.settings;
  $('#strips-per-row').value = s.stripsPerRow;
  $('#rotate-cw').checked = s.rotateCw;
  $('#zoom').value = Math.round(s.zoom * 100);
  $('#zoom-out').textContent = `${Math.round(s.zoom * 100)}%`;
  view.setView({ stripsPerRow: s.stripsPerRow, zoom: s.zoom, fillOpacity: s.frameFillOpacity });
  applyRanges(0, true);
  renderRecent();
  if (info.session) applySession(info.session);
}

init().catch((err) => status(err.message));
