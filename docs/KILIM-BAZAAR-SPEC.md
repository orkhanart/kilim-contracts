# Kilim Bazaar: the build spec

Written 11 October 2026 from the two judged rounds. The judges split on the winner. Judge 1 picked "scale" and judge 2 picked "minimal", and both used minimal's compiled contract as the base for the renderer and the overall shape. This spec therefore takes:

- **From minimal:** the renderer, the splice check, the escaping, the 32-bit seed and `_safeMint` last.
- **From scale:** the loom engineering: two-phase custody, counting in memory and folding once per touched word, computing each motif locally, the 8,191-block seed window, batch sealing and token ids in weaving order.
- **From collector:** the one-call `weave` that never touches the loom, the rule that a loom opens with at least 10 motifs, and a cheap record for small kilims.

Every fix the judges asked for is applied (listed in section 7). I re-read every claim about existing code in the repo, or on Sepolia at block 11,894,847.

**Checked today on Sepolia:**
- `settled()` false, `highestBid` 0.017 ETH, `highestBidMotifs()` = (50, 17), `endsAt` 21:08:48 UTC on 12 October 2026.
- `motifsAllocated` 66, `motifsClaimed` 21.
- The 1/1's HEAD is 1 chunk of 197 data bytes ending `<script>{const GRIDS='`. TAIL is 34 chunks; the first starts `O2Nv`, which decodes to `;const BLOB='H4sI…`.
- `headHash` 0x69dd43c6…261a and `tailHash` 0x25b853dc…b794 equal `onchain/build-page/manifest.json`.
- A local `keccak256(abi.encode(11155111, motifs, id)) % 1024 + 1` equals `motifOf` for ids 1, 2, 600,000 and 1,000,000 (motifOf(1) = 91).
- The EIP-2935 contract is at 0x0000F90827F1C53a10cb7A02335B175320002935, code hash 0x6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d, the same as on mainnet. A lookup 5,000 blocks back returned that block's hash.

**Checked in the stored artwork (decompressed from `build-page/tail.bin`):**
- It reads `typeof KILIM_PIECE<"u"`.
- readPiece parses the seed with `parseInt(seed,16)>>>0` and defaults `top` to 1e3.
- RANKS costs are 10/30/100/300/1e3/null, named Apprentice, Journeyman, Weaver, Artisan, Dyer, The Master.
- It has three classic `<script>` tags and no modules.

## 1) What it is

1. One new immutable contract, `contracts/src/KilimBazaar.sol`: an ERC-721 called "Kilim Bazaar" (KILIM). It has no owner, no setter, no pause, no upgrade and no ETH.
2. You burn your own motifs into a kilim in one of two ways:
   - **`weave(ids, to)`:** one transaction, up to about 300 motifs.
   - **The loom:** `deposit(ids)` in batches, then `weaveLoom(ids, to)`.

   Each id is taken from you with `transferFrom` and burned in the same call.
3. The number burned sets the rank: 10, 30, 100, 300, 1,000, and the Master at the winning bid in motifs, read from the auction. Kilims are numbered in weaving order within each rank ("Weaver 41").
4. Anyone can seal the seed later, from the hash of the block after the weave. The window is 8,191 blocks; if nobody seals within it, the kilim re-arms to a fresh block.
5. tokenURI is the 1/1's own stored page: its HEAD and TAIL chunks are copied as they are, and `;window.KILIM_PIECE={seed,motifs,top}` is spliced in right after the grids, so the artwork weaves exactly that kilim.

## 2) The contract

