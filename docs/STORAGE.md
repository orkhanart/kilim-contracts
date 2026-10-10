# On-chain storage: the chunks, the hash chain and the 1/1's answer

Everything the two token contracts show is stored on the chain in SSTORE2 data contracts ("chunks") and read back with `extcodecopy`: the 1,024 motif grids and names for Motif Bazaar (`src/KilimMotifs.sol`), and the three sections of the 1/1's page for The Unwoven Kilim (`src/KilimOneOfOne.sol`). Nothing is hosted. This file is the recipe: what the chunks hold, how every byte is pinned from the artist's file down to the deployed addresses, how the 1/1's `tokenURI` is put together and what it costs, and what to do when the artwork changes. Everything in it can be recomputed from the repository. The design is [CONTRACTS.md](CONTRACTS.md).

## The pieces

| Contract | Holds | Deployed by | Changes after deploy? |
| --- | --- | --- | --- |
| Grid chunks (2) | 32,768 bytes of motif grids, cut at 24,544 bytes | CREATE2, salt 0, through the deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` | No: code cannot change |
| Names chunk (1) | 13,739 bytes today: the offset table and the names | the same | No |
| Page chunks (35 today: prefix 1, head 1, tail 33) | The 1/1's token JSON and loader page, cut at 24,575 bytes | the same | No |
| `KilimMotifs` (Motif Bazaar) | The grid and names chunk addresses and the two hashes, checked in its constructor | the artist's wallet, nonce n | No: no owner, no setter |
| `KilimOneOfOne` (The Unwoven Kilim) | The page chunk addresses and the three section hashes, checked in its constructor; the motif contract's address | nonce n + 1 | No |
| `KilimAuction` | The two token contracts' addresses | nonce n + 2 | No |

A chunk's runtime code is `0x00` followed by the data (the leading `STOP` keeps it from doing anything when called), at most 24,576 bytes of code, so at most **24,575** data bytes. Its creation code is `61 <len+1> 80 60 0a 3d 39 3d f3 00 <data>` (`PUSH2 len, DUP1, PUSH1 10, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN, STOP`), the same bytes in `onchain/pack_motifs.py` (`sstore2_initcode`) and `script/DeployKilim.s.sol` (`_sstore2`). Deployed through the CREATE2 deployer with salt 0, a chunk's address is `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(initcode))[12:]`: a function of its bytes alone, the same on every chain, known before anything is sent. Every chunk but a section's last is full, so a reader finds any byte from its offset.

## Grids

`grids.bin`: 1,024 × 32 bytes, motif `n` (1-based) at offset `(n − 1) × 32`. A grid is 16 rows of 16 bits, row 0 first, column 0 in the most significant bit: bit `(r, c)` is bit `255 − (r × 16 + c)` of the `bytes32`. Cut into chunks of **767 grids = 24,544 bytes** so no grid straddles two chunks: today 24,544 + 8,224. `gridsHash = keccak256(grids.bin)`.

`grid(n)` copies 32 bytes out of chunk `(n − 1) / 767` at offset `1 + ((n − 1) mod 767) × 32`; `grids()` copies every chunk into one 32,768-byte answer, which is what the 1/1 reads.

## Names

`names.bin`, one chunk: 1,025 big-endian `uint16` offsets (2,050 bytes), then the UTF-8 names concatenated. Motif `n`'s name is bytes `[off[n − 1], off[n])` of the part after the table. The constructor checks that the offsets never decrease and that the last one ends exactly at the end of the section, so every name read stays inside the chunk. `namesHash = keccak256(names.bin)`. Today: 13,739 bytes, 29 distinct names across the 1,024 motifs, the longest 44 bytes, printable ASCII (the packer refuses anything else, and the contract escapes `"` and `\` in the JSON anyway).

## The page, in three sections

`KilimOneOfOne.tokenURI(1)` is `data:application/json;utf8,` followed by the token JSON, with the loader page as its `animation_url`. Three stored sections, written by `onchain/pack_page.py`:

| Section | Contents | Stored as | Today |
| --- | --- | --- | --- |
| PREFIX | `{"name":…,"description":…,["external_url":…,]"image":"data:image/png;base64,<still>","animation_url":"data:text/html;base64,` | raw bytes | 393 bytes, 1 chunk (a placeholder still) |
| HEAD | The loader up to and including `const GRIDS='` | raw bytes | 196 bytes, 1 chunk |
| TAIL | The rest of the loader, from the `;` after the closing quote, holding `base64(gzip(artwork))` | **already base64** | 808,872 bytes, 33 chunks |

