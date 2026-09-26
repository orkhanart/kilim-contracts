// Count-agnostic rerun: packs two synthetic geometries (the first 700 motifs; today's set plus 100
// oversized motifs with 2- and 3-byte varints) and runs the whole renderer suite against each, then the
// 1/1 page tests. Gas ceilings are skipped: they apply to the final geometry only.
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const onchain = resolve(root, '../onchain');
const synth = resolve(onchain, 'build-synth');

function run(cmd, args, env = {}) {
  console.log(`\n$ ${[cmd, ...args].join(' ')}`);
  const r = spawnSync(cmd, args, { cwd: root, env: { ...process.env, ...env }, stdio: 'inherit' });
  if (r.error) throw r.error;
  if (r.status !== 0) process.exit(r.status ?? 1);
}

run('python3', [resolve(onchain, 'synth_geometry.py'), synth]);
for (const [name, extra] of [['first700', []], ['plus100', ['--allow-out-of-band']]]) {
  run('python3', [resolve(onchain, 'pack_store.py'), '--geometry', resolve(synth, `${name}.raw`),
    '--out', resolve(synth, name), ...extra]);
  run('node', ['scripts/forge.mjs', 'test', '--match-path', 'test/render/*', '--no-match-contract',
    'RenderGasLimitsTest'], { KILIM_STORE_DIR: `../onchain/build-synth/${name}` });
}
run('node', ['--test', resolve(onchain, 'test/page.test.mjs')]);
