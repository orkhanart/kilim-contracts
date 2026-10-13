// Prints the `expected` block for a deploy config: the content and the texts the config is signed off for,
// by hash. The deploy scripts compare every value again (DeployKilim with the manifests, both scripts with
// the config's texts).
//   pnpm -s expected [--config <deploy json>] [--motifs <dir>] [--page <dir>]
// The config (default deploy/mainnet.json) names the two stores (`motifStore`, `pageStore`, unless --motifs
// or --page say otherwise) and the texts. `texts` is script/KilimTexts.sol's hash: sha256 over the eight
// texts the contracts store, in this order, each as its byte length (32 bytes, big-endian) then its bytes:
//   collection.description, collection.externalUrl, oneOfOne.name, oneOfOne.description,
//   oneOfOne.externalUrl, bazaar.description, bazaar.externalUrl, bazaar.imageBase ("" without a bazaar block)
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const option = (name) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? undefined : process.argv[i + 1];
};
const configPath = resolve(CONTRACTS, option('--config') ?? 'deploy/mainnet.json');
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const store = (flag, key) => resolve(option(flag) ? process.cwd() : CONTRACTS, option(flag) ?? config[key]);
const read = (dir) => JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
const motifs = read(store('--motifs', 'motifStore'));
const page = read(store('--page', 'pageStore'));

const bazaar = config.bazaar ?? {};
const texts = [
  ['collection.description', config.collection.description],
  ['collection.externalUrl', config.collection.externalUrl],
  ['oneOfOne.name', config.oneOfOne.name],
  ['oneOfOne.description', config.oneOfOne.description],
  ['oneOfOne.externalUrl', config.oneOfOne.externalUrl],
  ['bazaar.description', bazaar.description ?? ''],
  ['bazaar.externalUrl', bazaar.externalUrl ?? ''],
  ['bazaar.imageBase', bazaar.imageBase ?? ''],
];
for (const [name, text] of texts) {
  if (typeof text !== 'string') {
    console.error(`expected: ${name} in ${configPath} is not a text`);
    process.exit(1);
  }
}
// The token texts must be the ones the stores were packed with (the deploy script refuses otherwise).
const packed = [
  ['collection.description', motifs.description],
  ['collection.externalUrl', motifs.externalUrl],
  ['oneOfOne.name', page.name],
  ['oneOfOne.description', page.description],
  ['oneOfOne.externalUrl', page.externalUrl],
];
for (const [name, text] of packed) {
  if (texts.find(([n]) => n === name)[1] !== text) {
    console.error(`expected: ${name} in ${configPath} differs from the packed store (${JSON.stringify(text)}): re-pack or fix the config`);
    process.exit(1);
  }
}
const textsHash = createHash('sha256');
for (const [, text] of texts) {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(32);
  length.writeBigUInt64BE(BigInt(bytes.length), 24);
  textsHash.update(length).update(bytes);
}

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
    texts: '0x' + textsHash.digest('hex'),
  },
}, null, 2));
console.error(`texts: the eight texts of ${configPath}, as hashed:`);
for (const [name, text] of texts) console.error(`  ${name.padEnd(24)} ${JSON.stringify(text)}`);
if (!page.artwork.readsGrids) console.error('note: this artwork never reads KILIM_GRIDS; mainnet refuses it.');
if (motifs.duplicateGrids.length) console.error('note: motifs drawn identically: ' + JSON.stringify(motifs.duplicateGrids));
