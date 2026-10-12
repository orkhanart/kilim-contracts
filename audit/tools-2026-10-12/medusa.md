# Medusa campaign, 12 October 2026

Stateful fuzzing of the four mainnet contracts (`src/auction/EnglishAuction.sol`, `src/KilimAuction.sol`,
`src/KilimMotifs.sol`, `src/KilimOneOfOne.sol`, `src/KilimBazaar.sol`) with Trail of Bits Medusa, in Recon's
Chimera layout so the same handlers and properties also run under Foundry. Harness, config and commands:
`contracts/security/medusa/` (README.md there).

## Result in one paragraph

**No property or assertion failed.** Two Medusa runs fuzzed for 4 h 09 m 51 s in total (3 h 09 m 52 s, then
59 m 59 s), executing **16,376,447 calls in 164,105 call sequences**, with 0 failed sequences. The final run's
summary: 69 tests passed, 0 failed (36 handler assertion tests, 19 properties, 14 reachability probes). The
same harness under Foundry passed all 19 invariants and the scripted lifecycle test. Line coverage of the
contracts: EnglishAuction 94.8%, KilimAuction 94.9%, KilimBazaar 92.4%, KilimOneOfOne 83.4%, KilimMotifs
82.5%; every Kilim-specific state-changing function of every contract was reached (of the inherited ERC-721
functions, `approve` and any transfer of the 1/1 were not exercised), and the lines never reached are
constructor refusals, interface/metadata helpers and escape branches the stand-in texts never need (listed
below). One path the properties guard was **not** exercised by Medusa: sealing a kilim through the EIP-2935
history contract (257-8,191 blocks after its seal block), because Medusa did not return the hash the harness
stored there; the Foundry run of the same harness does exercise it. Nothing found needs a Foundry
reproducer of a contract bug; the four failures seen in smoke runs were harness/tool artefacts, explained
below.

## Versions

