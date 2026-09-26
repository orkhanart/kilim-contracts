import { createRequire } from 'node:module';

// Resolve the lockfile's native Foundry binary (forge, anvil) for this platform.
const require = createRequire(import.meta.url);

export function foundryBinary(tool) {
  const toolRequire = createRequire(require.resolve(`@foundry-rs/${tool}/package.json`));
  const arch = process.arch === 'x64' ? 'amd64' : process.arch;
  const executable = process.platform === 'win32' ? `${tool}.exe` : tool;
  return toolRequire.resolve(`@foundry-rs/${tool}-${process.platform}-${arch}/bin/${executable}`);
}
