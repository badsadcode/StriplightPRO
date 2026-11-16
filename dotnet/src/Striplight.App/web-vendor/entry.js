// TOAST UI Editor 3 is built on ProseMirror; esbuild pulls the prosemirror-* packages
// into one self-contained file so the app works offline (no CDN).
import Editor from '@toast-ui/editor';

window.toastui = Object.assign(window.toastui || {}, { Editor });
