// Frame preview window (preview.html), the counterpart of the Lazarus "Frame Preview" form.
// Shows one frame exactly as export builds it. Wheel zooms around the cursor, drag pans,
// X/C step through frames, G/F jump between folder markers, R/M/N change this frame's
// orientation, T keeps the window on top.

import { call, on } from './bridge.js';
import { hydrateIcons } from './icons.js';

hydrateIcons();

const $ = (s) => document.querySelector(s);
const view = $('#pv-view');
const img = $('#pv-img');

const st = {
  index: Number(new URLSearchParams(location.search).get('i')) || 0,
  info: null,
  scale: 1, tx: 0, ty: 0,
  mode: 'fit',            // 'fit' | 'one' | 'free'
  fullQuality: false,
  topmost: false,
  step: 1,
  loadedOnce: false,
};

window.addEventListener('error', (e) => call('app.log', { message: `preview: ${e.message}` }).catch(() => {}));

// ------------------------------------------------------------------ loading

async function load(index, { keepView = false } = {}) {
  const info = await call('preview.frame', { index }).catch((e) => { message(e.message); return null; });
  if (!info) return;
  st.index = info.index;
  st.info = info;
  const s = info.settings;
  if (!st.loadedOnce) {
    st.fullQuality = s.fullQuality;
    st.topmost = s.topmost;
    st.step = s.step;
    $('#pv-step').value = s.step;
    document.documentElement.dataset.theme = s.theme;
  }
  render(info);
  if (!keepView && st.mode === 'free') st.mode = 'fit';

  const f = info.frame;
  const q = st.fullQuality || st.mode === 'one' ? 'full' : 'fit';
  const src = `https://img.striplight/frame/${info.index}?v=${info.imageVersion}` +
    `&g=${f.leadEdge}:${f.trailEdge}:${f.leftEdge}:${f.rightEdge}:${info.rotation}:${info.mirror}:${info.negative}&q=${q}`;
  if (img.dataset.src === src) return;
  img.dataset.src = src;
  message('Building frame…', true);
  img.onload = () => {
    message('');
    applyMode();
    if (!st.loadedOnce) { st.loadedOnce = true; }
    call('preview.loaded', { index: info.index, ok: true }).catch(() => {});
  };
  img.onerror = () => {
    message('Could not build this frame (missing strips or preview).');
    call('preview.loaded', { index: info.index, ok: false }).catch(() => {});
  };
  img.src = src;
}

function render(info) {
  const f = info.frame;
  $('#pv-title').textContent = `Frame ${(info.index + 1).toLocaleString()} of ${info.count.toLocaleString()}`;
  document.title = `Frame ${info.index + 1} — Striplight PRO`;
  $('#pv-size').textContent = `${info.width} × ${info.height}`;
  $('#pv-folder').hidden = !f.isMarker;
  $('#pv-folder').textContent = `Folder ${info.volume} start`;
  $('#pv-own').hidden = !info.ownOrientation;
  $('#pv-path').textContent = info.path ? `Folder ${info.volume}, file ${info.fileNo} → ${info.path}` : info.pathError;
  renderTarget(info);
  press('#pv-mirror', info.mirror);
  press('#pv-negative', info.negative);
  press('#pv-marker', f.isMarker);
  press('#pv-quality', st.fullQuality);
  press('#pv-topmost', st.topmost);
}

/** The target banner: folder number, target folder segments and file name, big enough to compare. */
function renderTarget(info) {
  const t = info.target, box = $('#pv-target');
  box.classList.toggle('start', !!info.frame.isMarker);
  box.classList.toggle('missing', !!info.pathError);
  $('#pv-target-num').textContent = info.volume.toLocaleString();
  $('#pv-target-of').textContent = `of ${t.folderCount.toLocaleString()}` + (info.frame.isMarker ? ' · starts here' : '');
  const segs = $('#pv-segments');
  segs.replaceChildren();
  if (info.pathError) {
    segs.textContent = info.pathError;
    $('#pv-file').textContent = t.namingMode === 1 ? `Archive list has ${t.rowCount} row${t.rowCount === 1 ? '' : 's'}` : '';
    return;
  }
  if (!t.segments.length) {
    const none = document.createElement('span');
    none.className = 'seg-none';
    none.textContent = 'output folder itself';
    segs.append(none);
  }
  t.segments.forEach((part, k) => {
    if (k) { const sep = document.createElement('span'); sep.className = 'seg-sep'; sep.textContent = '›'; segs.append(sep); }
    const el = document.createElement('span');
    el.className = 'seg-part';
    el.textContent = part;
    segs.append(el);
  });
  $('#pv-file').textContent = t.fileName;
}

