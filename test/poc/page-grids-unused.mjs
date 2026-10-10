// PoC: does the 1/1 page draw from the grids the contract hands it (KILIM_GRIDS), or from its own
// inline copy? CONTRACTS.md ("KilimOneOfOne", tokenURI) reads the grids live from KilimGlyphs so
// that "the 1/1 provably draws the same glyphs the glyph NFTs show". That is only true of a page
// that builds its glyphs from window.KILIM_GRIDS. onchain/test/page.test.mjs checks the global is
// defined and equals the grids, and that #art[data-renderer] appears; it cannot see whether the
// artwork used it.
//
// This packs the stand-in (onchain/test/fixtures/lean.html, the v3 build with the painter) twice
// with pack_page.build: once against the real grids (onchain/build-glyphs/grids.bin) and once
// against different, random grids. Both pages get the frozen clock onchain/painter/compare.mjs
// uses, are stepped to the same moments and their canvases are screenshotted. It reports:
//   - how many times each artwork's source names KILIM_GRIDS (also the v3 page in research/)
//   - inside the page: how many of the 1,024 glyphs in the artwork's own DATA.symbols equal the
//     glyph at the same index in KILIM_GRIDS (real grids: all; random grids: none, if ignored)
//   - whether the two pictures are byte-identical despite different grids
// Run from contracts/: node test/poc/page-grids-unused.mjs   (needs Chrome and python3)
// Exit 1 when the stand-in draws the same picture from different grids (the finding stands),
// 0 when the picture or the glyph table follows KILIM_GRIDS, 2 without Chrome or the stand-in.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findChrome, openPage } from '../../../onchain/test/chrome.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const ONCHAIN = here('../../../onchain');
const REPO = here('../../..');
const CHROME_ARGS = ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-webgl'];
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

const PACK = `
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import pack_page as P
artwork, still, grids = (Path(p).read_bytes() for p in sys.argv[2:5])
out = P.build(artwork, still, grids, 'The Unwoven Kilim', 'PoC page.')
Path(sys.argv[5]).write_bytes(out['animation.html'])
`;

// The same frozen clock as onchain/painter/compare.mjs, plus a seeded Math.random, so two runs of
// the page land on the same frame and only the grids can differ.
const CLOCK = `<script>(()=>{let now=1000,queue=[],id=0;performance.now=()=>now;
window.requestAnimationFrame=f=>{queue.push([++id,f]);return id};
window.cancelAnimationFrame=i=>{queue=queue.filter(e=>e[0]!==i)};
let s=0x9e3779b9;Math.random=()=>{s=(Math.imul(s,1664525)+1013904223)>>>0;return s/4294967296};
window.__step=(ms,times=1)=>{for(let k=0;k<times;k++){now+=ms;const run=queue;queue=[];for(const e of run)e[1](now)}};})();</script>`;

const READY = `new Promise((done,fail)=>{const t0=Date.now();(function wait(){const a=document.getElementById('art');
if(a&&a.dataset.renderer)return done(a.dataset.renderer);
if(Date.now()-t0>60000)return fail(new Error('the artwork did not start'));setTimeout(wait,50)})()})`;

// The artwork's own glyph table against the injected grids: glyph i of DATA.symbols as 64 hex
// characters (16 rows of 16 bits) versus KILIM_GRIDS.substr(i*64, 64).
const PROBE = `(()=>{
  const g = typeof KILIM_GRIDS === 'string' ? KILIM_GRIDS : null;
  const syms = (typeof DATA === 'object' && DATA && Array.isArray(DATA.symbols)) ? DATA.symbols : null;
  let same = 0, total = 0;
  if (g && syms) for (let i = 0; i < syms.length; i++) {
    const hex = syms[i].rows.map(r => parseInt(r, 2).toString(16).padStart(4, '0')).join('');
    total++; if (hex === g.substr(i * 64, 64)) same++;
  }
  const a = document.getElementById('art'), r = a.getBoundingClientRect();
  return JSON.stringify({ grids: g ? g.slice(0, 16) : null, hasData: !!syms, same, total,
    time: a.dataset.time, pattern: a.dataset.pattern, glyphs: a.dataset.glyphs,
    box: [r.left, r.top, r.width, r.height], size: [a.width, a.height] });
})()`;

function randomGrids(seed) {
  const out = Buffer.alloc(32768);
  let x = seed >>> 0;
  for (let i = 0; i < out.length; i++) { x = (Math.imul(x, 1103515245) + 12345) >>> 0; out[i] = x >>> 24; }
  return out;
}

function mentions(file) {
  if (!existsSync(file)) return 'absent';
  const s = readFileSync(file, 'utf8');
  return String(s.split('KILIM_GRIDS').length - 1);
}

