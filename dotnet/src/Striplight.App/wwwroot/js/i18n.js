// Translations for the page. The English text is the key; the host sends the dictionary for
// the chosen language (wwwroot/i18n/<lang>.json merged with the user's own file in
// %APPDATA%\StriplightPRO\lang). Anything missing stays English.
//
//   t('Nothing to undo.')                         plain text
//   t('Deleted frames {a}–{b}', { a: 1, b: 9 })   placeholders
//   tn(n, '{n} frame', '{n} frames')              counts: the dictionary entry for the plural
//                                                 English form may hold { one, few, many, other }
//
// The static HTML is translated once at start-up (text, title, aria-label, placeholder);
// elements with data-i18n-html are translated as a whole, markup included. Changing the
// language reloads the page.

import { call, inHost } from './bridge.js';

let dict = {};
let lang = 'en';
let plural = new Intl.PluralRules('en');

const norm = (s) => s.replace(/\s+/g, ' ').trim();

function fill(s, vars) {
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
}

export function t(english, vars) {
  const v = dict[english];
  const s = typeof v === 'string' && v ? v : v && typeof v === 'object' ? v.other ?? english : english;
  return fill(s, vars);
}

export function tn(n, one, other, vars = {}) {
  const v = dict[other] ?? dict[one];
  let s;
  if (v && typeof v === 'object') s = v[plural.select(n)] ?? v.other ?? (n === 1 ? one : other);
  else if (typeof v === 'string' && v) s = v;
  else s = n === 1 ? one : other;
  return fill(s, { n: Number(n).toLocaleString(), ...vars });
}

export const currentLanguage = () => lang;

/** Translates text nodes and the title / aria-label / placeholder attributes under root. */
export function translateDom(root = document.body) {
  if (lang === 'en') return;
  for (const el of root.querySelectorAll('[data-i18n-html]')) {
    const key = norm(el.innerHTML);
    const v = dict[key];
    if (typeof v === 'string' && v) el.innerHTML = v;
  }
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.parentElement?.closest('script, style, [data-i18n-html], [data-no-i18n]')
      ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
  });
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const key = norm(n.nodeValue);
    if (!key) continue;
    const v = dict[key];
    if (typeof v !== 'string' || !v) continue;
    const lead = n.nodeValue.match(/^\s*/)[0], trail = n.nodeValue.match(/\s*$/)[0];
    n.nodeValue = lead + v + trail;
  }
  for (const attr of ['title', 'aria-label', 'placeholder']) {
    for (const el of root.querySelectorAll(`[${attr}]`)) {
      const v = dict[norm(el.getAttribute(attr))];
      if (typeof v === 'string' && v) el.setAttribute(attr, v);
    }
  }
}

/** Loads the dictionary from the host and translates the static page. */
export async function initI18n() {
  if (inHost) {
    try {
      const r = await call('i18n.get');
      lang = r?.lang || 'en';
      dict = r?.dict || {};
    } catch { /* stay English */ }
  }
  try { plural = new Intl.PluralRules(lang); } catch { plural = new Intl.PluralRules('en'); }
  document.documentElement.lang = lang;
  document.title = t(document.title);
  translateDom();
}
