// Skeptic PoC (deploy lens, "dropped third creation"): what forge 1.7.1 itself does when the third
// creation of runContracts() leaves the mempool after the first two are mined, measured on its own
// chain id (31338: its own broadcast/ directory and config file, so it never shares state with
// test/poc/anvil-broadcast.mjs, which uses 31337).
//
// Two settings, because a live chain keeps producing blocks while forge waits and anvil does not:
//   default          blocks every second while forge waits (what mainnet does);
//   POC_NO_BLOCKS=1  no block after the one that mines the first two creations (what
//                    test/poc/anvil-broadcast.mjs section 5 measures).
//
// It answers, in order:
//   1. after anvil_dropTransaction, does the node still know the hash (eth_getTransactionByHash)?
//   2. how long does forge wait past --timeout, how does it exit, what does it print, and which
//      RPC methods does it call while it waits (a tallying proxy sits between forge and anvil)?
//   3. what does the broadcast file record for the dropped creation (hash, receipt, pending)?
//   4. does `forge script --resume` re-send it (forge's own message says it is "retried when using
//      --resume")? If not, does --resume re-send it once the recorded hash is removed?
//   5. the manual recovery from the review finding: eth_sendTransaction of the recorded input at
//      the recorded nonce, then the read-back.
//
//   node test/poc/anvil-dropped-third.mjs            (from contracts/; needs the packed stores)
//
// The store is etched with anvil_setCode at the manifest addresses (what runStore would leave), so
// only the contracts phase is exercised. deploy/poc-dropped-third.json is written while it runs and
// removed at the end; forge's broadcast/DeployKilim.s.sol/31338/ is left for inspection.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress, F } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CHAIN_ID = 31338;
const NO_BLOCKS = process.env.POC_NO_BLOCKS === '1';
const CONFIG = resolve(CONTRACTS, 'deploy/poc-dropped-third.json');
const LATEST = resolve(CONTRACTS, `broadcast/DeployKilim.s.sol/${CHAIN_ID}/runContracts-latest.json`);
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';

const GLYPH_DIR = resolve(CONTRACTS, '../onchain/build-glyphs');
const PAGE_DIR = resolve(CONTRACTS, '../onchain/build-page');
const glyphManifest = JSON.parse(readFileSync(resolve(GLYPH_DIR, 'manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(PAGE_DIR, 'manifest.json'), 'utf8'));

let failures = 0;
function check(cond, what) { console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) failures++; }
function note(what) { console.log(`  --   ${what}`); }
function section(title) { console.log(`\n== ${title}`); }
const sigArgs = ['script', 'script/DeployKilim.s.sol', '--sig', 'runContracts()', '--skip', 'OneOfOneGridsSource'];
const INTERESTING = /dropped|known to the node|receipt|timed out|Timed out|resume|Error|error|ONCHAIN|Sending|Sequence|Nothing|nothing|hash/i;

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-dropped-third.mjs',
    chainId: CHAIN_ID, deployer, deployerNonce: nonce, minLeadSeconds: 86400,
    glyphStore: '../onchain/build-glyphs', pageStore: '../onchain/build-page',
    auction: {
      treasury: '0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac', startsAt, duration: 86400, extensionWindow: 600,
      incrementBps: 1000, reservePrice: 10000000000000000, maxGlyphsPerBid: 1000000,
    },
    collection: { glyphCap: 1000000, description: glyphManifest.description, externalUrl: 'https://kilim.art' },
    oneOfOne: { name: pageManifest.name, description: pageManifest.description, externalUrl: pageManifest.externalUrl ?? '' },
  }, null, 2));
}

/** Spawn forge; resolve on exit or kill it after `capMs` (the finding says it can sit for minutes). */
function runForge(extra, capMs) {
  return new Promise((done) => {
    const started = Date.now();
    const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...sigArgs, ...extra], {
      cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-dropped-third.json' },
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    let killed = false;
    const timer = setTimeout(() => { killed = true; child.kill('SIGKILL'); }, capMs);
    child.on('exit', (code) => { clearTimeout(timer); done({ code, out, killed, seconds: Math.round((Date.now() - started) / 1000) }); });
  });
}
const lines = (out, n = 12) => out.split('\n').filter((l) => INTERESTING.test(l)).slice(-n).map((l) => '    | ' + l.trim()).join('\n');
const broadcastSummary = () => {
  if (!existsSync(LATEST)) return 'no broadcast file';
  const f = JSON.parse(readFileSync(LATEST, 'utf8'));
  return `txs ${f.transactions.length} [${f.transactions.map((t) => `${t.contractName}:nonce ${Number(t.transaction.nonce)}:hash ${t.hash ? t.hash.slice(0, 10) : 'null'}`).join(', ')}] receipts ${f.receipts.length} pending ${JSON.stringify(f.pending)}`;
};

