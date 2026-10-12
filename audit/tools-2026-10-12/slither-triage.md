# Slither 0.11.6: triage

12 October 2026, Slither 0.11.6 (102 detectors), same source copy as the Aderyn run (`contracts/out` not
touched). Raw output: `slither-0.11.6.json` (local only, 6 MB; `slither-summary.json` lists every result). 3 high, 28 medium, 20 low, 42 informational.

The 9 October run (Slither 0.11.5) found no high or medium in the four auction-side contracts. **Every high
and medium here is in `KilimBazaar.sol`, which did not exist then.** The other four files are unchanged.

## High: none real

| Detector | Where | Verdict |
| --- | --- | --- |
| weak-prng | `KilimBazaar.sol:997` | False positive. `mod(sub(3, mod(m, 3)), 3)` pads the page length to a multiple of 3 for base64; it is not randomness. The seal seed (`seal`, line 270, from a block hash) is the real randomness question. It is a known open item (re-roll by withholding) and the AI audit's seal lens covers it. |
| incorrect-return | `tokenURI` → `_respondWithPage` (`KilimBazaar.sol:388`, `868`) | Intended: the page is ABI-encoded in place and returned from assembly. `_respondWithPage` is private and its only caller is `tokenURI`, so no caller's code is skipped. Same as Aderyn H-4. |
| uninitialized-state `_hands` | `KilimBazaar.sol:119` | False positive. `_hands` is written through `uint256[64] storage words = _hands[key]` in `_record` (545, 560–566) and `_fold` (576); Slither does not follow writes through storage references. The page tests read those counts back. |

## Medium: none real

- **incorrect-equality** (17): `==` on lengths, ranks, flags, escape characters and the page's end position.
  These are exact checks by design, not balance comparisons.
- **reentrancy-no-eth** (2): `deposit` and `makeFromLoom` write the loom after `_take`. Both are
  `nonReentrant` (one transient guard shared by `make`, `deposit`, `makeFromLoom`, `seal`). `_take` calls only
  Motif Bazaar's `transferFrom`/`burn`, which have no receiver callback. The one call that reaches unknown
  code, `_safeMint`, comes after every write.
- **uninitialized-local** (9): accumulators meant to start at zero.

## Low and informational

calls-loop (bounded batches into Motif Bazaar), timestamp (the auction clock, documented since 9 October),
reentrancy-benign/events (after-call events in guarded functions), assembly, low-level calls (the history
contract's staticcall and `_pay`), too-many-digits (constants), pragma.
