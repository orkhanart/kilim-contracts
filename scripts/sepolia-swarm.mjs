// The Sepolia swarm: robot wallets run the whole Kilim auction on the Sepolia rehearsal deployment,
// through the site's own adapter (site/chain.js) wherever a visitor would use the page, and check the
// contracts after every step. Test ETH only; it refuses any chain but Sepolia.
//
//   node scripts/sepolia-swarm.mjs run       the whole test, resumable: rerun it after any stop
//   node scripts/sepolia-swarm.mjs status    balances, phase and the next step
//   node scripts/sepolia-swarm.mjs check     the invariants once, at the latest block
//
// Keys: ~/.kilim-sepolia-swarm/ (a random seed for the robot wallets, and the pool wallet's keystore
// with its password file, copied there by hand). Never commit them; they hold test ETH only.
// Record: contracts/audit/sepolia-swarm/ (events.jsonl, checks.jsonl, gas.json, status.json, log.txt).
//
// The plan (rehearses checklists/1-pre-deploy.md's testnet items with real transactions):
//   1. Refusals simulated before registration completes (eth_call; nothing sent).
//   2. 100 check-ins in three relays: each robot holds the 0.01 ETH, checks in through chain.js, then
//      passes the ETH to the next. Every tenth signs the EIP-712 check-in and the pool submits it
//      with registerFor (the sponsor's path).
//   3. The opening bid starts the 24-hour clock; two EOAs and a contract wallet that cannot receive
//      ETH bid at the minimum, so one outbid refund is pushed and one deferred and withdrawn; a bid at
//      half time; then two late bids inside the last 10 minutes, each extending the close.
//   4. After the close: settle (the 1/1 delivered to the winner), every robot claims its motifs, the
//      1/1's tokenURI is compared with the golden, refusals after the close are simulated.
//   5. The treasury's withdrawProceeds is the artist's to send (orkhanart.eth); the swarm only
//      simulates it, then returns every robot's leftover test ETH to the pool.
// Invariants (contracts/AUDIT.md, the auction's accounting) are checked after every action and every
// minute: the auction's balance equals liabilities(), the counters equal the events, the site's
// snapshot equals the contracts.
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { randomBytes, createHash } from 'node:crypto';
import { loadSite, CORE, SITE } from '../../site/tools/node-load.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(here, '../../registration-relayer/package.json'));
const { ethers } = require('ethers'); // registration-relayer's ethers 6; the contracts package has none

const CHAIN_ID = 11155111;
const CHAIN_HEX = '0xaa36a7';
const SITE_CFG = JSON.parse(readFileSync(join(SITE, 'chains', `${CHAIN_ID}.json`), 'utf8'));
const AUCTION = SITE_CFG.auction, MOTIFS = SITE_CFG.motifs, ONE = SITE_CFG.oneOfOne;
const DEPLOY_BLOCK = SITE_CFG.deployBlock;
// SWARM_RPC and SWARM_OUT point a rehearsal at a local fork of Sepolia (anvil) and a scratch record.
const RPCS = process.env.SWARM_RPC ? [process.env.SWARM_RPC] : ['https://ethereum-sepolia-rpc.publicnode.com', 'https://sepolia.drpc.org'];
if (process.env.SWARM_RPC) SITE_CFG.rpcUrls = [process.env.SWARM_RPC];
const HOME = join(homedir(), '.kilim-sepolia-swarm');
const OUT = process.env.SWARM_OUT ? resolve(process.env.SWARM_OUT) : resolve(here, '../audit/sepolia-swarm');
const ETH = 10n ** 18n, MILLI = 10n ** 15n;
const TIP = 2_000_000n;                       // 0.002 gwei: Sepolia's base fee is a few wei
const HOLD = 10n * MILLI + 200_000_000_000_000n; // 0.0102 ETH: the 0.01 a check-in needs, plus every hop's gas
const RELAYS = 3;
const ROBOTS = 100;
const BIDDERS = { B1: 201, B2: 202, B3: 203 }; // B3 owns the contract wallet CW and settles
const LATE_FIRST = 240, LATE_SECOND = 120;     // seconds before the close for the two late bids
// The artist places the opening bid from a wallet of their own, through the page: the swarm waits this long
// after the 100th check-in before it opens the auction itself (0 = open at once).
const WAIT_OPEN = Number(process.env.SWARM_WAIT_OPEN ?? 3 * 3600);

if (!ethers) throw new Error('ethers not found: run pnpm install in registration-relayer');
for (const [k, v] of Object.entries({ AUCTION, MOTIFS, ONE })) if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`site/chains/${CHAIN_ID}.json has no ${k}`);

// ---------------------------------------------------------------- record
mkdirSync(OUT, { recursive: true });
const STATUS = join(OUT, 'status.json');
const state = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : { done: {}, gas: {}, notes: [] };
state.done ??= {}; state.gas ??= {}; state.notes ??= [];
const saveState = () => writeFileSync(STATUS, JSON.stringify(state, null, 1));
const stamp = () => new Date().toISOString();
const json = (o) => JSON.stringify(o, (k, v) => (typeof v === 'bigint' ? v.toString() : v));
function log(line) { const s = `${stamp()}  ${line}`; console.log(s); appendFileSync(join(OUT, 'log.txt'), s + '\n'); }
function record(o) { appendFileSync(join(OUT, 'events.jsonl'), json({ t: stamp(), ...o }) + '\n'); }
function checkRecord(o) { appendFileSync(join(OUT, 'checks.jsonl'), json({ t: stamp(), ...o }) + '\n'); }
function gasNote(label, gasUsed) {
  const g = (state.gas[label] ??= { n: 0, min: null, max: null, sum: 0 });
  const u = Number(gasUsed);
  g.n++; g.sum += u; g.min = g.min === null ? u : Math.min(g.min, u); g.max = g.max === null ? u : Math.max(g.max, u);
  writeFileSync(join(OUT, 'gas.json'), JSON.stringify(state.gas, null, 1));
}
let failures = 0;
function fail(what, detail) { failures++; log(`FAIL ${what}${detail ? ': ' + detail : ''}`); checkRecord({ ok: false, what, detail }); }
function pass(what, detail) { checkRecord({ ok: true, what, detail }); }
// An exception in a step (a node timing out, a race with another bidder): recorded and retried, and
// listed by the verdict for review, apart from the checks of the contracts and the site.
function stepError(what, detail) { log(`step error ${what}: ${String(detail).split('\n')[0]}`); checkRecord({ ok: false, kind: 'step', what, detail }); }

// ---------------------------------------------------------------- rpc
let rpcId = 1;
async function rpc(method, params = []) {
  let last;
  for (const url of RPCS) {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, params }), signal: AbortSignal.timeout(30000) });
        const body = await res.json();
        if (body.error) {
          const e = new Error(body.error.message || 'rpc error'); e.code = body.error.code; e.data = body.error.data; e.rpc = true;
          // A revert or an answer about the transaction itself is final; anything else (rate limits,
          // a backend behind, an internal error) is retried and then sent to the other endpoint.
          e.final = !!e.data || /revert|insufficient funds|nonce|already known|underpriced|invalid|exceeds/i.test(e.message);
          throw e;
        }
        return body.result;
      } catch (e) {
        if (e.rpc && e.final) throw e;
        last = e; await sleep(1500 * (attempt + 1));
      }
    }
  }
  throw last;
}
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
// A read right after a receipt can reach a load-balanced backend a block behind: ask again a few times.
async function eventually(read, ok, tries = 8) {
  let v;
  for (let i = 0; i < tries; i++) { v = await read(); if (ok(v)) return v; await sleep(2500); }
  return v;
}
const hex = (n) => '0x' + BigInt(n).toString(16);
const fmt = (wei) => ethers.formatEther(wei);

const abiOf = (n, dir = 'src') => JSON.parse(readFileSync(resolve(here, `../out/${n}.sol/${n}.json`), 'utf8'));
const iA = new ethers.Interface(abiOf('KilimAuction').abi);
const iM = new ethers.Interface(abiOf('KilimMotifs').abi);
const iO = new ethers.Interface(abiOf('KilimOneOfOne').abi);
const CW_ART = abiOf('SwarmBidder');
const iCW = new ethers.Interface(CW_ART.abi);
async function view(iface, to, fn, args = [], tag = 'latest') {
  return iface.decodeFunctionResult(fn, await rpc('eth_call', [{ to, data: iface.encodeFunctionData(fn, args) }, tag]));
}
const A = (fn, args, tag) => view(iA, AUCTION, fn, args, tag).then((r) => r[0]);
const balanceOf = async (who, tag = 'latest') => BigInt(await rpc('eth_getBalance', [who, tag]));

