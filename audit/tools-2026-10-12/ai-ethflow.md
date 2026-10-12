# AI audit, ETH-flow lens (12 October 2026)

One of five independent AI reviewers (Claude instances). The lens: every path by which ETH enters or leaves
the auction, and whether the fixed gas numbers hold up if operation prices change after deployment. **This is
not the independent human audit (K-08).**

- **Code read:** `src/auction/EnglishAuction.sol` and `src/KilimAuction.sol` in full, and where they touch the
  auction, `src/KilimMotifs.sol` (mint, guard, `_update`), `src/KilimOneOfOne.sol` (`mint`, `_update`) and
  `src/KilimBazaar.sol` (reads `settled`, `highestBid`, `highestBidMotifs`; no ETH). Also `site/chain.js` for
  the gas limits it sends, and OpenZeppelin 5.6.1's `ReentrancyGuard`, `EIP712`, `SignatureChecker`.
- **Checked against:** `AUDIT.md` (F-, R-, V-, FA- items) and the existing suites (`GasFloors`, `AuditGaps`,
  `AttackPatterns`, `KilimAuction`, `AuctionInvariants`). Documented, accepted behaviour is not reported again.
- **Glamsterdam prices:** the parameter tables of EIP-8037 and EIP-8038 as published (both Last Call until
  2026-11-01), read on 12 October; read-only RPC calls for the current gas limits (mainnet 60,000,000; Sepolia
  200,000,000).
- **PoC and measurements:** `security/ai-audit/ethflow/EthFlowAudit.t.sol`, 9 tests, all pass (the last run: 9 passed, 0 failed). Run as
  `FOUNDRY_OUT=.tools-out/ai-ethflow/out FOUNDRY_CACHE_PATH=.tools-out/ai-ethflow/cache FOUNDRY_TEST=security/ai-audit/ethflow nice -n 10 node scripts/forge.mjs test -vvv`.
  Gas figures are measured cold with `vm.cool`, as a mainnet transaction meets the state, and read with
  `vm.lastCallGas()`.

## Result

**No Medium or higher found.** No path takes, double-pays or strands ETH. No hostile outbid wallet or winner
can make a correctly gassed bid or settlement fail. All three of today's fixed gas numbers still work at the
Last Call prices of EIP-8037/8038. One of them, `PRIZE_GAS`, has a thin margin: about 46,000 gas, or roughly
a 10% further rise in the price of a fresh storage slot. Past that, settlement can no longer hand the 1/1 to
any winner, but nothing is stuck except for winners that cannot call `claimPrize`. That case is already
accepted (FA-06).

| ID | Severity | Where | Proven by |
|---|---|---|---|
| ETH-1 | Low (known open item, now measured) | `src/KilimAuction.sol:51`, `:207-215` | Measurement tests (pass) plus arithmetic from the EIP tables. Not a failing PoC: forge 1.7.1 has no Glamsterdam EVM |
| ETH-2 | Info | `src/auction/EnglishAuction.sol:26`, `:243-250` | `testDeferredRefundReserveSlackAtTheFloor` (pass) plus arithmetic |
| ETH-3 | Info | `site/chain.js:22`, `:800` | `testWorstCaseBidAgainstTheSiteLimit`, `testCancunBaselines` (pass) plus arithmetic |
| ETH-4 | Info (unproven) | `src/auction/EnglishAuction.sol:244`, `src/KilimAuction.sol:211` | The EIP-8037 text only; cannot be run in forge 1.7.1 |
| ETH-5 | Info | `src/auction/EnglishAuction.sol:244`, `:282` | `testRefundToAnEmptiedAccountRecreatesIt` (pass) |

## Glamsterdam prices used

Taken from the EIP-8037 and EIP-8038 parameter tables (Last Call).

- **Price per state byte (CPSB).** 1,530. EIP-8037 calls it "a fixed parameter derived from a reference
  block gas limit" of 150M, with a target of 120 GiB of state per year. It does **not** move with the gas
  limit. It is fixed until another fork changes it.
