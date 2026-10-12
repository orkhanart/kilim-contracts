# AI audit, 12 October 2026: the Kilim Bazaar seal and the metadata it produces

Lens: `seal`, `sealState`, the seed, the 8,191-block window (EIP-2935 history contract plus `blockhash`), re-arm, the seal events, and `tokenURI`/`pieceOf` (the stored 1/1 page with `;window.KILIM_PIECE=` spliced in, JSON, base64, determinism, ERC-4906). This is one AI reviewer, not the independent audit.

Files read: `src/KilimBazaar.sol` (all of it), `docs/KILIM-BAZAAR-SPEC.md` (all of it, including Deviations 1–19), the AUDIT.md sections that mention the Bazaar, `launch/KILIM-BAZAAR-RULES.md`, `living-language-v3/source/bazaar.js`, `app.js:20-32` and `field.js:29` (the page side), `EnglishAuction.sol` (settle and bid), `KilimOneOfOne.sol` (the chunk lists), `KilimMotifs.sol` (names and grids), `script/DeployKilimBazaar.s.sol:255`, `site/chain.js:990-1075`, `landing-departure/src/components/Weave.tsx:250-290`, and the existing Bazaar tests.

PoC suite: `contracts/security/ai-audit/seal/SealAudit.t.sol`, built on `test/bazaar/BazaarBase.sol` and the committed fixture page store. Run with:

```
cd contracts && FOUNDRY_OUT=.tools-out/ai-seal/out FOUNDRY_CACHE_PATH=.tools-out/ai-seal/cache \
  FOUNDRY_TEST=security/ai-audit/seal nice -n 10 node scripts/forge.mjs test -vvv
```

Result: **12 passed, 0 failed**. The SL-* tests pass when the behaviour they describe is present. The check_* tests pin what was checked and found sound.

## Findings

| ID | Severity | Where | Proof |
|---|---|---|---|
| SL-1 | **Medium** (known on-chain behaviour; the mitigation it relies on does not exist) | `src/KilimBazaar.sol:256-259`, `site/chain.js:1011-1017`, spec §4 line 383, Deviation 17 | PoC, passes |
| SL-2 | Low | `src/KilimBazaar.sol:258` | PoC, passes |
| SL-3 | Info (accepted residual risk, now quantified) | `src/KilimBazaar.sol:627`, `:270` | PoC, passes |
| SL-4 | Info | `src/KilimBazaar.sol:358-365` vs `:261-269` | PoC, passes |
| SL-5 | Info | `launch/KILIM-BAZAAR-RULES.md:44`, `:81`; `landing-departure/src/components/Weave.tsx:267` | text, no PoC |
| SL-6 | Info (unproven, documented open item) | page side: `app.js:27`, Deviation 13 | not tested (Firefox, Safari and WKWebView not available without changing system settings) |

No Critical or High finding. No way was found to make `tokenURI` revert, emit invalid JSON or HTML, or let a value escape the `window.KILIM_PIECE=` statement.

### SL-1 — Medium: withholding re-rolls the look as often as the owner likes, and the sealer the acceptance relies on does not exist

**What the code does.** This part is as documented. A kilim made in block B gets its seed from `hash(B+1)`. The hash is public from B+2, so the owner can compute the seed and the exact look before anything is sealed: `seed = uint32(keccak256(abi.encode(hash(B+1), bazaar, id)))`. The artwork itself accepts `?piece={seed,motifs,top}` (`app.js:27`), so no engine needs rebuilding to preview it. If nobody calls `seal` within 8,191 blocks, the next `seal` re-arms to `block.number + 1` (`KilimBazaar.sol:256-259`), which is a fresh draw. Repeat as often as wanted.

**Why it is not just the accepted Deviation 17.** The spec accepts withholding on one premise, stated in §4 line 383 and §4 line 393: "the site runs a sealer with no privileges: one batched `seal` per block for every pending `KilimWoven`". Deviation 17 adds: "What holds rule 7 is the sealer: it must run for as long as kilims can be made". **No such sealer exists in the repository**:

- No server, relayer or script calls `seal`.
- `site/chain.js:1011-1017` and the landing page's `Weave.tsx:289` seal from the *maker's own wallet* as an optional "second, small prompt". The maker can simply decline it, and by then B+1 is mined, so the seed can already be computed.
- `contracts/checklists/*`, `README.md` and `TODO.md` never mention a sealer.
- Meanwhile the rules still promise "No preview, no re-roll" (`launch/KILIM-BAZAAR-RULES.md:44`).

