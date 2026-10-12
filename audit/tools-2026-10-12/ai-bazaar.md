# AI audit, 12 October 2026: Kilim Bazaar custody and supply

**Lens:** burning motifs to make kilims. That covers custody (`transferFrom` into the Bazaar, then burn), duplicates, the loom, strays, receiver hooks, ranks, `CountOverflow`, gas for big makes, approval phishing, ERC-721/2981/4906 conformance, supply and ids, and the "opens only when settled" gate.

**Code:** `contracts/src/KilimBazaar.sol` at `2a63a727` (working tree, `src/` unmodified), read with `KilimMotifs.sol`, `KilimAuction.sol` / `EnglishAuction.sol` and `KilimOneOfOne.sol` where they interact.

**Read first:** `docs/KILIM-BAZAAR-SPEC.md`, including §7 and the Deviations section; `launch/KILIM-BAZAAR-RULES.md`; the AUDIT.md sections up to 11 October; the Bazaar tests already in `test/`.

**This is one of five AI reviews. It is not the independent human audit (K-08).**

## Result

**No Medium or higher found.** This lens found no way to:
- burn or count a motif you don't own;
- use one id twice;
- add to, close, redirect or block someone else's loom;
- push a stray into the counts;
- re-enter a write;
- reach `CountOverflow`;
- open the Bazaar before settlement, or keep it closed after.

There is one Low (operational, Glamsterdam gas) and five Informational findings.

PoC and property tests: `contracts/security/ai-audit/bazaar/BazaarCustodyAudit.t.sol`. 16 tests in 3 contracts, all passing. They reuse `test/bazaar/BazaarBase.sol` and the committed fixture page store, `onchain/test/fixtures/page-store`, which is present. Run them like this:

    cd contracts && FOUNDRY_OUT=.tools-out/ai-bazaar/out FOUNDRY_CACHE_PATH=.tools-out/ai-bazaar/cache \
      FOUNDRY_TEST=security/ai-audit/bazaar nice -n 10 node scripts/forge.mjs test -vvv

## Findings

| ID | Severity | Where | Summary | PoC / evidence | Result |
|---|---|---|---|---|---|
| BZ-1 | Low | spec `docs/KILIM-BAZAAR-SPEC.md:302-304`; `site/chain.js:947`; `KilimBazaar.sol:484-506` | Under Glamsterdam the "300 ids per call" rule needs about 43–46M gas per transaction against a 60M mainnet block | `testFullMakesProjectedUnderGlamsterdam` (measurement) | passes; numbers below |
| BZ-2 | Info | `KilimOneOfOne.sol:436-438`; `KilimBazaar.sol:436` | A plain `transferFrom` strands The Unwoven Kilim in the Bazaar forever | `testTheOneOfOneCanBeStrandedInTheBazaarByAPlainTransfer` | passes (behaviour shown) |
| BZ-3 | Info | `KilimBazaar.sol:617-621`; `launch/KILIM-BAZAAR-RULES.md:43` | "Made from the winning bid" goes with the ids, not the winner. It can be split, and bought | `testTheWinningBidTagFollowsTheIdsAndSplits` | passes (behaviour shown) |
| BZ-4 | Info | `KilimBazaar.sol:200`, `:234` | The standing approval is safe, but `to` is free: a fake or compromised front end can burn everything into a kilim it receives | existing `testApprovalsCannotBeUsedThroughTheBazaar`; `testAStrangerCannotCloseFeedOrRedirectALoom` | passes |
| BZ-5 | Info | `KilimBazaar.sol:218-244` | A loom has no exit and no split. A contract depositor that cannot call `makeFromLoom` strands its burned motifs | `testFuzzALoomIsAlwaysClosable` | passes |
| BZ-6 | Info | `KilimBazaar.sol:591`, `:498-501` | `CountOverflow` cannot happen at the mainnet cap: at most 1,073 ids show any one motif | `testNoMotifCanReachALaneOverflowAtTheMainnetCap` | passes |

### BZ-1 (Low): under Glamsterdam the 300-per-call rule takes most of a mainnet block

