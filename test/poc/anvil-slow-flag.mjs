// Skeptic PoC (deploy lens, "--slow and --timeout in 2-deploy.md"): what forge 1.7.1's --slow flag
// changes for the Kilim deploy commands, measured on forge's real broadcast path against a local
// anvil, on its own chain id (31339: its own broadcast/ directory and config file, so it never
// shares state with the other anvil PoCs).
//
// The finding under test says: without --slow forge sends a whole phase in one burst and then
// waits; a transaction that stops being mineable keeps forge waiting far past --timeout (the title
// says "indefinitely"); in the contracts phase the 1/1 and auction creations are already in flight
// when the glyph creation fails, so all three nonces are spent. It suggests --slow as the fix.
// Each section starts a fresh anvil with the store etched at the manifest addresses (what runStore
// leaves) and the CREATE2 deployer in place, so only the contracts phase is sent, except E2.
//
//   A. burst (no --slow), --timeout 10, nothing is ever mined: how long does forge wait, and does
//      it exit by itself? (bounded, or "indefinitely")
//   B. --slow, --timeout 10: is exactly one creation in the pool until it is mined? Then the third
//      is dropped like the other PoC did: does --slow shorten the wait?
//   C. --slow, the first creation is cancelled (dropped and replaced by a self-transfer at nonce n,
//      what a wallet's "cancel" does): are the 1/1 and the auction left unsent, nonces n+1, n+2 free?
//   D. burst, the same cancel: are the 1/1 and the auction mined anyway, and what does it cost?
//   E. nothing goes wrong, blocks every second: wall time of runContracts with and without --slow,
//      and E2: runStore --slow from a fresh anvil (38 chunks), to see what --slow costs the store.
//
//   node test/poc/anvil-slow-flag.mjs            (from contracts/; needs the packed stores)
//
// deploy/poc-slow-flag.json is written while it runs and removed at the end; forge's
// broadcast/DeployKilim.s.sol/31339/ is left for inspection.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress, F } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CHAIN_ID = 31339;
const CONFIG = resolve(CONTRACTS, 'deploy/poc-slow-flag.json');
const BROADCAST_DIR = resolve(CONTRACTS, `broadcast/DeployKilim.s.sol/${CHAIN_ID}`);
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';
const NO_NONCE_CHECK = (2n ** 256n - 1n).toString();
const TIMEOUT = 10; // seconds, forge --timeout

const GLYPH_DIR = resolve(CONTRACTS, '../onchain/build-glyphs');
const PAGE_DIR = resolve(CONTRACTS, '../onchain/build-page');
const glyphManifest = JSON.parse(readFileSync(resolve(GLYPH_DIR, 'manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(PAGE_DIR, 'manifest.json'), 'utf8'));

let failures = 0;
function check(cond, what) { console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) failures++; }
function note(what) { console.log(`  --   ${what}`); }
function section(title) { console.log(`\n== ${title}`); }
const INTERESTING = /dropped|receipt|timed out|Timed out|resume|Error|error|ONCHAIN|Sending|Sequence|failed|Failed|hash/i;
const lines = (out, n = 10) => out.split('\n').filter((l) => INTERESTING.test(l)).slice(-n).map((l) => '    | ' + l.trim()).join('\n');
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-slow-flag.mjs',
    chainId: CHAIN_ID, deployer, deployerNonce: nonce, minLeadSeconds: 86400,
    glyphStore: '../onchain/build-glyphs', pageStore: '../onchain/build-page',
    auction: {
      treasury: '0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac', startsAt, duration: 86400, extensionWindow: 600,
      incrementBps: 1000, reservePrice: 10000000000000000, maxGlyphsPerBid: 1000000,
    },
    collection: { glyphCap: 1000000, description: glyphManifest.description, externalUrl: 'https://kilim.art' },
    oneOfOne: { name: pageManifest.name, description: pageManifest.description, externalUrl: pageManifest.externalUrl ?? '' },
  }, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2).replace(`"${NO_NONCE_CHECK}"`, NO_NONCE_CHECK));
}

/** Spawn forge script with `sig`; resolve on exit, or kill it after `capMs` and say so. */
function runForge(sig, extra, capMs) {
  return new Promise((done) => {
    const started = Date.now();
    const args = ['script', 'script/DeployKilim.s.sol', '--sig', sig, '--skip', 'OneOfOneGridsSource', ...extra];
    const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...args], {
      cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-slow-flag.json' },
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    let killed = false;
    const timer = setTimeout(() => { killed = true; child.kill('SIGKILL'); }, capMs);
    child.on('exit', (code) => { clearTimeout(timer); done({ code, out, killed, seconds: Math.round((Date.now() - started) / 1000) }); });
  });
}