/** A forwarding JSON-RPC proxy that tallies the methods forge calls (reset with `reset()`). */
function startProxy(upstream) {
  let tally = {};
  let last = {};
  const handle = async (req) => {
    tally[req.method] = (tally[req.method] ?? 0) + 1;
    last[req.method] = Date.now();
    const res = await fetch(upstream, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(req) });
    return res.json();
  };
  const server = createServer((request, response) => {
    let body = '';
    request.on('data', (d) => { body += d; });
    request.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const answer = Array.isArray(parsed) ? await Promise.all(parsed.map(handle)) : await handle(parsed);
        response.setHeader('content-type', 'application/json');
        response.end(JSON.stringify(answer));
      } catch (e) {
        response.statusCode = 500;
        response.end(String(e));
      }
    });
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok({
    url: `http://127.0.0.1:${server.address().port}`,
    reset: () => { tally = {}; last = {}; },
    report: () => Object.entries(tally).map(([m, c]) => `${m} x${c} (last ${Math.round((Date.now() - last[m]) / 1000)} s ago)`).join(', ') || '(no calls)',
    stop: () => new Promise((done) => server.close(() => done())),
  })));
}

const t0 = Date.now();
const anvil = await startAnvil({ chainId: CHAIN_ID });
const rpc = rpcClient(anvil.rpcUrl);
const proxy = await startProxy(anvil.rpcUrl);
try {
  note(`setting: ${NO_BLOCKS ? 'no blocks while forge waits (POC_NO_BLOCKS=1)' : 'a block every second while forge waits (live chain)'}`);
  const [deployer] = await rpc.call('eth_accounts');
  const nonceOf = async (tag = 'latest') => Number(await rpc.call('eth_getTransactionCount', [deployer, tag]));
  const codeAt = async (a) => (await rpc.call('eth_getCode', [a, 'latest'])) !== '0x';
  const poolOf = async () => {
    const pool = await rpc.call('txpool_content');
    return Object.values(pool.pending ?? {}).flatMap((m) => Object.values(m)).filter((t) => t.from?.toLowerCase() === deployer.toLowerCase());
  };
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  const etch = async (dir, chunks) => {
    for (const c of chunks) await rpc.call('anvil_setCode', [c.address, '0x00' + readFileSync(resolve(dir, c.file)).toString('hex')]);
  };
  await etch(GLYPH_DIR, [...glyphManifest.grids.chunks, ...glyphManifest.names.chunks]);
  for (const s of ['prefix', 'head', 'tail']) await etch(PAGE_DIR, pageManifest.sections[s].chunks);
  const n = await nonceOf();
  const predicted = { glyphs: createAddress(deployer, n), oneOfOne: createAddress(deployer, n + 1), auction: createAddress(deployer, n + 2) };
  writeConfig(deployer, n, now + 3 * 86400);
  rmSync(LATEST, { force: true });
  const rpcArgs = ['--rpc-url', proxy.url, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', '20'];

  section('1. runContracts() --broadcast --timeout 20; the auction creation is dropped, the other two mined');
  await rpc.call('evm_setAutomine', [false]);
  const first = runForge(rpcArgs, 420_000);
  let pending = [];
  for (let i = 0; i < 1200 && pending.length < 3; i++) {
    await new Promise((ok) => setTimeout(ok, 250));
    pending = await poolOf();
  }
  check(pending.length === 3, `three creations pending from the deployer (${pending.length})`);
  const third = pending.find((t) => Number(t.nonce) === n + 2);
  check(!!third, `the auction creation is the one at nonce ${n + 2}`);
  const dropped = await rpc.call('anvil_dropTransaction', [third.hash]);
  check(dropped === third.hash, `anvil_dropTransaction ${third.hash}`);
  const known = await rpc.call('eth_getTransactionByHash', [third.hash]);
  check(known === null, `after the drop the node answers eth_getTransactionByHash = ${known === null ? 'null (the hash is unknown, as after a real mempool eviction)' : 'the transaction (still known)'}`);
  await rpc.call('anvil_mine', ['0x1']);
  check((await nonceOf()) === n + 2, `glyphs and the 1/1 mined: nonce ${await nonceOf()} (n + 2 is free)`);
  check(!(await codeAt(predicted.auction)), 'no code at the predicted auction address');
  proxy.reset();
  const tDrop = Date.now();
  if (!NO_BLOCKS) await rpc.call('evm_setIntervalMining', [1]);
  const r1 = await first;
  if (NO_BLOCKS) await rpc.call('evm_setIntervalMining', [1]); // from here on anything re-sent is mined within a second
  note(`forge exit ${r1.killed ? 'KILLED by this PoC' : r1.code}, ${Math.round((Date.now() - tDrop) / 1000)} s after the drop (${r1.seconds} s in all) with --timeout 20`);
  note(`RPC calls from forge after the drop: ${proxy.report()}`);
  console.log(lines(r1.out));
  check(r1.code !== 0, 'forge did not report success');
  check(!r1.killed, 'forge exited by itself (it did not have to be killed)');
  note(`broadcast file: ${broadcastSummary()}`);
  check(!(await codeAt(predicted.auction)), 'still no code at the predicted auction address');

  section('2. runContracts() again, no --resume: refused on the nonce (nothing sent)');
  const r2 = await runForge(rpcArgs, 180_000);
  check(r2.code !== 0 && /deployer nonce/.test(r2.out), 'refused: "deployer nonce"');
  check((await nonceOf()) === n + 2, 'nothing was sent');

  section('3. forge script --resume: does forge re-send the dropped creation by itself?');
  proxy.reset();
  const r3 = await runForge([...rpcArgs, '--resume'], 180_000);
  note(`--resume exit ${r3.killed ? 'KILLED by this PoC' : r3.code} after ${r3.seconds} s`);
  note(`RPC calls from forge during --resume: ${proxy.report()}`);
  console.log(lines(r3.out));
  let recovered = await codeAt(predicted.auction);
  note(`auction has code after --resume: ${recovered}`);
  note(`broadcast file: ${broadcastSummary()}`);
  const resumeWorked = recovered;

  let resumeWithoutHashWorked = null;
  if (!recovered && existsSync(LATEST)) {
    section('4. --resume once the recorded hash is removed from the broadcast file');
    const f = JSON.parse(readFileSync(LATEST, 'utf8'));
    const tx = f.transactions.find((t) => t.contractName === 'KilimAuction');
    tx.hash = null;
    f.pending = (f.pending ?? []).filter((h) => h !== third.hash);
    writeFileSync(LATEST, JSON.stringify(f, null, 2));
    const r4 = await runForge([...rpcArgs, '--resume'], 180_000);
    note(`--resume exit ${r4.killed ? 'KILLED by this PoC' : r4.code} after ${r4.seconds} s`);
    console.log(lines(r4.out));
    recovered = await codeAt(predicted.auction);
    resumeWithoutHashWorked = recovered;
    note(`auction has code after --resume without the hash: ${recovered}`);
    note(`broadcast file: ${broadcastSummary()}`);
  }

  if (!recovered) {
    section('5. manual recovery: eth_sendTransaction of the recorded input at nonce n + 2');
    if (!existsSync(LATEST)) {
      check(false, 'no broadcast file to recover from: forge never wrote one');
    } else {
      const f = JSON.parse(readFileSync(LATEST, 'utf8'));
      const tx = f.transactions.find((t) => t.contractName === 'KilimAuction');
      check(Number(tx.transaction.nonce) === n + 2, 'the broadcast file records nonce n + 2 for the auction');
      const receipt = await rpc.send({ from: deployer, data: tx.transaction.input, nonce: '0x' + (n + 2).toString(16), gas: tx.transaction.gas });
      check(receipt.contractAddress.toLowerCase() === predicted.auction.toLowerCase(), 'the auction lands at the predicted address');
      recovered = await codeAt(predicted.auction);
    }
  }

  section('read-back of the whole deployment');
  check(recovered, 'the auction has code at the predicted address');
  check((await rpc.view(predicted.glyphs, F.glyphs.minter))[0].toLowerCase() === predicted.auction.toLowerCase(), 'glyphs.minter() is the auction');
  check((await rpc.view(predicted.oneOfOne, F.oneOfOne.minter))[0].toLowerCase() === predicted.auction.toLowerCase(), '1/1.minter() is the auction');
  check((await rpc.view(predicted.auction, F.auction.oneOfOne))[0].toLowerCase() === predicted.oneOfOne.toLowerCase(), 'auction.oneOfOne() is the 1/1: the deployment is whole');

  section('summary');
  note(`setting: ${NO_BLOCKS ? 'no blocks while forge waited' : 'a block every second while forge waited'}`);
  note(`forge --resume re-sent the dropped creation by itself: ${resumeWorked}`);
  note(`forge --resume re-sent it once its hash was removed from the file: ${resumeWithoutHashWorked === null ? 'not needed' : resumeWithoutHashWorked}`);
  note(`manual re-send of the recorded input was needed: ${!resumeWorked && !resumeWithoutHashWorked}`);
} finally {
  await proxy.stop();
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
