// Point the site at a real deployment (Sepolia rehearsal or Ethereum mainnet) after checking it.
//
//   pnpm site-config --chain 11155111 --auction 0x… --block 12345678 [--rpc https://…] [--allow-started]
//   (--config <file> targets another config file with the same shape; the tests use it)
//
// Reads the chain's own config (site/chains/<id>.json), verifies the auction on that chain, and
// writes auction, collection and deployBlock into the config. Then rebuild: python3 site/build.py
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSite } from '../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const site = resolve(here, '../../site');
const { KILIM_ABI: A, KILIM_RPC: R } = loadSite();
const args = process.argv.slice(2);
const value = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
function die(msg) { console.error(`site-config: ${msg}`); process.exit(1); }

const chainId = Number(value('--chain'));
const auction = value('--auction');
const block = Number(value('--block'));
if (![1, 11155111].includes(chainId)) die('--chain must be 1 (Ethereum) or 11155111 (Sepolia)');
if (!A.isValidInputAddress(auction || '')) die('--auction must be an address');
if (!Number.isSafeInteger(block) || block <= 0) die('--block must be the auction deployment block');

const path = value('--config') ? resolve(value('--config')) : resolve(site, `chains/${chainId}.json`);
const cfg = JSON.parse(readFileSync(path, 'utf8'));
if (cfg.chainId !== chainId) die(`${path} is for chain ${cfg.chainId}`);
const rpc = R.http([value('--rpc') ?? cfg.rpcUrls[0]]);
const hex = (n) => '0x' + n.toString(16);
async function call(to, f, args = [], tag = 'latest') {
  return f.decode(await rpc.request({ method: 'eth_call', params: [{ to, data: f.encode(args) }, tag] }))[0];
}

const id = Number(await rpc.request({ method: 'eth_chainId' }));
if (id !== chainId) die(`the RPC answers for chain ${id}, not ${chainId}`);
const a = auction.toLowerCase();
const codeAt = (addr, tag) => rpc.request({ method: 'eth_getCode', params: [addr, tag] });
if ((await codeAt(a, 'latest')) === '0x') die('no contract at the auction address');
if ((await codeAt(a, hex(block))) === '0x') die(`no auction code at block ${block}: that is not the deployment block`);
if ((await codeAt(a, hex(block - 1))) !== '0x') die(`the auction already existed at block ${block - 1}: pass the deployment block`);
const F = A.F;
const collection = (await call(a, F.auction.collection)).toLowerCase();
if ((await codeAt(collection, 'latest')) === '0x') die('auction.collection() has no code');
const token = (await call(a, F.auction.paymentToken)).toLowerCase();
if (token !== cfg.usdc.toLowerCase()) die(`paymentToken() is ${token}, not the configured USDC ${cfg.usdc}`);
const unit = await call(a, F.auction.tokenUnit);
if (unit !== 1_000_000n) die(`tokenUnit() is ${unit}, not 1e6`);
const endsAt = await call(a, F.auction.endsAt);
if (endsAt !== 0n && !args.includes('--allow-started')) die('endsAt() is not 0: the auction already has bids (pass --allow-started to accept)');
const motifs = Number(await call(collection, F.collection.motifCount));
if (motifs !== 812) die(`collection.motifCount() is ${motifs}; the site draws 812`);

const facts = {
  startsAt: new Date(Number(await call(a, F.auction.startsAt)) * 1000).toISOString(),
  duration: `${Number(await call(a, F.auction.duration))} s`,
  extensionWindow: `${Number(await call(a, F.auction.extensionWindow))} s`,
  incrementBps: Number(await call(a, F.auction.incrementBps)),
  reservePrice: `${Number(await call(a, F.auction.reservePrice)) / 1e6} USDC`,
  symbolCap: String(await call(a, F.auction.symbolCap)),
  maxSymbolsPerBid: String(await call(a, F.auction.maxSymbolsPerBid)),
  treasury: A.checksum(await call(a, F.auction.treasury)),
  maxCells: Number(await call(collection, F.collection.maxCells)),
};
console.table(facts);

cfg.auction = A.checksum(a);
cfg.collection = A.checksum(collection);
cfg.deployBlock = block;
writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
console.log(`Wrote ${path}.\nNext: python3 site/build.py, then publish site/index.html, auction.html and merge.html.`);