The loader (`onchain/loader.html`, 894 bytes before the blob goes in) is a small page of its own: it decodes the blob, gunzips it with `DecompressionStream('gzip')`, puts `<script>KILIM_GRIDS="…"</script>` right after the artwork's doctype and writes the result over itself with `document.open`, `write`, `close`. In a browser without `DecompressionStream` it shows one line of text instead. The artwork never carries the grids: the contract hands them in when the token is read, so the 1/1 provably draws the motifs the motif tokens show. `onchain/ARTWORK-ONCHAIN.md` says what the artwork file must do with `KILIM_GRIDS`.

The packer checks the one piece of arithmetic the contract relies on: `(len(HEAD) + 65,536 + 1 + pad) mod 3 == 0`, with `pad` 0 to 2 spaces, so that the base64 of the middle piece ends on a whole group and concatenates with TAIL into one valid encoding (today `pad` is 0). The contract knows nothing of what is inside HEAD and TAIL beyond that rule and the closing quote.

Today's store is packed from the stand-in artwork `onchain/test/fixtures/lean.html` (2,097,436 bytes, gzip 454,477 bytes, blob 605,972 characters) with the placeholder still `still-placeholder.png`. The final artwork is re-packed by the procedure at the end of this file.

## The hash chain

Every value is computed off-chain from the files, checked by the constructors against the chain, and checked again by the deploy script's dry run through the goldens. Nothing is typed in by hand except the texts (name, description, external URL), and the script compares those with the manifests.

| Value | Computed by | From | Checked by |
| --- | --- | --- | --- |
| `source.sha256` | `pack_motifs.py` | the artist's page (`research/motifs/curate/living-language-v3/index.html`) | recorded in `onchain/build-motifs/manifest.json`; `--check` rebuilds and compares |
| `gridsHash`, `namesHash` | `pack_motifs.py` | `grids.bin`, `names.bin` (keccak256) | `KilimMotifs`'s constructor, which copies every chunk and hashes it; the deploy script, from the chunk files |
| chunk keccak, initcode keccak, CREATE2 address | `pack_motifs.py`, `pack_page.py` | each chunk file | the deploy script: file size and keccak against the manifest, the address against its own prediction, no foreign code at the address; `_requireStored` before the contracts |
| `prefixHash`, `headHash`, `tailHash` | `pack_page.py` | the three sections (keccak256) | `KilimOneOfOne`'s constructor; the deploy script |
| the constructor arguments | the deploy script | the manifests and the config | read back from every immutable after each deployment (`_checkContracts`) |
| motif golden | `pack_motifs.py` | the sha256 of the `tokenURI` of a token showing motif 1, from the JSON and SVG reproduced in Python byte for byte, with the collection description | the dry run mints such a token as the auction and compares (`motif tokenURI differs from golden`) |
| 1/1 golden | `pack_page.py` | the sha256 of the whole `tokenURI(1)`, from the three sections plus `grids.bin` | the dry run mints the 1/1 as the auction and compares (`1/1 tokenURI differs from golden`) |

Because the 1/1's golden covers the grids hex, it pins the motif store as well as the page: a store packed from other grids fails it. `motifOf(id)` does not depend on the grids (`keccak256(abi.encode(chainid, address(this), id)) % 1024 + 1`), so which motif a token shows is fixed by the motif contract's address, that is, by the deployer and the nonce.

To check a deployed store independently: at the tagged commit run `pnpm -s pack:motifs -- --check --description "<the deployed description>"` and `pnpm -s pack:page -- … --check` with the deployed name, description and URL, then compare the manifests' addresses and hashes with the chain (`gridChunks()`, `namesChunk()`, `gridsHash()`, `namesHash()`, `prefixChunks()`, `headChunks()`, `tailChunks()`, `prefixHash()`, `headHash()`, `tailHash()`), and `sha256(tokenURI(1))` with the page manifest's golden once the token exists.

## The 1/1's tokenURI, and what it costs

The answer is built in one buffer in assembly (`KilimOneOfOne.tokenURI`):

