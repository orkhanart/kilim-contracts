// A narrated run of the whole auction on a fresh local anvil, driven through the site's own
// adapter (site/chain.js) exactly as the pages drive it. Every step prints the snapshot the
// page would show and asserts it. Everything is native ETH.   pnpm walkthrough
import assert from 'node:assert/strict';
import { startAnvil } from './dev/anvil.mjs';
import { deployLocal, siteConfig, rpcClient, registerWallets, openBidding, A, F, UNIT } from './dev/deploy.mjs';
import { loadSite, CORE } from '../../site/tools/node-load.mjs';

let n = 0;
function step(title) { n++; console.log(`\n${String(n).padStart(2, ' ')}. ${title}`); }
function show(chain, extra = {}) {
  const a = chain.auction(), acct = chain.account();
  const row = {
    phase: a.phase, registered: `${a.registrationCount}/100`, high: a.high ? `${a.high} ETH` : '—', minNext: `${a.minNext} ETH`,
    endsAt: a.endsAt ? new Date(a.endsAt * 1000).toISOString() : '(not started)',
    reserved: a.motifsReserved, claimed: a.motifsClaimed, poolLeft: a.poolLeft, bids: a.bids.length,
  };
  if (acct) Object.assign(row, { you: acct.address.slice(0, 8), credits: acct.credits, refund: KILIM_CHAIN.fmtEth(acct.refund), held: chain.holdings().length });
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
  // `account`: an anvil account index, or any address (the dev wallet impersonates it).
  const as = async (account, lockMotifIds = false) => {
    const provider = ctx.KILIM_DEV.createWallet({ rpcUrl: anvil.rpcUrl, account });
    const chain = ctx.KILIM_CHAIN.create({ chainId: 31337, provider, poll: false, receiptMs: 20, lockMotifIds });
    await chain.ready;
    return chain;
  };
  const warp = async (ts) => { await rpc.call('evm_setNextBlockTimestamp', [Number(ts)]); await rpc.call('evm_mine'); };
  const balance = async (who) => BigInt(await rpc.call('eth_getBalance', [who, 'latest']));
  const view = async (to, f, args = []) => (await rpc.view(to, f, args))[0];
  return { anvil, rpc, d, cfg, ctx, as, warp, balance, view };
}
const bid = async (chain, eth, opts) => chain.bid(await chain.quote(eth), opts);
let KILIM_CHAIN;

