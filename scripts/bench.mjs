// Contract test bench: a private anvil chain with a fresh native-ETH Kilim deployment, and one
// page of buttons to try it by hand: check wallets in, bid, move the clock, settle, claim.
// Local only. Nothing here can reach a real network: every wallet is an impersonated address on
// the private chain, funded with test ETH.
//
//   node scripts/bench.mjs                 chain on :8547, page on http://127.0.0.1:5199
//   node scripts/bench.mjs --port 5200 --rpc-port 8548
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from './dev/anvil.mjs';
import { deployLocal, rpcClient, A } from './dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const value = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : fallback; };
const PORT = Number(value('--port', '5199')), RPC_PORT = Number(value('--rpc-port', '8547'));

const ETH = 10n ** 18n;
const hex = (n) => '0x' + BigInt(n).toString(16);
const eth = (wei) => { const s = (BigInt(wei) * 1000000n / ETH).toString().padStart(7, '0'); return (s.slice(0, -6) + '.' + s.slice(-6)).replace(/\.?0+$/, '') || '0'; };
const toWei = (text) => { const [whole, part = ''] = String(text).trim().split('.'); return BigInt(whole || '0') * ETH + BigInt((part + '0'.repeat(18)).slice(0, 18)); };
/** Wallet n of the bench: a plain address on the private chain, impersonated by anvil. */
const wallet = (n) => '0x' + (0xb0b0n * 16n ** 36n + BigInt(n)).toString(16).padStart(40, '0');

const anvil = await startAnvil({ port: RPC_PORT });
const rpc = rpcClient(anvil.rpcUrl);
let stopping = false;
async function stop(code = 0) { if (stopping) return; stopping = true; await anvil.stop(); process.exit(code); }
process.on('SIGINT', () => stop(0)); process.on('SIGTERM', () => stop(0));

let d, F, fresh, used = 0;
const log = [];
const note = (ok, text) => { log.unshift({ ok, text, at: new Date().toISOString().slice(11, 19) }); if (log.length > 200) log.pop(); };

async function deploy() {
  d = await deployLocal(anvil.rpcUrl, { nativeEth: true });
  F = A.F.auction;
  await rpc.call('anvil_autoImpersonateAccount', [true]);
  // Check-in opens at startsAt: go there, so the bench starts where a visitor would.
  await rpc.call('evm_setNextBlockTimestamp', [d.startsAt]); await rpc.call('evm_mine');
  fresh = await rpc.call('evm_snapshot');
  used = 0;
}

const view = async (f, a = []) => (await rpc.view(d.auction, f, a))[0];
const now = async () => Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);

/** Send from a bench wallet; a revert comes back as the contract's own error name. */
async function send(from, f, a = [], wei = 0n, to = d.auction) {
  try {
    const receipt = await rpc.send({ from, to, data: f.encode(a), value: hex(wei), gas: '0x2dc6c0' });
    return { ok: true, gas: Number(receipt.gasUsed) };
  } catch (e) {
    const raw = typeof e.data === 'string' ? e.data : (String(e.message).match(/0x[0-9a-fA-F]{8,}/) || [null])[0];
    const why = raw ? A.decodeRevert(raw) : null;
    const code = why && why.name !== 'Unknown' ? why.name : null;
    return { ok: false, error: code ? plain(code, why.args) + ' (' + code + ')' : String(e.message).slice(0, 160) };
  }
}

