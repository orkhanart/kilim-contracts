# Aderyn 0.6.8: triage

12 October 2026. Aderyn 0.6.8 (Cyfrin), 88 detectors, on the five mainnet sources at 2a63a727
(`src/KilimAuction.sol`, `src/auction/EnglishAuction.sol`, `src/KilimMotifs.sol`, `src/KilimOneOfOne.sol`,
`src/KilimBazaar.sol`; 1,972 nSLOC). Run on a copy of `src/` so `contracts/out` was not touched:

```
cp -R src foundry.toml .tools-out/aderyn/project/ && ln -s ../../../node_modules .tools-out/aderyn/project/
cd .tools-out/aderyn/project && aderyn . -s src -o ../../../audit/tools-2026-10-12/aderyn-report.md
```

Full output: `aderyn-report.md` (4 high, 13 low categories). **Result: no real issue.** Every high is a
false positive or intended; every low is style or gas.

## High

| Aderyn | Where | Verdict |
| --- | --- | --- |
| H-1 Reentrancy: state change after external call | `KilimAuction.sol:84,90`; `KilimBazaar.sol:162–178` | False positive. Constructor reads (`minter()`, `motifCap()`, `codehash`) of contracts named in the config; nothing can re-enter a constructor. |
| H-1 (same) | `KilimBazaar.sol:219` `deposit` | False positive. `nonReentrant`; `_take` calls only Motif Bazaar's own `transferFrom` and `burn`, which have no receiver callback. |
| H-2 Storage array edited with memory | `KilimMotifs.sol:212,269,271`; `KilimOneOfOne.sol:342,344` | False positive. These are `string.concat` in view functions building JSON; no storage array is passed. |
| H-3 Unsafe integer casts | `KilimAuction.sol:182–183`; `KilimBazaar.sol:211–212, 604, 631, 635–636` | Intended; each cast is bounded and commented: `take <= remaining` (uint128); ids `<= motifCap` (uint32); counts `<= MAX_BATCH`/1,024 (uint16/uint32); rank-lane number `< 2^32`; flags are 3 bits (uint8); `sealBlock = block.number + 1` fits uint40 (about 1.1 × 10^12 blocks). `_fold` uses `SafeCast` for the one sum that could grow. The Halmos run checks the bounds that matter. |
| H-4 Yul block contains `return` | `KilimBazaar.sol:1075` (`_respondWithPage`, private, reached only from `tokenURI`); `KilimOneOfOne.sol:328` (`tokenURI`) | Intended: the page is ABI-encoded in place and handed back to stop copying ~2 MB twice. Safe while nothing calls these internally; a grep finds no internal caller of either. |

## Low (13 categories)

Style or gas, no change advised before the freeze: costly operations in loops (bounded batches);
empty block; large literals; literals instead of constants; shadowing; modifier used once; `nonReentrant` not first
on `KilimMotifs.sol:109` (the other modifier is a plain check, nothing to re-enter); `require` in loops;
"could be immutable" (strings cannot be immutable); unchecked return (`_requireOwned`, called as a check);
uninitialised locals (zero by design); public function not used internally; "unused" constants (used inside
assembly: `GRID_BYTES`, `HEX_CHARS`, `SCHEME`).
