# The Kilim contracts

Decided 10 October 2026 with the artist. This is the design every contract, test, packer, script and page follows. It replaces the single `Kilim.sol` collection (symbols + grid artworks + masterpiece + an SVG grid renderer), which no longer matches the work: there is no arranging of symbols in a grid any more. The work is a generative ASCII carpet drawn from 1,024 motifs (`research/motifs/curate/living-language-v3/`, see `onchain/ARTWORK-ONCHAIN.md`).

Vocabulary: the 1,024 drawings are **motifs** (never "symbols", "glyphs" or "designs" in anything public). A bidder's NFTs are motifs. A collector's later piece is a **kilim**.

Names, given by the artist on 10 October (the ERC-721 names and the marketplace collection names; the tickers are my choice and can change until the code freezes):

| | Name | Ticker |
|---|---|---|
| The motif collection | **Motif Bazaar** | `MOTIF` |
| The 1/1 | **The Unwoven Kilim** | `UNWOVEN` |
| The burn-to-create collection (the weaver, later) | **Kilim Bazaar** | `KILIM` |

The artwork file itself is still titled "KILIM / What the weave remembers" inside the page; the token is The Unwoven Kilim.

## Four contracts

| Contract | File | Tokens | Minted by |
|---|---|---|---|
| **Motif Bazaar** | `src/KilimMotifs.sol` | Up to `motifCap` (1,000,000) ERC-721 tokens, ids `1..motifCap`; each shows one of the 1,024 motifs | The auction, when a bidder claims |
| **The Unwoven Kilim** | `src/KilimOneOfOne.sol` | Exactly one token, id 1 | The auction, at settlement (or `claimPrize`) |
| **Kilim Auction** | `src/KilimAuction.sol` over `src/auction/EnglishAuction.sol` | none | — |
| **Kilim Bazaar** (the weaver) | not built now | kilims | Built when weaving opens; burns motifs through `KilimMotifs.burn` |

No contract has an admin, pause, upgrade, metadata setter or ownership role. Everything is fixed by constructor arguments. Each token contract has one `minter`, an immutable address given at construction: the auction's address, predicted from the deployer's nonce (see Deployment). One contract = one marketplace collection page, which is why the 1/1 is not inside the motif collection.

Why separate contracts: the auction is money, the motifs are a collection, the 1/1 is a single work with 450 KB of stored page, and the weaver's rules are not decided. Each can be audited and read on its own.

## KilimMotifs

`contract KilimMotifs is ERC721("Motif Bazaar", "MOTIF")`.

Constructor: `(address minter, address royaltyReceiver, uint256 motifCap, address[] gridChunks, bytes32 gridsHash, address namesChunk, bytes32 namesHash, string description, string externalUrl)`. Refuses zero addresses, `motifCap == 0` or `> type(uint32).max`, and chunks whose contents do not hash to `gridsHash` / `namesHash` (it reads them with `extcodecopy`, skipping the leading `0x00` byte, and checks `keccak256`). `description` and `externalUrl` are stored once and never change.

Motif data, read from SSTORE2 chunks (runtime code `0x00 || data`):
- **Grids**: 1,024 x 32 bytes = 32,768 bytes, motif `n` (1-based) at offset `(n-1)*32`. A grid is 16 rows of 16 bits, row 0 first, most significant bit = column 0: bit `(r, c)` is bit `255 - (r*16 + c)` of the `bytes32`. Chunks are cut at **24,544** bytes (767 x 32) so no motif straddles a chunk: two chunks, 24,544 + 8,224, and the constructor refuses any other number of chunks. `gridsHash = keccak256(all 32,768 bytes)`.
- **Names**: one chunk. 1,025 big-endian `uint16` offsets (2,050 bytes), then the UTF-8 names concatenated; motif `n`'s name is bytes `[off[n-1], off[n])` of the names section (offsets are relative to the start of the names section, i.e. after the offset table). Names are ASCII, at most 44 bytes today, not unique (29 distinct meanings across 1,024 motifs). `namesHash = keccak256(whole names section including the offset table)`.

