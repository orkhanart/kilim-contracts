// PoC (skeptic pass on the site review, 10 October 2026): what a wrong deployBlock in the chain
// config does to site/chain.js, and whether the page could tell. Run from contracts/ after
// `node scripts/forge.mjs build`:
//   node test/poc/site-late-deploy-block.poc.mjs
// Cases:
//   1. deployBlock later than the first bid and claim: the panel (state reads) shows the high bid,
//      the book (BidPlaced logs from deployBlock) is empty, the bidder's ten claimed motifs are not
//      in holdings(), and the afterglow gate derives 'no-holdings' for that collector.
//   2. The gap is permanent: after a later bid the book shows one entry while the chain has two, and
//      the top of the book now agrees with highestBidder, so "highestBidder set and book empty"
//      catches only the first moment. The book's rewards summed against motifsAllocated still
//      disagree (a check that needs no extra RPC).
//   3. deployBlock earlier than the deployment (1): complete book and holdings. A too-early value
//      only costs log queries; only a too-late one loses events.
// Measured apart from this script (curl, 10 October 2026): the site's configured public RPCs answer
// eth_getCode at a block only within about 128 blocks of the head (ethereum-rpc.publicnode.com:
// head-100 answers, head-200 "Archive requests require a personal token"; the Sepolia endpoint:
// "pruned history unavailable"). The suggested startup check eth_getCode(auction, deployBlock-1)
// cannot run in a viewer's page once the deployment is older than ~25 minutes.
import assert from 'node:assert/strict';
import { startChain, openBidding, loadSite, A, eth } from '../../../site/test/helpers.mjs';
import { CORE } from '../../../site/tools/node-load.mjs';

const env = await startChain();
const { rpc, d, cfg } = env;
const chains = {}; chains[cfg.chainId] = cfg;
const ctx = loadSite([...CORE, 'dev/devwallet.js', 'chain.js', 'afterglow-access.js'],
  { KILIM_CHAINS: chains, KILIM_DEFAULT_CHAIN: cfg.chainId, KILIM_NO_AUTO: true, KILIM_DEV_NO_AUTO: true });
const head = async () => Number(await rpc.call('eth_blockNumber'));
const balanceOf = A.fn('balanceOf(address) returns (uint256)');

async function adapter(patch, account) {
  const wallet = ctx.KILIM_DEV.createWallet({ rpcUrl: cfg.rpcUrls[0], account });
  const mine = { ...cfg, ...patch };
  const chain = ctx.KILIM_CHAIN.create({ chainId: cfg.chainId, chains: { [cfg.chainId]: mine }, provider: wallet, poll: false, receiptMs: 20, discoverMs: 0 });
  await chain.ready;
  assert.equal(chain.status().error, null, 'startup accepted the config');
  return chain;
}
// The BidPlaced events the chain really holds, asked from block 0.
async function bidsOnChain() {
  const logs = await rpc.call('eth_getLogs', [{ address: d.auction, topics: [ctx.KILIM_ABI.EV.BidPlaced.topic], fromBlock: '0x0', toBlock: 'latest' }]);
  return logs.length;
}
// The afterglow gate's pure decision for a connected collector after the auction ended.
function gate(chain) {
  const s = chain.status();
  return ctx.KILIM_AFTERGLOW_ACCESS.derive({
    status: { ...s, walletChainId: cfg.chainId }, config: chain.config(),
    account: { ...chain.account(), hasOneOfOne: false }, holdings: chain.holdings(),
    auctionLoaded: true, inventoryFresh: true, motifCount: 1024,
  }, 'ended');
}
const sumRewards = (a) => a.bids.reduce((n, b) => n + b.reward, 0);

try {
  await openBidding(rpc, d);
  const bidder = d.accounts[3].toLowerCase();

  // Account 3 bids 0.01 ETH and claims its ten motifs through a correctly configured adapter.
  const right = await adapter({}, 3);
  await right.bid(await right.quote(eth(10)));
  await right.claim();
  const held = Number((await rpc.view(d.motifs, balanceOf, [bidder]))[0]);
  assert.equal(held, 10);
  const ok = right.auction();
  assert.equal(ok.bids.length, 1); assert.equal(right.holdings().length, 10);

  // 1. The same wallet, a config whose deployBlock is after everything that happened.
  const late = await adapter({ deployBlock: (await head()) + 1 }, 3);
  await rpc.call('evm_mine');
  await late.refresh();
  const a = late.auction();
  console.log('case 1: deployBlock = head+1 →', { high: a.high, highBidder: a.highBidder, book: a.bids.length, holdings: late.holdings().length,
    onChainBids: await bidsOnChain(), walletHolds: held, afterglow: gate(late).reason, afterglowRight: gate(right).reason });
  assert.equal(a.highBidder, bidder);
  assert.ok(a.high > 0 && a.bids.length === 0, 'the panel shows a high bid, the book shows none');
  assert.equal(late.holdings().length, 0, 'the claimed motifs are not shown');
  assert.equal(gate(late).reason, 'no-holdings', 'the afterglow gate denies the collector');
  assert.equal(gate(right).reason, 'verified');

  // 2. Permanent: a later bid lands after the wrong deployBlock. The book shows it and only it.
  const other = await adapter({}, 4);
  await other.bid(await other.quote(eth(20)));
  await late.refresh();
  const b = late.auction();
  console.log('case 2: after a later bid →', { book: b.bids.length, onChainBids: await bidsOnChain(), topMatchesState: b.bids[0].addr === b.highBidder,
    bookRewards: sumRewards(b), motifsReserved: b.motifsReserved, holdingsOf3: late.holdings().length });
  assert.equal(b.bids.length, 1); assert.equal(await bidsOnChain(), 2);
  assert.equal(b.bids[0].addr, b.highBidder, 'top of the book agrees with the state: that check would pass now');
  assert.notEqual(sumRewards(b), b.motifsReserved, 'the rewards in the book do not add up to motifsAllocated');
  assert.equal(late.holdings().length, 0);

  // 3. Too early is harmless: everything is there.
  const early = await adapter({ deployBlock: 1 }, 3);
  const c = early.auction();
  console.log('case 3: deployBlock = 1 →', { book: c.bids.length, holdings: early.holdings().length, bookRewards: sumRewards(c), motifsReserved: c.motifsReserved });
  assert.equal(c.bids.length, 2); assert.equal(early.holdings().length, 10);
  assert.equal(sumRewards(c), c.motifsReserved);
  console.log('done');
} finally { await env.anvil.stop(); }
