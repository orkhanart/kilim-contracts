// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../../src/KilimBazaar.sol";
import {HalmosBase} from "./HalmosBase.sol";

/// @dev Stands in for the auction: every read the Bazaar makes (MOTIF_PRICE, motifs, oneOfOne, settled,
///      highestBid, highestBidMotifs), settable, so the auction's final terms can be symbolic. The real
///      auction keeps them final after settlement (AuctionSolvencyHalmos checks that); here they are set once.
contract FakeAuction {
    KilimMotifs public motifs;
    KilimOneOfOne public oneOfOne;
    uint256 public immutable MOTIF_PRICE;
    bool public settled;
    uint256 public highestBid;
    uint256 internal _first;
    uint256 internal _won;

    constructor(uint256 price) {
        MOTIF_PRICE = price;
    }

    function setTokens(KilimMotifs motifs_, KilimOneOfOne oneOfOne_) external {
        motifs = motifs_;
        oneOfOne = oneOfOne_;
    }

    function settle(uint256 bid, uint256 first, uint256 won) external {
        settled = true;
        highestBid = bid;
        _first = first;
        _won = won;
    }

    function highestBidMotifs() external view returns (uint256, uint256) {
        return (_first, _won);
    }
}

abstract contract BazaarHalmosBase is HalmosBase {
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    /// The canonical EIP-2935 runtime, as on mainnet and Sepolia (the same bytes the Foundry tests etch).
    bytes internal constant HISTORY_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";
    address internal constant H = address(0xBEEF01); // a holder (EOA)
    uint256 internal constant CAP = 1_000_000;
    // KilimBazaar storage slots (forge storageLayout).
    uint256 internal constant SLOT_TALLY = 9;
    uint256 internal constant SLOT_LOOMS = 10;
    uint256 internal constant SLOT_HANDS = 12;
    uint256 internal constant SLOT_KILIMS = 11;

    FakeAuction internal fake;
    KilimMotifs internal motifs;
    KilimOneOfOne internal oneOfOne;

    function _core() internal {
        _core(0.001 ether);
    }

    function _core(uint256 price) internal {
        fake = new FakeAuction(price);
        motifs = newMotifs(address(fake), CAP);
        oneOfOne = newOneOfOne(address(fake), motifs);
        fake.setTokens(motifs, oneOfOne);
    }

    function _newBazaar() internal returns (KilimBazaar) {
        return new KilimBazaar(
            KilimAuction(address(fake)), address(0xA27157), oneOfOne.tailHash(), "desc", "https://x/", ""
        );
    }

    /// @dev Mints ids first..first+qty-1 to `to`, as the auction's claim would.
    function _give(address to, uint256 first, uint256 qty) internal {
        for (uint256 done; done < qty;) {
            uint256 q = qty - done < 64 ? qty - done : 64;
            vm.prank(address(fake));
            motifs.mintMotifs(to, to, first + done, q);
            done += q;
        }
    }

    function _range(uint256 first, uint256 count) internal pure returns (uint256[] memory r) {
        r = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            r[i] = first + i;
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }

    /// @dev The page's ranks: the Master at or above top, else the highest fixed cost at or under count.
    function _expectedRank(uint256 count, uint256 top) internal pure returns (uint8) {
        if (count < 10) return 0;
        if (count >= top) return 6;
        if (count >= 1000) return 5;
        if (count >= 300) return 4;
        if (count >= 100) return 3;
        if (count >= 30) return 2;
        return 1;
    }

    function _loomSlot(address weaver) internal pure returns (bytes32) {
        return keccak256(abi.encode(weaver, SLOT_LOOMS));
    }

    function _handSlot(uint256 key, uint256 word) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(key, SLOT_HANDS))) + word);
    }
}