- **Fresh slot (zero to nonzero).** 64 state bytes × 1,530 = 97,920 state gas, plus `STORAGE_WRITE` 10,000,
  plus 2,100 if the slot is cold. That is **110,020 cold** against 22,100 today: **+87,920 per fresh slot**.
- **First change of a nonzero slot.** 12,100 cold or 10,100 warm, against 5,000 or 2,900 today (+7,100 or
  +7,200).
- **Other prices.** A cold account costs 3,000 (+400). A CALL with value costs 11,300 (+2,300). A new account
  is 120 × 1,530 = 183,600 state gas, which matches the 204,600-gas plain send recorded on Sepolia.

**Check against the brief's Sepolia receipts.** The table below takes the Cancun cold measurements from
`testCancunBaselines`, adds the repricing per slot written, and subtracts the guard's `STORAGE_WRITE`
refund.

| Bid on Sepolia | Projection | Brief |
|---|---|---|
| First-time bidder outbids, refund paid | ≈ 430,000 | 428k |
| First-time bidder outbids, refund deferred | ≈ 648,000 | 648k |

The model also gives about 148,000 for `register`, against 142k in the brief. These projections are used
below.

## Findings

### ETH-1 · Low · `PRIZE_GAS` has about 46,000 gas of headroom at Last Call prices

`src/KilimAuction.sol:51` (`PRIZE_GAS = 500_000`), `:207-215` (`_afterSettle`), `:218-224` (`deliverPrize`).

**Today, measured cold** (`testPrizeDeliveryHeadroomForAnEoaAndAContractWinner`, `testPrizeMintSplit`):

- Delivering to an EOA uses 97,130 gas, of which the 1/1's `mint` is 70,176.
- Delivering to a contract with an empty hook uses 98,589 gas, of which the mint is 74,135.
- Every delivery writes **4 fresh slots**: `prizeClaimed`, the 1/1's `minted`, `_owners[1]` and
  `_balances[winner]`. It updates none.

**At Last Call prices**, delivery to an EOA works like this:

- `deliverPrize` spends about 113,500 before calling the 1/1: `prizeClaimed` (110,020) and the cold call
  (3,000).
- That leaves about 386,500. Under the 63/64 rule the 1/1 gets about 380,400 of it.
- The 1/1 needs 70,176 + 3 × 87,920 + 400 = **334,336**.
- So the margin is **about 46,000**. A contract winner has about 42,000 left for its hook. A Safe needs
  about 22,000 (`AUDIT.md`), so it fits; a hook that writes one fresh slot does not.

**How it fails.** The same arithmetic gives the break-even point. Delivery fails for **every** winner,
EOAs included, once a fresh slot costs about **11,600 more** than the Last Call price (≈ +10.5%). That would
happen, for example, at CPSB ≥ about 1,711 instead of 1,530, or with `STORAGE_WRITE` ≥ about 21,600.

**Consequences:**

- `settle()` still succeeds and the proceeds can still be withdrawn (`testAFailedDeliveryLeavesOnlyTheWinnersOwnClaim`).
- `PrizeDeliveryFailed` is emitted, and the winner must call `claimPrize(to)`, which has no gas cap.
- Nobody else can claim or deliver (`Unauthorized`).
- A winning contract that cannot make that call (a pool or crowdfund with a fixed `bid()`) never gets the
  1/1. Today that happens only to winners whose hook needs more than about 385,000 gas. Past the threshold it
  happens to every such contract, whatever its hook. This is the FA-06 class the artist accepted, made wider
  by the price.

**Why it is plausible.** EIP-8037/8038 are not final until 1 November. The EIP pins CPSB to a 150M reference
gas limit, so if mainnet goes well past 150M, a higher CPSB is the lever for keeping state growth on target.
`PRIZE_GAS` is immutable.

**Record.** This is a known open item: "Still to decide: PRIZE_GAS headroom under Glamsterdam" (AUDIT.md,
11 October) and checklist 1 line 216. What is new is the margin computed from the final Last Call tables:
about 46k for an EOA winner, or a ~10% rise in the fresh-slot price.

**Suggested fix (the artist decides; the code is frozen).** Choose one:

