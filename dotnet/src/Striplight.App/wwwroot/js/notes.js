// Roll notes: TOAST UI Editor (ProseMirror-based) in Markdown + WYSIWYG modes.
// The Markdown is stored in the roll's .slf project (<StriplightNotes>).

import { call } from './bridge.js';
import { t } from './i18n.js';

let editor = null;
let pending = '';       // notes set before the editor existed
let suppress = false;   // true while loading notes, so loading does not mark the roll dirty
let timer = 0;

export function initNotes(container) {
  if (editor || !window.toastui) return;
  editor = new window.toastui.Editor({
    el: container,
    height: '100%',
    initialEditType: 'wysiwyg',
    previewStyle: 'tab',
    theme: 'dark',
    usageStatistics: false,  // no tracking ping to the vendor
    hideModeSwitch: false,
    placeholder: t('Notes about this roll: damage, missing frames, box labels, questions for the archive…'),
    toolbarItems: [
      ['heading', 'bold', 'italic', 'strike'],
      ['hr', 'quote'],
      ['ul', 'ol', 'task'],
      ['table', 'link'],
      ['code', 'codeblock'],
    ],
    initialValue: pending,
    events: {
      change: () => {
        if (suppress) return;
        clearTimeout(timer);
        timer = setTimeout(flushNotes, 400);
      },
    },
  });
}

export function setNotes(markdown) {
  pending = markdown || '';
  if (!editor) return;
  suppress = true;
  editor.setMarkdown(pending, false);
  suppress = false;
}

/** Sends the current notes to the host right away (used before saving). */
export function flushNotes() {
  clearTimeout(timer);
  if (!editor) return Promise.resolve();
  return call('notes.set', { markdown: editor.getMarkdown() });
}
