// Local dev chain for the site: anvil on 127.0.0.1:8545, a fresh Kilim deployment (native ETH), the
// site config in site/chains/31337.json, and the *.dev.html pages. Runs until Ctrl-C.
//
//   pnpm dev:chain                    deploy; registration opens at startsAt (two minutes later)
//   pnpm dev:chain --open             warp to startsAt and register 100 throwaway wallets: bidding is unlocked
//   pnpm dev:chain --registering      warp to startsAt and register 98, so the page can register the last two
//   pnpm dev:chain --registering 40   ...or leave any other number registered (0 to 99)
//   pnpm dev:chain --port 8546 --no-build
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from './dev/anvil.mjs';
import { deployLocal, siteConfig, rpcClient, registerWallets, REGISTRATION_TARGET } from './dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const contracts = resolve(here, '..');
const site = resolve(contracts, '../site');
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : fallback; };

function run(cmd, argv, cwd) {
  const r = spawnSync(cmd, argv, { cwd, stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

// How many wallets to register before handing over: 100 with --open, fewer with --registering.
let register = null;
if (flag('--open')) register = REGISTRATION_TARGET;
if (flag('--registering')) {
  const n = Number(/^\d+$/.test(value('--registering', '')) ? value('--registering') : REGISTRATION_TARGET - 2);
  if (flag('--open') || n >= REGISTRATION_TARGET) { console.error('--registering leaves registration open: pass 0 to 99, without --open'); process.exit(1); }
  register = n;
}

if (!flag('--no-build')) run(process.execPath, ['scripts/forge.mjs', 'build'], contracts);

const port = Number(value('--port', '8545'));
const anvil = await startAnvil({ port });
console.log(`anvil ${anvil.rpcUrl}`);
let stopping = false;
async function stop(code = 0) { if (stopping) return; stopping = true; await anvil.stop(); process.exit(code); }
process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));

try {
  const d = await deployLocal(anvil.rpcUrl);
  const cfg = siteConfig(d, { rpcUrl: anvil.rpcUrl });
  writeFileSync(resolve(site, 'chains/31337.json'), JSON.stringify(cfg, null, 2) + '\n');
  console.log(`auction    ${cfg.auction}\ncollection ${cfg.collection}\ndeployed at block ${d.deployBlock}; registration opens at ${new Date(d.startsAt * 1000).toISOString()}`);
  if (register !== null) {
    const count = await registerWallets(rpcClient(anvil.rpcUrl), d, register);
    console.log(count === REGISTRATION_TARGET
      ? 'warped to startsAt and registered 100 wallets: bidding is unlocked (the 24h clock starts with the first bid)'
      : `warped to startsAt and registered ${count} wallets: ${REGISTRATION_TARGET - count} more unlock bidding (register from the page, or the dev panel)`);
  }
  run('python3', [resolve(site, 'build.py'), '--dev'], resolve(contracts, '..'));
  const base = 'http://127.0.0.1:8765';
  console.log(`
Serve the site (another terminal):
  python3 -m http.server 8765 --bind 127.0.0.1 --directory site
Then open:
  ${base}/auction.dev.html?as=1   Alice
  ${base}/auction.dev.html?as=2   Bob
  ${base}/auction.dev.html?as=9   the treasury (cannot register or bid)
  ${base}/weave.dev.html?as=1     the weaving page
  ${base}/index.dev.html          the landing page
Accounts 0-9 hold 10,000 test ETH. Bids, refunds and proceeds are ETH. Ctrl-C stops anvil.`);
} catch (e) {
  console.error(e);
  await stop(1);
}