- **(a)** Before the freeze, raise `PRIZE_GAS`, for example to 1,000,000. That gives about 540k of headroom
  at Last Call prices, about five more fresh slots. The settle floor becomes about 1.07M plus the gas spent
  before it, so `SETTLE_GAS` on the site must go to at least 1.6M. A hostile winner could then cost the
  settler up to 1M gas.
- **(b)** Keep 500,000 and treat a failed delivery as a normal outcome. The site would show "Claim the 1/1"
  whenever `PrizeDeliveryFailed` is seen (with a recipient field, W-17), and the terms would tell contract
  bidders that they must be able to call `claimPrize`.

Either way, re-measure on Sepolia after 1 November: the swarm's `settle` receipt is the real figure.

### ETH-2 · Info · `DEFERRED_REFUND_RESERVE` holds at Last Call prices, with about 36% to spare

`src/auction/EnglishAuction.sol:26`, `:243-250`.

**The test setup** (`testDeferredRefundReserveSlackAtTheFloor`):

- The rival is a first-time bidder.
- The leader's `receive()` burns the whole 150,000.
- It is the auction's first deferral, so both `refunds[leader]` and `refundLiability` are fresh.

**What it measured:**

- The smallest call gas that lands the bid is **549,109**, or 570,629 as a transaction.
- One gas less fails with `InsufficientGas`, never with a bare out-of-gas, so the floor check is what binds.
- At that limit, **255,468** gas is left when the bid returns.
- The deferral writes two fresh slots after the refund call.

**At Last Call prices.** The deferral costs 2 × 87,920 more, which leaves **79,628**. The reserve runs out
only when a fresh slot costs about 39,800 more than Last Call (≈ +36%, to about 150,000).

**Past that point.** F-01's guarantee no longer holds: "the gas a bid needs never depends on the outbid
wallet's code". A bid sent with a wallet's no-margin estimate, taken while the leader was cheap, would run out
of gas if the leader arms a gas-burning receiver. Only gas is lost, and the site's fixed 1.5M still covers
it (ETH-3).

**Also checked** (`testMinimumBidGasIsTheSameForEveryLeaderShape`). The smallest gas that lands a bid is the
same, **549,109**, for six leader shapes: accept, refuse, burn all, a 150 KB return buffer, accept after
starving its caller, and re-entry attempts. This is F-01 confirmed on more shapes.

**F-06 at Glamsterdam prices.** A gas-burning leader costs each rival about 150,000 plus 2 × 110,020, about
370k extra, against about 14k for an EOA leader. That is about 0.00018 ETH at 0.5 gwei.

**Record.** Known as R-07 ("reduced") and "about 40%" in AUDIT.md. This test confirms it with the final prices.

**Suggested fix.** None needed. If CPSB rises later, the site's fixed gas limit is the defence. Keep it.

### ETH-3 · Info · The site's fixed gas limits fit at Last Call prices with wide margins

`site/chain.js:22` (`BID_GAS = 1,500,000`, `SETTLE_GAS = 1,200,000`), `:800` (opening bid: the node's
estimate × 4/3).

**The worst outbidding bid** is a first-time bidder, a gas-burning leader and the first deferral: 5 fresh
slots and 5 cold first updates (`testWorstCaseBidAgainstTheSiteLimit`).

| Worst outbidding bid | Today (Cancun, cold) | Last Call |
|---|---|---|
| Gas used, as a transaction | 317,461 | ≈ 793,000 |
| Gas limit it needs (refund floor) | 570,629 | ≈ 870,000 |

**`BID_GAS`.** 1.5M stops being enough only once a fresh slot costs about 141,000 more than Last Call.

**Settlement.** It writes one fresh slot (`proceedsDue`) and two first updates before its floor, so it needs
about 690,000 against 1.2M.

**Opening bid.** It writes 8 fresh slots (measured: 212,358 gas cold today). That projects to about 920,000
at Last Call prices, matching the site's own figure of about 926,000.

**On mainnet today (Cancun).** The opening bid is sent with about 283,000 gas (212,358 × 4/3). If a rival's opening bid lands
first, it becomes an outbidding bid below the ~570k floor and reverts with `InsufficientGas`. The site
comment at `chain.js:26` already says so: nothing is lost but gas.

