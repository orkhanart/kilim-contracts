// Deploy Kilim (native ETH) to a local anvil through plain JSON-RPC from anvil's unlocked accounts,
// and register throwaway wallets so bidding can open. Local chains only.
// The stores are the real ones: the packed motif chunks (onchain/build-motifs) and page chunks
// (onchain/build-page) go on the chain first, here by plain CREATE where script/DeployKilim.s.sol
// uses the CREATE2 deployer, then KilimMotifs, KilimOneOfOne and KilimAuction in the published
// order, so tokenURI answers are the production ones.
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSite } from '../../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const CONTRACTS = resolve(here, '../..');

// Only the ABI encoder (and the keccak it needs): nothing else of the site is loaded here.
const site = loadSite(['vendor/js-sha3-0.8.0/sha3.min.js', 'abi.js']);
export const A = site.KILIM_ABI;

export const LAUNCH = {
  duration: 24n * 3600n,
  extensionWindow: 600n,
  incrementBps: 1000,
  reservePrice: 10n ** 16n,          // 0.01 ETH: the only reserve the constructor accepts
  motifCap: 1_000_000n,
  maxMotifsPerBid: 1_000_000n,
  externalUrl: 'https://orkhan.art/kilim', // the motif collection's; the 1/1's comes from the packed page
  openDelay: 120n,                   // startsAt = latest block + 120 s
};
export const UNIT = 10n ** 15n;                  // MOTIF_PRICE: 0.001 ETH, one motif
export const REGISTRATION_TARGET = 100;
const REGISTRANT_BASE = 0x5eed0000n;             // throwaway registrants: this address, then +1, +2, ...

/**
 * The contract functions the dev scripts call, by signature, so they do not depend on the site's
 * own ABI table (site/abi.js) while it changes.
 */
const bySignature = (list) => Object.fromEntries(list.map((s) => [s.slice(0, s.indexOf('(')), A.fn(s)]));
export const F = {
  auction: bySignature([
    'register()', 'registrationCount() returns (uint256)', 'registered(address) returns (bool)',
    'bid(uint256 amount,uint256 minimumReward,uint256 expectedFirstMotifId)',
    'rewardForBid(uint256 amount) returns (uint256)',
    'minimumBid() returns (uint256)', 'highestBid() returns (uint256)', 'highestBidder() returns (address)',
    'endsAt() returns (uint64)', 'settled() returns (bool)', 'settle()', 'proceedsDue() returns (uint256)',
    'withdrawProceeds(address to)', 'withdrawRefund(address to)', 'refunds(address) returns (uint256)',
    'claimMotifs(uint256 quantity,address to)', 'claimPrize(address to)', 'prizeClaimed() returns (bool)',
    'motifCredits(address) returns (uint256)', 'motifsAllocated() returns (uint256)', 'motifsClaimed() returns (uint256)',
    'unclaimedMotifRanges(address bidder) returns ((uint128,uint128)[])',
    'motifs() returns (address)', 'oneOfOne() returns (address)', 'treasury() returns (address)',
    'MOTIF_PRICE() returns (uint256)', 'motifCap() returns (uint256)', 'maxMotifsPerBid() returns (uint256)',
    'startsAt() returns (uint64)', 'duration() returns (uint64)', 'extensionWindow() returns (uint64)',
    'incrementBps() returns (uint16)', 'reservePrice() returns (uint256)',
  ]),
  motifs: bySignature([
    'balanceOf(address owner) returns (uint256)', 'ownerOf(uint256 tokenId) returns (address)',
    'tokenURI(uint256 tokenId) returns (string)', 'motifOf(uint256 id) returns (uint16)',
    'motifName(uint16 motif) returns (string)', 'grid(uint16 motif) returns (bytes32)',
    'minter() returns (address)', 'MOTIF_COUNT() returns (uint256)', 'motifCap() returns (uint256)',
    'motifsMinted() returns (uint256)', 'motifsBurned() returns (uint256)',
  ]),
  oneOfOne: bySignature([
    'ownerOf(uint256 tokenId) returns (address)', 'tokenURI(uint256 tokenId) returns (string)',
    'minted() returns (bool)', 'minter() returns (address)', 'motifs() returns (address)',
  ]),
};

export function rpcClient(url) {
  let id = 1;
  async function call(method, params = []) {
    const res = await fetch(url, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: id++, method, params }),
    });
    const body = await res.json();
    if (body.error) {
      const e = new Error(`${method}: ${body.error.message}`);
      e.code = body.error.code; e.data = body.error.data;
      throw e;
    }
    return body.result;
  }
  async function receipt(hash) {
    for (let i = 0; i < 600; i++) {
      const r = await call('eth_getTransactionReceipt', [hash]);
      if (r) return r;
      await new Promise((ok) => setTimeout(ok, 50));
    }
    throw new Error(`No receipt for ${hash}`);
  }
  async function send(tx) {
    const hash = await call('eth_sendTransaction', [tx]);
    const r = await receipt(hash);
    if (r.status !== '0x1') {
      let reason = '';
      try { await call('eth_call', [{ ...tx, gas: undefined }, r.blockNumber]); } catch (e) { reason = JSON.stringify(e.data ?? e.message); }
      throw new Error(`Transaction reverted: ${reason}`);
    }
    return r;
  }
  async function view(to, f, args = [], block = 'latest') {
    return f.decode(await call('eth_call', [{ to, data: f.encode(args) }, block]));
  }
  return { call, send, receipt, view, url };
}

