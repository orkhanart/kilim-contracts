// Review PoC (deploy lens): script/DeployKilim.s.sol broadcast end to end against a local anvil
// through forge's real broadcast path (simulation, then eth_sendTransaction from an unlocked
// account), the way a hardware wallet run would go apart from the signing. It answers, on a live
// RPC rather than forge's in-memory chain:
//   1. runStore() sends every chunk through the CREATE2 deployer and a chunk somebody else already
//      deployed is skipped;
//   2. the published-nonce check reads the live nonce: one stray transaction from the wallet makes
//      runContracts() refuse before anything is sent;
//   3. runContracts() lands the three contracts at the predicted nonces and the broadcast file holds
//      what Etherscan verification and a manual retry need (nonce, input, constructor arguments);
//   4. a third transaction dropped from the mempool after the first two were mined: what forge
//      --resume does with it, and whether re-sending the recorded input at the recorded nonce
//      recovers the deployment;
//   5. the real gasUsed per transaction against the script's printed estimates and the 8M policy.
//
//   node test/poc/anvil-broadcast.mjs            (from contracts/; needs the packed stores)
//
// It writes deploy/poc-anvil.json while it runs (the script can only read ./deploy) and removes it
// at the end, and it leaves forge's broadcast/ output for inspection.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync, existsSync, mkdirSync, copyFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress, F, A } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CONFIG = resolve(CONTRACTS, 'deploy/poc-anvil.json');
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
// What forge etches for the deterministic deployer (test/poc/Create2DeployerCode.t.sol prints it).
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';
const NO_NONCE_CHECK = (2n ** 256n - 1n).toString();
const MAX_TX_GAS = 8_000_000;

