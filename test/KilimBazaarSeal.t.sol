// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase, VmBazaar} from "./bazaar/BazaarBase.sol";

/// @notice Sealing the seed: skipped until the seal block is mined, the BLOCKHASH path up to 256 blocks, the
///         EIP-2935 history path up to 8,191, the re-arm decided by block numbers alone (with and without
///         the history contract), a failing lookup that only skips, the seed formula for any caller at any
///         block in the window, batches with junk, and the events.
contract KilimBazaarSealTest is BazaarBase {
    event SeedRearmed(uint256 indexed tokenId, uint256 sealBlock);
    event KilimSealed(uint256 indexed tokenId, bytes32 blockHash, uint256 seed);
    event MetadataUpdate(uint256 _tokenId);

    uint256 internal constant B = 1_000_000;
    bytes32 internal constant H = keccak256("the hash of block B+1");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
    }

    /// @dev The Bazaar with the history contract etched first (seedWindow 8,191), or without it (256).
    function _open(bool withHistory) internal {
        if (withHistory) vmb.etch(HISTORY, HISTORY_CODE);
        _deployBazaar();
        assertEq(bazaar.seedWindow(), withHistory ? 8191 : 256);
        _settle(10 ether);
        vm.roll(B);
    }

    function _seed(bytes32 h, uint256 id) internal view returns (uint256) {
        return uint32(uint256(keccak256(abi.encode(h, address(bazaar), id))));
    }

    function _one() internal returns (uint256) {
        return _make(ALICE, _fresh(ALICE, 10));
    }

    function _list(uint256 a) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }

    /// @dev Sets the hash the history contract serves for block n (its ring buffer slot).
    function _history(uint256 n, bytes32 h) internal {
        vmb.store(HISTORY, bytes32(n % 8191), h);
    }

    // ------------------------------------------------------------ the windows

    function testSkippedInTheBlockMadeAndTheNextThenSealedFromBPlus2() public {
        _open(false);
        uint256 id = _one();
        assertEq(bazaar.kilim(id).sealBlock, B + 1);
        assertEq(bazaar.sealState(id), 1);
        assertEq(bazaar.seal(_list(id)), 0);
        vm.roll(B + 1);
        assertEq(bazaar.sealState(id), 1);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).flags & bazaar.SEALED(), 0);
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        assertEq(bazaar.sealState(id), 2);
        assertEq(bazaar.seal(_list(id)), 1);
        KilimBazaar.Kilim memory k = bazaar.kilim(id);
        assertEq(k.seed, _seed(H, id));
        assertTrue(k.flags & bazaar.SEALED() != 0);
        assertEq(k.sealBlock, B + 1);
        assertEq(bazaar.sealState(id), 4);
    }

    function testTheBlockhashPathAtTheEndOfItsWindow() public {
        _open(false);
        uint256 id = _one();
        vm.roll(B + 257); // age 256
        vmb.setBlockhash(B + 1, H);
        assertEq(bazaar.sealState(id), 2);
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(bazaar.kilim(id).seed, _seed(H, id));
    }

    function testWithoutHistoryAKilimReArmsAfter256Blocks() public {
        _open(false);
        uint256 id = _one();
        vm.roll(B + 258); // age 257
        assertEq(bazaar.sealState(id), 3);
        vm.expectEmit();
        emit SeedRearmed(id, B + 259);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).sealBlock, B + 259);
        assertEq(bazaar.kilim(id).flags & bazaar.SEALED(), 0);
        assertEq(bazaar.sealState(id), 1);
        // sealed from the new block's hash
        vm.roll(B + 260);
        vmb.setBlockhash(B + 259, H);
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(bazaar.kilim(id).seed, _seed(H, id));
    }

    function testTheHistoryPathAtAges300And8191() public {
        _open(true);
        uint256 id = _one();
        uint256 snap = vmb.snapshotState();
        vm.roll(B + 1 + 300);
        _history(B + 1, H);
        assertEq(bazaar.sealState(id), 2);
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(bazaar.kilim(id).seed, _seed(H, id));
        vmb.revertToState(snap);
        vm.roll(B + 1 + 8191);
        _history(B + 1, H);
        assertEq(bazaar.sealState(id), 2);
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(bazaar.kilim(id).seed, _seed(H, id));
    }

    /// @dev Inside the BLOCKHASH window the history contract is never asked: a different hash stored there
    ///      changes nothing.
    function testTheBlockhashPathIsUsedWhereItCanBe() public {
        _open(true);
        uint256 id = _one();
        vm.roll(B + 100);
        vmb.setBlockhash(B + 1, H);
        _history(B + 1, keccak256("another"));
        bazaar.seal(_list(id));
        assertEq(bazaar.kilim(id).seed, _seed(H, id));
    }

    function testReArmAt8192ThenSealOneBlockAfterAndASecondLapseReArmsAgain() public {
        _open(true);
        uint256 id = _one();
        vm.roll(B + 1 + 8192);
        _history(B + 1, H); // even a readable hash does not matter past the window
        assertEq(bazaar.sealState(id), 3);
        uint256 rearmed = block.number + 1;
        vm.expectEmit();
        emit SeedRearmed(id, rearmed);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).sealBlock, rearmed);
        uint256 snap = vmb.snapshotState();
        // one block after the new seal block
        vm.roll(rearmed);
        assertEq(bazaar.seal(_list(id)), 0);
        vm.roll(rearmed + 1);
        bytes32 h2 = keccak256("the hash of the re-armed block");
        vmb.setBlockhash(rearmed, h2);
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(bazaar.kilim(id).seed, _seed(h2, id));
        vmb.revertToState(snap);
        // a second lapse re-arms again
        vm.roll(rearmed + 8192);
        assertEq(bazaar.sealState(id), 3);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).sealBlock, rearmed + 8193);
    }

    function testAReArmIsAnEventOnlyAndNotAMetadataUpdate() public {
        _open(false);
        uint256 id = _one();
        vm.roll(B + 1000);
        vmb.recordLogs();
        bazaar.seal(_list(id));
        VmBazaar.Log[] memory logs = vmb.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], SeedRearmed.selector);
        assertEq(logs[0].emitter, address(bazaar));
    }

    // ------------------------------------------------------------ lookups that fail

    /// @dev A history call that fails inside the window skips: no state change and never a re-arm, so no
    ///      caller can force one while the window lasts.
    function testAFailingHistoryCallSkipsAndNeverReArms() public {
        _open(true);
        uint256 id = _one();
        vmb.etch(HISTORY, hex"5f5ffd"); // always reverts
        vm.roll(B + 1 + 300);
        KilimBazaar.Kilim memory before = bazaar.kilim(id);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(keccak256(abi.encode(bazaar.kilim(id))), keccak256(abi.encode(before)));
        assertEq(bazaar.sealState(id), 2);
        vm.roll(B + 1 + 8191);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(keccak256(abi.encode(bazaar.kilim(id))), keccak256(abi.encode(before)));
        // only the window's end re-arms
        vm.roll(B + 1 + 8192);
        bazaar.seal(_list(id));
        assertEq(bazaar.kilim(id).sealBlock, B + 1 + 8193);
    }

    function testAnEmptyOrMisshapenHistoryAnswerSkips() public {
        _open(true);
        uint256 id = _one();
        vm.roll(B + 1 + 500);
        // nothing stored for that block: the canonical contract answers zero
        assertEq(bazaar.seal(_list(id)), 0);
        // an answer of 64 bytes
        vmb.etch(HISTORY, hex"60406000f3"); // return(0, 64)
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).flags & bazaar.SEALED(), 0);
    }

    function testAZeroBlockhashSkips() public {
        _open(false);
        uint256 id = _one();
        vm.roll(B + 10);
        vmb.setBlockhash(B + 1, bytes32(0));
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).sealBlock, B + 1);
        assertEq(bazaar.sealState(id), 2);
    }

    // ------------------------------------------------------------ the seed

    function testTheSeedIsTheSameForAnyCallerAtAnyBlockInTheWindow() public {
        _open(true);
        uint256 id = _one();
        uint256 snap = vmb.snapshotState();
        uint256[4] memory ages = [uint256(1), 256, 257, 8191];
        address[4] memory callers = [ALICE, BOB, CAROL, address(0xDEAD)];
        for (uint256 i; i < ages.length; ++i) {
            vmb.revertToState(snap);
            vm.roll(B + 1 + ages[i]);
            vmb.setBlockhash(B + 1, H);
            _history(B + 1, H);
            vm.prank(callers[i]);
            assertEq(bazaar.seal(_list(id)), 1);
            assertEq(bazaar.kilim(id).seed, _seed(H, id));
        }
    }

    function testTwoKilimsFromOneBlockGetDifferentSeeds() public {
        _open(false);
        uint256 a = _one();
        uint256 b = _make(BOB, _fresh(BOB, 10));
        assertEq(bazaar.kilim(a).sealBlock, bazaar.kilim(b).sealBlock);
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        uint256[] memory both = new uint256[](2);
        both[0] = a;
        both[1] = b;
        assertEq(bazaar.seal(both), 2);
        assertTrue(bazaar.kilim(a).seed != bazaar.kilim(b).seed);
        assertEq(bazaar.kilim(a).seed, _seed(H, a));
        assertEq(bazaar.kilim(b).seed, _seed(H, b));
    }

    function testABatchWithJunkUnknownAndSealedIdsSealsTheRest() public {
        _open(false);
        uint256 a = _one();
        uint256 b = _one();
        uint256 c = _one();
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        uint256[] memory first = new uint256[](3);
        first[0] = 0;
        first[1] = 999;
        first[2] = a;
        assertEq(bazaar.seal(first), 1);
        uint256[] memory second = new uint256[](6);
        second[0] = a; // sealed
        second[1] = b;
        second[2] = b; // twice
        second[3] = type(uint256).max;
        second[4] = c;
        second[5] = 4; // not made yet
        assertEq(bazaar.seal(second), 2);
        assertEq(bazaar.seal(second), 0);
        assertEq(bazaar.seal(new uint256[](0)), 0);
        assertEq(bazaar.kilim(c).seed, _seed(H, c));
    }

    function testSealingEmitsKilimSealedAndMetadataUpdate() public {
        _open(false);
        uint256 id = _one();
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        vm.expectEmit();
        emit KilimSealed(id, H, _seed(H, id));
        vm.expectEmit();
        emit MetadataUpdate(id);
        bazaar.seal(_list(id));
    }

    /// @dev Once sealed, nothing changes the record again: no later call re-arms or re-seals it.
    function testASealedKilimIsFinal() public {
        _open(true);
        uint256 id = _one();
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        vm.prank(CAROL);
        bazaar.seal(_list(id));
        KilimBazaar.Kilim memory sealedRecord = bazaar.kilim(id);
        vm.roll(B + 100_000);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(keccak256(abi.encode(bazaar.kilim(id))), keccak256(abi.encode(sealedRecord)));
        assertEq(bazaar.sealState(id), 4);
        // moving it does not touch the record either
        vm.prank(ALICE);
        bazaar.transferFrom(ALICE, BOB, id);
        assertEq(keccak256(abi.encode(bazaar.kilim(id))), keccak256(abi.encode(sealedRecord)));
    }

    function testPieceOfIsTheSealedPiece() public {
        _open(false);
        uint256 id = _make(ALICE, _fresh(ALICE, 41));
        vm.roll(B + 2);
        vmb.setBlockhash(B + 1, H);
        bazaar.seal(_list(id));
        bytes memory s = _expectedPiece(id);
        assertEq(bazaar.pieceOf(id), string(_sub(s, 20, s.length)));
        assertTrue(_startsWith(bytes(bazaar.pieceOf(id)), '{"seed":"0x'));
        assertEq(vmb.parseJsonString(bazaar.pieceOf(id), ".seed"), _hex8(_seed(H, id)));
        assertEq(vmb.parseJsonUint(bazaar.pieceOf(id), ".top"), 10_000);
    }
}
