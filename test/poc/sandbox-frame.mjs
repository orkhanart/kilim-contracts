// PoC: how a marketplace frame runs the 1/1. Opens the exact animation_url the contract answers
// (onchain/build-page/animation.html, base64) in headless Chrome under the conditions marketplaces
// impose, and reports what the artwork sees:
//   1. an <iframe sandbox="allow-scripts"> (opaque origin, as OpenSea-style embeds do)
//   2. an <iframe sandbox="allow-scripts allow-same-origin">
//   3. an <iframe> without sandbox
//   4. top level, with DecompressionStream removed before the loader runs (the fallback path)
//   5. top level, which loader globals survive document.open() into the artwork's scope
//   6. an artwork that declares a top-level `const GRIDS` of its own (does the loader's leak break it?)
// Run from contracts/: node test/poc/sandbox-frame.mjs   (needs Chrome and onchain/build-page)
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findChrome } from '../../../onchain/test/chrome.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const sha256 = (d) => '0x' + createHash('sha256').update(d).digest('hex');
const CHROME_ARGS = ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-webgl'];

const PROBE = `(function () {
  var a = document.querySelector('#art[data-renderer]');
  var storage; try { void localStorage; storage = 'ok'; } catch (e) { storage = e.name; }
  return {
    href: location.href.slice(0, 30), origin: location.origin, title: document.title,
    renderer: a ? a.dataset.renderer : null, reason: a ? (a.dataset.fallbackReason || null) : null,
    body: document.body ? document.body.textContent.slice(0, 100) : null,
    kilimGrids: typeof KILIM_GRIDS === 'string' ? KILIM_GRIDS.length : typeof KILIM_GRIDS,
    GRIDS: typeof GRIDS, BLOB: typeof BLOB, storage: storage,
    decompression: typeof DecompressionStream
  };
})()`;

/** A browser-level DevTools client with flattened sessions, so frames in other processes are reachable. */
async function launch(chrome, args) {
  const profile = mkdtempSync(join(tmpdir(), 'kilim-poc-'));
  const child = spawn(chrome, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--mute-audio', '--hide-scrollbars', '--allow-file-access-from-files', `--user-data-dir=${profile}`,
    '--remote-debugging-port=0', ...args, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  const port = await new Promise((resolve, reject) => {
    let err = '';
    const t = setTimeout(() => reject(new Error('no DevTools: ' + err.slice(-300))), 30_000);
    child.stderr.on('data', (d) => { err += d; const m = /DevTools listening on ws:\/\/[^:]+:(\d+)\//.exec(err); if (m) { clearTimeout(t); resolve(Number(m[1])); } });
    child.on('exit', (c) => { clearTimeout(t); reject(new Error('Chrome exited ' + c + ': ' + err.slice(-300))); });
  });
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.addEventListener('open', res, { once: true }); ws.addEventListener('error', () => rej(new Error('ws')), { once: true }); });
  let id = 0;
  const pending = new Map();
  const listeners = [];
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
    else for (const l of listeners) l(m);
  });
  const send = (method, params = {}, sessionId) => new Promise((res, rej) => { const n = ++id; pending.set(n, { res, rej }); ws.send(JSON.stringify({ id: n, method, params, sessionId })); });
  const close = () => { try { child.kill('SIGKILL'); } catch { /* gone */ } try { rmSync(profile, { recursive: true, force: true }); } catch { /* held */ } };
  return { send, listeners, close };
}

/** One scenario: a fresh page target, every frame's default context probed until the artwork starts. */
async function scenario(browser, { name, url, beforeLoad = null, timeoutMs = 30_000 }) {
  const { send, listeners } = browser;
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId: top } = await send('Target.attachToTarget', { targetId, flatten: true });
  const sessions = new Set([top]);
  const contexts = new Map(); // `${session}:${contextId}` -> { session, contextId, frameId, origin }
  const exceptions = [];
  const onMessage = async (m) => {
    if (m.method === 'Target.attachedToTarget' && m.params.targetInfo.type === 'iframe') {
      const s = m.params.sessionId;
      sessions.add(s);
      try { await send('Runtime.enable', {}, s); if (beforeLoad) await send('Page.addScriptToEvaluateOnNewDocument', { source: beforeLoad }, s); } catch { /* gone */ }
    } else if (m.method === 'Runtime.executionContextCreated' && sessions.has(m.sessionId)) {
      const c = m.params.context;
      if (c.auxData && c.auxData.isDefault) contexts.set(`${m.sessionId}:${c.id}`, { session: m.sessionId, contextId: c.id, frameId: c.auxData.frameId, origin: c.origin });
    } else if (m.method === 'Runtime.executionContextDestroyed' && sessions.has(m.sessionId)) {
      contexts.delete(`${m.sessionId}:${m.params.executionContextId}`);
    } else if (m.method === 'Runtime.exceptionThrown' && sessions.has(m.sessionId)) {
      const d = m.params.exceptionDetails;
      exceptions.push((d.exception && d.exception.description) || d.text);
    }
  };
  listeners.push(onMessage);
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, top);
  await send('Page.enable', {}, top);
  await send('Runtime.enable', {}, top);
  if (beforeLoad) await send('Page.addScriptToEvaluateOnNewDocument', { source: beforeLoad }, top);
  await send('Emulation.setDeviceMetricsOverride', { width: 900, height: 900, deviceScaleFactor: 1, mobile: false }, top);
  await send('Page.navigate', { url }, top);
  const t0 = Date.now();
  let found = null;
  const seen = new Map();
  while (!found && Date.now() - t0 < timeoutMs) {
    for (const c of [...contexts.values()]) {
      try {
        const r = await send('Runtime.evaluate', { expression: PROBE, contextId: c.contextId, returnByValue: true }, c.session);
        if (r.exceptionDetails || !r.result.value) continue;
        const v = r.result.value;
        seen.set(`${c.session}:${c.contextId}`, { origin: c.origin, ...v });
        if (v.renderer || (v.body && /cannot open|could not be opened/.test(v.body))) found = { origin: c.origin, ...v };
      } catch { /* context went away (document.open) */ }
    }
    if (!found) await new Promise((r) => setTimeout(r, 100));
  }
  const elapsed = Date.now() - t0;
  listeners.splice(listeners.indexOf(onMessage), 1);
  try { await send('Target.closeTarget', { targetId }); } catch { /* gone */ }
  return { name, elapsed, found, frames: [...seen.values()], exceptions };
}

