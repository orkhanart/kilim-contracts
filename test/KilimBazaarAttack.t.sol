// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {BazaarBase} from "./bazaar/BazaarBase.sol";

/// @dev A kilim recipient that calls back into the Bazaar while the kilim arrives, and looks around:
///      the loom it came from, the kilim's seal state and its tokenURI. `bubble` turns a failed inner call
///      into the hook's own revert.
contract ReenteringReceiver is IERC721Receiver {
    KilimBazaar public bazaar;
    bytes public payload;
    bool public bubble;
    bool public innerOk;
    bytes public innerRevert;
    uint256 public loomKeySeen = type(uint256).max;
    uint8 public sealStateSeen;
    uint256 public uriBytesSeen;
    address public operatorSeen;

    function configure(KilimBazaar bazaar_, bytes calldata payload_, bool bubble_) external {
        bazaar = bazaar_;
        payload = payload_;
        bubble = bubble_;
    }

    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        operatorSeen = operator;
        (bool ok, bytes memory data) = address(bazaar).call(payload);
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
        innerOk = ok;
        innerRevert = data;
        loomKeySeen = bazaar.loomOf(operator).handKey;
        sealStateSeen = bazaar.sealState(tokenId);
        uriBytesSeen = bytes(bazaar.tokenURI(tokenId)).length;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice The attack surface: re-entry through the only outgoing hook into each write, strays by safe and
///         plain transfer, a front-run sale, operators and approvals used through the Bazaar, and attempts to
///         preview or re-roll a seed.
contract KilimBazaarAttackTest is BazaarBase {
    uint256 internal constant B = 4_000_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
        _standard();
        _settle(10 ether);
    }

    function _payloads(uint256[] memory list) internal view returns (bytes[4] memory p) {
        p[0] = abi.encodeCall(KilimBazaar.make, (list, address(this)));
        p[1] = abi.encodeCall(KilimBazaar.deposit, (list));
        p[2] = abi.encodeCall(KilimBazaar.makeFromLoom, (list, address(this)));
        p[3] = abi.encodeCall(KilimBazaar.seal, (ids(1, 1)));
    }

    /// @dev Every write re-entered from the hook reverts ReentrancyGuardReentrantCall; bubbled, the whole
    ///      kilim reverts with it and nothing is burned.
    function testReenteringEachWriteFromTheHookReverts() public {
        uint256[] memory list = _fresh(ALICE, 10);
        bytes[4] memory payloads = _payloads(list);
        for (uint256 i; i < payloads.length; ++i) {
            ReenteringReceiver r = new ReenteringReceiver();
            r.configure(bazaar, payloads[i], true);
            uint256 snap = vmb.snapshotState();
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
            bazaar.make(list, address(r));
            vmb.revertToState(snap);
        }
        assertEq(motifs.motifsBurned(), 0);
        assertEq(bazaar.totalSupply(), 0);
    }

    /// @dev Swallowed, the inner call fails the same way, and the hook sees a finished record: the loom
    ///      already deleted, the kilim waiting for its seal (no seed to judge), its tokenURI readable.
    function testTheHookSeesAFinishedRecordAndNoSeed() public {
        _deposit(ALICE, _fresh(ALICE, 12));
        uint256[] memory extra = _fresh(ALICE, 3);
        ReenteringReceiver r = new ReenteringReceiver();
        r.configure(bazaar, abi.encodeCall(KilimBazaar.deposit, (extra)), false);
        vm.prank(ALICE);
        uint256 tokenId = bazaar.makeFromLoom(new uint256[](0), address(r));
        assertTrue(!r.innerOk());
        assertEq(
            keccak256(r.innerRevert()), keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"))
        );
        assertEq(r.operatorSeen(), ALICE);
        assertEq(r.loomKeySeen(), 0);
        assertEq(r.sealStateSeen(), 1);
        assertTrue(r.uriBytesSeen() > 0);
        assertEq(bazaar.ownerOf(tokenId), address(r));
        assertEq(bazaar.kilim(tokenId).count, 12);
        assertEq(motifs.balanceOf(ALICE), 3);
    }

    /// @dev Nobody can make a kilim with someone else's motifs, even with an operator approval on Motif Bazaar,
    ///      and a standing approval to the Bazaar cannot be used by a third party.
    function testApprovalsCannotBeUsedThroughTheBazaar() public {
        uint256[] memory alices = _fresh(ALICE, 10);
        vm.prank(ALICE);
        motifs.setApprovalForAll(CAROL, true);
        vm.startPrank(CAROL);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", CAROL, alices[0], ALICE)
        );
        bazaar.make(alices, CAROL);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", CAROL, alices[0], ALICE)
        );
        bazaar.deposit(alices);
        vm.stopPrank();
        assertEq(motifs.balanceOf(ALICE), 10);
        assertEq(bazaar.loomOf(CAROL).handKey, 0);
        assertEq(bazaar.loomOf(ALICE).handKey, 0);
    }

    /// @dev A motif sold (moved) before the make lands makes only that make revert; the buyer keeps it.
    function testAFrontRunSaleRevertsOnlyThatCall() public {
        uint256[] memory list = _fresh(ALICE, 10);
        vm.prank(ALICE);
        motifs.transferFrom(ALICE, BOB, list[3]);
        // the buyer has not approved the Bazaar: refused at the approval
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", address(bazaar), list[3])
        );
        bazaar.make(list, ALICE);
        // the buyer has: refused at the owner, since the Bazaar only ever takes from the caller
        _approve(BOB);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", ALICE, list[3], BOB)
        );
        bazaar.make(list, ALICE);
        assertEq(motifs.ownerOf(list[3]), BOB);
        assertEq(motifs.balanceOf(ALICE), 9);
        // the rest plus another still make a kilim
        uint256[] memory more = _fresh(ALICE, 1);
        list[3] = more[0];
        assertEq(_make(ALICE, list), 1);
    }

    function testAPlainStrayCanNeverBeDepositedOrWoven() public {
        uint256[] memory list = _fresh(ALICE, 11);
        vm.prank(ALICE);
        motifs.transferFrom(ALICE, address(bazaar), list[10]);
        _deposit(ALICE, _slice(list, 0, 10));
        uint256[] memory stray = _slice(list, 10, 11);
        // not by its sender, not by anyone
        address[3] memory callers = [ALICE, BOB, address(bazaar)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert();
            bazaar.deposit(stray);
        }
        vm.prank(ALICE);
        vm.expectRevert();
        bazaar.makeFromLoom(stray, ALICE);
        assertEq(bazaar.strayMotifs(), 1);
        assertEq(bazaar.loomOf(ALICE).count, 10);
    }

    /// @dev Nothing about the seed exists when the kilim is minted, and a seal is the same for every caller.
    ///      No re-arm can be forced before the window ends, and a sealed kilim never re-arms.
    function testTheSeedCannotBePreviewedOrReRolled() public {
        uint256 tokenId = _make(ALICE, _fresh(ALICE, 10));
        assertEq(bazaar.kilim(tokenId).seed, 0);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.NotSealed.selector, tokenId));
        bazaar.pieceOf(tokenId);
        // the seal block is the next one: its hash does not exist yet
        assertEq(bazaar.kilim(tokenId).sealBlock, block.number + 1);
        assertEq(blockhash(block.number + 1), bytes32(0));
        // within the window every attempt either waits or seals; none re-arms
        for (uint256 age = 0; age <= 256; age += 64) {
            vm.roll(B + 1 + age);
            assertTrue(bazaar.sealState(tokenId) != 3);
        }
        vm.roll(B + 1 + 256);
        vmb.setBlockhash(B + 1, bytes32(0)); // a missing hash only skips
        assertEq(bazaar.seal(ids(tokenId, 1)), 0);
        assertEq(bazaar.kilim(tokenId).sealBlock, B + 1);
        vmb.setBlockhash(B + 1, keccak256("h"));
        vm.prank(BOB); // anyone
        assertEq(bazaar.seal(ids(tokenId, 1)), 1);
        uint256 seed = bazaar.kilim(tokenId).seed;
        vm.roll(B + 100_000);
        assertEq(bazaar.seal(ids(tokenId, 1)), 0);
        assertEq(bazaar.kilim(tokenId).seed, seed);
        assertEq(bazaar.kilim(tokenId).sealBlock, B + 1);
    }

    /// @dev Sealing never reverts on what it is handed, so nobody can block the site's batch.
    function testSealNeverRevertsOnJunk() public {
        _make(ALICE, _fresh(ALICE, 10));
        uint256[] memory junk = new uint256[](5);
        junk[0] = 0;
        junk[1] = type(uint256).max;
        junk[2] = 2;
        junk[3] = 1;
        junk[4] = 1;
        assertEq(bazaar.seal(junk), 0); // all waiting or unknown
        vm.roll(B + 2);
        assertEq(bazaar.seal(junk), 1);
    }

    /// @dev Burned ids stay burned: the Bazaar holds nothing between calls and nothing can mint them again.
    function testBurnedIdsCanNeverComeBack() public {
        uint256[] memory list = _fresh(ALICE, 10);
        _make(ALICE, list);
        vm.prank(address(auction));
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        motifs.mintMotifs(ALICE, ALICE, list[0], 1);
        assertEq(motifs.balanceOf(address(bazaar)), 0);
    }
}
