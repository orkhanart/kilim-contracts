# On-chain renderer: store, hash recipe and deploy order

Every Kilim token's metadata and media are drawn on-chain by `KilimRenderer` from one byte string, STORE, held in a few data contracts. Nothing is hosted: symbol and artwork images are contract-drawn SVG, and the 1/1's `animation_url` is its interactive page, assembled from the same stored geometry.

This file is the recipe to publish before deploying. Everything in it can be recomputed from the repository.

## The pieces

| Contract | What it holds | Changes after deploy? |
| --- | --- | --- |
| Data chunks (7 today) | STORE, cut into 24,575-byte pieces, each deployed as SSTORE2 code (`0x00` then the data) through the deterministic CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0 | No: code cannot change |
| `TABLES` | A number table and a base64 pair table (8,704 bytes), deployed by the renderer's constructor | No |
| `KilimRenderer` | The drawing code. Its constructor checks STORE against `geometryHash`, `indexHash` and `pageHash` and rejects anything else (`BadStore` codes 1-17) | No: no owner, no setter |
| `Kilim` | The ERC-721. Its constructor checks the renderer's code hash, motif count and geometry hash | No |

`Kilim.tokenURI` pushes each token's inputs to the renderer and returns its answer unchanged. The renderer never calls back.

## STORE

All integers are big-endian.

| Bytes | Field |
| --- | --- |
| 0-3 | `"KLM1"` |
| 4-7 | `geoLen`: length of GEOM |
| 8-11 | `idxLen`: length of INDEX, 16 per motif |
| 12-15 | `pageLen`: length of PAGE |
| 16-19 | `stillAt`: where the 1/1 still is spliced into PAGE |
| 20-23 | `symbolsAt`: where base64(GEOM) is spliced into PAGE |
| 24-41 | nine `u16` motif IDs: the 1/1 page's opening frame, the 3x3 cells around its hero cell, row-major; `0xFFFF` where the sheet has no cell |
| 42-63 | zero |
| 64 ... | GEOM: the raw varint geometry (today exactly `zlib.decompress(onchain/symbols.bin)`, 105,377 bytes) |
| then | INDEX: per motif, `u32` offset in GEOM, `u32` length, `i16 minX`, `i16 minY`, `u16 w`, `u16 h` |
| then | PAGE: `onchain/src-1of1.html` with its two splice tokens (`__STILL__`, `__SYMBOLS__`) removed |

The motif count is the leading varint of GEOM. Nothing in the contracts or the packer assumes 812.

`onchain/pack_store.py` builds STORE, the chunk files, `manifest.json` (sizes, hashes, CREATE2 addresses, per-chunk deploy gas, the opening frame, worst-case motif lists and the gas budget) and `golden.json` (sha256 of every renderer output the tests check), all in `onchain/build/`. `pnpm pack:check` fails if the committed build is not what the inputs produce.

## Hash recipe

Publish these, computed from the exact bytes that go on-chain:

| Value | Recipe | Today |
| --- | --- | --- |
| `geometryHash` | keccak256(GEOM) | `0x072134247de2d0ab98f8315ae051ce9ca0220e0eaca7516c1dbdf2402e7c3fa1` |
| `indexHash` | keccak256(INDEX) | `0x302a954a11f930fb229667bbccb48d35da8f8aed39acae5b6c519874a22d6e0a` |
| `pageHash` | keccak256(PAGE) | see `onchain/build/manifest.json`; it changes with every page edit |
| `rendererHash` | EXTCODEHASH of the deployed renderer | printed by `runStore` (and `pnpm deploy:dry`) |
| `motifCount` | leading varint of GEOM | 812 |

`geometryHash` covers the stored, uncompressed bytes, not the deflated `symbols.bin` the old checklist named. The renderer's runtime code embeds all three section hashes, the section lengths, the opening-frame motifs and its `TABLES` address, so `rendererHash` commits to the store as well as to the code. Because the chunks and the renderer are deployed with CREATE2 from fixed initcode, their addresses and `rendererHash` are the same on every chain and can be published before deploying. They change if the compiler settings, any renderer source file (including comments: the metadata hash is part of the code) or the store change.

To check a deployed renderer independently: rebuild with `pnpm build` at the tagged commit, run `pnpm pack:check`, run `pnpm deploy:dry`, and compare the printed addresses and `rendererHash` with the chain.

## Deploy order

Every transaction stays under 8M gas (the per-transaction cap is 16,777,216). Measured (`audit/gas-render.txt`):

| Transaction | Gas |
| --- | --- |
| each full chunk | about 5.40M at most (all 7: 33.5M) |
| renderer, including `TABLES` | about 6.86M |
| auction, which creates Kilim | about 5.47M |