1. the total length is computed first from the chunks' code sizes: `27 + len(PREFIX) + 4m/3 + len(TAIL) + 2`, where `m = len(HEAD) + 65,536 + 1 + pad` is the middle piece;
2. PREFIX is copied straight into place with `extcodecopy`, chunk by chunk;
3. HEAD is copied to the end of the room the base64 piece will need, so that the encoder, writing from the front, never overtakes bytes it has not read;
4. the grids come live from `KilimMotifs.grids()` (a `staticcall`; a wrong-sized answer reverts with `GridsUnavailable`), are placed in the second half of the hex room and expanded forward to 65,536 lowercase hex characters, a 32-byte word at a time with shifts and masks;
5. the closing quote and the padding spaces are written;
6. the middle piece is base64-encoded in place, 24 raw bytes to 32 characters per step, again a word at a time, with the last few groups through a small alphabet table; its length is a multiple of 3 by construction, so no `=` is ever written and the two base64 runs concatenate exactly;
7. TAIL is copied after it, then `"}`;
8. a length check, then `return` from assembly.

The call ends in that `return`, so nothing re-encodes the answer and **`tokenURI` must never be called internally**. A byte-at-a-time version of the two encoders costs about nine million gas here; the word-at-a-time version well under one. Memory expansion is the other cost, and it grows faster than linearly with the answer.

