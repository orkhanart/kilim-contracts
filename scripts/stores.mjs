// Packs, or checks, the two stores the contracts are deployed from, with the texts of a deploy config:
//   onchain/build-motifs  from the artist's page (the 1,024 motifs)
//   onchain/build-page    from the release copy of the artwork and its still
//
//   pnpm -s stores          write both (and the small fixture stores the deploy tests read)
//   pnpm -s check:stores    fail unless both are exactly what the inputs and the config give
//   options: --config <deploy json> (default deploy/local.json), --page-source <html>,
//            --artwork <html>, --still <png|webp>
//
// The release copy (mint/artwork.html) must be the page the motifs are read from, byte for byte: one
// file is the artwork, and its hash is what gets published.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const V3 = resolve(CONTRACTS, '../research/motifs/curate/living-language-v3');
const args = process.argv.slice(2);
const check = args.includes('--check');
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return resolve(i < 0 ? fallback : args[i + 1]);
};
const config = JSON.parse(readFileSync(opt('--config', resolve(CONTRACTS, 'deploy/local.json')), 'utf8'));
const pageSource = opt('--page-source', resolve(V3, 'index.html'));
const artwork = opt('--artwork', resolve(V3, 'mint/artwork.html'));
const still = opt('--still', resolve(V3, 'mint/still.webp'));
const motifStore = resolve(CONTRACTS, config.motifStore);
const pageStore = resolve(CONTRACTS, config.pageStore);
const sha = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');

if (sha(pageSource) !== sha(artwork)) {
  console.error(`stores: ${artwork} is not ${pageSource}: the release copy is stale (rebuild mint/ in the artwork's source).`);
  process.exit(1);
}
const run = (script, list) => {
  const r = spawnSync('python3', [resolve(CONTRACTS, '../onchain', script), ...list, ...(check ? ['--check'] : [])], { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
};
run('pack_motifs.py', [pageSource, motifStore, '--description', config.collection.description,
  '--external-url', config.collection.externalUrl]);
run('pack_page.py', [artwork, still, pageStore, '--grids', resolve(motifStore, 'grids.bin'),
  '--name', config.oneOfOne.name, '--description', config.oneOfOne.description,
  '--external-url', config.oneOfOne.externalUrl]);
if (!check) {
  const r = spawnSync('python3', [resolve(CONTRACTS, '../onchain/test/pack_fixtures.py')], { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
}
