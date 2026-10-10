// Skeptic PoC for the deploy finding "the nonce check and the 'pending:' print do not see a pending
// transaction from the wallet" (contracts/script/DeployKilim.s.sol:606). Two measurements that the
// reviewer's anvil-pending-nonce.mjs does not make:
//
//   1. Inside a forge script forked from the node, with a transaction from the account sitting unmined
//      in the pool: what vm.getNonce returns (the value runContracts() checks and prints as "pending")
//      next to eth_getTransactionCount at "latest" and at "pending" read through vm.rpc, which is the
//      finding's suggested fix.
//   2. runContracts() with --broadcast while the stray is priced ABOVE forge's own transaction, so the
//      node refuses the replacement instead of taking it: does forge still send the other two creations,
//      and what is left on the chain once the stray mines.
//
//   node test/poc/anvil-nonce-tags.mjs            (from contracts/; needs the packed stores)
//
// The store is etched with anvil_setCode at the manifest addresses, as anvil-pending-nonce.mjs does.
// deploy/poc-nonce-tags.json is written while it runs and removed at the end.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CONFIG = resolve(CONTRACTS, 'deploy/poc-nonce-tags.json');
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';

const MOTIF_DIR = resolve(CONTRACTS, '../onchain/build-motifs');
const PAGE_DIR = resolve(CONTRACTS, '../onchain/build-page');
const motifManifest = JSON.parse(readFileSync(resolve(MOTIF_DIR, 'manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(PAGE_DIR, 'manifest.json'), 'utf8'));

let failures = 0;
function check(cond, what) { console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) failures++; }
function section(title) { console.log(`\n== ${title}`); }

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-nonce-tags.mjs',
    chainId: 31337, deployer, deployerNonce: nonce, minLeadSeconds: 86400,
    motifStore: '../onchain/build-motifs', pageStore: '../onchain/build-page',
    auction: {
      treasury: '0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac', startsAt, duration: 86400, extensionWindow: 600,
      incrementBps: 1000, reservePrice: 10000000000000000, maxMotifsPerBid: 1000000,
    },
    collection: { motifCap: 1000000, description: motifManifest.description, externalUrl: 'https://kilim.art' },
    oneOfOne: { name: pageManifest.name, description: pageManifest.description, externalUrl: pageManifest.externalUrl ?? '' },
  }, null, 2));
}

function runForge(args, env = {}) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), 'script', ...args, '--skip', 'OneOfOneGridsSource'], {
      cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-nonce-tags.json', ...env },
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('exit', (code) => done({ code, out }));
  });
}
const line = (out, key) => { const m = out.match(new RegExp(`^\\s*${key} (\\d+)\\s*$`, 'm')); return m ? Number(m[1]) : NaN; };