/// @notice Rank and ladder for ALL Master costs (any winning bid from the reserve, 10 units, to uint128 max
///         counted in units) and ALL counts; and the refusals that come before any motif moves.
///         The stand-in auction here uses a 1-wei bid unit, so the Master's cost is the symbolic winning bid
///         itself: the Bazaar divides by the unit once (`highestBid / motifPrice`, exact for whole-unit bids)
///         and a symbolic 256-bit division made the ladder check time out. Rank logic sees only that quotient.
contract BazaarRankHalmos is BazaarHalmosBase {
    KilimBazaar internal bazaar;

    function setUp() public {
        _core(1);
        bazaar = _newBazaar();
        _give(H, 1, 10);
        vm.prank(H);
        motifs.setApprovalForAll(address(bazaar), true);
    }

    function _settle(uint256 topUnits) internal {
        vm.assume(topUnits >= 10 && topUnits <= type(uint128).max / UNIT);
        fake.settle(topUnits, 0, 0); // unit = 1 wei: masterCost() == topUnits
    }

    function check_rank_matchesPageRule(uint256 topUnits, uint256 count, uint256 count2) public {
        _settle(topUnits);
        uint8 r = bazaar.rankFor(count);
        assert(r == _expectedRank(count, topUnits));
        assert(r <= 6);
        // Monotone in the count.
        if (count <= count2) assert(r <= bazaar.rankFor(count2));
        assert(bazaar.masterCost() == topUnits);
    }

    /// @dev The ladder the page shows and the rank a kilim gets agree: a count earns rank r (1..5) only if
    ///      r's cost is on the ladder (not undercut by the Master), at or under the count, and the next
    ///      listed cost is above it; the Master exactly from its cost up; nothing under 10.
    function check_rank_agreesWithLadder(uint256 topUnits, uint256 count) public {
        _settle(topUnits);
        (uint256[6] memory costs, bool open) = bazaar.ladder();
        assert(open);
        assert(costs[5] == topUnits);
        uint256[5] memory fixedCosts = [uint256(10), 30, 100, 300, 1000];
        for (uint256 i; i < 5; ++i) {
            assert(costs[i] == (fixedCosts[i] < topUnits ? fixedCosts[i] : 0));
        }
        uint8 r = bazaar.rankFor(count);
        if (r == 0) {
            assert(count < 10);
        } else if (r == 6) {
            assert(count >= topUnits && count >= 10);
        } else {
            assert(count < topUnits);
            assert(costs[r - 1] != 0 && costs[r - 1] <= count);
            if (r < 5) assert(costs[r] == 0 || count < costs[r]);
        }
    }

    /// @dev Before settlement every read of the Master's cost reverts, the ladder shows the five fixed
    ///      costs closed, and make/deposit/makeFromLoom revert before any motif moves.
    function check_beforeSettlement(uint256 count) public {
        (bool ok,) = address(bazaar).staticcall(abi.encodeCall(bazaar.rankFor, (count)));
        assert(!ok);
        (ok,) = address(bazaar).staticcall(abi.encodeCall(bazaar.masterCost, ()));
        assert(!ok);
        (uint256[6] memory costs, bool open) = bazaar.ladder();
        assert(!open);
        assert(costs[0] == 10 && costs[1] == 30 && costs[2] == 100 && costs[3] == 300 && costs[4] == 1000);
        assert(costs[5] == 0);
        uint256[] memory list = _range(1, 10);
        vm.prank(H);
        (ok,) = address(bazaar).call(abi.encodeCall(bazaar.make, (list, H)));
        assert(!ok);
        vm.prank(H);
        (ok,) = address(bazaar).call(abi.encodeCall(bazaar.deposit, (list)));
        assert(!ok);
        vm.prank(H);
        (ok,) = address(bazaar).call(abi.encodeCall(bazaar.makeFromLoom, (list, H)));
        assert(!ok);
        assert(motifs.balanceOf(H) == 10); // nothing moved
    }

    /// @dev Fewer than 10 motifs (every length 0..9) never make a kilim or open a loom; closing a loom you
    ///      do not have reverts. All before any motif moves. Any Master cost.
    function check_quantityFloor(uint256 topUnits) public {
        _settle(topUnits);
        for (uint256 n; n < 10; ++n) {
            uint256[] memory list = _range(1, n);
            vm.prank(H);
            (bool ok, bytes memory ret) = address(bazaar).call(abi.encodeCall(bazaar.make, (list, H)));
            assert(!ok && _sel(ret) == KilimBazaar.TooFewMotifs.selector);
            vm.prank(H);
            (ok, ret) = address(bazaar).call(abi.encodeCall(bazaar.deposit, (list)));
            assert(!ok && _sel(ret) == KilimBazaar.TooFewMotifs.selector);
        }
        vm.prank(H);
        (bool ok2, bytes memory ret2) =
            address(bazaar).call(abi.encodeCall(bazaar.makeFromLoom, (new uint256[](0), H)));
        assert(!ok2 && _sel(ret2) == KilimBazaar.NoLoom.selector);
        assert(motifs.balanceOf(H) == 10);
    }

    /// @dev A kilim can never be minted to the zero address or to one of the four contracts. Any Master cost.
    function check_blockedRecipients(uint256 topUnits) public {
        _settle(topUnits);
        address[5] memory blocked =
            [address(0), address(bazaar), address(motifs), address(fake), address(oneOfOne)];
        for (uint256 i; i < 5; ++i) {
            vm.prank(H);
            (bool ok,) = address(bazaar).call(abi.encodeCall(bazaar.make, (_range(1, 10), blocked[i])));
            assert(!ok);
        }
        assert(motifs.balanceOf(H) == 10);
    }
}

