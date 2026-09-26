// Measures the renderer on the real store and both synthetic stores, then refits pack_store.py's
// GAS_MODEL with onchain/fit_gas_model.py (needs numpy). Paste the printed coefficients into GAS_MODEL.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const onchain = resolve(root, '../onchain');
const synth = resolve(onchain, 'build-synth');
const logs = mkdtempSync(join(tmpdir(), 'kilim-gas-'));

function run(cmd, args, env = {}, capture = false) {
  const r = spawnSync(cmd, args, {
    cwd: root, env: { ...process.env, ...env }, encoding: 'utf8', maxBuffer: 64 << 20,
    stdio: capture ? 'pipe' : 'inherit',
  });
  if (r.error) throw r.error;
  if (r.status !== 0) {
    if (capture) process.stderr.write(r.stdout + r.stderr);
    process.exit(r.status ?? 1);
  }
  return r.stdout;
}

run('python3', [resolve(onchain, 'synth_geometry.py'), synth]);
const stores = [['build', resolve(onchain, 'build')]];
for (const [name, extra] of [['first700', []], ['plus100', ['--allow-out-of-band']]]) {
  run('python3', [resolve(onchain, 'pack_store.py'), '--geometry', resolve(synth, `${name}.raw`),
    '--out', resolve(synth, name), ...extra], {}, true);
  stores.push([name, resolve(synth, name)]);
}
const args = [];
for (const [name, dir] of stores) {
  const out = run('node', ['scripts/forge.mjs', 'test', '--match-contract', 'RenderCalibrateTest', '-vv'],
    { KILIM_CALIBRATE: 'true', KILIM_STORE_DIR: dir }, true);
  const file = join(logs, `${name}.log`);
  writeFileSync(file, out);
  args.push(dir, file);
}
run('python3', [resolve(onchain, 'fit_gas_model.py'), ...args]);
