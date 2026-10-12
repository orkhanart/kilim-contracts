// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {KilimAuction} from "./KilimAuction.sol";
import {KilimMotifs} from "./KilimMotifs.sol";
import {KilimOneOfOne} from "./KilimOneOfOne.sol";

/// @notice Kilim Bazaar: burn your own motifs into a kilim. How many go into one kilim is its rank: five
///         fixed costs, 10, 30, 100, 300 and 1,000, and the Master at the auction's winning bid counted in
///         motifs (the names are `rankName`'s). Up to about 300 motifs go in one call (`make`);
///         more go into your loom in batches (`deposit`) and are closed with `makeFromLoom`. Every id is
///         taken from your wallet and burned in the same call. The seed is sealed later, by anyone,
///         from the hash of the block after the one the kilim was made in. The kilim's page is the
///         1/1's own stored page, handed this kilim's piece: it draws exactly that kilim.
/// @dev No owner, setter, pause, upgrade or ETH. Every write opens when the auction is settled: the
///      Master's price and the winning bid's ids are final then. Build spec: docs/KILIM-BAZAAR-SPEC.md.
///      tokenURI ends the call with an assembly `return`, so it MUST NEVER BE CALLED INTERNALLY.
contract KilimBazaar is IERC4906, ERC721, ReentrancyGuardTransient {
    using Strings for uint256;

    /// @notice An open loom: one per wallet, keyed by the wallet. One slot. handKey 0 = no loom.
    struct Loom {
        uint32 handKey;
        uint32 count;
        uint32 minId;
        uint32 maxId;
        uint16 title;
        uint16 titleCount;
        uint16 distinct;
    }

    /// @notice A kilim's record. One slot. rank 0 = no kilim. `seed` is meaningful once flags has SEALED.
    struct Kilim {
        uint32 handKey;
        uint32 count;
        uint32 number;
        uint16 title;
        uint16 distinct;
        uint8 rank;
        uint8 flags;
        uint40 sealBlock;
        uint32 seed;
    }

    /// @dev The auction's final terms: the Master's cost, and the winning bid's `won` ids from `first`.
    struct Terms {
        uint256 top;
        uint256 first;
        uint256 won;
    }

    /// @dev One batch of burned ids counted in memory: 16-bit lanes, motif n at lane n - 1.
    struct Batch {
        uint256[64] add;
        uint256 touched;
        uint256 minId;
        uint256 maxId;
    }

    /// @notice The least a kilim holds: one opening bid's worth.
    uint256 public constant FLOOR = 10;
    uint256 public constant MOTIF_COUNT = 1024;
    /// @notice Ids per call. Keeps the 16-bit counts in memory carry-free; gas limits batches far below it.
    uint256 public constant MAX_BATCH = 65_535;
    /// @notice Ranks run 1..6 in cost order, named by `rankName`; 6 is the Master; 0 = none.
    uint8 public constant MASTER = 6;
    /// @notice Resale royalty, 7.5%, fixed forever. Marketplaces may ignore royalties entirely.
    uint96 public constant ROYALTY_BPS = 750;
    /// @notice The EIP-2935 block-hash history contract, and its code hash on mainnet and Sepolia.
    address public constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    bytes32 public constant HISTORY_CODEHASH =
        0x6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d;
    /// @notice Kilim.flags bits.
    uint8 public constant SEALED = 1;
    uint8 public constant WHOLE = 2;
    uint8 public constant WINNING_BID = 4;
    uint8 public constant PACKED = 8;
    /// @dev 1,024 grids of 32 bytes, and the hex characters they expand to, as in KilimOneOfOne.
    uint256 private constant GRID_BYTES = 32_768;
    uint256 private constant HEX_CHARS = 65_536;

    KilimAuction public immutable auction;
    KilimMotifs public immutable motifs;
    KilimOneOfOne public immutable oneOfOne;
    /// @notice The auction's bid unit, 0.001 ETH: the winning bid divided by it is the Master's cost.
    uint256 public immutable motifPrice;
    /// @notice The chain id the motif collection recorded at deployment; its motif formula uses it.
    uint256 public immutable motifChainId;
    address public immutable royaltyReceiver;
    /// @notice Blocks after its seal block in which a kilim's seed can be sealed: 8,191 where the
    ///         EIP-2935 history contract was found at deployment, else 256. After that it re-arms.
    uint256 public immutable seedWindow;

    /// @notice Written once, in the constructor. Printable ASCII without `"`, `\`, `#` or `%`.
    string public description;
    /// @notice Written once. When non-empty each kilim links to externalUrl + its token id.
    string public externalUrl;
    /// @notice Written once. When non-empty a sealed kilim's image is imageBase + its token id (the
    ///         kilim's opening frame, rendered off-chain from its on-chain page); otherwise, and always
    ///         before the seal, the image is the title motif's drawing, on-chain.
    string public imageBase;

    /// @dev Eight uint32 lanes: lanes 0..5 = kilims made at rank 1..6, lane 6 = hand keys issued,
    ///      lane 7 = kilims made = the last token id. No lane can carry: there are at most motifCap / 10
    ///      kilims and hand keys, and motifCap fits uint32.
    uint256 private _tally;
    mapping(address => Loom) private _looms;
    mapping(uint256 => Kilim) private _kilims;
    /// @dev Hand key => counts. DENSE: motif n's count is (word[(n-1)>>4] >> (((n-1)&15)<<4)) & 0xffff.
    ///      PACKED (flag PACKED, one-call kilims only): entry i at bits 32*(i%8) of word i/8 holds
    ///      (motif << 16) | count, `distinct` entries in ascending motif order.
    mapping(uint256 => uint256[64]) private _hands;

    error InvalidConfiguration();
    error NotSettled();
    error InvalidQuantity();
    error TooFewMotifs(uint256 count);
    error NoLoom();
    error CountOverflow();
    error InvalidRecipient();
    error UnknownKilim(uint256 tokenId);
    error NotSealed(uint256 tokenId);
    error GridsUnavailable();
    error StrayTransfer();

    event MotifsLoomed(address indexed weaver, uint256 indexed loom, uint256 quantity, uint256 count);
    event KilimMade(
        uint256 indexed tokenId,
        address indexed weaver,
        address indexed to,
        uint256 rank,
        uint256 number,
        uint256 count,
        uint256 title,
        uint256 sealBlock
    );
    event SeedRearmed(uint256 indexed tokenId, uint256 sealBlock);
    event KilimSealed(uint256 indexed tokenId, bytes32 blockHash, uint256 seed);

    /// @param pageTailHash_ The 1/1's TAIL hash this deployment was checked against: pins the stored page.
    ///        Its RANKS (names and costs) must be this contract's `rankName` and fixed costs: the deploy script
    ///        compares its config's `pageRanks` with this contract, and onchain/test/kilim-page.test.mjs
    ///        compares that config, and this contract's own kilim pages, with the stored artwork.
    constructor(
        KilimAuction auction_,
        address royaltyReceiver_,
        bytes32 pageTailHash_,
        string memory description_,
        string memory externalUrl_,
        string memory imageBase_
    ) ERC721("Kilim Bazaar", "KILIM") {
        if (address(auction_).code.length == 0 || royaltyReceiver_ == address(0)) {
            revert InvalidConfiguration();
        }
        KilimMotifs motifs_ = auction_.motifs();
        KilimOneOfOne oneOfOne_ = auction_.oneOfOne();
        // The same trio the auction's own constructor checked.
        if (
            motifs_.minter() != address(auction_) || oneOfOne_.minter() != address(auction_)
                || address(oneOfOne_.motifs()) != address(motifs_)
        ) revert InvalidConfiguration();
        uint256 price = auction_.MOTIF_PRICE();
        if (price == 0) revert InvalidConfiguration();
        // Each motif is computed here, not asked for: the formula must be the collection's.
        uint256 chain = motifs_.deploymentChainId();
        uint256 cap = motifs_.motifCap();
        if (
            _lane(chain, address(motifs_), 1) + 1 != motifs_.motifOf(1)
                || _lane(chain, address(motifs_), cap) + 1 != motifs_.motifOf(cap)
        ) revert InvalidConfiguration();
        if (oneOfOne_.tailHash() != pageTailHash_) revert InvalidConfiguration();
        _checkSplicePoint(oneOfOne_);
        _checkText(description_);
        _checkText(externalUrl_);
        _checkText(imageBase_);
        auction = auction_;
        motifs = motifs_;
        oneOfOne = oneOfOne_;
        motifPrice = price;
        motifChainId = chain;
        royaltyReceiver = royaltyReceiver_;
        seedWindow = HISTORY.codehash == HISTORY_CODEHASH ? 8191 : 256;
        description = description_;
        externalUrl = externalUrl_;
        imageBase = imageBase_;
    }

    // ------------------------------------------------------------ making kilims

    /// @notice One kilim from exactly these motifs (at least 10), minted to `to`. Each id is taken from
    ///         your wallet and burned in this call; approve this contract on Motif Bazaar first. Your loom
    ///         is never touched. Up to about 300 ids fit one transaction.
    function make(uint256[] calldata ids, address to) external nonReentrant returns (uint256 tokenId) {
        _checkRecipient(to);
        Terms memory terms = _terms();
        if (ids.length < FLOOR) revert TooFewMotifs(ids.length);
        Batch memory b = _take(ids);
        (uint256 distinct, uint256 title, uint256 words) = _summary(b);
        Loom memory l;
        l.handKey = uint32(_newHandKey());
        l.count = uint32(ids.length); // <= MAX_BATCH
        l.minId = uint32(b.minId); // ids are at most motifCap, which fits uint32
        l.maxId = uint32(b.maxId);
        l.title = uint16(title); // <= 1,024
        l.distinct = uint16(distinct); // <= 1,024
        tokenId = _make(to, l, _record(l.handKey, b, distinct, words), terms);
    }

    /// @notice Put motifs into your loom, opening it if you have none: the first deposit carries at least
    ///         10. Each id is taken from your wallet and burned in this call. Returns the loom's key.
    function deposit(uint256[] calldata ids) external nonReentrant returns (uint256 loom) {
        if (!auction.settled()) revert NotSettled();
        Loom memory l = _looms[msg.sender];
        if (l.handKey == 0) {
            // So a loom always holds at least 10 and can always be closed into a kilim.
            if (ids.length < FLOOR) revert TooFewMotifs(ids.length);
            l.handKey = uint32(_newHandKey());
            l.minId = type(uint32).max;
        }
        _fold(l, _take(ids), ids.length);
        _looms[msg.sender] = l;
        emit MotifsLoomed(msg.sender, l.handKey, ids.length, l.count);
        return l.handKey;
    }

    /// @notice Close your loom into one kilim, minted to `to`, after putting `ids` in (may be empty).
    function makeFromLoom(uint256[] calldata ids, address to) external nonReentrant returns (uint256 tokenId) {
        _checkRecipient(to);
        Terms memory terms = _terms();
        Loom memory l = _looms[msg.sender];
        if (l.handKey == 0) revert NoLoom();
        if (ids.length != 0) _fold(l, _take(ids), ids.length);
        // The snapshot: only an open loom's key is ever written, so this hand is final.
        delete _looms[msg.sender];
        tokenId = _make(to, l, 0, terms);
    }

    /// @notice Seal the seeds of these kilims. Anyone may call it; it never reverts on a bad entry. A kilim
    ///         made in block B is sealed from block B+2 on, from the hash of block B+1. If nobody seals it
    ///         within `seedWindow` blocks of that, this re-arms it to the next block instead.
    function seal(uint256[] calldata tokenIds) external nonReentrant returns (uint256 sealedCount) {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            Kilim memory k = _kilimOf(id);
            if (k.rank == 0 || k.flags & SEALED != 0) continue;
            uint256 sb = k.sealBlock;
            if (block.number <= sb) continue;
            uint256 age = block.number - sb;
            if (age > seedWindow) {
                // Decided from block numbers alone: a lookup that fails inside the window only skips.
                k.sealBlock = uint40(block.number + 1);
                emit SeedRearmed(id, block.number + 1);
            } else {
                bytes32 h;
                if (age <= 256) {
                    h = blockhash(sb);
                } else {
                    // Only reachable with the history contract (seedWindow 8,191). A staticcall.
                    (bool ok, bytes memory r) = HISTORY.staticcall(abi.encode(sb));
                    if (ok && r.length == 32) h = abi.decode(r, (bytes32));
                }
                if (h == 0) continue;
                uint32 seed = uint32(uint256(keccak256(abi.encode(h, address(this), id))));
                k.seed = seed;
                k.flags |= SEALED;
                emit KilimSealed(id, h, seed);
                emit MetadataUpdate(id);
                ++sealedCount;
            }
            _kilims[id] = k;
        }
    }

    // ------------------------------------------------------------ reading

    /// @notice The Master's cost in motifs: the winning bid divided by the bid unit. Final at settlement.
    function masterCost() public view returns (uint256) {
        return _top();
    }

    /// @notice The five fixed costs, each 0 where the Master undercuts it, then the Master's cost.
    ///         Before settlement: [10, 30, 100, 300, 1000, 0] and open = false.
    function ladder() external view returns (uint256[6] memory costs, bool open) {
        open = auction.settled();
        uint256 top = open ? auction.highestBid() / motifPrice : type(uint256).max;
        for (uint256 r = 1; r < MASTER; ++r) {
            uint256 c = _cost(r);
            costs[r - 1] = c < top ? c : 0;
        }
        costs[5] = open ? top : 0;
    }

    /// @notice The rank `count` motifs make: 0 under the floor. Reverts before settlement.
    function rankFor(uint256 count) external view returns (uint8) {
        return _rankFor(count, _top());
    }

    /// @notice The six rank names, exactly as the stored page has them (its RANKS): the one place they are
    ///         written, so a rename is one line here (and the page). Token names drop a leading "The ".
    ///         "" for any other rank.
    function rankName(uint256 rank) public pure returns (string memory) {
        if (rank == 1) return "Apprentice";
        if (rank == 2) return "Journeyman";
        if (rank == 3) return "Weaver";
        if (rank == 4) return "Artisan";
        if (rank == 5) return "Dyer";
        if (rank == 6) return "The Master";
        return "";
    }

    function kilim(uint256 tokenId) external view returns (Kilim memory) {
        return _known(tokenId);
    }

    function loomOf(address weaver) external view returns (Loom memory) {
        return _looms[weaver];
    }

    /// @notice The motifs burned into a kilim and how many of each, ascending by motif number.
    function handOf(uint256 tokenId)
        external
        view
        returns (uint256[] memory motifNumbers, uint256[] memory counts)
    {
        Kilim memory k = _known(tokenId);
        return _hand(k.handKey, k.distinct, k.flags & PACKED != 0);
    }

    /// @notice The motifs in a wallet's open loom so far, ascending by motif number. Empty without a loom.
    function loomHandOf(address weaver) external view returns (uint256[] memory, uint256[] memory) {
        Loom memory l = _looms[weaver];
        return _hand(l.handKey, l.distinct, false);
    }

    /// @notice The exact KILIM_PIECE object a sealed kilim's page is handed: {"seed","motifs","top"}, the
    ///         motifs as [number, count] in ascending number order (the page breaks title ties by that order,
    ///         so pass it on unchanged). For the site's `?piece=` simulator.
    function pieceOf(uint256 tokenId) external view returns (string memory piece) {
        Kilim memory k = _known(tokenId);
        if (k.flags & SEALED == 0) revert NotSealed(tokenId);
        bytes memory s = _piece(k, _top());
        // Drop the 20 bytes `;window.KILIM_PIECE=`: the length word moves up over them.
        assembly ("memory-safe") {
            let len := mload(s)
            piece := add(s, 20)
            mstore(piece, sub(len, 20))
        }
    }

    /// @notice 0 no kilim, 1 waiting for its seal block, 2 sealable now, 3 the next seal() re-arms it, 4 sealed.
    function sealState(uint256 tokenId) external view returns (uint8) {
        Kilim memory k = _kilimOf(tokenId);
        if (k.rank == 0) return 0;
        if (k.flags & SEALED != 0) return 4;
        if (block.number <= k.sealBlock) return 1;
        if (block.number - k.sealBlock > seedWindow) return 3;
        return 2;
    }

    /// @notice Kilims made at `rank` (1..6) so far; 0 for any other rank.
    function madeAt(uint8 rank) external view returns (uint256) {
        if (rank == 0 || rank > MASTER) return 0;
        return (_tally >> (32 * (uint256(rank) - 1))) & 0xffffffff;
    }

    /// @notice Kilims made so far; token ids run 1..totalSupply with no gaps.
    function totalSupply() external view returns (uint256) {
        return _tally >> 224;
    }

    /// @notice Motifs sent here by plain transfer. They can never be burned into a kilim, moved or counted.
    function strayMotifs() external view returns (uint256) {
        return motifs.balanceOf(address(this));
    }

    /// @notice `data:application/json;utf8,` {name, description, [external_url], image, [animation_url],
    ///         attributes}. A sealed kilim's animation_url is the 1/1's stored page (its HEAD and TAIL chunks
    ///         copied as they are) with `;window.KILIM_PIECE={...}` right after the grids. Before the seal
    ///         there is no animation_url and the Seed trait reads "Sealing".
    /// @dev The sealed answer ends the call with an assembly `return`: MUST NEVER BE CALLED INTERNALLY.
    function tokenURI(uint256 tokenId) public view override returns (string memory uri) {
        _requireOwned(tokenId);
        Kilim memory k = _kilimOf(tokenId);
        bool isSealed = k.flags & SEALED != 0;
        string memory titleName = _escapeJson(motifs.motifName(k.title));
        bytes memory open = _openJson(tokenId, k, titleName, isSealed);
        bytes memory traits = _traits(k, titleName, isSealed);
        if (!isSealed) return string(bytes.concat(open, traits));
        _respondWithPage(
            bytes.concat(open, '"animation_url":"data:text/html;base64,'),
            _piece(k, _top()),
            bytes.concat('",', traits)
        );
    }

    /// @notice Collection-level metadata for marketplace pages.
    function contractURI() external view returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Kilim Bazaar","description":"',
                        description,
                        '","external_link":"',
                        externalUrl,
                        '","seller_fee_basis_points":',
                        uint256(ROYALTY_BPS).toString(),
                        ',"fee_recipient":"',
                        uint256(uint160(royaltyReceiver)).toHexString(20),
                        '"}'
                    )
                )
            )
        );
    }

    /// @notice ERC-2981. Royalties are advisory: marketplaces decide whether to pay them.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver, (salePrice * ROYALTY_BPS) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == 0x2a55205a || interfaceId == bytes4(0x49064906)
            || super.supportsInterface(interfaceId);
    }

    /// @notice Every safe transfer to the Bazaar bounces, and so does an auction claim sent here.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert StrayTransfer();
    }

    // ------------------------------------------------------------ internals: making

    /// @dev Reverts NotSettled before settlement. After it the values are final: no bid lands once the
    ///      close has passed, settle needs it passed, and only a bid moves the winning range.
    function _terms() private view returns (Terms memory t) {
        t.top = _top();
        (t.first, t.won) = auction.highestBidMotifs();
    }

    /// @dev Exact: bids are whole units, and at least the 10-unit reserve.
    function _top() private view returns (uint256) {
        if (!auction.settled()) revert NotSettled();
        return auction.highestBid() / motifPrice;
    }

    function _checkRecipient(address to) private view {
        if (to == address(0) || _blocked(to)) revert InvalidRecipient();
    }

    /// @dev The four contracts that can never move a kilim.
    function _blocked(address to) private view returns (bool) {
        return
            to == address(this) || to == address(motifs) || to == address(auction) || to == address(oneOfOne);
    }

    function _kilimOf(uint256 tokenId) private view returns (Kilim memory) {
        return _kilims[tokenId];
    }

    function _known(uint256 tokenId) private view returns (Kilim memory k) {
        k = _kilimOf(tokenId);
        if (k.rank == 0) revert UnknownKilim(tokenId);
    }

    function _newHandKey() private returns (uint256) {
        uint256 t = _tally + (1 << 192);
        _tally = t;
        return (t >> 192) & 0xffffffff;
    }

    /// @dev Takes every id from msg.sender (a plain transferFrom: no receiver hook), then burns and counts
    ///      them in memory. All transfers come first so the Bazaar's balance slot is not cleared and
    ///      re-created per motif. A duplicate, burned, unminted, stray or someone else's id reverts at its
    ///      transferFrom. burn is owner-only: the Bazaar owns every id by then.
    function _take(uint256[] calldata ids) private returns (Batch memory b) {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_BATCH) revert InvalidQuantity();
        KilimMotifs m = motifs;
        for (uint256 i; i < n; ++i) {
            m.transferFrom(msg.sender, address(this), ids[i]);
        }
        uint256 chain = motifChainId;
        b.minId = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            m.burn(id);
            // The id passed transferFrom, so it exists and lies in 1..motifCap; motif = lane + 1.
            uint256 lane = _lane(chain, address(m), id);
            unchecked {
                // n <= 65,535, so no 16-bit lane carries.
                b.add[lane >> 4] += 1 << ((lane & 15) << 4);
            }
            b.touched |= 1 << (lane >> 4);
            if (id < b.minId) b.minId = id;
            if (id > b.maxId) b.maxId = id;
        }
    }

    /// @dev KilimMotifs.motifOf less one, hashed at the free memory pointer without moving it.
    function _lane(uint256 chain, address m, uint256 id) private pure returns (uint256 lane) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, chain)
            mstore(add(p, 32), m)
            mstore(add(p, 64), id)
            lane := and(keccak256(p, 96), 1023)
        }
    }

    /// @dev Distinct motifs, the title (most burned, the lowest number among equals: lanes are scanned in
    ///      ascending order and only a strictly higher count replaces it) and the words the batch touched.
    function _summary(Batch memory b) private pure returns (uint256 distinct, uint256 title, uint256 words) {
        uint256 best;
        for (uint256 s; s < 64; ++s) {
            if ((b.touched >> s) & 1 == 0) continue;
            ++words;
            uint256 a = b.add[s];
            for (uint256 j; j < 16; ++j) {
                uint256 c = (a >> (j << 4)) & 0xffff;
                if (c == 0) continue;
                ++distinct;
                if (c > best) {
                    best = c;
                    title = (s << 4) + j + 1;
                }
            }
        }
    }

    /// @dev A one-call kilim's hand: PACKED when it takes fewer words than DENSE, else DENSE.
    ///      Returns the flag to record.
    function _record(uint256 key, Batch memory b, uint256 distinct, uint256 denseWords)
        private
        returns (uint256)
    {
        uint256[64] storage words = _hands[key];
        if ((distinct + 7) >> 3 >= denseWords) {
            for (uint256 s; s < 64; ++s) {
                if ((b.touched >> s) & 1 != 0) words[s] = b.add[s];
            }
            return 0;
        }
        uint256 buf;
        uint256 i;
        for (uint256 s; s < 64; ++s) {
            if ((b.touched >> s) & 1 == 0) continue;
            uint256 a = b.add[s];
            for (uint256 j; j < 16; ++j) {
                uint256 c = (a >> (j << 4)) & 0xffff;
                if (c == 0) continue;
                buf |= (((((s << 4) + j + 1) << 16) | c) << ((i & 7) << 5));
                ++i;
                if (i & 7 == 0) {
                    words[(i >> 3) - 1] = buf;
                    buf = 0;
                }
            }
        }
        if (i & 7 != 0) words[i >> 3] = buf;
        return PACKED;
    }

    /// @dev Adds a batch to an open loom's DENSE hand, once per touched word. Folding is exact because
    ///      counts only rise: the new maximum is the old title (unchanged) or a touched lane, and every
    ///      touched lane is compared, with the lowest number winning ties (the page's rule).
    function _fold(Loom memory l, Batch memory b, uint256 n) private {
        uint256[64] storage words = _hands[l.handKey];
        uint256 title = l.title;
        uint256 best = l.titleCount;
        uint256 distinct = l.distinct;
        for (uint256 s; s < 64; ++s) {
            if ((b.touched >> s) & 1 == 0) continue;
            uint256 w = words[s];
            uint256 a = b.add[s];
            for (uint256 j; j < 16; ++j) {
                uint256 inc = (a >> (j << 4)) & 0xffff;
                if (inc == 0) continue;
                uint256 old = (w >> (j << 4)) & 0xffff;
                uint256 c = old + inc;
                // Unreachable in practice (a motif shows on about 1 id in 1,024), but a count must never
                // spill into the next motif's lane.
                if (c > 0xffff) revert CountOverflow();
                if (old == 0) ++distinct;
                uint256 motif = (s << 4) + j + 1;
                if (c > best || (c == best && motif < title)) {
                    best = c;
                    title = motif;
                }
            }
            // Lane-wise and carry-free: every lane was checked above.
            words[s] = w + a;
        }
        l.title = uint16(title);
        l.titleCount = uint16(best);
        l.distinct = uint16(distinct);
        l.count = SafeCast.toUint32(uint256(l.count) + n);
        if (b.minId < l.minId) l.minId = uint32(b.minId);
        if (b.maxId > l.maxId) l.maxId = uint32(b.maxId);
    }

    /// @dev Records and mints the kilim. Every write comes before _safeMint, the only call that can reach
    ///      code the Bazaar does not know; all four writes are nonReentrant.
    function _make(address to, Loom memory l, uint256 flags, Terms memory terms)
        private
        returns (uint256 tokenId)
    {
        uint256 rank = _rankFor(l.count, terms.top); // >= 1: every hand holds at least 10
        if (l.distinct == MOTIF_COUNT) flags |= WHOLE;
        // Every burned id in [first, first + won): the winner's own motifs.
        if (terms.won != 0 && l.minId >= terms.first && l.maxId - terms.first < terms.won) {
            flags |= WINNING_BID;
        }
        uint256 t = _tally;
        uint256 lane = 32 * (rank - 1);
        tokenId = (t >> 224) + 1;
        uint256 number = ((t >> lane) & 0xffffffff) + 1;
        _tally = t + (1 << 224) + (1 << lane);
        uint256 sealBlock = block.number + 1;
        _kilims[tokenId] = Kilim({
            handKey: l.handKey,
            count: l.count,
            number: uint32(number),
            title: l.title,
            distinct: l.distinct,
            rank: uint8(rank),
            flags: uint8(flags),
            sealBlock: uint40(sealBlock),
            seed: 0
        });
        emit KilimMade(tokenId, msg.sender, to, rank, number, l.count, l.title, sealBlock);
        _safeMint(to, tokenId);
    }

    /// @dev The page's rule (bazaar.js readPiece and rankFor): the Master at or above `top`, otherwise the
    ///      highest fixed cost at or under the count. Ranks the Master undercuts fall away by themselves.
    function _rankFor(uint256 count, uint256 top) private pure returns (uint8) {
        if (count < FLOOR) return 0;
        if (count >= top) return MASTER;
        for (uint256 r = MASTER - 1; r > 1; --r) {
            if (count >= _cost(r)) return uint8(r);
        }
        return 1;
    }

    /// @dev The five fixed costs, as the stored page's RANKS has them.
    function _cost(uint256 rank) private pure returns (uint256) {
        if (rank == 1) return FLOOR;
        if (rank == 2) return 30;
        if (rank == 3) return 100;
        if (rank == 4) return 300;
        return 1000;
    }

    // ------------------------------------------------------------ internals: reading

    /// @dev A hand as two ascending arrays, from either format.
    function _hand(uint256 key, uint256 distinct, bool packed)
        private
        view
        returns (uint256[] memory motifNumbers, uint256[] memory counts)
    {
        motifNumbers = new uint256[](distinct);
        counts = new uint256[](distinct);
        if (distinct == 0) return (motifNumbers, counts);
        uint256[64] storage words = _hands[key];
        if (packed) {
            uint256 w;
            for (uint256 i; i < distinct; ++i) {
                if (i & 7 == 0) w = words[i >> 3];
                uint256 e = (w >> ((i & 7) << 5)) & 0xffffffff;
                motifNumbers[i] = e >> 16;
                counts[i] = e & 0xffff;
            }
            return (motifNumbers, counts);
        }
        uint256 k;
        for (uint256 s; s < 64 && k < distinct; ++s) {
            uint256 w = words[s];
            for (uint256 j; w != 0; ++j) {
                uint256 c = w & 0xffff;
                w >>= 16;
                if (c == 0) continue;
                motifNumbers[k] = (s << 4) + j + 1;
                counts[k] = c;
                ++k;
            }
        }
    }

    /// @dev `data:application/json;utf8,{"name":…,"description":…,["external_url":…,]"image":…,`
    function _openJson(uint256 tokenId, Kilim memory k, string memory titleName, bool isSealed)
        private
        view
        returns (bytes memory)
    {
        string memory rank = rankName(k.rank);
        // The token name drops a leading "The ": "Master 3", as the rules write it.
        if (bytes(rank).length > 4 && bytes4(bytes(rank)) == "The ") {
            assembly ("memory-safe") {
                let len := mload(rank)
                rank := add(rank, 4)
                mstore(rank, sub(len, 4))
            }
        }
        bytes memory image = bytes(imageBase).length != 0 && isSealed
            ? bytes.concat(bytes(imageBase), bytes(tokenId.toString()))
            : bytes.concat("data:image/svg+xml;base64,", bytes(Base64.encode(bytes(motifs.svg(k.title)))));
        bytes memory link = bytes(externalUrl).length != 0
            ? bytes.concat('"external_url":"', bytes(externalUrl), bytes(tokenId.toString()), '",')
            : bytes("");
        return bytes.concat(
            'data:application/json;utf8,{"name":"',
            bytes(rank),
            " ",
            bytes(uint256(k.number).toString()),
            " \\u00b7 ",
            bytes(titleName),
            '","description":"',
            bytes(description),
            '",',
            link,
            '"image":"',
            image,
            '",'
        );
    }

    /// @dev `"attributes":[…]}`, the traits in the spec's order.
    function _traits(Kilim memory k, string memory titleName, bool isSealed)
        private
        pure
        returns (bytes memory out)
    {
        out = bytes.concat(
            '"attributes":[{"trait_type":"Rank","value":"',
            bytes(rankName(k.rank)),
            '"},{"trait_type":"Number","display_type":"number","value":',
            bytes(uint256(k.number).toString()),
            '},{"trait_type":"Motifs","display_type":"number","value":',
            bytes(uint256(k.count).toString()),
            '},{"trait_type":"Distinct motifs","display_type":"number","value":',
            bytes(uint256(k.distinct).toString())
        );
        out = bytes.concat(
            out,
            '},{"trait_type":"Title motif","value":"',
            bytes(titleName),
            " (motif ",
            bytes(uint256(k.title).toString()),
            ')"},{"trait_type":"Seed","value":"',
            isSealed ? bytes(uint256(k.seed).toHexString(4)) : bytes("Sealing"),
            '"}'
        );
        if (k.flags & WHOLE != 0) out = bytes.concat(out, ',{"trait_type":"Whole","value":"Yes"}');
        if (k.flags & WINNING_BID != 0) {
            out = bytes.concat(out, ',{"trait_type":"Made from the winning bid","value":"Yes"}');
        }
        out = bytes.concat(out, "]}");
    }

    /// @dev S = `;window.KILIM_PIECE={"seed":"0x<8 hex>","motifs":[[n,c],…],"top":<top>}`, every nonzero
    ///      count in ascending motif number, decimal, no spaces: what JSON.stringify writes. Built in one
    ///      pass into a buffer of 192 + 13·distinct bytes, then the length is set. An entry is at most
    ///      `,[1024,65535]` (13 bytes) and the fixed text with any uint256 top at most 137 bytes, so every
    ///      write, including the whole word _put stores, lands inside that buffer.
    function _piece(Kilim memory k, uint256 top) private view returns (bytes memory s) {
        uint256 distinct = k.distinct;
        s = new bytes(192 + 13 * distinct);
        uint256 p;
        assembly ("memory-safe") {
            p := add(s, 32)
        }
        p = _put(p, ';window.KILIM_PIECE={"seed":"0x', 31);
        p = _hex8(p, k.seed);
        p = _put(p, '","motifs":[', 12);
        uint256[64] storage words = _hands[k.handKey];
        if (k.flags & PACKED != 0) {
            uint256 w;
            for (uint256 i; i < distinct; ++i) {
                if (i & 7 == 0) w = words[i >> 3];
                uint256 e = (w >> ((i & 7) << 5)) & 0xffffffff;
                p = _entry(p, i != 0, e >> 16, e & 0xffff);
            }
        } else {
            uint256 written;
            for (uint256 x; x < 64 && written < distinct; ++x) {
                uint256 w = words[x];
                for (uint256 j; w != 0; ++j) {
                    uint256 c = w & 0xffff;
                    w >>= 16;
                    if (c == 0) continue;
                    p = _entry(p, written != 0, (x << 4) + j + 1, c);
                    ++written;
                }
            }
        }
        p = _put(p, '],"top":', 8);
        p = _dec(p, top);
        p = _put(p, "}", 1);
        assembly ("memory-safe") {
            mstore(s, sub(p, add(s, 32)))
        }
    }

    /// @dev Writes `len` bytes of `word` at p (a whole word is stored; the buffer has room past the end).
    function _put(uint256 p, bytes32 word, uint256 len) private pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(p, word)
        }
        return p + len;
    }

    /// @dev `,[n,c]` (no comma for the first entry).
    function _entry(uint256 p, bool comma, uint256 n, uint256 c) private pure returns (uint256) {
        if (comma) p = _put(p, ",[", 2);
        else p = _put(p, "[", 1);
        p = _dec(p, n);
        p = _put(p, ",", 1);
        p = _dec(p, c);
        return _put(p, "]", 1);
    }

    /// @dev `v` in decimal, no leading zeros, written from the last digit back.
    function _dec(uint256 p, uint256 v) private pure returns (uint256 end) {
        unchecked {
            uint256 digits = 1;
            for (uint256 x = v; x >= 10; x /= 10) {
                ++digits;
            }
            end = p + digits;
            for (uint256 q = end; q > p;) {
                --q;
                assembly ("memory-safe") {
                    mstore8(q, add(48, mod(v, 10)))
                }
                v /= 10;
            }
        }
    }

    /// @dev The 8 lowercase hex digits of a 32-bit seed: the page's formatSeed and Strings.toHexString(seed, 4).
    function _hex8(uint256 p, uint256 v) private pure returns (uint256) {
        unchecked {
            for (uint256 i = 8; i != 0;) {
                --i;
                uint256 d = v & 15;
                assembly ("memory-safe") {
                    mstore8(add(p, i), add(d, add(48, mul(39, gt(d, 9)))))
                }
                v >>= 4;
            }
        }
        return p + 8;
    }

    /// @dev Answers the call with: before, base64(HEAD hex(grids) ' S pad), TAIL, after. HEAD and TAIL are
    ///      the 1/1's stored chunks, copied as they are. KilimOneOfOne.tokenURI's routine with four marked
    ///      changes (CHANGED 1-4). Ends the call with `return`.
    function _respondWithPage(bytes memory before, bytes memory piece, bytes memory afterPage) private view {
        address[] memory head = oneOfOne.headChunks();
        address[] memory tail = oneOfOne.tailChunks();
        address source = address(motifs);
        uint256 gridsCall = uint256(uint32(KilimMotifs.grids.selector)) << 224;
        uint256 unavailable = uint256(uint32(GridsUnavailable.selector)) << 224;
        assembly {
            // Data bytes held by a section's chunks: each chunk's code less its leading 0x00.
            function sectionSize(list) -> size {
                let n := mload(list)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    size := add(size, sub(extcodesize(mload(add(add(list, 32), shl(5, i)))), 1))
                }
            }
            // Copies a section's data bytes to dst, straight from the chunks' code; returns the end.
            function copyChunks(list, dst) -> end {
                end := dst
                let n := mload(list)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    let chunk := mload(add(add(list, 32), shl(5, i)))
                    let size := sub(extcodesize(chunk), 1)
                    extcodecopy(chunk, end, 1, size)
                    end := add(end, size)
                }
            }
            // A memory bytes value copied to dst; returns the end.
            function copyBytes(b, dst) -> end {
                let n := mload(b)
                mcopy(dst, add(b, 32), n)
                end := add(dst, n)
            }
            // 16 bytes, right-aligned, to their 32 lowercase hex characters.
            function hexHalf(x) -> y {
                x := and(
                    or(shl(64, x), x),
                    0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff
                )
                x := and(
                    or(shl(32, x), x),
                    0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff
                )
                x := and(
                    or(shl(16, x), x),
                    0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff
                )
                x := and(or(shl(8, x), x), 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff)
                y := or(
                    shl(4, and(x, 0x00f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f0)),
                    and(x, 0x000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f)
                )
                let letters :=
                    shr(
                        4,
                        and(
                            add(y, 0x0606060606060606060606060606060606060606060606060606060606060606),
                            0x1010101010101010101010101010101010101010101010101010101010101010
                        )
                    )
                y := add(
                    add(y, 0x3030303030303030303030303030303030303030303030303030303030303030),
                    mul(letters, 0x27)
                )
            }
            // 24 bytes, right-aligned, to their 32 base64 characters.
            function base64Block(x) -> y {
                x := or(
                    and(x, 0x0000000000000000000000000000000000000000ffffffffffffffffffffffff),
                    and(shl(32, x), 0x00000000ffffffffffffffffffffffff00000000000000000000000000000000)
                )
                x := or(
                    and(x, 0x00000000000000000000ffffffffffff00000000000000000000ffffffffffff),
                    and(shl(16, x), 0x0000ffffffffffff00000000000000000000ffffffffffff0000000000000000)
                )
                x := or(
                    and(x, 0x0000000000ffffff0000000000ffffff0000000000ffffff0000000000ffffff),
                    and(shl(8, x), 0x00ffffff0000000000ffffff0000000000ffffff0000000000ffffff00000000)
                )
                x := or(
                    and(x, 0x00000fff00000fff00000fff00000fff00000fff00000fff00000fff00000fff),
                    and(shl(4, x), 0x0fff00000fff00000fff00000fff00000fff00000fff00000fff00000fff0000)
                )
                x := or(
                    and(x, 0x003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f),
                    and(shl(2, x), 0x3f003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f00)
                )
                let a :=
                    shr(
                        6,
                        and(
                            add(x, 0x2626262626262626262626262626262626262626262626262626262626262626),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let b :=
                    shr(
                        6,
                        and(
                            add(x, 0x0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let c :=
                    shr(
                        6,
                        and(
                            add(x, 0x0202020202020202020202020202020202020202020202020202020202020202),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let d :=
                    shr(
                        6,
                        and(
                            add(x, 0x0101010101010101010101010101010101010101010101010101010101010101),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                // No lane borrows: where 75 or 15 is taken the lane already holds at least 123.
                y := sub(
                    add(
                        add(x, 0x4141414141414141414141414141414141414141414141414141414141414141),
                        add(mul(a, 6), mul(d, 3))
                    ),
                    add(mul(b, 75), mul(c, 15))
                )
            }

            // CHANGED 1: the piece to encode is HEAD, 65,536 hex chars, the quote, S, then 0-2 spaces to a
            // multiple of 3, so no '=' is written and the two base64 runs join.
            let m := add(add(sectionSize(head), HEX_CHARS), add(1, mload(piece)))
            m := add(m, mod(sub(3, mod(m, 3)), 3))
            let total := add(add(mload(before), div(mul(m, 4), 3)), add(sectionSize(tail), mload(afterPage)))

            // ABI head of the returned string: offset, length, then the bytes.
            let ptr := mload(0x40)
            mstore(ptr, 0x20)
            mstore(add(ptr, 32), total)
            // CHANGED 2: `before` (the JSON up to the animation_url's scheme) in place of the scheme and PREFIX.
            let encoded := copyBytes(before, add(ptr, 64))
            // The base64 piece occupies [encoded, encoded + 4m/3). Its raw bytes go to the last m of those.
            let raw := add(encoded, div(m, 3))
            let hexStart := copyChunks(head, raw)
            let out := hexStart
            {
                // The grids, live from the motif collection, land in the second half of the hex room and
                // are expanded forward: input word i sits at hexStart + 32768 + 32i, its 64 chars go to
                // hexStart + 64i, which never reaches an unread input word.
                mstore(0, gridsCall)
                if iszero(staticcall(gas(), source, 0, 4, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
                if iszero(eq(returndatasize(), add(64, GRID_BYTES))) {
                    mstore(0, unavailable)
                    revert(0, 4)
                }
                returndatacopy(0, 0, 64)
                if or(iszero(eq(mload(0), 0x20)), iszero(eq(mload(32), GRID_BYTES))) {
                    mstore(0, unavailable)
                    revert(0, 4)
                }
                let scratch := add(hexStart, GRID_BYTES)
                returndatacopy(scratch, 64, GRID_BYTES)
                for { let at := scratch } lt(at, add(scratch, GRID_BYTES)) { at := add(at, 32) } {
                    let w := mload(at)
                    mstore(out, hexHalf(shr(128, w)))
                    mstore(add(out, 32), hexHalf(and(w, 0xffffffffffffffffffffffffffffffff)))
                    out := add(out, 64)
                }
            }
            // The closing quote of the JS string; CHANGED 3: then S, then the padding spaces up to raw + m.
            mstore8(out, 0x27)
            for { let k := copyBytes(piece, add(out, 1)) } lt(k, add(raw, m)) { k := add(k, 1) } {
                mstore8(k, 0x20)
            }

            {
                let src := raw
                let dst := encoded
                let last := add(raw, m)
                // Whole blocks of 24 bytes: block j is read from raw + 24j and written, 32 bytes, to
                // encoded + 32j, which ends below raw + 24j + 24, the next unread byte, since raw = encoded + m/3.
                for {} iszero(lt(sub(last, src), 24)) {} {
                    mstore(dst, base64Block(shr(64, mload(src))))
                    src := add(src, 24)
                    dst := add(dst, 32)
                }
                // The last groups of 3 (fewer than 8), one at a time through the alphabet in memory.
                mstore(0, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")
                mstore(32, "ghijklmnopqrstuvwxyz0123456789+/")
                for {} lt(src, last) {} {
                    let v := shr(232, mload(src))
                    mstore8(dst, shr(248, mload(shr(18, v))))
                    mstore8(add(dst, 1), shr(248, mload(and(shr(12, v), 63))))
                    mstore8(add(dst, 2), shr(248, mload(and(shr(6, v), 63))))
                    mstore8(add(dst, 3), shr(248, mload(and(v, 63))))
                    src := add(src, 3)
                    dst := add(dst, 4)
                }
            }

            let pos := copyChunks(tail, add(raw, m))
            // CHANGED 4: `after` (the attributes and the closing brace) in place of `"}`.
            pos := copyBytes(afterPage, pos)
            if iszero(eq(pos, add(add(ptr, 64), total))) { revert(0, 0) }
            // Zero the padding of the last word and hand the ABI-encoded string back as is.
            mstore(pos, 0)
            return(ptr, add(64, and(add(total, 31), not(31))))
        }
    }

    // ------------------------------------------------------------ internals: checks and text

    /// @dev The splice point tokenURI relies on: HEAD's last chunk ends with `const GRIDS='` and TAIL's first
    ///      chunk starts with `O2Nv`, the base64 of `;co` (the `;const BLOB=` after the grids' closing quote).
    function _checkSplicePoint(KilimOneOfOne page) private view {
        address[] memory head = page.headChunks();
        address[] memory tail = page.tailChunks();
        address last = head[head.length - 1];
        address first = tail[0];
        uint256 lastSize = last.code.length;
        if (lastSize < 14 || first.code.length < 5) revert InvalidConfiguration();
        bytes32 end;
        bytes32 start;
        assembly ("memory-safe") {
            extcodecopy(last, 0, sub(lastSize, 13), 13)
            end := mload(0)
            extcodecopy(first, 0, 1, 4)
            start := mload(0)
        }
        if (bytes13(end) != bytes13("const GRIDS='") || bytes4(start) != bytes4("O2Nv")) {
            revert InvalidConfiguration();
        }
    }

    /// @dev The three texts travel raw inside a data: URL and a JSON string: printable ASCII only, and none
    ///      of `"` or `\` (JSON), `#` (would cut the URL) or `%` (would be decoded). Checked once, here.
    function _checkText(string memory text) private pure {
        bytes memory b = bytes(text);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c > 0x7e || c == '"' || c == "\\" || c == "#" || c == "%") {
                revert InvalidConfiguration();
            }
        }
    }

    /// @dev JSON-escaped text that is also safe raw in a `data:…;utf8,` URL: `"` and `\` get a backslash;
    ///      control characters, `#` and `%` become \u00XX. Two passes keep this allocation-exact.
    function _escapeJson(string memory input) private pure returns (string memory) {
        bytes memory data = bytes(input);
        uint256 length;
        for (uint256 i; i < data.length; ++i) {
            length += _escapedLength(data[i]);
        }
        if (length == data.length) return input;
        bytes memory out = new bytes(length);
        uint256 n;
        for (uint256 i; i < data.length; ++i) {
            bytes1 c = data[i];
            uint256 size = _escapedLength(c);
            if (size == 1) {
                out[n++] = c;
            } else if (size == 2) {
                out[n++] = "\\";
                out[n++] = c;
            } else {
                out[n++] = "\\";
                out[n++] = "u";
                out[n++] = "0";
                out[n++] = "0";
                out[n++] = bytes1(_hexDigit(uint8(c) >> 4));
                out[n++] = bytes1(_hexDigit(uint8(c) & 0x0f));
            }
        }
        return string(out);
    }

    function _escapedLength(bytes1 c) private pure returns (uint256) {
        if (c == '"' || c == "\\") return 2;
        if (uint8(c) < 0x20 || c == "#" || c == "%") return 6;
        return 1;
    }

    function _hexDigit(uint8 value) private pure returns (uint8) {
        return value < 10 ? 48 + value : 87 + value;
    }

    /// @dev None of the four contracts can move a kilim, so one sent there would be lost.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_blocked(to)) revert InvalidRecipient();
        return super._update(to, tokenId, auth);
    }
}
