# Certora Prover, local build: Kilim auction (12 October 2026)

**Result: the open-source Certora Prover 8.19.2 was built from source on this machine and runs locally.
68 properties of the auction (and, as a stretch, of Kilim Bazaar's rank rule and seal) were written in
CVL; all 68 are verified, none violated, none timed out in the final runs. No real bug was found.**
Every counterexample the prover produced along the way was a spec artefact, analysed below. Fifteen
hand-made mutants (one-line bugs in a copy of the sources) check that the specs bite: all 15 are caught.

Nothing was sent to Certora's cloud: the confs have no `server`, `run.sh` passes the local jar and unsets
`CERTORAKEY`, no key exists on this machine, and the jar's AWS event stream is off. This work edited
nothing under `src/`, `test/`, `script/`, `deploy/`, `scripts/` or `foundry.toml`, never ran forge, and
wrote nothing to `contracts/out` or `contracts/cache`: the prover compiles with solc into
`security/certora/work/`. (The `src/KilimAuction.sol` and `test/` edits and `cache/test-failures` that
appeared during the run belong to the separate PRIZE_GAS workflow.)

Specs, confs, harnesses and the exact commands: [`security/certora/`](../../security/certora/README.md).
Raw results: `security/certora/results/` (`<spec>.summary.txt` one line per rule and method,
`<spec>.output.json`, `<spec>.log`).

## Code under verification

Commit `2a63a727` (11 October) plus one working-tree change made by a separate workflow during this run:
`KilimAuction.PRIZE_GAS` raised from 500,000 to 1,000,000 (settle floor 1,065,873), with comments.

| File | sha256 of the final runs | Development runs |
| --- | --- | --- |
| `src/auction/EnglishAuction.sol` | `d6caa7b578c540095ac7105b1e31e3da1ed2b7700dc75f919f33ec1590f7d812` | same |
| `src/KilimAuction.sol` | `47d6e475f2391b334808b2ce525e0e996e06d387f91d6752fd25f4bab047a6d0` (PRIZE_GAS 1,000,000) | `45072956ff7fe3a9770457272ebcd6554988b2f2417bd9a7417975954fdbc118` (PRIZE_GAS 500,000, as committed) |
| `src/KilimBazaar.sol` | `b0f12fbf054b4b8a1a52df9ba7bfe201d3fae791dac9c400ada27dd9bd08b3a9` | same |

**The results below are from the final runs, on PRIZE_GAS = 1,000,000** (`results/sources.sha256`); the
first round of runs and the first mutant round used 500,000. The value cannot change any result: the
prover does not model gas (`gasleft()` is nondeterministic, the `{gas: …}` stipend is ignored), so the
two versions have the same verification conditions.

Compiled by the prover with solc 0.8.37, optimizer 200 runs, EVM `cancun`, no via-IR (the `foundry.toml`
profile), OpenZeppelin 5.6.1 from `node_modules`.

## Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Certora Prover | 8.19.2, tag commit `63fdea80a35b` | built with `./gradlew assemble` (Gradle 7.2 wrapper, 3 min); `emv.jar` sha256 `4f93d84e…6907` |
| tac_optimizer (fried-egg) | from the same tag | built by the Gradle task with cargo |
| JDK | Temurin 21.0.12.1+1 (runs Gradle and the prover), Temurin 19.0.2+7 (the build's pinned Gradle compile toolchain, `java.version=19`) | both macOS aarch64 from Adoptium, sha256 checked |
| Z3 | 4.15.4 arm64-osx | GitHub release, sha256 checked |
| cvc5 | 1.4.2 macOS arm64 static | GitHub release, sha256 checked |
| Rust | 1.99.0 via rustup (minimal), rustfilt 0.2.1 | under `~/.local/certora`, `--no-modify-path` |
| Python | 3.12.13 venv, `certora_cli_requirements.txt` | uv |
| solc | 0.8.37+commit.f401782d | Foundry's svm copy, linked as `solc8.37` |

Everything lives under `~/.local/certora` (no sudo, no Homebrew, no shell profile edits);
`~/.local/certora/env.sh` sets the paths for one shell. The README example
(`Public/TestEVM/CVLCompilation/OptionalFunction`) reproduces its expected result, and
`Public/TestEVM/Counter` verifies both rules, matching `expectedcounter.json`. One deviation from the README
was needed: the build pins a Java 19 Gradle toolchain, so a second JDK (19) was installed and registered in
`~/.local/certora/gradle-home/gradle.properties` with auto-download off. llvm-symbolizer, llvm-dwarfdump and
Graphviz were skipped (Solana and report rendering only).

The jar enables an AWS SQS event stream by default (`-enableEventReporting`, queue `events.fifo`). With no
AWS credentials on this machine it cannot send anything, and every conf now passes
`-enableEventReporting false`. Nothing else in the local path talks to the network: certoraRun skips its
PyPI version check in local mode, and the cloud path needs a `CERTORAKEY`.

## Model and assumptions

Scene: `KilimAuctionHarness` (KilimAuction unchanged, plus two views: the reentrancy guard state and the
upstream bid predicate `_isNewWinningBid` applied to an amount) and `OneOfOneMock`.

| What | How it is modelled | Why it is sound enough |
| --- | --- | --- |
| `KilimMotifs.mintMotifs` | CVL summary: records the quantity, the `bidder` argument and whether an id falls outside `1..motifsAllocated`; may revert (a receiver that refuses) | The motif contract's own checks (ids unique, never re-minted) are not part of this run |
| `KilimMotifs.MAX_MINT_BATCH` | returns 64 | the constant |
| `KilimOneOfOne.mint` | dispatched to `harness/OneOfOneMock.sol`, which counts mints and may reject any recipient (a symbolic `rejects` map) | the real mint additionally refuses everyone but the auction and refuses a second mint |
| ETH transfer in `_pay` | unresolved call, prover default: may fail; other contracts' state and balances are havocked; the auction's storage untouched; its balance can only rise during the call | the "no reentrant state change" part is proved separately: `SelfCalls.reentryReverts` shows every state-changing entry point reverts while the guard is held, for any caller but the auction |
| `payOutbidRefund`, `deliverPrize` | inlined where `bid` and `settle` make the self-call (try/catch included); excluded from invariants as top-level calls | `SelfCalls` proves both revert for every caller but the auction |
| Immutables | symbolic; `configOk()` requires what the constructors enforce (reserve = 0.01 ETH, 1 ≤ incrementBps ≤ 10,000, 0 < extensionWindow ≤ duration ≤ 30 days, treasury not zero/self/token, 0 < maxMotifsPerBid ≤ motifCap ≤ 2^32 − 1) | immutables never change after the constructor; the cap bound is KilimMotifs' constructor check |
| Transactions | `msg.sender` is not the auction and not `address(0)`; `block.timestamp ≤ 2^64 − 1` | the auction calls itself only from inside `bid`/`settle` |
| Time | for `proceedsAreTheWinningBid` only: once settled, later transactions have `timestamp ≥ endsAt` | block timestamps never decrease; settlement needed `timestamp ≥ endsAt` and only a bid (impossible after the close) moves `endsAt` |
| Gas | `gasleft()` is nondeterministic; the 150,000 refund and 1,000,000 prize stipends and the EIP-150 reserve are not modelled | a receiver that burns its gas is the same as one that reverts: the call fails |
| ETH paid out | a `CALL` hook records every successful value-carrying call the auction makes, in total and per recipient | measures payments exactly, where the balance alone cannot (the havoc lets it rise during the call) |
| Loops | `optimistic_loop`, `loop_iter` 3 (auction) / 6 (Bazaar) | `claimMotifs` is checked for claims that touch at most 3 credit ranges; longer claims are assumed away (see "Not covered") |
| `Math.mulDiv(x, y, d, Ceil)` | MinimumBid.spec only: replaced by its definition `ceil(x·y/d)` | its one call site has `x ≤ 2^128`, `y ≤ 10,000`, so `x·y < 2^256` |

Ledger sums use ghost mirrors of `refunds` and `motifCredits` (Sstore/Sload hooks) and `usum`, which also
knows a total is at least any single entry.

## Results

All runs on 12 October 2026, final specs. "Verified" for an invariant means the constructor base case and
the induction step for each of the 8 auction entry points (`bid`, `claimMotifs`, `claimPrize`, `register`,
`registerFor`, `settle`, `withdrawProceeds`, `withdrawRefund`). Every rule also passed the prover's
`rule_sanity basic` vacuity check.

### Solvency.spec: 13 invariants, all verified

| Invariant | Statement |
| --- | --- |
| `solvency` | `nativeBalances[auction] >= liabilities()` (= `refundLiability + (settled ? proceedsDue : highestBid)`) |
| `refundLiabilityIsSumOfRefunds` | `refundLiability == Σ refunds[a]` |
| `refundAtMostLiability(a)` | `refunds[a] <= refundLiability` (so `withdrawRefund` never fails on its subtraction) |
| `noBidderNoBid` | no highest bidder ⇒ `highestBid == 0 && endsAt == 0` |
| `settledHasWinner` | `settled ⇒ highestBidder != 0` |
| `proceedsAreTheWinningBid` | `proceedsDue == 0 || (settled && proceedsDue == highestBid)` (time assumption) |
| `highestBidBounded` | `highestBid <= 2^128 − 1` |
| `registrationCountBounded` | `registrationCount <= 100` |
| `registrationCountMatchesRegistered` | `registrationCount` = number of registered wallets |
| `bidsOnlyAfterRegistration` | a highest bidder exists ⇒ `registrationCount == 100` |
| `prizeOnlyAfterSettlement` | `prizeClaimed ⇒ settled` |
| `prizeMintedAtMostOnce` | number of 1/1 mints == `prizeClaimed ? 1 : 0` |
| `guardIdle` | the reentrancy guard is idle between transactions |

### Auction.spec: 10 rules, all verified

| Rule | What it proves for every successful call |
| --- | --- |
| `bidRaisesHighestBid` | the bid becomes the highest, strictly above the old one; `msg.value == amount`; whole 0.001 ETH units; `≤ 2^128 − 1`; 100 registrations; not the treasury |
| `bidTiming` | no bid at or after the close; the first bid sets `endsAt = now + duration`; the close never moves earlier; a later bid leaves `endsAt ≥ now + extensionWindow` |
| `bidRefundsOutbidBidder` | the outbid bid is either sent to the outbid bidder, exactly that amount and no ETH to anyone else, or (if that payment fails) added in full to their deferred refund and to `refundLiability`: never both, never neither; no other refund entry changes |
| `withdrawRefundPaysOnlyOwed` | sends exactly the caller's own refund (> 0) to the chosen address and nothing else, clears it, lowers the total by it, touches no other refund; recipient not zero, the auction or a token contract |
| `withdrawRefundOnce` | a second withdrawal by the same caller reverts |
| `settleOnlyAfterCloseOnce` | needs a bid, `timestamp ≥ endsAt`, not settled; sets `proceedsDue = highestBid`; does not move the outcome; a second `settle` reverts |
| `withdrawProceedsOnlyTreasuryOnce` | only the treasury, only after settlement; sends exactly the winning bid (> 0) to the chosen address and nothing else; refunds untouched; a second call reverts |
| `withdrawProceedsRevertsForOthers` | any other caller reverts |
| `claimPrizeOnlyWinnerOnce` | only the winner, only after settlement, only if not yet delivered; exactly one mint, to the chosen address; a second claim reverts |
| `settleDeliversPrizeOrLeavesItClaimable` | settlement either mints the 1/1 once to the winner (`prizeClaimed`) or mints nothing and leaves it claimable |

### MinimumBid.spec: 4 rules, all verified (with the `mulDiv` summary)

| Rule | Statement |
| --- | --- |
| `minimumBidIsAccepted` | `minimumBid()` always passes the upstream bid predicate |
| `nothingBelowMinimumIsAccepted` | no whole-unit amount below `minimumBid()` passes it |
| `bidAtLeastMinimumBid` | every accepted bid is at least the `minimumBid()` quoted just before |
| `launchLadder` | at 10%: 0.01 → 0.011 → 0.013 ETH |

Without the summary, the same assertion inside `bidRaisesHighestBid` timed out after 622 s (83 split
problems): OpenZeppelin's 512-bit `mulDiv` is too much for the solvers. With it, all four finish in 85 s.

### Motifs.spec: 4 invariants and 3 rules, all verified

| Property | Statement |
| --- | --- |
| `motifAllocationWithinCap` | `motifsAllocated <= motifCap` |
| `creditsMatchAllocation` | `Σ motifCredits[a] == motifsAllocated − motifsClaimed` (hence `motifsClaimed <= motifsAllocated`) |
| `mintedEqualsClaimed` | motifs handed to `mintMotifs` == `motifsClaimed` |
| `mintsOnlyForTheClaimer` | `mintMotifs` is never called with a `bidder` other than the claimer |
| `bidAllocatesReward` | a bid gives the bidder exactly `rewardForBid(amount)` = min(units, maxMotifsPerBid, cap − allocated), ≥ `minimumReward`; ids continue the allocation order (`first = allocated + 1`), match `highestBidMotifs()` and the `expectedFirstMotifId` guard; nobody else's credits change |
| `claimMotifsNeverExceedsCredits` | a claim is 1..64, at most the caller's credits, mints exactly that many, all for the caller, and spends exactly that many credits; nobody else's change |
| `claimMoreThanCreditsReverts` | more than the caller's credits reverts |

### MotifRanges.spec: 5 invariants, all verified

Hooks mirror the private `_creditRanges` arrays, their lengths, the cursors and `motifsAllocated`.

| Invariant | Statement |
| --- | --- |
| `rangesWithinAllocation` | every reserved range satisfies `1 ≤ nextId` and `nextId + remaining ≤ motifsAllocated + 1` |
| `mintsInsideAllocation` | so `mintMotifs` is never asked for an id outside `1..motifsAllocated` |
| `rangeCountBounded(b)` | a bidder has at most `motifsAllocated` ranges |
| `cursorSplitsRanges(b)` | ranges before the cursor are used up, ranges from the cursor to the end are nonempty, nothing past the end |
| `creditsAreTheUnclaimedRanges(b)` | `motifCredits[b] == Σ remaining` of b's ranges: a claim of at most the credits always finds its ids |

### SelfCalls.spec: 4 rules, all verified

| Rule | Statement |
| --- | --- |
| `payOutbidRefundOnlyBySelf` | any caller but the auction reverts |
| `deliverPrizeOnlyBySelf` | any caller but the auction reverts |
| `reentryReverts` | while the guard is held, all 10 state-changing entry points revert for any caller but the auction |
| `payOutbidRefundMovesOnlyAmount` | when the auction calls it: at most `amount` leaves, no auction state changes |

On "payOutbidRefund only pays an existing deferred refund": the function never pays a *deferred* refund.
It is the automatic refund of the bid just outbid, and only `bid` reaches it (the two `OnlyBySelf` rules);
there it pays the outbid bidder at most the outbid bid, and if that payment fails the same amount becomes
a deferred refund (`bidRefundsOutbidBidder`). Deferred refunds leave only through the owner's
`withdrawRefund` (`refundsChangeOnlyByOutbidOrOwner`, `ethLeavesOnlyThroughPayouts`).

### Parametric.spec: 9 rules × 8 entry points, all verified

| Rule | Only … |
| --- | --- |
| `onlyBidMovesTheAuction` | `bid` changes `highestBid`, `highestBidder`, `endsAt`; the bid and the close never go down |
| `onlySettleSettles` | `settle` sets `settled`; nothing clears it |
| `proceedsChangeOnlyBySettleOrTreasury` | `settle` raises `proceedsDue`; only `withdrawProceeds` by the treasury lowers it, to 0 |
| `refundsChangeOnlyByOutbidOrOwner` | `refunds[u]` rises only in a `bid` that outbids `u`, by exactly the outbid bid; falls only by `u`'s own `withdrawRefund`, to 0 |
| `refundLiabilityChangesOnlyByBidOrWithdraw` | `bid` raises, `withdrawRefund` lowers the refund total |
| `ethLeavesOnlyThroughPayouts` | ETH leaves (balance or a successful value-carrying call) only in `bid` (the outbid refund), `withdrawRefund`, `withdrawProceeds` |
| `creditsChangeOnlyByBidOrOwnClaim` | credits rise only for the bidder in `bid`, fall only for the claimer in `claimMotifs`; `motifsAllocated` only in `bid`, `motifsClaimed` only in `claimMotifs`, both only grow |
| `prizeClaimedOnlyBySettleOrClaim` | `settle` or `claimPrize` set `prizeClaimed` and mint the 1/1; nothing clears it |
| `registrationOnlyByRegister` | `register`/`registerFor` register, one wallet at a time; a registration is never undone |

### Reachability.spec: 9 witnesses, all satisfied

The model can reach: a refund paid straight back (the balance drops by exactly the old bid net of the new),
a refund deferred, settlement that delivers the 1/1, settlement whose delivery fails, a claim across two
credit ranges, a refund withdrawal (balance drops by exactly the amount), a proceeds withdrawal, a
sponsored registration, and the 100th registration followed by the first bid. So the safety rules above
are not passing because a path was cut away.

### Bazaar.spec (stretch): 7 rules, all verified

The auction is not in the scene: `settled()` and `highestBid()` are fixed ghost values per rule (a whole
number of units, at least the reserve), `motifPrice = 0.001 ETH`.

| Rule | Statement |
| --- | --- |
| `rankZeroOnlyUnderFloor` | rank 0 exactly when count < 10; rank ≤ 6 |
| `rankMonotone` | more motifs never make a lower rank |
| `masterExactlyAtTop` | `masterCost() = highestBid / 0.001 ETH`; the Master exactly when count ≥ it |
| `fixedRankIsHighestCostReached` | below the Master, rank r means cost(r) ≤ count < cost(r+1) (10, 30, 100, 300, 1000) |
| `rankForRevertsBeforeSettlement` | no rank before settlement |
| `ladderAgreesWithRankFor` | each nonzero ladder cost reaches its own rank; a zeroed cost is one the Master undercuts |
| `sealOnlySeals` | `seal()` never touches the tally, a kilim's hand, rank or number, never creates a kilim, never changes a sealed kilim, and sets no flag but SEALED |

## Counterexamples analysed

None of the violations was a bug in the contracts. Each is listed with the fix to the spec.

1. **`refundLiabilityIsSumOfRefunds`, constructor base case.** The `usum` ghost started at an arbitrary
   value. Fixed with an `init_state` axiom that the sum starts at 0.
2. **`proceedsChangeOnlyBySettleOrTreasury` on `settle()`.** The prover started from an unreachable state:
   `settled = false` with `proceedsDue = 1`. `settle` then lowered `proceedsDue` to `highestBid = 0`. Fixed
   by assuming the verified invariant `proceedsAreTheWinningBid`.
3. **`cursorSplitsRanges` on `bid()`.** The prover started from a bidder with `2^256 − 1` credit ranges,
   where `push` would wrap the length. Unreachable: each range needs a bid that allocates at least one
   motif. Fixed with the new invariant `rangeCountBounded` (ranges ≤ motifs allocated, ≤ 2^32).
4. **`mintsInsideAllocation` on `claimMotifs()`.** The hook mirror of `motifsAllocated` (1) differed from
   storage (0) because `claimMotifs` never reads that slot. Fixed by tying mirror to storage in the
   preserved blocks.
5. **`prizeMintedAtMostOnce` and `reentryReverts` on `OneOfOneMock.mint`.** Once the stand-in was in the
   scene, the parametric checks also called its `mint` directly. The real `KilimOneOfOne.mint` accepts only
   the auction, so the checks are now limited to the auction's entry points.
6. **`bidRaisesHighestBid`: timeout**, not a violation: see MinimumBid above.

**A modelling trap worth knowing (prover behaviour, not a contract bug).** The first model summarised
`KilimOneOfOne.mint` with a CVL function that could `revert`. The witness "settlement whose 1/1 delivery
fails" was then unreachable: a probe with a summary that always reverts made `settle()` never succeed. In
this build, a CVL `revert` inside the summary of a call made within the auction's own
`try this.deliverPrize() {} catch {}` was not caught by that try/catch; it reverted the whole transaction.
A Solidity-level revert in the same place is caught (the deferred-refund path, `payOutbidRefund` failing
inside `try`, was reachable throughout). Rules proved with that model on the "delivery fails" branch would
have been vacuously true. The final model dispatches the mint to a Solidity stand-in that reverts in
Solidity, and the witness is reachable. Worth reporting to Certora with the probe; it does not affect the
contracts.

## Mutants

`security/certora/mutants.py` copies `src/` to `work/mutants/<id>/src` (gitignored), makes one edit there,
and runs the named spec against the copy. The frozen `src/` is never touched. Final round, on the
PRIZE_GAS 1,000,000 sources (`results/mutants.txt`):

| Mutant | Bug | Caught by |
| --- | --- | --- |
| `settle-twice` | `settle()` can run again after the proceeds were paid | `solvency`, `prizeMintedAtMostOnce` (on `settle`) |
| `proceeds-not-zeroed` | `withdrawProceeds` pays without clearing `proceedsDue` | `solvency` (on `withdrawProceeds`) |
| `refund-not-cleared` | `withdrawRefund` pays without clearing the refund | `refundLiabilityIsSumOfRefunds` |
| `deferred-not-counted` | a deferred refund is not added to `refundLiability` | `refundAtMostLiability`, `refundLiabilityIsSumOfRefunds` |
| `deferred-not-recorded` | a deferred refund is added to the total but not to the bidder | `refundLiabilityIsSumOfRefunds` |
| `refund-dropped` | a failed push refund is silently dropped; the books still balance | `bidRefundsOutbidBidder` |
| `refund-twice` | a paid refund is also recorded as deferred | `solvency` (on `bid`) |
| `no-close-check` | bids accepted after the close | `bidTiming` |
| `refund-wrong-bidder` | the outbid amount goes to the new bidder | `bidRefundsOutbidBidder` |
| `self-call-open` | anyone can call `payOutbidRefund` | `payOutbidRefundOnlyBySelf` |
| `treasury-check-dropped` | anyone can withdraw the proceeds | `withdrawProceedsOnlyTreasuryOnce`, `withdrawProceedsRevertsForOthers` |
| `reward-uncapped` | rewards ignore the motif cap | `motifAllocationWithinCap` |
| `claim-keeps-credits` | `claimMotifs` mints without spending credits | `claimMotifsNeverExceedsCredits`, `creditsMatchAllocation` |
| `prize-claim-twice` | the winner can claim the 1/1 again | `prizeMintedAtMostOnce` |
| `withdraw-unguarded` | `withdrawRefund` loses `nonReentrant` | `reentryReverts` |

The first round (13 mutants, `results/mutants-round1.txt`) had one survivor, and it exposed a real gap in
the specs, not in the contracts. `deferred-not-recorded` survived only because it was pointed at the
wrong spec, but thinking it through showed that a mutant dropping *both* lines of the deferred branch (the
bidder loses the refund, `refunds` and `refundLiability` stay consistent, solvency still holds) would have
passed `bidRefundsOutbidBidder` too: that rule told "paid" from "deferred" by the auction's balance, and
the havoc of the outside call lets the balance rise, so "not paid and not deferred" looked like "paid".
The rule now measures payments with a `CALL` hook (exact amount, exact recipient) and demands one of the
two outcomes; `refund-dropped` and `refund-twice` were added and both are caught.

## Not covered

- **The token contracts.** `KilimMotifs` and `KilimOneOfOne` are not in the scene: their own checks (each id
  minted once and never again after a burn, the 1/1 minted once, recipient rules, ERC-721 callbacks) are
  not verified here. The auction side is: it asks only for allocated ids, only for the claimer, only as
  many as claimed, and mints the 1/1 at most once.
- **Gas.** `gasleft()` is free in the model; the refund and prize gas caps, the EIP-150 reserve and
  `InsufficientGas` are not checked. A receiver that burns its gas is covered only as a call that fails.
- **Liveness.** Nothing proves a call *succeeds* (any call may revert on `gasleft()` in the model). What is
  proved is that the bookkeeping never blocks one: `refundAtMostLiability` (withdrawals never underflow)
  and `creditsAreTheUnclaimedRanges` / `cursorSplitsRanges` (a claim within the credits always finds its
  ids).
- **Long claims.** `claimMotifs` is unrolled to 3 iterations with optimistic loops: claims touching more
  than 3 credit ranges (possible up to 64) are assumed away, not checked. The range invariants above do
  hold after any claim the unrolling covers.
- **Signatures.** `registerFor` is checked only as part of the state invariants; ECDSA and ERC-1271 are
  modelled abstractly (ecrecover is uninterpreted), so signature binding to chain, contract, wallet and
  deadline is not proved here (it is tested in `test/SponsoredRegistration.t.sol`).
- **Monotonic time** is assumed for `proceedsAreTheWinningBid` and timestamps are bounded by `2^64 − 1`.
- **Kilim Bazaar's making path.** `make`, `deposit` and `makeFromLoom` are not covered: a kilim needs at
  least 10 burned ids and its hand is counted over 64 words × 16 lanes, loops the prover would have to
  unroll about a thousand times. So the burn counts against kilims, the hand encoding, the tally lanes,
  `tokenURI` and the page assembly are not verified. Only the rank rule (`rankFor`, `masterCost`, `ladder`)
  and `seal()` are.
- **Forced ETH** (selfdestruct) only raises the balance and cannot break solvency; it is not otherwise
  modelled. **The constructors** are checked as the base case of each invariant with symbolic arguments;
  their external checks of the token contracts are not.
- **Compiler and EVM.** The prover checks the solc 0.8.37 bytecode for Cancun; the Glamsterdam gas changes
  (AUDIT FA-02) are outside its model.
