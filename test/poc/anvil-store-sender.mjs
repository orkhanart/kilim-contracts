// Review PoC (deploy lens, skeptic pass): who sends the store phase of script/DeployKilim.s.sol.
// checklists/2-deploy.md says runStore() goes "--ledger --sender <any funded key>" and that the
// chunks can go up "from any key"; deployStore() calls vm.startBroadcast(c.deployer), the config's
// deployer, which on mainnet must be orkhanart.eth. Against a live anvil through forge's real
// broadcast path this answers:
//   1. with --sender B and a config whose deployer is A, from whom does runStore() send? (A: the
//      --sender is not used for the store, and A's nonce moves by one per chunk);
//   2. with a signer for B only (--private-key, no --unlocked) and the config's deployer A, does
//      forge send anything, and what does it say?;
//   3. run() (the Sepolia rehearsal): with deployerNonce read before the store, the contracts phase
//      refuses "deployer nonce", because the store from the same key moved it by 38; with the nonce
//      after the store it goes through.
//
//   node test/poc/anvil-store-sender.mjs            (from contracts/; needs the packed stores)
//
// It writes deploy/poc-store-sender.json while it runs (the script can only read ./deploy) and
// removes it at the end.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CONFIG = resolve(CONTRACTS, 'deploy/poc-store-sender.json');
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
// What forge etches for the deterministic deployer (test/poc/Create2DeployerCode.t.sol prints it).
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';
const NO_NONCE_CHECK = (2n ** 256n - 1n).toString();
// anvil's second account under the default test mnemonic (public key material; local chains only).
const B_PRIVATE_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