/// @notice The seal: for ANY two later blocks n1 <= n2 (< 2^40), a seal() at n1 then at n2 does exactly
///         what sealState() said: waits, re-arms only once the window has passed, or seals from the hash of
///         the seal block (from the EIP-2935 history contract, its storage fully symbolic) and only when that
///         hash is nonzero. A sealed seed never changes. NOT covered: the blockhash branch (age 1..256),
///         because Halmos 0.3.3 crashes on the BLOCKHASH opcode; blocks are assumed outside that branch.
///         Two Bazaars: one deployed without the history contract (window 256), one with it (8,191).
contract BazaarSealHalmos is BazaarHalmosBase {
    KilimBazaar internal b256;
    KilimBazaar internal b8191;

    function setUp() public {
        _core();
        b256 = _newBazaar();
        vm.etch(HISTORY, HISTORY_CODE);
        b8191 = _newBazaar();
        require(b256.seedWindow() == 256, "window 256");
        require(b8191.seedWindow() == 8191, "window 8191");
        fake.settle(50 * UNIT, 0, 0);
        _give(H, 1, 20);
        vm.startPrank(H);
        motifs.setApprovalForAll(address(b256), true);
        motifs.setApprovalForAll(address(b8191), true);
        b256.make(_range(1, 10), H);
        b8191.make(_range(11, 10), H);
        vm.stopPrank();
    }

    /// @dev Returns which way the seal went: 1 waited, 2 re-armed, 4 sealed from the history contract,
    ///      5 skipped (zero hash), 6 already sealed. (3, sealed from blockhash, is not reachable here.)
    function _step(KilimBazaar bz, uint256 window) internal returns (uint8 path) {
        KilimBazaar.Kilim memory k = bz.kilim(1);
        uint8 state = bz.sealState(1);
        uint256 n = block.number;
        uint256 sb = k.sealBlock;
        bool sealedBefore = k.flags & 1 != 0;
        // Halmos 0.3.3 crashes on the BLOCKHASH opcode (Z3Exception "parser error": it applies f_blockhash to
        // its own BV wrapper), so the blockhash branch (1 <= age <= 256) cannot be explored: assume it away.
        vm.assume(n <= sb || n - sb > 256);
        bytes32 h;
        if (!sealedBefore && n > sb && n - sb <= window) {
            h = vm.load(HISTORY, bytes32(sb % 8191));
        }
        uint256 count = bz.seal(_one(1));
        KilimBazaar.Kilim memory k2 = bz.kilim(1);
        // What a seal never touches.
        assert(k2.handKey == k.handKey && k2.count == k.count && k2.number == k.number);
        assert(k2.title == k.title && k2.distinct == k.distinct && k2.rank == k.rank);
        bool unchanged = k2.flags == k.flags && k2.seed == k.seed && k2.sealBlock == k.sealBlock;
        if (sealedBefore) {
            assert(state == 4 && unchanged && count == 0);
            path = 6;
        } else if (n <= sb) {
            assert(state == 1 && unchanged && count == 0);
            path = 1;
        } else if (n - sb > window) {
            assert(state == 3 && count == 0);
            assert(k2.sealBlock == n + 1 && k2.flags == k.flags && k2.seed == k.seed);
            assert(bz.sealState(1) == 1);
            path = 2;
        } else {
            assert(state == 2);
            if (h != 0) {
                assert(count == 1);
                assert(k2.flags == k.flags | 1 && k2.sealBlock == k.sealBlock);
                assert(k2.seed == uint32(uint256(keccak256(abi.encode(h, address(bz), uint256(1))))));
                assert(bz.sealState(1) == 4);
                path = 4;
            } else {
                assert(unchanged && count == 0 && bz.sealState(1) == 2);
                path = 5;
            }
        }
    }

    function _twoSteps(KilimBazaar bz, uint256 window, uint256 n1, uint256 n2)
        internal
        returns (uint8 first, uint8 second)
    {
        svm.enableSymbolicStorage(HISTORY);
        vm.assume(n1 >= block.number && n1 <= n2 && n2 < (1 << 40) - 2);
        vm.roll(n1);
        first = _step(bz, window);
        vm.roll(n2);
        second = _step(bz, window);
    }

    function check_seal_window8191(uint256 n1, uint256 n2) public {
        _twoSteps(b8191, 8191, n1, n2);
    }

    function check_seal_window256(uint256 n1, uint256 n2) public {
        _twoSteps(b256, 256, n1, n2);
    }

    // Reachability probes (EXPECTED to FAIL): a counterexample shows the path is reachable.

    function check_reach_sealFromHistory_EXPECTED_FAIL(uint256 n1, uint256 n2) public {
        (uint8 a, uint8 b) = _twoSteps(b8191, 8191, n1, n2);
        assert(a != 4 && b != 4);
    }

    function check_reach_rearmThenSeal_EXPECTED_FAIL(uint256 n1, uint256 n2) public {
        (uint8 a, uint8 b) = _twoSteps(b8191, 8191, n1, n2);
        assert(!(a == 2 && b == 4));
    }

    function check_reach_rearm256_EXPECTED_FAIL(uint256 n1, uint256 n2) public {
        (uint8 a, uint8 b) = _twoSteps(b256, 256, n1, n2);
        assert(a != 2 && b != 2);
    }
}