// ---------------------------------------------------------------- keys
function seedHex() {
  const p = join(HOME, 'seed.hex');
  if (!existsSync(p)) {
    if (state.robots) throw new Error(`${p} is missing but ${STATUS} names robots: restore the seed, do not make a new one`);
    mkdirSync(HOME, { recursive: true, mode: 0o700 }); writeFileSync(p, randomBytes(32).toString('hex'), { mode: 0o600 });
  }
  return readFileSync(p, 'utf8').trim();
}
const SEED = seedHex();
const robot = (i) => new ethers.Wallet(ethers.keccak256(ethers.concat(['0x' + SEED, ethers.toBeHex(i, 32)])));
{
  const names = { B1: robot(201).address, B2: robot(202).address, B3: robot(203).address, R1: robot(1).address, R100: robot(100).address };
  if (state.robots && JSON.stringify(state.robots) !== JSON.stringify(names)) throw new Error('the seed does not match the robots in status.json');
  state.robots = names;
}
async function poolWallet() {
  const ks = join(HOME, 'pool-keystore.json'), pw = join(HOME, 'pool-password.txt');
  if (!existsSync(ks) || !existsSync(pw)) throw new Error(`put the pool wallet's keystore and password at ${ks} and ${pw}`);
  return ethers.Wallet.fromEncryptedJson(readFileSync(ks, 'utf8'), readFileSync(pw, 'utf8').trim());
}

// ---------------------------------------------------------------- sending
const locks = new Map(), nonces = new Map();
async function withLock(key, fn) {
  const prev = locks.get(key) || Promise.resolve();
  let release; const mine = new Promise((ok) => { release = ok; });
  locks.set(key, prev.then(() => mine));
  await prev;
  try { return await fn(); } finally { release(); }
}
async function sendRaw(wallet, tx, label) {
  const from = wallet.address;
  return withLock(from, async () => {
    if (!nonces.has(from)) nonces.set(from, Number(await rpc('eth_getTransactionCount', [from, 'pending'])));
    const block = await rpc('eth_getBlockByNumber', ['latest', false]);
    const base = BigInt(block.baseFeePerGas);
    const value = BigInt(tx.value || 0);
    let gas = tx.gas != null ? BigInt(tx.gas) : null;
    if (gas === null) {
      const est = BigInt(await rpc('eth_estimateGas', [{ from, to: tx.to, value: hex(value), data: tx.data || '0x' }]));
      gas = est * 5n / 4n + 20_000n;
    }
    const req = { type: 2, chainId: CHAIN_ID, nonce: nonces.get(from), to: tx.to, value, data: tx.data || '0x',
      gasLimit: gas, maxFeePerGas: 2n * base + TIP, maxPriorityFeePerGas: TIP };
    const raw = await wallet.signTransaction(req);
    const hash = ethers.keccak256(raw);
    for (let attempt = 0; ; attempt++) {
      try { await rpc('eth_sendRawTransaction', [raw]); break; }
      catch (e) {
        // A backend a block behind has not seen the ETH that just arrived: send the same transaction again.
        if (/insufficient funds/i.test(e.message) && attempt < 6) { await sleep(4000); continue; }
        const seen = /already known/i.test(e.message) || (!e.final && (await rpc('eth_getTransactionByHash', [hash]).catch(() => null)));
        if (!seen) { nonces.delete(from); throw e; }
        break;
      }
    }
    nonces.set(from, req.nonce + 1);
    record({ kind: 'sent', label, from, to: tx.to, value, gas, nonce: req.nonce, hash });
    return hash;
  });
}
async function receipt(hash, label) {
  for (let i = 0; i < 200; i++) {
    const r = await rpc('eth_getTransactionReceipt', [hash]).catch(() => null);
    if (r) {
      record({ kind: 'receipt', label, hash, status: r.status, gasUsed: BigInt(r.gasUsed), block: Number(r.blockNumber),
        price: BigInt(r.effectiveGasPrice || 0), logs: decodeLogs(r.logs) });
      if (r.status === '0x1') gasNote(label, BigInt(r.gasUsed));
      return r;
    }
    await sleep(3000);
  }
  throw new Error(`no receipt for ${label} ${hash} after 10 minutes`);
}
async function sendAndWait(wallet, tx, label) {
  const hash = await sendRaw(wallet, tx, label);
  const r = await receipt(hash, label);
  if (r.status !== '0x1') throw new Error(`${label} reverted on chain (${hash})`);
  return r;
}
async function transferAll(wallet, to, label) {
  const bal = await balanceOf(wallet.address, 'pending');
  const est = BigInt(await rpc('eth_estimateGas', [{ from: wallet.address, to, value: '0x1' }]));
  const gas = est * 6n / 5n;
  const base = BigInt((await rpc('eth_getBlockByNumber', ['latest', false])).baseFeePerGas);
  const cost = gas * (2n * base + TIP) + 500_000_000_000n; // and 0.0000005 ETH for a node a block behind
  if (bal <= cost) return null;
  return sendAndWait(wallet, { to, value: bal - cost, gas }, label);
}
async function topUp(pool, who, need, label) {
  const bal = await balanceOf(who, 'pending');
  if (bal >= need) return;
  await sendAndWait(pool, { to: who, value: need - bal }, label);
}

// ---------------------------------------------------------------- events
function decodeLogs(logs) {
  const out = [];
  for (const l of logs || []) {
    const addr = l.address.toLowerCase();
    const iface = addr === AUCTION.toLowerCase() ? iA : addr === MOTIFS.toLowerCase() ? iM : addr === ONE.toLowerCase() ? iO : null;
    if (!iface) continue;
    try {
      const p = iface.parseLog(l);
      if (p) out.push({ address: addr, name: p.name, args: Object.fromEntries(p.fragment.inputs.map((inp, i) => [inp.name, p.args[i]])),
        tx: l.transactionHash, block: Number(l.blockNumber), index: Number(l.logIndex) });
    } catch {}
  }
  return out;
}
const LOGCACHE = join(OUT, 'logcache.json');
const logCache = existsSync(LOGCACHE) ? JSON.parse(readFileSync(LOGCACHE, 'utf8')) : { to: DEPLOY_BLOCK - 1, logs: {} };
async function getLogs(from, to) {
  const q = (a, b) => rpc('eth_getLogs', [{ address: [AUCTION, MOTIFS, ONE], fromBlock: hex(a), toBlock: hex(b) }]);
  try { return await q(from, to); }
  catch (e) { // a node that refuses the span: smaller pieces
    const out = [];
    for (let a = from; a <= to; a += 100) out.push(...(await q(a, Math.min(a + 99, to))));
    return out;
  }
}
async function allEvents(toBlock) {
  return withLock('__logs', async () => {
    if (toBlock > logCache.to || toBlock > logCache.to - 64) {
      const start = Math.max(DEPLOY_BLOCK, Math.min(logCache.to + 1, toBlock - 64));
      for (let from = start; from <= toBlock; from += 2000) {
        const to = Math.min(from + 1999, toBlock);
        for (const l of await getLogs(from, to)) logCache.logs[`${l.transactionHash}:${Number(l.logIndex)}`] = l;
      }
      if (toBlock > logCache.to) logCache.to = toBlock;
      writeFileSync(LOGCACHE, JSON.stringify(logCache));
    }
    return decodeLogs(Object.values(logCache.logs).filter((l) => Number(l.blockNumber) <= toBlock))
      .sort((a, b) => a.block - b.block || a.index - b.index);
  });
}
const tsCache = new Map();
async function blockTime(n) {
  if (!tsCache.has(n)) tsCache.set(n, Number((await rpc('eth_getBlockByNumber', [hex(n), false])).timestamp));
  return tsCache.get(n);
}

