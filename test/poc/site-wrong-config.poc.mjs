// PoC (site review, 10 October 2026): what site/chain.js does when the chain config names the wrong
// contracts. Run from contracts/ after `node scripts/forge.mjs build` (it compiles RogueAuction.sol):
//   node test/poc/site-wrong-config.poc.mjs
// Cases:
//   1. auction = a contract that is not an auction (an SSTORE2 chunk): startup never fails, it
//      retries forever as if the network were down, and guardWrite() still lets a write through,
//      so settle() signs and lands a transaction to that address (gas spent, no value).
//   2. auction = a rogue contract naming the real tokens: every startup check passes (the tokens are
//      not asked who their minter is) and a bid's ETH goes to the rogue.
//   3. deployBlock later than the bids: the book shows no bids while the panel shows a high bid.
//   4. glyphs/oneOfOne swapped, or an auction of another deployment: stopped at startup (sound).
import assert from 'node:assert/strict';
import { startChain, openBidding, siteContext, deployLocal, A, UNIT, eth } from '../../../site/test/helpers.mjs';
import { artifact } from '../../scripts/dev/deploy.mjs';

const env = await startChain();
const { rpc, d, cfg } = env;
const ctx = siteContext(cfg);
const hex = (n) => '0x' + n.toString(16);
const balance = async (who) => BigInt(await rpc.call('eth_getBalance', [who, 'latest']));
function adapter(patch, account) {
  const sent = [];
  const wallet = ctx.KILIM_DEV.createWallet({ rpcUrl: cfg.rpcUrls[0], account });
  const provider = { on: wallet.on, request: (req) => { if (req.method === 'eth_sendTransaction') sent.push(req.params[0]); return wallet.request(req); } };
  const mine = { ...cfg, ...patch };
  const chain = ctx.KILIM_CHAIN.create({ chainId: cfg.chainId, chains: { [cfg.chainId]: mine }, provider, poll: false, receiptMs: 20, discoverMs: 0 });
  return { chain, sent };
}
try {
  await openBidding(rpc, d);

  // 1. A contract that is not an auction.
  {
    const chunk = d.chunks.names[0];
    const { chain, sent } = adapter({ auction: chunk }, 1);
    await chain.ready;
    const s = chain.status();
    console.log('case 1: auction = SSTORE2 chunk →', { error: s.error, stale: s.stale, ready: s.ready, phase: chain.phase() });
    assert.equal(s.error, null, 'no startup error: the page thinks the network is down');
    assert.match(s.stale, /ABI data too short/);
    // The page shows its Connect button in this state (no error, addresses configured); after the
    // click, guardWrite() passes: it checks fatal, void, wallet and network, never that startup finished.
    await chain.connect();
    const r = await chain.settle();
    const receipt = await rpc.receipt(r.tx);
    console.log('case 1: settle() signed a transaction to', receipt.to, 'status', receipt.status, 'gasUsed', Number(receipt.gasUsed));
    assert.equal(receipt.to.toLowerCase(), chunk);
    assert.equal(sent.length, 1);
  }

  // 2. A rogue auction naming the real tokens.
  {
    const rogue = artifact('RogueAuction');
    const rc = await rpc.send({ from: d.deployer, gas: '0x2dc6c0', data: rogue.bytecode + A.encode(['address', 'address', 'address'], [d.glyphs, d.oneOfOne, d.treasury]).slice(2) });
    const rogueAddr = rc.contractAddress.toLowerCase();
    const { chain, sent } = adapter({ auction: rogueAddr, deployBlock: Number(rc.blockNumber) }, 2);
    await chain.ready;
    const s = chain.status();
    console.log('case 2: auction = RogueAuction →', { error: s.error, stale: s.stale, phase: chain.phase() });
    assert.equal(s.error, null, 'every startup check passed');
    const before = await balance(rogueAddr);
    const q = await chain.quote(eth(10));
    const r = await chain.bid(q);
    console.log('case 2: the bid landed at', rogueAddr, 'reward', r.reward, 'rogue balance now', Number(await balance(rogueAddr) - before) / 1e18, 'ETH');
    assert.equal(await balance(rogueAddr) - before, 10n * UNIT);
    assert.equal(sent[0].to.toLowerCase(), rogueAddr);
    // The two reads that would have caught it, which site-config.mjs makes and chain.js does not:
    const minter = A.fn('minter() returns (address)');
    const g = (await rpc.view(d.glyphs, minter))[0], o = (await rpc.view(d.oneOfOne, minter))[0];
    console.log('case 2: glyphs.minter() =', g, ' oneOfOne.minter() =', o, ' cfg.auction =', rogueAddr);
    assert.notEqual(g, rogueAddr);
  }

  // 3. deployBlock later than the first bids.
  {
    const first = adapter({}, 3);
    await first.chain.ready;
    await first.chain.bid(await first.chain.quote(eth(10)));
    await first.chain.claim();
    const late = Number(await rpc.call('eth_blockNumber'));
    await rpc.call('evm_mine');
    const { chain } = adapter({ deployBlock: late + 1 }, 3);
    await chain.ready;
    const a = chain.auction();
    console.log('case 3: deployBlock after the bids →', { high: a.high, highBidder: a.highBidder, bookLength: a.bids.length, holdings: chain.holdings().length, credits: chain.account().credits });
    assert.ok(a.high > 0 && a.bids.length === 0, 'the panel shows a high bid, the book shows none');
    assert.equal(chain.holdings().length, 0, 'the claimed glyphs are not shown');
  }

  // 4. Sound: swapped tokens, and an auction of another deployment with this one's tokens.
  {
    const swapped = adapter({ glyphs: cfg.oneOfOne, oneOfOne: cfg.glyphs }, 4);
    await swapped.chain.ready;
    assert.match(swapped.chain.status().error, /auction\.glyphs\(\) does not match/);
    const other = await deployLocal(cfg.rpcUrls[0], {});
    const stale = adapter({ auction: A.checksum(other.auction) }, 4);
    await stale.chain.ready;
    assert.match(stale.chain.status().error, /auction\.glyphs\(\) does not match/);
    const wrongTokens = adapter({ glyphs: A.checksum(other.glyphs), oneOfOne: A.checksum(other.oneOfOne) }, 4);
    await wrongTokens.chain.ready;
    assert.match(wrongTokens.chain.status().error, /auction\.glyphs\(\) does not match/);
    console.log('case 4: swapped tokens, another deployment\'s auction, another deployment\'s tokens: all stopped at startup with', JSON.stringify(stale.chain.status().error));
  }
  console.log('done');
} finally { await env.anvil.stop(); }
