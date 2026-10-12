# AI audit, 12 October 2026: motif credits, motif minting and the 1/1 prize

One of five independent AI auditors (a Claude instance) working before the mainnet launch. This is not the independent human audit (K-08).

**Lens:** every path that creates or moves a token: credits per bid, claims, the cap, `highestBidMotifs`, the slippage parameters, settlement's prize delivery, `claimPrize`, the two token contracts' mint, burn and transfer rights, and the auction hooks in `EnglishAuction`.

**Code read:** `src/KilimAuction.sol`, `src/auction/EnglishAuction.sol`, `src/KilimMotifs.sol` and `src/KilimOneOfOne.sol` in full. In `src/KilimBazaar.sol`, the parts that use motif burns and `highestBidMotifs`.

**Proofs:** `security/ai-audit/credits/CreditsAudit.t.sol`, 8 tests, all passing. They were run as:

`FOUNDRY_OUT=.tools-out/ai-credits/out FOUNDRY_CACHE_PATH=.tools-out/ai-credits/cache FOUNDRY_TEST=security/ai-audit/credits node scripts/forge.mjs test -vvv`

## Result

**No Medium or higher finding.** I found no way to:

- create credits outside the bid rule;
- claim twice, or claim another bidder's credits;
- mint an id twice, or mint above the cap;
- send the 1/1 to anyone the winner did not choose, or mint it twice;
- re-enter the auction from any ERC-721 or ETH callback.

Below are one Low finding, two Info findings, and a list of what I checked and found sound.

| ID | Severity | Where | Proven |
| --- | --- | --- | --- |
| CR-1 | Low (a documented class; the reason given for accepting it is wrong) | `KilimAuction.sol:207-239`, `docs/NATIVE-ETH.md:105`, `AUDIT.md:520` | PoC passes: the permanent state is reproduced |
| CR-2 | Info | `KilimAuction.sol:153-193`, `launch/KILIM-BAZAAR-RULES.md:43`, `KilimBazaar.sol:618-621` | Test passes: the claim order is pinned |
| CR-3 | Info, unproven | `KilimAuction.sol:51,207-224` | No. Forge simulates Cancun; this is already an open item at `AUDIT.md:614` |

---

## CR-1 · Low · A winner that can only bid leaves the 1/1 unminted for good; "any contract that could bid can make calls" is not true

**Where:**
- `KilimAuction.sol:207-215`: `_afterSettle`
- `KilimAuction.sol:230-239`: `claimPrize`, winner only
- `KilimOneOfOne.sol:90-96`: `mint`, minter only
- `AUDIT.md:520` (the FA-06 decision) and `docs/NATIVE-ETH.md:105`: the stated reason

**What happens.** Settlement delivers the 1/1 with a `_safeMint`. If the winner's address has code without an `onERC721Received` that answers correctly, or its hook needs more than what is left of `PRIZE_GAS`, delivery fails and `PrizeDeliveryFailed` is emitted. From then on, `claimPrize(to)` is the only path that can mint the 1/1, and only `highestBidder` can call it.

FA-06 removed `deliverPrizeToWinner()`. The reason recorded was that "any contract that could bid can make calls". A contract that can call `bid()` can make *that* call. It cannot necessarily call `claimPrize` or `claimMotifs`.

**Failure scenario.** A collector deploys a sniping contract with one entry point: `bid(amount)`, which calls `auction.bid{value: amount}(amount, 0, 0)`. It also has a `receive()` for refunds, and nothing else. It wins.

1. `settle()` reverts inside the delivery with `ERC721InvalidReceiver`, and `PrizeDeliveryFailed(bot)` is emitted.
2. Nobody else may call `claimPrize`. `deliverPrize` is self-call only. `settle` cannot run again. `KilimOneOfOne.mint` is minter only.
3. The Unwoven Kilim is therefore never minted, and its `tokenURI(1)` reverts for ever.
4. The bot's motif credits are stranded in the same way, so "made from the winning bid" can never be made.

The proceeds are not affected.

Under Glamsterdam pricing the same outcome is reachable by any non-calling contract whose hook writes one new slot (`AUDIT.md:409`).

**Why only Low:**
- The loss falls on the winner, who chose a broken contract.
- Checklist 1 line 194 already tells bidders to use a wallet that can send transactions later.
- EOAs, EIP-7702 EOAs, Safes and ERC-4337 accounts can all call `claimPrize`. `AttackPatterns.t.sol` and `GasFloors.t.sol` test this.

The finding is that the stated reason is wrong, not that the outcome was unknown: the class itself is F-19 / V-15.

**PoC:** `CreditsAuditTest.testBidOnlyContractWinnerLeavesThePrizeUnmintedForever`, **PASS**. It reproduces the permanent state and checks every entry point:

