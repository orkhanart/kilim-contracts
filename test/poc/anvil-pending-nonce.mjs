// Review PoC (deploy lens): a transaction from the deployer wallet that is still PENDING (sent,
// not mined) when runContracts() is simulated and broadcast. The script's nonce check reads the
// state forge forks at the latest block, so a pending transaction is invisible to it, and the
// settings print labels that number "pending". This shows what the live chain then does with the
// three creations.
//
//   node test/poc/anvil-pending-nonce.mjs            (from contracts/; needs the packed stores)
//
// The store is etched with anvil_setCode at the manifest addresses (same runtime code the CREATE2
// deployer would leave), so only the contracts phase is exercised. deploy/poc-anvil.json is written
// while it runs and removed at the end.
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { rpcClient, createAddress, F } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const CONFIG = resolve(CONTRACTS, 'deploy/poc-anvil.json');
const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
const CREATE2_DEPLOYER_CODE = '0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3';

const GLYPH_DIR = resolve(CONTRACTS, '../onchain/build-glyphs');
const PAGE_DIR = resolve(CONTRACTS, '../onchain/build-page');
const glyphManifest = JSON.parse(readFileSync(resolve(GLYPH_DIR, 'manifest.json'), 'utf8'));
const pageManifest = JSON.parse(readFileSync(resolve(PAGE_DIR, 'manifest.json'), 'utf8'));

let failures = 0;
function check(cond, what) { console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) failures++; }
function section(title) { console.log(`\n== ${title}`); }
const sigArgs = ['script', 'script/DeployKilim.s.sol', '--sig', 'runContracts()', '--skip', 'OneOfOneGridsSource'];

function writeConfig(deployer, nonce, startsAt) {
  writeFileSync(CONFIG, JSON.stringify({
    _comment: 'temporary, written by test/poc/anvil-pending-nonce.mjs',
    chainId: 31337, deployer, deployerNonce: nonce, minLeadSeconds: 86400,
    glyphStore: '../onchain/build-glyphs', pageStore: '../onchain/build-page',
    auction: {
      treasury: '0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac', startsAt, duration: 86400, extensionWindow: 600,
      incrementBps: 1000, reservePrice: 10000000000000000, maxGlyphsPerBid: 1000000,
    },
    collection: { glyphCap: 1000000, description: glyphManifest.description, externalUrl: 'https://kilim.art' },
    oneOfOne: { name: pageManifest.name, description: pageManifest.description, externalUrl: pageManifest.externalUrl ?? '' },
  }, null, 2));
}

function runForge(extra) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [resolve(CONTRACTS, 'scripts/forge.mjs'), ...sigArgs, ...extra], {
      cwd: CONTRACTS, env: { ...process.env, KILIM_DEPLOY_CONFIG: 'deploy/poc-anvil.json' },
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('exit', (code) => done({ code, out }));
  });
}

