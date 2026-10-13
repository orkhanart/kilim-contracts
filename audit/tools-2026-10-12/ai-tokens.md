# AI audit, 12 October 2026: token contracts, on-chain rendering, mainnet deploy path

> **Status, 12 October 2026 (later):** TK-1 and TK-2 are fixed in the deploy scripts (see AUDIT.md). The three PoC tests in `security/ai-audit/tokens/DeployPath.t.sol` that demonstrated them (`testMainnetBazaarScriptAcceptsAnAuctionTheArtistNeverDeployed`, `testMainnetJsonDeploysAtThePublishedAddresses`, `testMainnetConfigFailsClosedOnItsTodos`) now fail, as intended.


One of five independent AI reviewers (Claude, Opus 5.5). Lens: `src/KilimMotifs.sol`, `src/KilimOneOfOne.sol`, `script/DeployKilim.s.sol`, `script/DeployKilimBazaar.s.sol`, `deploy/mainnet.json`, the CREATE2 store, `checklists/0-2`, `scripts/`. Read against `AUDIT.md`; items it already records are listed as known, not as new findings. This is not the independent human audit (K-08).

**Result: no Medium or higher.** Two Low and six Info items. The token contracts have no admin, owner, pause or setter. Only the immutable minter (the auction) can mint, and only an owner can burn. Both tokens pass `slither-check-erc` ERC-721 with no failures. All 1,024 motif tokenURIs match the Python reference renderer byte for byte. The 1/1 over the real page equals its golden. Run on chain id 1, `deploy/mainnet.json` deploys at the three published addresses.

## How it was run

- PoC tests: `contracts/security/ai-audit/tokens/` (`TokenRendering.t.sol`, `DeployPath.t.sol`, and `MotifReferenceHashes.sol`, which is generated from `onchain/pack_motifs.py` by the script quoted at its top). They run on the real packed stores `onchain/build-motifs` and `onchain/build-page`.
  `cd contracts && FOUNDRY_OUT=.tools-out/ai-tokens/out FOUNDRY_CACHE_PATH=.tools-out/ai-tokens/cache FOUNDRY_TEST=security/ai-audit/tokens nice -n 10 node scripts/forge.mjs test -vvv`
  Result: **13 passed, 0 failed.** The fuzz test ran 512 runs.
- `slither-check-erc . KilimMotifs|KilimOneOfOne --erc ERC721 --foundry-ignore-compile --foundry-out-directory .tools-out/ai-tokens/out` (build-info from the run above): every function, return type, event and indexed parameter `[✓]`, nothing missing.
- `contracts/out` and `contracts/cache` were not written (mtimes still 11 October). Nothing was broadcast, no key was used, nothing in `src/`, `test/`, `script/`, `deploy/`, `scripts/` or `checklists/` was edited.

## Findings

### TK-1 — Low (proven): on chain 1, DeployKilimBazaar accepts an auction that orkhanart.eth never deployed

- **Where:** `script/DeployKilimBazaar.s.sol:171-217` (`check`). The comparisons with `bazaar.motifs` and `bazaar.oneOfOne` at `:183-188` are skipped when those keys are absent, and `deploy/mainnet.json:28-29` has neither key. Its `bazaar.auction` is `"TODO: the mainnet auction address, after runContracts"`.
- **Failure scenario:** the operator fills the TODO with a wrong address: a typo-squat, a phished link, or a Sepolia address with code on mainnet. That address can be a look-alike trio (an auction, a KilimMotifs and a KilimOneOfOne naming each other) that anyone can deploy over the public page chunks. Every check passes:
  - the minters agree;
  - `oneOfOne.tailHash()` equals `bazaar.pageTailHash`, because the attacker reuses the real TAIL chunks;
  - the page store manifest agrees;
  - the texts, ranks, sender orkhanart.eth, royalty receiver, imageBase and history contract all pass.

  A permanent "Kilim Bazaar" is then created from the artist's wallet, bound to fake contracts. It cannot touch real motifs, so no funds or tokens are at risk. The result is a wasted deploy and a lasting phishing and confusion vector under the artist's address. The same config already names `deployer` and `deployerNonce`, from which the real auction's address follows (`0xb4817D07…3423` at 1,568). The script never compares the two.
