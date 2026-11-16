// Page side of the JSON bridge (host side: Bridge/BridgeHost.cs).
//   call('project.open', { path })  -> Promise resolving with the handler result
//   on('export.progress', fn)       -> host events

const webview = window.chrome && window.chrome.webview;
const pending = new Map();
const listeners = new Map();
let nextId = 1;

export const inHost = !!webview;

if (webview) {
  webview.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg && msg.event) {
      for (const fn of listeners.get(msg.event) || []) {
        try { fn(msg.data); } catch (err) { console.error(err); }
      }
      return;
    }
    const p = msg && pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.ok) p.resolve(msg.result);
    else p.reject(new Error(msg.error || 'Unknown error'));
  });
}

export function call(cmd, args = {}) {
  if (!webview) {
    return Promise.reject(new Error('Striplight PRO must run inside its desktop window (WebView2).'));
  }
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    webview.postMessage({ id, cmd, args });
  });
}

export function on(event, fn) {
  if (!listeners.has(event)) listeners.set(event, []);
  listeners.get(event).push(fn);
}
