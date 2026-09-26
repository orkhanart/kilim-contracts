// A narrated run of the whole auction on a fresh local anvil, driven through the site's own
// adapter (site/chain.js) exactly as the pages drive it. Every step prints the snapshot the
// page would show and asserts it.   pnpm walkthrough
import assert from 'node:assert/strict';
import { startAnvil } from './dev/anvil.mjs';
import { deployLocal, siteConfig, rpcClient, A } from './dev/deploy.mjs';
import { loadSite, CORE } from '../../site/tools/node-load.mjs';

const USD = 1_000_000n;
let n = 0;
function step(title) { n++; console.log(`\n${String(n).padStart(2, ' ')}. ${title}`); }
function show(chain, extra = {}) {
  const a = chain.auction(), acct = chain.account();
  const row = {
    phase: a.phase, high: a.high ? `$${a.high}` : '—', minNext: `$${a.minNext}`,
    endsAt: a.endsAt ? new Date(a.endsAt * 1000).toISOString() : '(not started)',
    reserved: a.symbolsReserved, poolLeft: a.poolLeft, bids: a.bids.length,
  };
  if (acct) Object.assign(row, { you: acct.address.slice(0, 8), credits: acct.credits, refund: KILIM_CHAIN.fmtUsd(acct.refund), held: chain.holdings().length });
  console.log('   ', JSON.stringify({ ...row, ...extra }));
}
async function expectName(promise, name) {
  try { await promise; } catch (e) {
    const got = e.revertName || e.kind;
    assert.equal(got, name, e.message);
    return e;
  }
  throw new Error(`expected ${name}`);
}

async function world(overrides = {}) {
  const anvil = await startAnvil();
  const rpc = rpcClient(anvil.rpcUrl);
  const d = await deployLocal(anvil.rpcUrl, overrides);
  const cfg = siteConfig(d, { rpcUrl: anvil.rpcUrl });
  const ctx = loadSite([...CORE, 'dev/devwallet.js', 'chain.js'], {
    KILIM_CHAINS: { 31337: cfg }, KILIM_DEFAULT_CHAIN: 31337, KILIM_NO_AUTO: true, KILIM_DEV_NO_AUTO: true,
  });
  const as = async (account, batch = false, lockSymbolIds = false) => {
    const provider = ctx.KILIM_DEV.createWallet({ rpcUrl: anvil.rpcUrl, account, batch });
    const chain = ctx.KILIM_CHAIN.create({ chainId: 31337, provider, poll: false, receiptMs: 20, lockSymbolIds });
    await chain.ready;
    return chain;
  };
  const warp = async (ts) => { await rpc.call('evm_setNextBlockTimestamp', [Number(ts)]); await rpc.call('evm_mine'); };
  return { anvil, rpc, d, cfg, ctx, as, warp };
}
const bid = async (chain, usd, opts) => chain.bid(await chain.quote(usd), opts);
let KILIM_CHAIN;