- **PoC:** `DeployPath.t.sol: testMainnetBazaarScriptAcceptsAnAuctionTheArtistNeverDeployed`. It builds a trio from the test contract over `onchain/build-page`, takes every other value from `deploy/mainnet.json` and switches to chain id 1 with the EIP-2935 code. `script.deploy(c, ARTIST)` succeeds and `b.auction()` is not the published auction. **PASS** (the script accepts it).
- **Fix:** on chain 1, require `c.auction == computeCreateAddress(LAUNCH_ARTIST, deployerNonce + 2)`, read from the same config's top-level `deployer` and `deployerNonce`. Alternatively, require `bazaar.motifs` and `bazaar.oneOfOne` on mainnet. Either way, fill `bazaar.auction`, `bazaar.motifs` and `bazaar.oneOfOne` now with the published addresses. The script still refuses until the auction has code (`the auction has no code`), so this costs nothing.

### TK-2 — Low (reproduced): the collection link, and the Bazaar's texts, are pinned by nothing in `expected`; V-08's fix compares the config with itself

- **Where:** `script/DeployKilim.s.sol:313-316` compares `collection.externalUrl` with the motif manifest's `.externalUrl`. `_requireExpected` (`:345-364`) checks eleven values, and none of them covers the link. `scripts/stores.mjs:43` writes that manifest field from `config.collection.externalUrl`.
- **Failure scenario:** someone edits `collection.externalUrl` in `deploy/mainnet.json` after sign-off and re-runs `pnpm -s stores`. The edit could be a mistake or come from another session in the shared tree. Every check passes:
  - the published `expected` block;
  - the chunk files and CREATE2 addresses;
  - `gridsHash` and `namesHash`;
  - `motifGolden`, which has no link in it;
  - `motifSource`.

  `KilimMotifs.contractURI()` then serves the wrong `external_link` forever. The same holds for `bazaar.description`, `externalUrl` and `imageBase`: format checks only, no hash. AUDIT V-08 calls the link pinned by the manifest, but the manifest is regenerated from the same config, so only the human sign-off pins it.
- **Reproduction:** `pack_motifs.build()` in memory with `--external-url https://attacker.example/kilim`, writing nothing. Against the real build, `gridsHash`, `namesHash`, `golden.tokenURI.sha256`, `source.sha256`, the chunk files and the chunk addresses are all unchanged. Only `externalUrl` differs. The script is in the session scratchpad, and the output is quoted in the final report.
- **Fix:** add `collectionExternalUrl` (or `keccak256` of all deployed texts, the Bazaar's included) to `expected` and to the published list, so a post-sign-off edit changes a published value.

### TK-3 — Info (proven): the read-gas policy samples one motif; the worst is 4.7x it

- **Where:** `DeployKilim._checkGolden` (`:746-769`) measures only the token showing `golden.motif` (motif 1, 287,324 gas). `checklists/1-pre-deploy.md:59` gives "a motif 287,312" as the motif read cost.
- **Measured** (`testEveryMotifTokenURIEqualsTheReferenceRenderer`, all 1,024 motifs, real store, warm): the maximum is **1,347,521 gas for motif #504** (94 runs, 7,477-byte answer). It is still far under 8M and every public `eth_call` cap. The same checklist line gives the 1/1 as 1,068,635 bytes; today's `tokenURI(1)` is **1,068,627** (after the Spinner re-pack).
- **Fix:** quote the worst case, or have the dry run measure motif 504 as well. No contract change.

### TK-4 — Info (proven): a third party can deploy a byte-identical "The Unwoven Kilim" that reads the real Motif Bazaar

- **Where:** the `KilimOneOfOne` constructor (`src/KilimOneOfOne.sol:68`) requires only that `motifs_` has code. Anyone can deploy one with their own minter, the public page chunks and `motifs_` set to the **real** Motif Bazaar, then mint id 1 to themselves.
- Its `tokenURI(1)` equals the golden exactly. The golden depends on the chunks and the grids, not on any address. `oneOfOne.motifs()` returns the genuine collection, so a naive "does it read the real Motif Bazaar?" check passes. `testOneOfOneRealPageGoldenAndFraming` shows the golden coming out of a 1/1 whose minter is the test contract.
- **Fix (docs only):** the phishing-clone notice and the site should verify by the published 1/1 address, or by `minter() == published auction`, never by content or by `motifs()`.

### TK-5 — Info (proven): the deployed 1/1 can be checked against its golden before `startsAt`

- `checklists/2-deploy.md:113` says `tokenURI(1)` cannot be read before the mint, so the only pre-auction golden check is forge's simulation.
- An `eth_call` with a state override fixes this. Set `_owners[1]` (OpenZeppelin ERC721, slot 2: `keccak256(abi.encode(1, 2))`) on the deployed 1/1 to any address, and the call reads the real on-chain `tokenURI(1)`.
- **Proof:** `testUnmintedOneOfOneReadsTheGoldenWithAStateOverride`. One `vm.store` makes an unminted 1/1 answer the golden, and the real mint writes exactly that slot.
- **Suggested read-back line:** `eth_call` `tokenURI(1)` with `stateOverride {<1/1>: {stateDiff: {keccak256(abi.encode(1,2)): <any address>}}}`, and compare its sha256 with `expected.oneOfOneGolden`.

### TK-6 — Info (unproven): store chunks can be front-run, which costs the store wallet one reverted transaction

- A chunk's CREATE2 address binds its bytes, so nobody can put other code there. The script verifies existing code and skips it (`_loadSection` `:397-400`). Squatting is impossible.
- Someone can deploy the same chunk between forge's simulation and the store wallet's broadcast. The broadcast then hits an EIP-684 collision: the call reverts and the init frame's gas is consumed (up to about 7.8M per full chunk at forge's 130%). The griefer pays a full chunk deployment of about 6M each time, so it is not profitable. A rerun skips the chunk.
- No action needed; worth one line in checklist 2 ("a reverted chunk transaction: rerun").