- `claimPrize` from three other addresses: `Unauthorized`
- `deliverPrize`: `Unauthorized`
- a second `settle`: `AlreadySettled`
- a direct `oneOfOne.mint`: `Unauthorized`
- `tokenURI(1)`: reverts
- proceeds: paid to the treasury
- 50 credits: stranded

**Suggested fix.** The code is frozen, so this is a documentation change. Correct NATIVE-ETH.md section 6 and the FA-06 note. A contract must be able to call `claimPrize` and `claimMotifs` itself (a generic `execute` or a Safe). A contract that can only bid can lose the 1/1 and its motifs. Put this sentence in the bidding UI's warning as well as in checklist 1.

If the code is ever reopened: allow a winner-agnostic `deliverPrizeToWinner()` only after a long delay (for example 30 days without a claim). That keeps the FA-06 race closed during the period when the winner can act.

---

## CR-2 · Info · Claims are oldest first only, and the "winning bid" tag follows the ids, not the winner

**Where:**
- `KilimAuction.sol:153-193`: `claimMotifs` and `_claim` walk the ranges from a cursor
- `KilimBazaar.sol:618-621`: the `WINNING_BID` flag
- `launch/KILIM-BAZAAR-RULES.md:43`: "the winner's own Master, which nobody else can make"

**What happens:**

1. **No way to claim a chosen range.** `highestBidMotifs()` is always the winner's *last* range. A winner with earlier bids must mint every older range before any id of the winning bid is minted. For an honest winner with two or three bids this costs a few extra claims. For a ladder winner (F-04), the winning range comes after up to roughly 1,000,000 older ids, which is about 15,600 claims of 64. The Bazaar's "made from the winning bid" Master needs exactly the winning range, so it costs the winner all of that first.
2. **The tag follows the ids.** The Bazaar's `WINNING_BID` flag checks only that every burned id lies in `[first, first + won)`. The winner can claim those ids to any address, and once claimed they are ordinary transferable ERC-721s. So anyone who holds them can make the tagged kilim. Rule 6's "which nobody else can make" is therefore inaccurate. Because the ids are burned, at most one tagged Master can exist; that part holds.

**Test:** `CreditsAuditTest.testWinnerReachesTheWinningRangeOnlyAfterEveryOlderRange`, **PASS**. The winning range is the second unclaimed range. `claimMotifs(10)` mints ids 1..10, not ids of the winning bid, and id 22 is still unminted.

**Suggested fix:**
- Rules and site copy: "claims mint your oldest bid first; to make the winning-bid Master, claim everything before it".
- Reword rule 6, for example: "carries the tag whoever weaves them; the winner holds them first".
- No code change needed.

---

## CR-3 · Info · Unproven · PRIZE_GAS headroom under EIP-8037 depends on a price this code cannot see (already open)

**Where:** `KilimAuction.sol:51` (`PRIZE_GAS = 500_000`), `KilimAuction.sol:207-224`.

The delivery writes four new slots and updates none:
- `prizeClaimed`
- the 1/1's `minted`
- `_owners[1]`
- `_balances[winner]`

AUDIT.md:409 projects the delivery at 465,458 gas, leaving 34,542 for an EOA with no hook, a margin of about 7%. The constant is immutable. If the per-slot state price in force is more than about 8% above the projection, every delivery fails, even to an EOA. That can happen through EIP-8037's final values, or through a later rise in the block gas limit if the state price scales with it (I have not verified that it does).

EOAs and Safes then fall back to `claimPrize` without loss. Only the CR-1 class loses the 1/1.

**Why it is unproven:** forge here simulates Cancun (`foundry.toml` `evm_version = "cancun"`), so I could not measure it. AUDIT.md:614 already lists "PRIZE_GAS headroom under Glamsterdam (the Sepolia settlement measures it)" as open. This is not a new finding.

**For tonight's Sepolia run:** a `PrizeDeliveryFailed` for an EOA winner there is this effect, not a logic bug. Record the delivery's gas from the trace.

---

## Checked and sound

Each item has a reasoned trace through the code; the item points to the test that backs it.

**Credits per bid** (`KilimAuction.sol:115-137`):
- The reward is `min(units, maxMotifsPerBid, motifCap - motifsAllocated)`, never above the cap.
- The ranges are pushed only when the reward is nonzero, so every range is nonempty.
- `motifCredits`, the ranges and `motifsAllocated` move together.
- A wrong `msg.value` or failed slippage reverts everything.
- `firstMotifId = 1 + motifsAllocated`, and the last id is at most `motifCap`.

Fuzzed by `testFuzzCapBoundaryAndRangesPartitionTheIds` (512 runs, caps 1..60, per-bid 1..cap, 14 bids by three wallets):
- every reward is exact;
- `highestBidMotifs` equals the last bid's range after every bid;
- the ranges of all bidders partition `1..motifsAllocated` with no gap or overlap, and each id's reserver matches;
- claiming everything mints exactly those ids to their reservers;
- `cap + 1` is refused by the collection.

