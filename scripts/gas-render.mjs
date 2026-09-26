// Runs the renderer gas-ceiling tests and writes their measurements to audit/gas-render.txt.
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const r = spawnSync('node', ['scripts/forge.mjs', 'test', '--match-contract', 'RenderGasLimitsTest', '--json', '-vv'], {
  cwd: root, encoding: 'utf8', maxBuffer: 64 << 20,
});
if (r.error) throw r.error;
const start = r.stdout.indexOf('{');
const results = JSON.parse(r.stdout.slice(start));
const lines = [];
let failed = false;
for (const suite of Object.values(results)) {
  for (const [name, t] of Object.entries(suite.test_results)) {
    if (t.status !== 'Success') failed = true;
    for (const log of t.decoded_logs ?? []) {
      const m = /^(gas|size): (.*): (\d+)$/.exec(log.trim());
      if (m) lines.push([m[1], m[2], Number(m[3]), name, t.status]);
    }
  }
}
lines.sort((a, b) => (a[0] + a[1]).localeCompare(b[0] + b[1]));
const pad = Math.max(...lines.map((l) => l[1].length));
const text = [
  '# Renderer gas and sizes, from test/render/RenderGasLimits.t.sol (pnpm gas:render).',
  '# Gas is an eth_call estimate: callee gas through a staticcall that copies nothing back, plus 21,000',
  '# and 16 gas per calldata byte. Store: onchain/build. Ceilings: symbol 0.6M, artwork 36M, typical',
  '# artwork 24M, 1/1 24M, anything 45M, every deployment transaction 8M.',
  '',
  ...lines.map(([kind, label, value, , status]) =>
    `${kind.padEnd(4)} ${label.padEnd(pad)}  ${value.toLocaleString('en-US').padStart(12)}${status === 'Success' ? '' : '  FAILED'}`),
  '',
].join('\n');
writeFileSync(resolve(root, 'audit/gas-render.txt'), text);
process.stdout.write(text);
if (failed || r.status !== 0) process.exit(1);
