// Small UI helpers for the custom controls in index.html.

/**
 * Segmented control: <div class="seg" id="x"><button data-v="0">…</button>…</div>.
 * Gives the container a `value` property and fires 'change' on it, so it can be
 * used like a <select>.
 */
export function initSegmented(el) {
  const buttons = [...el.querySelectorAll('button[data-v]')];
  let value = buttons[0]?.dataset.v ?? '';
  const paint = () => buttons.forEach((b) => {
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(b.dataset.v === value));
  });
  Object.defineProperty(el, 'value', {
    get: () => value,
    set: (v) => { value = String(v); paint(); },
  });
  buttons.forEach((b) => b.addEventListener('click', () => {
    if (b.dataset.v === value) return;
    value = b.dataset.v;
    paint();
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }));
  paint();
}

/** Keeps the filled part of a range track in step with its value. */
export function paintRange(r) {
  const min = Number(r.min || 0), max = Number(r.max || 100), v = Number(r.value);
  r.style.setProperty('--fill', `${max > min ? ((v - min) / (max - min)) * 100 : 0}%`);
}

export function initRanges(root = document) {
  root.querySelectorAll('input[type=range]').forEach(paintRange);
  root.addEventListener('input', (e) => { if (e.target.matches?.('input[type=range]')) paintRange(e.target); });
}
