// PoC: do the loader's top-level names survive document.open() into the artwork's scope?
//
// The loader (onchain/loader.html) holds the grids and the gzipped artwork in two consts, then
// replaces itself with document.open()/write()/close(). The HTML standard's document.open() keeps
// the Window, so a `const` declared at the top level of the loader's script stays in the global
// lexical environment the artwork's scripts are then instantiated in. An artwork that declares the
// same name at its top level fails GlobalDeclarationInstantiation with a SyntaxError and that
// script never runs. This packs five artworks with the loader as it was at HEAD (top-level consts)
// and as it is in the working tree (one block), opens each in headless Chrome and reports:
//   - typeof GRIDS / BLOB / KILIM_GRIDS inside the artwork document
//   - whether the artwork started (#art[data-renderer]) and every uncaught exception
// Artworks (from onchain/test/fixtures/synthetic-artwork.html):
//   plain             the fixture as it is
//   separate-const    <script>const GRIDS='mine';</script> before the artwork's own script
//   main-const        `const GRIDS='mine';` at the top of the artwork's own (only) script
//   main-var          `var GRIDS;` there (a var clashes with a lexical binding too)
//   main-function     `function BLOB(){}` there
// Run from contracts/: node test/poc/loader-globals.mjs   (needs Chrome, python3, git)
// Exit 1 if the working-tree loader still leaks either name or any artwork fails to start with it.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findChrome, openPage } from '../../../onchain/test/chrome.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const ONCHAIN = here('../../../onchain');
const REPO = here('../../..');
const CHROME_ARGS = ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-webgl'];

const PACK = `
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import pack_page as P
template, artwork, still, grids = (Path(p).read_bytes() for p in sys.argv[2:6])
out = P.build(artwork, still, grids, 'n', 'd', template=template)
Path(sys.argv[6]).write_bytes(out['animation.html'])
`;

// "loader" when the name holds what the loader declared (the 65,536-char hex grids, the base64
// blob), "artwork" when it holds the artwork's own declaration, else its typeof.
const PROBE = `(function () {
  var a = document.querySelector('#art[data-renderer]');
  function who(t, v, loaders) { return t === 'undefined' ? 'undefined' : loaders(v) ? 'loader' : 'artwork'; }
  var g = typeof GRIDS, b = typeof BLOB;
  return {
    renderer: a ? a.dataset.renderer : null,
    GRIDS: who(g, g === 'undefined' ? null : GRIDS, function (v) { return typeof v === 'string' && /^[0-9a-f]{65536}$/.test(v); }),
    BLOB: who(b, b === 'undefined' ? null : BLOB, function (v) { return typeof v === 'string' && v.length > 100 && /^[A-Za-z0-9+\\/=]+$/.test(v); }),
    KILIM_GRIDS: typeof KILIM_GRIDS,
    body: document.body ? document.body.textContent.slice(0, 80) : null
  };
})()`;

function loaders() {
  const head = spawnSync('git', ['-C', REPO, 'show', 'HEAD:onchain/loader.html'], { encoding: 'buffer' });
  if (head.status !== 0) throw new Error('git show failed: ' + head.stderr);
  return { 'HEAD loader': head.stdout, 'working-tree loader': readFileSync(join(ONCHAIN, 'loader.html')) };
}

function artworks() {
  const fixture = readFileSync(join(ONCHAIN, 'test/fixtures/synthetic-artwork.html'), 'utf8');
  const mainScript = '<script>\n// A stand-in';
  if (!fixture.includes(mainScript) || !fixture.includes('<body>')) throw new Error('the synthetic fixture changed shape');
  const inMain = (decl) => fixture.replace(mainScript, '<script>' + decl + '\n// A stand-in');
  return {
    'plain': fixture,
    'separate-const': fixture.replace('<body>', "<body><script>const GRIDS='mine';</script>"),
    'main-const': inMain("const GRIDS='mine';"),
    'main-var': inMain('var GRIDS;'),
    'main-function': inMain('function BLOB(){}'),
  };
}

async function run(url, timeoutMs) {
  const page = await openPage(url, { width: 300, height: 300, record: true, timeoutMs: 30_000, args: CHROME_ARGS });
  try {
    const t0 = Date.now();
    let probe = null;
    while (Date.now() - t0 < timeoutMs) {
      probe = await page.evaluate(PROBE);
      if (probe.renderer || /cannot open|could not be opened/.test(probe.body || '')) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    // the stack of an exception from a data: URL page carries the whole URL: keep the first line
    return { ...probe, exceptions: page.errors().map((e) => String(e).split('\n')[0]) };
  } finally {
    await page.close();
  }
}

async function main() {
  const chrome = findChrome();
  if (!chrome) { console.log('no Chrome: set CHROME_PATH'); process.exit(2); }
  const dir = mkdtempSync(join(tmpdir(), 'kilim-loader-globals-'));
  const still = join(ONCHAIN, 'test/fixtures/still-placeholder.png');
  const grids = join(dir, 'grids.bin');
  writeFileSync(grids, Buffer.alloc(32768, 0x5a));
  let bad = 0;
  try {
    for (const [loaderName, template] of Object.entries(loaders())) {
      const templateFile = join(dir, loaderName.replace(/\W+/g, '-') + '.html');
      writeFileSync(templateFile, template);
      console.log(`\n== ${loaderName} (${template.length} bytes)`);
      for (const [artName, html] of Object.entries(artworks())) {
        const artFile = join(dir, artName + '.html');
        const pageFile = join(dir, artName + '-' + loaderName.replace(/\W+/g, '-') + '.animation.html');
        writeFileSync(artFile, html);
        const r = spawnSync('python3', ['-c', PACK, ONCHAIN, templateFile, artFile, still, grids, pageFile], { encoding: 'utf8' });
        if (r.status !== 0) throw new Error('pack_page.build failed: ' + r.stderr);
        const url = 'data:text/html;base64,' + readFileSync(pageFile).toString('base64');
        const res = await run(url, 6_000);
        const started = res.renderer === 'Canvas2D';
        const leaks = res.GRIDS === 'loader' || res.BLOB === 'loader';
        if (loaderName === 'working-tree loader' && (!started || leaks)) bad++;
        console.log(`   ${artName.padEnd(15)} started=${started ? 'yes' : 'NO '} renderer=${String(res.renderer).padEnd(8)} ` +
          `GRIDS=${res.GRIDS.padEnd(9)} BLOB=${res.BLOB.padEnd(9)} KILIM_GRIDS=${res.KILIM_GRIDS}`);
        if (res.exceptions.length) console.log('      exceptions:', JSON.stringify(res.exceptions));
        if (!started) console.log('      body:', JSON.stringify(res.body));
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log(bad ? `\n${bad} artwork(s) leak or fail with the working-tree loader` : '\nworking-tree loader: no leak, every artwork started');
  process.exit(bad ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
