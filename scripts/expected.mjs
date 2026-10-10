// Prints the `expected` block for a deploy config from the two packed stores: the content the config
// is signed off for, by hash. The deploy script compares every value with the manifests again.
//   pnpm -s expected [--motifs <dir>] [--page <dir>]
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return resolve(i < 0 ? resolve(CONTRACTS, fallback) : process.argv[i + 1]);
};
const read = (dir) => JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
const motifs = read(arg('--motifs', '../onchain/build-motifs'));
const page = read(arg('--page', '../onchain/build-page'));

console.log(JSON.stringify({
  expected: {
    gridsHash: motifs.hashes.gridsHash,
    namesHash: motifs.hashes.namesHash,
    prefixHash: page.hashes.prefixHash,
    headHash: page.hashes.headHash,
    tailHash: page.hashes.tailHash,
    motifGolden: motifs.golden.tokenURI.sha256,
    oneOfOneGolden: page.golden.tokenURI.sha256,
    motifSource: motifs.source.sha256,
    artwork: page.artwork.sha256,
    still: page.still.sha256,
    loader: page.loaderTemplate.sha256,
  },
}, null, 2));
if (!page.artwork.readsGrids) console.error('note: this artwork never reads KILIM_GRIDS; mainnet refuses it.');
if (motifs.duplicateGrids.length) console.error('note: motifs drawn identically: ' + JSON.stringify(motifs.duplicateGrids));
