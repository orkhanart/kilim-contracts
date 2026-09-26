// Deploy the Kilim auction (and, locally, a 6-decimal MockUSD plus the DevUniswap stand-ins)
// to a local anvil through plain JSON-RPC from anvil's unlocked accounts. Local chains only.
// The renderer is the real one: the packed store's chunks (onchain/build) and KilimRenderer are
// deployed first, as script/DeployKilim.s.sol does for a live chain (here by plain CREATE, not the
// CREATE2 deployer), so tokenURI answers are the production ones.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSite } from '../../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const CONTRACTS = resolve(here, '../..');
const require = createRequire(import.meta.url);

const site = loadSite();
export const A = site.KILIM_ABI;

export const LAUNCH = {
  duration: 24n * 3600n,
  extensionWindow: 600n,
  incrementBps: 1000,
  reservePrice: 1_000_000n,          // $1 in 6-decimal USDC
  symbolCap: 1_000_000n,
  maxSymbolsPerBid: 1_000_000n,
  // motifCount is the packed store's (onchain/build/manifest.json), never a literal: Kilim's
  // constructor rejects any other value. Pass { renderer: 'mock', motifCount } to try another.
  maxCells: 256,
  openDelay: 120n,                   // startsAt = latest block + 120 s
  usdPerEth: 3000n,
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
  const path = resolve(CONTRACTS, `out/${name}.sol/${name}.json`);
  if (!existsSync(path)) throw new Error(`Missing ${path}: run "node scripts/forge.mjs build" in contracts/ first.`);
  const json = JSON.parse(readFileSync(path, 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

// DevUniswap.sol lives outside src/ and test/, so forge never builds it: compile it here with
// the pinned solc and cache the result by source hash under cache/ (gitignored).
export function devUniswap() {
  const source = readFileSync(resolve(here, 'DevUniswap.sol'), 'utf8');
  const hash = createHash('sha256').update(source).digest('hex');
  const cachePath = resolve(CONTRACTS, 'cache/dev-uniswap.json');
  if (existsSync(cachePath)) {
    const cached = JSON.parse(readFileSync(cachePath, 'utf8'));
    if (cached.hash === hash) return cached.contracts;
  }
  const solc = require('solc');
  const input = {
    language: 'Solidity',
    sources: { 'DevUniswap.sol': { content: source } },
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun',
                outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } },
  };
  const output = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (output.errors || []).filter((e) => e.severity === 'error');
  if (errors.length) throw new Error(errors.map((e) => e.formattedMessage).join('\n'));
  const contracts = {};
  for (const name of ['DevSwapRouter02', 'DevQuoterV2']) {
    const c = output.contracts['DevUniswap.sol'][name];
    contracts[name] = { abi: c.abi, bytecode: '0x' + c.evm.bytecode.object };
  }
  mkdirSync(dirname(cachePath), { recursive: true });
  writeFileSync(cachePath, JSON.stringify({ hash, contracts }));
  return contracts;
}

async function create(rpc, from, bytecode, argTypes = [], args = []) {
  const data = bytecode + (argTypes.length ? A.encode(argTypes, args).slice(2) : '');
  const r = await rpc.send({ from, data, gas: '0x1c9c380' });
  if (!r.contractAddress) throw new Error('No contract address in receipt');
  return r.contractAddress.toLowerCase();
}

const AUCTION_CONFIG = '(address,address,address,uint64,uint64,uint64,uint16,uint256,uint256,uint256,uint16,uint16,bytes32,bytes32,address)';

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
 * Deploy a fresh auction. With `fork`, use that chain's real USDC and Uniswap contracts and buy
 * each test account its USDC through the real SwapRouter02; otherwise deploy MockUSD and DevUniswap.
 */
export async function deployLocal(rpcUrl, overrides = {}) {
  const rpc = rpcClient(rpcUrl);
  const chainId = Number(await rpc.call('eth_chainId'));
  const accounts = (await rpc.call('eth_accounts')).map((a) => a.toLowerCase());
  const deployer = accounts[0];
  const treasury = overrides.treasury ?? accounts[9];
  const cfg = { ...LAUNCH, ...overrides };
  const fund = overrides.fund ?? 100_000n * 1_000_000n;

  let usdc, weth, swapRouter02, quoterV2, feeTiers;
  if (cfg.fork) {
    ({ usdc, weth, swapRouter02, quoterV2, feeTiers } = cfg.fork);
    usdc = usdc.toLowerCase();
    // On mainnet the public test-mnemonic accounts carry EIP-7702 delegations (sweepers): any
    // ETH sent to them, such as a swap's refundETH, is forwarded away. Make them plain EOAs here.
    for (const a of accounts) {
      if ((await rpc.call('eth_getCode', [a, 'latest'])) !== '0x') await rpc.call('anvil_setCode', [a, '0x']);
    }
  } else if (cfg.reuse) {
    ({ usdc, weth, swapRouter02, quoterV2, feeTiers } = cfg.reuse);
  } else {
    usdc = await create(rpc, deployer, artifact('MockUSD').bytecode, ['uint8'], [6]);
    const dev = devUniswap();
    swapRouter02 = await create(rpc, deployer, dev.DevSwapRouter02.bytecode, ['address', 'uint256'], [usdc, cfg.usdPerEth]);
    quoterV2 = await create(rpc, deployer, dev.DevQuoterV2.bytecode, ['address'], [swapRouter02]);
    [weth] = await rpc.view(swapRouter02, A.F.uniswap.WETH9);
    feeTiers = [3000];
  }

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
    usdc, treasury, overrides.collectionOwner ?? treasury,
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

  const bidders = accounts.slice(1, 9);
  if (!cfg.reuse && fund > 0n) {
    if (cfg.fork) {
      // Buy exact USDC through the real router: this also exercises the swap path.
      const deadline = BigInt(latest.timestamp) + 3600n;
      for (const who of bidders) {
        const swap = A.F.uniswap.exactOutputSingle.encode([[weth, usdc, cfg.fork.fundFee ?? 500, who, fund, 10n ** 21n, 0n]]);
        const data = A.F.uniswap.multicall.encode([deadline, [swap, A.F.uniswap.refundETH.encode([])]]);
        // Explicit gas: anvil's exact estimate can fall just short for forked Uniswap swaps.
        await rpc.send({ from: who, to: swapRouter02, data, value: '0x' + (10n ** 21n).toString(16), gas: '0x7a120' });
      }
    } else {
      for (const who of bidders) await rpc.send({ from: deployer, to: usdc, data: A.F.erc20.mint.encode([who, fund]) });
    }
  }
  return { chainId, usdc, weth, swapRouter02, quoterV2, feeTiers, auction, collection: collection.toLowerCase(),
           deployBlock, startsAt: Number(startsAt), accounts, treasury, deployer,
           renderer: r.renderer, rendererHash: r.rendererHash, chunks: r.chunks, motifCount: r.motifCount };
}

/** The per-chain site config the pages read (site/chains/<id>.json shape). */
export function siteConfig(d, { rpcUrl = 'http://127.0.0.1:8545', name = 'Local anvil', fork = null } = {}) {
  return {
    chainId: d.chainId,
    name,
    rpcUrls: [rpcUrl],
    explorer: null,
    dev: true,
    usdc: A.checksum(d.usdc),
    weth: A.checksum(d.weth),
    swapRouter02: A.checksum(d.swapRouter02),
    quoterV2: A.checksum(d.quoterV2),
    feeTiers: d.feeTiers,
    auction: A.checksum(d.auction),
    collection: A.checksum(d.collection),
    deployBlock: d.deployBlock,
    notice: '',
    writesDisabled: false,
    void: [],
    ethPayment: true,
    ...(fork ? { fork } : {}),
  };
}
