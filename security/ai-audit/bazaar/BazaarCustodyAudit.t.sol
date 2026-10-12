// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {BazaarBase, FakeAuction} from "../../../test/bazaar/BazaarBase.sol";

/// AI audit 2026-10-12, lens: Kilim Bazaar custody and supply. Each test asserts the property the audit
/// checked; a failing test would be a finding. Run only with the isolated out/cache dirs (see ai-bazaar.md).

interface VmRec {
    function record() external;
    function accesses(address) external returns (bytes32[] memory reads, bytes32[] memory writes);
    function load(address, bytes32) external view returns (bytes32);
}

/// @dev Receives motifs from a mint and, on the tenth, makes a kilim from them inside the mint's hook.
contract MintHookMaker is IERC721Receiver {
    KilimBazaar public immutable bazaar;
    KilimMotifs public immutable motifs;
    uint256[] public got;
    uint256 public kilimId;
    bool public made;

    constructor(KilimBazaar bazaar_, KilimMotifs motifs_) {
        bazaar = bazaar_;
        motifs = motifs_;
        motifs_.setApprovalForAll(address(bazaar_), true);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(motifs)) {
            got.push(id);
            if (got.length == 10 && !made) {
                made = true;
                kilimId = bazaar.make(got, address(this));
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function gotLength() external view returns (uint256) {
        return got.length;
    }
}

/// @dev A winning bidder whose receiver hook refuses the 1/1 in three hostile ways.
contract HostileWinner {
    uint8 public immutable mode; // 0 revert, 1 burn all gas, 2 return bomb

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function bid(KilimAuction a, uint256 amount) external payable {
        a.bid{value: amount}(amount, 0, 0);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (mode == 0) revert("no");
        if (mode == 1) {
            uint256 x;
            while (gasleft() > 0) {
                ++x;
            }
            return bytes4(uint32(x));
        }
        assembly {
            revert(0, 200000)
        }
    }
}

/// @notice Custody, duplicates, looms, strays, cross-contract hooks, tags and Glamsterdam gas, after a 10 ETH close.
contract BazaarCustodyAuditTest is BazaarBase {
    VmRec internal constant rec = VmRec(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant B = 5_000_000;
    /// Pool ids for the fuzzed hands: far from the holder range (500,001+) and the winning range (1..10,000).
    uint256 internal constant POOL_FROM = 800_000;
    uint256 internal constant FILLER_FROM = 950_000;
    uint256 internal constant PER_MOTIF = 20;

    uint256[4] internal targets;
    uint256[][4] internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
        _standard();
        _settle(10 ether);
        // four motifs, PER_MOTIF ids showing each, for the fuzzed hands with many ties
        uint256 id = POOL_FROM;
        for (uint256 nt; nt < 4; ++id) {
            uint256 m0 = _motifOf(id);
            bool dup;
            for (uint256 u; u < nt; ++u) {
                if (targets[u] == m0) dup = true;
            }
            if (dup) continue;
            targets[nt] = m0;
            pool[nt].push(id);
            ++nt;
        }
        uint256 filled;
        for (; filled < 4; ++id) {
            uint256 m = _motifOf(id);
            for (uint256 t; t < 4; ++t) {
                if (m == targets[t] && pool[t].length < PER_MOTIF) {
                    pool[t].push(id);
                    if (pool[t].length == PER_MOTIF) ++filled;
                    break;
                }
            }
        }
    }

    // ------------------------------------------------------------ duplicates and reuse

    function testDuplicateIdsInsideOneCallRevertEverywhere() public {
        uint256[] memory list = _fresh(ALICE, 12);
        uint256[] memory dup = _slice(list, 0, 10);
        dup[9] = dup[0];
        bytes memory incorrect = abi.encodeWithSignature(
            "ERC721IncorrectOwner(address,uint256,address)", ALICE, dup[0], address(bazaar)
        );
        vm.prank(ALICE);
        vmb.expectRevert(incorrect);
        bazaar.make(dup, ALICE);
        vm.prank(ALICE);
        vmb.expectRevert(incorrect);
        bazaar.deposit(dup);
        // an open loom, then a duplicate in a later deposit and in makeFromLoom's own ids
        _deposit(ALICE, _slice(list, 0, 10));
        uint256[] memory two = new uint256[](2);
        two[0] = list[10];
        two[1] = list[10];
        bytes memory incorrect2 = abi.encodeWithSignature(
            "ERC721IncorrectOwner(address,uint256,address)", ALICE, list[10], address(bazaar)
        );
        vm.prank(ALICE);
        vmb.expectRevert(incorrect2);
        bazaar.deposit(two);
        vm.prank(ALICE);
        vmb.expectRevert(incorrect2);
        bazaar.makeFromLoom(two, ALICE);
        assertEq(motifs.motifsBurned(), 10);
        assertEq(bazaar.loomOf(ALICE).count, 10);
        assertEq(motifs.ownerOf(list[10]), ALICE);
        assertEq(motifs.balanceOf(address(bazaar)), 0);
    }

    function testAnIdCanNeverServeTwiceAcrossLoomMakeAndKilims() public {
        uint256[] memory a = _fresh(ALICE, 10);
        uint256[] memory b = _fresh(ALICE, 30);
        _deposit(ALICE, a);
        // a loomed id in a one-call make
        uint256[] memory mix = _slice(b, 0, 10);
        mix[4] = a[3];
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", a[3]));
        bazaar.make(mix, ALICE);
        // a loomed id again into the same loom
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", a[0]));
        bazaar.makeFromLoom(_slice(a, 0, 1), ALICE);
        // close, then reuse the made kilim's ids in a second kilim and a new loom
        uint256 k1 = _makeFromLoom(ALICE, new uint256[](0));
        uint256[] memory again = _slice(b, 10, 20);
        again[0] = a[9];
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", a[9]));
        bazaar.make(again, ALICE);
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", a[9]));
        bazaar.deposit(again);
        uint256 k2 = _make(ALICE, _slice(b, 0, 10));
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", b[0]));
        bazaar.make(_slice(b, 0, 10), ALICE);
        // the burned ids can never be minted again either
        vm.prank(address(auction));
        vmb.expectRevert(abi.encodeWithSignature("AlreadyMinted()"));
        motifs.mintMotifs(ALICE, ALICE, a[0], 1);
        assertEq(bazaar.kilim(k1).count + bazaar.kilim(k2).count, motifs.motifsBurned());
        assertEq(bazaar.totalSupply(), 2);
    }

    // ------------------------------------------------------------ looms and strangers

    function testAStrangerCannotCloseFeedOrRedirectALoom() public {
        uint256[] memory alices = _fresh(ALICE, 20);
        _deposit(ALICE, _slice(alices, 0, 10));
        KilimBazaar.Loom memory before = bazaar.loomOf(ALICE);
        // BOB has no loom, whatever `to` he names
        vm.prank(BOB);
        vmb.expectRevert(abi.encodeWithSelector(KilimBazaar.NoLoom.selector));
        bazaar.makeFromLoom(new uint256[](0), BOB);
        vm.prank(BOB);
        vmb.expectRevert(abi.encodeWithSelector(KilimBazaar.NoLoom.selector));
        bazaar.makeFromLoom(new uint256[](0), ALICE);
        // even an operator over all of ALICE's motifs cannot put them in any loom
        vm.prank(ALICE);
        motifs.setApprovalForAll(BOB, true);
        uint256[] memory rest = _slice(alices, 10, 20);
        vm.prank(BOB);
        vmb.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", BOB, rest[0], ALICE)
        );
        bazaar.deposit(rest);
        vm.prank(BOB);
        vmb.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", BOB, rest[0], ALICE)
        );
        bazaar.make(rest, BOB);
        // BOB's own loom is separate; ALICE's is exactly as it was
        _deposit(BOB, _fresh(BOB, 10));
        KilimBazaar.Loom memory after_ = bazaar.loomOf(ALICE);
        assertEq(after_.handKey, before.handKey);
        assertEq(after_.count, before.count);
        assertEq(after_.title, before.title);
        assertEq(after_.distinct, before.distinct);
        // ALICE closes hers to CAROL; BOB's stays open
        vm.prank(ALICE);
        uint256 t = bazaar.makeFromLoom(rest, CAROL);
        assertEq(bazaar.ownerOf(t), CAROL);
        assertEq(bazaar.kilim(t).count, 20);
        assertEq(bazaar.loomOf(ALICE).handKey, 0);
        assertEq(bazaar.loomOf(BOB).count, 10);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzzALoomIsAlwaysClosable(uint8 a, uint8 b, uint8 c, address to) public {
        if (to == address(0) || to.code.length != 0 || uint160(to) < 0x10000) to = address(0xD00D);
        uint256 n0 = 10 + uint256(a) % 60;
        uint256 n1 = uint256(b) % 40;
        uint256 n2 = uint256(c) % 40;
        _deposit(ALICE, _fresh(ALICE, n0));
        if (n1 != 0) _deposit(ALICE, _fresh(ALICE, n1));
        uint256[] memory last = n2 == 0 ? new uint256[](0) : _fresh(ALICE, n2);
        vm.prank(ALICE);
        uint256 g = gasleft();
        uint256 t = bazaar.makeFromLoom(last, to);
        uint256 used = g - gasleft();
        KilimBazaar.Kilim memory k = bazaar.kilim(t);
        assertEq(k.count, n0 + n1 + n2);
        assertEq(k.rank, _expectedRank(n0 + n1 + n2, 10_000));
        assertEq(bazaar.ownerOf(t), to);
        assertEq(motifs.motifsBurned(), n0 + n1 + n2);
        if (n2 == 0) assertTrue(used < 200_000);
    }

    /// @dev One kilim from the same ids, made in one call or loomed in up to three batches, is the same kilim:
    ///      count, rank, title (ties to the lower number across batches), distinct, tags and hand.
    /// forge-config: default.fuzz.runs = 96
    function testFuzzMakeAndLoomAgreeOnEveryHand(uint256 seed) public {
        uint256[] memory list = _tiedHand(seed);
        for (uint256 i; i < list.length; ++i) {
            _give(ALICE, list[i], 1);
        }
        _approve(ALICE);
        uint256 snap = vmb.snapshotState();
        uint256 t1 = _make(ALICE, list);
        KilimBazaar.Kilim memory k1 = bazaar.kilim(t1);
        (uint256[] memory n1, uint256[] memory c1) = bazaar.handOf(t1);
        vmb.revertToState(snap);
        uint256 t2 = _loomed(list, seed);
        assertEq(t1, t2);
        _sameKilim(k1, bazaar.kilim(t2));
        _sameHand(n1, c1, t2, list.length);
        // the title is the page's: most burned, lowest number among equals
        (uint256 title, uint256 distinct) = _title(_counts(list));
        assertEq(bazaar.kilim(t2).title, title);
        assertEq(bazaar.kilim(t2).distinct, distinct);
    }

    function _loomed(uint256[] memory list, uint256 seed) internal returns (uint256) {
        uint256 n = list.length;
        uint256 s1 = 10 + uint256(keccak256(abi.encode(seed, "s1"))) % (n - 9); // 10..n
        uint256 s2 = s1 + uint256(keccak256(abi.encode(seed, "s2"))) % (n - s1 + 1); // s1..n
        _deposit(ALICE, _slice(list, 0, s1));
        if (s2 > s1) _deposit(ALICE, _slice(list, s1, s2));
        return _makeFromLoom(ALICE, _slice(list, s2, n));
    }

    function _sameKilim(KilimBazaar.Kilim memory k1, KilimBazaar.Kilim memory k2) internal pure {
        assertEq(k1.count, k2.count);
        assertEq(k1.rank, k2.rank);
        assertEq(k1.number, k2.number);
        assertEq(k1.title, k2.title);
        assertEq(k1.distinct, k2.distinct);
        assertEq(k1.sealBlock, k2.sealBlock);
        assertEq(k1.flags & ~uint256(8), k2.flags & ~uint256(8)); // all but PACKED
    }

    function _sameHand(uint256[] memory n1, uint256[] memory c1, uint256 t2, uint256 n) internal view {
        (uint256[] memory n2, uint256[] memory c2) = bazaar.handOf(t2);
        assertEq(n1.length, n2.length);
        uint256 sum;
        for (uint256 i; i < n1.length; ++i) {
            assertEq(n1[i], n2[i]);
            assertEq(c1[i], c2[i]);
            sum += c1[i];
        }
        assertEq(sum, n);
    }

    /// @dev 2..20 ids for each of four motifs plus two fillers, shuffled.
    function _tiedHand(uint256 seed) internal view returns (uint256[] memory list) {
        uint256[4] memory c;
        uint256 n = 2;
        for (uint256 t; t < 4; ++t) {
            c[t] = 2 + uint256(keccak256(abi.encode(seed, t))) % (PER_MOTIF - 1);
            // make exact ties likely: half the time copy the previous motif's count
            if (t != 0 && uint256(keccak256(abi.encode(seed, "tie", t))) % 2 == 0) c[t] = c[t - 1];
            n += c[t];
        }
        list = new uint256[](n);
        uint256 k;
        for (uint256 t; t < 4; ++t) {
            for (uint256 i; i < c[t]; ++i) {
                list[k++] = pool[t][i];
            }
        }
        list[k++] = FILLER_FROM + seed % 1000;
        list[k++] = FILLER_FROM + 1000 + (seed >> 16) % 1000;
        for (uint256 i = n - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, "shuffle", i))) % (i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
    }

    // ------------------------------------------------------------ strays

    function testStraysStayOutOfEveryCountAndCannotBeUsedByAnyone() public {
        uint256[] memory alices = _fresh(ALICE, 3);
        for (uint256 i; i < 3; ++i) {
            vm.prank(ALICE);
            motifs.transferFrom(ALICE, address(bazaar), alices[i]);
        }
        assertEq(bazaar.strayMotifs(), 3);
        // others make and loom around the strays
        uint256 t1 = _make(BOB, _fresh(BOB, 10));
        _deposit(CAROL, _fresh(CAROL, 15));
        uint256 t2 = _makeFromLoom(CAROL, _fresh(CAROL, 5));
        assertEq(bazaar.strayMotifs(), 3);
        assertEq(motifs.motifsBurned(), 30);
        assertEq(bazaar.kilim(t1).count + bazaar.kilim(t2).count, 30);
        // nobody can use a stray: not its sender, not another holder, whatever the list around it
        address[3] memory callers = [ALICE, BOB, CAROL];
        for (uint256 i; i < 3; ++i) {
            uint256[] memory list = _fresh(callers[i], 10);
            list[9] = alices[i];
            vm.prank(callers[i]);
            vmb.expectRevert(
                abi.encodeWithSignature(
                    "ERC721IncorrectOwner(address,uint256,address)", callers[i], alices[i], address(bazaar)
                )
            );
            bazaar.make(list, callers[i]);
        }
        // and nobody can move it out: the Bazaar has no function that does
        vm.prank(ALICE);
        vmb.expectRevert(
            abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", ALICE, alices[0])
        );
        motifs.transferFrom(address(bazaar), ALICE, alices[0]);
        for (uint256 i; i < 3; ++i) {
            assertEq(motifs.ownerOf(alices[i]), address(bazaar));
            assertTrue(!motifs.burned(alices[i]));
        }
    }

    // ------------------------------------------------------------ hooks across contracts

    /// @dev A kilim made from inside a motif mint's receiver hook (KilimMotifs.mintMotifs, nonReentrant there,
    ///      but transferFrom and burn are not): the mint finishes, nothing is minted twice, counts agree.
    function testMakingFromInsideAMotifMintHook() public {
        MintHookMaker h = new MintHookMaker(bazaar, motifs);
        uint256 first = 700_001;
        uint256 mintedBefore = motifs.motifsMinted();
        vm.prank(address(auction));
        motifs.mintMotifs(address(h), address(h), first, 12);
        assertTrue(h.made());
        assertEq(h.gotLength(), 12);
        uint256 t = h.kilimId();
        assertEq(bazaar.ownerOf(t), address(h));
        assertEq(bazaar.kilim(t).count, 10);
        for (uint256 i; i < 10; ++i) {
            assertTrue(motifs.burned(first + i));
        }
        assertEq(motifs.ownerOf(first + 10), address(h));
        assertEq(motifs.ownerOf(first + 11), address(h));
        assertEq(motifs.motifsMinted(), mintedBefore + 12);
        assertEq(motifs.motifsBurned(), 10);
        assertEq(motifs.balanceOf(address(bazaar)), 0);
        vm.prank(address(auction));
        vmb.expectRevert(abi.encodeWithSignature("AlreadyMinted()"));
        motifs.mintMotifs(address(h), address(h), first, 1);
    }

    // ------------------------------------------------------------ informational

    /// @dev INFO BZ-3: the 1/1 predates the Bazaar, so its _update does not block it: a plain transferFrom
    ///      strands The Unwoven Kilim in the Bazaar forever (a safe transfer bounces).
    function testTheOneOfOneCanBeStrandedInTheBazaarByAPlainTransfer() public {
        assertEq(oneOfOne.ownerOf(1), WINNER);
        vm.prank(WINNER);
        vmb.expectRevert(abi.encodeWithSelector(KilimBazaar.StrayTransfer.selector));
        oneOfOne.safeTransferFrom(WINNER, address(bazaar), 1);
        vm.prank(WINNER);
        oneOfOne.transferFrom(WINNER, address(bazaar), 1);
        assertEq(oneOfOne.ownerOf(1), address(bazaar));
        // the reverse direction is blocked: a kilim cannot go to the 1/1's contract
        uint256 t = _make(ALICE, _fresh(ALICE, 10));
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSelector(KilimBazaar.InvalidRecipient.selector));
        bazaar.transferFrom(ALICE, address(oneOfOne), t);
    }

    /// @dev INFO BZ-4: "Made from the winning bid" follows the ids, not the winner: a buyer of ten of the
    ///      winner's motifs makes a tagged Apprentice, and the winner can split the range into many tagged kilims.
    function testTheWinningBidTagFollowsTheIdsAndSplits() public {
        (uint256 first, uint256 won) = auction.highestBidMotifs();
        assertEq(first, 1);
        assertEq(won, 10_000);
        _give(WINNER, first, 30);
        _approve(WINNER);
        uint256[] memory range = ids(first, 30);
        vm.startPrank(WINNER);
        for (uint256 i; i < 10; ++i) {
            motifs.transferFrom(WINNER, BOB, range[i]);
        }
        vm.stopPrank();
        _approve(BOB);
        uint256 bobs = _make(BOB, _slice(range, 0, 10));
        uint256 w1 = _make(WINNER, _slice(range, 10, 20));
        uint256 w2 = _make(WINNER, _slice(range, 20, 30));
        assertTrue(bazaar.kilim(bobs).flags & 4 != 0);
        assertTrue(bazaar.kilim(w1).flags & 4 != 0);
        assertTrue(bazaar.kilim(w2).flags & 4 != 0);
        assertEq(bazaar.kilim(bobs).rank, 1);
    }

    /// @dev INFO BZ-5: CountOverflow is unreachable at the mainnet cap. Over ids 1..1,000,000 at the planned
    ///      mainnet Motif Bazaar address, the most ids showing any one motif is far below 65,535.
    function testNoMotifCanReachALaneOverflowAtTheMainnetCap() public view {
        address planned = 0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF;
        uint256[1024] memory c;
        uint256 best;
        for (uint256 id = 1; id <= 1_000_000; ++id) {
            uint256 lane;
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 1)
                mstore(add(p, 32), planned)
                mstore(add(p, 64), id)
                lane := and(keccak256(p, 96), 1023)
            }
            uint256 v = ++c[lane];
            if (v > best) best = v;
        }
        _log(string.concat("most ids showing one motif, 1..1,000,000 on chain 1: ", vm.toString(best)));
        assertTrue(best < 1_200);
    }

    // ------------------------------------------------------------ Glamsterdam projection

    uint256 internal nextFresh;

    function _freshBuckets(address to, uint256 n) internal returns (uint256[] memory list) {
        list = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = 600_000 + (nextFresh++) * 256;
            _give(to, list[i], 1);
        }
        _approve(to);
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Runs `data` from `from` as its own transaction (everything cold), counts the storage slots it
    ///      takes from zero to nonzero in the Bazaar and Motif Bazaar, then rolls the call back.
    function _measure(address from, bytes memory data) internal returns (uint256 cancun, uint256 newSlots) {
        uint256 snap = vmb.snapshotState();
        rec.record();
        vmb.cool(address(bazaar));
        vmb.cool(address(motifs));
        vmb.cool(address(auction));
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(bazaar).call(data);
        cancun = g - gasleft();
        // a separate statement: in one expression solc evaluates _intrinsic first, inside the measurement
        cancun += _intrinsic(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        address[2] memory who = [address(bazaar), address(motifs)];
        bytes32[][2] memory slots;
        bytes32[][2] memory finals;
        for (uint256 w; w < 2; ++w) {
            (, bytes32[] memory writes) = rec.accesses(who[w]);
            slots[w] = writes;
            finals[w] = new bytes32[](writes.length);
            for (uint256 i; i < writes.length; ++i) {
                finals[w][i] = rec.load(who[w], writes[i]);
            }
        }
        vmb.revertToState(snap);
        for (uint256 w; w < 2; ++w) {
            for (uint256 i; i < slots[w].length; ++i) {
                bool seen;
                for (uint256 j; j < i; ++j) {
                    if (slots[w][j] == slots[w][i]) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                if (rec.load(who[w], slots[w][i]) == 0 && finals[w][i] != 0) ++newSlots;
            }
        }
    }

    function _project(string memory what, uint256 cancun, uint256 newSlots) internal view returns (uint256 total) {
        uint256 state = newSlots * 97_920;
        // EIP-8037/8038: a new slot is 97,920 state gas + about 12,100 execution, against 22,100 on Cancun.
        total = cancun - newSlots * 10_000 + state;
        _log(
            string.concat(
                what,
                ": Cancun ",
                vm.toString(cancun),
                ", new slots ",
                vm.toString(newSlots),
                ", state gas ",
                vm.toString(state),
                ", projected tx.gas ~",
                vm.toString(total)
            )
        );
    }

    /// @dev INFO BZ-1: the site's "300 ids per call always fit" rule under Glamsterdam (EIP-8037). Every new
    ///      slot costs 97,920 state gas and tx.gas must fit the block's remaining state gas (60M on mainnet).
    function testFullMakesProjectedUnderGlamsterdam() public {
        uint256[] memory fresh300 = _freshBuckets(ALICE, 300);
        (uint256 c1, uint256 s1) = _measure(ALICE, abi.encodeCall(KilimBazaar.make, (fresh300, ALICE)));
        uint256 p1 = _project("make 300, every id a fresh _burned bucket", c1, s1);
        (uint256 c2, uint256 s2) = _measure(ALICE, abi.encodeCall(KilimBazaar.deposit, (fresh300)));
        uint256 p2 = _project("deposit 300 fresh-bucket ids, opening a loom", c2, s2);
        uint256[] memory market = _fresh(BOB, 300);
        (uint256 c3, uint256 s3) = _measure(BOB, abi.encodeCall(KilimBazaar.make, (market, BOB)));
        uint256 p3 = _project("make 300 consecutive ids", c3, s3);
        uint256[] memory fresh150 = _slice(fresh300, 0, 150);
        (uint256 c4, uint256 s4) = _measure(ALICE, abi.encodeCall(KilimBazaar.make, (fresh150, ALICE)));
        uint256 p4 = _project("make 150, every id a fresh _burned bucket", c4, s4);
        // On Cancun the worst 300 fits the 2^24 transaction cap ...
        assertTrue(c1 < 16_777_216);
        // ... under Glamsterdam it needs a gas limit far above 2^24 (wallets that cap estimates fail) and
        // most of a 60M mainnet block's state budget.
        assertTrue(p1 > 16_777_216 && p2 > 16_777_216);
        assertTrue(p1 < 60_000_000 && p2 < 60_000_000);
        assertTrue(p3 < p1 && p4 < p1);
    }
}

/// @notice The settlement gate: a hostile winner cannot keep the Bazaar closed.
contract BazaarGateAuditTest is BazaarBase {
    function setUp() public {
        vm.warp(1_800_000_000);
        _standard();
    }

    function _hostileClose(uint8 mode) internal {
        HostileWinner h = new HostileWinner(mode);
        _openBidding(auction);
        vm.deal(address(h), 0.05 ether);
        h.bid(auction, 0.05 ether);
        uint256[] memory list = _fresh(ALICE, 10);
        // closed before settlement, whatever the holder does
        vm.prank(ALICE);
        vmb.expectRevert(abi.encodeWithSelector(KilimBazaar.NotSettled.selector));
        bazaar.make(list, ALICE);
        vm.warp(auction.endsAt());
        auction.settle{gas: 3_000_000}();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        (, bool open) = bazaar.ladder();
        assertTrue(open);
        assertEq(bazaar.masterCost(), 50);
        uint256 t = _make(ALICE, list);
        assertEq(bazaar.kilim(t).rank, 1);
    }

    function testARevertingWinnerCannotKeepTheBazaarClosed() public {
        _hostileClose(0);
    }

    function testAGasBurningWinnerCannotKeepTheBazaarClosed() public {
        _hostileClose(1);
    }

    function testAReturnBombingWinnerCannotKeepTheBazaarClosed() public {
        _hostileClose(2);
    }
}

/// @notice Ranks against the page's rule at any close, through a stand-in auction that can settle anywhere.
contract BazaarRankAuditTest is BazaarBase {
    FakeAuction internal fake;
    KilimMotifs internal fm;
    KilimBazaar internal fb;

    function setUp() public {
        vm.warp(1_800_000_000);
        pageDir = FIXTURE_PAGE;
        pageHead = _pageFile("head.bin");
        fake = new FakeAuction();
        fm = newMotifs(address(fake), TREASURY, 1000);
        KilimOneOfOne o = new KilimOneOfOne(
            address(fake), TREASURY, fm, pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin")),
            ONE_OF_ONE_NAME, DESCRIPTION, ""
        );
        fake.setTokens(fm, o);
        fb = new KilimBazaar(KilimAuction(address(fake)), ARTIST, o.tailHash(), BAZAAR_DESCRIPTION, "", "");
    }

    function _ladderRank(uint256 count) internal view returns (uint256) {
        (uint256[6] memory costs, bool open) = fb.ladder();
        assertTrue(open);
        if (count < 10) return 0;
        if (count >= costs[5]) return 6;
        for (uint256 r = 5; r >= 1; --r) {
            if (costs[r - 1] != 0 && count >= costs[r - 1]) return r;
        }
        return 0;
    }

    function testFuzzRankForMatchesThePageRuleAndTheLadder(uint64 units, uint256 count, uint8 pick) public {
        uint256 top = 10 + uint256(units) % 5_000_000;
        fake.settle(top * 1e15, 0, 0);
        assertEq(fb.masterCost(), top);
        uint256[9] memory near = [top - 1, top, top + 1, 9, 10, 29, 30, 999, 1000];
        if (pick % 2 == 0) count = near[pick % 9];
        else count = count % (top * 2 + 2_000);
        uint8 r = fb.rankFor(count);
        assertEq(r, _expectedRank(count, top));
        assertEq(r, _ladderRank(count));
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzzMadeKilimsTakeTheRankAtTheMastersEdge(uint8 units) public {
        uint256 top = 10 + uint256(units) % 40; // 10..49
        fake.settle(top * 1e15, 0, 0);
        uint256 next = 1;
        uint256[2] memory sizes = [top > 10 ? top - 1 : 10, top];
        for (uint256 s; s < 2; ++s) {
            uint256 n = sizes[s];
            vm.prank(address(fake));
            fm.mintMotifs(ALICE, ALICE, next, n);
            uint256[] memory list = ids(next, n);
            next += n;
            vm.prank(ALICE);
            fm.setApprovalForAll(address(fb), true);
            vm.prank(ALICE);
            uint256 t = fb.make(list, ALICE);
            assertEq(fb.kilim(t).rank, _expectedRank(n, top));
        }
    }
}