const motifManifest = JSON.parse(readFileSync(resolve(CONTRACTS, '../onchain/build-motifs/manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(CONTRACTS, '../onchain/build-page/manifest.json'), 'utf8'));
const chunkCount = motifManifest.grids.chunks.length + motifManifest.names.chunks.length
  + pageManifest.sections.prefix.chunks.length + pageManifest.sections.head.chunks.length
  + pageManifest.sections.tail.chunks.length;

let failures = 0;
function check(cond, what) {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`);
  if (!cond) failures++;
}
function section(title) { console.log(`\n== ${title}`); }

function forge(args) {
  const r = spawnSync(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...args], {
    cwd: CONTRACTS, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-store-sender.json' },
  });
  return { ok: r.status === 0, out: (r.stdout || '') + (r.stderr || '') };
}

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-store-sender.mjs',
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

const sigArgs = (sig) => ['script', 'script/DeployKilim.s.sol', '--sig', sig, '--skip', 'OneOfOneGridsSource'];
const tail = (out, n = 6) => out.trim().split('\n').slice(-n).map((l) => '    ' + l.trim()).join('\n');
const t0 = Date.now();
const anvil = await startAnvil({ chainId: 31337 });
const rpc = rpcClient(anvil.rpcUrl);
try {
  // Blocks every second (see anvil-broadcast.mjs: automine leaves part of a 38-transaction burst pending).
  await rpc.call('evm_setIntervalMining', [1]);
  const accounts = await rpc.call('eth_accounts');
  const A = accounts[0]; // the config's deployer (orkhanart.eth on mainnet)
  const B = accounts[1]; // "any funded key"
  const nonceOf = async (who) => Number(await rpc.call('eth_getTransactionCount', [who, 'latest']));
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  const startsAt = now + 3 * 86400;
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  check((await rpc.call('eth_getCode', [CREATE2_DEPLOYER, 'latest'])).length > 2, 'CREATE2 deployer etched on anvil');
  console.log(`  A (config deployer) ${A}\n  B (--sender)        ${B}\n  chunks in the store ${chunkCount}`);
  const fresh = await rpc.call('evm_snapshot');

  section('1. runStore() --broadcast --unlocked --sender B, config deployer A');
  writeConfig(A, NO_NONCE_CHECK, startsAt);
  const [a0, b0] = [await nonceOf(A), await nonceOf(B)];
  let r = forge([...sigArgs('runStore()'), '--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', B]);
  check(r.ok, 'forge reported success');
  if (!r.ok) console.log(tail(r.out, 15));
  const [a1, b1] = [await nonceOf(A), await nonceOf(B)];
  check(a1 - a0 === chunkCount, `A (the config's deployer) sent ${a1 - a0} transactions: one per chunk`);
  check(b1 - b0 === 0, `B (the --sender) sent ${b1 - b0}: the --sender is not used for the store`);
  const firstTail = pageManifest.sections.tail.chunks[0];
  check((await rpc.call('eth_getCode', [firstTail.address, 'latest'])).length > 2, 'the store is on the chain');
  const storeRun = JSON.parse(readFileSync(resolve(CONTRACTS, 'broadcast/DeployKilim.s.sol/31337/runStore-latest.json'), 'utf8'));
  const froms = new Set(storeRun.transactions.map((t) => t.transaction.from.toLowerCase()));
  check(froms.size === 1 && froms.has(A.toLowerCase()), `broadcast file: every store transaction has from = A (${[...froms].join(', ')})`);

  section('2. a signer for B only (--private-key), config deployer A: forge cannot sign for A');
  await rpc.call('evm_revert', [fresh]);
  check((await rpc.call('eth_getCode', [firstTail.address, 'latest'])) === '0x', 'back to the state before the store');
  r = forge([...sigArgs('runStore()'), '--rpc-url', anvil.rpcUrl, '--broadcast', '--private-key', B_PRIVATE_KEY, '--sender', B]);
  check(!r.ok, `forge did not report success (ok=${r.ok})`);
  const noWallet = /No associated wallet for addresses/i.test(r.out);
  check(noWallet, 'forge says "No associated wallet for addresses" (the config deployer has no signer)');
  console.log(tail(r.out.split('\n').filter((l) => /wallet|Error|error/i.test(l)).join('\n'), 4));
  check((await nonceOf(A)) === a0 && (await nonceOf(B)) === b0, 'nothing was sent from A or B');
  check((await rpc.call('eth_getCode', [firstTail.address, 'latest'])) === '0x', 'no chunk on the chain');

  section('3. run() with deployerNonce read before the store (the Sepolia one-shot)');
  await rpc.call('evm_revert', [fresh]);
  const published = await nonceOf(A); // what a publisher reads before anything is sent
  writeConfig(A, published, startsAt);
  r = forge([...sigArgs('run()'), '--rpc-url', anvil.rpcUrl, '--unlocked', '--sender', A]); // simulation only
  check(!r.ok && /deployer nonce/.test(r.out), 'refused: "deployer nonce" (the store moved it first)');
  const pendingLine = (r.out.match(/deployerNonce\s+\d+ \(pending: \d+\)/) || [])[0];
  console.log(`    ${pendingLine ?? '(no deployerNonce line printed)'}`);
  check(new RegExp(`\\(pending: ${published + chunkCount}\\)`).test(r.out), `the script saw the nonce after the store: ${published} + ${chunkCount}`);
  writeConfig(A, published + chunkCount, startsAt);
  r = forge([...sigArgs('run()'), '--rpc-url', anvil.rpcUrl, '--unlocked', '--sender', A]);
  check(r.ok && /KilimAuction\s+0x/.test(r.out), `run() goes through with deployerNonce = nonce before the store + ${chunkCount}`);

  section('4. two phases from the same key: n published before runStore is spent by the store');
  await rpc.call('evm_revert', [fresh]);
  const n = await nonceOf(A);
  writeConfig(A, n, startsAt); // n published, then the store is sent from A
  r = forge([...sigArgs('runStore()'), '--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', A]);
  check(r.ok && (await nonceOf(A)) === n + chunkCount, `the store spent nonces ${n}..${n + chunkCount - 1} of A`);
  r = forge([...sigArgs('runContracts()'), '--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', A]);
  check(!r.ok && /deployer nonce/.test(r.out), 'runContracts() at the published n is refused: nothing sent, but n and the predictions must be republished');
  check((await nonceOf(A)) === n + chunkCount, 'nothing was sent by the refused run');
} finally {
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