const W = await world();
KILIM_CHAIN = W.ctx.KILIM_CHAIN;
const { d, rpc } = W;
try {
  const alice = await W.as(1), bob = await W.as(2), carol = await W.as(3, true), treasury = await W.as(9);

  step('Before startsAt: the page counts down; nobody can register or bid yet');
  assert.equal(alice.phase(), 'before');
  await expectName(alice.register(), 'RegistrationClosed');
  await expectName(bid(alice, '0.01'), 'RegistrationIncomplete');
  show(alice);

  step('startsAt passes: registration opens. Alice registers: no deposit, she only has to hold 0.01 ETH');
  await W.warp(d.startsAt);
  await alice.refresh();
  assert.equal(alice.phase(), 'waiting');
  const beforeRegistering = await W.balance(d.auction);
  await alice.register();
  assert.equal(alice.auction().registrationCount, 1);
  assert.equal(alice.auction().registered, true);
  assert.equal(await W.balance(d.auction), beforeRegistering, 'registration paid the auction nothing');
  await expectName(alice.register(), 'AlreadyRegistered');
  const noTreasury = await expectName(treasury.register(), 'TreasuryCannotBid');
  console.log('    ', treasury.explain(noTreasury).message);
  const locked = await expectName(bid(alice, '0.01'), 'RegistrationIncomplete');
  console.log('    ', alice.explain(locked).message);
  show(alice);

  step('98 more wallets register; Bob is the 100th. Bidding is unlocked and registration is closed');
  assert.equal(await registerWallets(rpc, d, 99), 99);
  await bob.refresh();
  await bob.register();
  assert.equal(bob.auction().registrationCount, 100);
  assert.equal(bob.auction().endsAt, 0, 'registering placed no bid: the clock has not started');
  await carol.refresh();
  await expectName(carol.register(), 'RegistrationClosed');
  show(bob);

  step('Alice bids 0.01 ETH, the reserve: one payable transaction. The 24h clock starts');
  const a1 = await bid(alice, '0.01');
  assert.equal(a1.reward, 10, 'one motif per 0.001 ETH');
  assert.equal(alice.phase(), 'open');
  assert.equal(await W.balance(d.auction), 10n * UNIT);
  show(alice, { reservedIds: `#${a1.firstId}–#${a1.lastId}` });

  step('Bob bids 0.02 ETH: Alice gets her 0.01 ETH back inside his transaction, and keeps her motifs');
  const aliceBefore = await W.balance(d.accounts[1]);
  const b1 = await bid(bob, '0.02');
  assert.equal(b1.reward, 20);
  assert.equal(await W.balance(d.accounts[1]), aliceBefore + 10n * UNIT, 'the refund arrived as ETH');
  await alice.refresh();
  assert.equal(alice.account().refund, 0n, 'nothing waits to be withdrawn');
  assert.equal(alice.account().credits, 10);
  assert.equal(await W.balance(d.auction), 20n * UNIT, 'the auction holds only the highest bid');
  show(alice);

  step('Carol (never registered: anyone may bid once 100 have) finds her quote stale twice: MotifRangeMoved, then BidTooLow');
  let cq = await carol.quote('0.05');
  await bid(alice, '0.03');
  const moved = await expectName(carol.bid(cq), 'MotifRangeMoved');
  console.log('    ', carol.explain(moved).message);
  cq = await carol.quote('0.05');
  await bid(alice, '0.06');
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

  step('A contract that cannot receive ETH bids. When Alice outbids it the refund is deferred, and it withdraws it to another address');
  // The motif collection has no receive function: the dev wallet impersonates it as a bidder.
  await rpc.call('anvil_setBalance', [d.motifs, '0xde0b6b3a7640000']);
  const vault = await W.as(d.motifs);
  const v1 = await bid(vault, vault.auction().minNext);
  await alice.refresh();
  await bid(alice, alice.auction().minNext);
  await vault.refresh();
  const owed = vault.account().refund;
  assert.equal(owed, BigInt(Math.round(v1.bid * 1000)) * UNIT, 'the push refund failed, so the whole bid waits');
  assert.equal(vault.account().credits, v1.reward, 'its motifs stay');
  show(vault);
  const safe = d.accounts[5], safeBefore = await W.balance(safe);
  await vault.withdrawRefund(safe);
  assert.equal(await W.balance(safe), safeBefore + owed);
  assert.equal(vault.account().refund, 0n);
  await expectName(vault.withdrawRefund(safe), 'NothingToWithdraw');
  console.log('    ', `withdrew ${KILIM_CHAIN.fmtEth(owed)} to ${safe.slice(0, 8)}`);

  step('Three late bids, each in the last 10 minutes: each moves the close to 10 minutes after it');
  for (const who of [carol, alice, carol]) {
    await who.refresh();
    await W.warp(who.auction().endsAt - 300);
    await who.refresh();
    const r = await bid(who, who.auction().minNext);
    const ts = Number((await rpc.call('eth_getBlockByNumber', ['latest', false])).timestamp);
    assert.equal(r.endsAt, ts + 600);
    show(who);
  }

  step('Carol tries to claim to a contract that cannot hold NFTs: caught before signing');
  // A contract whose runtime is 0xfe (INVALID): every call to it reverts with no data, which the
  // safe-mint hook reports as ERC721InvalidReceiver. (A stored page chunk is not usable here: its code
  // starts with STOP, so onERC721Received returns empty data and the decode fails with no reason.)
  const rejecting = (await rpc.send({ from: d.deployer, data: '0x60fe60005360016000f3', gas: '0x30000' })).contractAddress;
  const bad = await expectName(carol.claim({ to: rejecting }), 'ERC721InvalidReceiver');
  console.log('    ', carol.explain(bad).message);

  step('Nothing is sent automatically: each bidder claims their own motifs with claimMotifs, up to 64 per transaction');
  await alice.refresh();
  assert.equal(alice.auction().motifsClaimed, 0, 'no motif token exists until its bidder claims it');
  let minted = 0;
  for (const who of [alice, bob, carol]) {
    await who.refresh();
    const credits = who.account().credits;
    const r = await who.claimAll();
    assert.equal(r.count, credits);
    assert.equal(who.account().credits, 0);
    assert.equal(who.holdings().length, credits);
    console.log(`     ${who.account().address.slice(0, 8)} claimed ${r.count} in ${Math.ceil(r.count / 64)} transaction${r.count > 64 ? 's' : ''}`);
    minted += r.count;
  }
  // The contract bidder cannot hold NFTs either, so it claims to the address it withdrew to.
  await vault.refresh();
  minted += (await vault.claimAll({ to: safe })).count;
  await alice.refresh(); await carol.refresh();
  assert.equal(alice.auction().motifsReserved, alice.auction().motifsClaimed);
  assert.equal(alice.auction().motifsClaimed, minted);
  show(alice);
  show(carol);

  step('Every token shows one of the 1,024 motifs, fixed from deployment, drawn from the stored grids');
  assert.equal(await W.view(d.motifs, F.motifs.MOTIF_COUNT), 1024n);
  assert.equal(Number(await W.view(d.motifs, F.motifs.motifsMinted)), minted);
  for (const id of [a1.firstId, a1.lastId, c1.firstId]) {
    const motif = Number(await W.view(d.motifs, F.motifs.motifOf, [BigInt(id)]));
    const name = await W.view(d.motifs, F.motifs.motifName, [motif]);
    const uri = await W.view(d.motifs, F.motifs.tokenURI, [BigInt(id)]);
    assert.ok(motif >= 1 && motif <= 1024);
    assert.ok(uri.startsWith('data:application/json;base64,'));
    const json = JSON.parse(Buffer.from(uri.slice('data:application/json;base64,'.length), 'base64').toString());
    assert.equal(json.name, `${name} (motif ${motif})`);
    assert.ok(json.image.startsWith('data:image/svg+xml;base64,'));
    console.log(`     token #${id} shows motif ${motif}, "${name}"`);
  }

  step('The close passes: anyone settles, and settling sends the 1/1 to the winner. The treasury withdraws the winning bid in ETH');
  await alice.refresh();
  await expectName(bob.settle(), 'AuctionNotEnded');
  await W.warp(alice.auction().endsAt);
  await bob.refresh();
  assert.equal(bob.phase(), 'ended');
  await bob.settle();
  const winner = [alice, carol].find((c) => c.auction().youWin);
  await winner.refresh();
  assert.equal(winner.phase(), 'settled');
  assert.ok(winner.account().hasOneOfOne, 'the 1/1 is in the winner\'s wallet');
  assert.equal(winner.auction().prizeClaimed, true);
  assert.equal((await W.view(d.oneOfOne, F.oneOfOne.ownerOf, [1n])).toLowerCase(), winner.account().address.toLowerCase());
  const uri = await W.view(d.oneOfOne, F.oneOfOne.tokenURI, [1n]);
  assert.ok(uri.startsWith('data:application/json;utf8,{"name":"The Unwoven Kilim"'));
  console.log(`     the 1/1's tokenURI is ${uri.length.toLocaleString('en-US')} bytes, served from the chain`);
  await expectName(winner.claimPrize(), 'PrizeAlreadyClaimed');
  await treasury.refresh();
  const due = treasury.auction().proceedsDue;
  assert.equal(due, winner.auction().highRaw);
  assert.equal(await W.balance(d.auction), due, 'every outbid bid went back: only the winning bid is left');
  const payout = d.accounts[6], payoutBefore = await W.balance(payout);
  await treasury.withdrawProceeds(payout);
  assert.equal(await W.balance(payout), payoutBefore + due);
  assert.equal(await W.balance(d.auction), 0n, 'the auction holds nothing');
  show(winner, { proceedsWithdrawn: KILIM_CHAIN.fmtEth(due) });
} finally {
  await W.anvil.stop();
}

step('A second deployment with a 5-motif pool: once it is used up, bids still count and pass 0 and 0');
const S = await world({ motifCap: 5n, maxMotifsPerBid: 5n });
try {
  await openBidding(S.rpc, S.d);
  const alice = await S.as(1), bob = await S.as(2);
  const first = await bid(alice, '0.01');
  assert.equal(first.reward, 5, 'the pool caps the reward');
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