/** A fresh anvil with the CREATE2 deployer and (unless `store` is false) every chunk etched. */
async function freshChain({ store = true } = {}) {
  const anvil = await startAnvil({ chainId: CHAIN_ID });
  const rpc = rpcClient(anvil.rpcUrl);
  const [deployer, other] = await rpc.call('eth_accounts');
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  if (store) {
    const etch = async (dir, chunks) => {
      for (const c of chunks) await rpc.call('anvil_setCode', [c.address, '0x00' + readFileSync(resolve(dir, c.file)).toString('hex')]);
    };
    await etch(GLYPH_DIR, [...glyphManifest.grids.chunks, ...glyphManifest.names.chunks]);
    for (const s of ['prefix', 'head', 'tail']) await etch(PAGE_DIR, pageManifest.sections[s].chunks);
  }
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  const n = Number(await rpc.call('eth_getTransactionCount', [deployer, 'latest']));
  const predicted = { glyphs: createAddress(deployer, n), oneOfOne: createAddress(deployer, n + 1), auction: createAddress(deployer, n + 2) };
  const ctx = {
    anvil, rpc, deployer, other, n, predicted,
    nonceOf: async (who = deployer, tag = 'latest') => Number(await rpc.call('eth_getTransactionCount', [who, tag])),
    codeAt: async (a) => (await rpc.call('eth_getCode', [a, 'latest'])) !== '0x',
    poolOf: async (who = deployer) => {
      const pool = await rpc.call('txpool_content');
      const all = (m) => Object.values(m ?? {}).flatMap((x) => Object.values(x));
      return [...all(pool.pending), ...all(pool.queued)].filter((t) => t.from?.toLowerCase() === who.toLowerCase());
    },
    /** Poll until the deployer has `count` transactions in the pool, or `ms` pass. */
    waitPool: async (count, ms = 300_000) => {
      let p = [];
      for (let i = 0; i < ms / 250 && p.length < count; i++) { await sleep(250); p = await ctx.poolOf(); }
      return p;
    },
    rpcArgs: ['--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', String(TIMEOUT)],
    stop: () => anvil.stop(),
  };
  writeConfig(deployer, n, now + 3 * 86400);
  rmSync(BROADCAST_DIR, { recursive: true, force: true });
  return ctx;
}