### Files, settings, inheritance
- `contract KilimBazaar is IERC4906, ERC721("Kilim Bazaar", "KILIM"), ReentrancyGuardTransient`. Use `supportsInterface override(ERC721, IERC165)`.
- Solidity 0.8.37, OpenZeppelin 5.6.1 (checked in node_modules), foundry.toml as it is: cancun (TSTORE and MCOPY), optimizer 200 runs, no via-IR.
- NatSpec in plain English.
- Imports: ERC721, IERC165, IERC4906, ReentrancyGuardTransient, Base64, Strings, SafeCast, and the three Kilim contracts.
- Runtime must stay at or under 24,576 bytes; expected about 21–22 KB (minimal's subset compiled to 19,038). If the build goes over, drop these views in this order: `loomHandOf`, `sealState`, `strayMotifs`, `ladder`.
- `sealed` is a reserved word in 0.8.37, so no identifier may use it.

### Constants
```
FLOOR = 10                          // the least a kilim holds
MOTIF_COUNT = 1024
MAX_BATCH = 65_535                  // ids per call; keeps the in-memory 16-bit counts carry-free (gas limits batches far below this)
MASTER = 6                          // ranks 1 Apprentice, 2 Journeyman, 3 Weaver, 4 Artisan, 5 Dyer, 6 The Master; 0 = none
ROYALTY_BPS = 500                   // uint96, as KilimMotifs.sol:25 and KilimOneOfOne.sol:32
HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935          // EIP-2935
HISTORY_CODEHASH = 0x6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d
SEALED = 1; WHOLE = 2; WINNING_BID = 4; PACKED = 8          // Kilim.flags bits
GRID_BYTES = 32_768; HEX_CHARS = 65_536                      // private, as KilimOneOfOne.sol:34-35
```
The fixed ladder costs (10, 30, 100, 300, 1000) and the names are pure functions. The names are Apprentice, Journeyman, Weaver, Artisan, Dyer, and "The Master" in traits but "Master" in token names.

### Immutables (all public)
- `KilimAuction auction`
- `KilimMotifs motifs` and `KilimOneOfOne oneOfOne`: both derived from the auction.
- `uint256 motifPrice`: `auction.MOTIF_PRICE()`, 0.001 ether (EnglishAuction.sol:38).
- `uint256 motifChainId`: `motifs.deploymentChainId()` (KilimMotifs.sol:32).
- `address royaltyReceiver`
- `uint256 seedWindow`: 8191 if HISTORY's code hash equals HISTORY_CODEHASH at construction, else 256.

### Storage, after OZ ERC721's slots 0–5 (the transient guard uses no slot)
```
string public description;          // written once (constructor)
string public externalUrl;          // written once; each kilim links to externalUrl + tokenId when non-empty
string public imageBase;            // written once; "" = on-chain picture (decision 1)
uint256 private _tally;             // eight uint32 lanes: lanes 0..5 = kilims woven at rank 1..6,
                                    // lane 6 (bits 192-223) = hand keys issued, lane 7 (bits 224-255) = kilims woven = last token id
mapping(address => Loom) private _looms;            // one open loom per wallet
mapping(uint256 => Kilim) private _kilims;          // token id => record (rank 0 = no kilim)
mapping(uint256 => uint256[64]) private _hands;     // hand key => counts (format below)

struct Loom  { uint32 handKey; uint32 count; uint32 minId; uint32 maxId; uint16 title; uint16 titleCount; uint16 distinct; }   // 176 bits, one slot; handKey 0 = no loom
struct Kilim { uint32 handKey; uint32 count; uint32 number; uint16 title; uint16 distinct; uint8 rank; uint8 flags; uint40 sealBlock; uint32 seed; } // 216 bits, one slot
```

**Hand formats** (in `_hands[key]`):
- **DENSE** (always for looms; for one-call weaves when it uses no more words): 16 lanes of 16 bits per word. Motif n's count is `(word[(n-1)>>4] >> (((n-1)&15)<<4)) & 0xffff`, where lane 0 is the least significant bits.
- **PACKED** (one-call weaves when it uses fewer words; flag PACKED): 8 entries of 32 bits per word. Entry i sits at bits `32*(i%8)` of word `i/8` and holds `(motif << 16) | count`. Entries are in ascending motif order, and there are exactly `distinct` of them, so the unused ones read 0.

**Ids and counts fit uint32:**
- Ids are bounded by `motifCap ≤ type(uint32).max` (KilimMotifs.sol:69).
- Counts and kilim totals can never exceed the motifs that exist. They are cast with SafeCast anyway.
- The `_tally` lanes cannot carry, because there are at most motifCap/10 kilims and hand keys.

### Constructor
`constructor(KilimAuction auction_, address royaltyReceiver_, bytes32 pageTailHash_, string memory description_, string memory externalUrl_, string memory imageBase_)`

Reverts `InvalidConfiguration` unless all of these hold:
1. `address(auction_).code.length != 0` and `royaltyReceiver_ != address(0)`.
2. `motifs_ = auction_.motifs()` and `oneOfOne_ = auction_.oneOfOne()`, and:
   - `motifs_.minter() == address(auction_)`
   - `oneOfOne_.minter() == address(auction_)`
   - `address(oneOfOne_.motifs()) == address(motifs_)`

   This is the same trio the auction checked (KilimAuction.sol:83-86).
3. `motifPrice = auction_.MOTIF_PRICE() != 0`.
4. The local motif formula equals `motifs_.motifOf(1)` and `motifs_.motifOf(motifs_.motifCap())`. The formula is `uint256(keccak256(abi.encode(motifChainId, address(motifs_), id))) % 1024 + 1`, as KilimMotifs.sol:148.
5. `oneOfOne_.tailHash() == pageTailHash_`. This pins the deployment to the stored page whose ladder and names the deploy script compared with these constants.
6. The splice point (`_checkSplicePoint`, minimal's code verbatim):
   - The last 13 data bytes of the last `headChunks()` chunk are `const GRIDS='`.
   - The first 4 data bytes of the first `tailChunks()` chunk are `O2Nv`, which is base64 of `;co`. pack_page.py:80-81 guarantees the `;`.
   - It reverts if the last HEAD chunk has fewer than 14 code bytes or the first TAIL chunk fewer than 5.
7. `description_`, `externalUrl_` and `imageBase_` are printable ASCII (0x20–0x7e) with none of `"`, `\`, `#` or `%`. They travel raw inside a `data:` URL, the same rule as pack_page.py:106-112. Once checked here, they need no escaping when read.
8. `seedWindow`: HISTORY's codehash compared with HISTORY_CODEHASH.

It does not require the auction to be settled: the Bazaar may be deployed any time after the auction, and everything that writes opens at settlement (decision 5).

### Writes (all `external nonReentrant`; none payable; no receive or fallback)

Every write is open to anyone but acts only on `msg.sender`'s own motifs and loom (`seal` excepted). Before settlement, `deposit`, `weave` and `weaveLoom` revert `NotSettled()`, because they all read `_terms()`:

```
function _terms() private view returns (uint256 top, uint256 first, uint256 won) {
    if (!auction.settled()) revert NotSettled();
    top = auction.highestBid() / motifPrice;          // exact: bids are whole units (EnglishAuction.sol:214); ≥ 10 (reserve, :40, :102)
    (first, won) = auction.highestBidMotifs();        // KilimAuction.sol:144-146
}
```
These values are final once settled is true:
- No bid lands once `block.timestamp >= endsAt` (EnglishAuction.sol:209).
- `settle` needs `endsAt` passed and sets `settled` once (EnglishAuction.sol:167-172).
- The winning range changes only in `_bid` (KilimAuction.sol:131-133).

**1. `weave(uint256[] calldata ids, address to) returns (uint256 tokenId)`: one kilim from exactly these motifs. The caller's loom is never touched.**
1. Reverts `InvalidRecipient` early if `to` is 0, this contract, motifs, auction or oneOfOne.
2. `(top, first, won) = _terms()`.
3. Reverts `TooFewMotifs(ids.length)` if `ids.length < FLOOR`.
4. `b = _take(ids)` (below).
5. Summarise b in memory, scanning touched words and lanes in ascending motif order:
   - `distinct` is the number of nonzero lanes.
   - `title` is the first lane with the strictly highest count, so the lowest number wins ties.
   - `denseWords` is `popcount(b.touched)`.
6. `key` = the next hand key (tally lane 6).
7. If `(distinct + 7) / 8 < denseWords`: write PACKED entries in ascending order, 8 per word, and set `flags = PACKED`. Otherwise write `_hands[key][s] = b.add[s]` for every touched s (DENSE).
8. `tokenId = _weave(to, key, ids.length, title, distinct, b.minId, b.maxId, flags, top, first, won)`.

**2. `deposit(uint256[] calldata ids) returns (uint256 loom)`: put motifs into your loom.**
1. `_terms()` (only the settlement check matters here).
2. Load `l = _looms[msg.sender]`. If `l.handKey == 0`:
   - Revert `TooFewMotifs(ids.length)` if `ids.length < FLOOR`. A loom therefore always holds at least 10 motifs and can always be woven.
   - Set `l.handKey` to the next hand key, `l.minId = type(uint32).max`, `l.maxId = 0`.
3. `_fold(l, _take(ids))`.
4. `_looms[msg.sender] = l`.
5. Emit `MotifsLoomed(msg.sender, l.handKey, ids.length, l.count)` and return `l.handKey`.

**3. `weaveLoom(uint256[] calldata ids, address to) returns (uint256 tokenId)`: weave your loom, after adding `ids` (may be empty).**
1. Early `to` check, then `(top, first, won) = _terms()`.
2. `l = _looms[msg.sender]`; revert `NoLoom()` if `l.handKey == 0`.
3. If `ids.length != 0`, `_fold(l, _take(ids))`.
4. `delete _looms[msg.sender]`. This is the snapshot: nothing can be added to this hand again, because only an open loom's key is ever written.
5. `tokenId = _weave(to, l.handKey, l.count, l.title, l.distinct, l.minId, l.maxId, 0, top, first, won)`.

**4. `seal(uint256[] calldata tokenIds) returns (uint256 sealedCount)`: anyone; never reverts on a bad entry. For each id:**
1. Load `k = _kilims[id]` (storage). Skip if `k.rank == 0` or `k.flags & SEALED != 0`.
2. `sb = k.sealBlock`; skip if `block.number <= sb`. Let `age = block.number - sb`.
3. If `age > seedWindow`: set `k.sealBlock = uint40(block.number + 1)`, emit `SeedRearmed(id, block.number + 1)`, continue. The re-arm depends on block numbers alone, never on a failed lookup.
4. Find the hash:
   - `age <= 256`: `h = blockhash(sb)`.
   - Otherwise (only reachable when seedWindow is 8191): `(ok, r) = HISTORY.staticcall(abi.encode(sb))`; `h = (ok && r.length == 32) ? abi.decode(r, (bytes32)) : 0`.
5. If `h == 0`, skip with no state change.
6. `seed = uint32(uint256(keccak256(abi.encode(h, address(this), id))))`. Set `k.seed = seed`, `k.flags |= SEALED`, emit `KilimSealed(id, h, seed)` and `MetadataUpdate(id)`, then `++sealedCount`.

**Internals.** Lane math runs in `unchecked` blocks only where the bounds are stated.

```solidity
struct Batch { uint256[64] add; uint256 touched; uint256 minId; uint256 maxId; }

function _take(uint256[] calldata ids) private returns (Batch memory b) {
    uint256 n = ids.length;
    if (n == 0 || n > MAX_BATCH) revert InvalidQuantity();
    // 1. Custody, all of it first: a plain transferFrom (no receiver hook), always from msg.sender.
    for (uint256 i; i < n; ++i) motifs.transferFrom(msg.sender, address(this), ids[i]);
    // 2. Burn and count in memory. burn is owner-only (KilimMotifs.sol:129-134): we own every id now.
    b.minId = type(uint256).max;
    for (uint256 i; i < n; ++i) {
        uint256 id = ids[i];
        motifs.burn(id);
        uint256 lane = _laneOf(id);                     // keccak(motifChainId, motifs, id) % 1024; motif = lane + 1
        b.add[lane >> 4] += 1 << ((lane & 15) << 4);    // n <= 65,535 so no lane carries
        b.touched |= 1 << (lane >> 4);
        if (id < b.minId) b.minId = id;
        if (id > b.maxId) b.maxId = id;
    }
}
```
`_laneOf` hashes in assembly at the free-memory pointer without moving it (scale's `_laneOf`), so nothing is allocated per id. It is valid because the id has just passed `transferFrom`, so it exists, lies in 1..motifCap and belongs to the caller.

```solidity
function _fold(Loom memory l, Batch memory b) private {
    uint256[64] storage words = _hands[l.handKey];
    for (uint256 s; s < 64; ++s) {
        if ((b.touched >> s) & 1 == 0) continue;
        uint256 w = words[s]; uint256 a = b.add[s];
        for (uint256 j; j < 16; ++j) {
            uint256 inc = (a >> (j << 4)) & 0xffff; if (inc == 0) continue;
            uint256 old = (w >> (j << 4)) & 0xffff; uint256 c = old + inc;
            if (c > 0xffff) revert CountOverflow();            // unreachable: at most ~1,100 ids show one motif
            if (old == 0) ++l.distinct;
            uint256 m = (s << 4) + j + 1;
            if (c > l.titleCount || (c == l.titleCount && m < l.title)) { l.title = uint16(m); l.titleCount = uint16(c); }
        }
        words[s] = w + a;                                        // lane-wise, carry-free (checked above)
    }
    l.count = SafeCast.toUint32(l.count + /*n*/ popcount-free: ids.length);  // pass n in
    if (b.minId < l.minId) l.minId = uint32(b.minId);
    if (b.maxId > l.maxId) l.maxId = uint32(b.maxId);
}
```
The title rule is the page's: most burned, lowest number among equals (bazaar.js:149). Folding is exact because counts only rise. After a batch, the maximum is either the old title, whose count is unchanged, or a touched lane, and every touched lane is compared.

```solidity
function _weave(address to, uint256 key, uint256 count, uint256 title, uint256 distinct,
                uint256 minId, uint256 maxId, uint256 flags, uint256 top, uint256 first, uint256 won)
    private returns (uint256 tokenId)
{
    uint8 rank = _rankFor(count, top);                           // ≥ 1: count ≥ 10 here
    if (distinct == MOTIF_COUNT) flags |= WHOLE;
    if (won != 0 && minId >= first && maxId - first < won) flags |= WINNING_BID;
    uint256 t = _tally;
    tokenId = (t >> 224) + 1;                                    // global weaving order, 1, 2, 3 … no gaps
    uint256 number = ((t >> (32 * (rank - 1))) & 0xffffffff) + 1;
    _tally = t + (1 << 224) + (1 << (32 * (rank - 1)));          // (hand-key lane bumped where the key was issued)
    _kilims[tokenId] = Kilim(uint32(key), uint32(count), uint32(number), uint16(title), uint16(distinct),
                             rank, uint8(flags), uint40(block.number + 1), 0);
    emit KilimWoven(tokenId, msg.sender, to, rank, number, count, title, block.number + 1);
    _safeMint(to, tokenId);                                      // last: the only call that can reach unknown code
}

function _rankFor(uint256 count, uint256 top) private pure returns (uint8) {
    if (count < FLOOR) return 0;
    if (count >= top) return MASTER;
    if (count >= 1000) return 5; if (count >= 300) return 4; if (count >= 100) return 3; if (count >= 30) return 2;
    return 1;
}
```

### Overrides and receiving
- `_update(to, tokenId, auth)`: reverts `InvalidRecipient` if `to` is this contract, motifs, auction or oneOfOne, then calls `super._update`. None of the four can move a kilim (sibling pattern, KilimOneOfOne.sol:436-439). Unsealed kilims transfer normally.
- `onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4)`: always reverts `StrayTransfer()`. Every `safeTransferFrom` to the Bazaar bounces. So does an auction claim to it, because `mintMotifs` uses `_safeMint` (KilimMotifs.sol:122).
- No kilim burn exists: a woven kilim is final.

### Views
| Function | Returns / behaviour |
|---|---|
| `masterCost() returns (uint256)` | `_terms().top`; reverts `NotSettled` before settlement |
| `ladder() returns (uint256[6] costs, bool open)` | Before settlement: `[10,30,100,300,1000,0]`, false. After: each fixed cost, or 0 where `cost >= top` (that rank falls away); `costs[5] = top`; true |
| `rankFor(uint256 count) returns (uint8)` | `_rankFor(count, masterCost())`, 0 under the floor |
| `kilim(uint256 tokenId) returns (Kilim memory)` | Reverts `UnknownKilim(tokenId)` if rank is 0 |
| `loomOf(address weaver) returns (Loom memory)` | handKey 0 means no loom |
| `handOf(uint256 tokenId) returns (uint256[] memory motifNumbers, uint256[] memory counts)` | Ascending, length `distinct`; reads PACKED or DENSE |
| `loomHandOf(address weaver) returns (uint256[] memory, uint256[] memory)` | The open loom's hand (DENSE) |
| `pieceOf(uint256 tokenId) returns (string memory)` | The exact KILIM_PIECE JSON object (S below, without `;window.KILIM_PIECE=`), for the site's `?piece=` simulator (app.js:27). Reverts `NotSealed` or `UnknownKilim` |
| `sealState(uint256 tokenId) returns (uint8)` | 0 no kilim, 1 waiting (`block.number <= sealBlock`), 2 sealable now, 3 the next seal() re-arms, 4 sealed |
| `wovenAt(uint8 rank) returns (uint256)`; `totalSupply() returns (uint256)` | Tally lanes |
| `strayMotifs() returns (uint256)` | `motifs.balanceOf(address(this))`. Between calls the Bazaar holds only motifs sent to it by plain transfer |
| `tokenURI(uint256)` | Section 6. Ends in assembly `return`: MUST NEVER BE CALLED INTERNALLY |
| `contractURI()` | Base64 JSON `{"name":"Kilim Bazaar","description":…,"external_link":…,"seller_fee_basis_points":500,"fee_recipient":"0x…"}`, the same shape as KilimMotifs.sol:262-281 |
| `royaltyInfo(uint256, uint256 salePrice)` | `(royaltyReceiver, salePrice * 500 / 10_000)` |
| `supportsInterface(bytes4)` | ERC-721, metadata, ERC-165, `0x2a55205a` (2981), `0x49064906` (4906) |

### Events
```
event MotifsLoomed(address indexed weaver, uint256 indexed loom, uint256 quantity, uint256 count);
event KilimWoven(uint256 indexed tokenId, address indexed weaver, address indexed to, uint256 rank, uint256 number, uint256 count, uint256 title, uint256 sealBlock);
event SeedRearmed(uint256 indexed tokenId, uint256 sealBlock);
event KilimSealed(uint256 indexed tokenId, bytes32 blockHash, uint256 seed);
// IERC4906: MetadataUpdate(uint256 _tokenId) at every seal; ERC-721 Transfer/Approval/ApprovalForAll.
// Each burned motif also shows on Motif Bazaar as Transfer(holder → Bazaar) then Transfer(Bazaar → 0).
```

### Errors
`InvalidConfiguration()`, `NotSettled()`, `InvalidQuantity()`, `TooFewMotifs(uint256 count)`, `NoLoom()`, `CountOverflow()`, `InvalidRecipient()`, `UnknownKilim(uint256 tokenId)`, `NotSealed(uint256 tokenId)`, `GridsUnavailable()`, `StrayTransfer()`. OZ's `ReentrancyGuardReentrantCall`, the ERC721 errors and KilimMotifs' `Unauthorized` bubble up.

## 3) The loom and burning

**The flow:**
1. **Approve once.** The holder calls `motifs.setApprovalForAll(bazaar, true)`. A per-token `approve` also works (OZ `_isAuthorized`).
2. **Up to about 300 motifs (Apprentice to Artisan): one call.** `weave(ids, to)` mints the kilim at once, marked "Sealing".
3. **More motifs: the loom.**
   - The first `deposit` carries at least 10 ids. Then deposit as often as needed, and close with `weaveLoom(ids, to)`, where ids may be empty.
   - One loom per wallet. Nobody else can add to it, close it or block it.
   - `weave` never touches the loom, so a holder can weave Apprentices while slowly filling a Master.
   - A loom has no exit and no split (tool audit BZ-5, 12 October 2026). Motifs burn at `deposit`, and only the same address can close the loom, into one kilim, with `makeFromLoom` (this spec's `weaveLoom`). **For integrators:** a contract that can call `deposit` but not `makeFromLoom` (a vault, a module-restricted multisig, a helper contract) strands its burned motifs for good, and so does a wallet whose key is lost. The depositing address must be able to make the closing call.
4. **Seal.** `seal([...])` from block B+2 onward, by the weaver's page, the site's sealer or anyone.

**Custody and burn.** `burn` is owner-only and ignores approvals (KilimMotifs.sol:127-134), so the Bazaar takes custody first. All transfers come before all burns. Moving and burning one id at a time would take the Bazaar's balance slot 0→1→0 for every motif. That costs a fresh new-slot charge each time, with capped refunds: measured 46,108 against 26,361 per motif on mainnet rules, and 55,171 against 44,345 execution on Sepolia.

**Why custody is safe:**
- KilimMotifs' `_update` blocks only itself and the minter (KilimMotifs.sol:378-381), so the Bazaar can hold motifs.
- A burned id can never be minted again (KilimMotifs.sol:121, 131, 137-139).
- After every call the Bazaar's motif balance is what it was before.

**Batch limits:**
- No gas cap is coded. `MAX_BATCH` (65,535) only keeps the memory counts carry-free.
- **Site rule (since the 12 October 2026 tool audit, BZ-1): each call is sized by its gas, not by a fixed count.** The site sends at most 150 ids per `make` or `deposit`, estimates each call with `eth_estimateGas` before the wallet prompt, splits it again in proportion while the estimate is over 13M, and sends it with the estimate plus a fifth as its gas limit, which stays under 16,777,216. A kilim above one call goes into the loom, then `makeFromLoom` closes it; the page says how many confirmations that takes before the first one.
- Why not 300: 300 ids that each open a fresh `_burned` bucket take 13.29M today (`deposit` 13.82M), but about 43M (`deposit` about 46M) under Glamsterdam, where every new slot costs 97,920 state gas. That is 72–77% of a 60M block's state budget, and a transaction is only included while `tx.gas` fits what is left of it. 150 such ids are about 6.9M today and about 22M under Glamsterdam, so the 13M ceiling splits them in two there; 150 consecutive or started-bucket ids stay one call.
- On mainnet before Glamsterdam, up to 600 ids whose buckets are already started (15.48M), or 760 consecutive ids (15.6M).
- On Glamsterdam the state gas rides above the cap, so a 300-id call would need a gas limit above 2^24 (about 20M for a loom opening, up to about 50M if every bucket is fresh), which wallets that cap estimates at 2^24 refuse. The site's calls never ask for more than 16,777,216.
- Ids sorted ascending share `_burned` buckets and cost less.

**Per motif.** Measured in the design round by the "scale" prototype, which has the same custody, local motif and memory fold as this spec:
- Mainnet rules: a local EVM on the Osaka schedule running the deployed KilimMotifs code.
- Sepolia: live eth_call with state overrides (Glamsterdam).

| One motif burned | Mainnet, gross | Mainnet, net of refunds | Sepolia execution | Sepolia state gas |
|---|---:|---:|---:|---:|
| Consecutive ids (its 256-id bucket already written this call) | 21,929 | ≈17,500 | 33,738 | 0 |
| A market motif, bucket already started | 26,361 | ≈21,100 | 44,345 | 0 |
| First burn in an untouched 256-id bucket | 43,461 | ≈38,700 | ≈43,400–45,300 | +97,920 |
| (Interleaved transfer and burn, rejected) | 46,108 | | 55,171 | |

The mainnet refunds are 4,800 per motif (the owner slot is cleared) plus 19,900 once per call (the Bazaar's balance goes back to 0), capped at a fifth of the gas.

**Fixed costs.** Mainnet is Cancun pricing; on Sepolia a new slot is about 110,000 in all, which is 97,920 state plus about 12,100 execution (repo calibration 110,020, PrizeGasBudget.t.sol).
- Transaction: 21,000 plus about 164 calldata gas per id.
- New count word (DENSE), or 8 entries (PACKED): 22,100 on mainnet; 12,100 execution plus 97,920 state on Sepolia.
- Count word already there: about 5,000 per touched word per batch.
- New loom slot: about 27k on mainnet; +97,920 state on Sepolia.
- Weave fixed part (record, ERC-721 owner, first-time balance, tally, events, three auction reads): about 90k on mainnet for a wallet's first kilim and about 73k after. On Sepolia about 60k execution plus 3 new slots, or 2 if the wallet already holds a kilim.

**Per transaction.** These are estimates derived from the primitives above. `BazaarGas.t.sol` and the Sepolia receipts replace them before anything is published. Assumptions: market motifs, a wallet's first kilim, distinct and touched words as expected for random hands.

| Call | Mainnet gross / net | Sepolia execution / total |
|---|---:|---:|
| `weave` 10 (Apprentice; PACKED, 2 words) | 0.42M / 0.35M | 0.57M / 1.06M |
| `weave` 17 (Sepolia's likely Master; 3 words) | 0.63M / 0.53M | 0.85M / 1.44M |
| `weave` 30 (Journeyman; 4 words) | 1.0M / 0.83M | 1.46M / 2.17M |
| `weave` 100 (Weaver; 12 words) | 3.0M / 2.5M | 4.7M / 6.2M |
| `weave` 300 (Artisan; 33 words) | 8.8M / 7.3M | 13.9M / 17.4M |
| `deposit` 300, opening a loom (≈63 words) | 9.4M / 7.9M | 14.2M / 20.5M |
| `deposit` 300 into an open loom | 8.3M / 6.9M | 13.7M / 13.7M |
| `weaveLoom([])` | 0.11M | 0.08M / 0.38M |
| `seal`, one kilim | ≈31k (minimal measured 30,665) | 20,295 inner (history path 26,173; re-arm 19,284) + 21k |
| `seal`, 20 kilims (the sealer) | ≈0.2M | ≈0.33M |
| `setApprovalForAll`, once per wallet | ≈46k | ≈130k |
| Deploy (≈22 KB runtime) | ≈5.0M (under the 8M policy) | ≈35M (1,530/byte code deposit + 183,600 account + strings) |

**Gas table to publish beside the ladder.** Minimum per kilim, motifs already claimed (claiming is separate: 64 per claim, KilimMotifs.sol:19). The site sends at most 150 ids a transaction (BZ-1), so the counts below are today's; under Glamsterdam a call whose ids open fresh buckets is split again by its estimate. The gas figures were derived for 300-id batches; 150-id batches add about 0.1M of fixed cost per extra transaction.

| Rank | Transactions | Mainnet (net, today's pricing) | Sepolia / Glamsterdam |
|---|---:|---:|---:|
| Apprentice, 10 | 1 | ≈0.35M | ≈1.1M |
| Journeyman, 30 | 1 | ≈0.83M | ≈2.2M |
| Weaver, 100 | 1 | ≈2.5M | ≈6.2M |
| Artisan, 300 | 2 | ≈7.3M | ≈17.4M |
| Dyer, 1,000 | 7 | ≈24M | ≈53M |
| Master at 10 ETH, 10,000 | 67 | ≈0.19–0.23 G | ≈0.36–0.46 G |

Plus a seal of about 0.03M and one approval per wallet. The Master's figure is the same however the motifs were gathered; nearly all of it is the burns.

## 4) The seed

**Sealing:**
- A weave in block B records `sealBlock = B + 1`, the block after the one you weave in (rule 7).
- From B+2 anyone may call `seal`: `seed = uint32(uint256(keccak256(abi.encode(hash(sealBlock), address(this), tokenId))))`, the low 32 bits.
- The token id makes kilims woven in the same block differ. The contract address separates deployments, and the block hash is already chain-specific.
- The full block hash goes in `KilimSealed` for provenance.

**Why 32 bits:**
- The stored readPiece does `parseInt(seed,16)>>>0` (bazaar.js:189, re-checked in the stored bytes), and weave does `seed >>>= 0` (bazaar.js:139). A 256-bit hex string would give every kilim seed 0.
- The contract writes `"0x"` plus 8 lowercase hex digits (`Strings.toHexString(seed, 4)`). That is the page's own `formatSeed` (randomize.js:32), so the Seed trait and the page's `dataset.piece.seed` match.

**Where the hash comes from**, by `age = block.number − sealBlock`:

| age | Source |
|---|---|
| ≤ 0 | Not mined yet: skipped |
| 1–256 | `BLOCKHASH(sealBlock)` |
| 257–8,191 | EIP-2935 history contract (serves `block.number−8191 … block.number−1`; bytecode read today). Used only when its code hash matched at construction |
| > `seedWindow` | Re-arm: `sealBlock = block.number + 1`, `SeedRearmed`, no seed yet |

**Re-arm rules:**
- A re-arm is decided from block numbers alone. A lookup that fails inside the window only skips, so no caller can force a re-arm while the hash is readable, whatever gas they send.
- After a re-arm the next seal uses the new block's hash, which nobody knew when it was set. Nothing ever falls back to a known value.
- Without the history contract (a bare local chain) the window is 256.

**Who seals.** Anyone, with the same result at any moment in the window. The site runs a sealer with no privileges, `kilim-sealer/` (built 12 October 2026 for audit finding SL-1):
- From its own wallet, it follows `KilimMade` and `SeedRearmed` and sends one batched `seal` as soon as the head reaches a kilim's seal block, so the kilim is sealed in B+2.
- It counts a kilim as sealed only from `KilimSealed`.
- Gas on anvil, at today's mainnet prices: 32,593 for a kilim sealed alone, about 10,150 for each further kilim in a batch, 31,022 for a re-arm.
- Gas on Sepolia: about 15.5k per kilim in a batch.

The weaver's page offers "Seal now".

**Before sealing:**
- tokenURI has no `animation_url`, the trait Seed reads "Sealing", and the image is the on-chain title-motif drawing.
- At seal, `MetadataUpdate(id)` tells marketplaces to refresh. Re-arming is an event only, with no trait.

**Griefing, front-running, re-rolls:**
- **No preview.** At weave time hash(B+1) does not exist, and the burn is final first.
- **Minting before the seed.** Minting at weave means a receiver contract cannot read the seed in `onERC721Received` and refuse a bad one.
- **Front-running a seal** changes nothing.
- **Withholding.** A weaver who dislikes the seed must stop everyone, the site's sealer included, from sealing for 8,191 blocks (about 27.3 hours) to get a re-arm. With the sealer running, that is not possible in practice.
- **Residual risk:** the builder of block B+1 can grind its hash. Every next-block-hash seed has this, the rule chose it, and the stake is one kilim's look.
- **Rejected alternatives:**
  - `prevrandao` at seal time: it is known a block ahead, so the sealer could pick the block.
  - Minting at seal: the sealer would pay for minting, and the re-roll through the receiver hook would be possible.
- **Seed collisions:** about 1% across 10,000 kilims; two kilims with the same seed still differ by hand and rank.

## 5) Ranks, the Master, tags, numbering

**Rank.**
- The Master if `count >= top`. Otherwise the highest of 1,000, 300, 100, 30 and 10 at or under the count. Under 10, no kilim.
- This is the page's rule exactly: readPiece keeps the fixed ranks whose cost is below `top` and puts the Master at `top` (bazaar.js:191); rankFor keeps the highest cost at or under the count (bazaar.js:44).
- Ranks the Master undercuts fall away by themselves: at `top` 800, a count of 900 is a Master, so there is no Dyer. At `top` 10, every kilim is a Master.
- Nothing above a rank is wasted: a Journeyman of 50 says 50 and the page draws all 50.

**The Master's price.**
- `top = highestBid / MOTIF_PRICE`, read live at every weave and in tokenURI and `pieceOf`. It is final after settlement (section 2).
- If the pool ran short, the winning bid earned fewer motifs than `top`, or none (KilimAuction.sol:149-151). The Master still costs `top`, as decided on 11 October.
- Sepolia today: 0.017 ETH, so `top` = 17. If the auction settles there, the ladder is Apprentice 10–16 and The Master 17 or more.

**"Woven from the winning bid".**
- Set when `won != 0 && minId >= first && maxId − first < won`, so every burned id lies in `[first, first+won)`.
- It is judged at weave against the final range, using the min and max id the loom kept across its deposits.
- It applies at any rank, as rule 6 is written ("a kilim woven only from them carries that tag"). A tagged Master needs `won == top` and all of those ids.
- It follows the ids, not the winner (tool audit CR-2 and BZ-3, 12 October 2026): the winner can claim them to any address, and whoever holds them can make the tagged kilim. Each id burns once, so at most one tagged Master can exist. Claims mint a bidder's oldest range first, so a winner with earlier bids claims those before any id of the winning bid.
- `won == 0` never tags.
- Sepolia: ids 50–66 woven together make "Master 1", tagged.

**"Whole".** `distinct == 1024`, which needs at least 1,024 motifs, so only a Dyer or a Master.

**Title motif.** The motif burned most, the lowest number among equals, the same as the page (bazaar.js:149). It names the kilim and is the page's sculpture source (app.js:44).

**Numbering.**
- `tokenId` runs 1, 2, 3, … in weaving order, with no gaps (a loom has no token id).
- `number` counts per rank in weaving order.
- The token name is `"<Rank> <number> · <title name>"`, with "Master" for rank 6 as in the rules ("Master 3"), for example "Weaver 41 · Burdock". The middle dot is written as `·` so the answer stays ASCII. This follows the rules (the title motif "names the kilim", kilims are numbered "Weaver 41") and the page's own title (app.js:280).
- With no caps, there is no race beyond who gets the low numbers.

## 6) tokenURI

**What is stored and reused.**
- `oneOfOne.headChunks()` (KilimOneOfOne.sol:102-104): HEAD, the raw loader up to and including `const GRIDS='`, 197 bytes on Sepolia.
- `oneOfOne.tailChunks()` (KilimOneOfOne.sol:106-108): TAIL, base64 of the loader's rest, encoded on its own (pack_page.py:176). It starts `;const BLOB='…`, holds the gzipped artwork, and ends with `document.open(); document.write(…'<script>KILIM_GRIDS='…)`.
- The 1/1 answers `scheme ‖ PREFIX ‖ base64(HEAD ‖ hex(grids) ‖ ' ‖ pad) ‖ TAIL ‖ "}` (KilimOneOfOne.sol:110, 247-328; pack_page.py:139-146). PREFIX (the 1/1's JSON and its still) is not used here.

**Where KILIM_PIECE goes.**
- A literal `<script>` before the artwork's script is impossible. The artwork is gzipped inside BLOB in TAIL, which is immutable and hash-checked, and the fixed loader writes only KILIM_GRIDS into it.
- The only bytes a contract writes are the middle piece. So KILIM_GRIDS and KILIM_PIECE share the splice point: the grids inside the quotes, the piece right after the closing quote.
- The loader then reads `{const GRIDS='<65,536 hex>';window.KILIM_PIECE={…}␠␠;const BLOB='…';(async()=>{…document.open();document.write(…)})()}`. That is valid JavaScript: one more statement inside the loader's block, run before `document.open()`.
- `document.open()` keeps the Window, as pack_page.py:12-15 notes. The judges confirmed in headless Chrome that `window.KILIM_PIECE` survives, and the artwork's `typeof KILIM_PIECE` (app.js:27) finds it.
- S holds only digits, hex, brackets, commas, colons, quotes, `x` and its fixed keys. It never contains `'`, `<` or `</script`.
- `KILIM_GRIDS` stays exactly 65,536 hex characters, as grids.js `motifsFrom` requires.
- Rules line 86 should be reworded to this equivalent when the contract lands.

**S, exactly** (built in one pass into a buffer of `160 + 13·distinct` bytes, then the length is set):
```
;window.KILIM_PIECE={"seed":"0x" HEX8(seed) ","motifs":[ [n,c] (, [n,c])* ],"top": DEC(top) }
```
- Entries are every nonzero count in ascending motif number, decimal with no leading zeros and no spaces. It equals `';window.KILIM_PIECE=' + JSON.stringify({seed, motifs, top})` in JS and `json.dumps(…, separators=(',',':'))` in Python.
- **Ascending order matters.** The page's `standIn` breaks ties by hand order with a strict `<` (bazaar.js:157-166). NatSpec says so, and `pieceOf` must be passed on unchanged.

**The answer for a sealed kilim, byte by byte:**
```
before = "data:application/json;utf8,"
         {"name":"<RankWord> <number> \u00b7 <escape(motifName(title))>",
          "description":"<description>",
         ["external_url":"<externalUrl><tokenId>",]            (only when externalUrl is non-empty)
          "image":"<IMAGE>",
          "animation_url":"data:text/html;base64,
piece  = BASE64( HEAD ‖ hex(motifs.grids()) [65,536 lowercase] ‖ ' ‖ S ‖ pad )
         TAIL                                               (the 1/1's chunks, copied as they are)
after  = ","attributes":[ TRAITS ]}
pad    = (−(|HEAD| + 65,536 + 1 + |S|)) mod 3 spaces        (on Sepolia, |HEAD| = 197: pad = (2 − |S|) mod 3)
m      = |HEAD| + 65,536 + 1 + |S| + pad                    (a multiple of 3, so no '=' and the two base64 runs join)
total  = |before| + 4m/3 + |TAIL| + |after|
```

**The image:**
- An unsealed kilim always shows the title motif's own drawing: `data:image/svg+xml;base64,` + base64(`motifs.svg(title)`) (KilimMotifs.sol:227-259).
- A sealed kilim shows the same drawing when `imageBase` is empty, otherwise `<imageBase><tokenId>` (decision 1).
- No contract can draw a kilim's opening frame.

**Traits, in this order:**
```
{"trait_type":"Rank","value":"Apprentice|Journeyman|Weaver|Artisan|Dyer|The Master"}
{"trait_type":"Number","display_type":"number","value":41}
{"trait_type":"Motifs","display_type":"number","value":150}
{"trait_type":"Distinct motifs","display_type":"number","value":87}
{"trait_type":"Title motif","value":"Burdock (motif 23)"}          (Motif Bazaar's own "Name (motif n)" form)
{"trait_type":"Seed","value":"0x1a2b3c4d"}                          ("Sealing" before the seal)
[{"trait_type":"Whole","value":"Yes"}]
[{"trait_type":"Woven from the winning bid","value":"Yes"}]
```
- **Unsealed answer:** `"data:application/json;utf8," + {name, description, [external_url], image, "attributes":[…]}`, returned normally, with no animation_url.
- **Text safety:**
  - Motif names go through `_escapeJson` (minimal's version): `"` and `\` get a backslash; control characters, `#` and `%` become `\u00XX`. A raw `#` would cut a data: URL and `%XX` would be decoded.
  - The judges checked that all 1,024 names are plain ASCII without any of these, but the contract does not rely on it.
  - The constructor already refused bad characters in the three texts.

**Assembly** (`_respondWithPage(before, S, after)`, called last from tokenURI). It is KilimOneOfOne.sol:128-329 copied verbatim: `sectionSize`, `copyChunks`, `hexHalf`, `base64Block`, the live `grids()` staticcall with its two `GridsUnavailable` checks, the forward hex expansion into the second half of the hex room, the in-place encoding with the raw bytes at `encoded + m/3`, the tail groups through the alphabet in scratch memory, the final length check, zeroing the last word, and `return(ptr, 64 + roundup32(total))`. There are four marked changes:
1. `m` includes `|S|`.
2. `before` is MCOPYed in place of the scheme and PREFIX: `encoded = ptr + 64 + |before|`.
3. After the closing quote, S is MCOPYed, then spaces up to `raw + m`.
4. `after` is MCOPYed after TAIL in place of `"}`.

The in-place invariant still holds: block j exists only when `24(j+1) ≤ m`, so `encoded + 32j + 32 ≤ raw + 24j + 24`. The grids expansion ends at `hexStart + 65,536`, before S is written. `before`, S, `after` and the chunk lists all sit below `mload(0x40)`. `_checkSplicePoint` guarantees the layout.

**Size.** The animation_url is about 920,600 + 1.33·|S| characters: at most about 939 KB for a whole Master, under Chromium's 2 MiB limit (page.test.mjs).

**Gas to read** (measured in the design round on the same assembly):

| Kilim | Mainnet rules (local) | Sepolia eth_call |
|---|---:|---:|
| Unsealed | 269,979 | ≈0.3M |
| Apprentice, sealed | 4,562,690 | 4,414,104–5,164,081 |
| Weaver, 100 | 4,909,941 | 4,506,898 |
| Master, 1,024 drawings, heaviest title motif (504) | 6,209,183 (1,020 drawings) | 6,654,193 (937,472 bytes) |
| Digit upper bound (1,024 × 65,535) | | 6,324,773 |

All are under the project's 8M ceiling (enforced by test) and the 16,777,216 eth_call cap of Reth and Nethermind (AUDIT.md:291); the 1/1 reads at 4.52M. A non-empty `imageBase` skips the SVG, saving about 0.14–0.43M.

## 7) Security

**Fixed from the judges' notes:**
- The 256-block window becomes 8,191 blocks, with a re-arm decided by block numbers.
- The kilim is minted to a chosen `to`, so a wallet that cannot hold ERC-721 strands nothing.
- A loom opens with at least 10 motifs, so nothing is ever stranded below the floor.
- Token ids follow weaving order with no gaps.
- `seal` takes batches and skips bad entries.
- Each motif is computed locally (one external call fewer per id, about 20M gas over a 10,000-motif Master), and each batch is folded once per touched word.
- The hard cap of 200 ids is removed; batches are sized by gas.
- `weave` does not fold into an open loom.
- Small kilims use the PACKED record: an Apprentice is about 1.06M on Sepolia instead of 1.83M.
- Whole and the winning-bid tag carry `trait_type`.
- There is no "Re-armed" trait.
- There is no interleaved custody, no SSTORE2 deposit pages and no computed traits or card in this build.

**Each attack and how it is closed:**

1. **Stray transfers.**
   - `onERC721Received` reverts, so any `safeTransferFrom` to the Bazaar bounces. An auction claim with `to` = Bazaar also reverts: the auction allows it (KilimAuction.sol:241-244), but `_safeMint` (KilimMotifs.sol:122) calls the Bazaar, so the bidder keeps the credits.
   - A plain motif `transferFrom` to the Bazaar cannot be refused. That motif is inert forever:
     - `_take` pulls only `from = msg.sender`, and OZ reverts `ERC721IncorrectOwner` when the Bazaar already owns the id.
     - No function moves it, and nothing counts it.
     - `strayMotifs()` shows it. The site never sends plain transfers.
   - **The Unwoven Kilim is lost the same way** (tool audit BZ-2, 12 October 2026). The 1/1's `_update` refuses only itself, the auction and Motif Bazaar; it was deployed first and cannot know the Bazaar. So its owner's plain `transferFrom(owner, bazaar, 1)` succeeds, and no function moves it out. A `safeTransferFrom` bounces with `StrayTransfer`. There is no rescue role, so the only guard is in words: the rules, the weave page and the claim page say never to send anything to the Bazaar by hand, and the site refuses the Bazaar as a recipient of any claim, prize or refund.
   - Kilims sent to the Bazaar, motifs, auction or 1/1 revert in `_update`.
   - No payable function and no receive, so ETH sent to it reverts.
2. **Reentrancy through `onERC721Received`.**
   - The Bazaar receives no callbacks: plain `transferFrom`, and `burn` has no hook.
   - Its only outgoing hook is `_safeMint(to)`, the last statement, after the record, the tally and the loom deletion are written.
   - All four writes are `nonReentrant` (OZ transient guard), so a hook that re-enters reverts.
   - The EIP-2935 read is a staticcall. Every other external call goes to the immutable auction (views) or motifs.
3. **Griefing a loom.**
   - Looms are keyed by `msg.sender`, and only the caller's own ids go in. There is no `from` and no depositFor.
   - Nobody can add to someone else's loom to change its title or break its tag, or close or block it.
   - A loom never sits below 10 and never expires.
   - A weave fails only on the weaver's own `to`. That includes an EIP-7702-delegated wallet without the hook; the loom stays and the weaver can name another `to`.
4. **Seed manipulation.** Section 4: no preview, a seal that is the same for any caller at any time, no forced re-arm (block numbers only; the 1/64 gas rule makes starving the lookup impossible anyway). The residual risks are builder grinding and withholding for 27 hours against a public sealer.
5. **Double counting.**
   - An id is counted only after this call moved it from the caller and burned it.
   - A duplicate id in one call reverts at its second `transferFrom`, and so do a burned or unminted id, someone else's id and a stray.
   - Counts, distinct and title all come from the same batch words.
   - Invariant: the lanes summed over all hands equal the motifs the Bazaar burned.
6. **Front-running.**
   - No caps, no prices and no places, so reordering only changes the low numbers.
   - The price and the range are final before anything can be woven.
   - A standing approval cannot be used by a third party through the Bazaar, which never takes `from`.
7. **Gas DoS.**
   - No loop runs over shared state.
   - Writes loop over the caller's own calldata; `seal` over the caller's list, skipping entries.
   - `weave`'s fixed part and `weaveLoom` cost the same at any size.
   - tokenURI is bounded: 64 words at most, 1,024 entries and 35 fixed chunks; worst case measured 6.65M.
8. **Data: URL and script injection.** Names are escaped, the texts are refused at deployment, and S contains only characters the contract writes, so it cannot close the loader's script or the JSON.
9. **Misconfiguration.** The constructor checks:
   - the auction trio;
   - the local motif formula against `motifOf`;
   - the pinned `tailHash`;
   - the splice markers;
   - the history code hash.
10. **Arithmetic.**
    - 16-bit lanes are checked before every fold, and in memory `n ≤ 65,535`.
    - uint32 casts go through SafeCast; the tally lanes are bounded by motifCap/10.
    - `unchecked` appears only in lane extraction and the digit writer, on bounded values.
11. **Assembly.** The renderer is the audited KilimOneOfOne routine with four marked changes, and keeps its length check and `return`. The digit writer writes only inside the buffer sized for it. tokenURI is never called internally (NatSpec, and a test that the source never calls it). Tests compare it byte for byte with an OZ Base64 reference.
12. **Admin, funds, permanence.** No owner, setter, pause, upgrade or withdraw, and no funds. The dependencies are immutable: the 1/1's chunk lists are written once (KilimOneOfOne.sol:45-48), the grids are hash-checked (KilimMotifs.sol:81), and the auction's terms are final after settlement. A kilim is final.

## 8) Tests

**Fixtures.**
- `contracts/test/bazaar/BazaarBase.sol` deploys the motifs (TestBase grids) and a 1/1 from a packed page store:
  - default `onchain/test/fixtures/page-store`, which is in git and packed by pack_page (197-byte HEAD, one TAIL chunk starting `O2Nv`);
  - `onchain/build-page` when present, for the page tests.
- TestBase's stand-in `PAGE_REST` starts with `'`, so the constructor rightly refuses it, and the tests check that refusal.
- It runs the real KilimAuction to settlement with the TestBase helpers (100 registrations, bid, warp, settle) at winning bids of 0.01, 0.017, 0.3, 0.8, 1, 1.001, 7.3 and 10 ETH.
- Motifs reach holders through `vm.prank(address(auction)); motifs.mintMotifs(...)`, keeping the winning range on the winner.
- For Whole: scan `motifOf` over a motifCap of 10,000 for about 7,700 ids that cover all 1,024 drawings.
- For the history path: `vm.etch(HISTORY, 0x3373ff…5f5500)` (the 83 canonical bytes) before deployment, and `vm.store(HISTORY, bytes32(n % 8191), h)`.

**Forge suites** (default profile unless marked):

1. **`KilimBazaar.t.sol`, behaviour.**
   - Constructor:
     - Reverts, each on its own: no code, zero receiver, a broken trio, a wrong `tailHash`, a HEAD not ending `const GRIDS='`, a TAIL not starting `O2Nv`, `"`, `\`, `#`, `%` or a control byte in any text.
     - The immutables equal the auction's.
     - `seedWindow` is 8191 with the etched history and 256 without.
   - Settlement gate: `deposit`, `weave`, `weaveLoom`, `masterCost` and `rankFor` revert `NotSettled` before settlement and work after. `ladder()` before and after; `masterCost == highestBid / 1e15` for every close.
   - Custody:
     - The motifs are burned: `ownerOf` reverts, `burned(id)` is true, `motifsBurned` rises by n.
     - Pulls only from `msg.sender`; reverts on someone else's id even when they approved the Bazaar.
     - Reverts on a missing approval, a duplicate, a burned id, id 0, an id above motifCap, an empty list and 65,536 ids, each with nothing burned.
     - `balanceOf(bazaar)` is unchanged after every call.
     - Works with `approve` and with `setApprovalForAll`.
   - `weave`:
     - The loom is untouched.
     - The PACKED or DENSE choice is exactly `ceil(d/8) < touched`, with forced cases on both sides of it.
     - `handOf` equals the multiset of `motifOf(ids)`; `TooFewMotifs(9)`.
   - Loom:
     - The first deposit below 10 reverts.
     - Later small deposits work and accumulate count, distinct, title, min and max across batches.
     - `weaveLoom([])` and `weaveLoom(ids)` give the same record as folding everything first.
     - The loom is deleted and a new deposit opens a new key; `NoLoom`.
   - Title tie cases: equal counts give the lower number, including a lower motif reaching an untouched higher title's count in a later batch.
   - Ranks: every boundary (9, 10, 29, 30, 99, 100, 299, 300, 999, 1000, top−1, top, top+1) at every close; numbers dense per rank; token ids 1..N with no gaps; `KilimWoven` fields.
   - Tags:
     - The exact winning range tags at any rank; one id outside, or at either edge of the range, does not; `won == 0` never tags.
     - A tagged Master needs all `won` ids and `won == top`.
     - Whole at 1,024 drawings; not at 1,023.
   - Recipients:
     - `to` of 0, the Bazaar, motifs, auction or 1/1 reverts `InvalidRecipient` before any burn.
     - A contract without the hook reverts and the loom stays; a re-entering receiver reverts `ReentrancyGuardReentrantCall`.
   - Views: `pieceOf`, `sealState`, `ladder`, `rankFor`, `strayMotifs`, `royaltyInfo`, `contractURI` and `supportsInterface`; an ABI check that no admin-like function exists.
2. **`BazaarSeal.t.sol`.**
   - Skipped in block B and at B+1.
   - The blockhash path at B+2 and B+257 (using `vm.setBlockhash`).
   - The history path at ages 300 and 8,191.
   - Re-arm at age 8,192, then a seal one block after the new sealBlock; a second lapse re-arms again.
   - Without history, re-arm after 256.
   - A history call that fails inside the window skips and never re-arms (etch reverting code there).
   - The seed equals the formula for any caller at any block in the window.
   - Two kilims from one block get different seeds.
   - A batch with junk, unknown and sealed ids seals the rest.
   - Emits `KilimSealed` and `MetadataUpdate`.
3. **`BazaarPage.t.sol`, tokenURI.**
   - The sealed answer equals a Solidity reference built with `abi.encodePacked` and OZ `Base64.encode(HEAD ‖ hex ‖ "'" ‖ S ‖ pad) ‖ TAIL`, byte for byte, on both stores, with pad 0, 1 and 2 (hands chosen so `|S| mod 3` covers all three).
   - The decoded animation_url is HEAD + hex + `'` + S + pad + base64-decode(TAIL).
   - S equals `';window.KILIM_PIECE='` + `pieceOf`.
   - The JSON parses (`vm.parseJson*`), with every field and trait as in section 6.
   - Hostile motif names from a mock-motifs fixture still give valid JSON with no raw `#` or `%`.
   - Unsealed: no animation_url, Seed "Sealing", the SVG image.
   - `imageBase` set: a sealed kilim's image is `<base><id>`, an unsealed one keeps the SVG.
   - Unminted ids revert.
   - The source never calls `tokenURI` internally (a static grep test).
4. **`BazaarDifferential.t.sol`, ffi profile (`pnpm -s test:render-ffi` style).**
   - `node ../onchain/test/bazaar_ref.mjs` runs the page's own `readPiece`, `rankFor` and `weave` on fuzzed (hand, seed, top). It must agree with the contract on rank, count, title, distinct and seed text.
   - `python3 ../onchain/kilim_ref.py`: a new reference, `kilim_animation_url(head, tail, grids, piece)` built on `pack_page.padding` and base64. It must give the contract's animation_url sha256 on the real store.
5. **`review/BazaarAttackSurface.t.sol`.**
   - Reentrant receivers into each write.
   - Strays by safe and plain transfer; a claim to the Bazaar reverts with credits unchanged; a plain stray can never be deposited.
   - Front-run sale of a motif reverts only that call.
   - Approved-operator abuse fails.
   - Seed re-roll attempts: no re-arm before the window passes; after a third party seals, no later re-arm.
6. **`BazaarInvariants.t.sol`, handler-based, `fail_on_revert`.** Actors weave, deposit, weaveLoom, seal, roll blocks, transfer kilims and send strays. Invariants:
   - Σ lanes over open looms and kilims == burns made by the Bazaar.
   - Each hand's lanes sum to its count, and its nonzero lanes equal distinct.
   - The title is the maximum count with the lowest number among equals.
   - `motifs.balanceOf(bazaar) ==` strays sent.
   - Every loom has at least 10.
   - Every rank equals `_rankFor(count, top)`.
   - Per-rank numbers run 1..woven and token ids run 1..totalSupply.
   - A woven record never changes except seed, the SEALED flag and sealBlock on re-arm; a sealed record never changes.
7. **`BazaarGas.t.sol`, Cancun.** Ceilings:
   - `weave` 10 < 0.5M; `weave` 300 with every bucket fresh < 15M.
   - `deposit` 300 fresh into a new loom < 15M; 600 started-bucket ids < 16M; 760 consecutive < 16M.
   - `weaveLoom` < 150k; one seal < 40k; a seal of 500 < 16.7M.
   - tokenURI < 8M for 1,024 drawings × 65,535 with title 504 and the longest name.
   - Deployment < 8M; runtime ≤ 24,576 bytes.

   It also logs per-motif slopes and Glamsterdam projections (zero→nonzero writes counted with `vm.startStateDiffRecording`, × 97,920). The published table is rebuilt from these logs plus the Sepolia receipts.
8. **`DeployKilimBazaar.t.sol`.** Every refusal of the script (section 9), plus a fork rehearsal against Sepolia (`--fork-url`): deploy, impersonate holders, weave, `vm.setBlockhash`, seal, compare the animation_url with the reference.
9. **Static and process.**
   - Slither (`pnpm -s audit:static`) with no medium or high finding; `slither-check-erc` for ERC-721; `forge fmt`; `FOUNDRY_PROFILE=ci`.
   - A mutation campaign aimed at `_rankFor`, the title condition, the winning-range clause, `block.number <= sb`, `age > seedWindow`, the PACKED choice and the pad arithmetic.
   - `site/test/contract-static.test.mjs`: add `KilimBazaar.sol` to its fixed file list, and allow only its code reads (`chunk` sizes in `_checkSplicePoint`, `HISTORY.codehash`).
   - pack_page.py gets a `KILIM_PIECE` declared/assigned refusal like `GRIDS_DECLARED`, so the mainnet artwork can never shadow the piece.

**Node and Chrome: `onchain/test/kilim-page.test.mjs`** (`pnpm -s test:kilim-page`, run like page.test.mjs):
1. Load the store with page.test.mjs's `loadStore()`: `build-page` and `build-motifs/grids.bin`, else the packed fixture.
2. Build pieces covering:
   - Apprentice 10 and Journeyman 30 at top 1000;
   - Weaver 100 at top 10000;
   - Master 17 at top 17;
   - a Whole Master of 1,024 drawings at top 1000;
   - pad 0, 1 and 2;
   - a hand with a tie for the title.

   Each piece has a seed such as `"0x0badf00d"`.
3. `assembleKilim({head, tail, grids, S})` returns the animation_url as in section 6.
4. Assert:
   - its sha256 equals `python3 onchain/kilim_ref.py` for the same inputs;
   - it equals the contract's output when `KILIM_BAZAAR_URI_DIR` points at the files `BazaarPage.t.sol` writes (`vm.writeFile`; add a write `fs_permission` for `../onchain/build-kilim`);
   - it is under 2 MiB.
5. Open it in headless Chrome (`chrome.mjs openPage`, the same SwiftShader flags, `record: true`), wait for `#art[data-renderer]`, and require:
   - `typeof KILIM_PIECE === 'object'` in the artwork document;
   - `KILIM_GRIDS` is 65,536 lowercase hex characters, equal to the store's grids;
   - `document.documentElement.dataset.motifs === 'chain'`;
   - `JSON.parse(art.dataset.piece)` gives rank (the page's name, "The Master" for 6), count, `seed === seedText`, title, distinct and cost equal to the expected contract record;
   - `art.dataset.interactive === 'false'`;
   - `document.title === "<Rank without 'The '> · <title name> · <count> motifs"`;
   - no uncaught errors, no `console.error`, and no request other than `data:`.
6. When the store's artwork does not mention `KILIM_PIECE` (the synthetic fixture), skip the piece assertions with a message.
7. **By hand, once:** open the same file in Firefox and Safari and confirm `window.KILIM_PIECE` survives `document.open()`.

## 9) Sepolia deploy plan (a throwaway wallet, no admin)

1. **Build gate.** All suites green, plus `pnpm -s test:kilim-page` against the real `build-page`, whose `tailHash` 0x25b853dc…b794 equals the Sepolia 1/1's. Runtime is at or under 24,576 bytes.
2. **Deploy script.** `contracts/script/DeployKilimBazaar.s.sol` reads a `bazaar` block in `deploy/sepolia.json`:
   ```json
   "bazaar": {"auction":"0xf8301C81906512090f663bA474B59Cc186BD2e66","royaltyReceiver":"0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac",
              "pageTailHash":"0x25b853dcdb5725d48dae54b6d7822e46d508e7f8de896693e7deaebe8228b794",
              "description":"<decision 3>","externalUrl":"<decision 3>","imageBase":""}
   ```
   It refuses when:
   - the chain id is wrong;
   - the auction has no code;
   - the trio is broken;
   - `pageTailHash` differs from the manifest or from the chain;
   - the decompressed `build-page` ladder and names differ from the contract's constants (checked by a node pre-step, `scripts/check-bazaar-ladder.mjs`);
   - a text is bad;
   - on chain 1, the sender is not orkhanart.eth.

   No setting, no owner and no later transaction is part of it.
3. **Throwaway wallet.** A new key that has never signed on mainnet, funded with about 0.2 SepoliaETH (check `eth_gasPrice`; the deploy is about 35M gas). The deployer gets no role: the contract has none to give.
4. **Timing.** The code allows deployment any time after the auction exists. The rehearsal deploys as soon as the build is ready, and may do so before the auction closes (21:08:48 UTC on 12 October; settle is callable after that by anyone). Before settlement, confirm that `deposit` and `weave` revert `NotSettled`.
5. **Send** from `contracts/`:
   ```sh
   KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DeployKilimBazaar.s.sol \
     --rpc-url "$SEPOLIA_RPC" --broadcast --slow --timeout 600 --skip-simulation --gas-estimate-multiplier 120 \
     --sender <throwaway> --private-key "$THROWAWAY_KEY"
   ```
   Use `--skip-simulation --gas-estimate-multiplier 120` as for the store: forge's Cancun estimate is far short of Glamsterdam's code deposit.
6. **Read back** by eth_call:
   - auction, motifs, oneOfOne, motifPrice (1e15), motifChainId (11155111), royaltyReceiver, `seedWindow == 8191`, the texts;
   - `ladder()` (open false until settled);
   - `supportsInterface` and `contractURI`.
7. **After `settled()` is true:**
   - `masterCost()` returns 17 if no later bid, and `ladder()` returns [10,0,0,0,0,17].
   - **Holder B** (any wallet with 10–16 claimed motifs): `setApprovalForAll`, then `weave(10 ids, B)`. Expect Apprentice 1.
   - **Winner W** (0xE3fA0855…): `claimMotifs(17, W)` for ids 50–66, then `weave(ids 50..66, W)`. Expect "Master 1 · …" with "Woven from the winning bid".
   - **A loom run:** `deposit(10)` then `weaveLoom([], …)` from a third holder, if motifs allow.
   - **A third wallet seals:** `seal([1,2,…])` two blocks later.
8. **Checks after the weaves:**
   - tokenURI by eth_call on two RPCs (publicnode and drpc), each under 8M; `kilim-page.test.mjs` in RPC mode opens the live animation_url and asserts the piece.
   - Strays: a plain-transfer test motif shows in `strayMotifs()`, and a `safeTransferFrom` reverts.
   - The Alchemy Sepolia NFT API shows the kilims; their metadata refreshes after `MetadataUpdate`.
9. **Records** go in `contracts/audit/bazaar-sepolia-<date>.txt`: every receipt's gas (the Glamsterdam truth for the gas table), the addresses and the read-back. Re-measure after EIP-8037 leaves Last Call (1 November). On mainnet the same script runs from orkhanart.eth.

## 10) Decisions for the artist

1. **The picture marketplaces show for a kilim.** You ruled that every token shows its own preview, and for kilims that means their opening frame. No contract can draw that frame. The carpet itself, the `animation_url`, is fully on-chain in every option.
   - (a) The kilim's own opening frame, rendered from its on-chain page by orkhan.art and served from an address fixed in the contract at deployment (`imageBase`). Grids then show carpets. The thumbnails depend on the site: if it goes away they break, and the kilims don't.
   - (b) The title motif's own drawing, on-chain. Nothing to host, but in a grid every kilim looks like a Motif Bazaar motif.
   - (c) A small on-chain card drawn from the hand. This is a new picture; I'd need 1–3 references you like first.

   **Recommendation: (a)**, because it is your ruling. Sepolia uses (b), since the code supports both and only the deployment setting differs.
2. **Royalty on kilims.**
   - (a) 5% to orkhanart.eth, as on Motif Bazaar and The Unwoven Kilim.
   - (b) Another rate or address.
   - (c) None.

   **Recommendation: (a).**
3. **The collection's description and link**, fixed forever. They may not contain `#`, `%`, `"` or `\`.
   - (a) "Kilims woven from burned motifs by the engine of The Unwoven Kilim. Each is fixed by its seed and drawn only in the motifs that went into it.", with the link base https://orkhan.art/kilim/bazaar/ (each kilim links to …/<its number>).
   - (b) Your own words.

   **Recommendation: (a)** unless you want to write it.
4. **"Journeyman".** The six rank names are written into the contract and must match the stored page. Sepolia's page says Journeyman.
   - (a) Keep it.
   - (b) Rename it before the mainnet page is packed; the contract follows.

   **Recommendation: (a).**
5. **When weaving opens on mainnet.**
   - (a) Deploy the Bazaar before the auction starts and publish it with the others. Weaving then opens by itself the moment anyone settles the auction.
   - (b) Deploy right after settlement, at a time you announce.

   **Recommendation: (a)**: no step on settlement day, and nothing can be woven before the price is final anyway.

## Deviations

Recorded 11 October 2026 when the contract was built (`src/KilimBazaar.sol`, runtime 23,416 bytes), and updated the same day after three reviewers attacked the build (17 to 19, and changes to 3, 4, 11 to 13 and 16). Everything not listed here is as specified above.

**From the artist's decisions of 11 October** (these override sections 2, 6 and 10):
1. **Royalty 7.5%.** `ROYALTY_BPS = 750`; `royaltyInfo` pays `salePrice * 750 / 10_000` to `royaltyReceiver` (orkhanart.eth on mainnet) and `contractURI` says `"seller_fee_basis_points":750`.
2. **The image** is decision 1 (a) as written in section 6: a sealed kilim with a non-empty `imageBase` shows `<imageBase><tokenId>`, its opening frame; `""` (and every unsealed kilim) shows the title motif's drawing. The deploy script refuses an empty `imageBase` on mainnet.
3. **No "weave" or "woven" in what people read.** The tag's trait is `{"trait_type":"Made from the winning bid","value":"Yes"}`, not "Woven from the winning bid". The description used everywhere is the artist's: "Kilims made from burned motifs by the engine of The Unwoven Kilim. Each is fixed by its seed and drawn only in the motifs that went into it." The deploy script refuses the words in all three texts in any case and inside other words: "weav" anywhere, and "woven" anywhere but in "unwoven" (so the 1/1's name, "The Unwoven Kilim", passes, and "WOVEN", "hand-woven" and `https://…/woven/` do not). Function, event and view names keep the spec's (`weave`, `weaveLoom`, `KilimWoven`, `wovenAt`).
4. **Rank names in one place.** They are written once, in the new public pure view `rankName(uint256 rank)` (1 Apprentice … 6 "The Master", `""` otherwise); token names drop a leading "The " from it ("Master 3"). Renaming Journeyman is that one line, plus the page and the deploy config's `pageRanks` (12). The fixed costs are written once, in `_cost`. The forge tests take every name from `rankName` and the costs from `ladder()`; the only pins to the stored page are kilim-page.test.mjs and the deploy check (12).
5. **Mainnet deploys with the auction** (decision 5 (a)): nothing in the contract or the script requires settlement; the script prints whether the auction is settled.

**Small choices the spec left open or that the build needed:**
6. `deposit` checks `auction.settled()` itself instead of calling `_terms()`: the same `NotSettled`, two reads fewer.
7. `handOf` reverts `UnknownKilim` for a token that does not exist; `wovenAt(rank)` returns 0 outside 1..6.
8. The KILIM_PIECE buffer is `192 + 13·distinct` bytes, not 160: with any uint256 `top` (not only the real auction's, at most 24 digits) every write, including the whole word stored for each fixed piece of text, stays inside the allocation. The bytes written are the same.
9. The auction's three values travel in an internal `Terms` struct (stack depth without via-IR). Storage, ABI and behaviour are unchanged; the storage layout is as section 2 (`_kilims` slot 11, `_hands` slot 12).

**Tests** (141 in 7 files, all green; the full forge suite is 411; `kilim-page.test.mjs` 22, of which one skips until a deploy config names `pageRanks`):
10. The files are `test/KilimBazaar.t.sol` (behaviour), `KilimBazaarSeal.t.sol`, `KilimBazaarPage.t.sol`, `KilimBazaarGas.t.sol`, `KilimBazaarAttack.t.sol` (the spec's `review/BazaarAttackSurface.t.sol`), `KilimBazaarInvariants.t.sol` and `KilimBazaarDeploy.t.sol`, with the fixture in `test/bazaar/BazaarBase.sol`.
11. **The page hand-off to node.** `foundry.toml` grants no write permission and was not changed, so instead of `vm.writeFile` three forge tests log `KILIM_RANKS`, `KILIM_FIXTURE <json>` and `KILIM_URI <tokenURI>` for nine real kilims on the real stores: `testRealStoreKilimPages` at a 0.3 ETH close (Apprentice, Journeyman, Weaver from a loom, the winner's tagged Master 300, a Whole Master of 8,807 burns), `testRealStoreKilimPagesAtTheSepoliaClose` at 0.017 ETH (ladder [10, 0, 0, 0, 0, 17]: an Apprentice whose ten motifs tie for the title, and the winner's tagged Master 17) and `testRealStoreKilimPagesAtTenEther` (Weaver 100, Artisan 301 at top 10,000). `onchain/test/kilim-page.test.mjs` runs them with `forge test --json -vv` and reads every `testRealStoreKilimPages*` result (or a saved copy named by `$KILIM_BAZAAR_LOGS`). It checks every byte of each page against `build-page` and `build-motifs`, asserts that paddings 0, 1 and 2 all occur and that the three closes are there, then opens each page in headless Chrome: `window.KILIM_PIECE` survives `document.open()` and the artwork draws that kilim (rank, cost, count, seed, title, distinct, title text, not interactive, no uncaught error, no network). `console.error` is recorded from the DevTools protocol (`Runtime.consoleAPICalled`) from before the page loads, not by a hook installed after the loader's load event, which could miss what the artwork logs while it boots; a probe logged at the end proves the recorder works. Section 8's Apprentice, Journeyman and Whole Master "at top 1000" are made at top 300 instead; the rank rule is the same at both.
12. **The ladder and names check of section 9** has three links, and no separate `scripts/check-bazaar-ladder.mjs`. The page's artwork is gzipped inside TAIL and forge's file permission covers only `../onchain` and `./deploy`, so forge cannot read the RANKS itself. (a) The deploy config names the stored page's ranks: `.bazaar.pageRanks = {"names": [six, exactly as RANKS has them], "costs": [the five fixed costs]}`. `DeployKilimBazaar` refuses a block that is not six names and five costs, refuses a missing one on mainnet and Sepolia, and after the dry run (and again after the broadcast) refuses names other than `rankName(1..6)` or costs other than `ladder()`'s; once the auction is settled `ladder()` hides the ranks the Master undercuts, and the page drops the same ones, so for those it requires a page cost of at least `top`. (b) `kilim-page.test.mjs` compares every deploy config's `pageRanks` (`contracts/deploy/*.json`, or `$KILIM_DEPLOY_CONFIGS`) with the RANKS of the artwork in that config's page store. (c) It also compares the contract's own names and costs (logged from `rankName` and from `ladder()` read before settlement, not from a test literal) with the stored RANKS, and checks the rank each real page draws. A rename on one side only fails (a) or (b)/(c). The static check is in the same file (forge cannot read `src/`): `tokenURI(` occurs only in its declaration, and `_respondWithPage(`, which holds the assembly `return`, occurs exactly twice, its declaration and one call that is the last statement of `tokenURI`.
13. Not built yet, to do before the Sepolia build gate (section 9.1): `BazaarDifferential.t.sol` (ffi: the page's `readPiece`, `rankFor` and `weave` against the contract on fuzzed hand, seed and top; `kilim_ref.py`'s independent animation_url sha256); a `forge script` run of `DeployKilimBazaar` against a local fork (it has run only inside forge tests, with `snapshotState` and `startBroadcast` as cheatcodes); the Sepolia fork rehearsal; the Glamsterdam state-diff projections in the gas test; the `pack_page.py` KILIM_PIECE refusal; Slither and the mutation campaign; the RPC mode of `kilim-page.test.mjs` (section 9.8: until it exists, read the live `tokenURI` with `cast call` and compare it by hand, or extend the node test); and the by-hand check in Firefox and Safari (section 8, node item 7, plus an iOS WKWebView as wallets use) that `window.KILIM_PIECE` survives `document.open()`, which has not been done. One mutation was run by hand: deleting `_fold`'s `if (c > 0xffff) revert CountOverflow();` left every other test green, so `testALoomCountNeverSpillsIntoTheNextMotifsLane` now forces a lane to 0xffff in storage and expects `CountOverflow` through `deposit` and `weaveLoom`, and checks 0xfffe + 1 fits with the next lane untouched.
14. **Gas ceiling for an Apprentice.** `weave` 10 < 0.5M holds for market or consecutive ids (486,268 measured); ten ids that each open a fresh `_burned` bucket cost 675,984, so that case has a 0.75M ceiling.

**Measured (Cancun, everything the call touches cold, gross, with the intrinsic cost; the re-arm now has a 40k ceiling too):** `weave` 10 / 30 / 100 / 300 / 1,000 consecutive ids: 486,268 / 890,423 / 2,492,456 / 6,678,816 / 19,936,006; `weave` 300 with every bucket fresh 13,249,067; `deposit` 300 fresh opening a loom 13,789,159, into an open loom 12,629,080; 600 started-bucket ids 15,581,132; 760 consecutive 15,722,629; `weaveLoom([])` about 120,000; a Master of 10,000 in 35 transactions 204,763,419 (20,476 a motif); one `seal` 33,118 (history path 35,982, re-arm 31,547), 500 in one call 5,336,885; deployment 5,515,459. tokenURI on the real store: Apprentice 4,290,193, Weaver 4,538,948, Master 300 4,679,374, Whole Master 6,415,297; at the 0.017 ETH close Apprentice 4,290,112 and Master 17 4,230,792; at 10 ETH Weaver 4,530,324 and Artisan 301 4,797,654; and the bound (1,024 drawings × 65,535, title 504) 7,607,091, all under 8M; the largest animation_url is 936,982 characters.

**Outside the files this build could touch:**
15. `site/test/contract-static.test.mjs` now fails three checks because `src/` has a fifth source: its fixed file list needs `KilimBazaar.sol`; its vocabulary rule `\bweav(e|ing)\b` matches the function name `weave`; and `site/chain.js` `explain()` needs plain messages for `TooFewMotifs`, `NoLoom`, `CountOverflow`, `UnknownKilim`, `NotSealed` and `StrayTransfer`.
16. `deploy/sepolia.json` and `deploy/mainnet.json` have no `bazaar` block yet. `script/DeployKilimBazaar.s.sol` reads `.bazaar.{auction, royaltyReceiver, pageTailHash, description, externalUrl, imageBase, pageRanks}` (optional `.bazaar.motifs`, `.bazaar.oneOfOne`, `.bazaar.pageStore`, else the top-level `pageStore`); `pageRanks` is `{"names": ["Apprentice", "Journeyman", "Weaver", "Artisan", "Dyer", "The Master"], "costs": [10, 30, 100, 300, 1000]}` for today's page and is required on mainnet and Sepolia; `$KILIM_BAZAAR_AUCTION` may name the auction instead, and must agree when both do.
    Also outside these files: `contracts/package.json` has no `test:kilim-page` script and its `test` and `test:ci` do not run `kilim-page.test.mjs` (sections 8 and 9.1 name `pnpm -s test:kilim-page`); `launch/KILIM-BAZAAR-RULES.md` still says "Woven from the winning bid" (rule 6, line 43; the trait is "Made from the winning bid", and the site bundle shows the old words), about 200 ids per transaction (line 78), a 256-block window (line 81; it is 8,191) and a `<script>KILIM_PIECE=…</script>` before the artwork's script (line 86; it is `;window.KILIM_PIECE={…}` inside the loader, which relies on `document.open()` keeping the Window). On the artwork side (the mainnet page is packed later; the Sepolia page is pinned by `tailHash`): a click on a kilim drawn with the camera study "Dye vat" (studies/wool.js `vat`, in the Dyer and Master pools) starts the camera, because app.js:246 does not check piece mode, and the study then follows the room, so the kilim is no longer fixed by its seed and answers the viewer (rules 7 and 8); and the Echo pattern morphs the title into the outline of a partner motif chosen from all 1,024 (echo.js:29), burned or not, which is the artist's call.

**From the review round (11 October):**
17. **Withholding the seal is a re-roll once nobody seals for 8,191 blocks.** Section 4 accepts withholding because the site's sealer seals every kilim within a block or two. That sealer is `kilim-sealer/`, added on 12 October 2026 after audit finding SL-1 showed there was none. The contract is permanent and has no admin; the sealer is not. If nobody seals a kilim within 8,191 blocks of its seal block, the next `seal` re-arms it to a fresh block, and its owner, who could compute the first seed from block B+2 on and run the page offline, has in effect drawn again: about 27 hours and one seal per draw, as many times as they like. The same owner can also sell an unsealed kilim whose look they know while marketplaces show "Sealing" (anyone, a buyer included, can compute that seed or call `seal` first). This cannot be closed on-chain: once a block hash is older than 8,191 blocks nothing on-chain can read it, so after a lapse any seed is either a fresh draw or a value known in advance. Two on-chain mitigations were weighed and not built. Sealing in `_update` on every transfer seals only after the sale is agreed, so it protects no buyer and stops no re-roll. A cursor that every `weave`, `deposit` and `weaveLoom` advances to seal older kilims costs each of them about 9,000 gas more for good (an Apprentice is 486,268 against the 0.5M ceiling), and an owner defeats it by making a burst of kilims just before theirs when activity is low, which is exactly when a sealer is likely to be gone. What holds rule 7 is the sealer: it must run for as long as kilims can be made (`checklists/0-launch-steps.md` step 12 and `2-deploy.md` start it before making opens, fund it and watch it), and the rules and the site should say plainly that a kilim nobody seals within about 27 hours re-arms. If the artist would rather pay the gas for the partial on-chain guard, the cursor fits in the runtime headroom (1,160 bytes).
18. **The two URL bases are permanent.** `imageBase` and `externalUrl` get the token id appended as they are (`<base><tokenId>`), and nothing can change them. The deploy script refuses a non-empty one that does not start with `https://`, `ipfs://` or `ar://`, carries a space, or does not end in `/` or `=` (so `…/frames` without its slash cannot make every image `…/frames12`), and prints kilim 1's image and link to open before broadcasting. Decision 1 (a) also makes the domain part of every sealed kilim's marketplace picture for as long as the contract exists: if orkhan.art lapsed and someone else registered it, they could serve any picture as every kilim's `image` (the on-chain `animation_url` is unaffected). Keeping the domain renewed, or pinning the frames on IPFS or Arweave and deploying with that base, is part of the launch's upkeep.
19. **Uint32 casts.** Only `_fold`'s running count uses SafeCast. The other casts are plain because each value is bounded where it is made: `uint32(ids.length)` in `weave` (at most MAX_BATCH, checked by `_take` before the cast); `uint32(b.minId)` and `uint32(b.maxId)` in `weave` and `_fold` (ids that just passed `transferFrom`, so at most `motifCap`, which KilimMotifs.sol:69 keeps within uint32); `uint32(_newHandKey())` and `uint32(number)` (read through a `0xffffffff` mask from the tally, whose lanes cannot carry: every hand key and every kilim takes at least 10 burned motifs, so there are at most motifCap / 10 of each); and the seed's `uint32(…)`, which is the intended low 32 bits (section 4). A SafeCast on a masked value could never fire; the tally bound is what keeps the lanes exact.

### Deviation: names (11 October 2026, before any deployment)

The project dropped weaving words in code as well as copy (site/test/contract-static.test.mjs, "the public vocabulary is motifs"). The functions, event and view are therefore renamed: `weave` → `make`, `weaveLoom` → `makeFromLoom`, `KilimWoven` → `KilimMade`, `wovenAt` → `madeAt`, and internally `_weave` → `_make`. Behaviour, storage and gas are unchanged; the runtime is still 23,416 bytes. Read this spec's `weave` as `make` throughout. The rank "Weaver" and "The Unwoven Kilim" are names and stay.
