// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestBase} from "./TestBase.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";

interface VmX {
    function etch(address, bytes calldata) external;
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function record() external;
    function accesses(address) external returns (bytes32[] memory reads, bytes32[] memory writes);
    function load(address, bytes32) external view returns (bytes32);
}

/// @dev A wallet that answers ETH and NFTs with a chosen attack: a large return buffer, a large
///      revert buffer, or a list of calls back into the auction.
contract HostileWallet is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256 public bombOnEth; // bytes returned (odd mode) or reverted (even mode) on receiving ETH
    bool public revertOnEth;
    uint256 public bombOnNft; // bytes reverted from the NFT hook
    bool public wrongSelector;
    bytes[] private payloads;
    uint256 public succeeded;

    constructor(KilimAuction a) {
        auction = a;
    }

    function setEth(uint256 size, bool revert_) external {
        bombOnEth = size;
        revertOnEth = revert_;
    }

    function setNft(uint256 size, bool wrongSelector_) external {
        bombOnNft = size;
        wrongSelector = wrongSelector_;
    }

    function arm(bytes[] calldata calls) external {
        delete payloads;
        for (uint256 i; i < calls.length; ++i) {
            payloads.push(calls[i]);
        }
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function run(bytes calldata data) external returns (bool ok) {
        (ok,) = address(auction).call(data);
    }

    function _reenter() private {
        for (uint256 i; i < payloads.length; ++i) {
            (bool ok,) = address(auction).call(payloads[i]);
            if (ok) ++succeeded;
        }
    }

    receive() external payable {
        _reenter();
        uint256 size = bombOnEth;
        bool fail = revertOnEth;
        assembly ("memory-safe") {
            if fail { revert(0, size) }
            return(0, size)
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _reenter();
        uint256 size = bombOnNft;
        if (size != 0) {
            assembly ("memory-safe") {
                revert(0, size)
            }
        }
        return wrongSelector ? bytes4(0xdeadbeef) : IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Code a delegated EOA might point at: accepts ETH, has no NFT hook and no ERC-1271.
contract PlainDelegate {
    receive() external payable {}
}

/// @dev Code that refuses ETH.
contract RefusingDelegate {
    receive() external payable {
        revert("no");
    }
}

/// @dev ERC-1271 wallets that misbehave. Mode 0 valid, 1 burns all gas, 2 returns 31 bytes, 3 returns
///      the wrong value, 4 returns a megabyte, 5 reverts, 6 is valid only while `open` is set.
contract Odd1271 {
    uint8 public immutable mode;
    bool public open = true;

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function shut() external {
        open = false;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        uint8 m = mode;
        if (m == 1) while (gasleft() > 0) {}
        if (m == 2) {
            assembly ("memory-safe") {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 31)
            }
        }
        if (m == 3) return 0xffffffff;
        if (m == 4) {
            assembly ("memory-safe") {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 1000000)
            }
        }
        if (m == 5) revert("no");
        if (m == 6 && !open) return 0xffffffff;
        return 0x1626ba7e;
    }
}

/// @dev One transaction that fills every registration slot with one 0.01 ETH float.
contract SybilChild {
    constructor(KilimAuction a) payable {
        a.register();
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }
}

contract SybilFactory {
    function run(KilimAuction a, uint256 count) external payable {
        for (uint256 i; i < count; ++i) {
            new SybilChild{value: 0.01 ether}(a);
        }
    }

    receive() external payable {}
}

/// @notice Attack patterns from the October 2026 research report (reports/Auction contract attack
///         patterns 2026.md) that had no test of their own. Item numbers refer to its checklist.
contract AttackPatternsTest is TestBase {
    VmX private constant vmx = VmX(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    // Glamsterdam as scheduled (EIP-8037, EIP-8038): what one storage write costs more than today.
    uint256 private constant NEW_SLOT_EXTRA = 110_020 - 22_100;
    uint256 private constant UPDATE_EXTRA = 12_100 - 5_000;
    // KilimAuction's PRIZE_GAS: the gas settlement gives the 1/1's delivery to the winner.
    uint256 private constant PRIZE_GAS = 1_000_000;

    KilimAuction internal auction;
    KilimMotifs internal nft;

    function setUp() public {
        auction = new KilimAuction(config());
        nft = auction.motifs();
        _openBidding(auction);
        _fund(ALICE, 1000 ether);
        _fund(BOB, 1000 ether);
        _fund(CAROL, 1000 ether);
    }

    function _wallet() private returns (HostileWallet w) {
        w = new HostileWallet(auction);
        _fund(address(w), 100 ether);
    }

    function _bidWithGas(address who, uint256 amount, uint256 gasLimit) private returns (bool ok) {
        vm.prank(who);
        (ok,) =
            address(auction).call{value: amount, gas: gasLimit}(abi.encodeCall(auction.bid, (amount, 0, 0)));
    }

    /// @dev The smallest gas limit at which `who`'s bid succeeds in the current state.
    function _estimateBid(address who, uint256 amount) private returns (uint256 hi) {
        uint256 lo = 21_000;
        hi = 3_000_000;
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _bidWithGas(who, amount, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _estimateSettle() private returns (uint256 hi) {
        uint256 lo = 21_000;
        hi = 3_000_000;
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{gas: mid}(abi.encodeCall(auction.settle, ()));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    // ---- A1: only the credited address withdraws its deferred refund, once ----

    function testFuzzOnlyTheCreditedAddressWithdrawsItsRefund(address thief, address to) public {
        HostileWallet leader = _wallet();
        leader.setEth(0, true);
        leader.bid(RESERVE);
        _bid(auction, ALICE, auction.minimumBid());
        assertEq(auction.refunds(address(leader)), RESERVE);
        if (thief != address(leader)) {
            vm.expectRevert();
            vm.prank(thief);
            auction.withdrawRefund(to == address(0) ? thief : to);
        }
        assertEq(auction.refunds(address(leader)), RESERVE);
        assertEq(auction.refundLiability(), RESERVE);
        uint256 before = CAROL.balance;
        assertTrue(leader.run(abi.encodeCall(auction.withdrawRefund, (CAROL))));
        assertEq(CAROL.balance, before + RESERVE);
        assertEq(auction.refundLiability(), 0);
        assertTrue(!leader.run(abi.encodeCall(auction.withdrawRefund, (CAROL))));
        assertEq(address(auction).balance, auction.liabilities());
    }

    // ---- A4, A7: a return-data bomb from the outbid wallet costs a rival no more than a gas burner ----

    function testReturnBombFromTheOutbidWalletIsContained() public {
        // 200 KB is about the most the 150,000-gas refund can build.
        uint256[4] memory sizes = [uint256(1_000), 50_000, 200_000, 600_000];
        for (uint256 flavour; flavour < 2; ++flavour) {
            for (uint256 i; i < sizes.length; ++i) {
                uint256 snap = vm.snapshotState();
                HostileWallet leader = _wallet();
                leader.bid(RESERVE);
                uint256 amount = auction.minimumBid();
                // Estimated while the leader is harmless, with no margin at all.
                uint256 limit = _estimateBid(ALICE, amount);
                leader.setEth(sizes[i], flavour == 1);
                vm.prank(ALICE);
                uint256 before = gasleft();
                (bool ok,) = address(auction).call{value: amount, gas: limit}(
                    abi.encodeCall(auction.bid, (amount, 0, 0))
                );
                uint256 used = before - gasleft();
                assertTrue(ok);
                assertEq(auction.highestBidder(), ALICE);
                assertTrue(used < 320_000);
                assertEq(address(auction).balance, auction.liabilities());
                vm.revertToState(snap);
            }
        }
    }

    // ---- A5: an ordinary wallet's refund is never pushed to the pull path by a rival's gas limit ----

    function testFuzzAnOrdinaryLeaderIsRefundedOrTheBidRevertsWhole(uint256 gasLimit) public {
        gasLimit = 30_000 + gasLimit % 2_000_000;
        _bid(auction, ALICE, RESERVE);
        uint256 aliceBefore = ALICE.balance;
        uint256 amount = auction.minimumBid();
        bool ok = _bidWithGas(BOB, amount, gasLimit);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.refundLiability(), 0);
        if (ok) {
            assertEq(auction.highestBidder(), BOB);
            assertEq(ALICE.balance, aliceBefore + RESERVE);
        } else {
            assertEq(auction.highestBidder(), ALICE);
            assertEq(ALICE.balance, aliceBefore);
        }
        assertEq(address(auction).balance, auction.liabilities());
    }

    // ---- A8: no auction function can be entered from the refund callback ----

    function testNothingCanBeEnteredFromTheRefundCallback() public {
        HostileWallet w = _wallet();
        w.bid(RESERVE);
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(auction.bid, (0, 0, 0));
        calls[1] = abi.encodeCall(auction.settle, ());
        calls[2] = abi.encodeCall(auction.withdrawRefund, (address(w)));
        calls[3] = abi.encodeCall(auction.withdrawProceeds, (address(w)));
        calls[4] = abi.encodeCall(auction.claimMotifs, (1, address(w)));
        calls[5] = abi.encodeCall(auction.claimPrize, (address(w)));
        calls[6] = abi.encodeCall(auction.register, ());
        calls[7] = abi.encodeCall(auction.registerFor, (address(w), type(uint256).max, ""));
        calls[8] = abi.encodeCall(auction.payOutbidRefund, (address(w), 1 ether));
        calls[9] = abi.encodeCall(auction.deliverPrize, ());
        w.arm(calls);
        uint256 credits = auction.motifCredits(address(w));
        uint256 before = address(w).balance;
        _bid(auction, ALICE, auction.minimumBid());
        assertEq(w.succeeded(), 0);
        assertEq(address(w).balance, before + RESERVE);
        assertEq(auction.motifCredits(address(w)), credits);
        assertEq(address(auction).balance, auction.liabilities());
        // claimMotifs is valid for this wallet outside the callback: it failed above on the guard.
        assertTrue(w.run(calls[4]));
    }

    // ---- A9: a refund sent to an unusual address pays once or leaves the credit untouched ----

    function testRefundToUnusualRecipients() public {
        HostileWallet leader = _wallet();
        leader.setEth(0, true);
        leader.bid(RESERVE);
        _bid(auction, ALICE, auction.minimumBid());
        address[5] memory odd =
            [address(nft), address(new RefusingDelegate()), address(1), address(4), address(0x100)];
        for (uint256 i; i < odd.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 before = odd[i].balance;
            bool ok = leader.run(abi.encodeCall(auction.withdrawRefund, (odd[i])));
            if (ok) {
                assertEq(odd[i].balance, before + RESERVE);
                assertEq(auction.refunds(address(leader)), 0);
            } else {
                assertEq(odd[i].balance, before);
                assertEq(auction.refunds(address(leader)), RESERVE);
            }
            assertEq(address(auction).balance, auction.liabilities());
            vm.revertToState(snap);
        }
        // The collection and a contract that refuses ETH cannot be paid; the credit survives.
        assertTrue(!leader.run(abi.encodeCall(auction.withdrawRefund, (address(nft)))));
        assertEq(auction.refunds(address(leader)), RESERVE);
    }

    // ---- A11, D25: a wallet that gains code after bidding (EIP-7702) cannot block anything ----

    function testAWalletThatGainsCodeAfterBiddingCannotBlockBidsOrSettlement() public {
        _bid(auction, ALICE, RESERVE);
        // Alice delegates to code that refuses ETH after she has bid.
        vmx.etch(ALICE, address(new RefusingDelegate()).code);
        uint256 amount = auction.minimumBid();
        _bid(auction, BOB, amount);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.refunds(ALICE), RESERVE);
        // She still controls the address and sends the refund elsewhere.
        vm.prank(ALICE);
        auction.withdrawRefund(CAROL);
        assertEq(auction.refunds(ALICE), 0);
        // Her address now has code with no NFT hook, so it cannot take her motifs. The claim to herself
        // reverts and keeps the credits; the same claim to another address goes through.
        uint256 credits = auction.motifCredits(ALICE);
        assertEq(credits, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, ALICE));
        vm.prank(ALICE);
        auction.claimMotifs(credits, ALICE);
        assertEq(auction.motifCredits(ALICE), credits);
        assertEq(nft.motifsMinted(), 0);
        vm.prank(ALICE);
        auction.claimMotifs(credits, CAROL);
        assertEq(nft.balanceOf(CAROL), credits);
        assertEq(auction.motifCredits(ALICE), 0);

        // Bob, the winner, delegates to code with no NFT hook before settlement.
        vmx.etch(BOB, address(new PlainDelegate()).code);
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(BOB);
        auction.settle();
        assertTrue(auction.settled());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        // He claims it to an address that can hold it.
        vm.prank(BOB);
        auction.claimPrize(CAROL);
        assertEq(auction.oneOfOne().ownerOf(1), CAROL);
        assertEq(address(auction).balance, auction.liabilities());
    }

    // ---- B13, B14: fifty bids in the closing window, and the closing second itself ----

    function testFiftyLastWindowBidsEachMoveTheCloseByExactlyTheWindow() public {
        _bid(auction, ALICE, RESERVE);
        uint64 window = auction.extensionWindow();
        for (uint256 i; i < 50; ++i) {
            vm.warp(auction.endsAt() - 1);
            vm.expectRevert(EnglishAuction.AuctionNotEnded.selector);
            auction.settle();
            _bid(auction, i % 2 == 0 ? BOB : ALICE, auction.minimumBid());
            assertEq(auction.endsAt(), block.timestamp + window);
        }
        // At the close exactly: no bid, only settlement.
        vm.warp(auction.endsAt());
        uint256 minimum = auction.minimumBid();
        vm.expectRevert(EnglishAuction.AuctionNotOpen.selector);
        _bid(auction, CAROL, minimum);
        auction.settle();
        vm.expectRevert(EnglishAuction.AuctionNotOpen.selector);
        _bid(auction, CAROL, minimum);
        assertEq(address(auction).balance, auction.liabilities());
    }

    // ---- C19: what the self-outbid ladder is worth (accepted by the artist; recorded, not prevented) ----

    function testSelfOutbidLadderRatioIsWhatTheDocsSay() public {
        KilimAuction.Config memory c = config(1_000_000);
        c.startsAt = uint64(block.timestamp + 1 hours);
        c.incrementBps = 1000;
        c.maxMotifsPerBid = 1_000_000;
        KilimAuction a = new KilimAuction(c);
        _openBidding(a);
        uint256 spentBefore = ALICE.balance;
        _bid(a, ALICE, RESERVE);
        while (a.highestBid() < 1 ether) {
            _bid(a, ALICE, a.minimumBid());
        }
        uint256 top = a.highestBid();
        uint256 credits = a.motifCredits(ALICE);
        emit log_named_uint("ladder top bid, wei", top);
        emit log_named_uint("ladder motifs", credits);
        emit log_named_uint("honest motifs for the same top bid", top / UNIT);
        // Only the top bid is still locked; every earlier rung came back.
        assertEq(spentBefore - ALICE.balance, top);
        // About eleven times an honest bidder's reward, as AUDIT.md (F-04) and the launch notes state.
        uint256 honest = top / UNIT;
        assertTrue(credits >= honest * 10 && credits <= honest * 12);
    }

    event log_named_uint(string key, uint256 value);

    // ---- D25: a winner's hook cannot make settlement fail, whatever it returns ----

    function testWinnerHookCannotMakeSettlementFail() public {
        // Sizes up to what the 1,000,000-gas delivery can build and pass back (about 358 KB), and past
        // it. The band from 316 KB to 358 KB is where the revert data is as large as it can be and
        // still reach settle(): a settle that copied it would run out of gas there (measured on 12
        // October 2026 against a copy of the auction whose catch copies the data). Each size up to
        // 355 KB is checked to come back from the delivery whole; from 360 KB on it cannot.
        uint256[17] memory sizes = [
            uint256(0),
            1_000,
            100_000,
            200_000,
            300_000,
            316_000,
            320_000,
            325_000,
            330_000,
            335_000,
            340_000,
            345_000,
            350_000,
            355_000,
            360_000,
            400_000,
            900_000
        ];
        for (uint256 wrong; wrong < 2; ++wrong) {
            for (uint256 i; i < sizes.length; ++i) {
                if (wrong == 0 && sizes[i] == 0) continue;
                uint256 snap = vm.snapshotState();
                HostileWallet winner = _wallet();
                winner.bid(RESERVE);
                vm.warp(auction.endsAt());
                // Estimated while the winner accepts, with no margin.
                uint256 limit = _estimateSettle();
                winner.setNft(sizes[i], wrong == 1);
                if (sizes[i] != 0) assertTrue(_deliveryPassesBack(sizes[i]) == (sizes[i] <= 355_000));
                uint256 before = gasleft();
                (bool ok,) = address(auction).call{gas: limit}(abi.encodeCall(auction.settle, ()));
                uint256 used = before - gasleft();
                assertTrue(ok);
                assertTrue(auction.settled());
                assertTrue(!auction.prizeClaimed());
                assertTrue(used < PRIZE_GAS + 100_000);
                vm.prank(TREASURY);
                auction.withdrawProceeds(TREASURY);
                // The winner still gets the 1/1 by naming an address that accepts it.
                assertTrue(winner.run(abi.encodeCall(auction.claimPrize, (CAROL))));
                assertEq(auction.oneOfOne().ownerOf(1), CAROL);
                vm.revertToState(snap);
            }
        }
    }

    /// @dev Whether the delivery, given PRIZE_GAS as settlement gives it, hands the winner's revert data of
    ///      `size` bytes back to the auction whole. Changes nothing.
    function _deliveryPassesBack(uint256 size) private returns (bool whole) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(auction));
        (bool ok, bytes memory data) =
            address(auction).call{gas: PRIZE_GAS}(abi.encodeCall(auction.deliverPrize, ()));
        whole = !ok && data.length == size;
        vm.revertToState(snap);
    }

    // ---- E29: one actor can fill the gate in one transaction (accepted; recorded) ----

    function testOneTransactionFillsTheGateAndAnyoneCanThenBid() public {
        KilimAuction a = new KilimAuction(config());
        vm.warp(a.startsAt());
        SybilFactory factory = new SybilFactory();
        vm.deal(address(this), 1 ether);
        uint256 before = gasleft();
        factory.run{value: 0.01 ether}(a, 100);
        uint256 used = before - gasleft();
        emit log_named_uint("gas to fill all 100 registrations in one transaction", used);
        assertEq(a.registrationCount(), 100);
        assertTrue(used < 16_777_216);
        assertEq(address(a).balance, 0);
        // Registration is a counter, not a list of who may bid.
        assertTrue(!a.registered(ALICE));
        _bid(a, ALICE, RESERVE);
        assertEq(a.highestBidder(), ALICE);
    }

    // ---- E33: malleable and compact signatures are refused ----

    function testHighSAndCompactSignaturesAreRefused() public {
        KilimAuction a = new KilimAuction(config());
        vm.warp(a.startsAt());
        uint256 key = 0xA11CE5;
        address user = vmx.addr(key);
        vm.deal(user, RESERVE);
        uint256 deadline = block.timestamp + 600;
        (uint8 v, bytes32 r, bytes32 s) = vmx.sign(key, a.registrationDigest(user, deadline));

        bytes memory flipped =
            abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        a.registerFor(user, deadline, flipped);

        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        a.registerFor(user, deadline, abi.encodePacked(r, vs));

        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        a.registerFor(user, deadline, abi.encodePacked(r, s, v, uint8(0)));

        assertTrue(!a.registered(user));
        a.registerFor(user, deadline, abi.encodePacked(r, s, v));
        assertTrue(a.registered(user));
    }

    // ---- E34: a delegated EOA cannot use the sponsored signature, and can still register directly ----

    function testADelegatedEoaCannotUseTheSponsoredSignatureButRegistersDirectly() public {
        KilimAuction a = new KilimAuction(config());
        vm.warp(a.startsAt());
        uint256 key = 0xB0B5;
        address user = vmx.addr(key);
        vm.deal(user, RESERVE);
        uint256 deadline = block.timestamp + 600;
        (uint8 v, bytes32 r, bytes32 s) = vmx.sign(key, a.registrationDigest(user, deadline));
        bytes memory sig = abi.encodePacked(r, s, v);

        // The address has code (an EIP-7702 delegation), so only ERC-1271 is tried, and it has none.
        vmx.etch(user, address(new PlainDelegate()).code);
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        a.registerFor(user, deadline, sig);
        assertTrue(!a.registered(user));

        // The same wallet registers itself directly.
        vm.prank(user);
        a.register();
        assertTrue(a.registered(user));

        // With the delegation cleared the signature works again for another wallet.
        uint256 key2 = 0xCA401;
        address user2 = vmx.addr(key2);
        vm.deal(user2, RESERVE);
        (v, r, s) = vmx.sign(key2, a.registrationDigest(user2, deadline));
        vmx.etch(user2, address(new PlainDelegate()).code);
        vmx.etch(user2, "");
        a.registerFor(user2, deadline, abi.encodePacked(r, s, v));
        assertTrue(a.registered(user2));
    }

    // ---- E36: a hostile ERC-1271 wallet cannot register on a bad answer; its gas cost is the caller's limit ----

    function testHostileSignatureWalletsNeverRegisterOnABadAnswer() public {
        KilimAuction a = new KilimAuction(config());
        vm.warp(a.startsAt());
        uint256 deadline = block.timestamp + 600;
        for (uint8 mode = 1; mode <= 5; ++mode) {
            address w = address(new Odd1271(mode));
            vm.deal(w, RESERVE);
            uint256 before = gasleft();
            (bool ok,) = address(a).call{gas: 300_000}(abi.encodeCall(a.registerFor, (w, deadline, "")));
            uint256 used = before - gasleft();
            assertTrue(!ok);
            assertTrue(!a.registered(w));
            // The sponsor loses at most the gas limit it chose.
            assertTrue(used <= 310_000);
        }
        assertEq(a.registrationCount(), 0);

        // A wallet whose answer changes: valid in the sponsor's simulation, invalid when it lands.
        Odd1271 flip = new Odd1271(6);
        vm.deal(address(flip), RESERVE);
        uint256 snap = vm.snapshotState();
        a.registerFor(address(flip), deadline, "");
        assertTrue(a.registered(address(flip)));
        vm.revertToState(snap);
        flip.shut();
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        a.registerFor(address(flip), deadline, "");
        assertTrue(!a.registered(address(flip)));

        // A valid contract wallet registers.
        address good = address(new Odd1271(0));
        vm.deal(good, RESERVE);
        a.registerFor(good, deadline, "");
        assertTrue(a.registered(good));
    }

    // ---- F39, F41: the fixed gas numbers at Glamsterdam prices ----

    /// @dev Slots on `target` that the recorded call took from zero to nonzero, and nonzero to another value.
    function _writes(address target, bytes32[] memory slots, bytes32[] memory pre)
        private
        view
        returns (uint256 fresh, uint256 updated)
    {
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (slots[j] == slots[i]) seen = true;
            }
            if (seen) continue;
            bytes32 post = vmx.load(target, slots[i]);
            if (pre[i] == bytes32(0) && post != bytes32(0)) ++fresh;
            else if (pre[i] != post) ++updated;
        }
    }

    /// @dev Runs `call` on the auction twice from one state: once to learn which slots it writes, once
    ///      to compare them before and after. Leaves the state after the call.
    function _diff(address caller, uint256 value, bytes memory data, address target)
        private
        returns (uint256 fresh, uint256 updated)
    {
        uint256 snap = vm.snapshotState();
        vmx.record();
        vm.prank(caller);
        (bool ok,) = address(auction).call{value: value}(data);
        assertTrue(ok);
        (, bytes32[] memory slots) = vmx.accesses(target);
        vm.revertToState(snap);
        bytes32[] memory pre = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            pre[i] = vmx.load(target, slots[i]);
        }
        vm.prank(caller);
        (ok,) = address(auction).call{value: value}(data);
        assertTrue(ok);
        return _writes(target, slots, pre);
    }

    function testDeferredRefundReserveCoversGlamsterdamPrices() public {
        // The same outbid twice: once the leader takes the refund, once it refuses.
        uint256 snap = vm.snapshotState();
        HostileWallet leader = _wallet();
        leader.bid(RESERVE);
        uint256 amount = auction.minimumBid();
        (uint256 paidFresh, uint256 paidUpdated) =
            _diff(ALICE, amount, abi.encodeCall(auction.bid, (amount, 0, 0)), address(auction));
        vm.revertToState(snap);
        leader = _wallet();
        leader.bid(RESERVE);
        leader.setEth(0, true);
        (uint256 deferredFresh, uint256 deferredUpdated) =
            _diff(ALICE, amount, abi.encodeCall(auction.bid, (amount, 0, 0)), address(auction));

        // The deferred path writes exactly two new slots after the refund call and updates none.
        uint256 extraFresh = deferredFresh - paidFresh;
        assertEq(extraFresh, 2);
        assertEq(deferredUpdated, paidUpdated);
        // About 50,000 gas today for those writes and the two events; at the scheduled prices:
        uint256 projected = 50_000 + extraFresh * NEW_SLOT_EXTRA;
        emit log_named_uint("deferred-refund path after the call, gas at Glamsterdam prices", projected);
        emit log_named_uint("new slots written by a first bid that outbids a refusing leader", deferredFresh);
        // The contract keeps 300,000 back for it.
        assertTrue(projected <= 300_000 * 80 / 100);
    }

    function testPrizeDeliveryAtGlamsterdamPrices() public {
        // What the delivery writes: settlement to an ordinary first-time holder, against settlement
        // whose delivery fails.
        _bid(auction, ALICE, RESERVE);
        vm.warp(auction.endsAt());
        uint256 snap = vm.snapshotState();
        (uint256 aFresh, uint256 aUpdated) =
            _diff(CAROL, 0, abi.encodeCall(auction.settle, ()), address(auction));
        vm.revertToState(snap);
        (uint256 nFresh, uint256 nUpdated) =
            _diff(CAROL, 0, abi.encodeCall(auction.settle, ()), address(auction.oneOfOne()));
        vm.revertToState(snap);
        vmx.etch(ALICE, address(new PlainDelegate()).code);
        (uint256 failFresh, uint256 failUpdated) =
            _diff(CAROL, 0, abi.encodeCall(auction.settle, ()), address(auction));
        vm.revertToState(snap);
        vmx.etch(ALICE, "");

        uint256 freshInDelivery = (aFresh - failFresh) + nFresh;
        uint256 updatedInDelivery = (aUpdated - failUpdated) + nUpdated;
        emit log_named_uint("new slots written inside the prize delivery", freshInDelivery);
        emit log_named_uint("slots updated inside the prize delivery", updatedInDelivery);

        // The most gas a winner's hook can use today and still be delivered.
        uint256 lo = 800_000;
        uint256 hi = PRIZE_GAS;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 s2 = vm.snapshotState();
            KilimAuction a2 = new KilimAuction(config());
            _openBidding(a2);
            GasHungryWinner w = new GasHungryWinner(a2, mid);
            _fund(address(w), 1 ether);
            w.bid(RESERVE);
            vm.warp(a2.endsAt());
            a2.settle();
            bool delivered = a2.prizeClaimed();
            vm.revertToState(s2);
            if (delivered) lo = mid;
            else hi = mid;
        }
        uint256 overheadToday = PRIZE_GAS - lo;
        uint256 overheadAfter =
            overheadToday + freshInDelivery * NEW_SLOT_EXTRA + updatedInDelivery * UPDATE_EXTRA;
        emit log_named_uint("gas a winner's hook may use today", lo);
        emit log_named_uint("delivery overhead today", overheadToday);
        emit log_named_uint("delivery overhead at Glamsterdam prices", overheadAfter);
        // The fixed 1,000,000 must still deliver to an ordinary wallet after the repricing, and leave a
        // winner's hook room for four new slots of its own at the new price.
        assertTrue(overheadAfter < PRIZE_GAS);
        emit log_named_uint("gas left for a winner's hook at Glamsterdam prices", PRIZE_GAS - overheadAfter);
        assertTrue(PRIZE_GAS - overheadAfter > 4 * (22_100 + NEW_SLOT_EXTRA));
        // 500,000 failed every winner once a new slot cost about 10% more than the scheduled price
        // (audit of 12 October 2026, ETH-1). 1,000,000 still delivers to an ordinary wallet at twice it.
        uint256 overheadAtTwice = overheadToday + freshInDelivery * (2 * NEW_SLOT_EXTRA + 22_100)
            + updatedInDelivery * (2 * UPDATE_EXTRA + 5_000);
        emit log_named_uint("delivery overhead at twice the Glamsterdam prices", overheadAtTwice);
        assertTrue(overheadAtTwice < PRIZE_GAS);
    }
}

/// @dev A winner whose NFT hook burns a set amount of gas.
contract GasHungryWinner is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256 private immutable burn;

    constructor(KilimAuction a, uint256 burn_) {
        auction = a;
        burn = burn_;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
