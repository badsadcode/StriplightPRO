// Roll overview under the strip view: one tick per folder marker, odd-size frame and
// exported frame along the whole roll, with the visible page highlighted. Click or
// drag to jump.

const css = getComputedStyle(document.documentElement);
const C = (n) => css.getPropertyValue(n).trim();

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
    canvas.addEventListener('pointermove', (e) => { if (e.buttons & 1) seek(e); });
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
    ctx.fillStyle = 'rgba(255,255,255,0.05)';
    ctx.fillRect(pad, h / 2 - 2, tw, 4);

    // frames: faint base ticks, then highlights
    ctx.fillStyle = 'rgba(255,255,255,0.10)';
    for (const f of v.frames) ctx.fillRect(x(f.leadEdge), h / 2 - 5, 1, 10);
    ctx.fillStyle = C('--f-exported');
    for (const f of v.frames) if (f.isExported) ctx.fillRect(x(f.leadEdge), h - 7, Math.max(1, x(f.trailEdge) - x(f.leadEdge)), 2);
    ctx.fillStyle = C('--f-abnormal');
    for (const f of v.frames) if (f.isOversized || f.isUndersized) ctx.fillRect(x(f.leadEdge) - 1, h / 2 - 6, 3, 12);
    ctx.fillStyle = C('--f-marker');
    for (const f of v.frames) if (f.isMarker) ctx.fillRect(x(f.leadEdge) - 1, 5, 2, h - 10);
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
