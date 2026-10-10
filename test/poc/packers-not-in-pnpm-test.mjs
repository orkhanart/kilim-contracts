// PoC for the review finding "pnpm test / test:ci never run test:pack or test:page, and there is no CI".
//
// It breaks the page packer on purpose (removes the '#' / '%' refusal in data_url_text, one of the
// three fixes made after the rewrite), then runs the two commands and reports what each one saw:
//   pnpm -s test:pack        must fail  (the packers' own unit tests catch the regression)
//   pnpm -s test:contracts   must pass  (the forge half of `pnpm test`; it never runs Python)
// The site half of `pnpm test` is not run here: ../site/test spawns python3 only for site/build.py
// and site/tools (grep "pack_page\|pack_glyphs" site/test finds no caller), so it cannot see the
// packer either. The forge profile has no ffi, and the stores it reads (onchain/build-*) are
// gitignored outputs of the packer, so a packer regression is invisible to it.
//
// onchain/pack_page.py is restored byte for byte, also on Ctrl-C or a crash. Do not run it while
// something else packs. From contracts/:  node test/poc/packers-not-in-pnpm-test.mjs
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const contracts = fileURLToPath(new URL('../..', import.meta.url));
const packer = fileURLToPath(new URL('../../../onchain/pack_page.py', import.meta.url));
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

const original = readFileSync(packer);
const before = sha256(original);
let restored = false;
const restore = () => {
  if (restored) return;
  writeFileSync(packer, original);
  restored = true;
  const after = sha256(readFileSync(packer));
  console.log(`restored onchain/pack_page.py: ${after === before ? 'same bytes' : 'MISMATCH, check git diff'}`);
};
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => { restore(); process.exit(130); });
process.on('exit', restore);

const marker = "    if '#' in s or '%' in s:\n";
const text = original.toString('utf8');
if (text.split(marker).length !== 2) throw new Error('the refusal line was not found exactly once; the packer changed, update this PoC');
writeFileSync(packer, text.replace(marker, '    if False:  # PoC regression: the data-URL refusal removed\n'));
console.log('injected the regression into onchain/pack_page.py');

const run = (script) => {
  const r = spawnSync('pnpm', ['-s', script], { cwd: contracts, encoding: 'utf8' });
  const tail = (r.stdout + r.stderr).trim().split('\n').slice(-3).join('\n  ');
  console.log(`\n$ pnpm -s ${script}  -> exit ${r.status}\n  ${tail}`);
  return r.status;
};

const pack = run('test:pack');
const forge = run('test:contracts');
restore();

const reproduced = pack !== 0 && forge === 0;
console.log(`\n${reproduced ? 'REPRODUCED' : 'NOT REPRODUCED'}: test:pack exit ${pack}, test:contracts exit ${forge}`);
process.exit(reproduced ? 0 : 1);