**Suggested fix.** None needed. These values live in the site, which can still change. Re-measure them with
the Sepolia swarm receipts.

### ETH-4 · Info (unproven) · Under EIP-8037 the 150k and 500k caps do not bound state gas from the reservoir

`src/auction/EnglishAuction.sol:244` (`try this.payOutbidRefund{gas: REFUND_GAS}`) and `:282` (`_pay`
forwards all gas); `src/KilimAuction.sol:211` (`deliverPrize{gas: PRIZE_GAS}`).

**What the EIP says.** EIP-8037 (Last Call): `state_gas_reservoir = evm_gas - gas_left`, so the reservoir
exists only when the gas limit exceeds the 16,777,216 execution budget. Also, "the `GAS` opcode returns
`gas_left` only", and "`state_gas_reservoir` is passed to a child frame in full: the 63/64 rule applies to
`gas_left` only".

**The consequence.** If a bid or `settle()` is sent with a gas limit above about 16.8M:

- The outbid leader's `receive()` (inside the 150k frame) or the winner's hook (inside the 500k frame) can
  spend the **whole reservoir** on state creation.
- It only has to succeed. A reverted child gets its state gas restored.
- Example: one CREATE of a 24,576-byte contract is about 37.6M state gas for about 12,000 of regular gas.
  The sender pays for it.

**What it does not break.** The F-01 floor and the deferral are unaffected: they run on `gas_left`, which
the child cannot touch beyond its cap. Only the sender's ETH is at risk.

**Why it is only Info.** It needs a sender who sets more than 16.7M gas by hand. The site sends 1.5M and
1.2M. Wallet estimates stay far below, because without a reservoir the hostile code is bounded by the cap.

**Unproven.** forge 1.7.1 has no Glamsterdam EVM, so no test can show this.

**Suggested fix.** The contract cannot see or cap the reservoir. Write it into NATIVE-ETH.md and the site:
never send a bid or `settle` above 16,777,216 gas.

### ETH-5 · Info · A refund owed to an emptied account (same-transaction self-destruct)

`src/auction/EnglishAuction.sol:244`, `:282`.

**The scenario.** A contract can bid from its constructor and self-destruct in the same transaction. Under
EIP-6780 its account is then deleted: no code, no balance, nonce 0. The refund push to it must re-create the
account.

**What it costs.**

- **Today:** 25,000 extra, paid by the rival. Measured with an emulated empty account in
  `testRefundToAnEmptiedAccountRecreatesIt`: 110,855 against 135,855. It fits the 150,000, and the ETH lands
  at a codeless address.
- **Under Glamsterdam:** a new account is 183,600 state gas, which no 150,000 frame can pay without a
  reservoir. The push fails and the refund is **always deferred**.

**Who loses.** Either way, the money can be reached only by redeploying the same init code at the same
address (CREATE2), which only the attacker can do. The rival pays at most the same as against F-06's
gas-burning leader. No honest party loses anything; it is F-06 and F-19 reached a new way.

**Suggested fix.** None needed. Optionally mention it beside F-19.

## Checked and found sound

1. **ETH in.** `bid` is the only payable function. There is no `receive` or `fallback`.
   - `msg.value == amount` must hold exactly (`EnglishAuction.sol:232-234`). The check runs after all
     bookkeeping and before the only external call, and any mismatch rolls back the whole bid.
   - The uint128 bound comes before thirdweb's predicate, and the whole-unit check after it.
   - `minimumBid()` is the smallest accepted whole-unit bid (existing fuzz
     `testFuzzMinimumBidIsTheSmallestAcceptedWholeUnit`; the algebra checked by hand).
2. **ETH out.** There are three paths: the push refund, `withdrawRefund(to)` and `withdrawProceeds(to)`.
   - All three go through `_pay`, and each zeroes its amount or makes it final before the call.
   - `_pay` sends empty calldata, so it cannot call a function.
   - `to` can never be the auction or either token contract, so `_pay` cannot reach `payOutbidRefund` or
     `deliverPrize` with a payload.
