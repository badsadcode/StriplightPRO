import { build } from 'esbuild';
import { copyFileSync, mkdirSync } from 'node:fs';

const out = '../wwwroot/vendor/toastui';
mkdirSync(out, { recursive: true });

await build({
  entryPoints: ['entry.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['chrome110'],
  legalComments: 'eof',
  outfile: `${out}/toastui-editor.bundle.js`,
});

const dist = 'node_modules/@toast-ui/editor/dist';
copyFileSync(`${dist}/toastui-editor.css`, `${out}/toastui-editor.css`);
copyFileSync(`${dist}/theme/toastui-editor-dark.css`, `${out}/toastui-editor-dark.css`);
copyFileSync('node_modules/prosemirror-view/LICENSE', `${out}/LICENSE-prosemirror.txt`);
console.log('TOAST UI Editor bundle written to', out);
