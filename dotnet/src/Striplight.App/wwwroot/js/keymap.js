// Configurable keyboard shortcuts. Every command the keyboard can trigger is listed here
// with its default keys; the user can add, change or remove keys (Keyboard shortcuts sheet).
// Custom bindings are stored in AppSettings.KeyBindings (command id -> list of keys).

/** All bindable commands. group: 'main' window or 'preview' window. keys: defaults. */
export const COMMANDS = [
  // ---- main window: file & view
  { id: 'open', group: 'main', section: 'File', label: 'Open roll', keys: ['Ctrl+O'] },
  { id: 'save', group: 'main', section: 'File', label: 'Save', keys: ['Ctrl+S'] },
  { id: 'saveAs', group: 'main', section: 'File', label: 'Save as', keys: ['Ctrl+Shift+S'] },
  { id: 'next', group: 'main', section: 'Navigate', label: 'Next page', keys: ['C', 'PageDown'] },
  { id: 'prev', group: 'main', section: 'Navigate', label: 'Previous page', keys: ['X', 'PageUp'] },
  { id: 'first', group: 'main', section: 'Navigate', label: 'First page', keys: ['Home'] },
  { id: 'last', group: 'main', section: 'Navigate', label: 'Last page', keys: ['End'] },
  { id: 'nextMarker', group: 'main', section: 'Navigate', label: 'Next folder marker', keys: ['F'] },
  { id: 'prevMarker', group: 'main', section: 'Navigate', label: 'Previous folder marker', keys: ['G'] },
  { id: 'nextAbnormal', group: 'main', section: 'Navigate', label: 'Next odd-size frame', keys: [] },
  { id: 'nextSmall', group: 'main', section: 'Navigate', label: 'Next undersized frame', keys: [] },
  { id: 'nextBig', group: 'main', section: 'Navigate', label: 'Next oversized frame', keys: [] },
  { id: 'zoomIn', group: 'main', section: 'View', label: 'Zoom in', keys: ['+', '='] },
  { id: 'zoomOut', group: 'main', section: 'View', label: 'Zoom out', keys: ['-'] },
  { id: 'toggleAuto', group: 'main', section: 'View', label: 'Auto strips per row on/off', keys: [] },
  { id: 'toggleNumbers', group: 'main', section: 'View', label: 'Strip numbers on/off', keys: [] },
  { id: 'toggleMulti', group: 'main', section: 'View', label: 'Multi-edit on/off (resize all selected)', keys: [] },
  { id: 'toggleCw', group: 'main', section: 'View', label: 'CW orientation on/off', keys: [] },
  { id: 'theme', group: 'main', section: 'View', label: 'Light / dark theme', keys: [] },
  { id: 'previewFrame', group: 'main', section: 'View', label: 'Open preview window', keys: ['Enter'] },
  { id: 'shortcuts', group: 'main', section: 'View', label: 'Keyboard shortcuts', keys: ['?'] },
  { id: 'help', group: 'main', section: 'View', label: 'Help / manual', keys: ['F1'] },
  { id: 'cache', group: 'main', section: 'View', label: 'Preview cache', keys: [] },
  // ---- main window: selection & editing
  { id: 'selectAll', group: 'main', section: 'Select', label: 'Select all', keys: ['Ctrl+A'] },
  { id: 'selectNone', group: 'main', section: 'Select', label: 'Select none', keys: ['Ctrl+D'] },
  { id: 'selectPage', group: 'main', section: 'Select', label: 'Select page', keys: [] },
  { id: 'selectSection', group: 'main', section: 'Select', label: 'Select folder section', keys: [] },
  { id: 'selectSuggestedSection', group: 'main', section: 'Select', label: 'Select suggested section', keys: [] },
  { id: 'selectFlagged', group: 'main', section: 'Select', label: 'Select flagged (size check)', keys: [] },
  { id: 'toggleMarker', group: 'main', section: 'Edit', label: 'Toggle folder marker', keys: ['A', 'M'] },
  { id: 'deleteQuick', group: 'main', section: 'Edit', label: 'Delete selected (no question)', keys: ['D'] },
  { id: 'deleteSelected', group: 'main', section: 'Edit', label: 'Delete selected (asks above 20)', keys: ['Delete'] },
  { id: 'deleteSection', group: 'main', section: 'Edit', label: 'Delete folder section', keys: [] },
  { id: 'merge', group: 'main', section: 'Edit', label: 'Merge pairs', keys: ['E'] },
  { id: 'combine', group: 'main', section: 'Edit', label: 'Combine overlapping', keys: ['J'] },
  { id: 'split', group: 'main', section: 'Edit', label: 'Split into parts', keys: ['S'] },
  { id: 'closeGaps', group: 'main', section: 'Edit', label: 'Fill gaps between selected', keys: [] },
  { id: 'joinClose', group: 'main', section: 'Edit', label: 'Join close fragments', keys: [] },
  { id: 'expand', group: 'main', section: 'Edit', label: 'Expand selected', keys: [] },
  { id: 'applyTrim', group: 'main', section: 'Edit', label: 'Apply trim', keys: [] },
  { id: 'toggleSuggested', group: 'main', section: 'Edit', label: 'Toggle suggested marker', keys: ['Z'] },
  { id: 'undo', group: 'main', section: 'Edit', label: 'Undo', keys: ['Ctrl+Z'] },
  { id: 'clearExportedSel', group: 'main', section: 'Edit', label: 'Clear exported mark on selected', keys: [] },
  // ---- main window: detection, markers, export
  { id: 'detect', group: 'main', section: 'Detect & export', label: 'Detect frames', keys: [] },
  { id: 'detectPause', group: 'main', section: 'Detect & export', label: 'Pause / resume detection', keys: [] },
  { id: 'detectStop', group: 'main', section: 'Detect & export', label: 'Stop detection (keep frames)', keys: [] },
  { id: 'detectContinue', group: 'main', section: 'Detect & export', label: 'Continue stopped detection', keys: [] },
  { id: 'suggest', group: 'main', section: 'Detect & export', label: 'Suggest markers', keys: [] },
  { id: 'selectSuggested', group: 'main', section: 'Detect & export', label: 'Select suggested', keys: [] },
  { id: 'acceptSuggested', group: 'main', section: 'Detect & export', label: 'Make suggested into markers', keys: [] },
  { id: 'clearSuggested', group: 'main', section: 'Detect & export', label: 'Clear suggested', keys: [] },
  { id: 'exportStart', group: 'main', section: 'Detect & export', label: 'Start export', keys: [] },
  { id: 'exportRetry', group: 'main', section: 'Detect & export', label: 'Re-export failed frames', keys: [] },
  { id: 'report', group: 'main', section: 'Detect & export', label: 'Handover report', keys: [] },

  // ---- preview window
  { id: 'pv.prev', group: 'preview', section: 'Preview window', label: 'Previous frame', keys: ['X', 'ArrowLeft', 'PageUp'] },
  { id: 'pv.next', group: 'preview', section: 'Preview window', label: 'Next frame', keys: ['C', 'ArrowRight', 'PageDown'] },
  { id: 'pv.prevMarker', group: 'preview', section: 'Preview window', label: 'Previous folder marker', keys: ['G'] },
  { id: 'pv.nextMarker', group: 'preview', section: 'Preview window', label: 'Next folder marker', keys: ['F'] },
  { id: 'pv.first', group: 'preview', section: 'Preview window', label: 'First frame', keys: ['Home'] },
  { id: 'pv.last', group: 'preview', section: 'Preview window', label: 'Last frame', keys: ['End'] },
  { id: 'pv.rotR', group: 'preview', section: 'Preview window', label: 'Rotate +90°', keys: ['R'] },
  { id: 'pv.rotL', group: 'preview', section: 'Preview window', label: 'Rotate −90°', keys: ['Shift+R'] },
  { id: 'pv.mirror', group: 'preview', section: 'Preview window', label: 'Mirror', keys: ['M'] },
  { id: 'pv.negative', group: 'preview', section: 'Preview window', label: 'Negative', keys: ['N'] },
  { id: 'pv.perFrame', group: 'preview', section: 'Preview window', label: 'This frame only on/off (R/M/N per frame)', keys: ['P'] },
  { id: 'pv.marker', group: 'preview', section: 'Preview window', label: 'Toggle folder marker', keys: ['A'] },
  { id: 'pv.zoomIn', group: 'preview', section: 'Preview window', label: 'Zoom in', keys: ['+', '='] },
  { id: 'pv.zoomOut', group: 'preview', section: 'Preview window', label: 'Zoom out', keys: ['-'] },
  { id: 'pv.fit', group: 'preview', section: 'Preview window', label: 'Fit to window', keys: ['0', 'Space'] },
  { id: 'pv.one', group: 'preview', section: 'Preview window', label: '1:1 pixels', keys: ['1'] },
  { id: 'pv.quality', group: 'preview', section: 'Preview window', label: 'Full quality on/off', keys: ['Q'] },
  { id: 'pv.topmost', group: 'preview', section: 'Preview window', label: 'Always on top on/off', keys: ['T'] },
  { id: 'pv.target', group: 'preview', section: 'Preview window', label: 'Target banner on/off', keys: ['I'] },
  { id: 'pv.close', group: 'preview', section: 'Preview window', label: 'Close preview', keys: ['Escape'] },
];

