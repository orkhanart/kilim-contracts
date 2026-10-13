import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import solc from 'solc';
import './verify-upstream.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const solcRequire = createRequire(require.resolve('solc/package.json'));
const { keccak_256 } = solcRequire('js-sha3'); // Already pinned by solc in the lockfile.
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const manifest = { schema: 2, contracts: {}, compiledSourceKeccak256: {}, sourceSha256: {} };
mkdirSync(resolve(root, 'abi'), { recursive: true });
for (const name of ['KilimMotifs', 'KilimOneOfOne', 'KilimAuction', 'KilimBazaar']) {
  const artifact = JSON.parse(readFileSync(resolve(root, `out/${name}.sol/${name}.json`), 'utf8'));
  const metadata = typeof artifact.metadata === 'string' ? JSON.parse(artifact.metadata) : artifact.metadata;
  const expectedCompiler = solc.version().split('.Emscripten')[0];
  if (metadata.compiler.version !== expectedCompiler) {
    throw new Error(`Unexpected compiler: ${metadata.compiler.version}`);
  }
  if (metadata.settings.evmVersion !== 'cancun' || !metadata.settings.optimizer.enabled
      || metadata.settings.optimizer.runs !== 200 || metadata.settings.viaIR === true
      || metadata.settings.metadata?.bytecodeHash !== 'ipfs') {
    throw new Error('Build settings mismatch: run pnpm build before exporting.');
  }
  for (const [path, source] of Object.entries(metadata.sources)) {
    const actual = `0x${keccak_256(readFileSync(resolve(root, path)))}`;
    if (actual !== source.keccak256) throw new Error(`Stale build input ${path}; run pnpm build.`);
    manifest.compiledSourceKeccak256[path] = actual;
  }
  if (!/^0x[0-9a-f]+$/i.test(artifact.bytecode.object)
      || !/^0x[0-9a-f]+$/i.test(artifact.deployedBytecode.object)) {
    throw new Error(`Unlinked or invalid bytecode for ${name}.`);
  }
  writeFileSync(resolve(root, `abi/${name}.json`), JSON.stringify(artifact.abi, null, 2) + '\n');
  manifest.contracts[name] = {
    compiler: metadata.compiler.version,
    evmVersion: metadata.settings.evmVersion,
    optimizer: metadata.settings.optimizer,
    viaIR: metadata.settings.viaIR ?? false,
    creationBytecodeBytes: (artifact.bytecode.object.length - 2) / 2,
    runtimeTemplateBytes: (artifact.deployedBytecode.object.length - 2) / 2,
    creationBytecodeSha256: sha256(Buffer.from(artifact.bytecode.object.slice(2), 'hex')),
    abiSha256: sha256(readFileSync(resolve(root, `abi/${name}.json`))),
  };
}
// The files git tracks, at their working-tree content, and only those: an untracked leftover (a scratch
// config, a local helper) never enters the manifest, so a clean checkout of the tag regenerates it byte
// for byte and `git diff` on it is a real comparison (final rehearsal F4, 12 October 2026).
const inputs = ['foundry.toml', 'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'audit/requirements.txt'];
const tracked = execFileSync('git', ['ls-files', '-z', '--', ...inputs, 'src', 'test', 'scripts', 'script', 'deploy', 'vendor'],
  { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
for (const path of inputs) {
  if (!tracked.includes(path)) throw new Error(`${path} is not tracked by git.`);
}
for (const path of [...new Set(tracked)].sort()) {
  if (!existsSync(resolve(root, path))) throw new Error(`${path} is tracked but missing from the working tree.`);
  manifest.sourceSha256[path] = sha256(readFileSync(resolve(root, path)));
}
writeFileSync(resolve(root, 'audit/build-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log('Exported ABIs and audit/build-manifest.json. No deployment performed.');
