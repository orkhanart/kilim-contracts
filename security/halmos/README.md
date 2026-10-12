# Halmos symbolic tests

Bounded symbolic checks (a16z Halmos 0.3.3) of the Kilim contracts in `src/`. They run only under Halmos.
They use Halmos's sequential CREATE addresses and its `svm` cheatcodes, so they never run under `forge test`.
Results, bounds and analysis: `../../audit/tools-2026-10-12/halmos.md`.

## Run

From `contracts/`, one file at a time (the seal checks need their own storage model and branching limit):

```sh
security/halmos/run.sh --match-contract '^AuctionMathHalmos$' --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^AuctionSolvencyHalmos$' --early-exit --loop 4 --solver-timeout-assertion 600s
security/halmos/run.sh --match-contract '^(RewardForBidHalmos|MotifAllocationHalmos|MotifClaimHalmos|MotifsHalmos)$' --loop 65 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^(BazaarRankHalmos|BazaarLoomHalmos|BazaarMakeHalmos)$' --loop 16 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^BazaarSealHalmos$' --storage-layout generic --solver-timeout-branching 10s --loop 16 --solver-timeout-assertion 300s
security/halmos/run.sh --match-contract '^AuctionInvariant(Fresh|Started)Halmos$' --invariant-depth 2 --loop 4 --solver-timeout-assertion 120s
```

`run.sh` builds into `contracts/.tools-out/halmos/{out,cache}`, never into `contracts/out` or
`contracts/cache`. It puts the pinned forge 1.7.1 from `node_modules`, and the yices/z3 that ship in
Halmos's own venv, on `PATH`, then runs Halmos under `nice -n 10`. Extra arguments go to Halmos. Use
`--match-test 'step_'`, `'reach_'` and so on to run part of a file.

Expect, when everything is as in the report:

- `*_EXPECTED_FAIL` checks FAIL. They are reachability probes: a counterexample proves that the matching
  check's success path is reachable. `check_isNewWinningBid_unboundedPanics_EXPECTED_FAIL` is the exception:
  it shows why `_handleBid` bounds the amount before the upstream predicate.
- TIMEOUT: every bid-increment check in `AuctionMathHalmos` except `check_firstBid_reserveExact`; also
  `check_step_bid` (both amounts symbolic) and `check_rewardForBid_monotone_mainnet`. The solver cannot
  decide 256-bit division by a symbolic value; the report has the details.
- The invariant suites take hours (3,500+ paths per invariant at depth 2).

## Files

| File | What it checks |
|---|---|
| `HalmosBase.sol` | Cheatcode interfaces; a stand-in motif store and page; the trio deployed in the script's order; test wallets (one that rejects ETH, one that re-enters); branch-free logic helpers. |
| `AuctionMath.t.sol` | `minimumBid()` against the predicate `_handleBid` enforces (`_isNewWinningBid`), through a harness that only exposes them. |
| `AuctionSolvency.t.sol` | One symbolic call to each auction entry point from any state that satisfies the invariant set. The set, solvency included, holds after the call (inductive). |
| `AuctionInvariant.t.sol` | Halmos `invariant_` tests over the real deployment: every sequence of up to `--invariant-depth` symbolic calls. |
| `MotifCredits.t.sol` | `rewardForBid`, the id reservations of symbolic bid sequences, `highestBidMotifs`, and claims in two parts. |
| `Motifs.t.sol` | `KilimMotifs.mintMotifs` range check, the burned bitmap, no double mint. |
| `Bazaar.t.sol` | Rank and ladder, the seal window and re-arm, the loom fold's lane arithmetic, the tally lanes and the winning-bid flag. |