function wrapper(dir, name, iframeAttrs, src) {
  const file = join(dir, name + '.html');
  writeFileSync(file, `<!doctype html><html><body style="margin:0"><iframe ${iframeAttrs} src="${src}" style="width:900px;height:900px;border:0"></iframe></body></html>`);
  return 'file://' + file;
}

async function main() {
  const chrome = findChrome();
  if (!chrome) { console.log('no Chrome: set CHROME_PATH'); return; }
  const buildPage = process.env.KILIM_PAGE_STORE || here('../../../onchain/build-page');
  if (!existsSync(join(buildPage, 'manifest.json'))) { console.log('no page store at ' + buildPage); return; }
  const manifest = JSON.parse(readFileSync(join(buildPage, 'manifest.json'), 'utf8'));
  const page = readFileSync(join(buildPage, 'animation.html'));
  const animationUrl = 'data:text/html;base64,' + page.toString('base64');
  if (sha256(Buffer.from(animationUrl, 'ascii')) !== manifest.golden.animationUrl.sha256) throw new Error('animation.html does not match the golden animation_url');
  console.log(`animation_url: ${animationUrl.length} chars (Chromium url::kMaxURLChars is 2,097,152)`);

  // 6: an artwork of its own with a top-level `const GRIDS`, packed the normal way
  const dir = mkdtempSync(join(tmpdir(), 'kilim-poc-pages-'));
  const synthetic = readFileSync(here('../../../onchain/test/fixtures/synthetic-artwork.html'), 'utf8');
  const clashing = synthetic.replace('<body>', "<body><script>const GRIDS='mine';</script>");
  writeFileSync(join(dir, 'clash.html'), clashing);
  writeFileSync(join(dir, 'grids.bin'), Buffer.alloc(32768, 0x5a));
  const r = spawnSync('python3', [here('../../../onchain/pack_page.py'), join(dir, 'clash.html'), here('../../../onchain/test/fixtures/still-placeholder.png'),
    join(dir, 'out'), '--grids', join(dir, 'grids.bin'), '--name', 'n', '--description', 'd'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('pack_page failed: ' + r.stderr);
  const clashUrl = 'data:text/html;base64,' + readFileSync(join(dir, 'out', 'animation.html')).toString('base64');

  const browser = await launch(chrome, CHROME_ARGS);
  const results = [];
  try {
    results.push(await scenario(browser, { name: '1 iframe sandbox="allow-scripts"', url: wrapper(dir, 's1', 'sandbox="allow-scripts"', animationUrl) }));
    results.push(await scenario(browser, { name: '2 iframe sandbox="allow-scripts allow-same-origin"', url: wrapper(dir, 's2', 'sandbox="allow-scripts allow-same-origin"', animationUrl) }));
    results.push(await scenario(browser, { name: '3 iframe, no sandbox', url: wrapper(dir, 's3', '', animationUrl) }));
    results.push(await scenario(browser, { name: '4 top level, DecompressionStream removed', url: animationUrl, beforeLoad: 'delete window.DecompressionStream;', timeoutMs: 15_000 }));
    results.push(await scenario(browser, { name: '5 top level, loader globals in the artwork', url: animationUrl }));
    results.push(await scenario(browser, { name: '6 artwork with its own top-level const GRIDS', url: clashUrl, timeoutMs: 8_000 }));
  } finally {
    browser.close();
    rmSync(dir, { recursive: true, force: true });
  }
  for (const r of results) {
    console.log(`\n== ${r.name} (${r.elapsed} ms)`);
    console.log('   artwork:', r.found ? JSON.stringify(r.found) : 'NOT STARTED');
    if (!r.found) for (const f of r.frames) console.log('   frame seen:', JSON.stringify(f));
    if (r.exceptions.length) console.log('   exceptions:', JSON.stringify(r.exceptions));
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