### TK-7 — Info (proven): the TODOs fail closed, but the order they impose is not what the config says

- `testMainnetConfigFailsClosedOnItsTodos`: `DeployKilim.loadConfig("deploy/mainnet.json")` and `DeployKilimBazaar.loadConfig(...)` both revert on the text values. `KILIM_BAZAAR_AUCTION` cannot override `bazaar.auction` because the key exists and is parsed first. That part is sound.
- Side effects:
  - (a) `runStore()` parses `auction.startsAt` (`DeployKilim.s.sol:208`) although it never uses it, so the launch date has to be chosen before the store goes up.
  - (b) The `_comment` (`deploy/mainnet.json:2`) says both TODO fields must be whole numbers "before either command runs". The two TODOs are now `startsAt` and `bazaar.auction`. The second can only be filled after `runContracts`, and it is an address, not a number.
- Related (by reading): a third creation mined after `startsAt` reverts in the constructor (`EnglishAuction.sol:99`) and voids both tokens (FA-04). With `minLeadSeconds` 86,400 that needs a pending creation stuck for more than 24 hours. The "wait or speed up, never cancel" rule covers it.

### TK-8 — Info: a clean checkout of the frozen tag has no stores

- `checklists/0-launch-steps.md:126` (step 10) says to run the contracts phase from a clean checkout of the frozen tag. `onchain/build-motifs/` and `onchain/build-page/` are git-ignored (`.gitignore:34-35`), so that checkout has neither.
- The step does not say to copy them in or to re-pack them with `pnpm -s stores`. Re-packing needs the same zlib, 1.2.12 as recorded in `blob.zlibVersion`. Otherwise TAIL changes and the script refuses `expected tailHash`.
- This fails closed. Add one line to the step.

## Known items re-checked (not new)

- **No bytecode pin in the script** (AUDIT, "Still to decide: … the bytecode pin in the script"). The goldens check output only. A modified token that renders identically and reads back the same immutables would pass every script check; only the manual tag checkout plus `pnpm -s artifacts` against `build-manifest.json` stops it. I agree it should be pinned: put each contract's `keccak256(creationCode)` in `expected`. Today's working tree matches `audit/build-manifest.json` (78 of 78 source hashes).
- **Glamsterdam** (FA-02), **the raw `data:` URL size at marketplaces**, **V-13** (motifs sent to the 1/1 are lost), **K-02** (layout fixed by deployer and nonce): unchanged and correctly described.

## What was checked and found sound

- **Roles.** KilimMotifs: `mintMotifs` is minter-only and `nonReentrant`, with batches of 1..64 and ids 1..motifCap (`firstId - 1 > motifCap - quantity`, no underflow). An id can never be minted twice, even after a burn (bitmap). `burn` is owner-only; approvals do not count. Neither the minter nor the contract can ever hold a motif. KilimOneOfOne: one mint by the minter, `minted` is set before `_safeMint`, and transfers to itself, its minter or the motif collection are refused. No owner, admin, pause, upgrade or setter; every address and text is immutable or set once in the constructor. Boundaries tested: ids 1, motifCap, `motifCap-64..motifCap-1`, `motifCap+1`, 0, `uint256.max`, batch 65, burn then re-mint, non-minter mint, mint to minter, transfer to minter.
- **ERC-721 and ERC-165.** `slither-check-erc` is clean for both. `supportsInterface` is true for 165, 721, 721-Metadata and 2981, and false for `0xffffffff` and Enumerable. ERC-2981 is 5% to the treasury. OpenZeppelin 5.6.1 supplies `safeTransferFrom` callbacks, events and approvals.
- **tokenURI correctness.** All 1,024 motifs:
  - The sha256 of the real contract's tokenURI equals Python's `motif_token_uri`, and Python's `json` parses all 1,024. The Motif trait is the string `"<n>"` and the name is `"<name> (motif <n>)"`. Python's motif-1 hash equals the manifest golden.
  - `grid(n)` and `motifName(n)` equal `grids.bin` and `names.bin` for every n, across the chunk boundary at 767/768. Both revert at 0 and 1,025.
  - Every name is printable ASCII with no `"`, `\`, `#` or `%` (longest 44 bytes). Every motif has at least 2 runs and at most 94.