async function open(pageFile) {
  const url = 'data:text/html;base64,' + readFileSync(pageFile).toString('base64');
  const page = await openPage(url, { width: 900, height: 900, record: true, timeoutMs: 60_000, args: CHROME_ARGS, callTimeoutMs: 120_000 });
  try {
    const renderer = await page.evaluate(READY);
    await page.evaluate('__step(40,3)');
    const early = JSON.parse(await page.evaluate(PROBE));
    const shotA = await page.screenshot({ clip: { x: early.box[0], y: early.box[1], width: early.box[2], height: early.box[3] } });
    await page.evaluate('__step(80,20)');
    const late = JSON.parse(await page.evaluate(PROBE));
    const shotB = await page.screenshot({ clip: { x: late.box[0], y: late.box[1], width: late.box[2], height: late.box[3] } });
    return { renderer, early, late, shots: [sha256(shotA), sha256(shotB)], errors: page.errors().map((e) => String(e).split('\n')[0]) };
  } finally {
    await page.close();
  }
}

async function main() {
  const lean = join(ONCHAIN, 'test/fixtures/lean.html');
  console.log('KILIM_GRIDS mentioned in the source:');
  for (const [label, file] of [
    ['stand-in onchain/test/fixtures/lean.html', lean],
    ['v3 research/motifs/curate/living-language-v3/index.html', join(REPO, 'research/motifs/curate/living-language-v3/index.html')],
    ['synthetic fixture (reads it)', join(ONCHAIN, 'test/fixtures/synthetic-artwork.html')],
  ]) console.log(`   ${mentions(file).padStart(6)}  ${label}`);
  if (!findChrome()) { console.log('no Chrome: set CHROME_PATH'); process.exit(2); }
  if (!existsSync(lean)) { console.log('no stand-in: build onchain/test/fixtures/lean.html first'); process.exit(2); }

  const html = readFileSync(lean, 'utf8');
  const at = html.indexOf('<script>const DATA=');
  if (at < 0) throw new Error('lean.html has no data block');
  const dir = mkdtempSync(join(tmpdir(), 'kilim-page-grids-'));
  const still = join(ONCHAIN, 'test/fixtures/still-placeholder.png');
  const realGrids = join(ONCHAIN, 'build-glyphs/grids.bin');
  const runs = {
    real: existsSync(realGrids) ? readFileSync(realGrids) : randomGrids(0x2545f491),
    random: randomGrids(0x1234abcd),
  };
  if (!existsSync(realGrids)) console.log('(onchain/build-glyphs/grids.bin absent: "real" is synthetic too)');
  const results = {};
  try {
    const artFile = join(dir, 'artwork.html');
    writeFileSync(artFile, html.slice(0, at) + CLOCK + html.slice(at));
    for (const [name, grids] of Object.entries(runs)) {
      const gridsFile = join(dir, name + '.grids.bin'), pageFile = join(dir, name + '.animation.html');
      writeFileSync(gridsFile, grids);
      const r = spawnSync('python3', ['-c', PACK, ONCHAIN, artFile, still, gridsFile, pageFile], { encoding: 'utf8' });
      if (r.status !== 0) throw new Error('pack_page.build failed: ' + r.stderr);
      results[name] = await open(pageFile);
      const { renderer, early, late, shots, errors } = results[name];
      console.log(`\n== packed against ${name} grids (sha256 ${sha256(grids).slice(0, 12)}…), renderer ${renderer}`);
      console.log(`   KILIM_GRIDS starts ${early.grids}; artwork DATA.symbols present: ${early.hasData}`);
      console.log(`   glyphs in DATA.symbols equal to the injected glyph at the same index: ${early.same} of ${early.total}`);
      console.log(`   frame 1: time ${early.time}, pattern ${early.pattern}, glyphs ${early.glyphs}, canvas ${early.size.join('x')}, png sha256 ${shots[0].slice(0, 16)}…`);
      console.log(`   frame 2: time ${late.time}, pattern ${late.pattern}, glyphs ${late.glyphs}, canvas ${late.size.join('x')}, png sha256 ${shots[1].slice(0, 16)}…`);
      if (errors.length) console.log('   exceptions:', JSON.stringify(errors));
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  const a = results.real, b = results.random;
  const sameMoment = ['time', 'pattern', 'glyphs'].every((k) => String(a.late[k]) === String(b.late[k]));
  const samePicture = sameMoment && a.shots[0] === b.shots[0] && a.shots[1] === b.shots[1];
  const tableFollows = b.early.total > 0 && b.early.same === b.early.total;
  console.log('');
  if (!sameMoment) console.log('the two runs are not at the same moment; the picture comparison says nothing');
  console.log(`glyph table follows KILIM_GRIDS: ${tableFollows ? 'yes' : 'NO (random grids injected, table unchanged)'}`);
  console.log(`picture identical with different grids: ${samePicture ? 'YES (the page ignores the grids)' : 'no'}`);
  const ignored = samePicture && !tableFollows;
  console.log(ignored ? '\nthe stand-in draws its inline glyphs whatever the contract hands it'
    : '\nthe stand-in draws from the injected grids');
  process.exit(ignored ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
