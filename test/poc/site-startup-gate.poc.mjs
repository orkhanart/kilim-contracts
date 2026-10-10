// PoC (skeptic pass on the site review, 10 October 2026): does site/chain.js let a write through
// before startup has verified the configured contracts, and what does that cost?
// Run from contracts/ after `node scripts/forge.mjs build`:
//   node test/poc/site-startup-gate.poc.mjs
// Cases:
//   A. auction = an SSTORE2 chunk (runtime 0x00…: every call succeeds with empty data). Startup
//      never becomes fatal (the decode error is retried as a network fault) and, through the API
//      only, settle / withdrawRefund / claimPrize / register sign and land a no-value transaction
//      to the chunk. bid() and claim() stop before signing. The only loss is the gas of those.
//   B. auction = the glyph contract (a wrong contract that reverts on auction selectors): startup
//      retries the same way, but the pre-sign simulation refuses the write. Nothing is signed.
//   C. the right config, with a read endpoint that once answers `0x` to the startup calls (a
//      backend without the state): the retry branch is what recovers it. Turning a decode failure
//      into a fatal 'Startup' error, as the finding suggests, would leave this visitor on
//      "Can't continue" until a reload.
import assert from 'node:assert/strict';
import { startChain, openBidding, siteContext, eth } from '../../../site/test/helpers.mjs';

const env = await startChain();
const { rpc, d, cfg } = env;
const ctx = siteContext(cfg);
const balance = async (who) => BigInt(await rpc.call('eth_getBalance', [who, 'latest']));
function adapter(patch, account, extra = {}) {
  const sent = [];
  const wallet = ctx.KILIM_DEV.createWallet({ rpcUrl: cfg.rpcUrls[0], account });
  const provider = { on: wallet.on, request: (req) => { if (req.method === 'eth_sendTransaction') sent.push(req.params[0]); return wallet.request(req); } };
  const mine = { ...cfg, ...patch };
  const chain = ctx.KILIM_CHAIN.create({ chainId: cfg.chainId, chains: { [cfg.chainId]: mine }, provider, poll: false, receiptMs: 20, discoverMs: 0, ...extra });
  return { chain, sent };
}
async function failsWith(promise) {
  try { await promise; } catch (e) { return (e && (e.kind || e.name)) + ': ' + (e && e.message); }
  return 'succeeded';
}
try {
  await openBidding(rpc, d);

  // A. The chunk.
  {
    const chunk = d.chunks.names[0];
    const { chain, sent } = adapter({ auction: chunk }, 1);
    await chain.ready;
    const s = chain.status();
    console.log('A: status', { error: s.error, stale: s.stale, ready: s.ready, phase: chain.phase(), imm: chain._state.imm });
    assert.equal(s.error, null);
    assert.equal(s.ready, false);
    assert.equal(chain._state.imm, null, 'startup never finished');
    await chain.connect();
    const who = chain.connected();
    const before = await balance(who);
    const landed = [];
    for (const [label, run] of [
      ['settle', () => chain.settle()],
      ['withdrawRefund', () => chain.withdrawRefund()],
      ['claimPrize', () => chain.claimPrize()],
      ['register', () => chain.register()],
    ]) {
      const r = await run();
      const rc = await rpc.receipt(r.tx);
      landed.push({ label, to: rc.to, status: rc.status, gasUsed: Number(rc.gasUsed), value: sent[sent.length - 1].value || '0x0' });
    }
    console.log('A: writes that landed through the API:', landed);
    landed.forEach((l) => { assert.equal(l.to.toLowerCase(), chunk); assert.equal(l.value, '0x0'); });
    console.log('A: bid()   →', await failsWith(chain.quote(eth(10)).then((q) => chain.bid(q))));
    console.log('A: claim() →', await failsWith(chain.claim()));
    console.log('A: claimAll() →', await failsWith(chain.claimAll()));
    assert.equal(sent.length, 4, 'only the four no-value writes were signed');
    const spent = before - (await balance(who));
    const gas = landed.reduce((n, l) => n + l.gasUsed, 0);
    console.log('A: ETH gone from the signer:', Number(spent) / 1e18, 'ETH, all gas (', gas, 'gas over', landed.length, 'transactions, value 0 )');
  }

  // B. The glyph contract in the auction's place.
  {
    const { chain, sent } = adapter({ auction: cfg.glyphs }, 2);
    await chain.ready;
    const s = chain.status();
    console.log('B: status', { error: s.error, stale: s.stale, phase: chain.phase() });
    assert.equal(s.error, null, 'also retried as a network fault');
    await chain.connect();
    console.log('B: settle() →', await failsWith(chain.settle()));
    assert.equal(sent.length, 0, 'the simulation refused it: nothing signed');
  }

  // C. The right config behind a read endpoint that once answers `0x` (no state) to the startup reads.
  {
    const inner = ctx.KILIM_RPC.http(cfg.rpcUrls);
    let blank = 1, blanked = 0;
    const read = {
      request: inner.request,
      batch: async (reqs) => {
        const out = await inner.batch(reqs);
        if (blank > 0 && reqs.some((r) => r.method === 'eth_call')) { blank--; blanked++; return out.map((r, i) => reqs[i].method === 'eth_call' ? { result: '0x' } : r); }
        return out;
      },
    };
    const seen = [];
    const { chain } = adapter({}, 3, { read, poll: true, pollMs: 30 });
    chain.onChange(() => { const s = chain.status(); if (s.stale && !seen.includes(s.stale)) seen.push(s.stale); });
    await chain.ready;
    chain.stop();
    const s = chain.status();
    console.log('C: one blank answer, then the retry →', { blanked, firstStale: seen[0] || null, error: s.error, stale: s.stale, ready: s.ready, phase: chain.phase() });
    assert.equal(blanked, 1);
    assert.match(seen[0] || '', /ABI data too short/, 'the same message the finding wants made fatal');
    assert.equal(s.error, null);
    assert.equal(s.ready, true);
    assert.notEqual(chain.phase(), 'loading', 'recovered by the retry');
  }
  console.log('done');
} finally { await env.anvil.stop(); }