/// @notice One loom fold for ANY prior count in the touched lane (and any other 15 lanes of that word),
///         any prior loom count, title and distinct: the lane rises by exactly the number of ids that show
///         its motif, never carries into a neighbour, CountOverflow fires exactly when the lane would pass
///         65,535, the loom count is SafeCast to uint32, and title/titleCount/distinct follow the page rule.
contract BazaarLoomHalmos is BazaarHalmosBase {
    KilimBazaar internal bazaar;
    uint256 internal key;
    uint256 internal x; // an id held by H, not yet in the loom
    uint256 internal y1; // two more ids that show the same motif
    uint256 internal y2;

    function setUp() public {
        _core();
        bazaar = _newBazaar();
        fake.settle(50 * UNIT, 0, 0);
        _give(H, 1, 128);
        vm.prank(H);
        motifs.setApprovalForAll(address(bazaar), true);
        vm.prank(H);
        key = bazaar.deposit(_range(1, 10));
        x = 11;
        // Find two ids in 12..128 that show the same motif (birthday: certain among 117 ids).
        uint256[1025] memory seen;
        for (uint256 id = 12; id <= 128; ++id) {
            uint256 m = motifs.motifOf(id);
            if (seen[m] != 0 && motifs.motifOf(x) != m) {
                y1 = seen[m];
                y2 = id;
                break;
            }
            seen[m] = id;
        }
        require(y2 != 0, "no pair");
    }

    struct L {
        uint256 c0;
        uint256 t0;
        uint256 tc0;
        uint256 d0;
    }

    /// @dev Writes a symbolic word into the hand and symbolic count/title/titleCount/distinct into the loom.
    function _symbolicLoom(uint256 lane) internal returns (uint256 w, L memory p) {
        w = svm.createUint256("word");
        p.c0 = svm.createUint(32, "count");
        p.t0 = svm.createUint(16, "title");
        p.tc0 = svm.createUint(16, "titleCount");
        p.d0 = svm.createUint(16, "distinct");
        vm.assume(p.c0 >= 10 && p.t0 >= 1 && p.t0 <= 1024 && p.d0 <= 1024);
        // titleCount is the hand's largest count: at least every lane of this word.
        for (uint256 j; j < 16; ++j) {
            vm.assume((w >> (16 * j)) & 0xffff <= p.tc0);
        }
        vm.store(address(bazaar), _handSlot(key, lane >> 4), bytes32(w));
        KilimBazaar.Loom memory l = bazaar.loomOf(H);
        uint256 packed = uint256(l.handKey) | (p.c0 << 32) | (uint256(l.minId) << 64) | (uint256(l.maxId) << 96)
            | (p.t0 << 128) | (p.tc0 << 144) | (p.d0 << 160);
        vm.store(address(bazaar), _loomSlot(H), bytes32(packed));
    }

    struct F {
        uint256 w;
        uint256 lane;
        uint256 inc;
        uint256 shift;
        uint256 old;
        uint256 c;
        uint32 minBefore;
        uint32 maxBefore;
        uint32 keyBefore;
    }

    /// @dev Returns 1 CountOverflow, 2 SafeCast revert, 3 folded.
    function _foldCheck(uint256[] memory ids, uint256 lane, uint256 inc) internal returns (uint8 path) {
        F memory f;
        L memory p;
        (f.w, p) = _symbolicLoom(lane);
        KilimBazaar.Loom memory before = bazaar.loomOf(H);
        f.minBefore = before.minId;
        f.maxBefore = before.maxId;
        f.keyBefore = before.handKey;
        f.lane = lane;
        f.inc = inc;
        f.shift = 16 * (lane & 15);
        f.old = (f.w >> f.shift) & 0xffff;
        f.c = f.old + inc;
        vm.prank(H);
        (bool ok, bytes memory ret) = address(bazaar).call(abi.encodeCall(bazaar.deposit, (ids)));
        if (f.c > 0xffff) {
            assert(!ok && _sel(ret) == KilimBazaar.CountOverflow.selector);
            path = 1;
        } else if (p.c0 + ids.length > type(uint32).max) {
            assert(!ok); // SafeCast
            path = 2;
        } else {
            assert(ok);
            _foldAfter(ids, f, p);
            path = 3;
        }
    }

    function _foldAfter(uint256[] memory ids, F memory f, L memory p) internal view {
        uint256 w2 = uint256(vm.load(address(bazaar), _handSlot(key, f.lane >> 4)));
        assert(w2 == f.w + (f.inc << f.shift)); // that lane only: no carry, no other lane touched
        KilimBazaar.Loom memory l = bazaar.loomOf(H);
        assert(l.handKey == f.keyBefore);
        assert(l.count == p.c0 + ids.length);
        assert(l.distinct == p.d0 + (f.old == 0 ? 1 : 0));
        uint256 motif = f.lane + 1;
        bool wins = f.c > p.tc0 || (f.c == p.tc0 && motif < p.t0);
        assert(l.title == (wins ? motif : p.t0));
        assert(l.titleCount == (wins ? f.c : p.tc0));
        uint256 lo = ids[0] < f.minBefore ? ids[0] : f.minBefore;
        uint256 hi = ids[ids.length - 1] > f.maxBefore ? ids[ids.length - 1] : f.maxBefore;
        assert(l.minId == lo && l.maxId == hi);
    }

    function check_fold_oneId() public {
        _foldCheck(_one(x), motifs.motifOf(x) - 1, 1);
    }

    function check_fold_twoIdsSameMotif() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = y1;
        ids[1] = y2;
        _foldCheck(ids, motifs.motifOf(y1) - 1, 2);
    }

    // Reachability probes (EXPECTED to FAIL): each path of the fold is reachable.

    function check_reach_foldOk_EXPECTED_FAIL() public {
        assert(_foldCheck(_one(x), motifs.motifOf(x) - 1, 1) != 3);
    }

    function check_reach_foldOverflow_EXPECTED_FAIL() public {
        assert(_foldCheck(_one(x), motifs.motifOf(x) - 1, 1) != 1);
    }
}

