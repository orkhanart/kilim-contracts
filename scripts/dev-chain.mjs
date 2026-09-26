// Local dev chain for the site: anvil on 127.0.0.1:8545, a fresh Kilim deployment, the site
// config in site/chains/31337.json, and the *.dev.html pages. Runs until Ctrl-C.
//
//   pnpm dev:chain                  deploy with MockUSD and the DevUniswap stand-in
//   pnpm dev:chain --open           ...and warp past startsAt so bidding is open
//   pnpm dev:chain --fork mainnet   fork Ethereum (KILIM_FORK_URL, default publicnode) with real USDC + Uniswap
//   pnpm dev:chain --port 8546 --no-build
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from './dev/anvil.mjs';
import { deployLocal, siteConfig, rpcClient } from './dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const contracts = resolve(here, '..');
const site = resolve(contracts, '../site');
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : fallback; };

const FORKS = {
  mainnet: { chain: 1, url: 'https://ethereum-rpc.publicnode.com' },
  sepolia: { chain: 11155111, url: 'https://ethereum-sepolia-rpc.publicnode.com' },
};

function run(cmd, argv, cwd) {
  const r = spawnSync(cmd, argv, { cwd, stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

if (!flag('--no-build')) run(process.execPath, ['scripts/forge.mjs', 'build'], contracts);

const port = Number(value('--port', '8545'));
const forkName = value('--fork', null);
let fork = null, ethUsdRange = null;
if (forkName) {
  if (!FORKS[forkName]) { console.error(`--fork must be one of ${Object.keys(FORKS).join(', ')}`); process.exit(1); }
  const real = JSON.parse(readFileSync(resolve(site, `chains/${FORKS[forkName].chain}.json`), 'utf8'));
  ethUsdRange = real.ethUsdRange ?? null;                 // the real chain's ETH/USD sanity band
  fork = { url: process.env.KILIM_FORK_URL || FORKS[forkName].url, block: process.env.KILIM_FORK_BLOCK,
           usdc: real.usdc, weth: real.weth, swapRouter02: real.swapRouter02, quoterV2: real.quoterV2, feeTiers: real.feeTiers };
}

const anvil = await startAnvil({ port, forkUrl: fork?.url, forkBlock: fork?.block });
console.log(`anvil ${anvil.rpcUrl}${fork ? ` (fork of ${forkName})` : ''}`);
let stopping = false;
async function stop(code = 0) { if (stopping) return; stopping = true; await anvil.stop(); process.exit(code); }
process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));

try {
  const d = await deployLocal(anvil.rpcUrl, fork ? { fork } : {});
  const cfg = siteConfig(d, { rpcUrl: anvil.rpcUrl, name: fork ? `Local anvil (fork of ${forkName})` : 'Local anvil', fork: forkName });
  if (ethUsdRange) cfg.ethUsdRange = ethUsdRange;
  writeFileSync(resolve(site, 'chains/31337.json'), JSON.stringify(cfg, null, 2) + '\n');
  console.log(`auction    ${cfg.auction}\ncollection ${cfg.collection}\nUSDC       ${cfg.usdc}\ndeployed at block ${d.deployBlock}; bidding opens at ${new Date(d.startsAt * 1000).toISOString()}`);
  if (flag('--open')) {
    const rpc = rpcClient(anvil.rpcUrl);
    await rpc.call('evm_setNextBlockTimestamp', [d.startsAt]);
    await rpc.call('evm_mine');
    console.log('warped to startsAt: bidding is open (the 24h clock starts with the first bid)');
  }
  run('python3', [resolve(site, 'build.py'), '--dev'], resolve(contracts, '..'));
  const base = 'http://127.0.0.1:8765';
  console.log(`
Serve the site (another terminal):
  python3 -m http.server 8765 --bind 127.0.0.1 --directory site
Then open:
  ${base}/auction.dev.html?as=1&batch=1   Alice, batched (one confirmation)
  ${base}/auction.dev.html?as=2&batch=0   Bob, sequential transactions
  ${base}/auction.dev.html?as=9           the treasury (cannot bid)
  ${base}/merge.dev.html?as=1             the weaving studio
  ${base}/index.dev.html                  the landing page
Accounts 1-8 hold 100,000 test USDC and 10,000 ETH. Ctrl-C stops anvil.`);
} catch (e) {
  console.error(e);
  await stop(1);
}