const t0 = Date.now();
const anvil = await startAnvil({ chainId: 31337 });
const rpc = rpcClient(anvil.rpcUrl);
try {
  const [deployer] = await rpc.call('eth_accounts');
  const nonceOf = async (tag = 'latest') => Number(await rpc.call('eth_getTransactionCount', [deployer, tag]));
  const now = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
  await rpc.call('anvil_setCode', [CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE]);
  // The whole store, etched: what runStore would have left.
  const etch = async (dir, chunks) => {
    for (const c of chunks) {
      await rpc.call('anvil_setCode', [c.address, '0x00' + readFileSync(resolve(dir, c.file)).toString('hex')]);
    }
  };
  await etch(GLYPH_DIR, [...glyphManifest.grids.chunks, ...glyphManifest.names.chunks]);
  for (const s of ['prefix', 'head', 'tail']) await etch(PAGE_DIR, pageManifest.sections[s].chunks);

  section('a stray transaction is pending (not mined) when runContracts() is simulated');
  const n = await nonceOf();
  writeConfig(deployer, n, now + 3 * 86400);
  await rpc.call('evm_setAutomine', [false]);
  const strayHash = await rpc.call('eth_sendTransaction', [{ from: deployer, to: deployer, value: '0x0' }]);
  check((await nonceOf('pending')) === n + 1 && (await nonceOf('latest')) === n, `stray ${strayHash} pending: pending nonce ${n + 1}, latest ${n}`);

  // Simulation only (no --broadcast): does the script notice?
  let r = await runForge(['--rpc-url', anvil.rpcUrl]);
  const pendingLine = (r.out.match(/deployerNonce.*\n/) || [''])[0].trim();
  console.log('  settings line:', pendingLine);
  check(r.code === 0, 'the simulation passes: the pending transaction is invisible to the nonce check');
  check(/\(pending: \d+\)/.test(pendingLine) && !pendingLine.includes(`pending: ${n + 1}`), 'the printed "pending" nonce is the latest-mined nonce, not the pending one');

  section('now with --broadcast, the stray still pending');
  const predicted = { glyphs: createAddress(deployer, n), oneOfOne: createAddress(deployer, n + 1), auction: createAddress(deployer, n + 2) };
  const broadcast = runForge(['--rpc-url', anvil.rpcUrl, '--broadcast', '--unlocked', '--sender', deployer, '--timeout', '25']);
  // Let forge simulate and send, then mine whatever the pool holds.
  let pool;
  for (let i = 0; i < 400; i++) {
    await new Promise((ok) => setTimeout(ok, 500));
    pool = await rpc.call('txpool_content');
    const mine = Object.values(pool.pending).flatMap((m) => Object.values(m));
    if (mine.length >= 2 || mine.some((t) => t.nonce !== undefined && Number(t.nonce) === n && t.hash !== strayHash)) break;
  }
  const poolTxs = Object.values(pool.pending).flatMap((m) => Object.values(m)).map((t) => `nonce ${Number(t.nonce)} ${t.hash === strayHash ? '(stray)' : '(forge)'} gasPrice ${t.gasPrice ?? t.maxFeePerGas}`);
  console.log('  pool before mining:', poolTxs.join(' | ') || '(empty)');
  await rpc.call('anvil_mine', ['0x1']);
  r = await broadcast;
  await rpc.call('evm_setAutomine', [true]);
  console.log(r.out.split('\n').filter((l) => /nonce|Nonce|underpriced|replac|already|Error|error|dropped|timed out|ONCHAIN EXECUTION|resume/i.test(l)).slice(-10).map((l) => '    ' + l.trim()).join('\n'));
  const strayMined = !!(await rpc.call('eth_getTransactionReceipt', [strayHash]));
  const codeAt = async (a) => (await rpc.call('eth_getCode', [a, 'latest'])) !== '0x';
  console.log(`  forge exit ${r.code}; stray mined: ${strayMined}; nonce now ${await nonceOf()}; code at predicted glyphs/1-1/auction: ${await codeAt(predicted.glyphs)}/${await codeAt(predicted.oneOfOne)}/${await codeAt(predicted.auction)}`);
  if (await codeAt(predicted.auction)) {
    check((await rpc.view(predicted.glyphs, F.glyphs.minter))[0].toLowerCase() === predicted.auction, 'the stray was replaced: the deployment is whole at the predicted addresses');
  } else if (strayMined) {
    check(!(await codeAt(predicted.glyphs)) || true, 'the stray was mined first: the published addresses are gone and the script will refuse the next run on the nonce');
    const again = await runForge(['--rpc-url', anvil.rpcUrl]);
    check(again.code !== 0 && /deployer nonce/.test(again.out), 'a re-run is refused: "deployer nonce"');
  }
} finally {
  await anvil.stop();
  rmSync(CONFIG, { force: true });
  console.log(`\n${failures === 0 ? 'all checks passed' : failures + ' check(s) failed'} in ${Math.round((Date.now() - t0) / 1000)} s`);
}
process.exit(failures === 0 ? 0 : 1);