3. **No double payment** (`testFuzzEveryLeaderIsPaidExactlyOnceOrNothingChanges`, 512 runs).
   - The test covers six receiver shapes at every gas limit from 30k to 1.63M.
   - Every bid either changes nothing or pays the old bid exactly once: pushed or owed, never both.
   - The balance always equals `liabilities()`, and deferred refunds can be withdrawn.
   - Why it holds: the transfer happens inside the self-call frame. A failure after the transfer (a starved
     frame, a return-data bomb) reverts the transfer before the deferral is recorded.
4. **try/catch.** There is no revert it fails to catch. The target is `this`, which has code; neither
   self-call returns data; `catch {}` decodes nothing. The 63/64 arithmetic of the two floors gives each
   child exactly its cap.
5. **Reentrancy.** Every state-changing entry point is `nonReentrant` under a single storage-slot guard.
   - The two self-calls run under the caller's guard and accept only `msg.sender == address(this)`.
   - From inside the refund callback, the motif mint hook or the 1/1 hook, every guarded function reverts
     (existing tests and the fuzz above).
   - `KilimMotifs.mintMotifs` has its own guard. `KilimOneOfOne.mint` deliberately has none (R-06).
   - The Bazaar holds no ETH and reads only values that are final once `settled` is set. If a Bazaar call
     made inside the winner's hook is part of a failed delivery, it rolls back with it.
6. **Read-only reentrancy.** `liabilities()` reads correctly during the refund push (balance =
   old + new − old ≥ refundLiability + new) and during the prize hook (settled, so proceedsDue).
7. **Accounting.** `liabilities() = refundLiability + (settled ? proceedsDue : highestBid)`.
   - balance − liabilities equals forced ETH only. ETH from selfdestruct or coinbase changes no number
     (existing `testForcedEthDoesNotAlterLiabilitiesOrRewards`; K-06).
   - There is no rounding and no dust: refunds equal bids and proceeds equal the winning bid, to the wei.
8. **Timing.**
   - A bid is open iff `timestamp < endsAt`; `settle` is allowed iff `timestamp >= endsAt`. The two never
     overlap.
   - An extension never brings the close forward.
   - Bids need the count to be exactly 100, and registration closes at 100.
9. **`registerFor`.** No ETH moves.
   - The EIP-712 domain includes the chain id and the auction's address, and OZ rebuilds it if the chain id
     changes.
   - `registered[wallet]` is a one-shot replay guard shared with `register()`.
   - OZ ECDSA refuses high-s signatures. ERC-1271 runs as a staticcall.
   - The deadline is inclusive. A signature can only register its own signer.
   - Sponsor griefing is F-08/W-25, already recorded.
10. **`TreasuryCannotBid`.** Enforced on `msg.sender` in `bid` and on the wallet in `_register`. It also
    holds for an EIP-7702-delegated treasury. Other wallets are K-07/FA-07.
11. **Ordering and MEV.**
    - Front-running or sandwiching a pending bid gains only motif farming (F-07/K-01). The front-runner
      takes the risk of winning at its own price.
    - A late bid always gets 10 more minutes. Stopping it means stuffing or censoring about 50 consecutive
      slots, and the base fee rises 12.5% per full block (about 360× over 50 blocks). The record calls this
      impractical (K-05).
    - The race at the opening bid is ETH-3.

## Notes for the coordinator

- `contracts/out` was not written: its timestamp is still 11 October.
- **`contracts/cache/test-failures` was written at 10:18:42 today** with `test_lifecycleReachesEveryStage`,
  which is not one of these tests (all of mine pass). Forge's default `test_failures_file` is
  `cache/test-failures`, relative to the project, and `FOUNDRY_CACHE_PATH` does not move it. A failing run
  by another reviewer therefore writes into `contracts/cache` despite the override. The same goes for fuzz
  failure persistence (`cache/fuzz`). If the live test cares, other runs could point the
  `test_failures_file` and `fuzz.failure_persist_dir` settings under `.tools-out/` as well (by env var or
  `--config-path`; the env names were not tried here).
