# Proofs of concept, final audit of 11 October 2026

Two Foundry tests written by the audit (see [../../AUDIT.md](../../AUDIT.md), FA-01 and FA-02). Each asserts the property the finding says is missing, so each **fails** on the code as it stands. They are kept here, outside `test/`, so the suite stays green; they become regression tests once the finding is fixed.

To run one, copy it into `test/review/` (the imports are relative to that folder) and run only that file:

    cp audit/poc-2026-10-11/GridsGateIsLexicalPoC.t.sol test/review/
    node scripts/forge.mjs test --match-path test/review/GridsGateIsLexicalPoC.t.sol -vv

- `GridsGateIsLexicalPoC.t.sol` (FA-01): an artwork that only names `KILIM_GRIDS` in a comment, and keeps drawing its own copy of the motifs, passes the deploy script's mainnet gate. Fails with "next call did not revert as expected". It keeps failing on purpose: the script cannot run a browser, so the proof of use lives in `onchain/test/page.test.mjs` (fixed 11 October, see AUDIT.md).
- `GlamsterdamBroadcastGasPoC.t.sol` (FA-02): the gas limit forge signs from its Cancun simulation (×130%) against what a Glamsterdam chain charges for the same creation under EIP-8037. Fails for a full store chunk (about 7.0M signed, about 38.3M needed) and for each of the three contracts. The live Sepolia measurement that confirms it is in `../final-audit-2026-10-11.json`, key `glamsterdam`.
