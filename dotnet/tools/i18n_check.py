"""Translation check for Striplight PRO.

Collects every translatable English string (HTML text and title/aria-label/placeholder,
t()/tn() calls in JS, keymap labels, tone method names, Loc.T in C#) and compares the list
with wwwroot/i18n/<lang>.json. Run after changing UI text:

    python dotnet/tools/i18n_check.py          # checks pl
    python dotnet/tools/i18n_check.py --list   # prints all keys as JSON

The English text is the key. Plural entries (tn) use the English plural form as the key and
an object { "one", "few", "many", "other" } as the value.
"""
import json, os, re, sys
from html.parser import HTMLParser

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src')
WWW = ROOT + '/Striplight.App/wwwroot'
norm = lambda s: re.sub(r'\s+', ' ', s).strip()
keys = {}          # key -> kind ('text' | 'plural')


def add(k, kind='text', raw=False):
    k = norm(k) if kind == 'text' and not raw else k
    if not k or len(re.findall(r'[A-Za-z]', k)) < 2 or re.fullmatch(r'(Ctrl |Shift )*[A-Z]|Ctrl [A-Z]|EN', k):
        return
    keys.setdefault(k, kind)


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []          # (tag, skip)
        self.html_capture = None  # [depth, parts]

    def skipping(self):
        return any(s for _, s in self.stack)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if self.html_capture is not None:
            self.html_capture[1].append(self.get_starttag_text())
        void = tag in ('input', 'br', 'img', 'meta', 'link', 'hr')
        skip = tag in ('script', 'style') or 'data-no-i18n' in a
        if 'data-i18n-html' in a and self.html_capture is None and not void:
            self.html_capture = [len(self.stack) + 1, []]
        for at in ('title', 'aria-label', 'placeholder'):
            if a.get(at) and not self.skipping() and not skip:
                add(a[at])
        if not void:
            self.stack.append((tag, skip))

    def handle_endtag(self, tag):
        if self.stack:
            self.stack.pop()
        if self.html_capture is not None:
            if len(self.stack) < self.html_capture[0]:
                add(''.join(self.html_capture[1]))
                self.html_capture = None
            else:
                self.html_capture[1].append(f'</{tag}>')

    def handle_data(self, d):
        if self.html_capture is not None:
            self.html_capture[1].append(d.replace('&', '&amp;'))
            return
        if not self.skipping():
            add(d)


for f in ('index.html', 'preview.html'):
    src = open(os.path.join(WWW, f), encoding='utf-8').read()
    m = re.search(r'<title>(.*?)</title>', src)
    if m:
        add(m.group(1))
    body = src[src.index('<body'):]
    p = P()
    p.feed(body)

STR = r"""'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)\""""
unq = lambda m: (m.group(1) if m.group(1) is not None else m.group(2)).replace("\\'", "'").replace('\\"', '"').replace('\\n', '\n')
for f in os.listdir(WWW + '/js'):
    if not f.endswith('.js') or f in ('icons.js', 'i18n.js'):
        continue
    src = open(os.path.join(WWW, 'js', f), encoding='utf-8').read()
    for m in re.finditer(r'\bt\(\s*(?:' + STR + r')', src):
        add(unq(m), raw=True)
    for m in re.finditer(r'\btn\([^,]+,\s*(?:' + STR + r')\s*,\s*(?:' + STR + r')', src):
        one = (m.group(1) if m.group(1) is not None else m.group(2))
        other = (m.group(3) if m.group(3) is not None else m.group(4))
        keys.setdefault(other.replace("\\'", "'"), 'plural')
    # t(which ? 'a' : 'b'), labels passed to markerTool, keymap labels/sections
    for m in re.finditer(r"\bt\(\s*[^'\")]+\?\s*'([^']+)'\s*:\s*'([^']+)'", src):
        add(m.group(1)); add(m.group(2))
    if f == 'keymap.js':
        for m in re.finditer(r"section: '([^']+)', label: '([^']+)'", src):
            add(m.group(1)); add(m.group(2))
    if f == 'app.js':
        for m in re.finditer(r"markerTool\(.*'([A-Z][^']+)'\),?$", src, re.M):
            add(m.group(1))
        for lbl in ('Trim', 'Ignore'):
            pass
sv = open(WWW + '/js/stripView.js', encoding='utf-8').read()
for m in re.finditer(r"label: '([^']+)'", sv):
    add(m.group(1))

core = open(ROOT + '/Striplight.Core/Imaging/ToneAdjust.cs', encoding='utf-8').read()
for m in re.finditer(r'=> "([^"]+)",', core[core.index('MethodName'):core.index('IsAdaptive')]):
    add(m.group(1))

for dp, _, fs in os.walk(ROOT + '/Striplight.App'):
    if '/obj' in dp or '/bin' in dp:
        continue
    for f in fs:
        if f.endswith('.cs'):
            src = open(os.path.join(dp, f), encoding='utf-8').read()
            for m in re.finditer(r'Loc\.T\("((?:[^"\\]|\\.)*)"', src):
                add(m.group(1).replace('\\"', '"').replace('\\n', '\n'), raw=True)
            for m in re.finditer(r'ConfirmDiscardOrSave\("([^"]+)"\)', src):
                add(m.group(1))

if '--list' in sys.argv:
    json.dump(keys, sys.stdout, ensure_ascii=False, indent=0)
    sys.exit(0)
lang = next((a for a in sys.argv[1:] if not a.startswith('-')), 'pl')
have = json.load(open(os.path.join(WWW, 'i18n', lang + '.json'), encoding='utf-8'))
missing = [k for k in keys if k not in have]
unused = [k for k in have if k not in keys]
wrong = [k for k, kind in keys.items() if k in have and (kind == 'plural') != isinstance(have[k], dict)]
print(f'{lang}.json: {len(keys)} strings in the app, {len(missing)} missing, {len(unused)} unused, {len(wrong)} plural/text mismatches')
for k in missing: print('  missing:', repr(k))
for k in unused: print('  unused: ', repr(k))
for k in wrong: print('  plural? ', repr(k))
sys.exit(1 if missing or wrong else 0)
