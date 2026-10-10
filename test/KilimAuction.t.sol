// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {TestBase} from "./TestBase.sol";
import {Receiver} from "./mocks/Receiver.sol";
import {RangeInspector} from "./mocks/RangeInspector.sol";
import {GasBurner} from "./mocks/GasBurner.sol";

/// @dev A bidding contract whose ETH and NFT receivers can reject, burn all their gas, or call back
///      into a target with ETH attached. fire() makes the same call from outside any callback.
contract HookedBidder is IERC721Receiver {
    bool public rejecting;
    bool public burning;
    address public target;
    uint256 public value;
    bytes public payload;
    bool public callbackSucceeded;

    function configure(bool rejecting_, bool burning_) external {
        rejecting = rejecting_;
        burning = burning_;
    }

    function hook(address target_, uint256 value_, bytes calldata payload_) external {
        target = target_;
        value = value_;
        payload = payload_;
    }

    function fire() external returns (bool ok) {
        (ok,) = target.call{value: value}(payload);
    }

    function _callback() private {
        if (target != address(0)) (callbackSucceeded,) = target.call{value: value}(payload);
    }

    receive() external payable {
        require(!rejecting, "ETH rejected");
        if (burning) while (gasleft() > 0) {}
        _callback();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _callback();
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract KilimAuctionTest is TestBase {
    KilimAuction internal auction;
    KilimMotifs internal nft;
    KilimOneOfOne internal oneOfOne;

    function setUp() public {
        auction = new KilimAuction(config());
        nft = auction.motifs();
        oneOfOne = auction.oneOfOne();
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _openBidding(auction);
    }

    function _fund(address user) private {
        _fund(user, 1e30);
    }

    /// @dev `units` bid units of 0.001 ETH, paid in full.
    function _bid(address user, uint256 units) private {
        vm.prank(user);
        auction.bid{value: units * UNIT}(units * UNIT, 0, 0);
    }

    /// @dev The auction holds exactly what it owes: no ETH is stranded and none is missing.
    function _assertSolvent() private view {
        assertEq(address(auction).balance, auction.liabilities());
    }

    /// @dev A funded bidding contract that rejects ETH, so its refund waits when it is outbid.
    function _rejectingBidder() private returns (HookedBidder bidder) {
        bidder = new HookedBidder();
        bidder.configure(true, false);
        _fund(address(bidder));
    }

    function testBidEscrowsFundsAndAllocatesCredits() public {
        uint256 before = ALICE.balance;
        _bid(ALICE, 25);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), 25 * UNIT);
        assertEq(auction.motifCredits(ALICE), 25);
        assertEq(ALICE.balance, before - 25 * UNIT);
        assertEq(address(auction).balance, 25 * UNIT);
        _assertSolvent();
        assertEq(nft.motifsMinted(), 0);
    }

    function testOpeningBidMustMeetTheReserve() public {
        assertEq(auction.minimumBid(), RESERVE);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidTooLow.selector, RESERVE));
        _bid(ALICE, 9);
        _bid(ALICE, 10);
        assertEq(auction.highestBid(), RESERVE);
        assertEq(auction.motifCredits(ALICE), 10);
        assertEq(auction.minimumBid(), 11 * UNIT);
        _assertSolvent();
    }

    function testMinimumBidRoundsUpToWholeUnit() public {
        _bid(ALICE, 25);
        assertEq(auction.minimumBid(), 27 * UNIT);
        vm.expectPartialRevert(EnglishAuction.BidTooLow.selector);
        _bid(BOB, 26);
        _bid(BOB, 27);
        assertEq(auction.minimumBid(), 29 * UNIT);
    }

    function testRejectsFractionalUnitBid() public {
        vm.expectRevert(EnglishAuction.NonWholeUnitBid.selector);
        vm.prank(ALICE);
        auction.bid{value: 25 * UNIT + 1}(25 * UNIT + 1, 0, 0);
    }

    /// @dev The ETH sent must equal the bid: less, more or none all revert and leave nothing behind.
    function testIncorrectPaymentRejected() public {
        uint256 before = ALICE.balance;
        vm.startPrank(ALICE);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        auction.bid{value: 25 * UNIT - 1}(25 * UNIT, 0, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        auction.bid{value: 25 * UNIT + 1}(25 * UNIT, 0, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        auction.bid{value: 26 * UNIT}(25 * UNIT, 0, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        auction.bid(25 * UNIT, 0, 0);
        vm.stopPrank();
        assertEq(ALICE.balance, before);
        assertEq(auction.highestBidder(), address(0));
        assertEq(auction.highestBid(), 0);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.motifsAllocated(), 0);
        assertEq(address(auction).balance, 0);
    }

    /// @dev The auction has no receive or fallback: ETH can only arrive as a bid.
    function testEthSentWithoutABidReverts() public {
        vm.startPrank(ALICE);
        (bool ok,) = address(auction).call{value: 25 * UNIT}("");
        assertTrue(!ok);
        (ok,) = address(auction).call{value: 25 * UNIT}(abi.encodeWithSignature("deposit()"));
        assertTrue(!ok);
        (ok,) = address(auction).call(abi.encodeWithSignature("deposit()"));
        assertTrue(!ok);
        // The other entry points are not payable either.
        (ok,) = address(auction).call{value: 1}(abi.encodeCall(auction.register, ()));
        assertTrue(!ok);
        (ok,) = address(auction).call{value: 1}(abi.encodeCall(auction.settle, ()));
        assertTrue(!ok);
        vm.stopPrank();
        assertEq(address(auction).balance, 0);
        _bid(ALICE, 25);
        vm.prank(BOB);
        (ok,) = address(auction).call{value: 27 * UNIT}("");
        assertTrue(!ok);
        assertEq(auction.highestBidder(), ALICE);
        _assertSolvent();
    }

    function testTimeBoundaries() public {
        // Before the start nobody can register, so bidding is not open yet.
        KilimAuction early = new KilimAuction(config());
        vm.expectRevert(EnglishAuction.RegistrationIncomplete.selector);
        _bid(early, ALICE, RESERVE);
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        vm.expectRevert(EnglishAuction.AuctionNotOpen.selector);
        _bid(BOB, 27);
        auction.settle();
        assertTrue(auction.settled());
    }

    function testOutbidRefundAndCreditsRemain() public {
        uint256 before = ALICE.balance;
        _bid(ALICE, 25);
        vm.expectEmit();
        emit EnglishAuction.RefundPaid(ALICE, 25 * UNIT);
        _bid(BOB, 27);
        // Paid back inside Bob's bid: nothing waits, nothing to withdraw, the motifs stay.
        assertEq(ALICE.balance, before);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.refundLiability(), 0);
        assertEq(auction.motifCredits(ALICE), 25);
        assertEq(address(auction).balance, 27 * UNIT);
        _assertSolvent();
        vm.expectRevert(EnglishAuction.NothingToWithdraw.selector);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
    }

    function testOnlyTheAuctionCanPayARefund() public {
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(ALICE);
        auction.payOutbidRefund(ALICE, 25 * UNIT);
        _assertSolvent();
    }

    function testSelfOutbidFullyFundedAndLiabilitiesConserved() public {
        uint256 before = ALICE.balance;
        _bid(ALICE, 25);
        _bid(ALICE, 27);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.motifCredits(ALICE), 52);
        assertEq(ALICE.balance, before - 27 * UNIT);
        assertEq(address(auction).balance, 27 * UNIT);
        assertEq(auction.liabilities(), 27 * UNIT);
    }

    /// @dev A bid that does not pay in full reverts as a whole: the standing bid and rewards stay.
    function testRejectedDepositRollsBackStandingBidAndRewards() public {
        _bid(ALICE, 25);
        uint256 close = auction.endsAt();
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(BOB);
        auction.bid{value: 26 * UNIT}(27 * UNIT, 0, 0);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), 25 * UNIT);
        assertEq(auction.endsAt(), close);
        assertEq(auction.refundLiability(), 0);
        assertEq(auction.motifsAllocated(), 25);
        assertEq(auction.motifCredits(BOB), 0);
        assertEq(ALICE.balance, aliceBefore);
        assertEq(BOB.balance, bobBefore);
        _assertSolvent();
    }

    /// @dev An outbid address that cannot receive ETH never blocks the next bid: its refund waits
    ///      as a pull refund, which it can send to another address.
    function testRejectedRefundPreservesEntitlement() public {
        HookedBidder bidder = _rejectingBidder();
        _bid(address(bidder), 25);
        vm.expectEmit();
        emit EnglishAuction.RefundDeferred(address(bidder), 25 * UNIT);
        _bid(BOB, 27);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        assertEq(auction.refundLiability(), 25 * UNIT);
        assertEq(auction.liabilities(), 52 * UNIT);
        assertEq(address(auction).balance, 52 * UNIT);
        vm.expectRevert(EnglishAuction.EthTransferFailed.selector);
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        assertEq(address(auction).balance, 52 * UNIT);
        uint256 before = CAROL.balance;
        vm.expectEmit();
        emit EnglishAuction.RefundWithdrawn(address(bidder), CAROL, 25 * UNIT);
        vm.prank(address(bidder));
        auction.withdrawRefund(CAROL);
        assertEq(CAROL.balance, before + 25 * UNIT);
        assertEq(auction.refunds(address(bidder)), 0);
        assertEq(auction.refundLiability(), 0);
        _assertSolvent();
    }

    /// @dev A receiver that burns every unit of gas it is given fails the automatic refund, so the
    ///      refund waits in full and the next bid still lands.
    function testGasBurningRefundReceiverDefersInFull() public {
        HookedBidder bidder = new HookedBidder();
        bidder.configure(false, true);
        _fund(address(bidder));
        _bid(address(bidder), 25);
        uint256 before = address(bidder).balance;
        vm.expectEmit();
        emit EnglishAuction.RefundDeferred(address(bidder), 25 * UNIT);
        _bid(BOB, 27);
        assertEq(auction.highestBidder(), BOB);
        assertEq(address(bidder).balance, before);
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        assertEq(address(auction).balance, 52 * UNIT);
        _assertSolvent();
        // Once it stops burning gas it withdraws the full amount.
        bidder.configure(false, false);
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertEq(address(bidder).balance, before + 25 * UNIT);
        _assertSolvent();
    }

    function testCannotStealAnotherBiddersRefund() public {
        HookedBidder bidder = _rejectingBidder();
        _bid(address(bidder), 25);
        _bid(ALICE, 27);
        _bid(BOB, 29);
        // One refund waits and one was paid; neither is anyone else's to withdraw.
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        vm.expectRevert(EnglishAuction.NothingToWithdraw.selector);
        vm.prank(CAROL);
        auction.withdrawRefund(CAROL);
        vm.expectRevert(EnglishAuction.NothingToWithdraw.selector);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        _assertSolvent();
    }

    /// @dev The automatic refund hands control to the outbid bidder. It cannot bid again from there,
    ///      and a deferred refund's withdrawal cannot re-enter either.
    function testRefundCallbackCannotReenterBidOrRefund() public {
        HookedBidder bidder = new HookedBidder();
        _fund(address(bidder));
        _bid(address(bidder), 25);
        bidder.hook(address(auction), 40 * UNIT, abi.encodeCall(auction.bid, (40 * UNIT, 0, 0)));
        uint256 before = address(bidder).balance;
        vm.expectEmit();
        emit EnglishAuction.RefundPaid(address(bidder), 25 * UNIT);
        _bid(BOB, 27);
        assertTrue(!bidder.callbackSucceeded());
        assertEq(address(bidder).balance, before + 25 * UNIT);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.highestBid(), 27 * UNIT);
        _assertSolvent();
        // The same call from outside the refund is an ordinary winning bid.
        assertTrue(bidder.fire());
        assertEq(auction.highestBidder(), address(bidder));
        assertEq(auction.highestBid(), 40 * UNIT);
        _assertSolvent();
        // A deferred refund's withdrawal cannot re-enter to withdraw again.
        bidder.configure(true, false);
        bidder.hook(address(0), 0, "");
        _bid(CAROL, 42);
        assertEq(auction.refunds(address(bidder)), 40 * UNIT);
        bidder.configure(false, false);
        bidder.hook(address(auction), 0, abi.encodeCall(auction.withdrawRefund, (CAROL)));
        before = address(bidder).balance;
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertTrue(!bidder.callbackSucceeded());
        assertEq(address(bidder).balance, before + 40 * UNIT);
        assertEq(auction.refundLiability(), 0);
        _assertSolvent();
    }

    /// @dev A receiver paid a deferred refund cannot reach another entry point that would succeed.
    function testRefundCallbackCannotSettle() public {
        HookedBidder bidder = _rejectingBidder();
        _bid(address(bidder), 25);
        _bid(BOB, 27);
        bidder.configure(false, false);
        vm.warp(auction.endsAt());
        bidder.hook(address(auction), 0, abi.encodeCall(auction.settle, ()));
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertTrue(!bidder.callbackSucceeded());
        assertTrue(!auction.settled());
        _assertSolvent();
        // The same call from outside the refund settles.
        assertTrue(bidder.fire());
        assertTrue(auction.settled());
        assertEq(oneOfOne.ownerOf(1), BOB);
    }

    /// @dev The winner's receiver also has a deferred refund; the prize callback still cannot withdraw it.
    function testPrizeCallbackCannotWithdrawARefund() public {
        // Receiver has no way to accept ETH, so its refund always waits.
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        _bid(BOB, 27);
        _bid(address(receiver), 29);
        assertEq(auction.refunds(address(receiver)), 25 * UNIT);
        // Sent to an address that accepts ETH, so only the reentrancy guard stops the callback.
        receiver.configure(false, address(auction), abi.encodeCall(auction.withdrawRefund, (CAROL)));
        uint256 before = CAROL.balance;
        vm.warp(auction.endsAt());
        // The 1/1 arrives inside settle(); the receiver's callback cannot withdraw from there.
        auction.settle();
        assertTrue(!receiver.callbackSucceeded());
        assertEq(oneOfOne.ownerOf(1), address(receiver));
        assertEq(auction.refunds(address(receiver)), 25 * UNIT);
        assertEq(CAROL.balance, before);
        _assertSolvent();
        // Outside the callback the same withdrawal goes through.
        vm.prank(address(receiver));
        auction.withdrawRefund(CAROL);
        assertEq(CAROL.balance, before + 25 * UNIT);
        _assertSolvent();
    }

    function testClockStartsAtFirstBidAndExtendsWithoutLimit() public {
        assertEq(auction.endsAt(), 0);
        vm.warp(auction.startsAt() + 5 days);
        uint256 firstBidAt = block.timestamp;
        _bid(ALICE, 25);
        // The full duration runs from the first bid, whenever it arrives.
        assertEq(auction.endsAt(), firstBidAt + 22 hours);
        for (uint256 i; i < 10; ++i) {
            vm.warp(auction.endsAt() - 1);
            _bidMinimum(ALICE);
            assertEq(auction.endsAt(), block.timestamp + 10 minutes);
            _assertSolvent();
        }
        // No absolute end: extensions have pushed the close past the original duration.
        assertTrue(auction.endsAt() > firstBidAt + 22 hours);
    }

    function _bidMinimum(address user) private {
        uint256 amount = auction.minimumBid();
        vm.prank(user);
        auction.bid{value: amount}(amount, 0, 0);
    }

    /// @dev A bid moves the close to one window after itself only when that is later: an early bid and a
    ///      bid exactly one window before the close leave it alone; one second later moves it by one second.
    function testBidsNeverBringTheCloseForward() public {
        _bid(ALICE, 25);
        uint256 close = auction.endsAt();
        vm.warp(block.timestamp + 1 hours);
        _bidMinimum(BOB);
        assertEq(auction.endsAt(), close);
        vm.warp(close - 10 minutes);
        _bidMinimum(ALICE);
        assertEq(auction.endsAt(), close);
        vm.warp(close - 10 minutes + 1);
        _bidMinimum(BOB);
        assertEq(auction.endsAt(), close + 1);
    }

    function testNoBidsNeverEndsAndNeverSettles() public {
        vm.warp(auction.startsAt() + 3650 days);
        assertEq(auction.endsAt(), 0);
        vm.expectRevert(EnglishAuction.NoBids.selector);
        auction.settle();
        vm.expectRevert(EnglishAuction.NotSettled.selector);
        vm.prank(TREASURY);
        auction.claimPrize(TREASURY);
        assertTrue(!oneOfOne.minted());
        // Bidding still works whenever someone finally arrives.
        _bid(ALICE, 25);
        assertEq(auction.endsAt(), block.timestamp + 22 hours);
    }

    function testSettlementAndProceedsLeaveRefundsSolvent() public {
        HookedBidder bidder = _rejectingBidder();
        _bid(address(bidder), 25);
        _bid(BOB, 27);
        bidder.configure(false, false);
        vm.warp(auction.endsAt());
        vm.prank(CAROL);
        auction.settle();
        _assertSolvent();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 27 * UNIT);
        assertEq(address(auction).balance, 25 * UNIT);
        assertEq(auction.liabilities(), 25 * UNIT);
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertEq(auction.liabilities(), 0);
        assertEq(address(auction).balance, 0);
    }

    /// @dev Every wei that comes in goes out again, and after each step the auction holds exactly
    ///      what it owes.
    function testBalanceEqualsLiabilitiesAfterEveryStep() public {
        HookedBidder bidder = _rejectingBidder();
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        uint256 bidderBefore = address(bidder).balance;
        assertEq(address(auction).balance, 0);
        _assertSolvent();
        _bid(ALICE, 25);
        _assertSolvent();
        // Alice is paid back inside this bid.
        _bid(address(bidder), 27);
        assertEq(address(auction).balance, 27 * UNIT);
        _assertSolvent();
        // This refund waits: the auction now holds the standing bid and the refund.
        _bid(BOB, 29);
        assertEq(address(auction).balance, 56 * UNIT);
        _assertSolvent();
        vm.prank(ALICE);
        auction.claimMotifs(25, ALICE);
        _assertSolvent();
        bidder.configure(false, false);
        vm.prank(address(bidder));
        auction.withdrawRefund(address(bidder));
        assertEq(address(auction).balance, 29 * UNIT);
        _assertSolvent();
        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(oneOfOne.ownerOf(1), BOB);
        assertEq(address(auction).balance, 29 * UNIT);
        _assertSolvent();
        vm.prank(BOB);
        auction.claimMotifs(29, BOB);
        _assertSolvent();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);
        // Deposits were 25 + 27 + 29 units; the two losing bids went back and the winning bid is the proceeds.
        assertEq(ALICE.balance, aliceBefore);
        assertEq(address(bidder).balance, bidderBefore);
        assertEq(BOB.balance, bobBefore - 29 * UNIT);
        assertEq(TREASURY.balance, 29 * UNIT);
    }

    function testSettlementTimingAndIdempotence() public {
        vm.expectRevert(EnglishAuction.NoBids.selector);
        auction.settle();
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.AuctionNotEnded.selector);
        auction.settle();
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(EnglishAuction.AlreadySettled.selector);
        auction.settle();
    }

    function testOnlyTreasuryCanWithdrawOnlyAfterSettlement() public {
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(ALICE);
        auction.withdrawProceeds(ALICE);
        vm.expectRevert(EnglishAuction.NotSettled.selector);
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        _assertSolvent();
    }

    function testWinnerClaimsExactlyOnePrizeToChosenRecipient() public {
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.NotSettled.selector);
        vm.prank(ALICE);
        auction.claimPrize(ALICE);
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeClaimed(ALICE, ALICE);
        auction.settle();
        // Settlement sent it: the winner never has to claim.
        assertEq(oneOfOne.ownerOf(1), ALICE);
        assertTrue(auction.prizeClaimed());
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(BOB);
        auction.claimPrize(BOB);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        vm.prank(ALICE);
        auction.claimPrize(ALICE);
    }

    function testTreasuryCannotClaimPrizeAfterSomeoneBids() public {
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(TREASURY);
        auction.claimPrize(TREASURY);
        assertEq(oneOfOne.ownerOf(1), ALICE);
    }

    function testRejectingWinnerCannotBlockSettlementOrProceeds() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        receiver.configure(true, address(0), "");
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert();
        vm.prank(address(receiver));
        auction.claimPrize(address(receiver));
        assertTrue(!auction.prizeClaimed());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 25 * UNIT);
        assertEq(address(auction).balance, 0);
        vm.prank(address(receiver));
        auction.claimPrize(CAROL);
        assertEq(oneOfOne.ownerOf(1), CAROL);
    }

    function testMotifClaimsBoundedAndNeverForfeitWithRefund() public {
        _bid(ALICE, 100);
        _bid(BOB, 105);
        vm.prank(ALICE);
        auction.claimMotifs(64, CAROL);
        vm.prank(ALICE);
        auction.claimMotifs(36, ALICE);
        assertEq(nft.balanceOf(CAROL), 64);
        assertEq(nft.balanceOf(ALICE), 36);
        assertEq(auction.motifCredits(ALICE), 0);
        assertEq(auction.motifsClaimed(), nft.motifsMinted());
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        vm.prank(ALICE);
        auction.claimMotifs(1, ALICE);
        _assertSolvent();
    }

    /// @dev Motifs are never sent by a bid, a refund or settlement: only claimMotifs mints them.
    function testMotifsAreMintedOnlyByClaim() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(nft.motifsMinted(), 0);
        assertEq(auction.motifsClaimed(), 0);
        assertEq(auction.motifsAllocated(), 52);
        assertEq(nft.balanceOf(ALICE), 0);
        // Credits outlive the auction: both bidders still claim after settlement.
        vm.prank(ALICE);
        auction.claimMotifs(25, ALICE);
        vm.prank(BOB);
        auction.claimMotifs(27, BOB);
        assertEq(nft.balanceOf(ALICE), 25);
        assertEq(nft.balanceOf(BOB), 27);
        assertEq(oneOfOne.balanceOf(BOB), 1);
        assertEq(auction.motifsClaimed(), 52);
    }

    function testInvalidClaimQuantities() public {
        _bid(ALICE, 100);
        vm.startPrank(ALICE);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.claimMotifs(0, ALICE);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.claimMotifs(65, ALICE);
        vm.stopPrank();
    }

    function testRejectingReceiverDoesNotConsumeMotifCredits() public {
        _bid(ALICE, 25);
        Receiver receiver = new Receiver();
        receiver.configure(true, address(0), "");
        vm.expectRevert();
        vm.prank(ALICE);
        auction.claimMotifs(4, address(receiver));
        assertEq(auction.motifCredits(ALICE), 25);
        assertEq(nft.motifsMinted(), 0);
    }

    function testNftCallbackCannotDoubleClaim() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        receiver.configure(false, address(auction), abi.encodeCall(auction.claimMotifs, (4, CAROL)));
        vm.prank(address(receiver));
        auction.claimMotifs(4, address(receiver));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(auction.motifCredits(address(receiver)), 21);
        assertEq(nft.motifsMinted(), 4);
    }

    function testRewardCapDoesNotBlockCompetitiveBids() public {
        KilimAuction.Config memory c = config(30);
        c.maxMotifsPerBid = 25;
        auction = new KilimAuction(c);
        _openBidding(auction);
        _bid(ALICE, 25);
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        vm.prank(BOB);
        auction.bid{value: 27 * UNIT}(27 * UNIT, 6, 0);
        vm.prank(BOB);
        auction.bid{value: 27 * UNIT}(27 * UNIT, 5, 0);
        _bid(ALICE, 29);
        assertEq(auction.motifsAllocated(), 30);
        assertEq(auction.highestBid(), 29 * UNIT);
        assertEq(auction.rewardForBid(1000 * UNIT), 0);
        _assertSolvent();
    }

    function testPerBidRewardCap() public {
        _bid(ALICE, 1001);
        assertEq(auction.motifCredits(ALICE), 1000);
        _assertSolvent();
    }

    /// @dev ETH forced into the auction (it cannot be sent normally) changes no accounting and
    ///      is not paid out to anyone.
    function testForcedEthDoesNotAlterLiabilitiesOrRewards() public {
        _bid(ALICE, 25);
        vm.deal(address(auction), address(auction).balance + 100 * UNIT);
        assertEq(auction.liabilities(), 25 * UNIT);
        assertEq(auction.motifsAllocated(), 25);
        assertEq(auction.minimumBid(), 27 * UNIT);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 25 * UNIT);
        assertEq(address(auction).balance, 100 * UNIT);
        assertEq(auction.liabilities(), 0);
    }

    function testProceedsCannotGoToAnInvalidRecipient() public {
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        auction.settle();
        uint256 held = address(auction).balance;
        address[3] memory bad = [address(0), address(auction), address(nft)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(EnglishAuction.InvalidRecipient.selector);
            vm.prank(TREASURY);
            auction.withdrawProceeds(bad[i]);
        }
        assertEq(auction.proceedsDue(), 25 * UNIT);
        assertEq(address(auction).balance, held);
        _assertSolvent();
    }

    function testInvalidRecipientsDoNotDestroyClaims() public {
        HookedBidder bidder = _rejectingBidder();
        _bid(address(bidder), 25);
        _bid(BOB, 27);
        address[3] memory bad = [address(0), address(auction), address(nft)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(EnglishAuction.InvalidRecipient.selector);
            vm.prank(address(bidder));
            auction.withdrawRefund(bad[i]);
            vm.expectRevert(EnglishAuction.InvalidRecipient.selector);
            vm.prank(address(bidder));
            auction.claimMotifs(1, bad[i]);
            // The recipient is checked before the quantity.
            vm.expectRevert(EnglishAuction.InvalidRecipient.selector);
            vm.prank(address(bidder));
            auction.claimMotifs(0, bad[i]);
        }
        assertEq(auction.refunds(address(bidder)), 25 * UNIT);
        assertEq(auction.motifCredits(address(bidder)), 25);
        _assertSolvent();
    }

    function testConstructorRejectsInvalidConfiguration() public {
        KilimAuction.Config memory c = config();
        c.treasury = address(0);
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config();
        c.startsAt = uint64(block.timestamp);
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config();
        c.incrementBps = 0;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config();
        c.reservePrice += 1;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        // The reserve is the registration balance and nothing else, whole units included.
        c = config();
        c.reservePrice = 25 * UNIT;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config();
        c.reservePrice = RESERVE - UNIT;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        KilimAuction valid = new KilimAuction(config());
        assertEq(valid.reservePrice(), valid.REGISTRATION_BALANCE());
        assertEq(valid.reservePrice(), 10 * valid.MOTIF_PRICE());
    }

    /// @dev The token contracts exist before the auction, so a config can name one of them as the treasury
    ///      by mistake. Neither could ever withdraw the proceeds.
    function testTreasuryCannotBeATokenContract() public {
        KilimAuction.Config memory c = config();
        c.treasury = c.motifs;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config();
        c.treasury = c.oneOfOne;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    /// @dev The tokens name the auction's address before it exists: the deploy script predicts it from the
    ///      deployer's nonce, and the auction refuses tokens that named any other minter.
    function testAuctionAddressIsPredictedAndCheckedByTheTokens() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        KilimAuction deployed = new KilimAuction(config());
        assertEq(address(deployed), next);
        assertEq(deployed.motifs().minter(), next);
        assertEq(deployed.oneOfOne().minter(), next);
        assertEq(address(deployed.oneOfOne().motifs()), address(deployed.motifs()));
        assertEq(deployed.motifCap(), deployed.motifs().motifCap());
        // Tokens built for one address refuse an auction at another: a creation in between moves it.
        KilimAuction.Config memory c = config();
        new Receiver();
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        // A 1/1 over a different motif collection is refused too.
        c = config();
        KilimMotifs other = newMotifs(
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2), TREASURY, MOTIF_CAP
        );
        c.oneOfOne = address(
            newOneOfOne(
                vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1), TREASURY, other
            )
        );
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    function testFuzzInvalidAuctionConfiguration(uint8 selector) public {
        KilimAuction.Config memory c = config();
        uint256 choice = uint256(selector) % 12;
        if (choice == 0) c.reservePrice = RESERVE + UNIT;
        else if (choice == 1) c.duration = 0;
        else if (choice == 2) c.duration = 30 days + 1;
        else if (choice == 3) c.extensionWindow = c.duration + 1;
        else if (choice == 4) c.extensionWindow = 0;
        else if (choice == 5) c.incrementBps = 10001;
        else if (choice == 6) c.maxMotifsPerBid = 0;
        else if (choice == 7) c.maxMotifsPerBid = MOTIF_CAP + 1;
        else if (choice == 8) c.motifs = ALICE; // no code
        else if (choice == 9) c.oneOfOne = ALICE; // no code
        else if (choice == 10) c.motifs = c.oneOfOne; // not a collection with this auction as minter
        else c.reservePrice = 0;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    /// @dev A proceeds payment that fails reverts and leaves the proceeds due; the treasury names
    ///      another recipient, and nothing is paid twice.
    function testRepeatedProceedsWithdrawalAndFailedPayment() public {
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        auction.settle();
        HookedBidder sink = new HookedBidder();
        sink.configure(true, false);
        vm.expectRevert(EnglishAuction.EthTransferFailed.selector);
        vm.prank(TREASURY);
        auction.withdrawProceeds(address(sink));
        assertEq(auction.proceedsDue(), 25 * UNIT);
        _assertSolvent();
        uint256 before = CAROL.balance;
        vm.expectEmit();
        emit EnglishAuction.ProceedsWithdrawn(CAROL, 25 * UNIT);
        vm.prank(TREASURY);
        auction.withdrawProceeds(CAROL);
        assertEq(CAROL.balance, before + 25 * UNIT);
        assertEq(auction.proceedsDue(), 0);
        assertEq(address(auction).balance, 0);
        vm.expectRevert(EnglishAuction.NothingToWithdraw.selector);
        vm.prank(TREASURY);
        auction.withdrawProceeds(CAROL);
    }

    function testNftReceiverCannotDoubleClaimPrize() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        receiver.configure(false, address(auction), abi.encodeCall(auction.claimPrize, (CAROL)));
        vm.warp(auction.endsAt());
        auction.settle();
        assertTrue(!receiver.callbackSucceeded());
        assertEq(oneOfOne.ownerOf(1), address(receiver));
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        vm.prank(address(receiver));
        auction.claimPrize(CAROL);
    }

    function testRejectingWinnerFallsBackToClaim() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        receiver.configure(true, address(0), "");
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(address(receiver));
        auction.settle();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        vm.prank(address(receiver));
        auction.claimPrize(CAROL);
        assertEq(oneOfOne.ownerOf(1), CAROL);
    }

    /// @dev A winner whose receiver burns the whole delivery allowance cannot stop settlement or
    ///      the proceeds; it claims the 1/1 to an address that can hold it.
    function testGasBurningWinnerFallsBackToClaim() public {
        GasBurner burner = new GasBurner();
        _fund(address(burner));
        _bid(address(burner), 25);
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(address(burner));
        auction.settle();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        assertTrue(!oneOfOne.minted());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 25 * UNIT);
        vm.expectEmit();
        emit KilimAuction.PrizeClaimed(address(burner), CAROL);
        vm.prank(address(burner));
        auction.claimPrize(CAROL);
        assertEq(oneOfOne.ownerOf(1), CAROL);
        assertTrue(auction.prizeClaimed());
    }

    function testOnlyTheAuctionCanDeliverThePrize() public {
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(ALICE);
        auction.deliverPrize();
    }

    function testExactLastSecondBidAndClose() public {
        _bid(ALICE, 25);
        uint256 end = auction.endsAt();
        // One second before the close still extends.
        vm.warp(end - 1);
        _bid(BOB, 27);
        assertEq(auction.endsAt(), end - 1 + 10 minutes);
        // At the close, bidding is over and settlement is open.
        vm.warp(auction.endsAt());
        vm.expectRevert(EnglishAuction.AuctionNotOpen.selector);
        _bid(ALICE, 31);
        auction.settle();
        assertEq(auction.highestBidder(), BOB);
        _assertSolvent();
    }

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 motifReward, uint256 firstMotifId, uint64 endsAt
    );

    function testTreasuryCannotBid() public {
        _fund(TREASURY);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        _bid(TREASURY, 25);
        _bid(ALICE, 25);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        _bid(TREASURY, 27);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.motifCredits(TREASURY), 0);
        assertEq(TREASURY.balance, 1e30);
        _assertSolvent();
    }

    function testMotifIdsAndMotifsAreFixedAtBidTime() public {
        _bid(ALICE, 25); // ids 1-25
        _bid(BOB, 27); // ids 26-52
        uint16[] memory motifs = new uint16[](52);
        for (uint256 i; i < 52; ++i) {
            motifs[i] = nft.motifOf(1 + i);
        }
        // Claim order, timing, block and recipient do not change which ids or motifs bidders receive.
        vm.warp(block.timestamp + 7 hours);
        vm.roll(block.number + 1000);
        vm.prank(BOB);
        auction.claimMotifs(27, CAROL);
        vm.warp(auction.endsAt());
        vm.roll(block.number + 1000);
        auction.settle();
        vm.prank(ALICE);
        auction.claimMotifs(25, BOB);
        for (uint256 i; i < 52; ++i) {
            uint256 id = 1 + i;
            assertEq(nft.ownerOf(id), id < 26 ? BOB : CAROL);
            assertEq(nft.motifOf(id), motifs[i]);
            // Independent reference derivation, so motifOf and the quote cannot drift together.
            assertEq(motifs[i], uint256(keccak256(abi.encode(block.chainid, address(nft), id))) % 1024 + 1);
        }
    }

    function testExpectedFirstMotifIdRejectsMovedRange() public {
        _bid(CAROL, 25); // ids 1-25; Alice is quoted 26 next.
        _bid(BOB, 27); // Lands first and takes 26-52.
        uint256 before = ALICE.balance;
        vm.expectRevert(abi.encodeWithSelector(KilimAuction.MotifRangeMoved.selector, 53));
        vm.prank(ALICE);
        auction.bid{value: 40 * UNIT}(40 * UNIT, 40, 26);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.motifsAllocated(), 52);
        assertEq(auction.motifCredits(ALICE), 0);
        assertEq(ALICE.balance, before);
        _assertSolvent();
        // The matching quote succeeds; 0 accepts whatever is next.
        vm.prank(ALICE);
        auction.bid{value: 40 * UNIT}(40 * UNIT, 40, 53);
        assertEq(auction.unclaimedMotifRanges(ALICE)[0].nextId, 53);
        _bid(CAROL, 42);
        assertEq(auction.unclaimedMotifRanges(CAROL)[1].nextId, 93);
        _assertSolvent();
    }

    function testExpectedFirstMotifIdRejectsExhaustedRewards() public {
        KilimAuction.Config memory c = config(25);
        c.maxMotifsPerBid = 25;
        auction = new KilimAuction(c);
        _openBidding(auction);
        _bid(ALICE, 25);
        vm.expectRevert(abi.encodeWithSelector(KilimAuction.MotifRangeMoved.selector, 0));
        vm.prank(BOB);
        auction.bid{value: 27 * UNIT}(27 * UNIT, 0, 26);
        _bid(BOB, 27);
        assertEq(auction.highestBidder(), BOB);
    }

    function testClaimAboveBatchCapAcrossRangesRejected() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        _bid(ALICE, 29);
        _bid(BOB, 31);
        _bid(ALICE, 33); // 87 credits in ranges of 25, 29 and 33, each below the batch cap.
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        vm.prank(ALICE);
        auction.claimMotifs(65, ALICE);
        vm.prank(ALICE);
        auction.claimMotifs(64, ALICE);
        assertEq(auction.motifCredits(ALICE), 23);
    }

    event MotifsMinted(address indexed recipient, address indexed bidder, uint256 firstId, uint256 count);
    event MotifsClaimed(
        address indexed bidder, address indexed recipient, uint256 count, uint256 firstTokenId
    );

    function testMultiRangeClaimEvents() public {
        _bid(ALICE, 25); // ids 1-25
        _bid(BOB, 27); // ids 26-52
        _bid(ALICE, 29); // ids 53-81
        vm.expectEmit();
        emit MotifsMinted(CAROL, ALICE, 1, 25);
        vm.expectEmit();
        emit MotifsMinted(CAROL, ALICE, 53, 5);
        vm.expectEmit();
        emit MotifsClaimed(ALICE, CAROL, 30, 1);
        vm.prank(ALICE);
        auction.claimMotifs(30, CAROL);
    }

    function testCreditRangesAreFinalBeforeReceiverCallbacks() public {
        // The inspector cannot accept ETH: its refund waits, which changes nothing about its credits.
        RangeInspector inspector = new RangeInspector(auction);
        _fund(address(inspector));
        _bid(address(inspector), 25);
        _bid(BOB, 27);
        _bid(address(inspector), 29);
        // Chunk 1 exhausts the first range; its callbacks must not still see it.
        inspector.execute(address(auction), abi.encodeCall(auction.claimMotifs, (30, address(inspector))));
        assertEq(nft.balanceOf(address(inspector)), 30);
        _assertSolvent();
    }

    function testClaimCallbackCannotReenterBid() public {
        HookedBidder bidder = new HookedBidder();
        _fund(address(bidder));
        _bid(address(bidder), 25);
        _bid(BOB, 27);
        // The callback pays in full, so only the reentrancy guard stops it.
        bidder.hook(address(auction), 29 * UNIT, abi.encodeCall(auction.bid, (29 * UNIT, 0, 0)));
        vm.prank(address(bidder));
        auction.claimMotifs(1, address(bidder));
        assertTrue(!bidder.callbackSucceeded());
        assertEq(nft.ownerOf(1), address(bidder));
        assertEq(auction.highestBidder(), BOB);
        _assertSolvent();
        // The same bid from outside the claim is accepted.
        assertTrue(bidder.fire());
        assertEq(auction.highestBidder(), address(bidder));
        _assertSolvent();
    }

    function testClaimsSpanBidRangesOldestFirst() public {
        _bid(ALICE, 25); // ids 1-25
        _bid(BOB, 27); // ids 26-52
        _bid(ALICE, 29); // ids 53-81
        KilimAuction.CreditRange[] memory ranges = auction.unclaimedMotifRanges(ALICE);
        assertEq(ranges.length, 2);
        assertEq(ranges[0].nextId, 1);
        assertEq(ranges[0].remaining, 25);
        assertEq(ranges[1].nextId, 53);
        assertEq(ranges[1].remaining, 29);
        vm.prank(ALICE);
        auction.claimMotifs(30, ALICE);
        for (uint256 id = 1; id < 26; ++id) {
            assertEq(nft.ownerOf(id), ALICE);
        }
        for (uint256 id = 53; id < 58; ++id) {
            assertEq(nft.ownerOf(id), ALICE);
        }
        vm.expectRevert();
        nft.ownerOf(58);
        ranges = auction.unclaimedMotifRanges(ALICE);
        assertEq(ranges.length, 1);
        assertEq(ranges[0].nextId, 58);
        assertEq(ranges[0].remaining, 24);
        vm.prank(ALICE);
        auction.claimMotifs(24, ALICE);
        assertEq(auction.unclaimedMotifRanges(ALICE).length, 0);
        assertEq(nft.ownerOf(81), ALICE);
        assertEq(nft.balanceOf(ALICE), 54);
        vm.expectRevert();
        nft.ownerOf(26);
    }

    function testBidEventReportsReservedIds() public {
        vm.expectEmit();
        emit BidPlaced(ALICE, 25 * UNIT, 25, 1, uint64(block.timestamp + 22 hours));
        _bid(ALICE, 25);
        uint64 deadline = auction.endsAt();
        vm.expectEmit();
        emit BidPlaced(BOB, 27 * UNIT, 27, 26, deadline);
        _bid(BOB, 27);
    }

    function testExhaustedRewardsReserveNoIds() public {
        KilimAuction.Config memory c = config(30);
        c.maxMotifsPerBid = 25;
        auction = new KilimAuction(c);
        nft = auction.motifs();
        _openBidding(auction);
        _bid(ALICE, 25); // ids 1-25
        _bid(BOB, 27); // ids 26-30, capped
        uint64 deadline = auction.endsAt();
        vm.expectEmit();
        emit BidPlaced(ALICE, 29 * UNIT, 0, 0, deadline);
        _bid(ALICE, 29);
        assertEq(auction.unclaimedMotifRanges(ALICE).length, 1);
        KilimAuction.CreditRange[] memory bobRanges = auction.unclaimedMotifRanges(BOB);
        assertEq(bobRanges[0].nextId, 26);
        assertEq(bobRanges[0].remaining, 5);
        vm.prank(BOB);
        auction.claimMotifs(5, BOB);
        assertEq(nft.ownerOf(30), BOB);
    }

    function testGas64MotifClaimAcrossBids() public {
        _bid(ALICE, 25); // ids 1-25
        _bid(BOB, 27);
        _bid(ALICE, 29); // ids 53-81
        _bid(BOB, 31);
        _bid(ALICE, 33); // ids 113-145
        vm.prank(ALICE);
        uint256 start = gasleft();
        auction.claimMotifs(64, ALICE);
        uint256 used = start - gasleft();
        emit log_named_uint("64-motif claim across 3 bids, execution gas (before refunds)", used);
        assertTrue(used < 10_000_000);
        assertEq(nft.ownerOf(122), ALICE);
    }

    event log_named_uint(string key, uint256 value);

    function testRefundCyclingAccumulatesRewardsForFreeLosingBids() public {
        uint256 aliceBefore = ALICE.balance;
        _bid(ALICE, 25);
        _bid(BOB, 27);
        _bid(ALICE, 29);
        _bid(BOB, 31);
        assertEq(ALICE.balance, aliceBefore);
        assertEq(auction.motifCredits(ALICE), 54);
        assertEq(auction.motifsAllocated(), 112);
        assertEq(address(auction).balance, 31 * UNIT);
        _assertSolvent();
    }

    function testFuzzBidAccounting(uint96 units, uint8 uplift) public {
        uint256 first = 25 + uint256(units) % 1e12;
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        _bid(ALICE, first);
        _assertSolvent();
        uint256 next = auction.minimumBid() + uint256(uplift) * UNIT;
        vm.prank(BOB);
        auction.bid{value: next}(next, 0, 0);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(ALICE.balance, aliceBefore);
        assertEq(BOB.balance, bobBefore - next);
        assertEq(address(auction).balance, next);
        assertEq(auction.liabilities(), next);
        assertTrue(auction.motifsAllocated() <= auction.motifCap());
    }

    /// @dev For any standing bid and increment the minimum is a whole number of units, it is accepted,
    ///      and one unit less is not.
    function testFuzzMinimumBidIsTheSmallestAcceptedWholeUnit(uint64 units, uint16 bps) public {
        KilimAuction.Config memory c = config();
        c.incrementBps = uint16(1 + uint256(bps) % 10000);
        KilimAuction other = new KilimAuction(c);
        _openBidding(other);
        uint256 first = (10 + uint256(units) % 1e12) * UNIT;
        _bid(other, ALICE, first);
        uint256 minimum = other.minimumBid();
        assertEq(minimum % UNIT, 0);
        assertTrue(minimum > first);
        assertTrue((minimum - first) * 10000 >= first * c.incrementBps);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidTooLow.selector, minimum));
        _bid(other, BOB, minimum - UNIT);
        _bid(other, BOB, minimum);
        assertEq(other.highestBid(), minimum);
        uint256 wholeUnits = minimum / UNIT;
        assertEq(other.motifCredits(BOB), wholeUnits < 1000 ? wholeUnits : 1000);
        assertEq(address(other).balance, other.liabilities());
    }
}
