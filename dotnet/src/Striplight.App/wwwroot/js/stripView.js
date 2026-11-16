// Canvas strip view — the paged light table (port of lazarus/uStripView.pas).
//
// Geometry: every strip is shown turned upright. Along the film (lead → trail) runs
// left → right on screen; across the film (LeftEdge → RightEdge) runs top → bottom.
// Strips sit edge to edge in rows; a page is as many rows as fit the canvas height.

const BASE_STRIP_W = 160;   // strip width on screen at zoom 1.0
const PAD_TOP = 66;         // room for the floating view toolbar
const PAD_BOTTOM = 86;      // room for the legend and the roll scrubber
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
    this.rotateCw = false;        // false: strips turned CCW (default), true: CW + mirror
    this.autoStrips = false;      // fit as many strips per row as the canvas allows
    this.showStripNumbers = false;
    this.splitPreview = false;    // show where S would cut the selected frames
    this.splitParts = 2;
    this.refreshTheme();
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

  setView({ stripsPerRow, zoom, fillOpacity, rotateCw, autoStrips, showStripNumbers }) {
    if (rotateCw !== undefined) this.rotateCw = !!rotateCw;
    if (autoStrips !== undefined) this.autoStrips = !!autoStrips;
    if (showStripNumbers !== undefined) this.showStripNumbers = !!showStripNumbers;
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

  /** Re-reads the theme colours used on the canvas (after a theme switch). */
  refreshTheme() {
    const c = getComputedStyle(document.documentElement);
    this.theme = {
      plate: c.getPropertyValue('--plate').trim() || '#16181c',
      plateEmpty: c.getPropertyValue('--plate-empty').trim() || '#1b1e23',
      plateShadow: c.getPropertyValue('--plate-shadow').trim() || 'rgba(0,0,0,.55)',
    };
    this.invalidate?.();
  }

  /** Zoom actually shown (strips are capped so a row fits the canvas). */
  get effectiveZoom() { return this.stripW ? this.stripW / BASE_STRIP_W : this.zoom; }

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
    const wanted = Math.round(BASE_STRIP_W * this.zoom);
    // Auto: as many strips per row as fit at this zoom (the Lazarus "auto strips" option).
    if (this.autoStrips) this.stripsPerRow = Math.max(1, Math.min(20, Math.floor((w - 32) / Math.max(24, wanted))));
    // Zoomed strip width, but never wider than the canvas allows.
    this.stripW = Math.max(24, Math.min(wanted, Math.floor((w - 32) / this.stripsPerRow)));
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
    const availH = Math.max(this.stripH, h - PAD_TOP - PAD_BOTTOM);
    this.rowsPerPage = Math.max(1, Math.floor(availH / this.stripH));
    this.perPage = this.stripsPerRow * this.rowsPerPage;
    this.originX = Math.max(0, Math.floor((w - this.stripsPerRow * this.stripW) / 2));
    this.originY = PAD_TOP + Math.max(0, Math.floor((availH - this.rowsPerPage * this.stripH) / 2));
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

  // Across-the-film coordinates (LeftEdge/RightEdge) are columns of the stored, sideways
  // strip, counted from its column 0. Turning the strip CCW puts column 0 at the BOTTOM of
  // the screen; CW + mirror (a transpose) puts it at the TOP. Verified against QuantumScan
  // detection on a real roll (B25465-B25587): its LeftEdge sits DetectOverscanWidth (100 px)
  // before the paper in stored-image columns.
  acrossToY(across) {
    const a = this.rotateCw ? across : this.roll.widthPixels - across;
    return a * this.pxPerAcross;
  }

  yToAcross(dy) {
    const a = dy / this.pxPerAcross;
    return this.rotateCw ? a : this.roll.widthPixels - a;
  }

  /** Frame edge shown at the top / bottom of the screen in the current orientation. */
  get topEdge() { return this.rotateCw ? 'left' : 'right'; }
  get bottomEdge() { return this.rotateCw ? 'right' : 'left'; }

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
    const across = Math.max(0, Math.min(this.roll.widthPixels, this.yToAcross(y - r.y)));
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
    ctx.clearRect(0, 0, w, h);
    this.segments = [];
    if (!this.roll || !this.pageStripCount) return;

    // The page sits on a rounded "light table" plate with a soft shadow.
    const rows = Math.ceil(this.pageStripCount / this.stripsPerRow);
    const cols = Math.min(this.stripsPerRow, this.pageStripCount);
    const plate = { x: this.originX - 6, y: this.originY - 6, w: cols * this.stripW + 12, h: rows * this.stripH + 12 };
    ctx.save();
    ctx.shadowColor = this.theme.plateShadow;
    ctx.shadowBlur = 30;
    ctx.shadowOffsetY = 10;
    ctx.fillStyle = this.theme.plate;
    ctx.beginPath();
    ctx.roundRect(plate.x, plate.y, plate.w, plate.h, 10);
    ctx.fill();
    ctx.restore();

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
        ctx.fillStyle = this.theme.plateEmpty;
        ctx.fillRect(r.x, r.y, r.w, r.h);
        if (e.state === 'missing') this.label(r, 'No preview', '#6c727d');
      }
      if (e.state === 'loading') allLoaded = false;
      // strip boundary + number pill
      ctx.strokeStyle = 'rgba(255,255,255,.05)';
      ctx.lineWidth = 1;
      ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
      if (this.showStripNumbers) this.pill(String(strip + 1), r.x + 5, r.y + r.h - 22, 'rgba(10,11,13,.72)', '#a4a9b4');
    }

    this.drawFrames();
    if (this.drag && this.drag.mode === 'draw' && this.drag.moved) this.drawRubberBand();
    if (allLoaded) this.prefetchNextPage();
  }

  /** Small rounded label; returns its width. */
  pill(text, x, y, bg, fg, bold = false) {
    const ctx = this.ctx;
    ctx.font = `${bold ? 650 : 500} 10.5px "Segoe UI Variable Text", "Segoe UI", sans-serif`;
    const w = Math.ceil(ctx.measureText(text).width) + 12;
    ctx.fillStyle = bg;
    ctx.beginPath();
    ctx.roundRect(x, y, w, 17, 8.5);
    ctx.fill();
    ctx.fillStyle = fg;
    ctx.fillText(text, x + 6, y + 12.5);
    return w;
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
      const ya = r.y + this.acrossToY(f.leftEdge), yb = r.y + this.acrossToY(f.rightEdge);
      const y1 = Math.min(ya, yb), y2 = Math.max(ya, yb);
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
    // Solid, semi-transparent fill in the frame's state colour. 100% still lets the page show through.
    const fill = Math.max(0, Math.min(1, this.fillOpacity / 100)) * 0.7;
    const singleSel = this.selected.size === 1 ? [...this.selected][0] : -1;
    // Folder number of each marker (frames are sorted along the film).
    const folderOf = new Map();
    let folder = 0;
    this.frames.forEach((f, i) => { if (f.isMarker) folderOf.set(i, ++folder); });
    // Selected frames last, so they sit on top.
    const order = this.frames.map((_, i) => i).sort((a, b) => this.selected.has(a) - this.selected.has(b));
    for (const i of order) {
      const f = this.frames[i];
      const segs = this.frameSegments(f);
      if (!segs.length) continue;
      const sel = this.selected.has(i);
      // Main colour as in Lazarus: selected cyan, odd size red, otherwise green.
      const main = sel ? COLOR.selected : (f.isOversized || f.isUndersized) ? COLOR.abnormal : COLOR.normal;
      for (const g of segs) {
        this.segments.push({ idx: i, ...g });
        const w = g.x2 - g.x1, h = g.y2 - g.y1;
        const rect = (inset, width, stroke) => {
          ctx.lineWidth = width;
          ctx.strokeStyle = stroke;
          ctx.strokeRect(g.x1 + inset, g.y1 + inset, Math.max(0, w - 2 * inset), Math.max(0, h - 2 * inset));
        };

        // Same layering as the Lazarus DrawFrameRect:
        // 1. fill: folder yellow, else suggested magenta, else the main colour
        if (fill > 0) {
          ctx.globalAlpha = fill;
          ctx.fillStyle = f.isMarker ? COLOR.marker : f.isSuggested ? COLOR.suggested : main;
          ctx.fillRect(g.x1, g.y1, w, h);
          ctx.globalAlpha = 1;
        }
        // 2. exported: extra blue tint
        if (f.isExported) {
          ctx.globalAlpha = 70 / 255;
          ctx.fillStyle = COLOR.exported;
          ctx.fillRect(g.x1, g.y1, w, h);
          ctx.globalAlpha = 1;
        }
        // 3. per-frame settings: orange outer ring
        if (f.hasOverride || hasTone(f)) rect(-5, 3, COLOR.perframe);
        // 4. exported: blue inner border
        if (f.isExported) rect(4, 2, COLOR.exported);
        // 5. suggested (not a folder): thick magenta outer ring + thin inner ring
        if (f.isSuggested && !f.isMarker) { rect(-3, 3, COLOR.suggested); rect(3, 1, COLOR.suggested); }
        // 6. main border
        rect(0, 2, main);
        // 7. folder start: thicker yellow outline on top, plus the folder number
        if (f.isMarker) {
          rect(-1, 3, COLOR.marker);
          if (g.isLead && w > 30) this.pill(`F${folderOf.get(i)}`, g.x1 + 6, g.y1 + 5, COLOR.marker, '#1b1204', true);
        }
        if (sel && g.isLead && w > 40 && h > 40) {
          ctx.font = '600 10.5px "Segoe UI Variable Text", "Segoe UI", sans-serif';
          const t = String(i + 1);
          const tw = ctx.measureText(t).width + 12;
          this.pill(t, g.x2 - tw - 4, g.y2 - 21, COLOR.selected, '#04131c', true);
        }
        if (i === singleSel && w > 24 && h > 24) this.drawHandles(g);
      }
      if (sel && this.splitPreview) this.drawSplitCuts(f);
    }
  }

  drawHandles(g) {
    // White squares with a black border, like Lazarus: corners and edge midpoints.
    const ctx = this.ctx, hh = 5;
    const sq = (x, y) => {
      ctx.fillStyle = '#fff';
      ctx.fillRect(x - hh, y - hh, hh * 2, hh * 2);
      ctx.lineWidth = 1;
      ctx.strokeStyle = '#000';
      ctx.strokeRect(x - hh + 0.5, y - hh + 0.5, hh * 2 - 1, hh * 2 - 1);
    };
    const my = (g.y1 + g.y2) / 2, mx = (g.x1 + g.x2) / 2;
    if (g.isLead) { sq(g.x1, g.y1); sq(g.x1, my); sq(g.x1, g.y2); }
    if (g.isTrail) { sq(g.x2, g.y1); sq(g.x2, my); sq(g.x2, g.y2); }
    sq(mx, g.y1);
    sq(mx, g.y2);
  }

  /** Split preview (Lazarus): dashed cut lines where S would split each selected frame. */
  drawSplitCuts(f) {
    const n = this.splitParts;
    const part = Math.floor((f.trailEdge - f.leadEdge) / n);
    if (n < 2 || part < 1) return;
    const ctx = this.ctx, ll = this.roll.lengthLines;
    const first = this.firstStrip, last = first + this.pageStripCount - 1;
    for (let k = 1; k < n; k++) {
      const cut = f.leadEdge + k * part;
      const s = Math.floor(cut / ll);
      if (s < first || s > last) continue;
      const r = this.stripRect(s - first);
      const x = Math.round(r.x + (cut - s * ll) * this.pxPerLine) + 0.5;
      const ya = r.y + this.acrossToY(f.leftEdge), yb = r.y + this.acrossToY(f.rightEdge);
      const y1 = Math.max(r.y, Math.min(ya, yb)), y2 = Math.min(r.y + r.h, Math.max(ya, yb));
      if (y2 <= y1) continue;
      ctx.lineWidth = 1;
      ctx.setLineDash([]);
      ctx.strokeStyle = 'rgba(0,0,0,.75)';
      ctx.beginPath(); ctx.moveTo(x + 1, y1); ctx.lineTo(x + 1, y2); ctx.stroke();
      ctx.lineWidth = 2;
      ctx.setLineDash([6, 4]);
      ctx.strokeStyle = '#fff';
      ctx.beginPath(); ctx.moveTo(x, y1); ctx.lineTo(x, y2); ctx.stroke();
      ctx.setLineDash([]);
    }
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
  /**
   * Edge or corner handle of the selected frame under the point.
   * Returns { idx, edges: ['lead'|'trail'|'left'|'right', ...], cursor } or null.
   * Corners (two edges at once) are checked first so diagonal resizing wins near them.
   */
  hitHandle(x, y) {
    const C = HANDLE + 3; // corners are a little easier to grab
    for (const g of this.segments) {
      if (!this.selected.has(g.idx) || this.selected.size !== 1) continue;
      const nearL = g.isLead && Math.abs(x - g.x1) <= C, nearR = g.isTrail && Math.abs(x - g.x2) <= C;
      const nearT = Math.abs(y - g.y1) <= C, nearB = Math.abs(y - g.y2) <= C;
      if ((nearL || nearR) && (nearT || nearB)) {
        const edges = [nearL ? 'lead' : 'trail', nearT ? this.topEdge : this.bottomEdge];
        const cursor = (nearL && nearT) || (nearR && nearB) ? 'nwse' : 'nesw';
        return { idx: g.idx, edges, cursor };
      }
      const inY = y >= g.y1 - HANDLE && y <= g.y2 + HANDLE;
      const inX = x >= g.x1 - HANDLE && x <= g.x2 + HANDLE;
      if (g.isLead && inY && Math.abs(x - g.x1) <= HANDLE) return { idx: g.idx, edges: ['lead'], cursor: 'ew' };
      if (g.isTrail && inY && Math.abs(x - g.x2) <= HANDLE) return { idx: g.idx, edges: ['trail'], cursor: 'ew' };
      if (inX && Math.abs(y - g.y1) <= HANDLE) return { idx: g.idx, edges: [this.topEdge], cursor: 'ns' };
      if (inX && Math.abs(y - g.y2) <= HANDLE) return { idx: g.idx, edges: [this.bottomEdge], cursor: 'ns' };
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
      this.beginDrag(e, 'resize', film, [handle.idx], handle);
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

  beginDrag(e, mode, film, indices, handle = null) {
    this.canvas.setPointerCapture(e.pointerId);
    this.drag = {
      mode, edges: handle?.edges ?? [], cursor: handle?.cursor ?? '', indices, moved: false,
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
      for (const edge of d.edges) {
        if (edge === 'lead') f.leadEdge = Math.min(film.lead, o.trailEdge - minSize);
        if (edge === 'trail') f.trailEdge = Math.max(film.lead, o.leadEdge + minSize);
        if (edge === 'left') f.leftEdge = Math.min(film.across, o.rightEdge - minSize);
        if (edge === 'right') f.rightEdge = Math.max(film.across, o.leftEdge + minSize);
      }
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
      : handle ? handle.cursor
      : this.hitFrame(x, y) >= 0 ? 'move' : '';
    this.canvas.className = cls;
    if (this.drag?.mode === 'resize') this.canvas.className = this.drag.cursor;

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