// ---------------------------------------------------------------- the site's adapter, per robot
const siteCtx = loadSite([...CORE, 'chain.js'], { KILIM_CHAINS: { [CHAIN_ID]: SITE_CFG }, KILIM_DEFAULT_CHAIN: CHAIN_ID, KILIM_NO_AUTO: true });
function walletProvider(wallet) {
  const addr = wallet.address.toLowerCase();
  return {
    async request({ method, params = [] }) {
      switch (method) {
        case 'eth_requestAccounts': case 'eth_accounts': return [addr];
        case 'eth_chainId': return CHAIN_HEX;
        case 'net_version': return String(CHAIN_ID);
        case 'wallet_switchEthereumChain':
          if (params[0] && Number(params[0].chainId) === CHAIN_ID) return null;
          throw Object.assign(new Error('the swarm wallet is Sepolia only'), { code: 4902 });
        case 'eth_sendTransaction': {
          const tx = params[0];
          if (tx.chainId !== undefined && Number(tx.chainId) !== CHAIN_ID) throw Object.assign(new Error('wrong chain'), { code: -32602 });
          if (tx.from && tx.from.toLowerCase() !== addr) throw Object.assign(new Error('wrong account'), { code: 4100 });
          return sendRaw(wallet, { to: tx.to, value: tx.value ? BigInt(tx.value) : 0n, data: tx.data, gas: tx.gas }, 'site: ' + (tx.data || '').slice(0, 10));
        }
        case 'eth_signTypedData_v4': {
          const t = typeof params[1] === 'string' ? JSON.parse(params[1]) : params[1];
          const types = { ...t.types }; delete types.EIP712Domain;
          return wallet.signTypedData(t.domain, types, t.message);
        }
        case 'personal_sign': return wallet.signMessage(ethers.getBytes(params[0]));
        default: return rpc(method, params);
      }
    },
    on() {}, removeListener() {},
  };
}
async function siteChain(wallet) {
  const chain = siteCtx.KILIM_CHAIN.create({ chainId: CHAIN_ID, provider: walletProvider(wallet), poll: false, lockMotifIds: true });
  await chain.ready;
  for (let i = 0; i < 50 && chain.connected() !== wallet.address.toLowerCase(); i++) await sleep(200);
  if (chain.connected() !== wallet.address.toLowerCase()) throw new Error('the site adapter did not attach ' + wallet.address);
  return chain;
}
async function siteWrite(label, promise) {
  const r = await promise;
  const hash = r && (r.tx || (r.receipts && r.receipts[0] && r.receipts[0].transactionHash));
  if (hash) { const rc = await receipt(hash, label); if (rc.status !== '0x1') throw new Error(`${label} reverted (${hash})`); }
  return r;
}

// ---------------------------------------------------------------- refusals (simulated, nothing sent)
async function expectRevert(what, { from, to = AUCTION, data, value = 0n }, errName) {
  try {
    await rpc('eth_call', [{ from, to, data, value: hex(value) }, 'latest', { [from]: { balance: hex(10n * ETH) } }]);
    fail(what, `did not revert (expected ${errName})`);
  } catch (e) {
    let name = null;
    try { if (e.data) name = (iA.parseError(e.data) || iM.parseError(e.data) || iO.parseError(e.data))?.name; } catch {}
    if (!name && e.data) { try { name = iM.parseError(e.data)?.name || iO.parseError(e.data)?.name; } catch {} }
    if (!errName || name === errName) pass(what, `reverts with ${name || e.message}`);
    else fail(what, `reverts with ${name || e.message}, expected ${errName}`);
  }
}
const enc = (fn, args = []) => iA.encodeFunctionData(fn, args);
async function refusalsBefore(pool) {
  if (state.done.refusalsBefore) return;
  const treasury = await A('treasury');
  const poor = robot(9001).address;                 // never funded
  await expectRevert('register from the treasury', { from: treasury, data: enc('register') }, 'TreasuryCannotBid');
  await rpc('eth_call', [{ from: poor, to: AUCTION, data: enc('register') }, 'latest'])
    .then(() => fail('register with no balance', 'did not revert'))
    .catch((e) => { let n; try { n = iA.parseError(e.data)?.name; } catch {} n === 'InsufficientRegistrationBalance' ? pass('register with no balance', n) : fail('register with no balance', n || e.message); });
  await expectRevert('bid before 100 check-ins', { from: poor, data: enc('bid', [10n * MILLI, 10n, 0n]), value: 10n * MILLI }, 'RegistrationIncomplete');
  const w = robot(9002);
  const deadline = BigInt(Math.floor(Date.now() / 1000) - 60);
  const domain = { name: 'Kilim Registration', version: '1', chainId: CHAIN_ID, verifyingContract: AUCTION };
  const types = { Register: [{ name: 'wallet', type: 'address' }, { name: 'deadline', type: 'uint256' }] };
  const expired = await w.signTypedData(domain, types, { wallet: w.address, deadline });
  await expectRevert('registerFor with an expired deadline', { from: pool.address, data: enc('registerFor', [w.address, deadline, expired]) }, 'RegistrationSignatureExpired');
  const later = BigInt(Math.floor(Date.now() / 1000) + 900);
  const wrongSigner = await robot(9003).signTypedData(domain, types, { wallet: w.address, deadline: later });
  await expectRevert('registerFor signed by another key', { from: pool.address, data: enc('registerFor', [w.address, later, wrongSigner]) }, 'InvalidRegistrationSignature');
  const otherDomain = await w.signTypedData({ ...domain, chainId: 1 }, types, { wallet: w.address, deadline: later });
  await expectRevert('registerFor signed for Ethereum mainnet', { from: pool.address, data: enc('registerFor', [w.address, later, otherDomain]) }, 'InvalidRegistrationSignature');
  await expectRevert('payOutbidRefund from outside', { from: poor, data: enc('payOutbidRefund', [poor, 1n]) }, 'Unauthorized');
  await expectRevert('deliverPrize from outside', { from: poor, data: enc('deliverPrize') }, 'Unauthorized');
  await expectRevert('settle with no bids', { from: poor, data: enc('settle') }, 'NoBids');
  await expectRevert('withdrawProceeds by a stranger', { from: poor, data: enc('withdrawProceeds', [poor]) }, 'Unauthorized');
  await expectRevert('withdrawRefund with nothing owed', { from: poor, data: enc('withdrawRefund', [poor]) }, 'NothingToWithdraw');
  await expectRevert('plain ETH sent to the auction', { from: poor, data: '0x', value: 1n }, null);
  state.done.refusalsBefore = stamp(); saveState();
  log('refusals before registration: simulated');
}

// ---------------------------------------------------------------- phase 2: 100 check-ins
async function relay(pool, ids, index) {
  for (let k = 0; k < ids.length; k++) {
    const w = robot(ids[k]);
    const count = Number(await A('registrationCount'));
    if (count >= 100) { log(`relay ${index}: registration is full`); await transferAll(w, pool.address, 'return to pool'); return; }
    if (!(await A('registered', [w.address]))) {
      if ((await balanceOf(w.address, 'pending')) < 10n * MILLI + 50_000_000_000_000n) await topUp(pool, w.address, HOLD, k === 0 ? 'fund relay head' : 'top up a relay robot');
      const held = await eventually(() => balanceOf(w.address), (b) => b >= 10n * MILLI);
      if (held < 10n * MILLI) { stepError(`relay ${index} robot ${ids[k]} balance`, fmt(held)); return; }
      if (ids[k] % 10 === 0) {
        // The sponsor's path: the wallet signs the check-in typed data exactly as the page asks it to,
        // and another wallet pays the gas of registerFor.
        const deadline = String(Math.floor(Date.now() / 1000) + 900);
        const typed = { domain: { name: 'Kilim Registration', version: '1', chainId: CHAIN_ID, verifyingContract: AUCTION.toLowerCase() },
          primaryType: 'Register',
          types: { EIP712Domain: [{ name: 'name', type: 'string' }, { name: 'version', type: 'string' }, { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }],
            Register: [{ name: 'wallet', type: 'address' }, { name: 'deadline', type: 'uint256' }] },
          message: { wallet: w.address.toLowerCase(), deadline } };
        const sig = await walletProvider(w).request({ method: 'eth_signTypedData_v4', params: [w.address, JSON.stringify(typed)] });
        await sendAndWait(pool, { to: AUCTION, data: enc('registerFor', [w.address, BigInt(deadline), sig]) }, 'registerFor (sponsored)');
      } else {
        const chain = await siteChain(w);
        await siteWrite('register (site)', chain.register());
      }
      const now = Number(await A('registrationCount'));
      if (!(await eventually(() => A('registered', [w.address]), (r) => r))) fail(`robot ${ids[k]} registered`, 'not registered after its check-in');
      if (now % 10 === 0) log(`check-ins: ${now} of 100`);
      await invariants(`check-in ${now}`);
    }
    const next = k + 1 < ids.length ? robot(ids[k + 1]).address : pool.address;
    await transferAll(w, next, next === pool.address ? 'return to pool' : 'relay the 0.01 on');
  }
}
async function registration(pool) {
  if (Number(await A('registrationCount')) >= 100) return;
  await refusalsBefore(pool);
  const per = Math.ceil(ROBOTS / RELAYS);
  const relays = Array.from({ length: RELAYS }, (_, r) => Array.from({ length: Math.min(per, ROBOTS - r * per) }, (_, k) => 1 + r * per + k));
  log(`check-ins: ${RELAYS} relays of ${per}`);
  await Promise.all(relays.map((ids, r) => relay(pool, ids, r + 1).catch((e) => stepError(`relay ${r + 1}`, e.message))));
  const count = Number(await A('registrationCount'));
  if (count === 100) {
    log('check-ins: 100 of 100; bidding is open');
    await expectRevert('register after 100', { from: robot(9004).address, data: enc('register') }, 'RegistrationClosed');
    await expectRevert('register twice', { from: robot(1).address, data: enc('register') }, 'RegistrationClosed');
  }
}

