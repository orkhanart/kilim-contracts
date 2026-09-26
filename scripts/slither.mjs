import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync, rmSync, readFileSync, writeFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const forgeRequire = createRequire(require.resolve('@foundry-rs/forge/package.json'));
const arch = process.arch === 'x64' ? 'amd64' : process.arch;
const binary = forgeRequire.resolve(`@foundry-rs/forge-${process.platform}-${arch}/bin/forge`);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
mkdirSync(resolve(root, 'audit'), { recursive: true });
rmSync(resolve(root, 'audit/slither.json'), { force: true });
const result = spawnSync(resolve(root, '.venv/bin/slither'), [
  '.', '--filter-paths', 'node_modules|test/', '--json', 'audit/slither.json', '--fail-medium',
], {
  cwd: root,
  env: { ...process.env, PATH: [dirname(binary), dirname(process.execPath), process.env.PATH ?? ''].join(delimiter) },
  stdio: 'inherit',
});
if (result.error) throw result.error;
const report = JSON.parse(readFileSync(resolve(root, 'audit/slither.json'), 'utf8'));
writeFileSync(resolve(root, 'audit/slither-summary.json'), JSON.stringify({
  success: report.success,
  error: report.error,
  findings: (report.results?.detectors ?? []).map(({ check, impact, confidence, description }) => ({
    check, impact, confidence, description,
  })),
}, null, 2) + '\n');
process.exit(result.status ?? 1);