**The problem.**
- The spec says "300 ids per call always fit both chains" (`KILIM-BAZAAR-SPEC.md:302`), and the site sends up to `MAKE_MAX = 300` in one `make` and `LOOM_BATCH = 200` per `deposit` (`site/chain.js:947`). That holds today on mainnet: the transaction cap is 2^24 and the worst `make` of 300 is 13.29M.
- The Bazaar is permanent, so it will run under Glamsterdam. Every new storage slot then costs 97,920 state gas (EIP-8037, CPSB 1,530).
- A block includes a transaction only if `tx.gas <= state_gas_available` (EIP-8037 L78, quoted in `audit/final-audit-2026-10-11.json` → `glamsterdam`). On mainnet that budget is the 60M block limit, less the state gas already in the block.

**Measured.** Cancun gas comes from forge with every contract cooled. "New slots" are the slots that go from zero to nonzero in the Bazaar and Motif Bazaar. The projection is Cancun − 10,000 per new slot + 97,920 per new slot.

| Call | Cancun | New slots | State gas | Projected tx.gas |
|---|---:|---:|---:|---:|
| `make` 300, every id the first burn in its 256-id `_burned` bucket | 13,285,381 | 339 | 33,194,880 | ≈43.1M |
| `deposit` 300 such ids, opening a loom | 13,816,832 | 367 | 35,936,640 | ≈46.1M |
| `make` 300 consecutive ids | 6,765,770 | 39 | 3,818,880 | ≈10.2M |
| `make` 150 such fresh-bucket ids | 6,917,945 | 173 | 16,940,160 | ≈22.1M |

The Cancun figures reproduce the spec's own (13,249,067 and 13,789,159).