/// @notice make() for ANY tally state (each of the eight 32-bit lanes below 2^32 - 1), ANY Master cost and
///         ANY winning range: the token id, rank, number and hand key come from the right lanes, every other
///         lane is untouched, and the winning-bid flag is set exactly when every burned id lies in the
///         winning bid's range.
contract BazaarMakeHalmos is BazaarHalmosBase {
    KilimBazaar internal bazaar;

    function setUp() public {
        _core();
        bazaar = _newBazaar();
        _give(H, 1, 20);
        vm.prank(H);
        motifs.setApprovalForAll(address(bazaar), true);
    }

    function check_make_tallyRankAndFlags(uint256 topUnits, uint256 first, uint256 won) public {
        _make(topUnits, first, won);
    }

    // Reachability probes (EXPECTED to FAIL): the Master rank and the winning-bid flag are reachable.

    function check_reach_makeMaster_EXPECTED_FAIL(uint256 topUnits, uint256 first, uint256 won) public {
        assert(_make(topUnits, first, won).rank != 6);
    }

    function check_reach_makeWinningBid_EXPECTED_FAIL(uint256 topUnits, uint256 first, uint256 won) public {
        assert(_make(topUnits, first, won).flags & 4 == 0);
    }

    function _make(uint256 topUnits, uint256 first, uint256 won) internal returns (KilimBazaar.Kilim memory k) {
        uint256[8] memory lane;
        uint256 t;
        for (uint256 i; i < 8; ++i) {
            lane[i] = svm.createUint(32, "lane");
            vm.assume(lane[i] < type(uint32).max);
            t |= lane[i] << (32 * i);
        }
        vm.store(address(bazaar), bytes32(SLOT_TALLY), bytes32(t));
        vm.assume(topUnits >= 10 && topUnits <= type(uint128).max / UNIT);
        vm.assume((first == 0 && won == 0) || (first >= 1 && won >= 1 && won <= CAP && first <= CAP + 1 - won));
        fake.settle(topUnits * UNIT, first, won);

        uint256[] memory ids = _range(5, 10); // ids 5..14
        vm.prank(H);
        uint256 tokenId = bazaar.make(ids, H);

        uint8 rank = _expectedRank(10, topUnits);
        assert(tokenId == lane[7] + 1);
        assert(bazaar.totalSupply() == lane[7] + 1);
        uint256 t2 = uint256(vm.load(address(bazaar), bytes32(SLOT_TALLY)));
        for (uint256 i; i < 8; ++i) {
            uint256 expected = lane[i] + ((i == 7 || i == 6 || i == rank - 1) ? 1 : 0);
            assert((t2 >> (32 * i)) & 0xffffffff == expected);
        }
        k = bazaar.kilim(tokenId);
        assert(k.rank == rank);
        assert(k.number == lane[rank - 1] + 1);
        assert(bazaar.madeAt(rank) == lane[rank - 1] + 1);
        assert(k.handKey == lane[6] + 1);
        assert(k.count == 10);
        assert(k.sealBlock == block.number + 1 && k.seed == 0);
        assert(k.flags & 1 == 0 && k.flags & 2 == 0); // not sealed; not whole
        bool winning = won != 0 && 5 >= first && 14 - first < won;
        assert((k.flags & 4 != 0) == winning);
        assert(bazaar.ownerOf(tokenId) == H);
        assert(motifs.burned(5) && motifs.burned(14));
    }
}