**Failure scenario, proven.** `test_SL1_OwnerWithholdsAndReArmsUntilTheApprenticeHasTheFieldTheyWant`:

1. Alice makes an Apprentice and never signs the seal prompt.
2. At each draw she reads `hash(sealBlock)` and computes the page's first draw, using a port of `field.js` `rng` checked against node in `test_check_PagePickPortMatchesFieldJs`.
3. She waits 8,192 blocks and re-arms, until the field she wants comes up. It took 7 draws: 49,160 blocks, about 6.8 days.
4. The sealed seed equals the one she previewed.

`test_SL1_OwnerReRollsAMasterUntilItIsOneOfTheThreeGames` does the same for a Master. At a 0.01 ETH close every 10-motif kilim is the Master. Its pool of 69 ends with the three games "only Masters have". Getting one took 21 draws, about 22 days.

`test_check_AThirdPartySealInsideTheWindowEndsTheReRoll` shows the countermeasure works when it exists: one seal by anyone, at any age up to 8,191, fixes the first draw for good.

**Impact.** No funds are at risk. A published fairness rule (rule 7) is false for any owner willing to wait. The scarcest looks (a Master's games, 3 in 69; a chosen field; a chosen ground) can be farmed at about 27.3 hours and roughly 32k gas per extra draw. Each lapse is also a window to sell a "Sealing" kilim whose look the seller already knows (Deviation 17). Nothing on-chain can close this: once a hash is older than 8,191 blocks, nothing can read it.

**Suggested fix (off-chain; the contract is frozen).**

- Run the sealer the spec describes, from the moment `make` opens and for as long as any kilim can be made or is unsealed. That means forever in practice: every kilim made after the sealer stops is re-rollable.
- Scope: watch `KilimMade` **and** `SeedRearmed`, and send one batched `seal` per block from an unprivileged funded key. Decide success from `KilimSealed` logs, not from `sealState` (see SL-4).
- Run at least two independent operators (for example your own service plus a hosted automation task).
- Alert on any kilim whose `sealState` is not 4 more than about 100 blocks after its `sealBlock`.
- Add the sealer to `checklists/0-launch-steps.md` and `3-post-deploy.md`.
- Until it runs, reword rule 7 and the site copy to say plainly that a kilim nobody seals within about 27 hours draws again (Deviation 17 already asks for this).

### SL-2 — Low: after a lapse, any caller chooses which block's hash becomes the seed

`seal` re-arms to `block.number + 1` (`KilimBazaar.sol:258`), so whoever triggers the re-arm picks the new seal block. If that caller builds the next block (as a builder, or as a proposer building their own block), or pays its builder, they grind that block's header and set the look.

`test_SL2_AfterALapseAnyCallerTimesTheReArmToABlockTheyBuildAndPicksTheLook`: Carol, a stranger, re-arms Alice's lapsed Apprentice in a block she chose. She then "builds" the next one and tries header candidates until the field is the one she wants. It took 9 tries, and Bob's later seal locks that look in.

This needs a lapse (SL-1) and block-building access. Without re-arm, a lapsed kilim would read "Sealing" forever, so re-arm is still the right call. The caller-timed block only adds this alignment.

Suggested fix, only if the freeze is ever lifted: re-arm to the next point on a fixed grid instead of a caller-timed block, for example the smallest `sb + j·(seedWindow + 1)` above `block.number`. Then nobody can line the draw up with a block they build. It does not remove SL-1.

### SL-3 — Info: the builder of the seal block has full control (accepted residual risk, quantified)

The seed depends only on `hash(B+1)`. The builder of B+1 can try any number of `extraData` values at the cost of a header hash each. The proposer of B+1 can do the same by building locally, giving up that slot's MEV-boost payment.

`test_SL3_TheBuilderOfTheSealBlockPicksAMastersGameInAFewDozenHashes`: a Master's game in 9 header candidates. In general, a first-order look takes about pool-size hashes (10 to 69). An exact 32-bit seed takes about 2^32 hashes, seconds on a GPU.

Ways to get there:

- A maker who is a validator knows the proposer schedule an epoch ahead. They can bundle `make` into the block just before their own slot. A missed bundle costs nothing.
- A dominant builder that wins both B and B+1 can place `make` at the end of B, which happens often.
- A proposer of B+1 who simply skips the slot gets one independent re-draw, at the cost of that slot's rewards.
- The next proposer's late-block reorg of B+1 is also one opportunistic re-draw.

This is the residual risk spec §4 accepts. No change is suggested beyond stating it in the rules.

### SL-4 — Info: `sealState` says "sealable now" when `seal` would skip

`sealState` returns 2 for any age from 1 to `seedWindow` (`KilimBazaar.sol:358-365`). `seal` skips with no state change when the lookup returns zero or fails (`:261-269`), for example when the slot was never written or a later fork changes the history contract. `test_SL4_SealStateSaysSealableWhenSealWouldSkip` shows this. On mainnet with the canonical contract it cannot happen inside the window. A sealer should still count `KilimSealed` logs. `site/chain.js:1045` already does.

### SL-5 — Info: the rules and UI copy contradict the contract

- `launch/KILIM-BAZAAR-RULES.md:44` says "No preview, no re-roll". Both are possible today (SL-1).
- `:81` still says a 256-block window (it is 8,191 on mainnet). Deviation 16 already lists this.
- `landing-departure/src/components/Weave.tsx:267` tells a maker whose seal failed "Seal it below: anyone can, any time". After about 27.3 hours, a seal re-arms instead, and the look the maker may have seen changes.
- A buyer who previews an unsealed kilim near the end of its window can lose that look to a lapse before they can seal it.

### SL-6 — Info, unproven: `window.KILIM_PIECE` surviving `document.open()` is untested outside Chrome

Deviation 13 lists Firefox, Safari and iOS WKWebView as not done. If a browser drops the window property, `app.js:27` falls back to `?piece=` (empty in a `data:` URL), and the page draws **the 1/1** (full engine, interactive) instead of the kilim. Modern HTML (the 2019 `document.open()` simplification) keeps the Window, so this is probably fine. It is a launch check, not a contract defect. It should also be checked inside a sandboxed marketplace iframe, as the 1/1 was.

## Seed control per actor

| Actor | What they can do | Cost | Control over the seed |
|---|---|---|---|
| Maker or owner, with an independent sealer running | choose when to `make` | — | none: one uniform draw. `hash(B+1)` does not exist during `make`, and `seal` skips in blocks B and B+1 (`:254`), so neither a receiver hook nor a same-block or bundled make-and-seal can see it |
| Maker or owner, **no sealer (the repo today)** | decline the seal prompt, preview off-chain, re-arm after 8,192 blocks | about 27.3 h and about 32k gas per extra draw (re-arm measured at 31,547 gas, Deviation figures) | best of N, where N ≈ 0.88 × days waited. A 1-in-k look takes about k draws: a chosen field k = 10 (PoC: 7 draws, 6.8 days), a Master game k = 23 (PoC: 21 draws, 22 days) |
| Any `seal` caller inside the window | none | — | none: same seed for every caller and every block from age 1 to 8,191 (existing `testTheSeedIsTheSameForAnyCallerAtAnyBlockInTheWindow`). A gas-starved lookup reverts the call rather than skipping the kilim (`test_check_AStarvedHistoryLookupNeverSucceedsWithoutSealing`, swept 3k–40k gas). No re-arm can be forced inside the window |
| Any caller after a lapse | picks the re-arm block | about 32k gas | none alone; full if they build the next block (SL-2) |
| Proposer of B+1 on MEV-boost | pick among builder bids, or skip the slot | the slot's rewards for a skip | log2(number of bids) bits; one independent re-draw per skipped slot |
| Builder of B+1, or a proposer who builds locally | grind the header | negligible compute (the proposer gives up the MEV-boost payment) | full (SL-3) |
| Proposer of B+2 | reorg a late B+1 | opportunistic | one re-draw |

**Does re-arm make it worse?** It is what turns a lapse into a fresh draw, and so it enables SL-1's unlimited re-rolls once nobody seals. Its caller-timed block adds SL-2. Inside the window it changes nothing: re-arm is decided from block numbers alone, and a failed lookup only skips. No on-chain variant removes the lapse re-roll. The fix is the sealer.

## Checked and found sound

- **EIP-2935 on mainnet today.** `eth_getCode(0x0000F908…2935)` on mainnet (head 26,176,868) is byte-identical to the test fixture. Its keccak equals `HISTORY_CODEHASH` (`test_check_HistoryCodehashIsMainnets`). A live `eth_call` 5,000 blocks back returned exactly that block's hash (`0x0c79e0a2…9d43`), and 9,000 back reverted.
- **The window lines up exactly.** The canonical code answers ages 1 to 8,191 (the Bazaar's `age <= seedWindow`), reverts at ages 0 and 8,192, and answers zero for an unwritten slot, which `seal` treats as skip (`test_check_HistoryAnswersExactlyTheBazaarsWindow`). The ring-buffer overwrite of slot `sb % 8191` happens at block `sb + 8192`, which is already past the window. `abi.encode(sb)` is the exact 32 bytes the contract requires.
- **Deployment.** The deploy script refuses a window other than 8,191 on mainnet and Sepolia (`script/DeployKilimBazaar.s.sol:255`). If the code at that address ever changed after deployment, a lookup at ages 257 to 8,191 would only skip, and ages 1 to 256 still use `BLOCKHASH`.
- **No kilim can stay unsealable forever.** After any make or re-arm, a seal at ages 1 to 256 reads a nonzero `BLOCKHASH` on mainnet. A history failure only skips, and a lapse re-arms. `uint40` block numbers do not overflow.
- **Determinism.** Every `tokenURI` input is fixed once the auction is settled:
  - `highestBid` is never written after `settle` (`EnglishAuction.sol:167-173`; `withdrawProceeds` touches only `proceedsDue`).
  - The 1/1's chunk lists are set once in its constructor, and the grids and names are hash-pinned.
  - The texts are set once, and hands are never written after their kilim is made, because loom keys are never reused.
  - The unsealed answer is unchanged through re-arms, the sealed answer is unchanged later and after a transfer, and exactly one `MetadataUpdate` is emitted, at seal (`test_check_TokenUriChangesOnlyAtTheSealWhichSignalsIt`).
  - The only mutable part is the off-chain picture behind `imageBase` (Deviation 18).
- **JSON, HTML and JS.** Every value written into the answer is one of these:
  - a constant (rank names, keys);
  - contract-written digits or hex (numbers, seed, piece);
  - constructor-checked printable ASCII without `"`, `\`, `#` or `%` (description, links, image base);
  - an escaped motif name. All 1,024 real names in `onchain/build-motifs/names.bin` are printable ASCII without `"`, `\`, `#` or `%` (checked by parsing the offset table).

  `S` uses only `{}[]":,`, digits, `0x`-hex and the letters of its three keys, even with a 78-digit `top`. It cannot contain `'`, `<` or `/`, so it cannot close the GRIDS string or the loader's script (`test_check_PieceWithTheLargestTopStaysSafe`). The `_piece` buffer's last whole-word write ends at offset 169 + 13·d, inside its 192 + 13·d allocation. The splice keeps base64 joinable because `m` is a multiple of 3. The in-place encoder bounds hold for any `before` length, and the exact-length check guards the end.
- **No reachable `tokenURI` revert for a minted kilim.** The title is always 1 to 1,024, `settled()` is true for any existing kilim, the size of the `grids()` answer is checked, and the repo's worst-case read is 7.61M gas, under 8M and under the 16.7M `eth_call` cap.
- **Page agreement.** `readPiece` parses `"0x…"` with `parseInt(…,16)>>>0` and takes an integer `top`. The contract's `_rankFor` equals the page's filtered ladder: when `count < top`, the highest fixed cost at or under `count` is below `top`, so the page keeps it. Title ties go to the lowest number in both. Seed 0 is fine, because `SEALED` is a separate flag.
- **ERC-165** reports `0x49064906`. A re-arm correctly emits no `MetadataUpdate`, since the metadata does not change.

## What this review did not do

- No differential run of the full page `weave()` against the chain beyond the first `rng` draw (the port is pinned to node outputs).
- No browser run of kilim pages (SL-6).
- No look at Sepolia state or the running swarm test.
- No change to `src/`, `test/`, `script/`, `deploy/`, `scripts/`, `research/` or `out/`.
