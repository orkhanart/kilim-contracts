// Skeptic PoC (deploy lens, "third creation never sent"): the first two creations of runContracts()
// are sent and mined, the third is refused at the send (what a hardware wallet rejecting the third
// signature, or an RPC refusing the request, looks like to forge). A small JSON-RPC proxy in front of
// anvil answers the third eth_sendTransaction with an error and forwards everything else. Chain id
// 31339: its own broadcast/ directory and config file.
//
// It answers:
//   1. how forge exits and what the broadcast file records (hashes for the two sent, none for the third);
//   2. whether `forge script --resume` then sends the third creation at nonce n + 2 by itself;
//   3. otherwise, the manual re-send of the recorded input.
//
//   node test/poc/anvil-unsent-third.mjs            (from contracts/; needs the packed stores)
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress, F } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CHAIN_ID = 31339;
const CONFIG = resolve(CONTRACTS, 'deploy/poc-unsent-third.json');
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
const INTERESTING = /dropped|known to the node|receipt|timed out|resume|Error|error|ONCHAIN|Sending|Sequence|rejected|Nothing|nothing|hash/i;

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-unsent-third.mjs',
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

function runForge(extra, capMs) {
  return new Promise((done) => {
    const started = Date.now();
    const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...sigArgs, ...extra], {
      cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-unsent-third.json' },
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

/** A JSON-RPC proxy that refuses every eth_sendTransaction from the `refuseFrom`th on (forge retries a
 *  refused send on its own: a single refusal is a hiccup, not a signer that keeps saying no). */
function startProxy(upstream, refuseFrom) {
  let sends = 0;
  let refusing = true;
  const handle = async (req) => {
    if (req.method === 'eth_sendTransaction' && ++sends >= refuseFrom && refusing) {
      return { jsonrpc: '2.0', id: req.id, error: { code: -32000, message: 'poc: the signer rejected this request' } };
    }
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
    sends: () => sends,
    allow: () => { refusing = false; },
    stop: () => new Promise((done) => server.close(() => done())),
  })));
}

const t0 = Date.now();
const anvil = await startAnvil({ chainId: CHAIN_ID });
const rpc = rpcClient(anvil.rpcUrl);
const proxy = await startProxy(anvil.rpcUrl, 3);
try {
  const [deployer] = await rpc.call('eth_accounts');
  const nonceOf = async () => Number(await rpc.call('eth_getTransactionCount', [deployer, 'latest']));
  const codeAt = async (a) => (await rpc.call('eth_getCode', [a, 'latest'])) !== '0x';
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

  section('1. runContracts() --broadcast through a proxy that refuses the third eth_sendTransaction');
  const r1 = await runForge(['--rpc-url', proxy.url, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', '20'], 300_000);
  note(`forge exit ${r1.killed ? 'KILLED by this PoC' : r1.code} after ${r1.seconds} s; eth_sendTransaction seen by the proxy: ${proxy.sends()} (the 3rd and every later one refused)`);
  console.log(lines(r1.out));
  check(r1.code !== 0 && !r1.killed, 'forge exited by itself with an error');
  check((await nonceOf()) === n + 2, `glyphs and the 1/1 are mined (nonce ${await nonceOf()}); n + 2 is free`);
  check(!(await codeAt(predicted.auction)), 'no code at the predicted auction address');
  note(`broadcast file: ${broadcastSummary()}`);
  const f = existsSync(LATEST) ? JSON.parse(readFileSync(LATEST, 'utf8')) : null;
  check(f && f.transactions.length === 3, 'the broadcast file holds the three creations');
  if (f) {
    const [g, o, a] = f.transactions;
    check(g.hash && o.hash && !a.hash, 'hashes recorded for the two sent creations, none for the auction');
    check(Number(a.transaction.nonce) === n + 2 && a.transaction.input?.length > 10, 'the auction creation is recorded with nonce n + 2 and its input');
  }

  section('2. runContracts() again, no --resume: refused on the nonce');
  const r2 = await runForge(['--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer], 180_000);
  check(r2.code !== 0 && /deployer nonce/.test(r2.out), 'refused: "deployer nonce"');

  section('3. forge script --resume, the signer accepting again: is the third creation sent now?');
  // forge resumes against the RPC URL recorded in the broadcast file (the proxy), whatever --rpc-url says.
  proxy.allow();
  const r3 = await runForge(['--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', '20', '--resume'], 180_000);
  note(`--resume exit ${r3.killed ? 'KILLED by this PoC' : r3.code} after ${r3.seconds} s`);
  console.log(lines(r3.out));
  let recovered = await codeAt(predicted.auction);
  note(`auction has code after --resume: ${recovered}`);
  note(`broadcast file: ${broadcastSummary()}`);
  const resumeWorked = recovered;

  if (!recovered) {
    section('4. manual recovery: eth_sendTransaction of the recorded input at nonce n + 2');
    const saved = JSON.parse(readFileSync(LATEST, 'utf8'));
    const tx = saved.transactions.find((t) => t.contractName === 'KilimAuction');
    const receipt = await rpc.send({ from: deployer, data: tx.transaction.input, nonce: '0x' + (n + 2).toString(16), gas: tx.transaction.gas });
    check(receipt.contractAddress.toLowerCase() === predicted.auction.toLowerCase(), 'the auction lands at the predicted address');
    recovered = await codeAt(predicted.auction);
  }

  section('read-back of the whole deployment');
  check(recovered, 'the auction has code at the predicted address');
  check((await rpc.view(predicted.glyphs, F.glyphs.minter))[0].toLowerCase() === predicted.auction.toLowerCase(), 'glyphs.minter() is the auction');
  check((await rpc.view(predicted.auction, F.auction.oneOfOne))[0].toLowerCase() === predicted.oneOfOne.toLowerCase(), 'auction.oneOfOne() is the 1/1: the deployment is whole');

  section('summary');
  note(`forge --resume sent the never-sent third creation by itself: ${resumeWorked}`);
} finally {
  await proxy.stop();
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