const results = {};
const t0 = Date.now();
try {
  // ---------------------------------------------------------------------------------------------
  section(`A. burst (no --slow), --timeout ${TIMEOUT}, nothing is ever mined: is the wait bounded?`);
  {
    const c = await freshChain();
    try {
      await c.rpc.call('evm_setAutomine', [false]);
      const run = runForge('runContracts()', c.rpcArgs, 600_000);
      const pending = await c.waitPool(3);
      const blocks = Number(await c.rpc.call('eth_blockNumber'));
      check(pending.length === 3, `three creations in the pool before any block was mined (${pending.length} pending, block ${blocks})`);
      note(`nonces in the pool: ${pending.map((t) => Number(t.nonce)).sort().join(', ')} (one burst, as the finding says)`);
      const r = await run;
      results.burstWait = r;
      note(`forge exit ${r.killed ? 'KILLED by this PoC at the cap' : r.code} after ${r.seconds} s with --timeout ${TIMEOUT} (${(r.seconds / TIMEOUT).toFixed(1)} x the timeout)`);
      console.log(lines(r.out));
      check(!r.killed, 'forge exited by itself: the wait is bounded, not indefinite');
      check(r.code !== 0, 'forge did not report success');
      check((await c.nonceOf()) === c.n, 'nothing was mined (anvil automine off)');
    } finally { await c.stop(); }
  }

  // ---------------------------------------------------------------------------------------------
  section(`B. --slow, --timeout ${TIMEOUT}: one creation at a time; then the third is dropped`);
  {
    const c = await freshChain();
    try {
      await c.rpc.call('evm_setAutomine', [false]);
      const run = runForge('runContracts()', [...c.rpcArgs, '--slow'], 600_000);
      let pending = await c.waitPool(1);
      check(pending.length === 1 && Number(pending[0].nonce) === c.n, `exactly one creation in the pool (nonce ${c.n})`);
      await sleep(8_000);
      pending = await c.poolOf();
      check(pending.length === 1, `still exactly one after 8 s: --slow sends the next only after a receipt (${pending.length} in the pool)`);
      await c.rpc.call('anvil_mine', ['0x1']);
      pending = await c.waitPool(1);
      check(pending.length === 1 && Number(pending[0].nonce) === c.n + 1, `after the block, the 1/1 creation arrives (nonce ${c.n + 1})`);
      await c.rpc.call('anvil_mine', ['0x1']);
      pending = await c.waitPool(1);
      check(pending.length === 1 && Number(pending[0].nonce) === c.n + 2, `then the auction creation (nonce ${c.n + 2})`);
      const tDrop = Date.now();
      await c.rpc.call('anvil_dropTransaction', [pending[0].hash]);
      await c.rpc.call('anvil_mine', ['0x1']); // an empty block, like the chain moving on without it
      const r = await run;
      results.slowDroppedWait = { ...r, afterDrop: Math.round((Date.now() - tDrop) / 1000) };
      note(`forge exit ${r.killed ? 'KILLED by this PoC at the cap' : r.code}, ${results.slowDroppedWait.afterDrop} s after the drop with --timeout ${TIMEOUT} (${(results.slowDroppedWait.afterDrop / TIMEOUT).toFixed(1)} x the timeout)`);
      console.log(lines(r.out));
      check(!r.killed, 'forge exited by itself');
      check(r.code !== 0, 'forge did not report success');
      check((await c.nonceOf()) === c.n + 2 && !(await c.codeAt(c.predicted.auction)), 'glyphs and the 1/1 are mined, the auction is not: the same state the burst leaves');
    } finally { await c.stop(); }
  }

  // ---------------------------------------------------------------------------------------------
  section('C. --slow, the first creation is cancelled (replaced by a self-transfer at nonce n)');
  {
    const c = await freshChain();
    try {
      await c.rpc.call('evm_setAutomine', [false]);
      const run = runForge('runContracts()', [...c.rpcArgs, '--slow'], 600_000);
      const pending = await c.waitPool(1);
      check(pending.length === 1 && Number(pending[0].nonce) === c.n, `the glyph creation is in the pool alone (nonce ${c.n})`);
      await c.rpc.call('anvil_dropTransaction', [pending[0].hash]);
      await c.rpc.call('eth_sendTransaction', [{ from: c.deployer, to: c.deployer, value: '0x0', nonce: '0x' + c.n.toString(16), gas: '0x5208' }]);
      await c.rpc.call('anvil_mine', ['0x1']);
      const r = await run;
      results.slowCancel = r;
      note(`forge exit ${r.killed ? 'KILLED' : r.code} after ${r.seconds} s`);
      console.log(lines(r.out));
      check(r.code !== 0 && !r.killed, 'forge stopped with an error');
      check((await c.nonceOf()) === c.n + 1, `only nonce ${c.n} is spent (nonce now ${await c.nonceOf()})`);
      check((await c.poolOf()).length === 0, 'the 1/1 and the auction creations were never sent (pool empty)');
      check(!(await c.codeAt(c.predicted.oneOfOne)) && !(await c.codeAt(c.predicted.auction)), 'no 1/1, no auction on the chain: n + 1 and n + 2 are free for a republished layout');
    } finally { await c.stop(); }
  }

  // ---------------------------------------------------------------------------------------------
  section('D. burst (no --slow), the same cancel of the first creation');
  {
    const c = await freshChain();
    try {
      await c.rpc.call('evm_setAutomine', [false]);
      const run = runForge('runContracts()', c.rpcArgs, 600_000);
      const pending = await c.waitPool(3);
      check(pending.length === 3, 'three creations in the pool');
      const first = pending.find((t) => Number(t.nonce) === c.n);
      await c.rpc.call('anvil_dropTransaction', [first.hash]);
      await c.rpc.call('eth_sendTransaction', [{ from: c.deployer, to: c.deployer, value: '0x0', nonce: '0x' + c.n.toString(16), gas: '0x5208' }]);
      await c.rpc.call('anvil_mine', ['0x1']);
      const r = await run;
      results.burstCancel = r;
      note(`forge exit ${r.killed ? 'KILLED' : r.code} after ${r.seconds} s`);
      console.log(lines(r.out));
      check(r.code !== 0 && !r.killed, 'forge stopped with an error');
      check((await c.nonceOf()) === c.n + 3, `all three nonces are spent (nonce now ${await c.nonceOf()})`);
      const oneOfOneThere = await c.codeAt(c.predicted.oneOfOne);
      check(oneOfOneThere, 'the 1/1 was mined anyway, with a minter that will never exist (void contract on the chain)');
      check(!(await c.codeAt(c.predicted.auction)), 'the auction creation reverted (its constructor wants code at the glyphs address)');
      const block = await c.rpc.call('eth_getBlockByNumber', ['latest', true]);
      let gas = 0;
      for (const t of block.transactions) {
        const rc = await c.rpc.call('eth_getTransactionReceipt', [t.hash]);
        const used = Number(rc.gasUsed);
        gas += used;
        note(`nonce ${Number(t.nonce)}: status ${Number(rc.status)}, gasUsed ${used.toLocaleString('en-US')}${rc.contractAddress ? ` (created ${rc.contractAddress})` : ''}`);
      }
      results.burstCancelGas = gas;
      note(`gas paid for nothing after the cancel: ${gas.toLocaleString('en-US')} (the finding says about 12M; the reverted auction pays only up to its first check)`);
      if (oneOfOneThere) {
        const minter = (await c.rpc.view(c.predicted.oneOfOne, F.oneOfOne.minter))[0].toLowerCase();
        check(minter === c.predicted.auction.toLowerCase() && !(await c.codeAt(minter)), `the void 1/1's minter is ${minter}, which has no code`);
      }
    } finally { await c.stop(); }
  }

  // ---------------------------------------------------------------------------------------------
  section('E. nothing goes wrong, blocks every second: what --slow costs in wall time');
  {
    const c = await freshChain();
    try {
      await c.rpc.call('evm_setIntervalMining', [1]);
      const burst = await runForge('runContracts()', c.rpcArgs, 600_000);
      check(burst.code === 0, `runContracts without --slow: exit ${burst.code} in ${burst.seconds} s`);
      check(await c.codeAt(c.predicted.auction), 'the auction is at the predicted address');
      results.burstOk = burst;
    } finally { await c.stop(); }
    const c2 = await freshChain();
    try {
      await c2.rpc.call('evm_setIntervalMining', [1]);
      const slow = await runForge('runContracts()', [...c2.rpcArgs, '--slow'], 600_000);
      check(slow.code === 0, `runContracts with --slow: exit ${slow.code} in ${slow.seconds} s`);
      check(await c2.codeAt(c2.predicted.auction), 'the auction is at the predicted address');
      const minter = (await c2.rpc.view(c2.predicted.glyphs, F.glyphs.minter))[0].toLowerCase();
      check(minter === c2.predicted.auction.toLowerCase(), 'glyphs.minter() is the auction (the predicted nonces held under --slow)');
      results.slowOk = slow;
    } finally { await c2.stop(); }
  }

  section('E2. runStore --slow from a fresh anvil (38 chunks), blocks every second');
  {
    const c = await freshChain({ store: false });
    try {
      await c.rpc.call('evm_setIntervalMining', [1]);
      // The store is sent from the other account (any funded key), the nonce check is off for it.
      const now = Number((await c.rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
      writeConfig(c.deployer, NO_NONCE_CHECK, now + 3 * 86400);
      const storeArgs = ['--rpc-url', c.anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', c.other, '--timeout', String(TIMEOUT), '--slow'];
      const slowStore = await runForge('runStore()', storeArgs, 900_000);
      const sent = await c.nonceOf(c.other);
      check(slowStore.code === 0, `runStore --slow: exit ${slowStore.code} in ${slowStore.seconds} s, ${sent} transactions`);
      const chunks = [...glyphManifest.grids.chunks, ...glyphManifest.names.chunks, ...['prefix', 'head', 'tail'].flatMap((s) => pageManifest.sections[s].chunks)];
      let all = true;
      for (const ch of chunks) all = all && (await c.codeAt(ch.address));
      check(all, `every one of the ${chunks.length} chunks has code at its manifest address`);
      const latest = resolve(BROADCAST_DIR, 'runStore-latest.json');
      if (existsSync(latest)) {
        const f = JSON.parse(readFileSync(latest, 'utf8'));
        const blocksUsed = new Set(f.receipts.map((r) => Number(r.blockNumber)));
        note(`store receipts ${f.receipts.length} over ${blocksUsed.size} blocks (one per block under --slow with 1 s blocks)`);
        results.slowStore = { seconds: slowStore.seconds, receipts: f.receipts.length, blocks: blocksUsed.size };
      }
    } finally { await c.stop(); }
  }

  section('summary');
  note(`A  burst, never mined, --timeout ${TIMEOUT}: forge exited by itself after ${results.burstWait.seconds} s (killed: ${results.burstWait.killed})`);
  note(`B  --slow, third dropped: forge exited ${results.slowDroppedWait.afterDrop} s after the drop (killed: ${results.slowDroppedWait.killed})`);
  note(`C  --slow, first cancelled: 1/1 and auction unsent, nonces n+1, n+2 free`);
  note(`D  burst, first cancelled: 1/1 mined void, auction reverted, ${results.burstCancelGas.toLocaleString('en-US')} gas paid`);
  note(`E  all good, 1 s blocks: runContracts ${results.burstOk.seconds} s without --slow, ${results.slowOk.seconds} s with; runStore --slow ${results.slowStore?.seconds} s for ${results.slowStore?.receipts} chunks`);
} finally {
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
