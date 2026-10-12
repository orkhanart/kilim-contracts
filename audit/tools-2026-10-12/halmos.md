# Halmos symbolic tests, 12 October 2026

Bounded symbolic checks of the Kilim contracts with a16z **Halmos 0.3.3** (solver Yices 2.6.4 from Halmos's
own venv; z3 4.12.6 tried on one saved query). Tests: `contracts/security/halmos/` (README there). No
contract source was edited; nothing was committed or uploaded.

**Bottom line.** No bug found. Every check that finished either passed or failed only by design (the
`EXPECTED_FAIL` reachability probes and one overflow demonstration). All three counterexamples that looked
like findings were artefacts of the test or of Halmos (analysed below).

- **Proved, bounded (PASS):** ETH solvency (balance >= `liabilities()`) and the auction state invariants are
  preserved by one call to every entry point, from any symbolic state that satisfies them. The bid is covered
  in two parts: a first bid fully symbolic, an outbid with its two amounts from an 8-row table. Rewards stay
  within maxMotifsPerBid, the pool and amount/unit. Four symbolic bids reserve contiguous ids, never past the
  cap, and `highestBidMotifs()` matches the winning bid. Claims split across ranges mint every reserved id
  exactly once, to the right recipient. `mintMotifs` is exact on the id range and the burned bitmap. In the
  Bazaar: rank and ladder agree for every Master cost and count; the seal window and re-arm hold (history
  branch); the loom lane arithmetic has no carry and fires `CountOverflow` exactly at 65,535; the tally lanes
  and the winning-bid flag are exact. In bounded sequences (depth 2), prize and refund bookkeeping held.
- **Not proven (TIMEOUT):** the bid-increment rule, `minimumBid()` against `_isNewWinningBid`. Every check
  timed out: the predicate divides by symbolic 256-bit values, which Yices and z3 do not decide here. Also
  timed out: outbid solvency with both amounts symbolic, and `rewardForBid` monotone at the mainnet cap.
- **Not finished:** the depth-2 invariant runs for solvency, shape and supply (stopped after hours, no
  counterexample so far). Solvency and shape are covered inductively above.
- **Not explored:** the `seal()` blockhash branch (Halmos 0.3.3 crashes on BLOCKHASH), gas, `registerFor`,
  and all metadata/rendering code.

## Setup

- Source: git `2a63a727` plus one uncommitted change made during the session by another workflow:
  `src/KilimAuction.sol` `PRIZE_GAS` 500,000 -> **1,000,000** (file time 11:05:54, plus comments). The table
  says which value each result was compiled against. Halmos does not meter gas: `PRIZE_GAS` only sets the
  threshold of `gasleft() < PRIZE_GAS + PRIZE_GAS / 63 + 50_000`, whose left side is a fresh symbol either
  way, and the call's gas stipend is ignored. So the explored behaviour is identical under both values. Every
  check that touches `settle()` or the auction's ETH (all of `AuctionSolvencyHalmos`, both invariant suites)
  was run against **1,000,000**.
- forge 1.7.1 (the pinned `node_modules` binary), solc 0.8.37, optimizer 200, cancun.
- Builds went only to `contracts/.tools-out/halmos/{out,cache}`: every forge and Halmos command set
  `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH` there. The mtimes of all 145 files in `contracts/out` were recorded
  before the first build and found unchanged at 10:20 and at 14:15. **At 17:31:48 to 17:32:05, 101 files in
  `contracts/out` (among them `KilimAuction.json` and test artifacts) and `contracts/cache/solidity-files-cache.json`
  were rewritten by another build.** No build of this work ran then: the last ones started at about 16:00, and
  they wrote to `.tools-out`. The timing matches the other workflow's `PRIZE_GAS` and test edits. It matters
  because the live Sepolia test reads ABIs from `contracts/out`. (`contracts/cache/test-failures` changed at
  10:18 and 11:36. Only `forge test` writes it, and this work never ran `forge test`.)
- The machine was heavily shared (load average 20 to 140 on 18 cores), so wall-clock solver limits bit harder
  than on an idle machine. Every TIMEOUT below is at a 300 s per-query limit unless stated.

## Command

From `contracts/` (`run.sh` sets `FOUNDRY_OUT`, `FOUNDRY_CACHE_PATH`, `FOUNDRY_TEST=security/halmos`,
`FOUNDRY_SCRIPT=security/halmos`, `--forge-build-out`, puts forge and yices on `PATH`, runs under `nice -n 10`):