**Off-by-one at the cap.** In `testExactCapEdge` (cap 25):
- the bid that fills the pool gets the 4 that are left (ids 22..25);
- the next bid reserves nothing and reports `(0, 0)`;
- `expectedFirstMotifId = 26` reverts with `MotifRangeMoved(0)`;
- `minimumReward = 1` reverts with `RewardSlippage`.

The collection's bound `firstId - 1 > motifCap - quantity` is the same inequality as the auction's.

**Outbid bidders keep their credits.** This is intended and accepted (K-01, F-04, F-07, FA-07). Not re-reported.

**Double claim, or claiming someone else's credits:**
- Credits and the cursor are keyed by `msg.sender`, and there is no `claimFor`.
- Credits are decremented, and the cursor advanced, before any callback.
- The invariant "unclaimed ranges from the cursor are nonempty and sum to the credits" makes the range walk stay in bounds and terminate.

**Re-entry from callbacks:**
- `testClaimCallbacksCannotReenterAnyAuctionEntryPoint`: a recipient tries `claimMotifs`, `claimPrize`, `settle`, `withdrawRefund` and `bid` from each of 30 motif callbacks across three ranges. All 150 attempts hit `ReentrancyGuardReentrantCall`, and credits drop by exactly 30.
- `KilimMotifs.mintMotifs` is minter-only and guarded.
- `KilimOneOfOne.mint` is minter-only and one-shot, and `minted` is set before `_safeMint`.
- `deliverPrize` and `payOutbidRefund` accept only self-calls.

**Cross-contract re-entry through the Bazaar.** In `CreditsBazaarCrossTest.testBazaarEnteredFromAClaimCallbackStaysConsistent`:
- the winner's claim callback calls `Bazaar.make` and burns ids 1..10 while `mintMotifs` is still minting 11..20;
- the claim completes, and the counters are consistent (20 minted, 10 burned, credits 0);
- the kilim carries `WINNING_BID`;
- a burned id cannot be minted again.

The Bazaar reads only views of the auction that are final after settlement, and it pulls with `transferFrom(msg.sender, …)`, so it cannot take ids from a wallet that only approved it.

**Prize to the wrong address, or claimed twice:**
- `deliverPrize` mints to `highestBidder`, which cannot change after settlement: bids need `block.timestamp < endsAt`, settlement needs `>= endsAt`, and `endsAt` only moves inside a bid.
- `prizeClaimed` and the 1/1's `minted` are set in the same frame as the mint, so they revert together with it.
- `testFuzzPrizeGoesOnlyToTheWinnerOnce`: any settler, any time after the close; the 1/1 goes to the winner, a second claim is refused, and the outbid bidder is refused.

**Gas floor and EIP-150:**
- The `_afterSettle` floor (557,936) makes the `{gas: 500_000}` self-call receive its full allowance.
- The catch path needs a few thousand gas against the 50,000 reserve.
- `catch {}` copies no revert data.
- A third party cannot raise the delivery's cost: access lists only make it cheaper, and none of the slots it writes can be made dirty beforehand.

**Who mints, the ids, supply, and burn:**
- Only the immutable `minter` (the auction, bound at construction on both tokens) can mint, and the auction mints only reserved ids.
- `burned()` keeps a burned id taken.
- `burn` is owner-only, and approvals do not count.
- The motif contract's `_update` refuses the minter and itself.
- The 1/1's `_update` refuses the minter, itself and the motif contract.
- `tokenURI` on both requires a minted token.

**Claim gas:**
- Worst case for one claim on this code, 64 ranges of one id each: **2,190,043 gas** (`testWorstCaseClaimGas`).
- On mainnet every range holds at least 10 ids except the one the cap cuts, so a 64-claim touches at most 7 ranges, about 1.8M gas (AUDIT.md).
- No loop depends on the number of bids, and the bid count is bounded to roughly 100–200 by the 10% raise.
- Claiming 1,000,000 motifs takes about 15,600 transactions. That is already listed as an informational item.

**Front-running claims.** Not possible: claims are bound to `msg.sender` and ids are fixed at bid time. Front-running *bids* moves later bidders' ids; that is K-02, guarded by `expectedFirstMotifId` and `minimumReward`.

**Smart wallets:**
- EOAs, EIP-7702 EOAs, Safes and ERC-4337 accounts can all call `claimPrize` and `claimMotifs` after a failed delivery.
- An EIP-7702 EOA without a hook cannot claim motifs to itself, but can claim them to another address (FA-16, documented).

**Transfers into the Bazaar (Info, accepted class):**
- The 1/1 or a motif sent into the Bazaar by plain `transferFrom` stays there. Neither token knows the Bazaar's address; this is the same accepted class as V-13. Safe transfers bounce (`StrayTransfer`).
- A claim to the Bazaar reverts with the credits kept.