export function artifact(name) {
  // FOUNDRY_OUT, when set, is where forge wrote this build (forge reads the same variable).
  const path = resolve(CONTRACTS, process.env.FOUNDRY_OUT || 'out', `${name}.sol/${name}.json`);
  if (!existsSync(path)) throw new Error(`Missing ${path}: run "node scripts/forge.mjs build" in contracts/ first.`);
  const json = JSON.parse(readFileSync(path, 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

async function create(rpc, from, bytecode, argTypes = [], args = []) {
  const data = bytecode + (argTypes.length ? A.encode(argTypes, args).slice(2) : '');
  const r = await rpc.send({ from, data, gas: '0x1c9c380' });
  if (!r.contractAddress) throw new Error('No contract address in receipt');
  return r.contractAddress.toLowerCase();
}

// KilimAuction.Config and KilimOneOfOne.Page, as the constructors take them.
const AUCTION_CONFIG = '(address,address,address,uint64,uint64,uint64,uint16,uint256,uint256)';
const PAGE = '(address[],bytes32,address[],bytes32,address[],bytes32)';

export const MOTIF_STORE = resolve(CONTRACTS, '../onchain/build-motifs');
export const PAGE_STORE = resolve(CONTRACTS, '../onchain/build-page');

/** One chunk file's bytes, checked against its manifest entry so a stale build fails here. */
function chunkBytes(dir, entry) {
  const hex = '0x' + readFileSync(resolve(dir, entry.file)).toString('hex');
  if ((hex.length - 2) / 2 !== entry.size || A.keccak(hex) !== entry.keccak.toLowerCase()) {
    throw new Error(`${entry.file} does not match ${dir}/manifest.json: repack the store (pnpm pack:motifs / pack:page)`);
  }
  return hex;
}

/** The packed motif store as KilimMotifs takes it: grid and names chunk bytes and the committed hashes. */
export function packedMotifStore(dir = MOTIF_STORE) {
  const m = JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
  if (m.motifCount !== 1024) throw new Error(`${dir}/manifest.json holds ${m.motifCount} motifs, not 1,024`);
  return {
    gridsHash: m.hashes.gridsHash, namesHash: m.hashes.namesHash,
    grids: m.grids.chunks.map((c) => chunkBytes(dir, c)), names: m.names.chunks.map((c) => chunkBytes(dir, c)),
    description: m.description, golden: m.golden,
  };
}

/** The packed page as KilimOneOfOne takes it: prefix, head and tail chunk bytes, hashes and texts. */
export function packedPageStore(dir = PAGE_STORE) {
  const m = JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
  const section = (name) => m.sections[name].chunks.map((c) => chunkBytes(dir, c));
  return {
    prefixHash: m.hashes.prefixHash, headHash: m.hashes.headHash, tailHash: m.hashes.tailHash,
    prefix: section('prefix'), head: section('head'), tail: section('tail'),
    name: m.name, description: m.description, externalUrl: m.externalUrl ?? '', golden: m.golden,
  };
}

/** SSTORE2 initcode: the runtime is a STOP byte followed by `data` (the contracts read from offset 1). */
function sstore2Initcode(data) {
  const n = (data.length - 2) / 2 + 1;
  if (n > 0xffff) throw new Error('chunk too large');
  return '0x61' + n.toString(16).padStart(4, '0') + '80600a3d393df300' + data.slice(2);
}

/** The address a plain CREATE from `deployer` at `nonce` lands on: keccak256(rlp([deployer, nonce]))[12:]. */
export function createAddress(deployer, nonce) {
  const rlp = (hex) => (hex.length === 2 && parseInt(hex, 16) < 0x80) ? hex : (0x80 + hex.length / 2).toString(16).padStart(2, '0') + hex;
  const n = BigInt(nonce);
  const nonceHex = n === 0n ? '' : n.toString(16).padStart(Math.ceil(n.toString(16).length / 2) * 2, '0');
  const payload = rlp(deployer.slice(2).toLowerCase()) + rlp(nonceHex);
  return '0x' + A.keccak('0x' + (0xc0 + payload.length / 2).toString(16) + payload).slice(-40);
}

/**
 * Deploy the stores and a fresh auction. Bidding stays locked until 100 wallets register, which the
 * contract allows from startsAt on: see registerWallets and openBidding below.
 * Overrides: any LAUNCH key, `treasury`, `startsAt`, `description` (the motif collection's; defaults
 * to the packed one), `motifStore` / `pageStore` (loaded stores, for tests with their own data).
 */
export async function deployLocal(rpcUrl, overrides = {}) {
  const rpc = rpcClient(rpcUrl);
  const chainId = Number(await rpc.call('eth_chainId'));
  const accounts = (await rpc.call('eth_accounts')).map((a) => a.toLowerCase());
  const deployer = accounts[0];
  const treasury = overrides.treasury ?? accounts[9];
  const cfg = { ...LAUNCH, ...overrides };
  const g = overrides.motifStore ?? packedMotifStore();
  const p = overrides.pageStore ?? packedPageStore();

  // The stores first: every chunk is its own contract.
  const put = async (list) => { const out = []; for (const data of list) out.push(await create(rpc, deployer, sstore2Initcode(data))); return out; };
  const chunks = { grids: await put(g.grids), names: await put(g.names), prefix: await put(p.prefix), head: await put(p.head), tail: await put(p.tail) };

  // Then the three contracts in the published order. Both token contracts name the auction, two
  // creations ahead, as their minter; its constructor checks that they did.
  const nonce = Number(await rpc.call('eth_getTransactionCount', [deployer, 'latest']));
  const predicted = createAddress(deployer, nonce + 2);
  const motifs = await create(rpc, deployer, artifact('KilimMotifs').bytecode,
    ['address', 'address', 'uint256', 'address[]', 'bytes32', 'address', 'bytes32', 'string', 'string'],
    [predicted, treasury, cfg.motifCap, chunks.grids, g.gridsHash, chunks.names[0], g.namesHash, cfg.description ?? g.description, cfg.externalUrl]);
  const oneOfOne = await create(rpc, deployer, artifact('KilimOneOfOne').bytecode,
    ['address', 'address', 'address', PAGE, 'string', 'string', 'string'],
    [predicted, treasury, motifs, [chunks.prefix, p.prefixHash, chunks.head, p.headHash, chunks.tail, p.tailHash], p.name, p.description, p.externalUrl]);

  const latest = await rpc.call('eth_getBlockByNumber', ['latest', false]);
  const startsAt = cfg.startsAt ?? BigInt(latest.timestamp) + cfg.openDelay;
  const auctionArgs = [[
    treasury, motifs, oneOfOne,
    startsAt, cfg.duration, cfg.extensionWindow, cfg.incrementBps, cfg.reservePrice, cfg.maxMotifsPerBid,
  ]];
  const receipt = await rpc.send({
    from: deployer, gas: '0x1c9c380',
    data: artifact('KilimAuction').bytecode + A.encode([AUCTION_CONFIG], auctionArgs).slice(2),
  });
  const auction = receipt.contractAddress.toLowerCase();
  if (auction !== predicted) throw new Error(`the auction landed at ${auction}, not at the predicted ${predicted}`);
  const deployBlock = Number(receipt.blockNumber);
  return { chainId, auction, motifs, oneOfOne, deployBlock, startsAt: Number(startsAt), accounts, treasury, deployer,
           chunks, motifStore: g, pageStore: p };
}

/** The i-th throwaway registrant (never one of anvil's ten accounts). */
export function registrant(i) {
  return '0x' + (REGISTRANT_BASE + BigInt(i)).toString(16).padStart(40, '0');
}

/**
 * Register throwaway wallets until `target` wallets are registered (the contract's own count, so
 * wallets that registered through the page are counted). Each is funded with 1 test ETH and
 * impersonated; registration needs 0.01 ETH held and takes no deposit. Warps to startsAt first if
 * the chain is not there yet: registration is closed before it.
 */
export async function registerWallets(rpc, d, target = REGISTRATION_TARGET) {
  const latest = await rpc.call('eth_getBlockByNumber', ['latest', false]);
  if (Number(latest.timestamp) < d.startsAt) {
    await rpc.call('evm_setNextBlockTimestamp', [d.startsAt]);
    await rpc.call('evm_mine');
  }
  const count = async () => Number((await rpc.view(d.auction, F.auction.registrationCount))[0]);
  const data = F.auction.register.encode([]);
  for (let i = await count(); i < target; i++) {
    const who = registrant(i);
    await rpc.call('anvil_setBalance', [who, '0xde0b6b3a7640000']);
    await rpc.call('anvil_impersonateAccount', [who]);
    await rpc.send({ from: who, to: d.auction, data });
    await rpc.call('anvil_stopImpersonatingAccount', [who]);
  }
  return count();
}

/** Warp to startsAt and fill the registration: bidding is unlocked, no bid is placed, endsAt stays 0. */
export async function openBidding(rpc, d) {
  return registerWallets(rpc, d, REGISTRATION_TARGET);
}

/** The per-chain site config the pages read (site/chains/<id>.json shape). */
export function siteConfig(d, { rpcUrl = 'http://127.0.0.1:8545', name = 'Local anvil' } = {}) {
  return {
    chainId: d.chainId,
    name,
    rpcUrls: [rpcUrl],
    explorer: null,
    dev: true,
    auction: A.checksum(d.auction),
    motifs: A.checksum(d.motifs),
    oneOfOne: A.checksum(d.oneOfOne),
    deployBlock: d.deployBlock,
    notice: '',
    writesDisabled: false,
    void: [],
    registrationRelayer: '',
  };
}