const NAMED = {
  ' ': 'Space', Escape: 'Escape', Enter: 'Enter', Delete: 'Delete', Backspace: 'Backspace', Tab: 'Tab',
  Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown', Insert: 'Insert',
  ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight', ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown',
};

/**
 * Normalised key name for a keydown event, e.g. "Ctrl+Shift+S", "A", "?", "PageDown".
 * Returns null for a lone modifier key. Shift is part of the name for letters and named keys,
 * not for symbols (Shift+/ is simply "?").
 */
export function comboFromEvent(e) {
  if (['Control', 'Shift', 'Alt', 'Meta', 'AltGraph', 'CapsLock'].includes(e.key)) return null;
  let key, shiftCounts = true;
  if (NAMED[e.key]) key = NAMED[e.key];
  else if (/^F\d{1,2}$/.test(e.key)) key = e.key;
  else if (e.key.length === 1) {
    if (/[a-z]/i.test(e.key)) key = e.key.toUpperCase();
    else { key = e.key; shiftCounts = false; }
  } else return null;
  const parts = [];
  if (e.ctrlKey || e.metaKey) parts.push('Ctrl');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey && shiftCounts) parts.push('Shift');
  parts.push(key);
  return parts.join('+');
}

/** Pretty label for a key name. */
export function keyLabel(k) {
  return k.replace('ArrowLeft', '←').replace('ArrowRight', '→').replace('ArrowUp', '↑').replace('ArrowDown', '↓')
    .replace('PageUp', 'PgUp').replace('PageDown', 'PgDn').replace('Delete', 'Del').replace('Escape', 'Esc');
}