/** The contract's refusals, in plain words. The contract's own name for each follows in brackets. */
const PLAIN = {
  AlreadyRegistered: () => 'this wallet has already checked in',
  InsufficientRegistrationBalance: () => 'the wallet holds less than 0.01 ETH',
  RegistrationClosed: () => '100 wallets have already checked in, so check-in is closed',
  RegistrationIncomplete: () => 'bidding is locked until 100 wallets have checked in',
  BidTooLow: (a) => 'too low, the bid must be at least ' + eth(a[0]) + ' ETH',
  AuctionNotEnded: () => 'the auction has not ended yet',
  AuctionEnded: () => 'the auction has already ended',
  NothingToWithdraw: () => 'there is no refund waiting. Outbid ETH is sent back automatically',
  PrizeAlreadyClaimed: () => 'the 1/1 was already delivered to the winner when the auction was settled',
  TreasuryCannotBid: () => 'the treasury wallet cannot bid',
  AlreadySettled: () => 'the auction is already settled',
  NotSettled: () => 'the auction has to be settled first',
  InvalidQuantity: () => 'this wallet has no symbols left to claim, or asked for too many at once',
};
const plain = (code, a) => (PLAIN[code] ? PLAIN[code](a ?? []) : 'the contract refused');
const NAMES = ['Aylin', 'Bora', 'Cem', 'Deniz', 'Elif'];
const who = (n) => NAMES[n - 1] ?? 'Wallet ' + n;

const actions = {
  /** Check in the next `count` new wallets. `poor` gives them less than the 0.01 ETH the contract asks for. */
  async checkin({ count = 1, poor = false }) {
    let done = 0, last = null;
    for (let i = 0; i < Math.min(Number(count), 100); i++) {
      const from = wallet(++used);
      await rpc.call('anvil_setBalance', [from, hex(poor ? ETH / 200n : 5n * ETH)]);
      last = await send(from, F.register);
      if (!last.ok) { note(false, `Check-in refused: ${last.error}.`); break; }
      done++;
    }
    if (done) note(true, `${done} wallet${done > 1 ? 's' : ''} checked in. ${await view(F.registrationCount)} of 100 so far.`);
  },
  /** The same wallet a second time: the contract should refuse. */
  async again({ n }) {
    const r = await send(wallet(n), F.register);
    note(r.ok, r.ok ? `${who(n)} checked in.` : `${who(n)} tried to check in again and was refused: ${r.error}.`);
  },
  async bid({ n, amount }) {
    const from = wallet(n), wei = amount ? toWei(amount) : await view(F.minimumBid);
    if (BigInt(await rpc.call('eth_getBalance', [from, 'latest'])) < wei + ETH) await rpc.call('anvil_setBalance', [from, hex(wei + 5n * ETH)]);
    if (Number(n) > used) used = Number(n);
    const r = await send(from, F.bid, [wei, 0n, 0n], wei);
    note(r.ok, r.ok ? `${who(n)} bid ${eth(wei)} ETH.` : `${who(n)}'s bid of ${eth(wei)} ETH was refused: ${r.error}.`);
  },
  /** Move the chain's clock: a number of seconds, or to a named moment. */
  async time({ seconds, to }) {
    const t = await now(), ends = Number(await view(F.endsAt));
    const target = to === 'beforeEnd' ? ends - 60 : to === 'afterEnd' ? ends + 1 : t + Number(seconds);
    if ((to && !ends) || target <= t) return note(false, to && !ends ? 'The clock has not started yet. It starts with the first bid.' : 'That moment has already passed.');
    await rpc.call('evm_setNextBlockTimestamp', [target]); await rpc.call('evm_mine');
    note(true, `Time moved forward ${target - t >= 3600 ? Math.round((target - t) / 360) / 10 + ' hours' : Math.round((target - t) / 60) + ' minutes'}.`);
  },
  async settle() { const r = await send(wallet(1), F.settle); note(r.ok, r.ok ? 'The auction is settled. The 1/1 went to the winner.' : `Settling was refused: ${r.error}.`); },
  async claim({ n, quantity = 10 }) {
    const from = wallet(n), r = await send(from, F.claimSymbols, [BigInt(quantity), from]);
    note(r.ok, r.ok ? `${who(n)} claimed ${quantity} symbols.` : `${who(n)}'s claim was refused: ${r.error}.`);
  },
  async refund({ n }) {
    const from = wallet(n), r = await send(from, F.withdrawRefund, [from]);
    note(r.ok, r.ok ? `${who(n)} withdrew a refund.` : `${who(n)} has nothing to withdraw: ${r.error}.`);
  },
  async prize({ n }) {
    const from = wallet(n), r = await send(from, F.claimPrize, [from]);
    note(r.ok, r.ok ? `${who(n)} claimed the 1/1.` : `${who(n)} cannot claim the 1/1: ${r.error}.`);
  },
  async proceeds() {
    const r = await send(d.treasury, F.withdrawProceeds, [d.treasury]);
    note(r.ok, r.ok ? 'The artist withdrew the winning bid.' : `Withdrawing was refused: ${r.error}.`);
  },
  /** Back to the fresh deployment. */
  async reset() { await rpc.call('evm_revert', [fresh]); fresh = await rpc.call('evm_snapshot'); used = 0; log.length = 0; },
};

