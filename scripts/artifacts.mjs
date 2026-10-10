import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
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
for (const name of ['KilimMotifs', 'KilimOneOfOne', 'KilimAuction']) {
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
const inputs = ['foundry.toml', 'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'audit/requirements.txt'];
function collectInputs(directory) {
  for (const entry of readdirSync(resolve(root, directory), { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) collectInputs(path);
    else if (entry.isFile()) inputs.push(path);
  }
}
for (const directory of ['src', 'test', 'scripts', 'script', 'deploy', 'vendor']) collectInputs(directory);
for (const path of inputs.sort()) {
  manifest.sourceSha256[path] = sha256(readFileSync(resolve(root, path)));
}
writeFileSync(resolve(root, 'audit/build-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log('Exported ABIs and audit/build-manifest.json. No deployment performed.');