// ---------------------------------------------------------------- phase 3: bidding
// The bids, in order. `nth` is that bidder's count of BidPlaced once the step has landed: a restart
// finds a step already on chain and marks it done instead of bidding twice.
const STEPS = [
  { step: 'open', who: 'B1', nth: 1, required: true },
  { step: 'b2-1', who: 'B2', nth: 1, required: true },   // B1's 0.01 pushed back (RefundPaid)
  { step: 'cw-1', who: 'CW', nth: 1, required: true },   // the contract wallet bids
  { step: 'b1-2', who: 'B1', nth: 2, required: true },   // CW's refund deferred (RefundDeferred)
  { step: 'b2-mid', who: 'B2', nth: 2, required: false }, // half time: the close must not move
  { step: 'late-1', who: 'B1', nth: 3, required: true },  // inside the last 10 minutes: the close moves
  { step: 'late-2', who: 'B2', nth: 3, required: true },  // inside the new last 10 minutes: moves again
];
const KEEP = 300_000_000_000_000n;        // 0.0003 ETH a robot keeps for gas
// What a bidder must hold beyond its bid: the site refuses to send a bid unless the wallet holds the bid
// and gas x fee at today's fees (chain.js plan(): 1.5M gas x (2 x base fee + tip)). Read as the site reads
// it, plus a fifth and 0.0001 ETH. About 0.0001 ETH on Sepolia, where the tip is 0.001 gwei.
async function siteReserve(gas = 1_500_000n) {
  const [p, blk] = await Promise.all([rpc('eth_gasPrice'), rpc('eth_getBlockByNumber', ['latest', false])]);
  const price = BigInt(p), base = BigInt(blk.baseFeePerGas);
  return gas * (2n * base + (price > base ? price - base : 10n ** 9n)) * 6n / 5n + 100_000_000_000_000n;
}
function addressOf(name) { return name === 'CW' ? state.cw : robot(BIDDERS[name]).address; }
const ours = () => [robot(BIDDERS.B1).address, robot(BIDDERS.B2).address, robot(BIDDERS.B3).address, state.cw].filter(Boolean).map((a) => a.toLowerCase());
async function bidsBy(name) {
  const a = addressOf(name); if (!a) return 0;
  return (await allEvents(Number(await rpc('eth_blockNumber')) - 1)).filter((e) => e.name === 'BidPlaced' && e.args.bidder.toLowerCase() === a.toLowerCase()).length;
}
function nextBid(h) {
  if (h === 0n) return 10n * MILLI;
  const inc = (h * 1000n + 9999n) / 10000n;               // 10 %, rounded up
  return ((h + inc + MILLI - 1n) / MILLI) * MILLI;        // to a whole 0.001
}
// What the swarm can spend now (the pool, the robots, a deferred refund still to withdraw), and its own
// bid locked in the auction if it leads (that comes back to the swarm when it is outbid).
async function funds(pool) {
  let spendable = await balanceOf(pool.address);
  for (const i of Object.values(BIDDERS)) spendable += await balanceOf(robot(i).address);
  if (state.cw) spendable += await A('refunds', [state.cw]);
  const leader = (await A('highestBidder')).toLowerCase();
  const high = await A('highestBid');
  return { spendable, locked: ours().includes(leader) ? high : 0n, high, total: spendable + (ours().includes(leader) ? high : 0n) };
}
// Can the swarm still place `count` bids in a row at the minimum, from the current highest bid? Each bid
// needs its amount up front; the outbid bid, if it is ours, comes back in the same transaction.
async function affordable(pool, count) {
  const { spendable, locked, high, total } = await funds(pool);
  const RESERVE = await siteReserve();
  let h = high, lock = locked, free = spendable, need = 0n;
  for (let i = 0; i < count; i++) {
    const a = nextBid(h), want = a + RESERVE + 2n * KEEP;
    if (free < want) return { ok: false, at: i, need: total - free + want, total };
    if (total - free + want > need) need = total - free + want;
    free = free - a + lock; h = a; lock = a;
  }
  return { ok: true, need, total };
}
async function ensureCW(pool) {
  if (state.cw && (await rpc('eth_getCode', [state.cw, 'latest'])) !== '0x') return state.cw;
  const owner = robot(BIDDERS.B3);
  await topUp(pool, owner.address, MILLI, 'fund B3 for the contract wallet');
  const r = await sendAndWait(owner, { to: null, data: CW_ART.bytecode.object }, 'deploy SwarmBidder');
  state.cw = ethers.getAddress(r.contractAddress); saveState();
  log(`contract wallet SwarmBidder at ${state.cw} (owner B3 ${owner.address})`);
  return state.cw;
}
async function refusalsDuringBidding(pool) {
  if (state.done.refusalsDuring) return;
  const b = robot(BIDDERS.B3).address, treasury = await A('treasury');
  const min = await A('minimumBid'), allocated = await A('motifsAllocated'), reward = await A('rewardForBid', [min]);
  await expectRevert('bid below the minimum', { from: b, data: enc('bid', [min - MILLI, 0n, 0n]), value: min - MILLI }, 'BidTooLow');
  await expectRevert('bid not a whole 0.001', { from: b, data: enc('bid', [min + MILLI / 2n, 0n, 0n]), value: min + MILLI / 2n }, 'NonWholeUnitBid');
  await expectRevert('bid with the wrong value', { from: b, data: enc('bid', [min, 0n, 0n]), value: min - 1n }, 'IncorrectPayment');
  await expectRevert('bid with a stale motif range', { from: b, data: enc('bid', [min, reward, allocated + 2n]), value: min }, 'MotifRangeMoved');
  await expectRevert('bid demanding too many motifs', { from: b, data: enc('bid', [min, reward + 1n, 0n]), value: min }, 'RewardSlippage');
  await expectRevert('bid from the treasury', { from: treasury, data: enc('bid', [min, 0n, 0n]), value: min }, 'TreasuryCannotBid');
  await expectRevertGas('outbid with 400,000 gas', { from: b, data: enc('bid', [min, 0n, 0n]), value: min }, 400_000n, 'InsufficientGas');
  await expectRevert('settle before the close', { from: b, data: enc('settle') }, 'AuctionNotEnded');
  await expectRevert('claimPrize before settlement', { from: b, data: enc('claimPrize', [b]) }, 'NotSettled');
  await expectRevert('withdrawProceeds before settlement', { from: treasury, data: enc('withdrawProceeds', [treasury]) }, 'NotSettled');
  await expectRevert('claim 0 motifs', { from: b, data: enc('claimMotifs', [0n, b]) }, 'InvalidQuantity');
  state.done.refusalsDuring = stamp(); saveState();
  log('refusals while bidding: simulated');
}
// A call with a fixed gas limit, simulated (the low-gas refusals: InsufficientGas).
async function expectRevertGas(what, { from, to = AUCTION, data, value = 0n }, gas, errName) {
  try {
    await rpc('eth_call', [{ from, to, data, value: hex(value), gas: hex(gas) }, 'latest', { [from]: { balance: hex(10n * ETH) } }]);
    fail(what, `did not revert (expected ${errName})`);
  } catch (e) {
    let name = null; try { name = iA.parseError(e.data)?.name; } catch {}
    if (name === errName) pass(what, `reverts with ${name}`);
    else if (!name && /out of gas|gas required exceeds|intrinsic gas/i.test(e.message)) pass(what, `refused: out of gas before the ${errName} check (${e.message})`);
    else fail(what, `reverts with ${name || e.message}, expected ${errName}`);
  }
}
// Before a bid, the other robots' spare ETH goes back to the pool, so the pool can fund the bid.
async function consolidate(pool, except) {
  for (const [name, i] of Object.entries(BIDDERS)) {
    if (name === except || (except === 'CW' && name === 'B3')) continue;
    const w = robot(i), bal = await balanceOf(w.address, 'pending');
    if (bal > KEEP + 200_000_000_000_000n) await transferAll(w, pool.address, 'consolidate to pool').catch((e) => log(`consolidate ${name}: ${e.message}`));
  }
}
async function placeBid(pool, { step, who, required }) {
  await consolidate(pool, who);
  const min = await A('minimumBid');
  const minEth = ethers.formatEther(min);
  const { spendable } = await funds(pool);
  const RESERVE = await siteReserve();
  if (spendable < min + RESERVE + KEEP) {
    const msg = `the minimum ${minEth} ETH is more than the swarm can spend (${fmt(spendable)})`;
    required ? fail(`${step} skipped`, msg) : log(`skip ${step}: ${msg}`);
    state.notes.push(`${step} skipped: ${msg}`); state.done[step] = 'skipped ' + stamp(); saveState();
    return 'skipped';
  }
  const before = await A('endsAt');
  if (who === 'CW') {
    const owner = robot(BIDDERS.B3);
    await topUp(pool, owner.address, min + RESERVE, `fund B3 for ${step}`);
    const reward = await A('rewardForBid', [min]), expected = reward > 0n ? 1n + (await A('motifsAllocated')) : 0n;
    const data = iCW.encodeFunctionData('exec', [AUCTION, enc('bid', [min, reward, expected])]);
    await sendAndWait(owner, { to: state.cw, data, value: min, gas: 1_800_000n }, 'bid (contract wallet)');
    log(`${step}: the contract wallet bid ${minEth} ETH`);
  } else {
    const w = robot(BIDDERS[who]);
    await topUp(pool, w.address, min + RESERVE, `fund ${who} for ${step}`);
    const chain = await siteChain(w);
    const q = await chain.quote(minEth);
    if (q.amount !== min) throw new Error(`site quote ${q.amount} != minimumBid ${min}`);
    const r = await siteWrite(`bid (site, ${q.opening ? 'opening' : 'outbid'})`, chain.bid(q));
    log(`${step}: ${who} bid ${minEth} ETH through the site, motifs #${r.firstId}-#${r.lastId}, close ${new Date(r.endsAt * 1000).toISOString()}`);
  }
  const after = await A('endsAt');
  state.closes ??= {}; state.closes[step] = { before: String(before), after: String(after) };
  state.done[step] = stamp(); saveState();
  await invariants(step);
  return 'done';
}
async function withdrawCwRefund(pool) {
  const owed = await A('refunds', [state.cw]);
  if (owed === 0n) {
    const ev = (await allEvents(Number(await rpc('eth_blockNumber')) - 1)).find((e) => e.name === 'RefundWithdrawn' && e.args.bidder.toLowerCase() === state.cw.toLowerCase());
    if (ev) { state.done['cw-withdraw'] = stamp(); saveState(); }
    return !!ev;
  }
  const owner = robot(BIDDERS.B3);
  await topUp(pool, owner.address, MILLI / 2n, 'fund B3 to withdraw for the contract wallet');
  await sendAndWait(owner, { to: state.cw, data: iCW.encodeFunctionData('exec', [AUCTION, enc('withdrawRefund', [pool.address])]) }, 'withdrawRefund (contract wallet)');
  state.done['cw-withdraw'] = stamp(); saveState();
  log(`the contract wallet's deferred refund of ${fmt(owed)} ETH withdrawn to the pool`);
  await invariants('withdraw the deferred refund');
  return true;
}