const W = await world();
KILIM_CHAIN = W.ctx.KILIM_CHAIN;
const { d, rpc } = W;
try {
  const alice = await W.as(1), bob = await W.as(2, true), carol = await W.as(3, false, true), treasury = await W.as(9);

  step('Before startsAt: the page counts down; a bid is simulated and refused');
  assert.equal(alice.phase(), 'before');
  await expectName(bid(alice, 1), 'AuctionNotOpen');
  show(alice);

  step('startsAt passes: bidding is open, the 24h clock waits for the first bid');
  await W.warp(d.startsAt);
  await alice.refresh();
  assert.equal(alice.phase(), 'waiting');
  assert.equal(alice.auction().endsAt, 0);
  show(alice);

  step('Alice bids $1 in USDC (approve, then bid): the clock starts');
  const a1 = await bid(alice, 1);
  assert.equal(a1.reward, 1);
  assert.equal(alice.phase(), 'open');
  show(alice, { reservedIds: `#${a1.firstId}` });

  step('Bob bids $2 with ETH, batched: swap ETH to exactly $2 USDC in his wallet, approve, bid');
  const drain = A.fn('transfer(address,uint256) returns (bool)');
  const bobUsdc = (await rpc.view(d.usdc, A.F.erc20.balanceOf, [d.accounts[2]]))[0];
  await rpc.send({ from: d.accounts[2], to: d.usdc, data: drain.encode([d.deployer, bobUsdc]) });
  const bq = await bob.quote(2);
  const eq = await bob.quoteEth(bq.shortfall);
  const b1 = await bob.bid(bq, { payWith: 'eth', ethQuote: eq });
  assert.equal(b1.batched, true);
  assert.equal(b1.payWith, 'eth');
  show(bob, { paidUpTo: KILIM_CHAIN.fmtEth(eq.ethMax), quoted: KILIM_CHAIN.fmtEth(eq.amountIn) });

  step('Carol’s quote goes stale twice: SymbolRangeMoved, then BidTooLow; each time she requotes');
  let cq = await carol.quote(5);
  await bid(alice, 3);
  const moved = await expectName(carol.bid(cq), 'SymbolRangeMoved');
  console.log('    ', carol.explain(moved).message);
  cq = await carol.quote(5);
  await bid(alice, 6);
  const low = await expectName(carol.bid(cq), 'BidTooLow');
  console.log('    ', carol.explain(low).message);
  await carol.refresh();
  cq = await carol.quote(carol.auction().minNext);
  const c1 = await carol.bid(cq);
  show(carol, { reservedIds: `#${c1.firstId}–#${c1.lastId}` });

  step('The treasury cannot bid');
  await treasury.refresh();
  const t = await expectName(bid(treasury, treasury.auction().minNext), 'TreasuryCannotBid');
  console.log('    ', treasury.explain(t).message);

  step('Three late bids, each in the last 10 minutes: each moves the close to 10 minutes after it');
  for (const who of [alice, carol, alice]) {
    await who.refresh();
    await W.warp(who.auction().endsAt - 300);
    await who.refresh();
    const r = await bid(who, who.auction().minNext);
    const ts = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
    assert.equal(r.endsAt, ts + 600);
    show(who);
  }

  step('Bob, outbid, withdraws his refund in USDC; his symbols stay');
  await bob.refresh();
  const refund = bob.account().refund;
  assert.ok(refund > 0n);
  await bob.withdrawRefund();
  assert.equal(bob.account().refund, 0n);
  assert.equal(bob.account().credits, 2);
  show(bob, { withdrew: KILIM_CHAIN.fmtUsd(refund) });

  step('Alice claims everything her bids reserved, up to 64 per claim, from non-contiguous ranges');
  await alice.refresh();
  console.log('     ranges:', alice.account().ranges.map((r) => `#${r.firstId}–#${r.firstId + r.count - 1}`).join(', '));
  const claimed = await alice.claimAll({ onProgress: (p) => console.log(`     claimed ${p.claimed} of ${p.total}`) });
  assert.equal(alice.account().credits, 0);
  assert.equal(alice.holdings().length, claimed.count);
  show(alice);

  step('Carol tries to claim to a contract that cannot hold NFTs: caught before signing');
  const bad = await expectName(carol.claim({ to: d.usdc }), 'ERC721InvalidReceiver');
  console.log('    ', carol.explain(bad).message);
  await carol.claimAll();
  show(carol);

  step('Carol weaves 2 × 2, expands it to 2 × 3, then freezes it');
  const held = carol.holdings();
  const w = await carol.weave(held.slice(0, 4), 2, 2, { mode: 'flat', materials: { flat: 'indigo' } });
  const art = carol.grids()[0];
  const extra = carol.holdings().slice(0, 2).map((x) => x.id);
  await carol.expand(w.artworkId, [art.cells[1], art.cells[0], extra[0], art.cells[3], art.cells[2], extra[1]], 2, 3,
                     { mode: 'flat', materials: { flat: 'indigo' } });
  await carol.freeze(w.artworkId);
  const g = carol.grids()[0];
  assert.equal(g.revision, 2); assert.equal(g.frozen, true);
  // The site names it as tokenURI does: the first artwork is Kilim Artwork #1, whatever its token ID.
  assert.equal(carol.nameOf(g.id), 'Kilim Artwork #1');
  console.log('    ', `${carol.nameOf(g.id)} (token ${g.id}) · ${g.cols} × ${g.rows} · revision ${g.revision} · ${g.frozen ? 'frozen' : 'editable'}`);

  step('The close passes: anyone settles, the winner claims the 1/1, the treasury withdraws');
  await alice.refresh();
  await W.warp(alice.auction().endsAt);
  await bob.refresh();
  assert.equal(bob.phase(), 'ended');
  await bob.settle();
  const winner = [alice, carol].find((c) => c.auction().youWin);
  await winner.refresh();
  await winner.claimPrize();
  assert.ok(winner.account().hasMasterpiece);
  await treasury.refresh();
  const due = treasury.auction().proceedsDue;
  await treasury.withdrawProceeds();
  show(winner, { proceedsWithdrawn: KILIM_CHAIN.fmtUsd(due) });
} finally {
  await W.anvil.stop();
}

step('A second deployment with a 5-symbol pool: once it is used up, bids still count and pass 0 and 0');
const S = await world({ symbolCap: 5n, maxSymbolsPerBid: 5n });
try {
  await S.warp(S.d.startsAt);
  const alice = await S.as(1), bob = await S.as(2);
  await bid(alice, 5);
  await bob.refresh();
  const q = await bob.quote(bob.auction().minNext);
  assert.equal(q.reward, 0n); assert.equal(q.minimumReward, 0n); assert.equal(q.expected, 0n);
  const r = await bob.bid(q);
  assert.equal(r.reward, 0);
  show(bob, { lastBidReserved: r.reward });
} finally {
  await S.anvil.stop();
}
console.log('\nWalkthrough complete: every step matched the chain.');
