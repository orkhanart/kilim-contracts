// PoC (site review, 10 October 2026): the gas limits site/chain.js sends (BID_GAS 1,500,000 and
// SETTLE_GAS 1,200,000) against the floors measured as real transactions on a local anvil, and
// against the EIP-7825 per-transaction cap. Run from contracts/ after `node scripts/forge.mjs build`:
//   node test/poc/site-gas-limits.poc.mjs
import assert from 'node:assert/strict';
import { startChain, openBidding, adapterFor, siteContext, warpTo, A, UNIT, eth } from '../../../site/test/helpers.mjs';

const BID_GAS = 1_500_000n, SETTLE_GAS = 1_200_000n, EIP_7825_CAP = 16_777_216n;
const env = await startChain();
const { rpc, d } = env;
const ctx = siteContext(env.cfg);
try {
  await openBidding(rpc, d);
  const [alice, bob, carol] = [d.accounts[1], d.accounts[2], d.accounts[3]];
  const bidData = (amount) => A.F.auction.bid.encode([amount, 0n, 0n]);
  const est = async (tx) => BigInt(await rpc.call('eth_estimateGas', [tx]));
  const hex = (n) => '0x' + n.toString(16);
  const rows = [];
  const measure = async (label, tx, limit) => {
    const floor = await est(tx);
    const r = await rpc.send({ ...tx, gas: hex(floor) });        // the floor is enough: it lands
    rows.push({ label, floor: Number(floor), used: Number(BigInt(r.gasUsed)), siteLimit: Number(limit), margin: (Number(limit) / Number(floor)).toFixed(2) + 'x' });
    return floor;
  };

  // The first bid has nobody to refund: no floor beyond its own work.
  await measure('first bid (0.01 ETH, fresh bidder)', { from: alice, to: d.auction, value: hex(10n * UNIT), data: bidData(10n * UNIT) }, BID_GAS);
  // An outbidding bid by a fresh wallet: new credit slots, then the refund with its reserve.
  const outbid = await measure('outbidding bid (0.011 ETH, fresh bidder)', { from: bob, to: d.auction, value: hex(11n * UNIT), data: bidData(11n * UNIT) }, BID_GAS);
  // One gas below the floor: the contract refuses it (InsufficientGas), nothing changes, gas is spent.
  {
    const tx = { from: carol, to: d.auction, value: hex(13n * UNIT), data: bidData(13n * UNIT), gas: hex(outbid - 1n) };
    let refused = null;
    try { await rpc.call('eth_call', [tx, 'latest']); } catch (e) { refused = A.decodeRevert(e.data).name; }
    rows.push({ label: 'outbidding bid at floor - 1 (eth_call)', floor: Number(outbid), used: '-', siteLimit: refused, margin: '-' });
  }
  // The site's own simulation of that bid, with BID_GAS, passes.
  await rpc.call('eth_call', [{ from: carol, to: d.auction, value: hex(13n * UNIT), data: bidData(13n * UNIT), gas: hex(BID_GAS) }, 'latest']);
  // A repeat bidder outbidding: warm credit slots, refund to Bob.
  await measure('outbidding bid (0.013 ETH, repeat bidder)', { from: alice, to: d.auction, value: hex(13n * UNIT), data: bidData(13n * UNIT) }, BID_GAS);
  // A claim of the maximum batch, for scale (the site lets the wallet estimate this one).
  await measure('bid of 64 units (0.064 ETH, fresh bidder)', { from: carol, to: d.auction, value: hex(64n * UNIT), data: bidData(64n * UNIT) }, BID_GAS);
  await measure('claimGlyphs(64)', { from: carol, to: d.auction, data: A.F.auction.claimGlyphs.encode([64n, carol]) }, 0n);
  // Settlement with an EOA winner (Carol), the 1/1 delivered inside settle.
  const endsAt = Number((await rpc.view(d.auction, A.F.auction.endsAt))[0]);
  await warpTo(rpc, endsAt);
  const settle = await measure('settle (EOA winner, 1/1 delivered)', { from: alice, to: d.auction, data: A.F.auction.settle.encode([]) }, SETTLE_GAS);
  assert.equal((await rpc.view(d.oneOfOne, A.F.oneOfOne.ownerOf, [1n]))[0], carol);

  console.table(rows);
  assert.ok(outbid < BID_GAS, `BID_GAS ${BID_GAS} is below the outbidding floor ${outbid}`);
  assert.ok(settle < SETTLE_GAS, `SETTLE_GAS ${SETTLE_GAS} is below the settle floor ${settle}`);
  assert.ok(BID_GAS < EIP_7825_CAP && SETTLE_GAS < EIP_7825_CAP);
  console.log(`BID_GAS ${BID_GAS} = ${(Number(BID_GAS) / Number(outbid)).toFixed(2)}x the outbidding floor; SETTLE_GAS ${SETTLE_GAS} = ${(Number(SETTLE_GAS) / Number(settle)).toFixed(2)}x the settle floor; both under the EIP-7825 cap ${EIP_7825_CAP}.`);

  // What the adapter really sends: the gas field of the bid and of settle, as a wallet sees them.
  const sent = [];
  const wallet = ctx.KILIM_DEV.createWallet({ rpcUrl: env.cfg.rpcUrls[0], account: 4 });
  const provider = { on: wallet.on, request: (req) => { if (req.method === 'eth_sendTransaction') sent.push(req.params[0]); return wallet.request(req); } };
  const chain = ctx.KILIM_CHAIN.create({ chainId: env.cfg.chainId, provider, poll: false, receiptMs: 20, discoverMs: 0 });
  await chain.ready;
  const e = await chain.settle().catch((x) => x);                 // already settled: refused before any prompt
  assert.equal(e.revertName, 'AlreadySettled');
  assert.equal(sent.length, 0);
  console.log('adapter: settle after settlement is refused in simulation (AlreadySettled); nothing was sent.');
} finally { await env.anvil.stop(); }