async function state() {
  const [t, count, highest, bidder, ends, settled, minimum, allocated, claimed, due] = await Promise.all([
    now(), view(F.registrationCount), view(F.highestBid), view(F.highestBidder), view(F.endsAt), view(F.settled),
    view(F.minimumBid).catch(() => 0n), view(F.symbolsAllocated), view(F.symbolsClaimed), view(F.proceedsDue),
  ]);
  const end = Number(ends);
  const phase = settled ? 'settled' : end && t >= end ? 'ended' : end ? 'running' : Number(count) >= 100 ? 'ready' : 'checkin';
  const leader = bidder && !/^0x0+$/.test(bidder) ? bidder.toLowerCase() : null;
  const wallets = [];
  for (let n = 1; n <= Math.max(used, NAMES.length); n++) {
    const a = wallet(n);
    // Only the wallets that have something to show beyond "checked in" are listed in full.
    const [credits, refund] = await Promise.all([view(F.symbolCredits, [a]), view(F.refunds, [a])]);
    if (n > NAMES.length && !credits && !refund && a !== leader) continue;
    const [registered, balance, owned] = await Promise.all([
      view(F.registered, [a]), rpc.call('eth_getBalance', [a, 'latest']),
      // The collection is an ERC-721: its balanceOf has the same shape as a token's.
      rpc.view(d.collection, A.F.erc20.balanceOf, [a]).then((r) => r[0]).catch(() => null),
    ]);
    wallets.push({ n, name: who(n), registered, balance: eth(balance), credits: String(credits), refund: eth(refund), owned: owned === null ? '?' : String(owned), leading: a === leader });
  }
  return {
    time: t, phase, count: Number(count), highest: eth(highest), leader: leader ? who(Number(BigInt(leader) & 0xffffffffn)) : null,
    endsAt: end, left: end ? end - t : null, minimum: eth(minimum), allocated: String(allocated), claimed: String(claimed), proceeds: eth(due),
    auction: d.auction, collection: d.collection, wallets, used, log: log.slice(0, 60),
  };
}

await deploy();
const page = readFileSync(resolve(here, 'bench.html'), 'utf8');
let busy = Promise.resolve();
createServer(async (req, res) => {
  const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(body)); };
  try {
    if (req.method === 'GET' && req.url === '/') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); return res.end(page); }
    if (req.method === 'GET' && req.url === '/state') return json(200, await (busy = busy.then(state, state)));
    if (req.method === 'POST' && req.url === '/do') {
      let body = ''; for await (const chunk of req) body += chunk;
      const { action, ...rest } = JSON.parse(body || '{}');
      if (!Object.hasOwn(actions, action)) return json(400, { error: 'unknown action' });
      // One action at a time: the chain's clock and nonces are shared.
      await (busy = busy.then(() => actions[action](rest), () => actions[action](rest)));
      return json(200, await state());
    }
    json(404, { error: 'not found' });
  } catch (e) { note(false, String(e.message).slice(0, 200)); json(500, { error: String(e.message) }); }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Kilim contract bench\n  page     http://127.0.0.1:${PORT}\n  chain    ${anvil.rpcUrl} (private, chain id 31337)\n  auction  ${d.auction}\nCtrl-C stops it.`);
});
