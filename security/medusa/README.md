# Medusa campaign (Chimera layout)

A stateful fuzzing harness for the four mainnet contracts (KilimAuction with its EnglishAuction base,
KilimMotifs, KilimOneOfOne, KilimBazaar), written once and run by two tools:

- **Medusa 1.5.1** (`CryticTester`), the main campaign;
- **Foundry 1.7.1** (`CryticToFoundry`), the same handlers and properties as invariants, plus one scripted
  walk through every stage.

The results of the 12 October 2026 campaign are in `../../audit/tools-2026-10-12/medusa.md`.

## Layout

```
security/medusa/
  medusa.json                 Medusa config (8 workers; corpus in corpus/, git-ignored)
  run.sh                      build | fuzz | forge, every output under contracts/.tools-out/medusa/
  coverage_summary.py         per-function / per-line summary of Medusa's lcov for the src/ contracts
  lib/chimera/                Recon's Chimera, vendored (see Provenance)
  recon/
    Setup.sol                 deployment (as the deploy script orders it), actors, ghost ledger
    Properties.sol            property_* (checked after every call), optimize_* (reachability)
    TargetFunctions.sol       the handlers: every call to the system, with its expected outcome
    Mocks.sol                 MoodyWallet (accepts / rejects / burns gas / re-enters), Blank
    CryticTester.sol          Medusa's target: TargetFunctions + CryticAsserts
    FoundryAsserts.sol        Chimera's Asserts for Foundry without forge-std
    CryticToFoundry.t.sol     Foundry's target: the properties as invariant_*, and a scripted lifecycle test
```

## Commands

Run from `contracts/`. Nothing here writes to `contracts/out` or `contracts/cache`: `run.sh` points
forge's `out`, `cache_path`, `test_failures_file` and both failure-persist directories at
`.tools-out/medusa/`, and Medusa reads the build through crytic-compile with `--ignore-compile
--foundry-ignore-compile --skip-clean` (crytic-compile otherwise runs `forge clean` first).

```sh
# Build the Medusa target only (a clean build into .tools-out/medusa/out, with build info).
security/medusa/run.sh build

# Build, then fuzz for N seconds with W workers, under nice -n 10 and caffeinate -i.
security/medusa/run.sh fuzz 3600 8           # one hour (12 October: 3 h 10 m, then this, from the same corpus)
security/medusa/run.sh fuzz 120 8            # a smoke run

# The same suite under Foundry (fail_on_revert = true; depth 120; runs from the profile, 128 by default).
security/medusa/run.sh forge --threads 2
FOUNDRY_INVARIANT_RUNS=1000 security/medusa/run.sh forge --threads 2 --match-test invariant_
security/medusa/run.sh forge --match-test test_lifecycleReachesEveryStage -vvv

# After a Medusa run: coverage per function and every src/ line never executed. Add --sources DIR (copies of
# the compiled src files) if src/ changed after the run was compiled: Medusa reports the source it read then.
python3 security/medusa/coverage_summary.py security/medusa/corpus/coverage/lcov.info
```

Medusa writes `corpus/coverage/coverage_report.html`, `lcov.info` and `revert_report.html` at the end of a
run, and keeps the corpus in `corpus/` (a later run starts from it; delete it for a fresh start). Medusa
`chdir`s to this folder, so the paths in `medusa.json` are relative to it.

To turn a Medusa failure into a Foundry test, copy the numbered calls of the shrunk sequence into a test in
`CryticToFoundry.t.sol`, in order, as calls to the same handler functions with the same arguments; put
`vm.warp`/`vm.roll` before a call whose `time=`/`block=` moved.

## What the harness does

Actors: two EOAs with known keys (they can sign `registerFor`), two `MoodyWallet` contract wallets whose ETH
and NFT receivers can accept, reject, burn all the gas, or re-enter the contract paying them (and which can
approve ERC-1271 registrations), the treasury (an EOA), and up to 100 throwaway registrants.

The deployment is the deploy script's: stand-in grid, name and page stores, the motif collection and the
1/1 naming the auction's predicted address, the auction with the mainnet terms (24 h, 10-minute extension,
10% increment, 0.01 ETH reserve) except a motif cap of 4,000 and a per-bid limit of 1,500 (so the pool
can run dry and the per-bid clamp can bind), and the Bazaar, deployed before settlement, with the EIP-2935
history contract etched first so its seed window is 8,191 blocks.

Each handler predicts, from the rules, whether its call must succeed, must fail, or may go either way (a
gas-capped call, a re-entering wallet), asserts the prediction, and on success asserts the exact effects
(balances, refunds, credits, minted ids, the kilim record and hand, the seal). A ghost ledger mirrors what
should be true; the `property_*` functions compare the contracts with it after every call. The
`optimize_*` functions are reachability probes: Medusa reports the largest value each reached (number of
kilims, seals, history-contract seals, re-arms, Master kilims, deferred refunds, prize claims, ...).

Two Medusa 1.5.1 behaviours the harness works around (both explained in the report):

- Medusa commits a block only when it holds a contract creation; otherwise it renumbers one pending
  block, so no block hash would exist for a kilim's seal block. The Bazaar and chain handlers deploy an
  empty `Blank` contract so blocks get committed and `blockhash` has something to return.
- The EIP-2935 history contract, etched in the constructor, did not answer with the hash the harness wrote
  into its slot with `vm.store`, even when re-etched inside the same transaction (Foundry does). The seal
  model therefore asks the history contract what it answers instead of assuming (mismatches are counted by
  `optimize_historyMismatch`); under Medusa that path never yields a hash, so the 257-8,191-block seal path
  is exercised only by the Foundry run of the same harness.

## Provenance of `lib/chimera`

Recon-Fuzz/chimera, tag `0.1.4`, commit `0d37c2b8998756680e76d859c343e01c4fc1e006`
(https://github.com/Recon-Fuzz/chimera), cloned 12 October 2026. Copied unchanged: `Asserts.sol`,
`BaseProperties.sol`, `BaseSetup.sol`, `BaseTargetFunctions.sol`, `CryticAsserts.sol`, `Hevm.sol`, and the
upstream `README.md`. The tag has no LICENSE file; every source file carries `SPDX-License-Identifier: MIT`.
Left out: `FoundryAsserts.sol`, `BaseCryticToFoundry.t.sol` and `HalmosAsserts.sol`, which import forge-std
(not vendored in this repo); `recon/FoundryAsserts.sol` replaces the first.
