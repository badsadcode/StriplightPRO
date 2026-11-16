// Canvas strip view — the paged light table (port of lazarus/uStripView.pas).
//
// Geometry: every strip is shown turned upright. Along the film (lead → trail) runs
// left → right on screen; across the film (LeftEdge → RightEdge) runs top → bottom.
// Strips sit edge to edge in rows; a page is as many rows as fit the canvas height.

const BASE_STRIP_W = 160;   // strip width on screen at zoom 1.0
const HANDLE = 6;           // edge grab distance, px
const DRAG_START = 4;       // px before a press becomes a drag

const css = getComputedStyle(document.documentElement);
const COLOR = {
  normal: css.getPropertyValue('--f-normal').trim(),
  abnormal: css.getPropertyValue('--f-abnormal').trim(),
  marker: css.getPropertyValue('--f-marker').trim(),
  selected: css.getPropertyValue('--f-selected').trim(),
  suggested: css.getPropertyValue('--f-suggested').trim(),
  perframe: css.getPropertyValue('--f-perframe').trim(),
  exported: css.getPropertyValue('--f-exported').trim(),
  accent: css.getPropertyValue('--accent').trim(),
};

export class StripView {
  constructor(canvas, callbacks) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.cb = callbacks;

    this.roll = null;
    this.frames = [];
    this.selected = new Set();
    this.anchor = -1;
    this.page = 0;
    this.stripsPerRow = 4;
    this.zoom = 1;
    this.fillOpacity = 35;
    this.imageVersion = 1;
    this.images = new Map();      // stripIdx -> { img, version, state }
    this.segments = [];           // hit-test rectangles of the frames drawn on this page
    this.drag = null;
    this.rafPending = false;