Functions:
- `mintMotifs(address to, address bidder, uint256 firstId, uint256 quantity)`: `onlyMinter`, `nonReentrant`, `quantity` in `1..MAX_MINT_BATCH (64)`, ids inside `1..motifCap`, each id never minted before (a burned id stays "minted": keep a `_burned` mapping or a packed bitmap so a burned id cannot be re-minted), `_safeMint` each, emits `MotifsMinted(to, bidder, firstId, quantity)`. `to` may not be the zero address, this contract or the minter (also enforced in `_update` for transfers).
- `burn(uint256 id)`: the **owner only** (`ownerOf(id) == msg.sender`; approvals do not count). Marks the id burned, `++motifsBurned`, `_burn`. This is what the Weaver will use after the collector transfers motifs to it.
- `motifOf(uint256 id) → uint16` (1..1024): `uint256(keccak256(abi.encode(deploymentChainId, address(this), id))) % 1024 + 1`, where `deploymentChainId` is `block.chainid` recorded by the constructor: a chain that changes its id later (a minority fork) shows the same motifs. Fixed at deployment, public, NOT randomness; works for unminted ids too (the auction quotes it).
- `grid(uint16 motif) → bytes32`, `motifName(uint16 motif) → string` (not `name(uint16)`: an overload of ERC-721's `name()` breaks libraries that look functions up by name), `grids() → bytes` (all 32,768 bytes; the 1/1 contract reads this), `MOTIF_COUNT = 1024`.
- `tokenURI(id)`: `data:application/json;base64,` of `{"name":"<Name> (motif <n>)","description":"<description>","image":"data:image/svg+xml;base64,<svg>","attributes":[{"trait_type":"Motif","value":<n>},{"trait_type":"Name","value":"<Name>"}]}` where `n = motifOf(id)`. The SVG: `viewBox="0 0 20 20"`, a `#FFFFFF` paper rect, the motif at offset (2,2) in `#141414`, one `<rect>` per horizontal run of set bits in a row (never one per bit), `shape-rendering="crispEdges"`. Names are JSON-escaped on-chain (they are plain ASCII, but escape `"` and `\` anyway).
- `contractURI()`: `{"name":"Motif Bazaar","description":…,"external_link":…,"seller_fee_basis_points":500,"fee_recipient":…}` base64. `royaltyInfo` (ERC-2981): 5% to `royaltyReceiver`, fixed. `supportsInterface` adds `0x2a55205a`.
- Counters: `motifsMinted`, `motifsBurned`.

## KilimOneOfOne

`contract KilimOneOfOne is ERC721(<name>, "UNWOVEN")` with the token name given at construction (it is "The Unwoven Kilim"; the collection name on marketplaces is the contract name, so the constructor takes `name`).

Constructor: `(address minter, address royaltyReceiver, KilimMotifs motifs, Page page, string name, string description, string externalUrl)` where
```
struct Page { address[] prefixChunks; bytes32 prefixHash; address[] headChunks; bytes32 headHash; address[] tailChunks; bytes32 tailHash; }
```
Refuses zero addresses, a `motifs` address without code, and sections whose bytes do not hash to the given hashes. All immutable (chunk lists in storage, written once).

- `mint(address to)`: `onlyMinter`, once, token id 1, `_safeMint`. Deliberately **not** `nonReentrant`: only the auction calls it, it is one-shot, the auction has its own guard; a shared guard would let a receiver callback make the prize delivery fail with settlement recorded (audit finding R-06).
- `tokenURI(1)`: the only dynamic part is the motif grids, read live from `motifs.grids()`, so the 1/1 provably draws the same motifs the motif NFTs show. It returns, **without base64-encoding the whole thing**:
  ```
  data:application/json;utf8,
    PREFIX                                  (raw, stored: {"name":…,"description":…,"image":"data:image/png;base64,<png>","animation_url":"data:text/html;base64,)
    base64( HEAD || hex(grids) || "'" || pad )   (HEAD raw, stored: the start of the loader page up to and including  const GRIDS='  ; hex is 65,536 lowercase chars; pad is 0–2 spaces so the encoded piece is a multiple of 3 bytes and base64 pieces concatenate exactly)
    TAIL                                    (stored, ALREADY base64: the rest of the loader page, starting with  ;  and holding the compressed artwork)
    "}
  ```
  Build the answer in one buffer: compute the total length first, `extcodecopy` each chunk straight into place, write the hex with a nibble table in assembly, base64-encode in place with a small assembly loop (do not call a library that allocates a second copy). Memory expansion is the dominant cost: the answer is about 1 MB and the measured gas must stay under **8,000,000** (policy: half of the 16,777,216 per-transaction cap). `tokenURI` ends in `return` from assembly like the old `Kilim.tokenURI` did, so nothing re-encodes the answer; it must never be called internally.
- `contractURI()`, `royaltyInfo` (5% fixed), `supportsInterface` as for the motifs.
- Also `minted() → bool`.

The page format (what `onchain/pack_page.py` produces; the contract does not know what is inside HEAD and TAIL beyond the `'` and the padding rule):
- The **loader** is a small HTML page: `<!doctype html><html><head><meta charset=utf-8><meta name=viewport …><style>html,body{margin:0;background:#fff}</style></head><body><script>const GRIDS='` … `';` then JS that base64-decodes the embedded blob, gunzips it with `DecompressionStream('gzip')`, inserts `<script>KILIM_GRIDS=GRIDS</script>` right after the doctype of the decompressed artwork, and replaces the document with `document.open(); document.write(html); document.close()`. If `DecompressionStream` is missing it writes a one-line message instead. The blob is `base64(gzip(artwork html))` held in a JS string in the loader. The loader uses only single quotes and no backslashes or `%`/`#` where it matters; it is base64-encoded as a whole in TAIL anyway, so this is just hygiene.
- `HEAD` = loader bytes up to and including `const GRIDS='`. `TAIL` = `base64(rest of loader)` where "rest" starts with the `;` after the closing quote (the contract writes the quote and the padding). The packer checks the arithmetic: `(len(HEAD) + 65536 + 1 + pad) % 3 == 0`.
- `PREFIX` = the JSON up to and including `"animation_url":"data:text/html;base64,`, with the description JSON-escaped and the still image (base64) inline: the lossless WebP for the launch, a PNG also accepted, with the media type read from the file.
- Sections are cut into SSTORE2 chunks of at most 24,575 bytes; every chunk except a section's last is full.

## KilimAuction

As today (ETH-only, registrations, +10% raises, push refunds with a pull fallback, prize delivery at settlement) with these changes and nothing else:
- `Config` loses `collectionOwner, motifCount, maxCells, geometryHash, rendererHash, renderer, symbolCap` and gains `address motifs, address oneOfOne`. `maxSymbolsPerBid` becomes `maxMotifsPerBid`.
- The constructor no longer creates the collection. It checks: both addresses have code; `KilimMotifs(motifs).minter() == address(this)`; `KilimOneOfOne(oneOfOne).minter() == address(this)`; `KilimOneOfOne(oneOfOne).motifs() == motifs`; the treasury is neither token contract; `maxMotifsPerBid` in `1..motifCap` where `motifCap = KilimMotifs(motifs).motifCap()` (read from the collection, not configured twice).
- Names: `MOTIF_PRICE` (in `EnglishAuction`, was `SYMBOL_PRICE`), `motifCap`, `maxMotifsPerBid`, `motifsAllocated`, `motifsClaimed`, `motifCredits`, `claimMotifs`, `unclaimedMotifRanges`, `MotifsClaimed`, `MotifRangeMoved`, `expectedFirstMotifId`, `firstMotifId`, `motifReward`. The first motif id is 1 (no `FIRST_SYMBOL_ID` offset: ids are `1..motifCap`). `MAX_MINT_BATCH` is read from the motifs contract.
- `deliverPrize` / `claimPrize` call `oneOfOne.mint(to)`. `deliverPrizeToWinner()` (review round, 10 October) lets anyone send the 1/1 to the winner again after a settlement that could not deliver it: `nonReentrant`, only when `settled && !prizeClaimed`, only to `highestBidder`, with the caller's gas.
- The audited behaviour of `EnglishAuction` (gas floors, refunds, registration, EIP-712 `registerFor`) is untouched apart from the constant's name.

## Deployment (from the artist's wallet, no admin keys)

`script/DeployKilim.s.sol`, same shape as today (dry run in a state snapshot with gas and read-back checks, refuse before sending anything, mainnet requires the decided launch values, the published nonce and a nonzero inspection window):

1. `runStore()`: all chunks (motif grids, names, page prefix/head/tail) through the CREATE2 deployer `0x4e59…956C`, salt 0, each verified or skipped if already there.
2. `runContracts()`: with the deployer at nonce `n`: `KilimMotifs` at `n` and `KilimOneOfOne` at `n+1`, both with `minter = computeCreateAddress(deployer, n+2)`, then `KilimAuction` at `n+2`. Read back every immutable, check the auction's address equals the prediction, print all addresses. On chain 1 the deployer must be `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth), which is also treasury and royalty receiver.
3. The dry run also calls `tokenURI(1)` on the 1/1 and `tokenURI` on a motif and compares `sha256` with the golden values in the manifests, and measures the gas of both.

Config JSON (`deploy/*.json`): `chainId, deployer, deployerNonce, minLeadSeconds, motifStore (dir), pageStore (dir), auction {treasury, startsAt, duration, extensionWindow, incrementBps, reservePrice, maxMotifsPerBid}, collection {motifCap, description, externalUrl}, oneOfOne {name, description, externalUrl}`. On chain 1 `oneOfOne.name` must be "The Unwoven Kilim". Launch values: reserve 0.01 ETH, +10%, 24 h, 10 min, `motifCap` 1,000,000, `maxMotifsPerBid` 1,000,000.

## Packers (`onchain/`)

- `onchain/pack_motifs.py <artwork html> <out dir>`: reads the `<script>const DATA=…</script>` block of the artist's page (`DATA.symbols[i].number, .name, .rows` — 16 strings of 16 `0`/`1`), writes `grids.bin`, `names.bin`, `chunks/*.bin`, `manifest.json` (hashes, chunk files, keccak and CREATE2 address per chunk, `motifCount`, and `golden`: the expected `tokenURI` sha256 for motif 1 of a known id, computed in Python by reproducing the contract's JSON and SVG). Also `--check` to verify an existing out dir. It never writes into `research/`.
- `onchain/pack_page.py <artwork html> <still png|webp> <out dir> --name --description --external-url`: builds the loader, PREFIX/HEAD/TAIL, chunks, `manifest.json` with section hashes, chunk addresses, sizes, and `golden.tokenURI.sha256` computed in Python from the same pieces plus the grids hex (it takes `--grids grids.bin`). Also `--check`. A Python unit test packs a tiny stand-in page and checks the base64 arithmetic; a headless-Chrome test (reuse `onchain/test/chrome.mjs`) opens the assembled `animation_url` data URL and checks the artwork starts (`#art[data-renderer]`).
- `onchain/keccak.py` stays. Everything else of the old pipeline goes: `pack_store.py, render_ref.py, synth_geometry.py, pack.py, fit_gas_model.py, symbols.bin, symbols.b64, build/, kilim-*.html, src-1of1.html, unpack.js, page.mjs, test/page.test.mjs, test/render-site.test.mjs, test/test_pack_store.py`. `onchain/painter/`, `onchain/test/chrome.mjs`, `onchain/ARTWORK-ONCHAIN.md`, and the untracked `onchain/current-1024/` and `onchain/pack_curves.py` (another session's) are not touched.

## Removed from the contracts

`src/Kilim.sol`, `src/render/` (renderer, writer, interface), every test under `test/render/`, `test/CompositionInvariants.t.sol`, `test/GasLimits.t.sol`, the renderer mocks, the `inspectArtwork` path in `test/mocks/Receiver.sol`, `scripts/render-geometries.mjs, gas-render.mjs, calibrate-gas.mjs`, the `test:render-*`, `gas:*`, `pack*` package scripts (replaced by `pack:motifs`, `pack:page`, `test:pack`), `docs/RENDERER.md` (replaced by `docs/STORAGE.md`). Materials, appearances, symbols and glyphs (as words for the drawings), cells, weaving, expanding, freezing: gone everywhere, contracts, site, docs and copy. The site's copy guard refuses "symbol" and "glyph" (the credit to the Nuance Glyph Duet excepted) and allows "weav…" only in "Kilim Bazaar"'s description of burning motifs to weave a kilim and in the artwork's own title.

## What must still hold (the audited properties)

The whole existing auction test suite (`KilimAuction.t.sol`, `AuctionInvariants`, `AuditGaps`, `AttackPatterns`, `GasFloors`, `Lifecycle`, `NativeRegistration`, `SponsoredRegistration`, `ReuseRegression`, `LaunchConfig`, `DeployKilim`) keeps every property it checks today, re-targeted at the new contracts and names: a claim mints exactly the reserved ids to the recipient; a settle that cannot deliver the 1/1 leaves settlement intact and `claimPrize` works; the gas floors (`InsufficientGas`) hold with the new mint costs (the hook budgets and the `407_000` winner burn in `AuditGaps` are re-measured, not assumed); no auction path (claim, prize, refund, proceeds) names the zero address, the auction or a token contract as recipient; each token contract refuses itself and its minter on every transfer, and the 1/1 also refuses the motif collection (a motif can still be sent to the 1/1's contract by its holder and is then lost, like any token sent to a contract that cannot move it); the treasury cannot bid but may receive tokens like any address; Slither (`pnpm -s audit:static`) reports no medium or high; `forge fmt --check` passes; `FOUNDRY_PROFILE=ci` passes.