const motifManifest = JSON.parse(readFileSync(resolve(CONTRACTS, '../onchain/build-motifs/manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(CONTRACTS, '../onchain/build-page/manifest.json'), 'utf8'));

let failures = 0;
function check(cond, what) {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`);
  if (!cond) failures++;
}
function section(title) { console.log(`\n== ${title}`); }

function forge(args, { expectFail = false } = {}) {
  const r = spawnSync(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...args], {
    cwd: CONTRACTS, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-anvil.json' },
  });
  const out = (r.stdout || '') + (r.stderr || '');
  const ok = r.status === 0;
  if (ok === expectFail) {
    console.log(out.split('\n').slice(-40).join('\n'));
  }
  return { ok, out };
}

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-broadcast.mjs',
    chainId: 31337, deployer, deployerNonce: nonce, minLeadSeconds: 86400,
    motifStore: '../onchain/build-motifs', pageStore: '../onchain/build-page',
    auction: {
      treasury: '0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac', startsAt, duration: 86400, extensionWindow: 600,
      incrementBps: 1000, reservePrice: 10000000000000000, maxMotifsPerBid: 1000000,
    },
    collection: { motifCap: 1000000, description: motifManifest.description, externalUrl: 'https://kilim.art' },
    oneOfOne: { name: pageManifest.name, description: pageManifest.description, externalUrl: pageManifest.externalUrl ?? '' },
  }, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2).replace(`"${NO_NONCE_CHECK}"`, NO_NONCE_CHECK));
}

function sstore2Initcode(data) {
  const n = (data.length - 2) / 2 + 1;
  return '0x61' + n.toString(16).padStart(4, '0') + '80600a3d393df300' + data.slice(2);
}

const BROADCAST_DIR = resolve(CONTRACTS, 'broadcast/DeployKilim.s.sol/31337');
// forge names the broadcast file after the entry point: runStore-latest.json, runContracts-latest.json.
const latest = (sig) => resolve(BROADCAST_DIR, `${sig.replace('()', '')}-latest.json`);
const sigArgs = (sig) => ['script', 'script/DeployKilim.s.sol', '--sig', sig, '--skip', 'OneOfOneGridsSource'];
const t0 = Date.now();
const anvil = await startAnvil({ chainId: 31337 });
const rpc = rpcClient(anvil.rpcUrl);
try {
  // forge fires every transaction of a phase into the pool at once (no --slow). anvil's automine mines a
  // block per arriving transaction with whatever fits (30M), and what is left over after the last arrival
  // stays pending for good: a first run of this PoC hung forge for 14 minutes with 14 of 37 chunk
  // transactions mined. Blocks every second, like a chain, avoid that; section 5 switches to manual mining.
  await rpc.call('evm_setIntervalMining', [1]);
  const accounts = await rpc.call('eth_accounts');
  const deployer = accounts[0];
  const stranger = accounts[1];
  const nonceOf = async () => Number(await rpc.call('eth_getTransactionCount', [deployer, 'latest']));
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  const startsAt = now + 3 * 86400;
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  check((await rpc.call('eth_getCode', [CREATE2_DEPLOYER, 'latest'])).length > 2, 'CREATE2 deployer etched on anvil');
  const rpcArgs = ['--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer];

  section('1. a chunk someone else deployed first is verified and skipped');
  const head = motifManifest.names.chunks[0]; // the names chunk, deployed by a stranger
  const data = '0x' + readFileSync(resolve(CONTRACTS, '../onchain/build-motifs', head.file)).toString('hex');
  const salt = '0x' + '00'.repeat(32);
  await rpc.send({ from: stranger, to: CREATE2_DEPLOYER, data: salt + sstore2Initcode(data).slice(2), gas: '0x7a1200' });
  check((await rpc.call('eth_getCode', [head.address, 'latest'])).length > 2, `names chunk already at ${head.address}`);

  section('2. runStore() --broadcast');
  writeConfig(deployer, NO_NONCE_CHECK, startsAt);
  const nonceBefore = await nonceOf();
  let r = forge([...sigArgs('runStore()'), ...rpcArgs]);
  check(r.ok, 'runStore broadcast succeeded');
  check(!/names  chunk 0 deployment gas/.test(r.out), 'no gas line for the chunk that was already there (skipped)');
  const storeTxs = (await nonceOf()) - nonceBefore;
  check(storeTxs === 37, `store sent ${storeTxs} transactions from the deployer (38 chunks, 1 already there)`);
  for (const c of [...motifManifest.grids.chunks, ...motifManifest.names.chunks]) {
    const code = await rpc.call('eth_getCode', [c.address, 'latest']);
    const want = '0x00' + readFileSync(resolve(CONTRACTS, '../onchain/build-motifs', c.file)).toString('hex');
    check(code === want, `${c.file} on chain at ${c.address} is 0x00 || data`);
  }
  const storeRun = JSON.parse(readFileSync(latest('runStore()'), 'utf8'));
  const storeGas = storeRun.receipts.map((x) => Number(x.gasUsed));
  check(storeRun.transactions.every((t) => t.transaction.to?.toLowerCase() === CREATE2_DEPLOYER.toLowerCase()), 'every store transaction is a call to the CREATE2 deployer');
  console.log(`  store receipts: ${storeGas.length}, max gasUsed ${Math.max(...storeGas).toLocaleString('en-US')}, total ${storeGas.reduce((a, b) => a + b, 0).toLocaleString('en-US')}`);
  check(Math.max(...storeGas) <= MAX_TX_GAS, 'every store transaction used at most 8,000,000 gas on the chain');
  // Idempotent: a second runStore sends nothing.
  const n1 = await nonceOf();
  r = forge([...sigArgs('runStore()'), ...rpcArgs]);
  check(r.ok && (await nonceOf()) === n1, 'a second runStore sends nothing');

  section('3. a stray transaction from the wallet: runContracts() refuses on the published nonce');
  const published = await nonceOf();
  writeConfig(deployer, published, startsAt);
  await rpc.send({ from: deployer, to: deployer, value: '0x0' }); // the wallet did something else
  check((await nonceOf()) === published + 1, 'the live nonce moved by one');
  r = forge([...sigArgs('runContracts()'), ...rpcArgs], { expectFail: true });
  check(!r.ok && /Refused\("deployer nonce"\)|deployer nonce/.test(r.out), 'refused: "deployer nonce" (nothing sent)');
  check((await nonceOf()) === published + 1, 'nothing was sent');

  section('4. runContracts() --broadcast at the published nonce');
  const n = await nonceOf();
  const predicted = { motifs: createAddress(deployer, n), oneOfOne: createAddress(deployer, n + 1), auction: createAddress(deployer, n + 2) };
  writeConfig(deployer, n, startsAt);
  const snapBeforeContracts = await rpc.call('evm_snapshot');
  r = forge([...sigArgs('runContracts()'), ...rpcArgs]);
  check(r.ok, 'runContracts broadcast succeeded');
  const printed = Object.fromEntries(['KilimMotifs', 'KilimOneOfOne', 'KilimAuction'].map((k) => [k, (r.out.match(new RegExp(`${k}\\s+(0x[0-9a-fA-F]{40})`)) || [])[1]?.toLowerCase()]));
  check(printed.KilimMotifs === predicted.motifs && printed.KilimOneOfOne === predicted.oneOfOne && printed.KilimAuction === predicted.auction, `printed addresses equal the nonce predictions (${n}, ${n + 1}, ${n + 2})`);
  const minter = (await rpc.view(predicted.motifs, F.motifs.minter))[0].toLowerCase();
  check(minter === predicted.auction, 'motifs.minter() is the auction on the chain');
  check((await rpc.view(predicted.auction, F.auction.motifs))[0].toLowerCase() === predicted.motifs, 'auction.motifs() on the chain');
  check((await rpc.view(predicted.auction, F.auction.oneOfOne))[0].toLowerCase() === predicted.oneOfOne, 'auction.oneOfOne() on the chain');
  const run = JSON.parse(readFileSync(latest('runContracts()'), 'utf8'));
  mkdirSync(resolve(here, 'out'), { recursive: true });
  copyFileSync(latest('runContracts()'), resolve(here, 'out/anvil-runContracts-latest.json'));
  const txs = run.transactions;
  check(txs.length === 3 && txs.every((t) => t.transactionType === 'CREATE'), 'broadcast file: three CREATE transactions');
  check(txs.every((t) => t.transaction.nonce !== undefined && t.transaction.input?.length > 10), 'broadcast file: each has an explicit nonce and the full creation input');
  check(txs.every((t) => Array.isArray(t.arguments) && t.arguments.length > 0), 'broadcast file: each has its constructor arguments (what Etherscan verification needs)');
  console.log('  nonces:', txs.map((t) => Number(t.transaction.nonce)).join(', '), ' names:', txs.map((t) => t.contractName).join(', '));
  const contractGas = run.receipts.map((x) => Number(x.gasUsed));
  console.log(`  contracts gasUsed: ${contractGas.map((g) => g.toLocaleString('en-US')).join(', ')}`);
  const estimates = [...r.out.matchAll(/(KilimMotifs|KilimOneOfOne|KilimAuction) deployment gas (\d+)/g)].map((m) => Number(m[2]));
  console.log(`  script estimates:  ${estimates.map((g) => g.toLocaleString('en-US')).join(', ')}`);
  check(contractGas.every((g) => g <= MAX_TX_GAS), 'every contract creation used at most 8,000,000 gas');
  check(estimates.length === 3 && estimates.every((e, i) => e >= contractGas[i]), 'the script printed estimates are at least the real gasUsed');
  const uriGas = Number((r.out.match(/1\/1 tokenURI gas (\d+)/) || [])[1]);
  console.log(`  1/1 tokenURI gas (script): ${uriGas.toLocaleString('en-US')}`);
  // The 1/1's tokenURI from the chain, as a marketplace would read it (mint first, as the auction).
  await rpc.call('anvil_setBalance', [predicted.auction, '0xde0b6b3a7640000']);
  await rpc.call('anvil_impersonateAccount', [predicted.auction]);
  await rpc.send({ from: predicted.auction, to: predicted.oneOfOne, data: A.fn('mint(address to)').encode([deployer]) });
  await rpc.call('anvil_stopImpersonatingAccount', [predicted.auction]);
  const uri = (await rpc.view(predicted.oneOfOne, F.oneOfOne.tokenURI, [1n]))[0];
  const { createHash } = await import('node:crypto');
  const sha = '0x' + createHash('sha256').update(uri, 'latin1').digest('hex');
  check(sha === pageManifest.golden.tokenURI.sha256, `tokenURI(1) read from the chain hashes to the packed golden (${uri.length.toLocaleString('en-US')} bytes)`);

  section('5. the third transaction is dropped after the first two are mined');
  await rpc.call('evm_revert', [snapBeforeContracts]);
  check((await nonceOf()) === n, 'back to the state before the contracts');
  rmSync(latest('runContracts()'), { force: true });
  await rpc.call('evm_setIntervalMining', [0]);
  await rpc.call('evm_setAutomine', [false]);
  // forge sends the three and waits for receipts; meanwhile drop the auction and mine the rest.
  const { spawn } = await import('node:child_process');
  const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...sigArgs('runContracts()'), ...rpcArgs, '--timeout', '20'], {
    cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-anvil.json' },
  });
  let childOut = '';
  child.stdout.on('data', (d) => { childOut += d; });
  child.stderr.on('data', (d) => { childOut += d; });
  const exit = new Promise((ok) => child.on('exit', (code) => ok(code)));
  let pending = [];
  for (let i = 0; i < 1200; i++) {
    const pool = await rpc.call('txpool_content');
    pending = Object.values(pool.pending[deployer] ?? pool.pending[deployer?.toLowerCase()] ?? pool.pending[A.checksum(deployer)] ?? {});
    if (pending.length >= 3) break;
    await new Promise((ok) => setTimeout(ok, 250));
  }
  check(pending.length === 3, `three transactions pending in the pool (${pending.length})`);
  const third = pending.find((t) => Number(t.nonce) === n + 2);
  if (third) {
    const dropped = await rpc.call('anvil_dropTransaction', [third.hash]);
    check(dropped === third.hash, `dropped the auction creation ${third.hash}`);
  }
  await rpc.call('anvil_mine', ['0x1']);
  const forgeExit = await exit;
  await rpc.call('evm_setIntervalMining', [1]);
  console.log(childOut.split('\n').filter((l) => /dropped|Dropped|timed out|Timed out|Error|error|resume|receipt/.test(l)).slice(-12).map((l) => '    ' + l.trim()).join('\n'));
  check(forgeExit !== 0, `forge did not report success (exit ${forgeExit})`);
  check((await nonceOf()) === n + 2, 'motifs and the 1/1 are mined; the auction is not');
  check((await rpc.call('eth_getCode', [predicted.auction, 'latest'])) === '0x', 'no code at the predicted auction address');

  section('5a. runContracts() again is refused (the published nonce is spent)');
  r = forge([...sigArgs('runContracts()'), ...rpcArgs], { expectFail: true });
  check(!r.ok && /deployer nonce/.test(r.out), 'refused: "deployer nonce"');

  section('5b. forge --resume with the dropped transaction');
  r = forge([...sigArgs('runContracts()'), ...rpcArgs, '--resume', '--timeout', '20'], { expectFail: true });
  const resumed = (await rpc.call('eth_getCode', [predicted.auction, 'latest'])) !== '0x';
  console.log(`  --resume exit ok=${r.ok}; auction now has code: ${resumed}`);
  console.log(r.out.split('\n').filter((l) => /dropped|Dropped|timed out|Error|error|resume|Nothing|nothing|broadcast/i.test(l)).slice(-8).map((l) => '    ' + l.trim()).join('\n'));

  section('5c. manual recovery: re-send the recorded input at the recorded nonce');
  if (!resumed) {
    const saved = JSON.parse(readFileSync(latest('runContracts()'), 'utf8'));
    const auctionTx = saved.transactions.find((t) => t.contractName === 'KilimAuction');
    check(Number(auctionTx.transaction.nonce) === n + 2, 'the broadcast file records nonce n + 2 for the auction');
    const receipt = await rpc.send({ from: deployer, data: auctionTx.transaction.input, nonce: '0x' + (n + 2).toString(16), gas: auctionTx.transaction.gas });
    check(receipt.contractAddress.toLowerCase() === predicted.auction, 'the auction lands at the predicted address');
  }
  check((await rpc.view(predicted.motifs, F.motifs.minter))[0].toLowerCase() === predicted.auction, 'motifs.minter() is the auction');
  check((await rpc.view(predicted.auction, F.auction.oneOfOne))[0].toLowerCase() === predicted.oneOfOne, 'auction.oneOfOne() is the 1/1: the deployment is whole');
} finally {
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