- **JSON escaping.** Fuzzed over arbitrary bytes, 512 runs, via `contractURI()` with `Base64.decode`. The description field never holds a raw control byte, ends at the first unescaped quote, unescapes to exactly the input, and the JSON after it is intact.
- **KilimOneOfOne assembly** (read in full, then tested on the real page):
  - Memory layout: everything is written above the free pointer. The three chunk lists sit below it and are never overwritten. Scratch use is limited to 0x00-0x3f.
  - In-place hex: output word i ends at or before unread input word i+1, with equality at i = 1023.
  - In-place base64: the block write ends at or before the next unread byte while `j + 1 <= m/24`, and the tail groups satisfy `k + 1 <= r`.
  - Returndata: the size must be exactly 64 + 32,768, with offset 0x20 and length 32,768, otherwise `GridsUnavailable`; a failed inner call bubbles its error.
  - Exact length (`pos == ptr+64+total`, else revert), zeroed padding, and correct ABI framing (offset 0x20, then length, then data).
  - The answer is 1,068,627 bytes and equals the golden. Real read cost is **4,520,507** gas (binary search, warm; about 120k more cold); with less gas the call fails whole, with no partial answer. Other ids and the unminted token revert.
  - Reads past a chunk's end cannot happen: sizes are taken live from `extcodesize`, and `grid` and `motifName` offsets are validated in the constructor. A chunk with no code (unreachable, since a chunk starts with STOP and cannot self-destruct) makes the read run out of gas and revert; it never returns a wrong string (`testOneOfOneWithAChunkGoneRevertsRatherThanAnswering`).
- **Deploy path, mainnet.json as it stands.** With only `startsAt` filled, on chain id 1, orkhanart.eth at nonce 1,568 and the real stores (`testMainnetJsonDeploysAtThePublishedAddresses`):
  - Every launch value, the `expected` block (all 11 values), the texts, the data-URL scan and `readsGrids` pass.
  - The contracts land at **Motif Bazaar `0x33E45DED…e6EF`, The Unwoven Kilim `0xeD82CE5F…42eC`, the auction `0xb4817D07…3423`**, the published addresses.
  - Both goldens pass. Dry-run creations are 3,213,215, 6,138,522 and 2,863,866 gas.
  - `bazaar.pageTailHash` equals the deployed 1/1's `tailHash`, and `bazaar.royaltyReceiver` equals the tokens' royalty receiver.
- **Nonce and front-running.** The contract addresses come from CREATE at the deployer's nonce, which no one else can use. The script refuses a deployer with code (EIP-7702), a nonce other than the published one, and a pending transaction. The store is refused from the deployer once its nonce is published. Chunk addresses bind their bytes (CREATE2, salt 0, fixed SSTORE2 initcode), so they cannot be squatted. Foreign code at a chunk address is refused.
- **Config pins on chain 1.** Fixed by the script: deployer, treasury and royalty receiver (orkhanart.eth, the Bazaar's too), reserve, increment, duration, extension, motifCap, maxMotifsPerBid and the 1/1 name. A nonce check is mandatory, `minLeadSeconds` must be nonzero (86,400), `startsAt` must lie between `now + minLeadSeconds` and one year out, and `run()` is refused. The Bazaar must come from orkhanart.eth with no code, have a non-empty imageBase, a page store and pageRanks, and a seed window of 8,191.
- **EIP-712 registration domain.** OpenZeppelin `EIP712("Kilim Registration","1")` uses `_hashTypedDataV4`, so the chain id is live (it rebuilds when the chain id changes) and the verifying contract is the auction. Correct for chain 1.
- **scripts/.** `forge.mjs` passes its arguments through to the lockfile binary. `expected.mjs` is read-only. `site-config.mjs` checks the minters, the hashes against `site/motifs.js`, `startsAt` and `minted`. `sepolia-swarm.mjs` signs with chain id 11155111 only. `dev-chain` and `walkthrough` are local anvil only.