1. **Freeze** the geometry and the page. Run `pnpm pack`, read the budget it prints, and review `onchain/build/manifest.json`.
2. **Test**: `pnpm test`, `pnpm test:render-geometries` (the whole renderer suite on a 700- and a 912-motif store), `pnpm test:render-ffi` (differential fuzzing against `onchain/render_ref.py`), `pnpm test:page` (the 1/1 page, then `test:render-site`), `pnpm test:render-site` (below), `pnpm test:pack`, `pnpm gas:render`.
3. **Store phase** (`runStore`): the script deploys every chunk that is not already on-chain, then the renderer, both through the CREATE2 deployer. Any funded key can do this, and it is idempotent: chunks or a renderer already at their addresses are verified and skipped.

   ```sh
   cd contracts
   KILIM_DEPLOY_CONFIG=deploy/<network>.json \
     node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
     --rpc-url "$RPC" --broadcast --ledger --sender <deployer>
   ```

4. **Publish** the chunk and renderer addresses, `rendererHash`, the three section hashes and `motifCount`. Then publish the auction deployer's address and next nonce, and the predicted auction and Kilim addresses (`1-pre-deploy.md`). Do step 3 before publishing the nonce, or use a different key for it.
5. **Auction phase** (`runAuction`): put `rendererHash` and the published nonce into the config, then run the same command with `--sig 'runAuction()'`.

`run()` does both phases in one go, for the testnet rehearsal.

The config file (see `deploy/sepolia.example.json`) holds the chain ID, the store directory, the deployer and its published nonce, the expected hashes and motif count, the payment token and its decimals, the minimum inspection window and the auction settings.

### What the script refuses

forge simulates the whole script before it sends anything, so any refusal below means nothing is broadcast. The script reverts with `Refused(reason)` when:

- the chain ID differs from the config;
- the manifest's motif count or any section hash differs from the config;
- a chunk file's size or keccak differs from the manifest, a chunk before the last is not full, or its CREATE2 address differs from the manifest;
- the three hashes recomputed from the concatenated chunk files differ from the config;
- a chunk or renderer address already holds different code;
- a dry run of any deployment needs more than 8M gas, or returns a different address;
- the dry-run renderer's immutables, chunk list, 1/1 URI, first golden symbol URI or first golden artwork URI differ from `golden.json`;
- the renderer's code hash differs from a published `rendererHash`;
- in the auction phase: the renderer is missing or differs, the payment token has no code or other decimals, the reserve price is not whole units, `startsAt` falls inside the inspection window or more than a year out, an address is zero, the deployer's nonce is not the published one, or any read-back value of the deployed auction or collection differs.

`test/DeployKilim.t.sol` runs both phases against the local chain and triggers each refusal.

## Gas and the complexity budget

`tokenURI` is a view, called with `eth_call`. Public RPCs usually allow 50M gas per `eth_call`, but some backends cap it at 25M (measured by the feasibility review), and `eth_estimateGas` on mainnet is capped at 16,777,216, so pass an explicit gas value when fetching. The targets are chosen to fit a 25M cap for the 1/1:

| Token | Measured `Kilim.tokenURI` (eth_call) | Ceiling |
| --- | --- | --- |
| largest symbol (cotton rag) | 0.48M | 0.6M |
| 16x16 artwork of the 256 heaviest motifs | 30.4M | 36M |
| 16x16 artwork of random motifs | about 17.5M | 24M |
| the 1/1 | 22.4M | 24M |

