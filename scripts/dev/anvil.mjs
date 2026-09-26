import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { foundryBinary } from '../foundry-bin.mjs';

// The default anvil/hardhat test mnemonic. Its keys are public: local chains only.
export const TEST_MNEMONIC = 'test test test test test test test test test test test junk';

function freePort(wanted = 0) {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.unref();
    server.on('error', (e) => reject(e.code === 'EADDRINUSE' ? new Error(`Port ${wanted} on 127.0.0.1 is already in use; pass another port.`) : e));
    server.listen(wanted, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolvePort(port));
    });
  });
}

async function rpc(url, method, params = []) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

/**
 * Start a local anvil on 127.0.0.1. Resolves once it answers eth_chainId. `gasLimit` sets the block
 * gas limit (anvil's default is 30M).
 * @returns {Promise<{rpcUrl: string, port: number, chainId: number, stop: () => Promise<void>}>}
 */
export async function startAnvil({ port, chainId = 31337, forkUrl, forkBlock, gasLimit, quiet = true } = {}) {
  const chosen = await freePort(port ?? 0);
  const args = [
    '--host', '127.0.0.1', '--port', String(chosen), '--chain-id', String(chainId),
    '--accounts', '10', '--balance', '10000', '--mnemonic', TEST_MNEMONIC,
  ];
  if (forkUrl) args.push('--fork-url', forkUrl);
  if (forkUrl && forkBlock) args.push('--fork-block-number', String(forkBlock));
  // A higher block gas limit also raises anvil's eth_call cap (the heaviest tokenURI needs ~30.4M).
  if (gasLimit) args.push('--gas-limit', String(gasLimit));
  const child = spawn(foundryBinary('anvil'), args, { stdio: ['ignore', quiet ? 'ignore' : 'inherit', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  let exited = null;
  child.on('exit', (code) => { exited = code ?? -1; });
  const rpcUrl = `http://127.0.0.1:${chosen}`;
  const deadline = Date.now() + (forkUrl ? 60_000 : 15_000);
  for (;;) {
    if (exited !== null) throw new Error(`anvil exited (${exited}): ${stderr.trim()}`);
    try {
      const id = await rpc(rpcUrl, 'eth_chainId');
      if (Number(id) !== chainId) throw new Error(`anvil answered chain ${Number(id)}, expected ${chainId}`);
      break;
    } catch (error) {
      if (/expected/.test(error.message)) { child.kill(); throw error; }
      if (Date.now() > deadline) { child.kill(); throw new Error(`anvil did not start: ${stderr.trim()}`); }
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return {
    rpcUrl,
    port: chosen,
    chainId,
    stop: () => new Promise((resolveStop) => {
      if (exited !== null) return resolveStop();
      child.once('exit', () => resolveStop());
      child.kill('SIGTERM');
      setTimeout(() => { if (exited === null) child.kill('SIGKILL'); }, 3000).unref();
    }),
  };
}
