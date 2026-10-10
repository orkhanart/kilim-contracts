// Deploy the Kilim auction (native ETH) to a local anvil through plain JSON-RPC from anvil's
// unlocked accounts, and register throwaway wallets so bidding can open. Local chains only.
// The renderer is the real one: the packed store's chunks (onchain/build) and KilimRenderer are
// deployed first, as script/DeployKilim.s.sol does for a live chain (here by plain CREATE, not the
// CREATE2 deployer), so tokenURI answers are the production ones.
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSite } from '../../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const CONTRACTS = resolve(here, '../..');

const site = loadSite();
export const A = site.KILIM_ABI;

export const LAUNCH = {
  duration: 24n * 3600n,
  extensionWindow: 600n,
  incrementBps: 1000,
  reservePrice: 10n ** 16n,          // 0.01 ETH: the only reserve the constructor accepts
  symbolCap: 1_000_000n,
  maxSymbolsPerBid: 1_000_000n,
  // motifCount is the packed store's (onchain/build/manifest.json), never a literal: Kilim's
  // constructor rejects any other value. Pass { renderer: 'mock', motifCount } to try another.
  maxCells: 256,
  openDelay: 120n,                   // startsAt = latest block + 120 s
};
export const UNIT = 10n ** 15n;                  // SYMBOL_PRICE: 0.001 ETH, one symbol
export const REGISTRATION_TARGET = 100;
const REGISTRANT_BASE = 0x5eed0000n;             // throwaway registrants: this address, then +1, +2, ...

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

const AUCTION_CONFIG = '(address,address,uint64,uint64,uint64,uint16,uint256,uint256,uint256,uint16,uint16,bytes32,bytes32,address)';

export const STORE_DIR = resolve(CONTRACTS, '../onchain/build');

/**
 * The packed store as the renderer takes it: chunk bytes and the committed hashes from manifest.json.
 * Each chunk file is checked against the manifest's size and keccak, so a stale build fails here.
 */
export function packedStore(dir = STORE_DIR) {
  const manifest = JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
  const chunks = manifest.chunks.map((c) => {
    const hex = '0x' + readFileSync(resolve(dir, c.file)).toString('hex');
    if ((hex.length - 2) / 2 !== c.size || A.keccak(hex) !== c.keccak.toLowerCase()) {
      throw new Error(`${c.file} does not match ${dir}/manifest.json: rerun "pnpm pack"`);
    }
    return hex;
  });
  const { geometryHash, indexHash, pageHash } = manifest.hashes;
  return { motifCount: manifest.motifCount, geometryHash, indexHash, pageHash, chunks };
}

/** SSTORE2 initcode: the runtime is a STOP byte followed by `data` (KilimRenderer reads from offset 1). */
function sstore2Initcode(data) {
  const n = (data.length - 2) / 2 + 1;
  if (n > 0xffff) throw new Error('chunk too large');
  return '0x61' + n.toString(16).padStart(4, '0') + '80600a3d393df300' + data.slice(2);
}

/**
 * Deploy the store's chunks and a KilimRenderer over them. With `mock`, deploy test/mocks/MockRenderer
 * instead (any motif count; tokenURI answers are ABI-encoded inputs, not metadata).
 * Returns the renderer, its code hash (the auction's rendererHash) and what it reports.
 */
export async function deployRenderer(rpc, from, { mock = null, store = null } = {}) {
  let renderer, chunks = [], motifCount, geometryHash;
  if (mock) {
    ({ motifCount, geometryHash } = mock);
    renderer = await create(rpc, from, artifact('MockRenderer').bytecode, ['uint256', 'bytes32'], [BigInt(motifCount), geometryHash]);
  } else {
    const s = store ?? packedStore();
    for (const data of s.chunks) chunks.push(await create(rpc, from, sstore2Initcode(data)));
    renderer = await create(rpc, from, artifact('KilimRenderer').bytecode, ['address[]', 'bytes32', 'bytes32', 'bytes32'],
                            [chunks, s.geometryHash, s.indexHash, s.pageHash]);
    ({ motifCount, geometryHash } = s);
  }
  const rendererHash = A.keccak(await rpc.call('eth_getCode', [renderer, 'latest']));
  return { renderer, rendererHash, chunks, motifCount: Number(motifCount), geometryHash: geometryHash.toLowerCase() };
}

/**
 * Deploy a fresh auction. Bidding stays locked until 100 wallets register, which the contract
 * allows from startsAt on: see registerWallets and openBidding below.
 */
export async function deployLocal(rpcUrl, overrides = {}) {
  const rpc = rpcClient(rpcUrl);
  const chainId = Number(await rpc.call('eth_chainId'));
  const accounts = (await rpc.call('eth_accounts')).map((a) => a.toLowerCase());
  const deployer = accounts[0];
  const treasury = overrides.treasury ?? accounts[9];
  const cfg = { ...LAUNCH, ...overrides };

  // The renderer before the auction: Kilim's constructor checks its code hash, motif count and geometry.
  let r;
  if (cfg.renderer === 'mock') {
    const mockCount = cfg.motifCount ?? packedStore().motifCount;
    r = await deployRenderer(rpc, deployer, { mock: { motifCount: mockCount, geometryHash: A.keccakText('kilim dev geometry') } });
  } else if (cfg.renderer === undefined || cfg.renderer === 'store') {
    r = await deployRenderer(rpc, deployer);
    if (cfg.motifCount !== undefined && Number(cfg.motifCount) !== r.motifCount) {
      throw new Error(`motifCount ${cfg.motifCount} is not the packed store's ${r.motifCount}; pass renderer: 'mock' to use another count`);
    }
  } else {
    throw new Error(`renderer must be 'store' or 'mock', not ${cfg.renderer}`);
  }

  const latest = await rpc.call('eth_getBlockByNumber', ['latest', false]);
  const startsAt = cfg.startsAt ?? BigInt(latest.timestamp) + cfg.openDelay;
  const auctionArgs = [[
    treasury, overrides.collectionOwner ?? treasury,
    startsAt, cfg.duration, cfg.extensionWindow, cfg.incrementBps, cfg.reservePrice,
    cfg.symbolCap, cfg.maxSymbolsPerBid, r.motifCount, cfg.maxCells,
    r.geometryHash, r.rendererHash, r.renderer,
  ]];
  const receipt = await rpc.send({
    from: deployer, gas: '0x1c9c380',
    data: artifact('KilimAuction').bytecode + A.encode([AUCTION_CONFIG], auctionArgs).slice(2),
  });
  const auction = receipt.contractAddress.toLowerCase();
  const deployBlock = Number(receipt.blockNumber);
  const [collection] = await rpc.view(auction, A.F.auction.collection);
  return { chainId, auction, collection: collection.toLowerCase(),
           deployBlock, startsAt: Number(startsAt), accounts, treasury, deployer,
           renderer: r.renderer, rendererHash: r.rendererHash, chunks: r.chunks, motifCount: r.motifCount };
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
  const count = async () => Number((await rpc.view(d.auction, A.F.auction.registrationCount))[0]);
  const data = A.F.auction.register.encode([]);
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
    collection: A.checksum(d.collection),
    deployBlock: d.deployBlock,
    notice: '',
    writesDisabled: false,
    void: [],
    registrationRelayer: '',
  };
}