```sh
security/halmos/run.sh --match-contract '^AuctionMathHalmos$' --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^AuctionSolvencyHalmos$' --early-exit --loop 4 --solver-timeout-assertion 600s
security/halmos/run.sh --match-contract '^(RewardForBidHalmos|MotifAllocationHalmos|MotifClaimHalmos|MotifsHalmos)$' --loop 65 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^(BazaarRankHalmos|BazaarLoomHalmos|BazaarMakeHalmos)$' --loop 16 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^BazaarSealHalmos$' --storage-layout generic --solver-timeout-branching 10s --loop 16 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^AuctionInvariant(Fresh|Started)Halmos$' --invariant-depth 2 --loop 4 --solver-timeout-assertion 120s
```

`--early-exit` only shortens failing checks (the probes); a passing check explores everything either way.

## Method in one paragraph

Each `check_` runs the real contract code: the deployed trio (`KilimMotifs`, `KilimOneOfOne`,
`KilimAuction`) built in the deploy script's order over a stand-in store, or an unchanged `EnglishAuction`
behind a harness that only exposes `highestBid` and `_isNewWinningBid`, or `KilimBazaar` against a stand-in
auction (`FakeAuction`) whose final terms can be symbolic. Inputs, and where stated contract storage, are
symbolic (`vm.store` of symbolic values into the slots from forge's storage layout). Where a check's
assertions sit behind an `if` on success, there is a matching **reachability probe**
(`check_reach_*_EXPECTED_FAIL`) that asserts the branch cannot happen; its counterexample shows that the
passing check was not vacuous there. Checks that assert success outright (claims, mints, the fold's
ok path) cannot be vacuous in that way.

## Results

`500k` / `1M` = the `PRIZE_GAS` value compiled in. `n/a` = the check does not deploy `KilimAuction`, or
never calls `settle()`.

### Auction ETH and state (`AuctionSolvency.t.sol`, `AuctionInvariant.t.sol`)

The inductive set S checked after every call: `balance >= liabilities()`; `highestBid == 0` iff
`highestBidder == 0`; a nonzero `highestBid` is a whole unit, >= the reserve, <= uint128 max; `highestBidder`
is never the treasury or the auction; `endsAt != 0` iff started; settled implies started and `now >= endsAt`;
`proceedsDue` is 0 before settlement and 0 or `highestBid` after; the caller's and the leader's refunds sum to at
most `refundLiability`; `motifsAllocated <= motifCap`; `endsAt` never moves back; after settlement
`highestBid`, `highestBidder`, `highestBidMotifs()` never change. Pre-state: all of these slots symbolic and
satisfying S; caller fully symbolic (not the auction, not address(0)); the outbid leader is one of: none, an
EOA, the ETH-rejecting `Rejecter`, the re-entering `Reenterer`; a payout recipient is one of an EOA,
`Rejecter`, `Reenterer`, or each address the auction must refuse; `now` any value in [startsAt, 2^63).

| Check | Result | Bounds / notes | PRIZE_GAS |
|---|---|---|---|
| `check_step_bid_first` | **PASS** (50 paths) | first bid: amount, msg.value, minReward, expectedFirst all symbolic | 1M |
| `check_step_bid_outbid` | **PASS** (3,014 paths; at a 600 s query limit. A first run at 300 s had 1 of 3,253 queries time out; that query, re-run alone, was unsat in under 1 s) | (highestBid, amount) from 8 rows (min steps 10->11->13->15 units, 1 ETH->1.1 ETH, 1 ETH->1.099 ETH refused, 5->5 ETH refused, 93.9->1000 ETH, top of uint128); all else symbolic | 1M |
| `check_step_bid` (all symbolic) | **TIMEOUT** | expected: run stopped after 30 of ~1,300 assertion queries hit 300 s (the predicate's symbolic divisions sit in the path condition) | 1M |
| `check_step_withdrawRefund` | **PASS** (715 paths) | recipient from the set above | 1M |
| `check_step_withdrawProceeds` | **PASS** (541 paths) | | 1M |
| `check_step_settle` | **PASS** (58 paths) | the prize delivery runs (winner = any leader kind) | 1M |
| `check_step_claimPrize` | **PASS** (302 paths) | | 1M |
| `check_step_claimMotifs` | **PASS** (478 paths) | credits 0 here (the claim logic is in `MotifClaimHalmos`) | 1M |
| `check_step_payOutbidRefund` | **PASS** (33 paths) | always refused from outside | 1M |
| `check_step_deliverPrize` | **PASS** (33 paths) | always refused from outside | 1M |
| `check_step_register` | **PASS** (32 paths) | registration closed | 1M |
| `check_step_plainTransferAndUnknownSelector` | **PASS** (34 paths) | plain ETH and selectors 0x00000000, 0xdeadbeef, 0xffffffff, with any msg.value | 1M |
| probes `check_reach_{bidPaidEOA,bidDeferredRejecter,withdrawRefund,settle,withdrawProceeds,claimPrize}` | **FAIL x6, as designed** | each success path is reachable: an outbid paid back to an EOA, an outbid deferred for `Rejecter` (both on the 1 ETH -> 1.1 ETH row), a refund withdrawn, a settlement, proceeds withdrawn, the prize claimed. An earlier code version (symbolic highest bid and leader kind) also reached all six. The final version of the two symbolic-kind bid probes was stopped after 60 min without a counterexample, superseded by the fixed-kind pair | 1M |
| `invariant_prize`, fresh deployment | **PASS** (3,520 paths) | depth 2. Senders: 2 EOAs, `Rejecter`, `Reenterer`, the treasury. Targets: withdrawRefund, settle, withdrawProceeds, claimPrize, payOutbidRefund, deliverPrize, register; handlers for bid (pays for real, see counterexample 4) and claimMotifs (1, 2 or 15); a time step <= 2 days. Cap 40, 15 per bid. prizeClaimed == the 1/1 minted, and only after settlement | 1M |
| `invariant_refundsAddUp`, fresh | **PASS** (3,515 paths) | sum of refunds over all senders == refundLiability | 1M |
| `invariant_prize`, running auction | **PASS** (20,561 paths) | setUp: `Rejecter` leads with 0.01 ETH, 30 s before the close (so an outbid defers its refund, and settle is one time step away) | 1M |
| `invariant_refundsAddUp`, running auction | **PASS** (20,630 paths) | | 1M |
| `invariant_solvent`, `invariant_shape`, `invariant_supply` (both suites) | **NOT FINISHED** (stopped 17:50) | One assertion query per explored state; outbid states carry the predicate's divisions, about 2 s per query. At the stop: fresh `invariant_solvent` had cleared 1,692 of ~3,520 states, running-auction `invariant_solvent` 848 of ~20,600, and the two `invariant_shape` runs about 1,800 and 4,300 states. No counterexample and no query timeout in any of them. `invariant_supply` never started. Solvency and shape are proved one step at a time by `AuctionSolvencyHalmos` above | 1M |

### Bid arithmetic (`AuctionMath.t.sol`; harness over the unchanged `EnglishAuction`)

| Check | Result | Bounds / notes | PRIZE_GAS |
|---|---|---|---|
| `check_firstBid_reserveExact` | **PASS** | any amount: before the first bid the minimum is 0.01 ETH and the predicate accepts exactly amounts >= it | n/a |
| `check_minimumBid_accepted_bps1000_T1` | **TIMEOUT** | `minimumBid()` is accepted by `_isNewWinningBid`; highest bid a whole unit in [0.01 ETH, 2^20 units) | n/a |
| `check_minimumBid_accepted_bps10000_T1` | **TIMEOUT** | same at 100% increment | n/a |
| `check_minimumBid_least_bps1000_T1` | **TIMEOUT** | no smaller whole-unit amount is accepted | n/a |
| `check_minimumBid_above_bps1000_T1` | **TIMEOUT** | every whole-unit amount >= `minimumBid()` is accepted | n/a |
| `check_isNewWinningBid_monotone` | **TIMEOUT** | current < 2^80, amounts <= uint128, bps 1..10000 | n/a |
| `check_isNewWinningBid_noPanic` | **TIMEOUT** | under `_handleBid`'s bounds the predicate never panics | n/a |
| `check_minimumBid_noRevert` | **TIMEOUT** | `minimumBid()` never reverts for highest bid <= uint128 max | n/a |
| `check_isNewWinningBid_unboundedPanics_EXPECTED_FAIL` | **FAIL, as designed** | see counterexample 2 | n/a |

The saved timed-out queries of `monotone`, `noPanic`, `above`, `least` and `noRevert` were re-run standalone
with Yices for 1,800 s each: all still `unknown`. z3 4.12.6 also gave up on the `noPanic` query (240 s). The reason: solc's
checked `(incoming - current) * MAX_BPS` tests overflow by dividing by the symbolic left operand, and the
predicate then divides by `current`. Bit-blasting solvers do not decide 256-bit division by a symbolic
value at this size. A variant with a CONCRETE highest bid and a symbolic amount timed out the same way,
because the overflow test still divides by the amount. Variants for other increments and a 2^37-unit tier
were removed after the first tier timed out. Not tried: Halmos's `bitwuzla-abs` solver, which abstracts
nonlinear arithmetic. Halmos downloads it on first use, and downloads were out of scope here.

### Motif credits and supply (`MotifCredits.t.sol`, `Motifs.t.sol`)

| Check | Result | Bounds / notes | PRIZE_GAS |
|---|---|---|---|
| `check_rewardForBid_mainnet` / `_fixture` | **PASS** / **PASS** | any amount <= uint128 max, any `motifsAllocated <= cap`: reward == min(amount/unit, maxPerBid, cap - allocated), never above any of the three, and 0 for a bid >= reserve only when the pool is empty. Mainnet: cap = maxPerBid = 1,000,000; fixture: 10,000 / 1,000 | 500k (no settle) |
| `check_rewardForBid_monotone_fixture` | **PASS** | | 500k |
| `check_rewardForBid_monotone_mainnet` | **TIMEOUT** | the one timed-out query re-run alone for 1,800 s: still `unknown`. The fixture version passes; the mainnet one has amount / 0.001 ETH twice at the full uint128 range | 500k |
| `check_allocation_fourBids` | **PASS** (859 paths) | 4 bids A, B, A, B with symbolic amounts (< 10^9 units), cap 26, 12 per bid: reward == the prior quote; ids contiguous from 1 in bid order; `highestBidMotifs()` == that bid's ids (0,0 when it earns none); credits and ranges add up; never past the cap | 500k (no settle) |
| `check_expectedFirstMotifId` | **PASS** | first bid, any whole-unit amount <= 10^24 wei: accepted iff expectedFirstMotifId is 0 or the true first id | 500k |
| `check_reach_poolExhausted_EXPECTED_FAIL` | **FAIL, as designed** | 4 bids that exhaust the pool exist | 500k |
| `check_claim_twoParts` | **PASS** (365 paths) | setUp reserves A 1..10, B 11..21, A 22..26 (cap binds). A claims q1 = 1..15 (each value a path) to R1, then the rest to R2: both claims succeed, the cursor and leftover ranges are exact, every one of A's 15 ids is minted once to the right recipient in order, B's ids, id 0 and ids past the cap stay unminted, a further claim reverts | 500k |
| `check_claim_quantityLimits` | **PASS** | 0, above credits or above 64 reverts for any caller | 500k |
| `check_mint_rangeExact` | **PASS** (664 paths) | any firstId, quantity 1..64 (loop 65): `SupplyExceeded` exactly when the range leaves 1..1,000,000; inside, the whole range is minted and nothing next to it | n/a |
| `check_mint_neverTwice` | **PASS** | two mints of 1..4 ids anywhere in range: the second succeeds iff the ranges are disjoint, else `AlreadyMinted` | n/a |
| `check_burn_bitmapExact` | **PASS** | any id and any other id: only the owner can burn (an approved address cannot); the bitmap marks exactly that id; it can never be minted again; other ids are unaffected | n/a |
| `check_mint_onlyMinter`, `check_mint_quantityLimits` | **PASS**, **PASS** | | n/a |

### Kilim Bazaar (`Bazaar.t.sol`; stand-in auction)

| Check | Result | Bounds / notes | PRIZE_GAS |
|---|---|---|---|
| `check_rank_matchesPageRule` | **PASS** | any Master cost in [10, uint128/unit], any counts: rank == the page's rule; monotone in the count; `masterCost()` == the cost | n/a |
| `check_rank_agreesWithLadder` | **PASS** | `ladder()` lists each fixed cost iff below the Master's; a count earns rank r in 1..5 only if r's cost is listed, at or under the count, with the next listed cost above it; the Master exactly from its cost up; nothing under 10 | n/a |
| `check_beforeSettlement`, `check_quantityFloor`, `check_blockedRecipients` | **PASS** x3 | every length 0..9 refused before any motif moves; no loom -> `NoLoom`; the zero address and the four contracts can never receive a kilim | n/a |
| `check_make_tallyRankAndFlags` | **PASS** | any tally (each 32-bit lane < 2^32 - 1), any Master cost, any winning range: token id, number, hand key from the right lanes, no other lane touched; winning-bid flag exactly when every burned id is in [first, first + won) | n/a |
| `check_reach_makeMaster`, `check_reach_makeWinningBid` | **FAIL, as designed** | both branches reachable | n/a |
| `check_fold_oneId`, `check_fold_twoIdsSameMotif` | **PASS**, **PASS** | any prior lane counts in the touched word, loom count, title, titleCount, distinct: the lane rises by exactly 1 (or 2), no carry and no other lane touched; `CountOverflow` exactly when the lane would pass 65,535; count via SafeCast; title, titleCount and distinct follow the page rule; min and max id update | n/a |
| `check_reach_foldOk`, `check_reach_foldOverflow` | **FAIL, as designed** | both branches reachable | n/a |
| `check_seal_window8191`, `check_seal_window256` | **PASS**, **PASS** | any blocks n1 <= n2 < 2^40 - 2: two `seal()` calls do what `sealState()` says (wait, re-arm only past the window to n + 1, seal only from a nonzero hash, read from the EIP-2935 contract with fully symbolic storage); a sealed seed never changes. **The blockhash branch (age 1..256) is excluded** (see Halmos limits) | n/a |
| `check_reach_sealFromHistory`, `check_reach_rearmThenSeal`, `check_reach_rearm256` | **FAIL, as designed** | each path reachable | n/a |

`BazaarRankHalmos` uses a stand-in auction with a 1-wei unit, so the Master's cost equals the symbolic
winning bid. With the real 0.001 ETH unit, `check_rank_agreesWithLadder` TIMED OUT, because the solver then
has to invert `units * 0.001 ETH / 0.001 ETH`. The rank logic only ever sees that quotient.
`BazaarMakeHalmos` uses the real unit and passed.

## Counterexamples analysed

1. **`check_minimumBid_noRevert`, first version: test artefact.** Counterexample highest bid
   `0x6041106e383dc` wei, about 0.00169 ETH: `minimumBid()` returns 0.002 ETH, below the reserve. The test had
   asserted `minimumBid() >= reserve` for any highest bid, but a highest bid under the reserve is unreachable:
   every accepted bid is >= 0.01 ETH. The assertion is now limited to reachable highest bids.
2. **`check_isNewWinningBid_unboundedPanics_EXPECTED_FAIL`: by design, not a bug.** current = 2^255,
   incoming = 3 * 2^254: `(incoming - current) * 10000` overflows and the unchanged thirdweb predicate panics.
   `_handleBid` rejects any amount above uint128 max before it calls the predicate
   (`src/auction/EnglishAuction.sol:211`), and every stored highest bid is <= uint128 max, so this is
   unreachable. The check documents why that bound must stay first.
3. **`AuctionSolvencyHalmos`, first version: test artefact.** caller = `address(0)`, no prior bid, a bid of
   about 3.0e38 wei accepted: `highestBidder` becomes `msg.sender` = 0 while `highestBid > 0`. That breaks
   "highestBid == 0 iff highestBidder == 0". No transaction can come from address(0), so it is unreachable on
   chain. The symbolic caller now excludes it. (For the record, the contract keys "started" on
   `highestBidder != 0`, at `EnglishAuction.sol:206`.)
4. **`invariant_solvent`, first run: a Halmos artefact.** Counterexample at depth 1: `Rejecter` calls
   `bid` directly with msg.value = amount, about 3.0e38 wei, and afterwards balance < `liabilities()`.
   Halmos 0.3.3 gives a direct invariant call its msg.value but never moves the ETH (`SEVM.run_message` does no
   value transfer), so the auction recorded a bid it was never paid. Bids now go through a handler on the test
   contract that makes an inner `call{value: amount}`, which Halmos does transfer, from the sender's balance.
   Every other target is non-payable, so a direct call with value reverts there. All invariant suites were
   rerun after the fix; the earlier invariant PASSes were discarded, because under the missing transfer an
   outbid refund could never be paid, only deferred.

No other counterexample was found.

## Halmos limits met (and what was done)

- **BLOCKHASH crashes Halmos 0.3.3** (`Z3Exception: parser error`: `f_blockhash` is applied to Halmos's own
  BV wrapper). The seal checks assume each seal happens either at or before the seal block, or more than 256
  blocks after it, so the blockhash branch is never executed. With the default 1 ms branching limit, Halmos
  still walked into that branch on unknown feasibility. Hence `--solver-timeout-branching 10s` for the seal
  run.
- **Symbolic storage slot**: the EIP-2935 contract reads slot `sb % 8191`, and after a re-arm `sb` is
  symbolic. The default `solidity` storage model cannot place that slot, so the seal run uses
  `--storage-layout generic`.
- **Symbolic `CALLDATACOPY` size**: `KilimAuction._claim` allocates arrays of length `quantity`, which
  Halmos cannot copy at a symbolic size. Claim quantities are split into concrete paths (`q == c` for
  c = 1..15, or 1, 2, 15 in the invariant handler). That is equivalent over that range.
- **Symbolic 256-bit division** (see Bid arithmetic): the reason for the TIMEOUTs. Whole-unit amounts are
  stated as `amount % unit == 0`, not as `units * unit`, which the solver cannot invert. That change took
  `check_expectedFirstMotifId` from TIMEOUT to PASS in 3 s.
- **No value transfer on direct invariant calls** (counterexample 4): bids go through a paying handler.
- **Path explosion** from `&&`, `?:` and checked arithmetic in the test's own pre- and post-conditions. Every
  JUMPI on a symbolic value forks. The solvency checks combine conditions branch-free (`_and`, `_imp`, `_ite`
  in `HalmosBase.sol`).

## What is NOT covered

- **Bounded, not unbounded.** A PASS holds only inside its bounds: the loop bounds (`--loop`), the
  concrete splits above, the value ranges in each check's `vm.assume`, the receiver kinds, the 8-row outbid
  table, and invariant depth 2 (with only `invariant_prize` and `invariant_refundsAddUp` finished). Nothing
  outside them.
- **The bid-increment rule is unproven**: the `AuctionMathHalmos` TIMEOUTs. The existing Foundry tests and
  fuzzing (`test/KilimAuction.t.sol`, `test/LaunchConfig.t.sol`) remain the evidence for "minimumBid() is the
  smallest accepted whole-unit bid".
- **Outbid solvency with both amounts symbolic** (`check_step_bid` TIMEOUT). It is covered for the first bid
  (fully symbolic) and for the 8 table rows (everything else symbolic). The depth-2 `invariant_solvent`
  runs were stopped unfinished.
- **Gas.** Halmos does not meter gas. `gasleft()` is a fresh symbol, so both sides of the `InsufficientGas`
  tests are explored, but the 150,000-gas refund call, the 1,000,000-gas prize delivery and any out-of-gas
  inside them are not modelled. A gas-burning receiver is equivalent here to a reverting one, which `Rejecter`
  covers. The gas floors are `test/GasFloors.t.sol`'s job.
- **Account balances above 2^128 wei** (Halmos assumes none).
- **Block hashes.** The blockhash branch of `seal()` (age 1..256) is not explored. In the history branch the
  EIP-2935 storage is fully symbolic (it can hold 0), a superset of the chain.
- **Not exercised at all:** `registerFor` (EIP-712; registration is closed in every state checked, but the
  signature path was not explored); every `tokenURI` / `svg` / `pieceOf` / `contractURI` / `_respondWithPage`
  assembly path; `KilimOneOfOne` beyond `mint`; `royaltyInfo`; the Bazaar's PACKED/DENSE hand encoding and
  `handOf`; `make` beyond the one 10-id hand checked, `deposit` beyond 1 or 2 new ids, any length near
  `MAX_BATCH` (the 16-bit in-memory lanes are carry-free up to 65,535 ids by argument, not by proof here);
  the deploy script.
- **The Bazaar runs against a stand-in auction**, so its terms can be symbolic. That the real auction's terms
  are final after settlement is the "final terms" clause of S above.
- **Tally lanes at 2^32 - 1** and **block numbers >= 2^40 - 2** are excluded (`uint40(block.number + 1)` would
  truncate). Neither is reachable: at most 100,000 kilims on mainnet, and 2^40 blocks is about 400,000 years.
