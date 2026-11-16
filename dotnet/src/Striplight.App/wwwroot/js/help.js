// Manual window (help.html). The text lives in help/<lang>.html as <section id="..."> blocks
// with an <h2>; this script loads the file for the current language, builds the contents
// list from the headings, filters by search and jumps to a topic (#id).

import { call, on } from './bridge.js';
import { hydrateIcons } from './icons.js';
import { initI18n, currentLanguage, t } from './i18n.js';

const $ = (s) => document.querySelector(s);

await initI18n();
try {
  const r = await call('i18n.get');
  if (r?.theme) document.documentElement.dataset.theme = r.theme;
} catch { /* defaults */ }
hydrateIcons();

const lang = currentLanguage();
let html = '';
for (const l of [lang, 'en']) {
  try {
    const res = await fetch(`help/${l}.html`);
    if (res.ok) { html = await res.text(); break; }
  } catch { /* try English */ }
}
const doc = $('#help-doc');
doc.innerHTML = html;
hydrateIcons(doc);
document.title = t('Striplight PRO — Help');

// Contents: one entry per section, sub-entries for its h3s.
const toc = $('#help-toc');
const sections = [...doc.querySelectorAll('section[id]')];
for (const s of sections) {
  const h2 = s.querySelector('h2');
  if (!h2) continue;
  const a = document.createElement('a');
  a.href = `#${s.id}`;
  a.textContent = h2.textContent;
  a.className = 'toc-h2';
  a.dataset.target = s.id;
  toc.append(a);
}

function show(id, smooth = true) {
  const el = id && document.getElementById(id);
  if (!el) return;
  el.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: 'start' });
  el.classList.add('flash');
  setTimeout(() => el.classList.remove('flash'), 1200);
}

// Highlight the section being read.
const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    toc.querySelectorAll('a').forEach((a) => a.classList.toggle('active', a.dataset.target === e.target.id));
  }
}, { root: $('#help-main'), rootMargin: '0px 0px -70% 0px' });
sections.forEach((s) => io.observe(s));

// Search: hide sections without the words, mark matches.
function clearMarks() {
  doc.querySelectorAll('mark.hit').forEach((m) => m.replaceWith(document.createTextNode(m.textContent)));
  doc.normalize();
}
function search(q) {
  clearMarks();
  const words = q.toLowerCase().split(/\s+/).filter((w) => w.length > 1);
  let any = false;
  for (const s of sections) {
    const text = s.textContent.toLowerCase();
    const ok = !words.length || words.every((w) => text.includes(w));
    s.hidden = !ok;
    toc.querySelector(`[data-target="${s.id}"]`)?.toggleAttribute('hidden', !ok);
    any ||= ok;
    if (ok && words.length) {
      const walker = document.createTreeWalker(s, NodeFilter.SHOW_TEXT);
      const nodes = [];
      for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
      const re = new RegExp(`(${words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
      for (const n of nodes) {
        if (!re.test(n.nodeValue)) continue;
        re.lastIndex = 0;
        const span = document.createElement('span');
        span.innerHTML = n.nodeValue.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]).replace(re, '<mark class="hit">$1</mark>');
        n.replaceWith(...span.childNodes);
      }
    }
  }
  $('#help-empty').hidden = any;
}
let timer = 0;
$('#help-q').addEventListener('input', (e) => { clearTimeout(timer); timer = setTimeout(() => search(e.target.value), 150); });
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey && e.key === 'f') || (e.key === '/' && document.activeElement !== $('#help-q'))) { e.preventDefault(); $('#help-q').focus(); }
  if (e.key === 'Escape' && document.activeElement === $('#help-q')) { $('#help-q').value = ''; search(''); }
});

window.addEventListener('hashchange', () => show(location.hash.slice(1)));
on('help.show', (d) => { $('#help-q').value = ''; search(''); show(d.topic); });
on('theme.changed', (d) => { document.documentElement.dataset.theme = d.theme; });
on('lang.changed', () => location.reload());
show(location.hash.slice(1), false);