Measured on 10 October 2026 (`pnpm -s deploy:dry`, the packed stand-in store, forge's `staticcall` without copying the answer):

| Read (`eth_call`) | Gas | Answer |
| --- | --- | --- |
| `KilimOneOfOne.tokenURI(1)` | **3,838,101** | 896,938 bytes |
| `KilimMotifs.tokenURI(id)` (a token showing motif 1) | 287,311 | 2,053 bytes |

The policy ceiling is **8,000,000** per read and per transaction (`MAX_TX_GAS` in the script: half of the 16,777,216 per-transaction cap of EIP-7825, which some nodes also apply to `eth_call`). The dry run refuses a store whose 1/1 reads above it. `test/KilimOneOfOne.t.sol` measures a page of launch size (a 70 KB prefix and a 600 KB tail across 25 chunks) at 3,378,414 gas for a 757,791-byte answer and asserts the ceiling. `scripts/probe-rpc.mjs` measures how much gas each RPC endpoint allows an `eth_call`, without deploying anything.

## Deployment, and what the script refuses

`script/DeployKilim.s.sol` deploys in the published order: `runStore()` puts every missing chunk on the chain through the CREATE2 deployer (idempotent: a chunk already at its address is verified and skipped, and any funded key can do it), then `runContracts()` deploys `KilimMotifs` at the deployer's nonce `n`, `KilimOneOfOne` at `n + 1`, both with the auction's address predicted at `n + 2` as `minter`, then `KilimAuction` at `n + 2`. `run()` does both, for the local dry run and the Sepolia rehearsal; it is refused on mainnet. The steps are in [../checklists/2-deploy.md](../checklists/2-deploy.md). Measured in the dry run on 10 October 2026, every transaction under the 8M policy:

| Transaction | Gas |
| --- | --- |
| the first grid chunk (24,544 bytes) | 5,645,861; the second, 8,224 bytes, 1,820,600 |
| the names chunk | 3,223,987 |
| the prefix and head chunks | 139,229 and 96,515 |
| each full tail chunk (24,575 bytes) | 5,731,788 to 5,876,690; the 33 tail chunks 191.1M in all |
| `KilimMotifs` | 3,226,366 |
| `KilimOneOfOne` | 5,600,491 |
| `KilimAuction` | 3,150,749 |
| the whole store, 38 chunks | about 202.0M |
| everything | about 214.0M |

Code deposit is 200 gas per byte today; EIP-8037 (Glamsterdam) raises it to 1,530, so the store should go on the chain before that fork reaches mainnet.

forge simulates the whole script before sending anything, so a refusal means nothing is broadcast. The script reverts with `Refused(reason)` when:

- the chain ID differs from the config;
- a manifest's `motifCount` is not 1,024, or its CREATE2 deployer is not the canonical one;
- a chunk file's size or keccak differs from the manifest, a chunk before a section's last is not full, a chunk is empty or above 24,575 bytes, or its CREATE2 address differs from the manifest;
- the grids are not 32,768 bytes, or the names are not one chunk;
- a section's chunks, concatenated, do not hash to the manifest's section hash;
- a chunk address already holds code other than `0x00` followed by that chunk's bytes;
- the collection description, or the 1/1's name, description or external URL in the config differ from the texts the manifests were packed with (the goldens were computed with them);
- a chunk's dry-run deployment needs more than 8M gas or lands at another address;
- in the contracts phase: the store is not fully deployed yet, the reserve price is not 0.01 ETH, `startsAt` is inside the inspection window or more than a year out, the treasury is the zero address, the deployer's nonce is not the published one, the dry-run auction's address differs from the prediction, any read-back immutable differs, either tokenURI differs from its golden, or a deployment or a tokenURI read needs more than 8M gas;
- on chain 1: the deployer is not orkhanart.eth, the 1/1's name is not "The Unwoven Kilim", any auction setting differs from the decided launch value, the nonce check is skipped, or `minLeadSeconds` is zero.

`test/DeployKilim.t.sol` runs both phases against the local chain and triggers each refusal, then switches the chain ID to 1 for the pinned values and to Sepolia's to show they are not pinned there, and checks that both templates carry the pinned values.

## Re-packing when the artwork changes

Nothing can change after deployment: the hashes are immutable, and a different motif set would change every chunk address and the 1/1's golden. Before deployment, re-pack whenever the artist's page, the still image, the loader or any token text changes:

1. **Motifs.** `pnpm -s pack:motifs -- --description "<collection description>"` reads the `<script>const DATA=…</script>` block of `research/motifs/curate/living-language-v3/index.html` and writes `onchain/build-motifs/` (`grids.bin`, `names.bin`, `chunks/`, `manifest.json`). It refuses a page without exactly 1,024 motifs numbered 1..1,024, a name that is not printable ASCII, or rows that are not 16 strings of 16 `0`/`1`. Then `python3 site/tools/pack_motifs.py` rewrites `site/motifs.js` through the same packer, so the site draws the bytes the chain stores.
2. **Page.** `pnpm -s pack:page -- <artwork.html> <still.png> ../onchain/build-page --grids ../onchain/build-motifs/grids.bin --name "The Unwoven Kilim" --description "<text>" [--external-url <url>]`. The artwork must start with a doctype and read `KILIM_GRIDS`; the still must be a PNG. The outputs are `prefix.bin`, `head.bin`, `tail.bin`, `chunks/`, `animation.html` (the decoded page, to open locally) and `manifest.json`.
3. **Config.** Put the same description, name and external URL into `deploy/*.json`; the script refuses a config whose texts differ from the manifests'.
4. **Check.** `pnpm -s test:pack` (the packers' invariants on synthetic pages), `pnpm -s test:page` (the exact `animation_url` the contract would return, opened in headless Chrome: the artwork must start), `pnpm -s test:contracts`, then `pnpm -s deploy:dry`, which deploys the new store in forge's memory, compares both tokenURIs with the new goldens and prints the gas of every transaction and of both reads. Both packers take `--check` with the same arguments to confirm that an existing out directory is what the inputs produce.
5. **Publish** the chunk addresses and the five hashes from the manifests before deploy day ([../checklists/1-pre-deploy.md](../checklists/1-pre-deploy.md)).

Only the artist's drawings may go on the chain; the motif packer never writes into `research/`.

## Local dev chain

`scripts/dev/deploy.mjs` (behind `pnpm dev:chain`, `pnpm walkthrough`, `scripts/bench.mjs` and the site tests) deploys the same chunk files by plain `CREATE` from anvil's first account, then the three contracts in the published order, so a local `tokenURI` is the production answer for the packed store.

## Reviewing the assembly

The pointer arithmetic lives in one function, `KilimOneOfOne.tokenURI`, with the invariants in its comments: the raw bytes of the middle piece sit at the end of the room the encoding needs (`raw = piece + m/3`), so block `j`, written to `piece + 32j`, ends below `raw + 24j + 24`, the next unread byte; the grids are expanded forward from the second half of the hex room for the same reason. The function checks that it ended exactly at the computed total before returning. `test/KilimOneOfOne.t.sol` compares the answer byte for byte with a Solidity reference built from `abi.encodePacked` and OpenZeppelin's `Base64` for HEAD lengths of every residue mod 3, for sections spread across many chunks and for the launch-size page; `test/KilimMotifs.t.sol` does the same for grids, names (including the offset-table checks) and the SVG runs. This is the code that most needs an independent human review ([../AUDIT.md](../AUDIT.md)).