// ---------------------------------------------------------------- phase 4: settle and claims
async function settleAndClaim(pool) {
  const b3 = robot(BIDDERS.B3);
  if (!(await A('settled'))) {
    const min = await A('minimumBid');
    await expectRevert('bid after the close', { from: b3.address, data: enc('bid', [min, 0n, 0n]), value: min }, 'AuctionNotOpen');
    await expectRevertGas('settle with 500,000 gas', { from: b3.address, data: enc('settle') }, 500_000n, 'InsufficientGas');
    await topUp(pool, b3.address, MILLI, 'fund B3 to settle');
    const chain = await siteChain(b3);           // B3 is not the treasury: anyone may settle
    const r = await siteWrite('settle (site)', chain.settle());
    const rc = await rpc('eth_getTransactionReceipt', [r.tx]);
    const names = decodeLogs(rc.logs).map((e) => e.name);
    log(`settled by B3 (not the treasury): ${names.join(', ')}`);
    if (names.includes('PrizeDeliveryFailed')) state.notes.push('PrizeDeliveryFailed at settlement: the winner must claimPrize');
    state.done.settle = stamp(); saveState();
    await invariants('settle');
  }
  const winner = await A('highestBidder');
  if (!(await A('prizeClaimed'))) {
    const mine = Object.entries(BIDDERS).find(([, i]) => robot(i).address.toLowerCase() === winner.toLowerCase());
    if (mine) { const c = await siteChain(robot(mine[1])); await topUp(pool, robot(mine[1]).address, MILLI, 'fund the winner to claim the 1/1'); await siteWrite('claimPrize (site)', c.claimPrize(winner)); }
    else log(`the winner ${winner} is not a robot: they claim the 1/1 themselves`);
  }
  if ((await A('prizeClaimed')) && !state.done.prizeChecked) {
    const owner = (await view(iO, ONE, 'ownerOf', [1n]))[0];
    const uri = (await view(iO, ONE, 'tokenURI', [1n]))[0];
    const golden = JSON.parse(readFileSync(resolve(here, '../deploy/sepolia.json'), 'utf8')).expected.oneOfOneGolden;
    const sha = '0x' + createHash('sha256').update(Buffer.from(uri, 'utf8')).digest('hex');
    (sha === golden ? pass : fail)('the real 1/1 tokenURI equals expected.oneOfOneGolden', `${uri.length} bytes, sha256 ${sha}, owner ${owner}`);
    await expectRevert('settle twice', { from: b3.address, data: enc('settle') }, 'AlreadySettled');
    const stranger = b3.address.toLowerCase() === winner.toLowerCase() ? robot(BIDDERS.B1).address : b3.address;
    await expectRevert('claimPrize by someone else', { from: stranger, data: enc('claimPrize', [stranger]) }, 'Unauthorized');
    state.done.prizeChecked = stamp(); saveState();
  }
  // Every robot bidder claims all its motifs through the site. B1's first batch goes to B3: a claim
  // to another address.
  for (const [name, i] of Object.entries(BIDDERS)) {
    const w = robot(i);
    if ((await A('motifCredits', [w.address])) === 0n) continue;
    await topUp(pool, w.address, 2n * MILLI, `fund ${name} to claim`);
    await expectRevert(`claim 65 motifs (${name})`, { from: w.address, data: enc('claimMotifs', [65n, w.address]) }, 'InvalidQuantity');
    await expectRevert(`claim into the motif contract (${name})`, { from: w.address, data: enc('claimMotifs', [1n, MOTIFS]) }, 'InvalidRecipient');
    const chain = await siteChain(w);
    if (name === 'B1' && !state.done.claimToOther) {
      const r = await siteWrite('claimMotifs (site, to another address)', chain.claim({ to: b3.address }));
      log(`B1 claimed ${r.count} motifs to B3`); state.done.claimToOther = stamp(); saveState();
    }
    if ((await A('motifCredits', [w.address])) > 0n) {
      const r = await chain.claimAll({});
      log(`${name} claimed ${r.count} motifs through the site`);
    }
    await invariants(`claims ${name}`);
  }
  if (state.cw) {
    let credits = await A('motifCredits', [state.cw]);
    while (credits > 0n) {
      const qty = credits > 64n ? 64n : credits;
      await topUp(pool, b3.address, 2n * MILLI, 'fund B3 to claim for the contract wallet');
      await sendAndWait(b3, { to: state.cw, data: iCW.encodeFunctionData('exec', [AUCTION, enc('claimMotifs', [qty, state.cw])]) }, 'claimMotifs (contract wallet, to itself)');
      credits = await A('motifCredits', [state.cw]);
    }
    await invariants('claims CW');
  }
  await holderActions(pool);
  // The treasury's withdrawal is the artist's: simulate it only.
  const treasury = await A('treasury');
  try {
    await rpc('eth_call', [{ from: treasury, to: AUCTION, data: enc('withdrawProceeds', [treasury]) }, 'latest']);
    pass('withdrawProceeds by the treasury (simulated)', fmt(await A('proceedsDue')) + ' ETH due');
  } catch (e) { fail('withdrawProceeds by the treasury (simulated)', e.message); }
  state.done.claims = stamp(); saveState();
}
// What a holder does next: transfer a motif, burn one, and an approved operator's burn is refused.
async function holderActions(pool) {
  if (state.done.holder) return;
  const b2 = robot(BIDDERS.B2), b3 = robot(BIDDERS.B3);
  const held = (await allEvents(Number(await rpc('eth_blockNumber')) - 1)).filter((e) => e.name === 'Transfer' && e.address === MOTIFS.toLowerCase() && e.args.to.toLowerCase() === b3.address.toLowerCase()).map((e) => e.args.tokenId);
  if (held.length < 2) { log('holder actions: B3 holds fewer than two motifs, skipped'); return; }
  const [a, b] = held;
  await topUp(pool, b3.address, MILLI, 'fund B3 for the holder actions');
  await sendAndWait(b3, { to: MOTIFS, data: iM.encodeFunctionData('transferFrom', [b3.address, b2.address, a]) }, 'motif transferFrom');
  ((await view(iM, MOTIFS, 'ownerOf', [a]))[0].toLowerCase() === b2.address.toLowerCase() ? pass : fail)('a transferred motif belongs to its new owner', `#${a}`);
  await sendAndWait(b3, { to: MOTIFS, data: iM.encodeFunctionData('approve', [b2.address, b]) }, 'motif approve');
  await expectRevertM('an approved operator cannot burn', { from: b2.address, data: iM.encodeFunctionData('burn', [b]) }, 'Unauthorized');
  await topUp(pool, b2.address, MILLI, 'fund B2 to burn');
  await sendAndWait(b2, { to: MOTIFS, data: iM.encodeFunctionData('burn', [a]) }, 'motif burn by its owner');
  ((await view(iM, MOTIFS, 'burned', [a]))[0] ? pass : fail)('a burned motif is marked burned', `#${a}`);
  state.done.holder = stamp(); saveState();
}
async function expectRevertM(what, { from, data }, errName) {
  try { await rpc('eth_call', [{ from, to: MOTIFS, data }, 'latest']); fail(what, 'did not revert'); }
  catch (e) { let n = null; try { n = iM.parseError(e.data)?.name; } catch {} n === errName ? pass(what, n) : fail(what, `${n || e.message}, expected ${errName}`); }
}