function toggleTarget() {
  const hidden = document.body.classList.toggle('no-target');
  $('#pv-target').hidden = hidden;
  try { localStorage.setItem('striplight.preview.target', hidden ? 'off' : 'on'); } catch { /* storage unavailable */ }
  applyMode();
}
try { if (localStorage.getItem('striplight.preview.target') === 'off') { document.body.classList.add('no-target'); $('#pv-target').hidden = true; } } catch { /* ignore */ }

function press(sel, on) { $(sel).setAttribute('aria-pressed', String(!!on)); }

function message(text, spinner = false) {
  $('#pv-msg').hidden = !text;
  $('#pv-msg-text').textContent = text;
  $('#pv-msg .spinner').hidden = !spinner;
}

// ------------------------------------------------------------------ zoom & pan

function fullWidth() { return st.info ? st.info.width : img.naturalWidth; }

/** Zoom in percent of full-resolution pixels (the image may be a downscaled render). */
function zoomPercent() { return st.scale * (img.naturalWidth / Math.max(1, fullWidth())) * 100; }

function apply() {
  img.style.transform = `translate(${st.tx}px, ${st.ty}px) scale(${st.scale})`;
  img.classList.toggle('pixelated', zoomPercent() >= 200);
  $('#pv-zoom').textContent = st.mode === 'fit' ? `Fit ${Math.round(zoomPercent())}%` : `${Math.round(zoomPercent())}%`;
  press('#pv-fit', st.mode === 'fit');
  press('#pv-one', st.mode === 'one');
}

function center() {
  st.tx = (view.clientWidth - img.naturalWidth * st.scale) / 2;
  st.ty = (view.clientHeight - img.naturalHeight * st.scale) / 2;
}

function applyMode() {
  if (!img.naturalWidth) return;
  if (st.mode === 'fit') {
    st.scale = Math.min((view.clientWidth - 32) / img.naturalWidth, (view.clientHeight - 32) / img.naturalHeight);
    center();
  } else if (st.mode === 'one') {
    st.scale = fullWidth() / img.naturalWidth; // 1 screen pixel per full-resolution pixel
    center();
  }
  apply();
}

function zoomAt(factor, cx = view.clientWidth / 2, cy = view.clientHeight / 2) {
  if (!img.naturalWidth) return;
  const min = 0.02, max = 32;
  const next = Math.max(min, Math.min(max, st.scale * factor));
  // keep the image point under the cursor where it is
  st.tx = cx - (cx - st.tx) * (next / st.scale);
  st.ty = cy - (cy - st.ty) * (next / st.scale);
  st.scale = next;
  st.mode = 'free';
  apply();
}

view.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = view.getBoundingClientRect();
  zoomAt(e.deltaY < 0 ? 1.25 : 1 / 1.25, e.clientX - r.left, e.clientY - r.top);
}, { passive: false });

let pan = null;
view.addEventListener('pointerdown', (e) => {
  if (e.button !== 0 && e.button !== 1) return;
  e.preventDefault();
  view.setPointerCapture(e.pointerId);
  pan = { x: e.clientX, y: e.clientY, tx: st.tx, ty: st.ty };
  view.classList.add('panning');
});
view.addEventListener('pointermove', (e) => {
  if (!pan) return;
  st.tx = pan.tx + (e.clientX - pan.x);
  st.ty = pan.ty + (e.clientY - pan.y);
  if (st.mode !== 'free' && (Math.abs(e.clientX - pan.x) > 3 || Math.abs(e.clientY - pan.y) > 3)) st.mode = 'free';
  apply();
});
view.addEventListener('pointerup', () => { pan = null; view.classList.remove('panning'); });
view.addEventListener('dblclick', () => setMode(st.mode === 'fit' ? 'one' : 'fit'));
new ResizeObserver(() => { if (st.mode !== 'free') applyMode(); }).observe(view);