const t0 = Date.now();
const anvil = await startAnvil({ chainId: 31337 });
const rpc = rpcClient(anvil.rpcUrl);
try {
  const [deployer] = await rpc.call('eth_accounts');
  const nonceOf = async (tag = 'latest') => Number(await rpc.call('eth_getTransactionCount', [deployer, tag]));
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  const etch = async (dir, chunks) => {
    for (const c of chunks) {
      await rpc.call('anvil_setCode', [c.address, '0x00' + readFileSync(resolve(dir, c.file)).toString('hex')]);
    }
  };
  await etch(MOTIF_DIR, [...motifManifest.grids.chunks, ...motifManifest.names.chunks]);
  for (const s of ['prefix', 'head', 'tail']) await etch(PAGE_DIR, pageManifest.sections[s].chunks);
  const n = await nonceOf();
  const predicted = { motifs: createAddress(deployer, n), oneOfOne: createAddress(deployer, n + 1), auction: createAddress(deployer, n + 2) };
  const codeAt = async (a) => (await rpc.call('eth_getCode', [a, 'latest'])) !== '0x';

  section('1. what a forge script sees of the nonce while a transaction from the account is pending');
  await rpc.call('evm_setAutomine', [false]);
  // Priced well above what forge will offer, so section 2 can refuse the replacement.
  const strayHash = await rpc.call('eth_sendTransaction', [{ from: deployer, to: deployer, value: '0x0', gasPrice: '0x174876e800' }]);
  check((await nonceOf('pending')) === n + 1 && (await nonceOf('latest')) === n, `stray ${strayHash} pending at 100 gwei: pending nonce ${n + 1}, latest ${n}`);
  let r = await runForge(['test/poc/NonceTags.s.sol', '--sig', 'run()', '--rpc-url', anvil.rpcUrl], { NONCE_ACCOUNT: deployer });
  const seen = { getNonce: line(r.out, 'getNonce'), latest: line(r.out, 'latest'), pending: line(r.out, 'pending') };
  console.log('  script printed:', JSON.stringify(seen));
  check(r.code === 0, 'the script ran');
  check(seen.getNonce === n && seen.latest === n, `vm.getNonce (${seen.getNonce}) is the latest-mined nonce (${n}): it does not count the pending transaction`);
  check(seen.pending === n + 1, `vm.rpc eth_getTransactionCount "pending" (${seen.pending}) does see it: the suggested fix would refuse here`);

  section('2. runContracts() --broadcast while that stray is priced above forge\'s transaction');
  writeConfig(deployer, n, now + 3 * 86400);
  r = await runForge(['script/DeployKilim.s.sol', '--sig', 'runContracts()', '--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', '25']);
  const pool = await rpc.call('txpool_content');
  const poolTxs = Object.values(pool.pending).flatMap((m) => Object.values(m)).map((t) => ({ nonce: Number(t.nonce), hash: t.hash, stray: t.hash === strayHash, price: t.gasPrice ?? t.maxFeePerGas }));
  console.log('  pool after forge:', poolTxs.map((t) => `nonce ${t.nonce} ${t.stray ? '(stray)' : '(forge)'} gasPrice ${t.price}`).join(' | ') || '(empty)');
  console.log(r.out.split('\n').filter((l) => /deployerNonce|underpriced|replac|nonce|Error|error|ONCHAIN EXECUTION|Simulated/i.test(l)).slice(-8).map((l) => '    ' + l.trim()).join('\n'));
  check(/\(pending: \d+\)/.test(r.out) && !r.out.includes(`pending: ${n + 1}`), 'the settings line still labels the latest-mined nonce "pending"');
  check(r.code !== 0 && /replacement transaction underpriced/.test(r.out), `forge exited ${r.code}: the node refused forge's nonce ${n} as an underpriced replacement`);
  // Measured, not assumed: forge (one signer, no --slow, as the checklist's commands run it) sends the
  // three creations as a batch, so the refusal of the first does not hold back the other two.
  const forgeLeft = poolTxs.filter((t) => !t.stray).map((t) => t.nonce).sort();
  check(poolTxs.some((t) => t.stray && t.nonce === n) && forgeLeft.join() === [n + 1, n + 2].join(), `the pool holds the stray at ${n} and forge's creations at ${n + 1} and ${n + 2}: the refusal did not stop the other two`);
  await rpc.call('anvil_mine', ['0x1']);
  await rpc.call('evm_setAutomine', [true]);
  const strayMined = !!(await rpc.call('eth_getTransactionReceipt', [strayHash]));
  const doomed = [];
  for (const t of poolTxs.filter((t) => !t.stray)) {
    const rc = await rpc.call('eth_getTransactionReceipt', [t.hash]);
    doomed.push({ nonce: t.nonce, status: rc?.status, gasUsed: rc ? Number(rc.gasUsed) : null });
  }
  console.log('  forge\'s creations once the stray mined:', JSON.stringify(doomed));
  check(strayMined && (await nonceOf()) === n + 3, `the stray mined and so did forge's two: the deployer's nonce is now ${await nonceOf()}, three past the published ${n}`);
  check(doomed.length === 2 && doomed.every((d) => d.status === '0x0'), 'both creations reverted (the 1/1 and the auction refuse token addresses without code): their gas is spent for nothing');
  check(!(await codeAt(predicted.motifs)) && !(await codeAt(predicted.oneOfOne)) && !(await codeAt(predicted.auction)), 'no code at the three predicted addresses');
  r = await runForge(['script/DeployKilim.s.sol', '--sig', 'runContracts()', '--rpc-url', anvil.rpcUrl]);
  check(r.code !== 0 && /deployer nonce/.test(r.out), 'a re-run is refused: "deployer nonce" (the already documented recovery path)');
} finally {
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