**What it means.**
- Such a transaction needs a gas limit far above 2^24, which the spec already notes.
- It also needs 72–77% of an empty block's state budget, so it waits for a block with that much state budget still free.
- Fresh buckets are the norm while a bucket's 256 ids are still unburned. 1,000,000 ids make 3,907 buckets, so early market motifs often start one.
- A lower block gas limit, or a CPSB re-derived upward (the EIP's rationale allows that), would make a 300-id fresh-bucket deposit impossible to include.

**What is not affected.**
- Nothing is stuck or lost: a failing call reverts before any burn, and the loom splits any kilim into small deposits.
- No funds are at risk.

**Suggested fix (no contract change).**
- Size every Bazaar call by its estimate, not by its count. Under Glamsterdam, aim for at most about 20–25M gas: about 150 fresh-bucket ids, or 300 started-bucket ids.
- Split with `deposit` above that, and set `tx.gas` explicitly from `eth_estimateGas` plus a margin.
- Reword spec line 302. Publish a Glamsterdam column in the gas table.
- A caveat: the projection's execution part ignores EIP-8038's other repricings. The state part is exact for CPSB 1,530. Bazaar's motif balance goes 0→n→0 inside the call and is not counted as a new slot.

### BZ-2 (Info): The Unwoven Kilim can be stranded in the Bazaar

**How it happens.**
- `KilimOneOfOne._update` refuses only the 1/1 itself, the auction and Motif Bazaar (`KilimOneOfOne.sol:436-438`). The Bazaar was deployed after it, so the 1/1 cannot know it.
- `owner → transferFrom(owner, bazaar, 1)` therefore succeeds. The Bazaar has no function that moves any token it holds, so the 1/1 is lost for good.
- `safeTransferFrom` bounces with `StrayTransfer` (`KilimBazaar.sol:436`).
- The opposite direction is blocked: a kilim cannot be sent to the 1/1's contract (`KilimBazaar.sol:1157`). The PoC asserts both.

**The risk.** The site "takes" motifs this way, which makes the Bazaar look like a place tokens go. The spec documents motif strays (§7.1), but not the 1/1.

**Suggested fix.** No on-chain fix is possible without a rescue role, which the project excludes. Say in the rules and on the site that nothing should ever be sent to the Bazaar by hand, and that the site never builds such a transfer.

### BZ-3 (Info): the winning-bid tag goes with the ids, not the winner

**What the code does.** `_make` tags any kilim whose every burned id lies in `[first, first + won)` (`KilimBazaar.sol:617-621`), whoever makes it.

**The PoC.** The winner's ids 1–30:
- ten sold to BOB make BOB a tagged Apprentice;
- the winner makes two more tagged Apprentices from the rest.

**Where the docs differ.** Rules line 43 says the tag means "the winner's own Master, which nobody else can make". The spec (§5) correctly says it "applies at any rank". Only the public rules overstate it.

**Suggested fix.** Reword rule 6. For example: "A kilim made only from the winning bid's motifs carries the tag, at any rank and whoever makes it." If exclusivity is wanted, it would have to be a code change, and it is a design call. Tying the tag to `msg.sender == highestBidder` would break for a winner who moves wallets.

### BZ-4 (Info): the approval is safe; `to` is the phishing surface

**What is safe.**
- `_take` only ever pulls `from = msg.sender` (`KilimBazaar.sol:489`). There is no `from`, depositFor or meta-transaction.
- So a standing `setApprovalForAll(bazaar, true)` cannot be used by anyone else. An operator over all of a victim's motifs is refused too, with `ERC721IncorrectOwner`.

**What is not.**
- `make(ids, to)` and `makeFromLoom(ids, to)` accept any `to` except the four blocked contracts.
- A cloned or compromised site can ask the user to sign `make(allTheirIds, attacker)`. The user's motifs are burned, and the attacker gets the kilim, perhaps a Master.
- This is ordinary front-end risk. It is worth naming because one signature destroys up to 300 motifs, or a whole loom.

**Suggested fix (site and copy).**
- Default `to` to the connected account, and require an explicit, displayed choice for any other.
- Show the count and the recipient before signing.
- Tell users they can revoke the approval after making.

### BZ-5 (Info): a loom has no exit and no split

**How it behaves.**
- Motifs are burned at `deposit`. The only way forward is `makeFromLoom`, by the same address, into exactly one kilim.
- For an EOA that is always possible: the fuzz test closes looms of 10–149 motifs to arbitrary EOAs with `makeFromLoom([])` under 200k gas.
- `_checkRecipient` lets the depositor pick another `to` if their own cannot receive. The spec documents the EIP-7702 case.

**The residual risk.** A contract that can call `deposit` but not `makeFromLoom` strands its burned motifs: for example a vault, a module-restricted multisig, or an integrator's helper. The same goes for a wallet whose key is lost.

**Suggested fix.** None needed. Document it for integrators.

### BZ-6 (Info): `CountOverflow` cannot be reached at the mainnet cap

**The evidence.**
- At the planned mainnet Motif Bazaar address `0x33E45DED…e6EF` on chain 1, the most ids among 1..1,000,000 that show any one motif is **1,073**. The expected maximum is about 1,080 at any address.
- A loom's 16-bit lane would need 65,536.
- In memory, a batch's lanes are bounded by `MAX_BATCH` = 65,535 (`KilimBazaar.sol:486`).

**Conclusion.** The check in `_fold` (`:591`) is defence in depth, and the existing mutation test covers it. No action.

## Checked and found sound

The PoC file name is shortened to `BCA` below.

**Custody: motifs you don't own or didn't approve.** `_take` does all the plain `transferFrom(msg.sender, bazaar, id)` calls, then all the burns. OZ 5.6.1 checks this:
- `_checkAuthorized`: owner, operator or per-token approval;
- then `previousOwner == from`.
- `burn` is owner-only, and the Bazaar owns the ids by then.

Someone else's id, an unapproved id, a burned id, an unminted id, id 0 and ids above the cap all revert before anything is recorded. Tests: existing `testPullsOnlyFromTheCaller…`, `testRevertsWithoutApproval`, `testApprovalsCannotBeUsedThroughTheBazaar`; BCA `testAStrangerCannotCloseFeedOrRedirectALoom`.

**Duplicates.**
- Inside one `make`, `deposit` or `makeFromLoom`: the second transfer of the same id finds the Bazaar as owner and reverts `ERC721IncorrectOwner(caller, id, bazaar)`.
- Across a deposit and a make, two deposits, a loom and its close, or two kilims: the id is burned and reverts `ERC721NonexistentToken`.
- The motif collection's bitmap stops a burned id from being minted again.

Tests: BCA `testDuplicateIdsInsideOneCallRevertEverywhere`, `testAnIdCanNeverServeTwiceAcrossLoomMakeAndKilims`.

**Looms.**
- Looms are keyed by `msg.sender`. A stranger gets `NoLoom`, and any `to` they name is irrelevant.
- An operator over the victim's motifs cannot feed them into any loom.
- Closing deletes the loom before minting. A new deposit opens a new hand key, and an old key is never written again.

**`make` and the loom agree.** The same ids made in one call, or loomed in 1–3 batches, give the same:
- count, rank and number;
- title, with ties to the lower number across batches;
- distinct, tags and hand.

This was fuzzed with heavy ties (four motifs, 2–20 each, half the runs with equal counts; 96 runs). Test: BCA `testFuzzMakeAndLoomAgreeOnEveryHand`.

**Strays.**
- A safe transfer bounces.
- A plain transfer is inert forever. It can't be used by its sender or anyone else, can't be moved out, and isn't counted: `motifsBurned` equals the sum of the hand counts, with `strayMotifs` constant.
- Strays only keep the Bazaar's motif balance nonzero. That makes later makes slightly cheaper and cannot break anything.

Tests: BCA `testStraysStayOutOfEveryCountAndCannotBeUsedByAnyone`; existing `testAPlainStrayCanNeverBeDepositedOrWoven`.

**Reentrancy.**
- The Bazaar's own `onERC721Received` always reverts.
- The only outgoing hook is `_safeMint`, last, after every write. All four writes share the transient guard, which the existing `testReenteringEachWriteFromTheHookReverts` covers.
- **Cross-contract:** a kilim made from inside a motif mint's receiver hook works. Here `KilimMotifs.mintMotifs` is guarded, but `transferFrom` and `burn` are not. The mint finishes, nothing is minted twice, and the counts agree. Test: BCA `testMakingFromInsideAMotifMintHook`.

**Ranks.**
- `rankFor` equals the page's rule and the `ladder()`-derived rank at any close (`top` 10..5,000,009) and count, including every boundary: 512 fuzz runs.
- Kilims actually made at `top − 1` and `top` take the expected rank for `top` 10..49.
- Tests: BCA `testFuzzRankForMatchesThePageRuleAndTheLadder`, `testFuzzMadeKilimsTakeTheRankAtTheMastersEdge`.

**Supply and ids.**
- Every hand key and every kilim needs at least 10 burned motifs. So the tally lanes are at most `motifCap / 10` = 100,000, far from 2^32, and no lane can carry into another.
- Token ids run 1..`totalSupply` with no gaps, and no kilim burn exists.
- Bids rise at least 10% (mainnet `incrementBps` 1000), so at most 11 × `top` motifs can exist, and at most 11 Masters.

**The settlement gate.**
- Every write reads `auction.settled()`, from the immutable, constructor-checked auction. The values it depends on are final once settled.
- The gate cannot stay shut while any bid exists. A winner whose 1/1 hook reverts, burns all gas or return-bombs 200 KB still lets anyone settle (with a 3M gas limit), and the Bazaar opens.
- With no bids no motifs exist at all.
- Tests: BCA `testARevertingWinner…`, `testAGasBurningWinner…`, `testAReturnBombingWinnerCannotKeepTheBazaarClosed`.

**Conformance.**
- `supportsInterface`: 721, Metadata, 165, 2981 (`0x2a55205a`) and 4906 (`0x49064906`) are true; `0xffffffff`, Enumerable and the receiver are false.
- `tokenURI` reverts for a token that does not exist.
- `MetadataUpdate` is emitted at seal, the only time metadata changes: the image switches to `imageBase` and `animation_url` appears. A re-arm changes nothing visible.
- `royaltyInfo` is 7.5% to the receiver.
- `KilimMade` precedes `Transfer` in the logs, which is allowed.

**Gas on mainnet today.**
- The worst 300-id `make` (13.29M) and `deposit` (13.82M) fit the 2^24 per-transaction cap and the 60M block.
- `makeFromLoom([])` is about 120k at any loom size. A loom can always be closed, and any kilim can be split across deposits.

**Documented and accepted behaviour, re-checked and not re-reported:**
- motif strays are lost (spec §7.1);
- seal withholding becomes a re-roll after 8,191 blocks (Deviation 17);
- the permanent URL bases (Deviation 18);
- a Master costs `top` even when the pool was short or `top` exceeds the motifs in circulation (decided 11 October);
- an EIP-7702 `to` without the hook (spec §7.3).