export class Keymap {
  constructor(overrides = {}) { this.setOverrides(overrides); }

  setOverrides(overrides) {
    this.overrides = { ...(overrides || {}) };
    this.index = {};
    for (const c of COMMANDS) {
      for (const k of this.keysFor(c.id)) this.index[`${c.group}|${k}`] = c.id;
    }
  }

  keysFor(id) {
    if (Object.prototype.hasOwnProperty.call(this.overrides, id)) return this.overrides[id];
    return COMMANDS.find((c) => c.id === id)?.keys ?? [];
  }

  /** Command id bound to this event in the given group, or null. */
  match(e, group) {
    const combo = comboFromEvent(e);
    return combo ? this.index[`${group}|${combo}`] ?? null : null;
  }

  /** Assigns a key to a command, taking it away from any other command in the same group. */
  bind(id, key) {
    const cmd = COMMANDS.find((c) => c.id === id);
    let movedFrom = null;
    for (const c of COMMANDS) {
      if (c.group !== cmd.group || c.id === id) continue;
      const keys = this.keysFor(c.id);
      if (keys.includes(key)) { this.overrides[c.id] = keys.filter((k) => k !== key); movedFrom = c.label; }
    }
    const mine = this.keysFor(id);
    if (!mine.includes(key)) this.overrides[id] = [...mine, key];
    this.setOverrides(this.overrides);
    return movedFrom;
  }

  unbind(id, key) {
    this.overrides[id] = this.keysFor(id).filter((k) => k !== key);
    this.setOverrides(this.overrides);
  }

  resetAll() { this.setOverrides({}); }
}
