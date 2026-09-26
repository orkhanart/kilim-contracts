import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';

// Use the lockfile's native binary directly and propagate failures to CI.
const require = createRequire(import.meta.url);
const forgeRequire = createRequire(require.resolve('@foundry-rs/forge/package.json'));
const arch = process.arch === 'x64' ? 'amd64' : process.arch;
const executable = process.platform === 'win32' ? 'forge.exe' : 'forge';
const binary = forgeRequire.resolve(`@foundry-rs/forge-${process.platform}-${arch}/bin/${executable}`);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const result = spawnSync(binary, process.argv.slice(2), {
  cwd: root,
  env: { ...process.env, PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ''}` },
  stdio: 'inherit',
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
