import { spawnSync } from 'node:child_process';
import { dirname, resolve, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { foundryBinary } from './foundry-bin.mjs';

// Use the lockfile's native binary directly and propagate failures to CI.
const binary = foundryBinary('forge');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const result = spawnSync(binary, process.argv.slice(2), {
  cwd: root,
  env: { ...process.env, PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ''}` },
  stdio: 'inherit',
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