    new ResizeObserver(() => this.resize()).observe(canvas);
    canvas.addEventListener('pointerdown', (e) => this.onPointerDown(e));
    canvas.addEventListener('pointermove', (e) => this.onPointerMove(e));
    canvas.addEventListener('pointerup', (e) => this.onPointerUp(e));
    canvas.addEventListener('dblclick', (e) => this.onDoubleClick(e));
    canvas.addEventListener('contextmenu', (e) => this.onContextMenu(e));
    canvas.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
    canvas.addEventListener('pointerleave', () => this.cb.onHover?.(''));
  }

  // ------------------------------------------------------------------ state

  setRoll(roll, frames) {
    this.roll = roll;
    this.frames = frames || [];
    this.selected.clear();
    this.anchor = -1;
    this.page = 0;
    this.images.clear();
    this.layout();
    this.invalidate();
  }

  clear() {
    this.roll = null;
    this.frames = [];
    this.selected.clear();
    this.images.clear();
    this.invalidate();
  }

  setFrames(frames, keepSelection = []) {
    this.frames = frames;
    this.selected = new Set(keepSelection.filter((i) => i >= 0 && i < frames.length));
    this.invalidate();
  }

  setView({ stripsPerRow, zoom, fillOpacity }) {
    if (stripsPerRow) this.stripsPerRow = Math.max(1, Math.min(20, stripsPerRow));
    if (zoom) this.zoom = Math.max(0.25, Math.min(4, zoom));
    if (fillOpacity !== undefined) this.fillOpacity = fillOpacity;
    const firstStrip = this.firstStrip;
    this.layout();
    this.page = Math.floor(firstStrip / this.perPage); // keep roughly the same strips in view
    this.clampPage();
    this.invalidate();
    this.cb.onPageChanged?.();
  }

  setImageVersion(v) {
    if (v === this.imageVersion) return;
    this.imageVersion = v;
    this.invalidate();
  }

  // ------------------------------------------------------------------ layout

  resize() {
    const dpr = window.devicePixelRatio || 1;
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    this.canvas.width = Math.max(1, Math.round(w * dpr));
    this.canvas.height = Math.max(1, Math.round(h * dpr));
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const firstStrip = this.firstStrip || 0;
    this.layout();
    if (this.perPage) this.page = Math.floor(firstStrip / this.perPage);
    this.clampPage();
    this.draw();
    this.cb.onPageChanged?.();
  }

  layout() {
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    this.stripW = Math.round(BASE_STRIP_W * this.zoom);
    const r = this.roll;
    if (r && r.widthPixels > 0 && r.lengthLines > 0) {
      const ds = Math.max(1, r.previewDownScale);
      this.previewW = Math.max(1, Math.floor(r.widthPixels / ds));
      this.previewH = Math.max(1, Math.floor(r.lengthLines / ds));
      this.stripH = Math.max(8, Math.round(this.stripW * this.previewW / this.previewH));
      this.pxPerLine = this.stripW / (this.previewH * ds);   // screen px per full-res line (along film)
      this.pxPerAcross = this.stripH / (this.previewW * ds); // screen px per full-res pixel (across film)
    } else {
      this.stripH = this.stripW;
    }
    this.rowsPerPage = Math.max(1, Math.floor(h / this.stripH));
    this.perPage = this.stripsPerRow * this.rowsPerPage;
    this.originX = Math.max(0, Math.floor((w - this.stripsPerRow * this.stripW) / 2));
    this.originY = Math.max(0, Math.floor((h - this.rowsPerPage * this.stripH) / 2));
  }

  get stripCount() { return this.roll ? this.roll.stripCount : 0; }
  get pageCount() { return this.perPage ? Math.ceil(this.stripCount / this.perPage) : 0; }
  get firstStrip() { return this.page * (this.perPage || 0); }
  get pageStripCount() { return Math.max(0, Math.min(this.perPage, this.stripCount - this.firstStrip)); }

  clampPage() {
    this.page = Math.max(0, Math.min(this.page, Math.max(0, this.pageCount - 1)));
  }

  gotoPage(p) {
    const old = this.page;
    this.page = p;
    this.clampPage();
    if (this.page !== old) {
      this.invalidate();
      this.cb.onPageChanged?.();
    }
  }

  /** Shows the page that holds the given frame. */
  revealFrame(idx) {
    const f = this.frames[idx];
    if (!f || !this.roll) return;
    const strip = Math.floor(f.leadEdge / this.roll.lengthLines);
    this.gotoPage(Math.floor(strip / this.perPage));
  }

  stripRect(i) {
    const row = Math.floor(i / this.stripsPerRow), col = i % this.stripsPerRow;
    return { x: this.originX + col * this.stripW, y: this.originY + row * this.stripH, w: this.stripW, h: this.stripH };
  }

  /** Film position under a screen point; with clamp the nearest strip on the page is used. */
  screenToFilm(x, y, clamp = false) {
    if (!this.roll || !this.pageStripCount) return null;
    let col = Math.floor((x - this.originX) / this.stripW);
    let row = Math.floor((y - this.originY) / this.stripH);
    if (!clamp && (col < 0 || col >= this.stripsPerRow || row < 0 || row >= this.rowsPerPage)) return null;
    col = Math.max(0, Math.min(this.stripsPerRow - 1, col));
    row = Math.max(0, Math.min(this.rowsPerPage - 1, row));
    let i = row * this.stripsPerRow + col;
    if (i >= this.pageStripCount) {
      if (!clamp) return null;
      i = this.pageStripCount - 1;
    }
    const r = this.stripRect(i);
    const strip = this.firstStrip + i;
    const ll = this.roll.lengthLines;
    const local = Math.max(0, Math.min(ll, (x - r.x) / this.pxPerLine));
    const across = Math.max(0, Math.min(this.roll.widthPixels, (y - r.y) / this.pxPerAcross));
    return { strip, lead: Math.round(strip * ll + local), across: Math.round(across) };
  }

  // ------------------------------------------------------------------ images

  imageFor(strip) {
    let e = this.images.get(strip);
    if (e && e.version === this.imageVersion) {
      this.images.delete(strip); // LRU: move to the end
      this.images.set(strip, e);
      return e;
    }
    const img = new Image();
    img.decoding = 'async';
    e = { img, version: this.imageVersion, state: 'loading', stale: e && e.state === 'ok' ? e.img : null };
    img.onload = () => { e.state = 'ok'; e.stale = null; this.invalidate(); };
    img.onerror = () => { e.state = 'missing'; e.stale = null; this.invalidate(); };
    img.src = `https://img.striplight/strip/${strip}?v=${this.imageVersion}`;
    this.images.set(strip, e);
    const cap = Math.max(48, this.perPage * 3);
    while (this.images.size > cap) this.images.delete(this.images.keys().next().value);
    return e;
  }

  prefetchNextPage() {
    const start = this.firstStrip + this.perPage;
    const end = Math.min(this.stripCount, start + this.perPage);
    for (let s = start; s < end; s++) this.imageFor(s);
  }

  // ------------------------------------------------------------------ drawing

  invalidate() {
    if (this.rafPending) return;
    this.rafPending = true;
    requestAnimationFrame(() => { this.rafPending = false; this.draw(); });
  }

  draw() {
    const ctx = this.ctx, w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    ctx.fillStyle = '#0d0e10';
    ctx.fillRect(0, 0, w, h);
    this.segments = [];
    if (!this.roll) return;

    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    let allLoaded = true;
    for (let i = 0; i < this.pageStripCount; i++) {
      const r = this.stripRect(i);
      const strip = this.firstStrip + i;
      const e = this.imageFor(strip);
      if (e.state === 'ok') ctx.drawImage(e.img, r.x, r.y, r.w, r.h);
      else if (e.stale) ctx.drawImage(e.stale, r.x, r.y, r.w, r.h);
      else {
        ctx.fillStyle = '#17191c';
        ctx.fillRect(r.x, r.y, r.w, r.h);
        if (e.state === 'missing') this.label(r, 'missing preview', '#6d6a64');
      }
      if (e.state === 'loading') allLoaded = false;
      // strip number + boundary
      ctx.fillStyle = 'rgba(13,14,16,.65)';
      ctx.fillRect(r.x + 2, r.y + 2, 46, 15);
      ctx.fillStyle = '#9b968d';
      ctx.font = '10px "Cascadia Mono", Consolas, monospace';
      ctx.fillText(String(strip + 1), r.x + 5, r.y + 13);
      ctx.strokeStyle = 'rgba(255,255,255,.06)';
      ctx.lineWidth = 1;
      ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
    }

    this.drawFrames();
    if (this.drag && this.drag.mode === 'draw' && this.drag.moved) this.drawRubberBand();
    if (allLoaded) this.prefetchNextPage();
  }

  label(r, text, color) {
    const ctx = this.ctx;
    ctx.fillStyle = color;
    ctx.font = '11px "Segoe UI", sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText(text, r.x + r.w / 2, r.y + r.h / 2);
    ctx.textAlign = 'left';
  }

  /** Screen rectangles of one frame on this page, merged across strips that share a row. */
  frameSegments(f) {
    const ll = this.roll.lengthLines;
    const s1 = Math.floor(f.leadEdge / ll), s2 = Math.floor(f.trailEdge / ll);
    const first = this.firstStrip, last = first + this.pageStripCount - 1;
    if (s2 < first || s1 > last) return [];
    const segs = [];
    let cur = null;
    for (let s = Math.max(s1, first); s <= Math.min(s2, last); s++) {
      const r = this.stripRect(s - first);
      const localLead = s === s1 ? f.leadEdge - s * ll : 0;
      const localTrail = s === s2 ? f.trailEdge - s * ll : ll;
      if (localTrail <= localLead) {
        // Trail exactly on a strip boundary: the previous segment holds the trail edge.
        if (s === s2 && cur) cur.isTrail = true;
        continue;
      }
      const x1 = r.x + localLead * this.pxPerLine;
      const x2 = r.x + Math.min(ll, localTrail) * this.pxPerLine;
      const y1 = r.y + f.leftEdge * this.pxPerAcross;
      const y2 = r.y + f.rightEdge * this.pxPerAcross;
      const row = Math.floor((s - first) / this.stripsPerRow);
      if (cur && cur.row === row) {
        cur.x2 = Math.max(cur.x2, x2);
        cur.y1 = Math.min(cur.y1, y1);
        cur.y2 = Math.max(cur.y2, y2);
        cur.isTrail = s === s2;
      } else {
        if (cur) segs.push(cur);
        cur = { row, x1, x2, y1, y2, isLead: s === s1, isTrail: s === s2 };
      }
    }
    if (cur) segs.push(cur);
    return segs.filter((g) => g.x2 - g.x1 > 0.5 && g.y2 - g.y1 > 0.5);
  }

  drawFrames() {
    const ctx = this.ctx;
    const fill = Math.max(0, Math.min(1, this.fillOpacity / 100)) * 0.45;
    const singleSel = this.selected.size === 1 ? [...this.selected][0] : -1;
    // Selected frames last, so they sit on top.
    const order = this.frames.map((_, i) => i).sort((a, b) => this.selected.has(a) - this.selected.has(b));
    for (const i of order) {
      const f = this.frames[i];
      const segs = this.frameSegments(f);
      if (!segs.length) continue;
      const sel = this.selected.has(i);
      const color = sel ? COLOR.selected
        : f.isExported ? COLOR.exported
        : (f.isOversized || f.isUndersized) ? COLOR.abnormal
        : COLOR.normal;
      for (const g of segs) {
        this.segments.push({ idx: i, ...g });
        const w = g.x2 - g.x1, h = g.y2 - g.y1;
        if (fill > 0) {
          ctx.globalAlpha = fill;
          ctx.fillStyle = color;
          ctx.fillRect(g.x1, g.y1, w, h);
          ctx.globalAlpha = 1;
        }
        ctx.lineWidth = 2;
        ctx.strokeStyle = f.isSuggested && !sel ? COLOR.suggested : color;
        ctx.setLineDash(f.isSuggested ? [6, 4] : []);
        ctx.strokeRect(g.x1 + 1, g.y1 + 1, Math.max(0, w - 2), Math.max(0, h - 2));
        ctx.setLineDash([]);

        if (f.isMarker && g.isLead) {
          // Folder marker: a bold yellow bar along the lead edge with a flag.
          ctx.fillStyle = COLOR.marker;
          ctx.fillRect(g.x1, g.y1, 4, h);
          ctx.beginPath();
          ctx.moveTo(g.x1 + 4, g.y1);
          ctx.lineTo(g.x1 + 16, g.y1 + 6);
          ctx.lineTo(g.x1 + 4, g.y1 + 12);
          ctx.fill();
        }
        if (g.isLead && (f.hasOverride || hasTone(f))) {
          ctx.fillStyle = COLOR.perframe;
          ctx.beginPath();
          ctx.arc(g.x2 - 7, g.y1 + 7, 3.5, 0, Math.PI * 2);
          ctx.fill();
        }
        if (i === singleSel && w > 24 && h > 24) this.drawHandles(g);
      }
    }
  }

  drawHandles(g) {
    const ctx = this.ctx, s = 7;
    ctx.fillStyle = COLOR.selected;
    const my = (g.y1 + g.y2) / 2, mx = (g.x1 + g.x2) / 2;
    if (g.isLead) ctx.fillRect(g.x1 - s / 2, my - s / 2, s, s);
    if (g.isTrail) ctx.fillRect(g.x2 - s / 2, my - s / 2, s, s);
    ctx.fillRect(mx - s / 2, g.y1 - s / 2, s, s);
    ctx.fillRect(mx - s / 2, g.y2 - s / 2, s, s);
  }

  drawRubberBand() {
    const d = this.drag, ctx = this.ctx;
    const a = d.startFilm, b = d.curFilm;
    const tmp = {
      leadEdge: Math.min(a.lead, b.lead), trailEdge: Math.max(a.lead, b.lead),
      leftEdge: Math.min(a.across, b.across), rightEdge: Math.max(a.across, b.across),
    };
    ctx.setLineDash([5, 4]);
    ctx.strokeStyle = COLOR.accent;
    ctx.lineWidth = 1.5;
    for (const g of this.frameSegments(tmp)) ctx.strokeRect(g.x1, g.y1, g.x2 - g.x1, g.y2 - g.y1);
    ctx.setLineDash([]);
  }

  // ------------------------------------------------------------------ hit testing

  /** Smallest frame under the point (stacked frames: the inner one wins). */
  hitFrame(x, y) {
    let best = -1, bestArea = Infinity;
    for (const g of this.segments) {
      if (x >= g.x1 && x <= g.x2 && y >= g.y1 && y <= g.y2) {
        const f = this.frames[g.idx];
        const area = (f.trailEdge - f.leadEdge) * (f.rightEdge - f.leftEdge);
        if (area < bestArea) { best = g.idx; bestArea = area; }
      }
    }
    return best;
  }

  /** Edge handle of a selected frame under the point: 'lead' | 'trail' | 'left' | 'right' | null. */
  hitHandle(x, y) {
    for (const g of this.segments) {
      if (!this.selected.has(g.idx) || this.selected.size !== 1) continue;
      const inY = y >= g.y1 - HANDLE && y <= g.y2 + HANDLE;
      const inX = x >= g.x1 - HANDLE && x <= g.x2 + HANDLE;
      if (g.isLead && inY && Math.abs(x - g.x1) <= HANDLE) return { idx: g.idx, edge: 'lead' };
      if (g.isTrail && inY && Math.abs(x - g.x2) <= HANDLE) return { idx: g.idx, edge: 'trail' };
      if (inX && Math.abs(y - g.y1) <= HANDLE) return { idx: g.idx, edge: 'left' };
      if (inX && Math.abs(y - g.y2) <= HANDLE) return { idx: g.idx, edge: 'right' };
    }
    return null;
  }

  // ------------------------------------------------------------------ selection

  select(idx, { toggle = false, range = false } = {}) {
    if (range && this.anchor >= 0) {
      const [a, b] = [Math.min(this.anchor, idx), Math.max(this.anchor, idx)];
      if (!toggle) this.selected.clear();
      for (let i = a; i <= b; i++) this.selected.add(i);
    } else if (toggle) {
      if (this.selected.has(idx)) this.selected.delete(idx); else this.selected.add(idx);
      this.anchor = idx;
    } else {
      this.selected.clear();
      if (idx >= 0) this.selected.add(idx);
      this.anchor = idx;
    }
    this.invalidate();
    this.cb.onSelectionChanged?.();
  }

  selectAll() { this.frames.forEach((_, i) => this.selected.add(i)); this.invalidate(); this.cb.onSelectionChanged?.(); }

  selectPage() {
    this.selected.clear();
    const ll = this.roll.lengthLines, a = this.firstStrip, b = a + this.pageStripCount - 1;
    this.frames.forEach((f, i) => {
      if (Math.floor(f.trailEdge / ll) >= a && Math.floor(f.leadEdge / ll) <= b) this.selected.add(i);
    });
    this.invalidate();
    this.cb.onSelectionChanged?.();
  }

  selectNone() { this.selected.clear(); this.anchor = -1; this.invalidate(); this.cb.onSelectionChanged?.(); }

  // ------------------------------------------------------------------ pointer

  point(e) {
    const r = this.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  onPointerDown(e) {
    if (!this.roll || e.button !== 0) return;
    this.canvas.focus();
    this.cb.onDismissMenus?.();
    const { x, y } = this.point(e);
    const film = this.screenToFilm(x, y, true);
    if (!film) return;

    const handle = this.hitHandle(x, y);
    if (handle) {
      this.beginDrag(e, 'resize', film, [handle.idx], handle.edge);
      return;
    }
    const hit = this.hitFrame(x, y);
    if (hit >= 0) {
      if (e.ctrlKey || e.shiftKey) {
        this.select(hit, { toggle: e.ctrlKey, range: e.shiftKey });
        return;
      }
      if (!this.selected.has(hit)) this.select(hit);
      this.beginDrag(e, 'move', film, [...this.selected]);
      return;
    }
    if (this.screenToFilm(x, y, false)) this.beginDrag(e, 'draw', film, []);
    else if (!e.ctrlKey) this.selectNone();
  }

  beginDrag(e, mode, film, indices, edge = null) {
    this.canvas.setPointerCapture(e.pointerId);
    this.drag = {
      mode, edge, indices, moved: false,
      startX: e.clientX, startY: e.clientY, startFilm: film, curFilm: film,
      originals: indices.map((i) => ({ ...this.frames[i] })),
    };
  }

  onPointerMove(e) {
    const { x, y } = this.point(e);
    const d = this.drag;
    if (!d) {
      this.updateHover(x, y);
      return;
    }
    if (!d.moved && Math.hypot(e.clientX - d.startX, e.clientY - d.startY) < DRAG_START) return;
    d.moved = true;
    const film = this.screenToFilm(x, y, true);
    if (!film) return;
    d.curFilm = film;
    const r = this.roll, maxLead = r.stripCount * r.lengthLines, minSize = 4 * Math.max(1, r.previewDownScale);

    if (d.mode === 'move') {
      let dl = film.lead - d.startFilm.lead, da = film.across - d.startFilm.across;
      // Keep the whole selection inside the roll.
      for (const o of d.originals) {
        dl = Math.max(dl, -o.leadEdge);
        dl = Math.min(dl, maxLead - o.trailEdge);
        da = Math.max(da, -o.leftEdge);
        da = Math.min(da, r.widthPixels - o.rightEdge);
      }
      d.indices.forEach((idx, k) => {
        const o = d.originals[k], f = this.frames[idx];
        f.leadEdge = o.leadEdge + dl; f.trailEdge = o.trailEdge + dl;
        f.leftEdge = o.leftEdge + da; f.rightEdge = o.rightEdge + da;
      });
    } else if (d.mode === 'resize') {
      const f = this.frames[d.indices[0]], o = d.originals[0];
      if (d.edge === 'lead') f.leadEdge = Math.min(film.lead, o.trailEdge - minSize);
      if (d.edge === 'trail') f.trailEdge = Math.max(film.lead, o.leadEdge + minSize);
      if (d.edge === 'left') f.leftEdge = Math.min(film.across, o.rightEdge - minSize);
      if (d.edge === 'right') f.rightEdge = Math.max(film.across, o.leftEdge + minSize);
    }
    this.invalidate();
    this.updateHover(x, y);
  }

  onPointerUp(e) {
    const d = this.drag;
    if (!d) return;
    this.drag = null;
    this.canvas.releasePointerCapture?.(e.pointerId);
    if (!d.moved) {
      if (d.mode === 'draw') this.selectNone();
      else if (d.mode === 'move') {
        const p = this.point(e);
        const hit = this.hitFrame(p.x, p.y);
        if (hit >= 0 && this.selected.size > 1) this.select(hit); // plain click inside a multi-selection
      }
      this.invalidate();
      return;
    }
    if (d.mode === 'draw') {
      const a = d.startFilm, b = d.curFilm;
      const frame = {
        leadEdge: Math.min(a.lead, b.lead), trailEdge: Math.max(a.lead, b.lead),
        leftEdge: Math.min(a.across, b.across), rightEdge: Math.max(a.across, b.across),
      };
      const min = 4 * Math.max(1, this.roll.previewDownScale);
      if (frame.trailEdge - frame.leadEdge >= min && frame.rightEdge - frame.leftEdge >= min) this.cb.onFrameCreated?.(frame);
      this.invalidate();
      return;
    }
    this.cb.onFramesEdited?.(d.indices);
  }

  /** Esc during a drag puts the frames back. */
  cancelDrag() {
    const d = this.drag;
    if (!d) return false;
    d.indices.forEach((idx, k) => Object.assign(this.frames[idx], d.originals[k]));
    this.drag = null;
    this.invalidate();
    return true;
  }

  onDoubleClick(e) {
    const { x, y } = this.point(e);
    const hit = this.hitFrame(x, y);
    if (hit >= 0) this.cb.onOpenFrame?.(hit);
  }

  onContextMenu(e) {
    e.preventDefault();
    const { x, y } = this.point(e);
    const hit = this.hitFrame(x, y);
    if (hit < 0) return;
    if (!this.selected.has(hit)) this.select(hit);
    this.cb.onContextMenu?.(x, y, hit);
  }

  onWheel(e) {
    if (!this.roll) return;
    e.preventDefault();
    if (e.ctrlKey) {
      const z = Math.round((this.zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1)) * 100) / 100;
      this.cb.onZoomRequest?.(Math.max(0.25, Math.min(4, z)));
    } else {
      this.gotoPage(this.page + (e.deltaY > 0 ? 1 : -1));
    }
  }

  updateHover(x, y) {
    const handle = !this.drag && this.hitHandle(x, y);
    const cls = this.drag ? (this.drag.mode === 'draw' ? 'draw' : this.drag.mode === 'move' ? 'move' : '')
      : handle ? (handle.edge === 'lead' || handle.edge === 'trail' ? 'ew' : 'ns')
      : this.hitFrame(x, y) >= 0 ? 'move' : '';
    this.canvas.className = cls;
    if (this.drag?.mode === 'resize') this.canvas.className = this.drag.edge === 'lead' || this.drag.edge === 'trail' ? 'ew' : 'ns';

    const film = this.screenToFilm(x, y, false);
    if (!film) { this.cb.onHover?.(''); return; }
    const hit = this.hitFrame(x, y);
    let text = `strip ${film.strip + 1} · line ${film.lead.toLocaleString()} · x ${film.across}`;
    if (hit >= 0) {
      const f = this.frames[hit];
      text += ` · frame ${hit + 1} (${f.trailEdge - f.leadEdge} × ${f.rightEdge - f.leftEdge})`;
    }
    this.cb.onHover?.(text);
  }
}

export function hasTone(f) {
  return f.perFrameBrightness !== -1 || f.perFrameContrast !== -1 || f.perFrameGamma !== -1 ||
    f.customBrightness !== -1 || f.customContrast !== -1 || f.customGamma !== -1;
}