// ---------------------------------------------------------------- invariants
const observer = { chain: null };
async function invariants(when) {
  const block = Number(await rpc('eth_blockNumber')) - 2;   // two behind the head: every backend has it
  const tag = hex(block);
  const ev = await allEvents(block);
  const by = (n, addr = AUCTION) => ev.filter((e) => e.name === n && e.address === addr.toLowerCase());
  const [bal, liab, count, allocated, claimed, highestBid, highestBidder, endsAt, settled, proceedsDue, refundLiability, hbm, duration, window] = await Promise.all([
    balanceOf(AUCTION, tag), A('liabilities', [], tag), A('registrationCount', [], tag), A('motifsAllocated', [], tag), A('motifsClaimed', [], tag),
    A('highestBid', [], tag), A('highestBidder', [], tag), A('endsAt', [], tag), A('settled', [], tag), A('proceedsDue', [], tag), A('refundLiability', [], tag),
    view(iA, AUCTION, 'highestBidMotifs', [], tag), A('duration', [], tag), A('extensionWindow', [], tag)]);
  const [minted, burnedCount] = await Promise.all([view(iM, MOTIFS, 'motifsMinted', [], tag).then((r) => r[0]), view(iM, MOTIFS, 'motifsBurned', [], tag).then((r) => r[0])]);
  const problems = [];
  const eq = (what, a, b) => { if (String(a).toLowerCase() !== String(b).toLowerCase()) problems.push(`${what}: ${a} != ${b}`); };
  eq('auction balance = liabilities()', bal, liab);
  eq('registrationCount = Registered events', count, by('Registered').length);
  const bids = by('BidPlaced');
  eq('motifsAllocated = sum of BidPlaced rewards', allocated, bids.reduce((s, e) => s + e.args.motifReward, 0n));
  eq('motifsClaimed = sum of MotifsClaimed', claimed, by('MotifsClaimed').reduce((s, e) => s + e.args.count, 0n));
  eq('motifsMinted = motifsClaimed', minted, claimed);
  eq('motifsBurned = Transfer to zero', burnedCount, ev.filter((e) => e.name === 'Transfer' && e.address === MOTIFS.toLowerCase() && e.args.to === ethers.ZeroAddress).length);
  eq('refundLiability = deferred - withdrawn', refundLiability, by('RefundDeferred').reduce((s, e) => s + e.args.amount, 0n) - by('RefundWithdrawn').reduce((s, e) => s + e.args.amount, 0n));
  if (bids.length) {
    const last = bids[bids.length - 1];
    eq('highestBid = last BidPlaced', highestBid, last.args.amount);
    eq('highestBidder = last BidPlaced', highestBidder, last.args.bidder);
    eq('endsAt = last BidPlaced endsAt', endsAt, last.args.endsAt);
    eq('highestBidMotifs = last BidPlaced range', `${hbm[0]},${hbm[1]}`, `${last.args.firstMotifId},${last.args.motifReward}`);
    if (by('AuctionStarted').length !== 1) problems.push(`AuctionStarted events: ${by('AuctionStarted').length}`);
    // The clock: the first bid opens a full duration; each later bid lands before the close and moves it
    // to max(close, its time + window).
    let close = 0n;
    for (let i = 0; i < bids.length; i++) {
      const ts = BigInt(await blockTime(bids[i].block));
      const want = i === 0 ? ts + duration : (ts + window > close ? ts + window : close);
      if (i > 0 && ts >= close) problems.push(`bid ${i + 1} landed at ${ts}, at or after the close ${close}`);
      eq(`bid ${i + 1} endsAt`, bids[i].args.endsAt, want);
      close = bids[i].args.endsAt;
      if (i > 0) {
        const prev = bids[i - 1];
        const back = ev.find((e) => e.tx === bids[i].tx && (e.name === 'RefundPaid' || e.name === 'RefundDeferred'));
        if (!back) problems.push(`bid ${i + 1} (${bids[i].tx}) has no refund event`);
        else { eq(`bid ${i + 1} refunds the outbid bidder`, back.args.bidder, prev.args.bidder); eq(`bid ${i + 1} refunds the outbid amount`, back.args.amount, prev.args.amount); }
      }
    }
    const settledEv = by('AuctionSettled')[0];
    if (settledEv && BigInt(await blockTime(settledEv.block)) < endsAt) problems.push('settled before the close');
  }
  if (settled) {
    const withdrawn = by('ProceedsWithdrawn').reduce((s, e) => s + e.args.amount, 0n);
    eq('proceedsDue + withdrawn = winning bid', proceedsDue + withdrawn, highestBid);
  }
  // The site's snapshot equals the contracts at the block the site read.
  try {
    observer.chain ??= await siteChain(robot(9999));
    await observer.chain.refresh();
    const sb = observer.chain.status().block, st = hex(sb);
    const s = observer.chain.auction();
    const [c2, hb, hbr, ea, mn, ma, mc, se] = await Promise.all(['registrationCount', 'highestBid', 'highestBidder', 'endsAt', 'minimumBid', 'motifsAllocated', 'motifsClaimed', 'settled'].map((f) => A(f, [], st)));
    eq('site registrationCount', s.registrationCount, c2);
    eq('site highest bid', s.highRaw, hb);
    eq('site highest bidder', s.highBidder || ethers.ZeroAddress, hbr);
    eq('site endsAt', s.endsAt, ea);
    eq('site minimum bid', s.minNextRaw, mn);
    eq('site motifs reserved', s.motifsReserved, ma);
    eq('site motifs claimed', s.motifsClaimed, mc);
    eq('site settled', s.phase === 'settled', se);
    // The bid book: the chain's BidPlaced up to the block the site read (which can be newer than ours).
    const chainBids = (await allEvents(Math.max(block, sb))).filter((e) => e.name === 'BidPlaced' && e.address === AUCTION.toLowerCase() && e.block <= sb);
    // The site reads far history in a background job (status().history, since 18d89333): compare the
    // book only once it is ready.
    const history = observer.chain.status().history;
    if (history && history !== 'ready') { /* the book is still loading: the state reads above are compared */ }
    else if (s.bids && s.bids.length !== chainBids.length) problems.push(`site bid book has ${s.bids.length} bids, the chain ${chainBids.length} at block ${sb}`);
    else if (s.bids && (!history || history === 'ready')) chainBids.forEach((e, i) => { const sbid = s.bids.find((x) => Number(x.firstId) === Number(e.args.firstMotifId) && String(x.addr).toLowerCase() === e.args.bidder.toLowerCase()); if (!sbid) problems.push(`site bid book lacks bid ${i + 1} (${e.args.bidder} from #${e.args.firstMotifId})`); });
  } catch (e) { problems.push(`site snapshot: ${e.message}`); }
  if (problems.length) fail(`invariants after ${when} (block ${block})`, problems.join('; '));
  else pass(`invariants after ${when}`, `block ${block}, balance ${fmt(bal)} ETH = liabilities, ${count} check-ins, ${bids.length} bids, ${allocated} motifs reserved, ${claimed} claimed`);
  return problems.length === 0;
}