`test/render/RenderGasLimits.t.sol` enforces these on the final geometry, one call per test (so no measurement pays for another's memory). The packer prints the remaining headroom on every run. With today's set:

- **Artworks** depend only on the 256 most complex motifs. Each extra point among them costs about 850 gas, so there is room for about 6,400 more points there (today 29,526 points; the lightest of the 256 has 70).
- **The 1/1** grows with the whole geometry: about 175 gas per byte, so about 9,500 more bytes, roughly **90 more motifs of median size**, before it reaches 24M. Past that, the 1/1 exceeds 25M-capped RPCs first; 45M allows several hundred more.
- Aim for 150 points or fewer per new symbol, drawn at today's scale.

`pnpm gas:calibrate` re-measures the renderer on three stores and refits the packer's model (`GAS_MODEL`).

## Changing the symbol set before deploy

Add, remove or redraw symbols freely until the geometry is frozen. Keep IDs append-only if the order matters. Then run `pnpm pack`: it recomputes the count, index, hashes, chunk layout, the 1/1's opening frame, the golden files and the budget. It refuses:

- any format problem: a motif with no ring, a ring of fewer than 3 points, a non-minimal varint, a coordinate outside int16, trailing bytes, a count outside 1..65,535;
- a motif outside the **scale band**: longest bbox side outside 12..150 quarter-units, or reaching more than half a sheet pitch (87 x 90) from its origin. The 1/1 draws motifs at natural size in cells about 176 x 182 apart, so an oversized or tiny motif would overlap its neighbours or vanish. Sizes outside today's 24..110 are only a warning;
- a page without exactly one `__STILL__` before exactly one `__SYMBOLS__`.

After deploy nothing can change: the motif count and hashes are immutable, and each symbol's motif is recomputed as `seed % motifCount`, so a different count would re-deal almost every token.

## Metadata

`tokenURI` returns `data:application/json;base64,...` for every kind; images are `data:image/svg+xml;base64,...`.

- **Symbol**: name `Kilim Symbol #<tokenId>`; attributes Kind, Motif (`#<motif + 1>`, the site's numbering), Material (English) and Material (Azerbaijani); plus `seed` and `geometry_hash`. The image is the motif at 80% of a 1000 x 1000 frame on paper `#f7f6f2`, with a 2-3 stop gradient per material, or a blind emboss for cotton rag.
- **Artwork**: name `Kilim Artwork #<n>`, numbered from 1 in minting order; attributes Kind, Appearance, Columns, Rows, Cells, Distinct motifs, Revision, Frozen. The image reproduces the site's flat merge view (`site/merge-render.js`) on a square canvas.
- **1/1**: name `Kilim 1/1`; attributes Kind and Motifs. `image` is the page's opening frame, the hero cell and its eight neighbours in the page's own ink on white, and the same SVG is the page's static fallback, visible until its script runs or when a host's CSP blocks scripts. `animation_url` is the page. Browsers block top-level navigation to `data:` URLs, so to open the page full-window or archive it, call `masterpieceHTML()` on the renderer and save the result as an `.html` file.

Artwork appearance is `bytes32` left-aligned ASCII (what `ethers.encodeBytes32String` produces): `flat/ink`, `flat/indigo` or `flat/vermilion`. `weave` and `expand` reject anything else with `InvalidAppearance`.

The names, descriptions, palette and trait labels are constants at the top of `KilimRenderer.sol` and `onchain/render_ref.py`. Change both, run `pnpm pack`, and the golden tests confirm they agree.

### Fidelity to the site

The golden and differential tests prove the Solidity equals `onchain/render_ref.py`, but both could drift from what the site draws. `pnpm test:render-site` (`onchain/test/render-site.test.mjs`) closes that gap in headless Chrome: it deploys the store and the renderer on a local anvil, asks the contract for every golden artwork case and every motif's symbol, and compares each rasterised SVG with the site's own code drawing the same thing on a canvas: `KILIM_RENDER.draw` from `site/merge-render.js` for artworks, `KILIM.drawSymbol` (pad 0.80) from `site/lib.js` for symbol silhouettes, with the geometry `site/build.py` embeds (`onchain/symbols.b64`). Each SVG is also checked against `golden.json`, and a first test (no Chrome needed) checks that `onchain/symbols.b64`, which the site embeds, inflates to the geometry whose keccak256 is `geometryHash`. Measured today: no artwork pixel differs by more than 64 in any channel (mean difference under 0.004 of 255), and symbol silhouettes differ by at most 0.1% of their ink with the centroid within 0.06 px at 500 px. The thresholds are tight enough that an ink or plate colour a few levels off, a pad 1.5% smaller, a half-pixel shift or two swapped cells fail, and a test proves it. Changing an artwork colour, a pad or the plate therefore means changing `site/merge-render.js` in the same step. The test needs Chrome (`CHROME_PATH` if it is not in a usual place); without one it is skipped, unless `CI` is set.

## Local dev chain

`scripts/dev/deploy.mjs` (used by `pnpm dev:chain`, `pnpm walkthrough` and the site tests) deploys the same chunks and the real `KilimRenderer` before the auction, by plain CREATE from anvil's first account rather than through the CREATE2 deployer, and passes the renderer, its code hash, the store's motif count and `geometryHash` in `Config`. A local `tokenURI` is therefore the production answer. `deployLocal(url, { renderer: 'mock', motifCount })` deploys `test/mocks/MockRenderer` instead, for a count other than the store's. Its `packedStore()` checks every chunk file against `manifest.json` first.

## Reviewing the assembly

The memory-unsafe writers live in `src/render/KilimWriter.sol`. Its header states the four rules they follow, and each writer's NatSpec states how far past its cursor it may write (always under 32 bytes, inside a buffer's slack). Every document ends with a length check: an upper bound for SVG, an exact length for every JSON, wrapper, HTML and base64 run. The geometry decoder proves that each record is consumed exactly. `_read` in the renderer never uses Solidity storage indexing, because its hashing uses the scratch space; that once corrupted index records that straddle a chunk boundary, and `testReadsAcrossEveryChunkBoundary` guards it.
