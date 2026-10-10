// PoC (site review, 10 October 2026): no build path produces a public page a bidder can bid from.
// Run from contracts/ (needs only python3 and the checked-in site/):
//   node test/poc/site-live-build.poc.mjs
// Cases, each against site/chains/1.json with three addresses and a deployBlock written in, which is
// exactly what `pnpm site-config --chain 1 …` writes the day the contracts are on mainnet:
//   1. `site/build.py --target orkhanart` (and the plain local build) refuse with "Native ETH
//      migration is pending", a lock from commit 59cabf91; the contracts have been native ETH since
//      aa8189fe and the message no longer describes anything.
//   2. With that one guard taken out, the public auction.html is composed from auction-info.part.html
//      and auction-info.js (build.py lines 341 and 347): <html data-mode="live">, the sign-up hidden by
//      the live-mode CSS, a disabled "Coming soon" button, no bid field, no bid call. check_published
//      lets it through (the only mode check is "soon pages must say soon").
//   3. The bidding page (auction.part.html + auction.js, today built only with --dev together with the
//      dev wallet and panel) passes check_published when built for a live public config without the
//      dev scripts: the fix the finding suggests needs no new copy rule.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = resolve(dirname(fileURLToPath(import.meta.url)), '../../../site');
const BUILD = join(SITE, 'build.py');
const GUARD = "    if not dev and any(is_live(cfg) for cfg in chains.values()):\n"
  + "        fail('Native ETH migration is pending; public builds must remain previews with no deployed addresses.')\n";

// Runs site/build.py with `replacements` ([old, new] pairs) applied to its source in memory, so its
// own paths (site/, onchain/) still resolve. No replacements = the script as checked in.
const DRIVER = `
import json, pathlib, sys
path, reps = sys.argv[1], json.loads(sys.argv[2])
src = pathlib.Path(path).read_text()
for a, b in reps:
    assert src.count(a) == 1, a
    src = src.replace(a, b)
sys.argv = ['build.py'] + sys.argv[3:]
exec(compile(src, path, 'exec'), {'__name__': '__main__', '__file__': path})
`;
function build(replacements, args) {
  return spawnSync('python3', ['-c', DRIVER, BUILD, JSON.stringify(replacements), ...args], { encoding: 'utf8' });
}

const work = mkdtempSync(join(tmpdir(), 'kilim-live-build-'));
const chains = join(work, 'chains'); mkdirSync(chains);
try {
  for (const f of ['1.json', '11155111.json']) writeFileSync(join(chains, f), readFileSync(join(SITE, 'chains', f)));
  const mainnet = JSON.parse(readFileSync(join(chains, '1.json'), 'utf8'));
  Object.assign(mainnet, { auction: '0x' + '11'.repeat(20), glyphs: '0x' + '22'.repeat(20), oneOfOne: '0x' + '33'.repeat(20), deployBlock: 26_100_000 });
  writeFileSync(join(chains, '1.json'), JSON.stringify(mainnet));

  // 1. The public builds refuse a live config, with the stale message.
  for (const target of [['--target', 'orkhanart'], []]) {
    const r = build([], [...target, '--chains', chains, '--out', join(work, 'refused')]);
    console.log(`case 1: build.py ${target.join(' ') || '(local)'} with mainnet addresses → exit ${r.status}:`, r.stderr.trim());
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Native ETH migration is pending/);
  }

  // 2. Without the guard, the public auction page is the read-only one, marked live.
  {
    const out = join(work, 'lifted');
    const r = build([[GUARD, '']], ['--target', 'orkhanart', '--chains', chains, '--out', out]);
    assert.equal(r.status, 0, r.stderr);
    const html = readFileSync(join(out, 'auction.html'), 'utf8');
    const facts = {
      htmlTag: html.match(/^<html[^>]*>/m)[0],
      readOnlyScript: /Read-only presentation of the confirmed launch terms/.test(html),
      inputs: (html.match(/<input\b/g) || []).length,
      placeButton: html.match(/<button class="act" id="place"[^>]*>[^<]*<\/button>/)[0],
      bidCalls: (html.match(/CHAIN\.bid\(|api\.bid\(|\.quote\(/g) || []).length,
      signUpHiddenWhenLive: /html\[data-mode="live"\] \[data-soon\] \{ display: none/.test(html) && /data-soon>Get notified/.test(html),
    };
    console.log('case 2: guard removed, orkhanart build passed check_published; auction.html →', facts);
    assert.equal(facts.htmlTag, '<html lang="en" data-mode="live">');
    assert.equal(facts.readOnlyScript, true, 'composed from auction-info.js');
    assert.equal(facts.inputs, 0, 'no bid field');
    assert.match(facts.placeButton, /disabled>Coming soon</);
    assert.equal(facts.bidCalls, 0, 'nothing on the page can place a bid');
  }

  // 3. The bidding page passes the copy guard when built for a live public config without the dev scripts.
  {
    const out = join(work, 'fixed');
    const r = build([
      [GUARD, ''],
      ["part = src('auction-info.part.html' if not dev else 'auction.part.html')", "part = src('auction.part.html' if (dev or live) else 'auction-info.part.html')"],
      ["script(src('auction-info.js' if not dev else 'auction.js'))", "script(src('auction.js' if (dev or live) else 'auction-info.js'))"],
    ], ['--target', 'orkhanart', '--chains', chains, '--out', out]);
    assert.equal(r.status, 0, r.stderr);
    const html = readFileSync(join(out, 'auction.html'), 'utf8');
    const facts = {
      htmlTag: html.match(/^<html[^>]*>/m)[0],
      inputs: (html.match(/<input\b/g) || []).length,
      devCode: (html.match(/devwallet|KILIM_DEV|127\.0\.0\.1/g) || []).length,
      readOnlyScript: /Read-only presentation of the confirmed launch terms/.test(html),
    };
    console.log('case 3: bidding page for a live public config, no dev scripts, check_published passed →', facts);
    assert.ok(facts.inputs > 0 && facts.devCode === 0 && !facts.readOnlyScript);
  }
  console.log('done');
} finally { rmSync(work, { recursive: true, force: true }); }