// ---------------------------------------------------------------- the verdict
async function verdict() {
  const block = Number(await rpc('eth_blockNumber')) - 2;
  const ev = await allEvents(block);
  const by = (n) => ev.filter((e) => e.name === n && e.address === AUCTION.toLowerCase());
  const rows = existsSync(join(OUT, 'checks.jsonl')) ? readFileSync(join(OUT, 'checks.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
  const sent = existsSync(join(OUT, 'events.jsonl')) ? readFileSync(join(OUT, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
  const items = [];
  const item = (ok, what) => items.push({ ok: !!ok, what });
  const cw = (state.cw || '').toLowerCase();
  const robotsSet = new Set([...Array.from({ length: ROBOTS }, (_, k) => robot(k + 1).address.toLowerCase()), ...ours()]);
  item(rows.some((r) => r.ok && r.what === 'bid before 100 check-ins'), 'before 100 check-ins a bid reverts with RegistrationIncomplete');
  item(by('Registered').length === 100, `exactly 100 Registered (${by('Registered').length})`);
  item(sent.filter((r) => r.kind === 'receipt' && r.label === 'registerFor (sponsored)' && r.status === '0x1').length >= 10, 'at least 10 check-ins through registerFor');
  item(rows.some((r) => r.ok && r.what === 'register after 100'), 'the 101st check-in reverts with RegistrationClosed');
  const bids = by('BidPlaced'), started = by('AuctionStarted');
  item(started.length === 1 && bids.length && BigInt(bids[0].args.endsAt) === BigInt(await blockTime(bids[0].block)) + 86400n, 'one AuctionStarted, close = first bid + 86400');
  item(by('RefundPaid').length >= 1, 'at least one refund pushed back in the same transaction');
  if (state.openedBy && !ours().includes(state.openedBy.toLowerCase())) {
    const a = state.openedBy.toLowerCase();
    item(by('RefundPaid').some((e) => e.args.bidder.toLowerCase() === a), `the artist's opening bid (${state.openedBy}, through the page) came back in the outbidding transaction`);
  }
  item(by('RefundDeferred').some((e) => e.args.bidder.toLowerCase() === cw) && by('RefundWithdrawn').some((e) => e.args.bidder.toLowerCase() === cw), 'the contract wallet: refund deferred, then withdrawn');
  const c = state.closes || {};
  if (c['b2-mid']) item(c['b2-mid'].before === c['b2-mid'].after, 'the half-time bid left the close unchanged');
  item(c['late-1'] && BigInt(c['late-1'].after) > BigInt(c['late-1'].before), 'the first late bid moved the close');
  item(c['late-2'] && BigInt(c['late-2'].after) > BigInt(c['late-2'].before), 'the second late bid moved the close again');
  const s = by('AuctionSettled')[0];
  item(s && BigInt(await blockTime(s.block)) >= BigInt(await A('endsAt')), 'settled at or after the final close');
  item(rows.some((r) => r.ok && r.what === 'the real 1/1 tokenURI equals expected.oneOfOneGolden'), 'the real 1/1 tokenURI equals the golden');
  const robotCredits = await Promise.all(ours().map((a) => A('motifCredits', [a])));
  item(robotCredits.every((x) => x === 0n), 'every robot claimed all its motifs');
  // Each robot's minted ids are exactly its BidPlaced ranges.
  let rangesOk = true;
  for (const a of ours()) {
    const want = bids.filter((e) => e.args.bidder.toLowerCase() === a).flatMap((e) => Array.from({ length: Number(e.args.motifReward) }, (_, k) => Number(e.args.firstMotifId) + k)).sort((x, y) => x - y);
    const got = ev.filter((e) => e.name === 'MotifsMinted' && e.args.bidder.toLowerCase() === a).flatMap((e) => Array.from({ length: Number(e.args.quantity) }, (_, k) => Number(e.args.firstId) + k)).sort((x, y) => x - y);
    if (JSON.stringify(want) !== JSON.stringify(got)) rangesOk = false;
  }
  item(rangesOk, "each robot's minted ids are its bids' reserved ranges");
  // motifOf: the site's port equals the contract for the robots' ids.
  const ids = ev.filter((e) => e.name === 'MotifsMinted').flatMap((e) => [Number(e.args.firstId), Number(e.args.firstId) + Number(e.args.quantity) - 1]).slice(0, 20);
  let motifOk = ids.length > 0;
  const obs = observer.chain ?? (observer.chain = await siteChain(robot(9999)));
  for (const id of ids) if (Number((await view(iM, MOTIFS, 'motifOf', [BigInt(id)]))[0]) !== Number(obs.motifOf(id))) motifOk = false;
  item(motifOk, `motifOf: the site's port equals the contract (${ids.length} ids)`);
  const checks = rows.filter((r) => r.kind !== 'step'), steps = rows.filter((r) => r.kind === 'step');
  item(checks.length > 0 && checks.every((r) => r.ok), `no failed check in checks.jsonl (${checks.filter((r) => !r.ok).length} failed of ${checks.length})`);
  if (steps.length) state.notes.push(`${steps.length} step errors were retried: read them in checks.jsonl`);
  const strangers = [...by('Registered').map((e) => e.args.wallet), ...bids.map((e) => e.args.bidder)].map((a) => a.toLowerCase()).filter((a) => !robotsSet.has(a));
  if (strangers.length) state.notes.push(`deviation: ${new Set(strangers).size} non-robot addresses registered or bid`);
  const ok = items.every((i) => i.ok);
  const text = [`VERDICT ${ok ? 'PASS' : 'FAIL'} at block ${block}`, ...items.map((i) => `  ${i.ok ? 'pass' : 'FAIL'}  ${i.what}`),
    ...(strangers.length ? [`  note  ${new Set(strangers).size} non-robot addresses took part (listed as a deviation)`] : []),
    ...(steps.length ? [`  note  ${steps.length} step errors were retried (checks.jsonl, kind "step"): each needs a reason`] : [])].join('\n');
  writeFileSync(join(OUT, 'verdict.txt'), text + '\n');
  console.log(text);
  return ok;
}

// ---------------------------------------------------------------- the loop
async function snapshot() {
  const [count, highestBid, endsAt, settled, prizeClaimed] = await Promise.all([A('registrationCount'), A('highestBid'), A('endsAt'), A('settled'), A('prizeClaimed')]);
  const now = Number((await rpc('eth_getBlockByNumber', ['latest', false])).timestamp);
  return { count: Number(count), highestBid, endsAt: Number(endsAt), settled, prizeClaimed, now, started: Number(endsAt) > 0 };
}
function takeLock() {
  const p = join(OUT, 'run.lock');
  if (existsSync(p)) {
    const pid = Number(readFileSync(p, 'utf8'));
    try { process.kill(pid, 0); throw new Error(`another run is going (pid ${pid}); stop it first`); } catch (e) { if (e.code !== 'ESRCH') throw e; }
  }
  writeFileSync(p, String(process.pid));
  process.on('exit', () => { try { if (Number(readFileSync(p, 'utf8')) === process.pid) writeFileSync(p, ''); } catch {} });
}
async function run() {
  const id = await rpc('eth_chainId');
  if (Number(id) !== CHAIN_ID) throw new Error(`the RPC answers for chain ${Number(id)}, not Sepolia`);
  takeLock();
  saveState();
  const pool = await poolWallet();
  const treasury = (await A('treasury')).toLowerCase();
  if ([treasury, '0xd6647eeec0c8d810c546f2ab8e025d4664d833ac'].includes(pool.address.toLowerCase())) throw new Error('the pool must not be the treasury or orkhanart.eth');
  log(`swarm: pool ${pool.address} holds ${fmt(await balanceOf(pool.address))} ETH; auction ${AUCTION}`);
  for (;;) { try { await invariants('start'); break; } catch (e) { log(`start check: ${e.message}`); await sleep(20000); } }
  let lastCheck = Date.now();
  for (;;) {
    let s;
    try { s = await snapshot(); } catch (e) { log(`snapshot: ${e.message}`); await sleep(20000); continue; }
    try {
      if (s.count < 100) { await registration(pool); continue; }
      if (!s.started) {
        state.fullAt ??= s.now; saveState();
        if (s.now < state.fullAt + WAIT_OPEN) {
          if (!state.notedWait) { log(`waiting for the artist's opening bid until ${new Date((state.fullAt + WAIT_OPEN) * 1000).toISOString()}; after that the swarm opens`); state.notedWait = true; saveState(); }
          await sleep(15000); continue;
        }
        // Never start the 24-hour clock without the ETH to finish the required bids.
        const required = STEPS.filter((x) => x.required).length;
        const a = await affordable(pool, required);
        if (!a.ok) { log(`waiting for test ETH: the ${required} required bids need about ${fmt(a.need)} ETH, the swarm holds ${fmt(a.total)}. Send Sepolia ETH to the pool ${pool.address}.`); await sleep(120000); continue; }
        await ensureCW(pool);
        if ((await bidsBy('B1')) === 0) await placeBid(pool, STEPS[0]);
        continue;
      }
      state.startedAt ??= await startedAt();
      if (!state.openedBy) {
        const first = (await allEvents(Number(await rpc('eth_blockNumber')) - 1)).find((e) => e.name === 'BidPlaced');
        if (first) {
          state.openedBy = first.args.bidder;
          if (!ours().includes(first.args.bidder.toLowerCase())) { state.done.open = 'opened by ' + first.args.bidder; log(`the auction was opened by ${first.args.bidder} (not a robot): ${fmt(first.args.amount)} ETH`); }
        }
      }
      saveState();
      const since = s.now - state.startedAt;
      const left = s.endsAt - s.now;
      if (!s.settled && left > 0) {
        if (!state.done.refusalsDuring) await refusalsDuringBidding(pool);
        // A step already on chain (a restart) is marked done, never sent twice.
        const external = state.openedBy && !ours().includes(state.openedBy.toLowerCase());
        for (const st of STEPS) {
          const nth = st.nth - (external && st.who === 'B1' ? 1 : 0);
          if (!state.done[st.step] && nth > 0 && addressOf(st.who) && (await bidsBy(st.who)) >= nth) { state.done[st.step] = 'found on chain ' + stamp(); saveState(); }
        }
        const early = left > LATE_FIRST + 60;
        const lateLeft = STEPS.filter((x) => x.step.startsWith('late') && !state.done[x.step]).length;
        // An opening bid from the artist leads for ten minutes before a robot outbids it.
        if (!state.done['b2-1'] && since >= (external ? 600 : 120) && early) await placeBid(pool, STEPS[1]);
        else if (state.done['b2-1'] && !state.done['cw-1'] && since >= 240 && early) { await ensureCW(pool); await placeBid(pool, STEPS[2]); }
        else if (state.done['cw-1'] && !state.done['b1-2'] && since >= 360 && early) await placeBid(pool, STEPS[3]);
        else if (state.done['b1-2'] && !state.done['cw-withdraw'] && early) await withdrawCwRefund(pool);
        else if (!state.done['b2-mid'] && since >= 12 * 3600 && early) {
          // The half-time bid only if the two late bids stay affordable after it.
          if ((await affordable(pool, 1 + lateLeft)).ok) await placeBid(pool, STEPS[4]);
          else { state.done['b2-mid'] = 'skipped (keeps the ETH for the late bids) ' + stamp(); state.notes.push('b2-mid skipped to keep the ETH for the late bids'); saveState(); log('skip b2-mid: the ETH is kept for the two late bids'); }
        }
        else if (!state.done['late-1'] && left <= LATE_FIRST && left > 45) await placeBid(pool, STEPS[5]);
        else if (state.done['late-1'] && !state.done['late-2'] && left <= LATE_SECOND && left > 30) await placeBid(pool, STEPS[6]);
      } else if (!state.done.claims) {
        if (left > -30) { await sleep(15000); continue; } // let the close pass on every node
        await settleAndClaim(pool);
        await sweep(pool);
        const ok = await verdict();
        log(`swarm finished: verdict ${ok ? 'PASS' : 'FAIL'}; record in ${OUT}`);
        process.exit(ok ? 0 : 1);
      } else { await verdict(); log('swarm already finished'); return; }
    } catch (e) {
      stepError('step', e.stack || e.message);
      await sleep(20000);
    }
    const leftNow = s.endsAt - s.now;
    if (Date.now() - lastCheck > (s.started && leftNow < 1800 ? 60000 : 300000)) { await invariants('a check').catch((e) => fail('invariants', e.message)); lastCheck = Date.now(); }
    writeFileSync(join(OUT, 'heartbeat.json'), json({ t: stamp(), ...s, done: Object.keys(state.done), failures }));
    // Sleep less near the close so the late bids land inside their windows.
    await sleep(s.started && leftNow > 0 && leftNow < 900 ? 5000 : 20000);
  }
}
async function startedAt() {
  const ev = (await allEvents(Number(await rpc('eth_blockNumber')) - 1)).find((e) => e.name === 'AuctionStarted');
  if (!ev) return Math.floor(Date.now() / 1000);
  return blockTime(ev.block);
}
async function sweep(pool) {
  for (const i of [...Object.values(BIDDERS)]) {
    const w = robot(i);
    await transferAll(w, pool.address, 'return to pool').catch((e) => log(`sweep ${w.address}: ${e.message}`));
  }
  log(`pool holds ${fmt(await balanceOf(pool.address))} ETH after the sweep`);
}
async function status() {
  const s = await snapshot();
  const pool = existsSync(join(HOME, 'pool-keystore.json')) ? '0x' + JSON.parse(readFileSync(join(HOME, 'pool-keystore.json'), 'utf8')).address.replace(/^0x/, '') : null;
  console.log(json({ ...s, endsAtIso: s.endsAt ? new Date(s.endsAt * 1000).toISOString() : null, pool, poolBalance: pool ? fmt(await balanceOf(pool)) : null,
    bidders: Object.fromEntries(Object.entries(BIDDERS).map(([n, i]) => [n, robot(i).address])), cw: state.cw || null, done: state.done, notes: state.notes }));
  if (s.settled) await verdict();
}

const cmd = process.argv[2] || 'status';
if (cmd === 'run') await run();
else if (cmd === 'check') { const ok = await invariants('manual check'); process.exit(ok ? 0 : 1); }
else if (cmd === 'status') { await status(); process.exit(0); }
else if (cmd === 'verdict') { process.exit((await verdict()) ? 0 : 1); }
else { console.error('usage: node scripts/sepolia-swarm.mjs run|status|check|verdict'); process.exit(2); }
