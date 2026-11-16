// Striplight PRO — page controller. Wires the app bar, tool rail, inspector panels,
// strip view and frame preview to the .NET host through the bridge. The host owns the
// project; this page keeps a copy of the frame list for drawing and sends every edit back.

import { call, on, inHost } from './bridge.js';
import { StripView, hasTone } from './stripView.js';
import { initNotes, setNotes, flushNotes } from './notes.js';
import { hydrateIcons, icon } from './icons.js';
import { initSegmented, initRanges, paintRange } from './ui.js';
import { Scrubber } from './scrubber.js';
import { COMMANDS, Keymap, comboFromEvent, keyLabel } from './keymap.js';
import { t, tn, initI18n, currentLanguage } from './i18n.js';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

hydrateIcons();
initSegmented($('#ovr-rotation'));
initSegmented($('#det-scope'));
initSegmented($('#tone-target'));
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
  onSelectionChanged: () => { refreshFramesPanel(); scrubber.invalidate(); followInPreview(); toneSelectionChanged(); },
  onPageChanged: () => { refreshPager(); scrubber.invalidate(); },
  onHover: (t) => { $('#status-hover').textContent = t; },
  onFramesEdited: (indices) => patchFrames(indices),
  onFrameCreated: (frame) => addFrame(frame),
  onOpenFrame: (idx) => openFrameModal(idx),
  onContextMenu: (x, y, hit, strip) => showContextMenu(x, y, hit, strip),
  onOverlayChanged: (layer, side, v) => overlayChanged(layer, side, v),
  onDismissMenus: () => hideContextMenu(),
  onZoomRequest: (z) => setZoom(z),
});
const scrubber = new Scrubber($('#scrubber'), view);
// For automated UI tests (smoke test, browser harness).
window.__striplight = { view };

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
  // While detecting: Pause / Stop / Cancel. After a stop: Continue.
  for (const id of ['#det-pause', '#det-stop', '#det-cancel']) $(id).hidden = !state.detecting;
  $('#det-pause').disabled = $('#det-stop').disabled = !state.detecting;
  $('#det-continue').hidden = !detectResume || state.detecting;
  $('#det-continue').disabled = !roll;
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
  $('.roll-name').textContent = s.roll.rollName || t('Untitled roll');
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
  $('#det-scope').value = 'all';

  toneTarget = 'all'; globalProcess = null;
  $('#tone-target').value = 'all';
  loadProcess(s.process);
  refreshToneTarget();
  detectResume = null;
  reportMfTyped = false;
  $('#report-modal').hidden = true;
  loadExport(s.export, s.defaultOutputRoot);
  // Saved project state: CW orientation, size check and every panel field.
  if (s.rotateCw !== undefined && $('#rotate-cw').checked !== s.rotateCw) {
    $('#rotate-cw').checked = s.rotateCw;
    view.setView({ rotateCw: s.rotateCw });
  }
  if (s.size) loadSizeRules({ sizeOverOn: s.size.overOn, sizeOverPercent: s.size.overPercent, sizeUnderOn: s.size.underOn, sizeUnderPercent: s.size.underPercent });
  if (s.panels) applyPanels(s.panels);
  else sendPanels(false);   // a project without saved panel state takes today's values (not marked unsaved)
  refreshOverlays();
  setNotes(s.notes);
  refreshFramesPanel();
  refreshPager();
  refreshEnabled();
  scrubber.invalidate();
  status(t('Opened {file}', { file: fileName(s.projectPath || s.idfPath) }));
  $('#strip-canvas').focus();
}

// ------------------------------------------------------------------ project panel state
// Every panel field of a project is saved in its .slf (via the host) and comes back on open,
// so a reopened project is exactly as it was left — not reset to defaults.
const PANEL_FIELDS = [
  // detection
  '#det-threshold', '#det-minw', '#det-minl', '#det-tone', '#det-live', '#det-auto', '#det-invert', '#det-adv',
  '#det-minrun', '#det-maxlen', '#det-touchw', '#det-touchl', '#det-osw', '#det-osl',
  '#det-scope', '#det-from', '#det-to', '#det-left', '#det-right', '#det-area',
  // folder-marker suggestions
  '#sug-num', '#sug-before', '#sug-every',
  // frames: split, repair, expand, trim, per-frame orientation
  '#split-parts', '#split-preview', '#join-gap', '#join-show', '#ex-l', '#ex-r', '#ex-t', '#ex-b',
  '#trim-show', '#trim-top', '#trim-bottom', '#ovr-rotation', '#ovr-mirror', '#ovr-negative',
];
let applyingPanels = false;

function gatherPanels() {
  const o = {};
  for (const id of PANEL_FIELDS) {
    const el = $(id);
    if (!el) continue;
    o[id.slice(1)] = el.type === 'checkbox' ? el.checked : String(el.value);
  }
  return o;
}

function applyPanels(state) {
  if (!state) return;
  applyingPanels = true;
  try {
    for (const id of PANEL_FIELDS) {
      const el = $(id), v = state[id.slice(1)];
      if (!el || v === undefined) continue;
      if (el.type === 'checkbox') el.checked = !!v; else el.value = v;
    }
    $('#det-adv-box').hidden = !$('#det-adv').checked;
    setStrictness($('#sug-num').value);
    refreshSplitPreview();
    refreshOverlays();
  } finally { applyingPanels = false; }
}

const sendPanels = debounce((user) => {
  if (!hasRoll() || applyingPanels) return;
  call('project.panels', { state: gatherPanels(), user }).catch(() => {});
}, 400);
for (const id of PANEL_FIELDS) {
  const el = $(id);
  if (!el) continue;
  el.addEventListener(el.matches('.seg') ? 'change' : el.type === 'checkbox' ? 'change' : 'input', () => { if (!applyingPanels) sendPanels(true); });
}

function refreshRollMeta() {
  if (!state.session) return;
  const r = state.session.roll;
  $('#roll-meta').textContent = `${tn(r.stripCount, '{n} strip', '{n} strips')} · ${tn(view.frames.length, '{n} frame', '{n} frames')}`;
}

async function openProject(path = '') {
  const s = await run('project.open', { path });
  if (s) applySession(s);
}