function setMode(mode) {
  st.mode = mode;
  if (mode === 'one' && !st.fullQuality && !img.dataset.src?.endsWith('q=full')) load(st.index, { keepView: true });
  else applyMode();
}

// ------------------------------------------------------------------ actions

function go(index) {
  if (!st.info) return;
  const i = Math.max(0, Math.min(st.info.count - 1, index));
  if (i === st.index) return;
  call('preview.select', { index: i }).catch(() => {});
  load(i, { keepView: true });
}

function goMarker(forward) {
  const target = forward ? st.info?.nextMarker : st.info?.prevMarker;
  if (target === undefined || target < 0) return;
  go(target);
}

async function orient(args) {
  const info = await call('preview.orient', { index: st.index, source: 'preview', ...args }).catch(() => null);
  if (info) load(info.index, { keepView: true });
}

async function toggleMarker() {
  await call('frames.toggleMarker', { indices: [st.index], source: 'preview' }).catch(() => null);
  load(st.index, { keepView: true });
}

function saveSettings() {
  call('preview.settings', { topmost: st.topmost, step: st.step, fullQuality: st.fullQuality }).catch(() => {});
}

const actions = {
  prev: () => go(st.index - st.step),
  next: () => go(st.index + st.step),
  prevMarker: () => goMarker(false),
  nextMarker: () => goMarker(true),
  rotL: () => orient({ rotate: -90 }),
  rotR: () => orient({ rotate: 90 }),
  mirror: () => orient({ mirror: true }),
  negative: () => orient({ negative: true }),
  marker: toggleMarker,
  zoomIn: () => zoomAt(1.25),
  zoomOut: () => zoomAt(1 / 1.25),
  fit: () => setMode('fit'),
  one: () => setMode('one'),
  quality: () => { st.fullQuality = !st.fullQuality; saveSettings(); load(st.index, { keepView: true }); },
  topmost: () => { st.topmost = !st.topmost; press('#pv-topmost', st.topmost); saveSettings(); },
};

document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-pv]');
  if (b) actions[b.dataset.pv]?.();
});

$('#pv-step').addEventListener('change', (e) => {
  st.step = Math.max(1, Number(e.target.value) || 1);
  e.target.value = st.step;
  saveSettings();
});

document.addEventListener('keydown', (e) => {
  if (e.target.closest('input')) { if (e.key === 'Escape') e.target.blur(); return; }
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  const k = e.key.toLowerCase();
  const map = {
    x: actions.prev, arrowleft: actions.prev, pageup: actions.prev,
    c: actions.next, arrowright: actions.next, pagedown: actions.next,
    g: actions.prevMarker, f: actions.nextMarker,
    r: e.shiftKey ? actions.rotL : actions.rotR,
    m: actions.mirror, n: actions.negative, a: actions.marker,
    '+': actions.zoomIn, '=': actions.zoomIn, '-': actions.zoomOut,
    '0': actions.fit, ' ': actions.fit, '1': actions.one,
    q: actions.quality, t: actions.topmost, i: toggleTarget,
    home: () => go(0), end: () => go((st.info?.count ?? 1) - 1),
    escape: () => call('preview.close').catch(() => {}),
  };
  const fn = map[k];
  if (fn) { e.preventDefault(); fn(); }
});

// ------------------------------------------------------------------ host events

on('preview.show', (d) => load(d.index, { keepView: true }));
on('frames.changed', (d) => { if (d?.source !== 'preview') load(st.index, { keepView: true }); });
on('theme.changed', (d) => { document.documentElement.dataset.theme = d.theme; });
// Tone or orientation changed in the main window: rebuild this frame (keeps zoom and position).
on('images.changed', () => load(st.index, { keepView: true }));
on('export.changed', () => load(st.index, { keepView: true })); // naming or archive list edited

load(st.index);