| Tool | Version |
|---|---|
| Medusa | 1.5.1 (`~/.local/bin/medusa`; source checked against tag v1.5.1, commit 540a483b) |
| crytic-compile | 0.4.2 |
| forge | 1.7.1 (commit 4072e487), from `contracts/node_modules` |
| solc | 0.8.37, optimizer on, 200 runs, `evm_version = cancun` (the repo's profile) |
| OpenZeppelin | 5.6.1 |
| Chimera | Recon-Fuzz/chimera tag 0.1.4, commit 0d37c2b8998756680e76d859c343e01c4fc1e006, vendored in `security/medusa/lib/chimera/` |

Medusa's chain runs Prague rules (`PragueTime = 0` in v1.5.1).

### Which contract code was fuzzed (PRIZE_GAS)

The artist raised `KilimAuction.PRIZE_GAS` from 500,000 to 1,000,000 during the campaign (the file changed
on disk at 15:05:54 UTC). Checked in each run's build info:

- **Run 1** (14:54:56 UTC) was compiled against **`PRIZE_GAS = 500_000`** (settle floor 557,936): the source in
  its build info says so and the deployed bytecode holds `PUSH3 0x07a120` three times and no `0x0f4240`.
- **Run 2** (built 18:06 UTC) was compiled against **`PRIZE_GAS = 1_000_000`** (settle floor 1,065,873); its
  build-info source is identical to today's `src/KilimAuction.sol`. The other four files were unchanged
  between the runs.

The harness hardcodes no copy of PRIZE_GAS. It gives a quarter-to-a-third of `settle()` and `bid()` calls an
explicit gas limit, drawn from 50,000-1,550,000 (settle) and 100,000-1,600,000 (bid), so both floors lie
inside the fuzzed range, and it asserts one fixed threshold, `SURE_GAS = 1,200,000`: a valid settle or bid
sent with at least that much must succeed. With PRIZE_GAS 1,000,000 a settle needs about 1.11 M at the call
(1,065,873 left at `_afterSettle` plus about 45,000 before it), so the threshold still holds, by about 90,000;
run 2 never tripped it. If PRIZE_GAS rises further, `SURE_GAS` in `recon/TargetFunctions.sol` must rise with it.

## Configuration (`security/medusa/medusa.json`)

8 workers, `nice -n 10`, `caffeinate -i`; call sequences of 100; `blockNumberDelayMax` 1 and
`blockTimestampDelayMax` 1,200 s (the harness has its own handlers for big block and time jumps);
`transactionGasLimit` 50,000,000; assertion mode (only `assert`/panic 0x01 fails, not reverts), property mode
(`property_*`, checked after every call), optimisation mode (`optimize_*`, reachability probes); shrink limit
300; Slither off; corpus in `security/medusa/corpus/` (git-ignored). crytic-compile runs with
`--ignore-compile --foundry-ignore-compile --skip-clean` on a build `run.sh` makes into
`contracts/.tools-out/medusa/out` (without those flags crytic-compile runs `forge clean` first).

## The harness

**Deployment**, as `script/DeployKilim.s.sol` orders it: stand-in grid, name and page stores (the page's HEAD
ends in `const GRIDS='` and its TAIL starts with `O2Nv`, as the Bazaar's constructor checks); the motif
collection and the 1/1 naming the auction's predicted address as minter; the auction; then Kilim Bazaar,
deployed before settlement, after the canonical EIP-2935 runtime is etched at `0x0000F908…2935` so its
`seedWindow` is 8,191 (asserted in setup). Auction terms are mainnet's (24 h, 10-minute extension, 10%
increment, 0.01 ETH reserve, start one hour after deployment) except **motif cap 4,000 and per-bid limit
1,500** (mainnet: 1,000,000 and 1,000,000), so that the pool can run dry and the per-bid clamp can bind.

**Actors**: two EOAs with known keys (they sign `registerFor`), two `MoodyWallet` contracts whose ETH and NFT
receivers can each accept, reject, burn all gas, or re-enter the contract that is paying or minting to them
(and which can approve ERC-1271 registrations), the treasury (an EOA), up to 100 throwaway registrants.

**Handlers** (36): registration (direct, by signature with valid / expired / wrong-key / wrong-deadline
signatures, by the treasury, bulk), wallet moods and balances, bids (valid, one unit short, not a whole unit,
wrong `msg.value`, reward slippage, wrong or right expected motif id, by the treasury; a quarter with a gas
limit), pull refunds and proceeds to every kind of recipient (including the auction, the token contracts, the
Bazaar and the zero address), forced ETH, the two self-call entry points from outside, time warps to the start
and around the close, settlement (a third with a gas limit), motif claims (valid, zero, over the credits, over
64), the 1/1 claim by the winner and others, motif transfers, burns and burns by non-owners, Bazaar approval,
`make`, a `make` built to hit the DENSE hand format, `deposit`, `makeFromLoom`, makes/deposits/closes that slip
in an id the caller does not hold (another holder's, burned, unminted, duplicate, a stray), strays sent by
plain and by safe transfer, kilim transfers including to the four blocked contracts, `seal` on up to five ids
(unknown and repeated ones included), block rolls (1-3, ~256, ~8,191 and up to 20,000 blocks), all the
metadata reads (`tokenURI` of motifs, the 1/1 and kilims, `pieceOf`, `ladder`, `rankFor`, `sealState`, ...), and
two shortcuts (registration-bid-close-settle; claim-and-approve for everyone) that call the same checked
handlers.

Each handler predicts whether its call must succeed, must fail, or may go either way (a gas-capped call, a
re-entering wallet), asserts the prediction, and on success asserts the exact effects against a ghost ledger.

## Properties and results

All results below are from the final summary of run 2 ("69 test(s) passed, 0 test(s) failed") and from run 1's
last status line ("failures: 0/119,346" sequences; no `[FAILED]` line and no shrink request in its log; it was
stopped before printing a summary).

### Properties, checked after every call (19)

| Property | Checks | Run 1 | Run 2 |
|---|---|---|---|
| `property_solvency` | auction ETH balance >= `liabilities()` | held | passed |
| `property_escrowExact` | balance = bids in + forced ETH - pushed refunds - pulled refunds - proceeds | held | passed |
| `property_liabilitiesExact` | `liabilities()` = refunds owed + (settled ? proceeds due : highest bid), and = balance - forced ETH | held | passed |
| `property_refundsMatchDeferred` | refund liability = sum of refunds owed; each bidder owed exactly deferred - withdrawn (nobody takes more than owed) | held | passed |
| `property_outbidConserved` | every outbid amount = pushed back + deferred; withdrawn <= deferred | held | passed |
| `property_dustAfterWithdrawals` | settled, proceeds and all refunds out => balance = forced ETH exactly (AUDIT.md K-06), else 0 | held | passed |
| `property_highestBidAndClock` | highest bid = last accepted bid, whole units, >= reserve; close = the one the last bid set; no bid, no clock; settled => close passed | held | passed |
| `property_settledOnce` | settled at most once; outcome fixed after; proceeds paid at most once and exactly the winning bid | held | passed |
| `property_registration` | <= 100 registrations, never the treasury; no accepted bid before 100 | held | passed |
| `property_credits` | allocated <= cap; credits + claimed = allocated; minted = claimed; per-bidder credits match the ghost | held | passed |
| `property_highestBidMotifs` | the winning (highest) bid's motif range is the one its bid reserved | held | passed |
| `property_unclaimedRanges` | each bidder's unclaimed ranges = the ghost's, non-empty, ascending, within the allocation, summing to its credits | held | passed |
| `property_oneOfOne` | 1/1 minted at most once, only after settlement, held by the winner or the recipient the winner chose | held | passed |
| `property_motifSupply` | minted - burned = holders' motifs + strays; burns = owners' + Bazaar's; each balance = the ghost's | held | passed |
| `property_bazaarClosedBeforeSettle` | before settlement: no kilim, no burn, no loom, `ladder()` closed | held | passed |
| `property_kilimRecords` | every kilim: >= 10 motifs, the rank its count earns, numbers dense per rank, made fields never change, sealed at most once and then frozen, `sealState` consistent | held | passed |
| `property_looms` | open looms hold >= 10 and exactly what was deposited (count, distinct, min/max id) | held | passed |
| `property_strays` | the Bazaar holds only the strays sent by plain transfer | held | passed |
| `property_noReentry` | no call back into the auction or the Bazaar from inside their own payment/mint succeeded | held | passed |

### Handler assertions (36 assertion tests, all passed in both runs)

The checks the task listed, by where they live:

- **Bids**: an accepted bid is strictly higher than the last and >= `minimumBid()`, a whole number of units;
  `minimumBid()` is exact (one unit less is refused); the first bid sets the close to now + 24 h, later bids
  only to max(close, now + 10 min); no bid at or after the close; the outbid amount is paid back in full or
  deferred in full, never split or lost; **a leader that takes ETH (EOA or accepting wallet) is always paid
  straight back, whatever gas the bid carried** (F-01); a valid bid with >= 1.2 M gas never fails;
  `rewardForBid` = min(units, per-bid limit, pool left); the reserved ids are the next ones and are what
  `highestBidMotifs` reports.
- **Refunds / proceeds**: a pull refund pays exactly what is owed, clears it, reduces the liability by it;
  a failed one changes nothing; only the treasury withdraws proceeds, once, exactly the winning bid.
- **Settlement**: only after the close, once; with any gas limit, a successful settle with a winner that takes
  NFTs has delivered the 1/1 to it (F-02); a refusing winner is left to `claimPrize`, which only the winner can
  call, once, to a recipient of its choice.
- **Claims**: each claimed id is the next id of the claimer's own reserved ranges, oldest bid first, and is now
  owned by the named recipient; minted count and credits move by exactly the quantity.
- **Registration**: outcomes of `register`/`registerFor` match the rules (time, count, duplicate, balance,
  signature, deadline, ERC-1271).
- **Bazaar**: `make`/`deposit`/`makeFromLoom` succeed or fail exactly as the rules say (settled, >= 10, approval,
  recipient); on success every passed id is burned, the burn count rises by exactly their number, the kilim's
  hand equals the multiset of the burned ids' motifs (recomputed from `motifOf`), the title is the most-burned
  motif with the lowest number among ties, rank and number are right, the seal block is the next block, the
  WHOLE and WINNING_BID flags are right, and every earlier kilim's hand is unchanged; an id the caller does not
  hold is always refused with nothing minted or burned; a safe transfer to the Bazaar bounces; kilims never
  reach the four blocked contracts.
- **Seal**: `seal` never reverts; its count and each kilim's new state equal a model computed from block
  numbers alone (skip before the seal block, re-arm to the next block after 8,191, else seal iff the hash is
  nonzero); the seed is `uint32(keccak256(hash, bazaar, id))` of the hash of the kilim's seal block, which is
  after the block it was made in; a sealed record never changes again.
- **Reads**: `tokenURI` never reverts for an existing token (motif, 1/1, kilim, sealed or not) and always for a
  missing one; `pieceOf` of a sealed kilim equals its seed, hand and Master cost serialised as `JSON.stringify`
  would; `rankFor` and `ladder` match the page's rule; `rankFor` reverts before settlement.

### Reachability (largest value Medusa reached in one call sequence, run 2)

| Probe | Max | Meaning |
|---|---|---|
| `optimize_motifsAllocated` | 4,000 | the motif pool was drained (bids continued with no reward) |
| `optimize_deferredRefunds` | 3 | outbid refunds parked as pull refunds |
| `optimize_pulledRefunds` | 1 | parked refunds withdrawn |
| `optimize_settledWithPrizeFallback` | 1 | settlements where delivery failed and the winner had to claim |
| `optimize_prizeClaims` | 1 | `claimPrize` successes |
| `optimize_kilims` | 7 | kilims made in one sequence |
| `optimize_loomCloses` | 4 | `makeFromLoom` successes |
| `optimize_masterKilims` | 1 | Master-rank kilims |
| `optimize_winningBidKilims` | 4 | kilims flagged WINNING_BID |
| `optimize_denseOneCallKilims` | 3 | one-call kilims stored DENSE (the other branch of `_record`) |
| `optimize_seals` | 3 | seals |
| `optimize_rearms` | 4 | re-arms after the 8,191-block window |
| `optimize_historySeals` | **0** | seals through the EIP-2935 contract: **never reached under Medusa** |
| `optimize_historyMismatch` | 11 | times the etched history contract did not answer with the stored hash |

Run 1's probes were not printed (it was stopped before its summary); the 2-minute smoke run before it had
already reached seals 1, re-arms 1, Master 1, WINNING_BID 2, DENSE 1, pool drained.

## Coverage (Medusa's report, run 2)

`security/medusa/corpus/coverage/coverage_report.html` and `lcov.info`, written at 19:10 UTC by run 2. Run 2
started by replaying run 1's corpus (369 sequences, 360 valid), so the report covers what both runs kept.
Summarised with `python3 security/medusa/coverage_summary.py security/medusa/corpus/coverage/lcov.info`.
Medusa does not count calls made by property checks, which is why the harness also calls the read functions
from a handler. The line attribution comes from an optimised build's source maps and is approximate inside
long expressions; function-level reach is exact.

| Contract | Lines executed | Every external/public state-changing function reached | Not reached |
|---|---|---|---|
| EnglishAuction | 109/115 (94.8%) | `register`, `registerFor`, `withdrawRefund`, `settle`, `withdrawProceeds`, `payOutbidRefund`; internals `_handleBid`, `_refundOutbid` (both the paid and the deferred branch), `_pay`, `_isNewWinningBid` | the constructor's `InvalidConfiguration` refusal; the base `_afterSettle` (overridden); immutable getters |
| KilimAuction | 93/98 (94.9%) | `bid` (every revert branch: `RewardSlippage`, `MotifRangeMoved`, `BidTooLow`, `NonWholeUnitBid`, `IncorrectPayment`, `AuctionNotOpen`, `RegistrationIncomplete`, `TreasuryCannotBid`), `claimMotifs` (multi-range `_claim`), `deliverPrize` (success and `PrizeDeliveryFailed`), `claimPrize`, `unclaimedMotifRanges`; both `InsufficientGas` floors were hit (judging by the drop in line counts: about 258 bids at the refund floor, about 174 settles at the prize floor) | the constructor's `InvalidConfiguration` refusals |
| KilimMotifs | 141/171 (82.5%) | `mintMotifs` (via claims), `burn`, `tokenURI`, `svg`, `grid`, `motifName`, `contractURI`, `royaltyInfo`, `grids` | `gridChunks`, `supportsInterface`; the escaping branch of `_escapeJson` and `_hexDigit` (the stand-in names and texts contain nothing to escape); `SupplyExceeded` (the auction never asks for an id outside 1..cap); constructor refusal |
| KilimOneOfOne | 171/205 (83.4%) | `mint` (via settle and `claimPrize`), `tokenURI` (the whole assembly builder), `contractURI`, `royaltyInfo` | `prefixChunks`, `supportsInterface`; `tokenURI`'s `GridsUnavailable` and bubbled-revert branches (the motif contract always answers); escaping branches; constructor refusal |
| KilimBazaar | 534/578 (92.4%) | `make`, `deposit`, `makeFromLoom`, `seal` (skip, re-arm, block-hash seal), `tokenURI` sealed (`_respondWithPage`) and unsealed, `pieceOf`, `ladder`, `rankFor`, `sealState`, `handOf`, `loomHandOf`, `strayMotifs`, `onERC721Received`, `_record` PACKED and DENSE | `supportsInterface`; the `imageBase` branch (deployed with `imageBase = ""`); `_escapeJson`'s escaping branch (stand-in names need none); `GridsUnavailable` branches; constructor refusals; inside `seal`, the history call is made 6,885 times but never returns a hash, so no seal through it |

Handler activity in run 2 (Medusa's revert report): every one of the 36 handlers was called between 106,182
and 143,636 times, with 0 handler reverts (handlers catch the calls they expect to fail and assert on them).

## Failures seen, and what they were

None in the two campaign runs. The smoke runs before them produced four, all in the harness or the tooling,
each fixed before the campaign:

1. **`bazaar_seal`: "seal: count differs from the block-number rule"** (smoke 1 and smoke 5; shrunk to 5 calls:
   `shortcut_toSettlement`, `shortcut_claimAndApprove`, `bazaar_make`, `chain_roll(+269 blocks)`,
   `bazaar_seal`). The model expected a seal through the history contract (age 268 > 256) because the harness
   had written the hash into the EIP-2935 slot with `vm.store`; the Bazaar's call to the etched history contract
   came back without that hash, so nothing was sealed. **Harness artefact, not a contract bug**: the same
   sequence under Foundry seals as modelled, and the contract behaved exactly as its documented rule says (a
   lookup that yields no hash skips). Re-etching the code inside the transaction did not change it. The model
   now asks the history contract what it answers (counted by `optimize_historyMismatch`, 11 times in run 2)
   instead of assuming. Consequence: the 257-8,191-block seal path is untested under Medusa (see below).
2. **No seal at all** (smoke 2-4). Medusa 1.5.1 commits a block only if it holds a contract creation;
   otherwise it renumbers one pending block, so no block ever had a hash for `blockhash` to return. The
   Bazaar and chain handlers now deploy an empty `Blank` contract so blocks get committed; seals then
   appeared (run 2: 1,435 executions of the seal branch).
3. **Medusa ran an old harness** (smoke 3): an incremental forge build left two build-info files and
   crytic-compile handed Medusa the stale one. `run.sh build` now starts from an empty `.tools-out/medusa/out`.
4. **Foundry scripted test "Bazaar stages not reached" / "no re-arm"**: inputs of the scripted walk were too
   small to reach the stage; fixed in the script.

A failure in a later run is turned into a Foundry reproducer by replaying the shrunk calls, in order, as calls
to the same handlers in `security/medusa/recon/CryticToFoundry.t.sol` (method in the README). None was needed.

## Foundry (the same harness, `security/medusa/run.sh forge`)

- 15:21 UTC, against PRIZE_GAS 1,000,000: 19 invariants x 128 runs x depth 120 (15,360 handler calls each,
  291,840 in all), 0 reverts, all passed; `test_lifecycleReachesEveryStage` passed. The scripted test requires a
  deferred refund, the prize fallback and claim, make/deposit/close, a DENSE one-call kilim, a stray, a seal
  through `blockhash`, **a seal through the history contract** and a re-arm, with every property checked
  after each stage.
- Earlier the same day, against PRIZE_GAS 500,000: 19 invariants x 32 runs x depth 120, all passed.

## What this campaign does not cover

- **The history-contract seal path under Medusa** (seal block 257-8,191 blocks back): reached as a call, never
  as a seal, for the reason in failure 1. Covered only by the Foundry run of this harness and the repo's own
  `test/KilimBazaarSeal.t.sol`.
- **WHOLE** (a kilim of all 1,024 motifs) and **`CountOverflow`** (65,536 of one motif in a loom): unreachable
  with a 4,000-motif pool.
- **Mainnet's pool size**: cap 4,000 and per-bid limit 1,500 here, 1,000,000 and 1,000,000 on mainnet; bids
  above about 4 ETH over the minimum and the `uint128` bid bound were not generated.
- **Real data**: stand-in grids, names and page; rendering correctness is checked only as far as the scheme
  prefix of each `tokenURI` and the exact `pieceOf` string.
- **Gas pricing**: Medusa's EVM prices gas by today's rules (Prague); Glamsterdam repricing (the reason for the
  PRIZE_GAS change) is not modelled. The fuzzed gas limits cover both PRIZE_GAS floors under current pricing.
- **Constructors**: one deployment; the `InvalidConfiguration` refusals are not fuzzed (covered by unit tests).
- **Actors**: four bidders; contract wallets limited to MoodyWallet's behaviours; ERC-1271 modelled as a wallet
  that approves any digest; EOAs assumed to take ETH and NFTs.
- **Ordering and MEV**: Medusa runs a sequence in its own blocks; same-block ordering against other senders,
  reorgs and chain-id changes are not modelled.
- Medusa's coverage omits calls made only by property checks (mitigated by `views_read`).

## Runtime and environment

| | Run 1 | Run 2 |
|---|---|---|
| Started | 14:54:56 UTC (corpus of the last smoke run: 318 sequences) | built 18:06 UTC and started by the lead from run 1's corpus (369 sequences); ended 19:10 UTC |
| Fuzzing time | 3 h 09 m 52 s, stopped when Claude was restarted | 59 m 59 s (`run.sh fuzz 3600 8`) |
| Calls | 11,920,331 | 4,456,116 |
| Sequences (failed) | 119,346 (0) | 44,759 (0) |
| Branches | 6,753 | 6,762 |
| PRIZE_GAS compiled | 500,000 | 1,000,000 |
| Log | scratchpad `campaign.log` | scratchpad `campaign2.log` |

Throughput was 330-1,700 calls/s: the machine (18 cores) was shared with Certora and Halmos jobs (load
average up to 134 in the first hour). Six smoke runs (2-4 minutes each) preceded run 1.

## Housekeeping and one incident

- Builds went only to `contracts/.tools-out/medusa/` (`out`, `cache`, `forge-out`, `forge-cache`,
  `crytic-export`). `contracts/out` is unchanged (every file's size and mtime compared with a snapshot taken
  before the first build, last at 20:40 UTC).
- **Incident, fixed**: forge keeps `test_failures_file` (default `cache/test-failures`) outside `cache_path`, so
  the first failing run of the scripted Foundry test, at 14:18:42 UTC, overwrote `contracts/cache/test-failures`
  (36 bytes, "testOneOfOneRealPageGoldenAndFraming", 14:09:18 UTC) with "test_lifecycleReachesEveryStage". It was
  restored at about 14:58 UTC to the previous bytes and mtime (checked against the snapshot), and `run.sh forge`
  now also sets `FOUNDRY_TEST_FAILURES_FILE`, `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR` and
  `FOUNDRY_FUZZ_FAILURE_PERSIST_DIR` to `.tools-out/medusa/forge-cache/`. The file has changed twice since, from
  another workflow's `forge test` runs ("testHeavyPool" at 15:11:04 UTC, then
  "testSettleGasCoversBothPricingsAndSepolia" at 15:36:08 UTC), not from this one. No other file in `contracts/cache`
  changed.
- No source outside `contracts/security/medusa/` and this file was edited; no commit, push or upload.