async function openDemo() {
  status(t('Preparing the demo roll…'));
  const s = await run('project.demo');
  if (s) {
    applySession(s);
    toast(t('Demo roll opened. Try Detect, Adjust and Export, or drag frames around.'), 'ok');
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
    toast(t('Saved {file}', { file: fileName(r.path) }), 'ok');
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
/** Selection changed: in "Selected frames" mode the sliders follow the (first) selected frame. */
function toneSelectionChanged() {
  if (toneTarget === 'sel') {
    if (!view.selected.size) setToneTarget('all');
    else loadSelectedTone();
  }
  refreshToneTarget();
}

function applyFrames(frames, keepKeys) {
  const keys = new Set(keepKeys ?? selection().map((i) => frameKey(view.frames[i])));
  state.session.frames = frames;
  const keep = [];
  frames.forEach((f, i) => { if (keys.has(frameKey(f))) keep.push(i); });
  view.setFrames(frames, keep);
  refreshFramesPanel();
  refreshRollMeta();
  refreshToneTarget();
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
  status(tn(r.remaining, 'Undone · {n} more step available', 'Undone · {n} more steps available'));
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
  toast(t('No folder markers on this roll.'));
}

async function deleteSelected(askConfirm = true) {
  const n = view.selected.size;
  if (!n) return;
  if (askConfirm && n > 20 && !confirm(tn(n, 'Delete {n} frame?', 'Delete {n} frames?'))) return;
  const r = await run('frames.delete', { indices: selection() });
  applyFrames(r, []);
  status(tn(n, 'Deleted {n} frame', 'Deleted {n} frames'));
}

/** Next flagged frame after the selection (Lazarus "Next Red / Next Small / Next Big"). */
function nextAbnormal(mode = 0) {
  const frames = view.frames;
  if (!frames.length) return;
  const match = (f) => (mode < 0 ? f.isUndersized : mode > 0 ? f.isOversized : f.isOversized || f.isUndersized);
  const start = selection().at(-1) ?? -1;
  for (let k = 1; k <= frames.length; k++) {
    const i = (start + k) % frames.length;
    if (match(frames[i])) {
      view.select(i);
      view.revealFrame(i);
      status(t('Frame {i}', { i: i + 1 }) + ` · ${frames[i].trailEdge - frames[i].leadEdge} px`);
      return;
    }
  }
  toast(mode < 0 ? t('No undersized frames with these settings.') : mode > 0 ? t('No oversized frames with these settings.') : t('No odd-size frames on this roll.'));
}

// ---- size check (Lazarus "Detect Oversized / Undersized Frames")
/** Same rule as FrameList.MarkOversizedUndersized in Core, for frames the host has not checked yet. */
function markSizes(frames) {
  const n = frames.length;
  if (!n) return;
  const h = frames.map((f) => f.trailEdge - f.leadEdge).sort((a, b) => a - b);
  const median = n % 2 ? h[(n - 1) / 2] : Math.trunc((h[n / 2 - 1] + h[n / 2]) / 2);
  if (!median) return;
  const r = sizeRules();
  const roundEven = (x) => { const f = Math.floor(x), d = x - f; return d > 0.5 || (d === 0.5 && f % 2) ? f + 1 : f; };
  const overH = roundEven(median * (r.overOn ? 1 + Math.min(200, r.overPercent) / 100 : 9999));
  const underH = roundEven(median * (r.underOn ? 1 - Math.min(99, r.underPercent) / 100 : 0));
  for (const f of frames) {
    const len = f.trailEdge - f.leadEdge;
    f.isOversized = len > overH;
    f.isUndersized = len < underH && len > 0;
  }
}

function sizeRules() {
  return {
    overOn: $('#sz-over').checked, overPercent: Number($('#sz-over-num').value) || 0,
    underOn: $('#sz-under').checked, underPercent: Number($('#sz-under-num').value) || 0,
  };
}
function loadSizeRules(s) {
  $('#sz-over').checked = s.sizeOverOn ?? true;
  $('#sz-under').checked = s.sizeUnderOn ?? true;
  $('#sz-over-num').value = $('#sz-over-range').value = s.sizeOverPercent ?? 50;
  $('#sz-under-num').value = $('#sz-under-range').value = s.sizeUnderPercent ?? 50;
  paintRange($('#sz-over-range'));
  paintRange($('#sz-under-range'));
}
const sendSizeRules = debounce(async () => {
  if (!hasRoll()) { call('frames.sizeRules', sizeRules()).catch(() => {}); return; }
  const r = await call('frames.sizeRules', { ...sizeRules(), user: true }).catch((e) => { toast(e.message, 'error'); return null; });
  if (r) applyFrames(r);
}, 150);
function refreshSizeHint() {
  const frames = view.frames;
  if (!frames.length) { $('#sz-hint').textContent = ''; return; }
  const lens = frames.map((f) => f.trailEdge - f.leadEdge).sort((a, b) => a - b);
  const n = lens.length;
  const median = n % 2 ? lens[(n - 1) / 2] : Math.floor((lens[n / 2 - 1] + lens[n / 2]) / 2);
  const big = frames.filter((f) => f.isOversized).length, small = frames.filter((f) => f.isUndersized).length;
  $('#sz-hint').textContent = `${t('Median frame length: {px} px', { px: median.toLocaleString() })} · ` +
    `${tn(big, '{n} oversized', '{n} oversized')} · ${tn(small, '{n} undersized', '{n} undersized')}`;
}
for (const [k, max] of [['over', 200], ['under', 99]]) {
  const r = $(`#sz-${k}-range`), n = $(`#sz-${k}-num`);
  r.addEventListener('input', () => { n.value = r.value; paintRange(r); sendSizeRules(); });
  n.addEventListener('change', () => {
    n.value = Math.max(0, Math.min(max, Number(n.value) || 0));
    r.value = n.value; paintRange(r); sendSizeRules();
  });
  $(`#sz-${k}`).addEventListener('change', sendSizeRules);
}

function refreshFramesPanel() {
  const frames = view.frames;
  $('#stat-frames').textContent = frames.length.toLocaleString();
  $('#stat-markers').textContent = frames.filter((f) => f.isMarker).length.toLocaleString();
  $('#stat-abnormal').textContent = frames.filter((f) => f.isOversized || f.isUndersized).length.toLocaleString();
  $('#stat-selected').textContent = view.selected.size.toLocaleString();
  refreshSizeHint();
  refreshEnabled();

  const sel = selection();
  const card = $('#frame-info');
  if (sel.length !== 1) { card.hidden = true; return; }
  const i = sel[0], f = frames[i], ll = state.session.roll.lengthLines;
  const rows = [
    [t('Lead → trail'), `${f.leadEdge.toLocaleString()} → ${f.trailEdge.toLocaleString()}`],
    [t('Strips'), `${Math.floor(f.leadEdge / ll) + 1} – ${Math.floor(f.trailEdge / ll) + 1}`],
    [t('Left → right'), `${f.leftEdge} → ${f.rightEdge}`],
    [t('Size'), `${f.trailEdge - f.leadEdge} × ${f.rightEdge - f.leftEdge} px`],
  ];
  if (f.customToneMethod >= 0) rows.push([t('Own tone'), `${t(state.toneMethods?.[f.customToneMethod] ?? String(f.customToneMethod))} · C ${f.customContrast} · B ${f.customBrightness} · G ${f.customGamma}`]);
  if (f.hasOverride) rows.push([t('Orientation'), `${f.rotation}°${f.flipH ? ' · ' + t('mirrored') : ''}${f.negative ? ' · ' + t('negative') : ''}`]);
  if (hasTone(f) && f.customToneMethod < 0) rows.push([t('Tone'), t('own values (from file)')]);
  card.replaceChildren();
  const title = document.createElement('div');
  title.className = 'fc-title';
  title.textContent = t('Frame {i} of {n}', { i: (i + 1).toLocaleString(), n: frames.length.toLocaleString() });
  if (f.isMarker) {
    const chip = document.createElement('span');
    chip.className = 'chip chip-warn';
    chip.textContent = t('Folder start');
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
    showStripNumbers: view.showStripNumbers, multiEdit: view.multiEdit,
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
// Frame fill opacity (0 = outlines only).
function setFill(v, persist = true) {
  v = Math.max(0, Math.min(100, Number(v) || 0));
  $('#fill-num').value = $('#fill-range').value = v;
  paintRange($('#fill-range'));
  view.setView({ fillOpacity: v });
  if (persist) sendView();
}
$('#fill-range').addEventListener('input', (e) => setFill(e.target.value));
$('#fill-num').addEventListener('change', (e) => setFill(e.target.value));

// ------------------------------------------------------------------ repair, trim, sections, overlays

const W = () => state.session.roll.widthPixels;

/** Expand: screen directions mapped to the frame edges (top/bottom depend on CW/CCW). */
function expandSelected() {
  const n = (id) => Number($(id).value) || 0;
  const top = n('#ex-t'), bottom = n('#ex-b');
  return frameTool('frames.expand', {
    lead: n('#ex-l'), trail: n('#ex-r'),
    right: view.rotateCw ? bottom : top, left: view.rotateCw ? top : bottom,
  });
}

/** Trim: the yellow bands are measured from the screen top / bottom of a strip. */
async function applyTrim() {
  const top = Number($('#trim-top').value) || 0, bottom = Number($('#trim-bottom').value) || 0;
  if (!top && !bottom) { toast(t('Set the trim lines first (Top / Bottom).')); return; }
  if (!confirm(t('Clip all {n} frames to the trim lines?\nOnly frames that reach into the yellow bands change.', { n: view.frames.length.toLocaleString() }))) return;
  const w = W();
  const minLeft = view.rotateCw ? top : bottom;            // stored column 0 is the screen top in CW mode
  const maxRight = view.rotateCw ? (bottom ? w - bottom : 0) : (top ? w - top : 0);
  const r = await run('frames.trim', { minLeft, maxRight });
  applyFrames(r.frames);
  status(tn(r.count, 'Trimmed {n} frame', 'Trimmed {n} frames'));
  $('#trim-top').value = $('#trim-bottom').value = 0;   // like Lazarus: lines reset after apply
  view.trim.top = view.trim.bottom = 0;
  view.invalidate();
  sendPanels(true);
}

async function selectSection(idx) {
  const r = await run('frames.section', { index: idx, includeSuggested: true });
  const ids = [];
  for (let i = r.start; i <= r.end; i++) ids.push(i);
  view.setFrames(view.frames, ids);
  refreshFramesPanel();
  scrubber.invalidate();
  status(t('Selected folder section: frames {a}–{b}', { a: r.start + 1, b: r.end + 1 }));
}

async function deleteSection(idx) {
  const r0 = await run('frames.section', { index: idx, includeSuggested: false });
  if (!confirm(t('Delete frames {a}–{b} ({n} frames, from the folder marker to the next one)?', { a: r0.start + 1, b: r0.end + 1, n: r0.end - r0.start + 1 }))) return;
  const r = await run('frames.deleteSection', { index: idx });
  applyFrames(r.frames, []);
  status(tn(r.count, 'Deleted {n} frame', 'Deleted {n} frames'));
}

async function clearExported(indices) {
  const frames = await run('frames.clearExportedOn', indices ? { indices } : {});
  applyFrames(frames);
}

function setDetectRange(which, strip) {
  $(which === 'from' ? '#det-from' : '#det-to').value = strip + 1;
  $('#det-scope').value = 'range';
  refreshOverlays();
  sendPanels(true);
  showTab('detect');
  toast(t(which === 'from' ? 'Detection starts at strip {n}' : 'Detection ends at strip {n}', { n: strip + 1 }));
}

/** Pushes the panel values into the strip-view overlays. */
function refreshOverlays() {
  if (!hasRoll()) return;
  const num = (id) => Math.max(0, Number($(id).value) || 0);
  view.trim = { show: $('#trim-show').checked, top: num('#trim-top'), bottom: num('#trim-bottom') };
  view.area = { show: $('#det-area').checked, top: num('#det-left'), bottom: num('#det-right') };
  const from = Math.max(0, num('#det-from') - 1), to = Math.max(0, num('#det-to') - 1);
  view.range = { show: $('#det-scope').value === 'range', from, to };
  $('#det-run').lastChild.textContent = view.range.show ? t('Detect strips {a}–{b}', { a: from + 1, b: to + 1 }) : t('Detect whole roll');
  view.join = { show: $('#join-show').checked, gap: num('#join-gap') };
  view.invalidate();
}

/** A trim / ignore line was dragged on the strips: show the new value in its field. */
function overlayChanged(layer, side, v) {
  const id = layer === 'trim' ? (side === 'top' ? '#trim-top' : '#trim-bottom') : (side === 'top' ? '#det-left' : '#det-right');
  $(id).value = v;
  sendPanels(true);
}

['#trim-show', '#trim-top', '#trim-bottom', '#det-area', '#det-left', '#det-right', '#det-from', '#det-to', '#join-show', '#join-gap']
  .forEach((id) => $(id).addEventListener('input', refreshOverlays));
// Typing a start or end means "detect this range" (as in the Lazarus edition)
['#det-from', '#det-to'].forEach((id) => $(id).addEventListener('input', () => { $('#det-scope').value = 'range'; refreshOverlays(); }));
$('#det-scope').addEventListener('change', refreshOverlays);

// ------------------------------------------------------------------ folder-marker suggestions

const anchor = () => (view.selected.size === 1 ? [...view.selected][0] : -1);

async function suggest(direction = 0) {
  if (direction && anchor() < 0) { toast(t('Select exactly one frame as the anchor.')); return; }
  const r = await run('markers.suggest', {
    strictness: Number($('#sug-num').value) || 50, beforeGap: $('#sug-before').checked, direction, anchor: anchor(),
  });
  applyFrames(r.frames);
  const what = direction < 0 ? tn(r.suggested, 'Suggested {n} marker toward start', 'Suggested {n} markers toward start')
    : direction > 0 ? tn(r.suggested, 'Suggested {n} marker toward end', 'Suggested {n} markers toward end')
      : tn(r.suggested, 'Suggested {n} marker', 'Suggested {n} markers');
  $('#sug-status').textContent = `${what} · ${t('gap threshold {px} px', { px: r.threshold.toLocaleString() })}`;
}

async function markerTool(cmd, args, label) {
  const r = await run(cmd, args);
  applyFrames(r.frames);
  $('#sug-status').textContent = `${t(label)}: ${r.count.toLocaleString()}`;
}

function setStrictness(v) {
  v = Math.max(10, Math.min(200, Number(v) || 50));
  $('#sug-num').value = $('#sug-range').value = v;
  paintRange($('#sug-range'));
}
// Like Lazarus: moving the slider re-runs the suggestion when suggestions are showing.
const resuggest = debounce(() => { if (view.frames.some((f) => f.isSuggested)) suggest(0); }, 250);
$('#sug-range').addEventListener('input', (e) => { setStrictness(e.target.value); resuggest(); sendPanels(true); });
$('#sug-num').addEventListener('change', (e) => { setStrictness(e.target.value); resuggest(); });
$('#sug-before').addEventListener('change', resuggest);

// Split preview (Lazarus): dashed lines where S would cut the selected frames.
function refreshSplitPreview() {
  view.splitPreview = $('#split-preview').checked;
  view.splitParts = Math.max(2, Number($('#split-parts').value) || 2);
  view.invalidate();
}
$('#split-preview').addEventListener('change', refreshSplitPreview);
$('#split-parts').addEventListener('input', refreshSplitPreview);
$('#multi-edit').addEventListener('change', (e) => {
  view.multiEdit = e.target.checked;
  view.invalidate();
  status(view.multiEdit ? t('Multi-edit on: dragging an edge resizes all selected frames') : t('Multi-edit off'));
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

const TONE_KEYS = ['method', 'flags', 'contrast', 'brightness', 'gamma', 'strength'];
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
    ? t('Adaptive methods analyse each frame on export. The strips show a per-strip approximation, so use Preview (Enter) for the exact result. The sliders apply after the adaptive step.')
    : isQuantum(method) ? t('Quantum ranges: contrast 64 and gamma 0 are neutral.') : '';
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
  const p = gatherControls();
  // While the sliders show the selected frames' tone, the global tone is the stashed one.
  if (toneTarget === 'sel' && globalProcess) {
    for (const k of TONE_KEYS) p[k] = globalProcess[k];
  }
  return p;
}

function gatherControls() {
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

// ---- per-frame tone ("Apply tone to: Selected frames")
// A frame given its own tone keeps the complete tone (method, curves, sliders, strength), so
// later changes to the global tone never touch it. The global values are stashed meanwhile.
var toneTarget = 'all';      // 'all' | 'sel'
var globalProcess = null;    // global tone while the sliders show the selected frames' tone
let toneUndo = true;         // first change of an edit makes one undo step

function toneFields() {
  const p = gatherControls();
  return Object.fromEntries(TONE_KEYS.map((k) => [k, p[k]]));
}

function setToneControls(t) {
  $('#tone-method').value = t.method;
  applyRanges(t.method, false);
  setSlider('contrast', t.contrast);
  setSlider('brightness', t.brightness);
  setSlider('gamma', t.gamma);
  setSlider('strength', t.strength);
  $$('#tone-flags input').forEach((c) => { c.checked = (t.flags & Number(c.value)) !== 0; });
}

async function loadSelectedTone() {
  const i = selection()[0];
  if (i === undefined) return;
  const t = await call('frames.toneOf', { index: i }).catch(() => null);
  if (t && toneTarget === 'sel') setToneControls(t);
  toneUndo = true;
}

async function setToneTarget(t) {
  if (t === 'sel' && !view.selected.size) t = 'all';
  $('#tone-target').value = t;
  if (t === toneTarget) { refreshToneTarget(); return; }
  if (t === 'sel') globalProcess = gatherControls();
  else if (globalProcess) setToneControls(globalProcess);
  toneTarget = t;
  if (t === 'all') globalProcess = null; else await loadSelectedTone();
  refreshToneTarget();
}

function refreshToneTarget() {
  const n = view.selected.size, own = view.frames.filter(hasTone).length, sel = toneTarget === 'sel';
  $('#tone-target-sel').textContent = n ? `${t('Selected frames')} (${n.toLocaleString()})` : t('Selected frames');
  $('#tone-target-sel').disabled = !n;
  $('#tone-title').textContent = sel ? t('Tone · selected frames') : t('Tone · all frames');
  $('[data-panel=process]').classList.toggle('tone-sel', sel);
  $('#tone-own').textContent = sel
    ? t('Changes here give the selected frames their own tone. Changing the global tone later leaves them as they are.')
    : own ? tn(own, "{n} frame has its own tone; global changes don't affect it.", "{n} frames have their own tone; global changes don't affect them.")
      : t('Select frames and choose "Selected frames" to give them their own tone.');
}

const sendFrameTone = debounce(async () => {
  if (!hasRoll() || toneTarget !== 'sel' || !view.selected.size) return;
  const undo = toneUndo;
  toneUndo = false;
  const r = await call('frames.setTone', { indices: selection(), undo, ...toneFields() }).catch((e) => toast(e.message, 'error'));
  if (r) applyFrames(r);
}, 180);

const toneChanged = () => (toneTarget === 'sel' ? sendFrameTone() : sendProcess());

$('#tone-target').addEventListener('change', (e) => setToneTarget(e.target.value));

let lastMethod = 0;
$('#tone-method').addEventListener('focus', (e) => { lastMethod = Number(e.target.value); });
$('#tone-method').addEventListener('change', (e) => {
  const m = Number(e.target.value);
  applyRanges(m, isQuantum(m) !== isQuantum(lastMethod)); // switching slider families resets to neutral
  lastMethod = m;
  toneChanged();
});
$$('.slider:not(.standalone)').forEach((el) => {
  const [r, n] = sliderInputs(el);
  const send = el.dataset.key === 'sharpness' ? sendProcess : toneChanged; // sharpening stays global
  r.addEventListener('input', () => { n.value = r.value; send(); });
  n.addEventListener('change', () => {
    n.value = Math.max(Number(n.min), Math.min(Number(n.max), Number(n.value) || 0));
    r.value = n.value;
    paintRange(r);
    send();
  });
});
$$('#tone-flags input').forEach((el) => el.addEventListener('change', toneChanged));
$$('#sharp-mode, #proc-rotation, #proc-mirror, #proc-negative, #tone-on-strips')
  .forEach((el) => el.addEventListener('change', sendProcess));

// ------------------------------------------------------------------ detect panel

// ---- detection options (remembered on this PC)
const num0 = (id) => Math.max(0, Number($(id).value) || 0);
const DET_KEYS = ['#det-auto', '#det-invert', '#det-adv', '#det-minrun', '#det-maxlen', '#det-touchw', '#det-touchl', '#det-osw', '#det-osl'];
function saveDetectOptions() {
  const o = Object.fromEntries(DET_KEYS.map((id) => [id, $(id).type === 'checkbox' ? $(id).checked : $(id).value]));
  try { localStorage.setItem('striplight.detect', JSON.stringify(o)); } catch { /* storage unavailable */ }
  $('#det-adv-box').hidden = !$('#det-adv').checked;
}
function loadDetectOptions() {
  let o = null;
  try { o = JSON.parse(localStorage.getItem('striplight.detect') || 'null'); } catch { o = null; }
  if (o) for (const id of DET_KEYS) if (id in o) { if ($(id).type === 'checkbox') $(id).checked = !!o[id]; else $(id).value = o[id]; }
  $('#det-adv-box').hidden = !$('#det-adv').checked;
}
DET_KEYS.forEach((id) => $(id).addEventListener('change', saveDetectOptions));
loadDetectOptions();

async function detect() {
  if (!hasRoll() || state.detecting) return;
  const stripCount = state.session.roll.stripCount;
  const wholeRoll = $('#det-scope').value !== 'range';
  const args = {
    threshold: Number($('#det-threshold').value),
    minWidth: Number($('#det-minw').value),
    minLength: Number($('#det-minl').value),
    stripFrom: wholeRoll ? 0 : Math.max(0, (Number($('#det-from').value) || 1) - 1),
    stripTo: wholeRoll ? stripCount - 1 : Math.min(stripCount - 1, (Number($('#det-to').value) || stripCount) - 1),
    // Insets are counted from stored column 0, which is the bottom of the screen in the
    // default CCW orientation and the top in CW mode. The fields are labelled as seen on screen.
    leftInset: $('#det-area').checked ? Number($(view.rotateCw ? '#det-left' : '#det-right').value) || 0 : 0,
    rightInset: $('#det-area').checked ? Number($(view.rotateCw ? '#det-right' : '#det-left').value) || 0 : 0,
    useToneSliders: $('#det-tone').checked,
    autoThreshold: $('#det-auto').checked,
    invert: $('#det-invert').checked,
    ...($('#det-adv').checked ? {
      minRun: num0('#det-minrun'), maxLength: num0('#det-maxlen'),
      touchWidth: num0('#det-touchw'), touchLength: num0('#det-touchl'),
      overscanWidth: Number($('#det-osw').value) || 0, overscanLength: Number($('#det-osl').value) || 0,
    } : {}),
  };
  detectResume = null;
  $('#det-status').textContent = wholeRoll ? t('Starting · whole roll…') : t('Starting · strips {a}–{b}…', { a: args.stripFrom + 1, b: args.stripTo + 1 });
  await runDetection('detect.run', args, args.stripFrom, args.stripTo, -1);
}

/** Continue a stopped detection (from the strip after the stop point to the original end). */
async function detectContinue() {
  if (!hasRoll() || state.detecting || !detectResume) return;
  const r = detectResume;
  $('#det-status').textContent = t('Continuing from strip {n}…', { n: r.nextStrip + 1 });
  await runDetection('detect.continue', {}, r.nextStrip, r.stripTo, r.replaceFrom);
}

let detectResume = null;   // { nextStrip, stripTo, replaceFrom } after Stop

async function runDetection(cmd, args, fromStrip, toStrip, replaceFrom) {
  state.detecting = true;
  state.detectPaused = false;
  $('#det-pause span').textContent = t('Pause');
  refreshEnabled();
  startLiveDetect(fromStrip, toStrip, replaceFrom);
  setBar('#det-bar', 0, 1);
  try {
    const r = await call(cmd, args);
    applyFrames(r.frames, []);
    detectResume = r.stopped ? { nextStrip: r.nextStrip, stripTo: r.stripTo, replaceFrom: r.replaceFrom } : null;
    const found = `${tn(r.found, 'Found {n} frame', 'Found {n} frames')} · ${tn(r.read ?? 0, '{n} preview read', '{n} previews read')}` +
        (r.missing ? ` · ${t('{n} missing in {folder}', { n: r.missing.toLocaleString(), folder: r.previewFolder })}` : '');
    const msg = r.found < 0 ? t('Detection cancelled')
      : r.stopped ? `${t('Stopped before strip {n}', { n: r.nextStrip + 1 })} · ${found}`
        : found;
    $('#det-status').textContent = msg;
    setBar('#det-bar', r.stopped ? 0 : 1, 1);
    status(msg);
  } catch (err) {
    $('#det-status').textContent = err.message;
    toast(err.message, 'error');
  } finally {
    // Whatever happened, the host's list is the truth: show it again.
    if (liveDetect && state.session) view.setFrames(state.session.frames, []);
    liveDetect = null;
    state.detecting = false;
    refreshEnabled();
  }
}

// Live detection: frames outside the range stay, frames inside are replaced as they are found.
let liveDetect = null;   // { base: frames outside the range, found: detected so far, from, to }

function startLiveDetect(fromStrip, toStrip, replaceFrom = -1) {
  if (!$('#det-live').checked) { liveDetect = null; return; }
  const ll = state.session.roll.lengthLines;
  const base = view.frames.filter((f) => {
    const s = Math.floor(f.leadEdge / ll);
    // on Continue the open frame (from replaceFrom) comes back grown in the results
    if (replaceFrom >= 0 && f.leadEdge >= replaceFrom && f.leadEdge < fromStrip * ll) return false;
    return s < fromStrip || s > toStrip;
  });
  liveDetect = { base, found: [] };
  view.setFrames(base, []);
}

function showLiveDetect(p) {
  if (!liveDetect || !p.frames) return;
  liveDetect.found.length = Math.min(liveDetect.found.length, p.fromIndex);
  liveDetect.found.push(...p.frames);
  const shown = liveDetect.base.concat(liveDetect.found).sort((a, b) => a.leadEdge - b.leadEdge || a.trailEdge - b.trailEdge);
  markSizes(shown);   // red odd-size frames while detecting (the host re-checks at the end)
  view.setFrames(shown, []);
  $('#stat-frames').textContent = shown.length.toLocaleString();
  $('#stat-abnormal').textContent = shown.filter((f) => f.isOversized || f.isUndersized).length.toLocaleString();
  // follow: keep the strip being scanned on screen
  const page = Math.floor(p.stripIndex / Math.max(1, view.perPage));
  if (page !== view.page) view.gotoPage(page);
  scrubber.invalidate();
}

on('detect.progress', (p) => {
  showLiveDetect(p);
  setBar('#det-bar', p.currentStrip, p.totalStrips);
  $('#det-status').textContent =
    `${t('Strip {i} of {n}', { i: p.currentStrip.toLocaleString(), n: p.totalStrips.toLocaleString() })} · ${tn(p.framesFound, '{n} frame', '{n} frames')}` +
    (p.stripsMissing ? ` · ${tn(p.stripsMissing, '{n} preview missing', '{n} previews missing')}` : '');
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
  $('#exp-digits-example').textContent = `${t('e.g.')} ${'1'.padStart(d, '0')}, ${'12'.padStart(d, '0')}`;
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
  const counts = archive ? `\n${tn(r.folders, '{n} folder', '{n} folders')} · ${tn(r.rows, '{n} list row', '{n} list rows')}${short ? ' ' + t('(rows missing)') : ''}` : '';
  el.textContent = (r.error ? r.error : `${t('Frame {i}', { i: index + 1 })} → ${r.path}`) + counts;
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

// Frames that failed in the last export (by position, so later edits don't confuse them).
let failedKeys = [];
function refreshRetry() {
  $('#exp-retry').hidden = !failedKeys.length || state.exporting;
  $('#exp-retry span').textContent = `${t('Re-export failed')} (${failedKeys.length.toLocaleString()})`;
}

async function exportStart(override = null) {
  if (!hasRoll() || state.exporting) return;
  const args = { ...gatherExport(), ...(override || {}) };
  if (args.scope === 'selected' && !args.indices.length) { toast(t('Select frames to export first.'), 'error'); return; }
  $('#exp-failures').replaceChildren();
  setBar('#exp-bar', 0, 1);
  try {
    const r = await call('export.start', args);
    state.exporting = true;
    failedKeys = [];
    refreshRetry();
    state.exportPaused = false;
    $('#exp-pause span').textContent = t('Pause');
    $('#exp-status').textContent = tn(r.jobs, 'Exporting {n} frame to {folder}', 'Exporting {n} frames to {folder}', { folder: r.outputRoot });
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
    t('{done} of {total} · {exported} exported · {skipped} skipped · {failed} failed', {
      done: p.done.toLocaleString(), total: p.total.toLocaleString(),
      exported: exportCounts.exported, skipped: exportCounts.skipped, failed: exportCounts.failed,
    });
  if (p.outcome === 'Exported' && view.frames[p.frameIdx]) {
    view.frames[p.frameIdx].isExported = true;
    view.invalidate();
    scrubber.invalidate();
  }
  if (p.outcome === 'Failed') {
    addFailure(p.frameIdx, p.error);
    if (view.frames[p.frameIdx]) failedKeys.push(frameKey(view.frames[p.frameIdx]));
  }
});

on('export.done', (d) => {
  state.exporting = false;
  refreshEnabled();
  refreshRetry();
  const msg = d.fatal ? `${t('Export stopped')}: ${d.fatal}`
    : `${d.cancelled ? t('Export stopped') : t('Export finished')}: ` +
      t('{exported} exported, {skipped} skipped, {failed} failed in {seconds} s', {
        exported: d.exported, skipped: d.skipped, failed: d.failed, seconds: d.seconds.toFixed(1),
      });
  $('#exp-status').textContent = msg;
  toast(msg, d.failed || d.fatal ? 'error' : 'ok');
  status(msg);
});

function addFailure(frameIdx, error) {
  const li = document.createElement('li');
  li.textContent = `${t('Frame {i}', { i: frameIdx + 1 })}: ${error}`;
  li.title = t('Show this frame');
  li.addEventListener('click', () => { view.select(frameIdx); view.revealFrame(frameIdx); });
  $('#exp-failures').append(li);
}

// ------------------------------------------------------------------ preview window

// Clicking a frame in the main window shows it in the preview window (if open).
let followFrom = -1;   // index the preview itself just selected: don't echo it back
let followTimer = 0;
function followInPreview() {
  if (view.selected.size !== 1) return;
  const idx = [...view.selected][0];
  if (idx === followFrom) { followFrom = -1; return; }
  clearTimeout(followTimer);
  followTimer = setTimeout(() => call('preview.follow', { index: idx }).catch(() => {}), 60);
}

/** Opens (or reuses) the separate preview window on a frame. */
function openFrameModal(idx) {
  if (!view.frames[idx]) return;
  view.select(idx);
  call('preview.open', { index: idx }).catch((e) => toast(e.message, 'error'));
}

on('preview.selected', (d) => {
  if (!view.frames[d.index]) return;
  followFrom = d.index;
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

// Right-click menu (like the Lazarus strip-view popup, plus a few extras).
function showContextMenu(x, y, hit, strip) {
  const m = $('#context-menu');
  const sel = view.selected.size > 0;
  const items = [
    hit >= 0 && { label: t('Frame {i}', { i: hit + 1 }), head: true },
    { label: t('Preview frame'), key: 'previewFrame', icon: 'eye', on: hit >= 0, run: () => openFrameModal(hit) },
    { label: t('Toggle folder marker'), key: 'toggleMarker', icon: 'flag', on: sel, run: () => frameCommand('frames.toggleMarker') },
    { label: t('Select folder section'), key: 'selectSection', icon: 'grid-2x2', on: hit >= 0, run: () => selectSection(hit) },
    { label: t('Delete folder section from marker'), key: 'deleteSection', icon: 'trash-2', on: hit >= 0, danger: true, run: () => deleteSection(hit) },
    'sep',
    { label: t('Clear exported mark'), icon: 'x', on: hit >= 0 && view.frames[hit]?.isExported, run: () => clearExported([hit]) },
    { label: t('Clear exported marks on selected'), key: 'clearExportedSel', icon: 'x', on: sel, run: () => clearExported(selection()) },
    { label: t('Clear all exported marks'), icon: 'x', on: true, run: () => clearExported(null) },
    'sep',
    { label: strip >= 0 ? t('Set detection start here (strip {n})', { n: strip + 1 }) : t('Set detection start here'), icon: 'chevrons-right', on: strip >= 0, run: () => setDetectRange('from', strip) },
    { label: strip >= 0 ? t('Set detection end here (strip {n})', { n: strip + 1 }) : t('Set detection end here'), icon: 'chevrons-left', on: strip >= 0, run: () => setDetectRange('to', strip) },
    'sep',
    { label: t('Clear per-frame settings'), icon: 'rotate-ccw', on: sel, run: () => frameCommand('frames.clearOverrides') },
    { label: t('Delete selected'), key: 'deleteSelected', icon: 'trash-2', on: sel, danger: true, run: () => deleteSelected(true) },
  ].filter(Boolean);
  m.replaceChildren();
  for (const it of items) {
    const li = document.createElement('li');
    if (it === 'sep') { li.className = 'sep'; m.append(li); continue; }
    if (it.head) { li.className = 'ctx-head'; li.textContent = it.label; m.append(li); continue; }
    const b = document.createElement('button');
    b.disabled = !it.on;
    if (it.danger) b.className = 'danger';
    b.innerHTML = icon(it.icon);
    b.append(it.label);
    const keys = it.key ? keymap.keysFor(it.key) : [];
    if (keys.length) { const k = document.createElement('kbd'); k.textContent = keyLabel(keys[0]); b.append(k); }
    b.addEventListener('click', () => { hideContextMenu(); it.run(); });
    li.append(b);
    m.append(li);
  }
  m.hidden = false;
  const vw = $('#viewer').clientWidth, vh = $('#viewer').clientHeight;
  m.style.left = `${Math.max(4, Math.min(x, vw - m.offsetWidth - 8))}px`;
  m.style.top = `${Math.max(4, Math.min(y, vh - m.offsetHeight - 8))}px`;
}

function hideContextMenu() { $('#context-menu').hidden = true; }

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
  nextAbnormal: () => nextAbnormal(0),
  nextSmall: () => nextAbnormal(-1),
  nextBig: () => nextAbnormal(1),
  selectFlagged: () => {
    const idx = view.frames.map((f, i) => (f.isOversized || f.isUndersized ? i : -1)).filter((i) => i >= 0);
    if (!idx.length) { toast(t('No odd-size frames on this roll.')); return; }
    view.setFrames(view.frames, idx);
    refreshFramesPanel();
    scrubber.invalidate();
    status(tn(idx.length, 'Selected {n} flagged frame', 'Selected {n} flagged frames'));
  },
  archiveFromFolders: async () => {
    const r = await run('dialog.archiveFromFolders');
    if (!r) return;
    if (!r.rows.length) { toast(t('No subfolders were found under the selected folder.'), 'error'); return; }
    if ($('#exp-archive').value.trim() && !confirm(tn(r.rows.length, 'Replace the current archive list with {n} row?', 'Replace the current archive list with {n} rows?'))) return;
    $('#exp-archive').value = r.rows.join('\n');
    refreshNamingMode();
    exportChanged();
    toast(tn(r.rows.length, 'Created {n} archive-list row from {folder}', 'Created {n} archive-list rows from {folder}', { folder: r.root }) +
      (r.skipped ? ' · ' + tn(r.skipped, 'skipped {n} folder name containing ";"', 'skipped {n} folder names containing ";"') : ''), 'ok');
  },
  exportRetry: () => {
    const keys = new Set(failedKeys);
    const indices = view.frames.map((f, i) => (keys.has(frameKey(f)) ? i : -1)).filter((i) => i >= 0);
    if (!indices.length) { toast(t('The failed frames are no longer on the roll.'), 'error'); return; }
    return exportStart({ scope: 'selected', indices });
  },
  toggleMarker: () => view.selected.size && frameCommand('frames.toggleMarker'),
  merge: () => view.selected.size && frameTool('frames.merge'),
  combine: () => view.selected.size && frameTool('frames.combine'),
  split: () => view.selected.size && frameTool('frames.split', { parts: Number($('#split-parts').value) || 2 }),
  toggleSuggested: () => {
    const sel = selection();
    if (sel.length !== 1) { toast(t('Select exactly one frame to toggle its suggestion.')); return; }
    return frameCommand('frames.toggleSuggested', { index: sel[0] });
  },
  undo,
  nextMarker: () => jumpMarker(true),
  prevMarker: () => jumpMarker(false),
  toggleAuto: () => { $('#auto-strips').click(); },
  toggleNumbers: () => { $('#strip-numbers').click(); },
  toggleMulti: () => { $('#multi-edit').click(); },
  toggleCw: () => { $('#rotate-cw').click(); },
  selectSection: () => { const i = selection()[0]; if (i !== undefined) selectSection(i); },
  deleteSection: () => { const i = selection()[0]; if (i !== undefined) deleteSection(i); },
  deleteQuick: () => deleteSelected(false),
  closeGaps: () => frameTool('frames.closeGaps'),
  joinClose: () => frameTool('frames.joinClose', { gap: Number($('#join-gap').value) || 0 }),
  expand: expandSelected,
  applyTrim,
  clearExportedSel: () => clearExported(selection()),
  keysReset: () => { keymap.resetAll(); saveKeymap(); renderKeysEditor(); },
  suggest: () => suggest(0),
  suggestStart: () => suggest(-1),
  suggestEnd: () => suggest(1),
  selectSuggested: () => {
    const idx = view.frames.map((f, i) => (f.isSuggested ? i : -1)).filter((i) => i >= 0);
    if (!idx.length) { toast(t('No suggested folder starts.')); return; }
    view.setFrames(view.frames, idx);
    refreshFramesPanel();
    scrubber.invalidate();
  },
  acceptSuggested: () => markerTool('markers.acceptSuggested', {}, 'Turned into folder markers'),
  clearSuggested: () => markerTool('markers.clearSuggested', {}, 'Cleared suggestions'),
  clearSelectedSuggested: () => markerTool('markers.clearSuggested', { selectedOnly: true, indices: selection() }, 'Cleared selected suggestions'),
  clearEveryBack: () => markerTool('markers.clearSuggestedEvery', { anchor: anchor(), direction: -1, every: Number($('#sug-every').value) || 2 }, 'Cleared suggestions'),
  clearEveryFwd: () => markerTool('markers.clearSuggestedEvery', { anchor: anchor(), direction: 1, every: Number($('#sug-every').value) || 2 }, 'Cleared suggestions'),
  clearMarkersBack: () => markerTool('markers.clearToward', { anchor: anchor(), direction: -1 }, 'Cleared markers'),
  clearMarkersFwd: () => markerTool('markers.clearToward', { anchor: anchor(), direction: 1 }, 'Cleared markers'),
  theme: async () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    applyTheme(next);
    await call('app.setTheme', { theme: next }).catch(() => {});
  },
  previewFrame: () => { const i = selection()[0]; if (i !== undefined) openFrameModal(i); },
  deleteSelected,
  clearMarkers: async () => {
    if (!confirm(t('Remove every folder marker on this roll?'))) return;
    applyFrames(await run('frames.clearMarkers'));
  },
  applyOverride: () => frameCommand('frames.setOverride', {
    rotation: Number($('#ovr-rotation').value), flipH: $('#ovr-mirror').checked, negative: $('#ovr-negative').checked,
  }),
  clearOverrides: () => frameCommand('frames.clearOverrides'),
  clearTone: async () => {
    await frameCommand('frames.clearTone');
    if (toneTarget === 'sel') loadSelectedTone();
    toast(t('Selected frames follow the global tone again'));
  },
  selectOwnTone: () => {
    const idx = view.frames.map((f, i) => (hasTone(f) ? i : -1)).filter((i) => i >= 0);
    if (!idx.length) { toast(t('No frames have their own tone.')); return; }
    view.setFrames(view.frames, idx);
    refreshFramesPanel();
    scrubber.invalidate();
    toneSelectionChanged();
  },
  detect,
  detectCancel: () => { detectResume = null; return call('detect.cancel'); },
  detectPause: async () => {
    if (!state.detecting) return;
    state.detectPaused = !state.detectPaused;
    await call(state.detectPaused ? 'detect.pause' : 'detect.resume').catch(() => {});
    $('#det-pause span').textContent = state.detectPaused ? t('Resume') : t('Pause');
    if (state.detectPaused) $('#det-status').textContent = `${t('Paused')} · ${$('#det-status').textContent}`;
  },
  detectStop: () => state.detecting && call('detect.stop').catch(() => {}),
  detectContinue,
  detectDefaults: () => {
    for (const [id, v] of [['#det-minrun', 0], ['#det-maxlen', 0], ['#det-touchw', 0], ['#det-osw', 0], ['#det-osl', 0]]) $(id).value = v;
    $('#det-touchl').value = hasRoll() ? Math.floor(state.session.roll.lengthLines / 64) : 64;
    $('#det-auto').checked = $('#det-invert').checked = false;
    saveDetectOptions();
    sendPanels(true);
    toast(t('Detection settings back to defaults'));
  },
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
    toast(tn(r.created, 'Created {n} folder in {folder}', 'Created {n} folders in {folder}', { folder: r.root }), 'ok');
  },
  exportPause: async () => {
    state.exportPaused = !state.exportPaused;
    await call(state.exportPaused ? 'export.pause' : 'export.resume');
    $('#exp-pause span').textContent = state.exportPaused ? t('Resume') : t('Pause');
  },
  exportStop: () => call('export.cancel'),
  shortcuts: () => { renderKeysEditor(); $('#shortcuts-modal').hidden = false; },
  report: () => { $('#report-modal').hidden = false; refreshReport(); },
  reportClose: () => { $('#report-modal').hidden = true; },
  reportRefresh: () => refreshReport(),
  reportMfReset: () => { $('#rep-mf').value = ''; reportMfTyped = false; refreshReport(true); },
  reportCopy: async () => {
    const r = await run('report.copy', reportArgs());
    if (r?.error) { toast(r.error, 'error'); return; }
    toast(tn(r.rows, 'Copied {n} row — paste it into Excel', 'Copied {n} rows — paste them into Excel') +
      (r.normalized ? ' · ' + t('some values were adjusted for Excel') : ''), 'ok');
  },
  // F1 opens the manual at the topic of the panel in front (or the start when no roll is open).
  help: () => {
    const tab = $('.rail [aria-selected=true]')?.dataset.tab;
    const topic = !hasRoll() ? 'start' : { frames: 'frames', detect: 'detect', process: 'adjust', export: 'export', notes: 'notes' }[tab] || 'start';
    call('help.open', { topic }).catch((e) => toast(e.message, 'error'));
  },
  langMenu: () => {
    const m = $('#lang-menu');
    if (!m.hidden) { m.hidden = true; return; }
    const r = $('[data-cmd=langMenu]').getBoundingClientRect();
    m.hidden = false;
    m.style.top = `${r.bottom + 4}px`;
    m.style.left = `${Math.max(8, r.right - m.offsetWidth)}px`;
  },
  langEn: () => setLanguage('en'),
  langPl: () => setLanguage('pl'),
  langFolder: async () => {
    $('#lang-menu').hidden = true;
    const folder = await run('i18n.openFolder');
    if (folder) toast(t('Edit pl.json in {folder}, then switch the language again (or restart) to see your changes.', { folder }), 'ok');
  },
  shortcutsClose: () => { $('#shortcuts-modal').hidden = true; },
};

document.addEventListener('click', (e) => {
  if (e.target.id === 'shortcuts-modal') { commands.shortcutsClose(); return; }
  if (e.target.id === 'report-modal') { commands.reportClose(); return; }
  const el = e.target.closest('[data-cmd]');
  if (!el || el.disabled) return;
  const fn = commands[el.dataset.cmd];
  if (fn) Promise.resolve(fn()).catch(() => {});
});

// ------------------------------------------------------------------ keyboard


// ------------------------------------------------------------------ configurable shortcuts

const keymap = new Keymap();
let capturing = null;   // command id waiting for a new key in the shortcuts sheet

function saveKeymap() { call('settings.keymap', { bindings: keymap.overrides }).catch((e) => toast(e.message, 'error')); }

function renderKeysEditor() {
  const box = $('#keys-editor');
  box.replaceChildren();
  let lastSection = '';
  for (const c of COMMANDS) {
    if (c.section !== lastSection) {
      const h = document.createElement('h4');
      h.textContent = t(c.section);
      box.append(h);
      lastSection = c.section;
    }
    const row = document.createElement('div');
    row.className = 'key-row';
    const label = document.createElement('span');
    label.className = 'key-label';
    label.textContent = t(c.label);
    const chips = document.createElement('span');
    chips.className = 'key-chips';
    for (const k of keymap.keysFor(c.id)) {
      const chip = document.createElement('span');
      chip.className = 'key-chip';
      chip.textContent = keyLabel(k);
      const x = document.createElement('button');
      x.textContent = '×';
      x.title = t('Remove this key');
      x.addEventListener('click', () => { keymap.unbind(c.id, k); saveKeymap(); renderKeysEditor(); });
      chip.append(x);
      chips.append(chip);
    }
    const add = document.createElement('button');
    add.className = 'key-add' + (capturing === c.id ? ' capturing' : '');
    add.textContent = capturing === c.id ? t('Press a key… (Esc cancels)') : '+';
    add.addEventListener('click', () => { capturing = c.id; renderKeysEditor(); });
    chips.append(add);
    row.append(label, chips);
    box.append(row);
  }
}

function typing(e) {
  return e.target.closest('input, textarea, select, [contenteditable="true"], .toastui-editor-defaultUI');
}

document.addEventListener('keydown', (e) => {
  // 1. capturing a new shortcut in the sheet
  if (capturing) {
    e.preventDefault();
    if (e.key === 'Escape') { capturing = null; renderKeysEditor(); return; }
    const combo = comboFromEvent(e);
    if (!combo) return;
    const moved = keymap.bind(capturing, combo);
    if (moved) toast(t('{key} moved from "{command}"', { key: keyLabel(combo), command: t(moved) }));
    capturing = null;
    saveKeymap();
    renderKeysEditor();
    return;
  }
  // 2. the report sheet is open: Escape closes it
  if (!$('#report-modal').hidden) {
    if (e.key === 'Escape') { e.preventDefault(); commands.reportClose(); }
    return;
  }
  // 2b. the shortcuts sheet is open
  if (!$('#shortcuts-modal').hidden) {
    if (e.key === 'Escape') { e.preventDefault(); commands.shortcutsClose(); }
    return;
  }
  // 3. Escape always cancels a drag / clears the selection / closes the menu
  if (e.key === 'Escape' && !typing(e) && hasRoll()) {
    e.preventDefault();
    if (!$('#context-menu').hidden) hideContextMenu();
    else if (!view.cancelDrag()) view.selectNone();
    return;
  }
  // 4. bound commands (Ctrl shortcuts work while typing, single keys do not)
  const id = keymap.match(e, 'main');
  if (!id) return;
  if (typing(e) && !(e.ctrlKey || e.metaKey)) return;
  const fn = commands[id];
  if (!fn) return;
  const noRoll = ['open', 'shortcuts', 'theme', 'help'];
  if (!hasRoll() && !noRoll.includes(id)) return;
  e.preventDefault();
  Promise.resolve(fn()).catch(() => {});
});

// ------------------------------------------------------------------ host events

// ------------------------------------------------------------------ handover report

let reportMfTyped = false;   // the microfilm field was edited by hand
function reportArgs() {
  return { microfilm: reportMfTyped ? $('#rep-mf').value.trim() : '', headers: $('#rep-headers').checked };
}

async function refreshReport(resetMf = false) {
  if (!hasRoll()) return;
  const r = await run('report.build', resetMf ? { microfilm: '' } : reportArgs()).catch(() => null);
  if (!r) return;
  if (!reportMfTyped) $('#rep-mf').value = r.microfilm || '';
  const head = $('#rep-table thead'), body = $('#rep-table tbody');
  body.replaceChildren();
  $('#rep-table tfoot')?.remove();
  if (r.error) {
    head.replaceChildren();
    const tr = document.createElement('tr'), td = document.createElement('td');
    td.className = 'rep-error'; td.textContent = r.error; tr.append(td); body.append(tr);
    $('#rep-totals').textContent = ''; $('#rep-warn').textContent = '';
    return;
  }
  const hr = document.createElement('tr');
  for (const h of r.headers) { const th = document.createElement('th'); th.textContent = h; hr.append(th); }
  head.replaceChildren(hr);
  for (const row of r.rows) {
    const tr = document.createElement('tr');
    if (row.missingFiles) { tr.className = 'missing'; tr.title = tn(row.missingFiles, '{n} file not found on disk', '{n} files not found on disk'); }
    const cells = [
      [row.identifier, 'id'], [row.signatures, ''], [row.microfilm, ''], [row.units.toLocaleString(), 'num'],
      [row.files.toLocaleString(), 'num'], [row.gb, 'num'], [row.directory, 'dir'],
    ];
    for (const [v, cls] of cells) { const td = document.createElement('td'); td.textContent = v; if (cls) td.className = cls; tr.append(td); }
    body.append(tr);
  }
  const foot = document.createElement('tfoot'), ft = document.createElement('tr');
  for (const [v, cls] of [[t('Total'), 'id'], ['', ''], ['', ''], [r.units.toLocaleString(), 'num'], [r.files.toLocaleString(), 'num'], [r.gb, 'num'], ['', '']]) {
    const td = document.createElement('td'); td.textContent = v; if (cls) td.className = cls; ft.append(td);
  }
  foot.append(ft);
  $('#rep-table').append(foot);
  $('#rep-totals').textContent = `${tn(r.rows.length, '{n} row', '{n} rows')} · ${tn(r.files, '{n} file', '{n} files')} · ${r.gb} GB`;
  const warn = [];
  if (r.missingFiles) warn.push(tn(r.missingFiles, '{n} exported file is missing on disk (not exported yet?)', '{n} exported files are missing on disk (not exported yet?)'));
  if (r.framesWithoutRow) warn.push(tn(r.framesWithoutRow, '{n} frame has no archive-list row', '{n} frames have no archive-list row'));
  $('#rep-warn').textContent = warn.join(' · ');
}
$('#rep-mf').addEventListener('input', () => { reportMfTyped = true; });
$('#rep-mf').addEventListener('change', () => refreshReport());
$('#rep-mf').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); refreshReport(); } });

async function setLanguage(lang) {
  $('#lang-menu').hidden = true;
  await flushNotes();
  await flushExportSettings();
  await run('app.setLanguage', { lang });
}
// Both windows reload in the new language; the roll stays open in the host.
on('lang.changed', () => location.reload());
document.addEventListener('pointerdown', (e) => {
  if (!e.target.closest('#lang-menu, [data-cmd=langMenu]')) $('#lang-menu').hidden = true;
});

on('project.dirty', setDirty);
on('toast', (m) => toast(m));
on('keymap.changed', (b) => { keymap.setOverrides(b); if (!$('#shortcuts-modal').hidden) renderKeysEditor(); });
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
  await initI18n();
  $('#lang-code').textContent = currentLanguage().toUpperCase();
  refreshEnabled();
  if (!inHost) {
    status(t('Open this page through StriplightPRO.exe — it needs the desktop host.'));
    return;
  }
  const info = await run('app.init');
  state.settings = info.settings;
  state.smoke = !!info.smoke;
  state.toneMethods = info.toneMethods;
  $('#tone-method').replaceChildren(...info.toneMethods.map((name, i) => new Option(t(name), String(i))));
  $('#status-engine').textContent = `v${info.version} · ${info.turboJpeg}`;
  document.title = `Striplight PRO ${info.version}`;

  const s = info.settings;
  keymap.setOverrides(s.keyBindings || {});
  $('#strips-per-row').value = s.stripsPerRow;
  $('#rotate-cw').checked = s.rotateCw;
  $('#zoom').value = Math.round(s.zoom * 100);
  paintRange($('#zoom'));
  $('#zoom-out').textContent = `${Math.round(s.zoom * 100)}%`;
  $('#auto-strips').checked = s.autoStrips;
  setFill(s.frameFillOpacity ?? 35, false);
  $('#strip-numbers').checked = s.showStripNumbers;
  loadSizeRules(s);
  $('#multi-edit').checked = view.multiEdit = !!s.multiEdit;
  applyTheme(s.theme || 'dark');
  view.setView({ stripsPerRow: s.stripsPerRow, zoom: s.zoom, fillOpacity: s.frameFillOpacity, rotateCw: s.rotateCw, autoStrips: s.autoStrips, showStripNumbers: s.showStripNumbers });
  applyRanges(0, true);
  renderRecent();
  if (info.session) applySession(info.session);
  if (state.smoke) call('app.ready').catch(() => {});
}

init().catch((err) => status(err.message));
