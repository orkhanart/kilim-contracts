// Point the site at a real deployment (Sepolia rehearsal or Ethereum mainnet) after checking it.
//
//   pnpm site-config --chain 11155111 --auction 0x… --block 12345678 [--rpc https://…] [--allow-started]
//   (--config <file> targets another config file with the same shape; the tests use it)
//
// Reads the chain's own config (site/chains/<id>.json), verifies the auction and its two token
// contracts on that chain, and writes auction, motifs, oneOfOne and deployBlock into the config.
// Then rebuild: python3 site/build.py
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSite } from '../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const site = resolve(here, '../../site');
const { KILIM_ABI: A, KILIM_RPC: R } = loadSite(['vendor/js-sha3-0.8.0/sha3.min.js', 'abi.js', 'rpc.js']);
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
// The functions this check reads, by signature: independent of the site's own ABI table.
const fn = (sig) => A.fn(sig);
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
const motifs = (await call(a, fn('motifs() returns (address)'))).toLowerCase();
const oneOfOne = (await call(a, fn('oneOfOne() returns (address)'))).toLowerCase();
if ((await codeAt(motifs, 'latest')) === '0x') die('auction.motifs() has no code');
if ((await codeAt(oneOfOne, 'latest')) === '0x') die('auction.oneOfOne() has no code');
const minter = fn('minter() returns (address)');
if ((await call(motifs, minter)).toLowerCase() !== a) die('motifs.minter() is not the auction');
if ((await call(oneOfOne, minter)).toLowerCase() !== a) die('oneOfOne.minter() is not the auction');
if ((await call(oneOfOne, fn('motifs() returns (address)'))).toLowerCase() !== motifs) die('oneOfOne.motifs() is not auction.motifs()');
const unit = await call(a, fn('MOTIF_PRICE() returns (uint256)'));
if (unit !== 1_000_000_000_000_000n) die(`MOTIF_PRICE() is ${unit}, not 0.001 ETH`);
const endsAt = await call(a, fn('endsAt() returns (uint64)'));
if (endsAt !== 0n && !args.includes('--allow-started')) die('endsAt() is not 0: the auction already has bids (pass --allow-started to accept)');
const count = Number(await call(motifs, fn('MOTIF_COUNT() returns (uint256)')));
if (count !== 1024) die(`motifs.MOTIF_COUNT() is ${count}; the site draws 1,024`);
if (await call(oneOfOne, fn('minted() returns (bool)'))) die('the 1/1 is already minted');

const facts = {
  startsAt: new Date(Number(await call(a, fn('startsAt() returns (uint64)'))) * 1000).toISOString(),
  duration: `${Number(await call(a, fn('duration() returns (uint64)')))} s`,
  extensionWindow: `${Number(await call(a, fn('extensionWindow() returns (uint64)')))} s`,
  incrementBps: Number(await call(a, fn('incrementBps() returns (uint16)'))),
  reservePrice: `${Number(await call(a, fn('reservePrice() returns (uint256)'))) / 1e18} ETH`,
  registered: `${Number(await call(a, fn('registrationCount() returns (uint256)')))} of 100 wallets`,
  motifCap: String(await call(a, fn('motifCap() returns (uint256)'))),
  maxMotifsPerBid: String(await call(a, fn('maxMotifsPerBid() returns (uint256)'))),
  treasury: A.checksum(await call(a, fn('treasury() returns (address)'))),
  motifs: A.checksum(motifs),
  oneOfOne: `${A.checksum(oneOfOne)} (${await call(oneOfOne, fn('name() returns (string)'))})`,
};
console.table(facts);

cfg.auction = A.checksum(a);
cfg.motifs = A.checksum(motifs);
cfg.oneOfOne = A.checksum(oneOfOne);
cfg.deployBlock = block;
writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
console.log(`Wrote ${path}.\nNext: python3 site/build.py, then publish site/index.html and auction.html.`
  + (chainId === 1 ? '\nFor orkhan.art (the pages go live there too): pnpm site:sync-orkhanart on its local branch kilim/unified-site, then review and commit there.' : ''));
