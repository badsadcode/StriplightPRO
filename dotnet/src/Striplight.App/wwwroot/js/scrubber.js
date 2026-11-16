// Roll overview under the strip view: one tick per folder marker, odd-size frame and
// exported frame along the whole roll, with the visible page highlighted. Click or
// drag to jump.

import { t } from './i18n.js';

const C = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();

export class Scrubber {
  constructor(canvas, view) {
    this.canvas = canvas;
    this.view = view;
    this.ctx = canvas.getContext('2d');
    this.pending = false;
    new ResizeObserver(() => this.draw()).observe(canvas);
    const seek = (e) => {
      const r = canvas.getBoundingClientRect();
      const t = Math.max(0, Math.min(1, (e.clientX - r.left - 8) / Math.max(1, r.width - 16)));
      const strip = Math.floor(t * view.stripCount);
      view.gotoPage(Math.floor(strip / Math.max(1, view.perPage)));
    };
    canvas.addEventListener('pointerdown', (e) => { canvas.setPointerCapture(e.pointerId); seek(e); });
    canvas.addEventListener('pointermove', (e) => { if (e.buttons & 1) seek(e); this.hover(e); });
    canvas.addEventListener('pointerleave', () => { if (this.tip) this.tip.hidden = true; });
  }

  /** Tooltip: strip, the frame there, its folder number and what it is. */
  hover(e) {
    const v = this.view;
    if (!v.roll || !v.stripCount) return;
    if (!this.tip) {
      this.tip = document.createElement('div');
      this.tip.className = 'scrub-tip';
      this.canvas.parentElement.append(this.tip);
    }
    const r = this.canvas.getBoundingClientRect();
    const tpos = Math.max(0, Math.min(1, (e.clientX - r.left - 8) / Math.max(1, r.width - 16)));
    const total = v.stripCount * v.roll.lengthLines, lead = tpos * total;
    const strip = Math.min(v.stripCount - 1, Math.floor(lead / v.roll.lengthLines));
    // the frame under the pointer, or the nearest one
    const fr = v.frames;
    let lo = 0, hi = fr.length - 1, best = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (fr[mid].leadEdge <= lead) { best = mid; lo = mid + 1; } else hi = mid - 1; }
    if (best < 0 || (best + 1 < fr.length && lead - fr[best].trailEdge > fr[best + 1].leadEdge - lead)) best = Math.min(fr.length - 1, best + 1);
    const parts = [t('Strip {n}', { n: (strip + 1).toLocaleString() })];
    if (best >= 0) {
      const f = fr[best];
      let folder = 0;
      for (let i = 0; i <= best; i++) if (fr[i].isMarker) folder++;
      parts.push(t('Frame {i}', { i: (best + 1).toLocaleString() }));
      if (folder) parts.push(t('folder {n}', { n: folder.toLocaleString() }));
      if (f.isMarker) parts.push(t('Folder start'));
      if (f.isSuggested) parts.push(t('Suggested'));
      if (f.isOversized || f.isUndersized) parts.push(t('Odd size'));
      if (f.isExported) parts.push(t('Exported'));
    }
    this.tip.textContent = parts.join(' · ');
    this.tip.hidden = false;
    const pr = this.canvas.parentElement.getBoundingClientRect();
    const x = e.clientX - pr.left;
    this.tip.style.left = `${Math.max(4, Math.min(pr.width - this.tip.offsetWidth - 4, x - this.tip.offsetWidth / 2))}px`;
    this.tip.style.top = `${r.top - pr.top - this.tip.offsetHeight - 6}px`;
  }

  invalidate() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => { this.pending = false; this.draw(); });
  }

  draw() {
    const v = this.view, cv = this.canvas, dpr = window.devicePixelRatio || 1;
    const w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return;
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
    const ctx = this.ctx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (!v.roll || !v.stripCount) return;

    const pad = 8, tw = w - pad * 2, total = v.stripCount * v.roll.lengthLines;
    const x = (lead) => pad + (lead / total) * tw;

    // track
    ctx.fillStyle = document.documentElement.dataset.theme === 'light' ? 'rgba(15,23,42,0.07)' : 'rgba(255,255,255,0.05)';
    ctx.fillRect(pad, h / 2 - 2, tw, 4);

    // frames: faint base ticks, then highlights
    ctx.fillStyle = document.documentElement.dataset.theme === 'light' ? 'rgba(15,23,42,0.16)' : 'rgba(255,255,255,0.10)';
    for (const f of v.frames) ctx.fillRect(x(f.leadEdge), h / 2 - 5, 1, 10);
    ctx.fillStyle = C('--f-exported');
    for (const f of v.frames) if (f.isExported) ctx.fillRect(x(f.leadEdge), h - 7, Math.max(1, x(f.trailEdge) - x(f.leadEdge)), 2);
    ctx.fillStyle = C('--f-abnormal');
    for (const f of v.frames) if (f.isOversized || f.isUndersized) ctx.fillRect(x(f.leadEdge) - 1, h / 2 - 6, 3, 12);
    // Thousands of markers would turn the bar solid: draw them thinner and fainter when dense.
    const markers = v.frames.filter((f) => f.isMarker);
    const dense = markers.length > tw / 4;
    ctx.fillStyle = C('--f-marker');
    ctx.globalAlpha = dense ? 0.45 : 1;
    for (const f of markers) ctx.fillRect(x(f.leadEdge) - (dense ? 0 : 1), 5, dense ? 1 : 2, h - 10);
    ctx.globalAlpha = 1;
    // Suggested folder starts (purple): shorter than the yellow markers, so both stay readable.
    const suggested = v.frames.filter((f) => f.isSuggested && !f.isMarker);
    const sDense = suggested.length > tw / 4;
    ctx.fillStyle = C('--f-suggested');
    ctx.globalAlpha = sDense ? 0.5 : 1;
    for (const f of suggested) ctx.fillRect(x(f.leadEdge) - (sDense ? 0 : 1), 9, sDense ? 1 : 2, h - 18);
    ctx.globalAlpha = 1;
    ctx.fillStyle = C('--f-selected');
    for (const i of v.selected) { const f = v.frames[i]; if (f) ctx.fillRect(x(f.leadEdge) - 1, h / 2 - 7, 3, 14); }

    // visible page window
    const a = x(v.firstStrip * v.roll.lengthLines);
    const b = x((v.firstStrip + v.pageStripCount) * v.roll.lengthLines);
    ctx.fillStyle = 'rgba(245,165,36,0.14)';
    ctx.strokeStyle = 'rgba(245,165,36,0.85)';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.roundRect(a, 3, Math.max(4, b - a), h - 6, 5);
    ctx.fill();
    ctx.stroke();
  }
}
