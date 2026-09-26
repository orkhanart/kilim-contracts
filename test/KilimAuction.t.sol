// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20EnglishAuction} from "../src/auction/ERC20EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";
import {Receiver} from "./mocks/Receiver.sol";
import {RangeInspector} from "./mocks/RangeInspector.sol";

contract KilimAuctionTest is TestBase {
    MockUSD internal usd;
    KilimAuction internal auction;
    Kilim internal nft;

    function setUp() public {
        usd = new MockUSD(6);
        auction = new KilimAuction(config(address(usd)));
        nft = auction.collection();
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        vm.warp(auction.startsAt());
    }

    function _fund(address user) private {
        usd.mint(user, 1e30);
        vm.prank(user);
        usd.approve(address(auction), type(uint256).max);
    }

    function _bid(address user, uint256 dollars) private {
        vm.prank(user);
        auction.bid(dollars * UNIT, 0, 0);
    }

    function testBidEscrowsFundsAndAllocatesCredits() public {
        _bid(ALICE, 25);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), 25 * UNIT);
        assertEq(auction.symbolCredits(ALICE), 25);
        assertEq(usd.balanceOf(address(auction)), auction.liabilities());
        assertEq(nft.symbolsMinted(), 0);
    }

    function testMinimumBidRoundsUpToWholeDollar() public {
        _bid(ALICE, 25);
        assertEq(auction.minimumBid(), 27 * UNIT);
        vm.expectPartialRevert(ERC20EnglishAuction.BidTooLow.selector);
        vm.prank(BOB);
        auction.bid(26 * UNIT, 0, 0);
        _bid(BOB, 27);
        assertEq(auction.minimumBid(), 29 * UNIT);
    }

    function testRejectsFractionalDollarBid() public {
        vm.expectRevert(ERC20EnglishAuction.NonWholeUnitBid.selector);
        vm.prank(ALICE);
        auction.bid(25 * UNIT + 1, 0, 0);
    }

    function testTimeBoundaries() public {
        uint256 start = auction.startsAt();
        vm.warp(start - 1);
        vm.expectRevert(ERC20EnglishAuction.AuctionNotOpen.selector);
        auction.bid(25 * UNIT, 0, 0);
        vm.warp(start);
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        vm.expectRevert(ERC20EnglishAuction.AuctionNotOpen.selector);
        auction.bid(27 * UNIT, 0, 0);
        auction.settle();
        assertTrue(auction.settled());
    }

    function testOutbidRefundAndCreditsRemain() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        uint256 before = usd.balanceOf(CAROL);
        vm.prank(ALICE);
        auction.withdrawRefund(CAROL);
        assertEq(usd.balanceOf(CAROL), before + 25 * UNIT);
        assertEq(auction.symbolCredits(ALICE), 25);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.refundLiability(), 0);
        assertEq(usd.balanceOf(address(auction)), auction.liabilities());
        vm.expectRevert(ERC20EnglishAuction.NothingToWithdraw.selector);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
    }

    function testSelfOutbidFullyFundedAndLiabilitiesConserved() public {
        _bid(ALICE, 25);
        _bid(ALICE, 27);
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        assertEq(auction.symbolCredits(ALICE), 52);
        assertEq(usd.balanceOf(address(auction)), 52 * UNIT);
        assertEq(auction.liabilities(), 52 * UNIT);
    }

    function testRejectedDepositRollsBackStandingBidAndRewards() public {
        _bid(ALICE, 25);
        vm.prank(BOB);
        usd.approve(address(auction), 0);
        vm.expectRevert();
        _bid(BOB, 27);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.refundLiability(), 0);
        assertEq(auction.symbolsAllocated(), 25);
    }

    function testRejectsFeeOnTransferDeposit() public {
        usd.setFee(100);
        vm.expectRevert(ERC20EnglishAuction.UnsupportedTokenBehavior.selector);
        _bid(ALICE, 25);
        assertEq(auction.highestBid(), 0);
        assertEq(usd.balanceOf(address(auction)), 0);
    }

    function testFalseReturnTokenRejected() public {
        usd.setReturnsFalse(true);
        vm.expectRevert();
        _bid(ALICE, 25);
        assertEq(auction.symbolsAllocated(), 0);
    }

    function testRejectedRefundPreservesEntitlement() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        usd.setBlockedRecipient(ALICE);
        vm.expectRevert();
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        // The same claimant can choose a working recipient.
        vm.prank(ALICE);
        auction.withdrawRefund(CAROL);
        assertEq(auction.refunds(ALICE), 0);
    }

    function testFeeOnWithdrawalRevertsWithoutLosingRefund() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        usd.setFee(100);
        vm.expectRevert(ERC20EnglishAuction.UnsupportedTokenBehavior.selector);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        assertEq(usd.balanceOf(address(auction)), 52 * UNIT);
    }

    function testCannotStealAnotherBiddersRefund() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        vm.expectRevert(ERC20EnglishAuction.NothingToWithdraw.selector);
        vm.prank(CAROL);
        auction.withdrawRefund(CAROL);
    }

    function testTokenCallbackCannotReenterBidOrRefund() public {
        usd.setHook(address(auction), abi.encodeCall(auction.bid, (27 * UNIT, 0, 0)));
        _bid(ALICE, 25);
        assertTrue(!usd.callbackSucceeded());
        _bid(BOB, 27);
        usd.setHook(address(auction), abi.encodeCall(auction.withdrawRefund, (CAROL)));
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertTrue(!usd.callbackSucceeded());
        assertEq(auction.refundLiability(), 0);
    }

    /// @dev A token hook during a refund payout cannot reach another entry point that would succeed.
    function testRefundTokenHookCannotSettle() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        vm.warp(auction.endsAt());
        usd.setHook(address(auction), abi.encodeCall(auction.settle, ()));
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertTrue(!usd.callbackSucceeded());
        assertTrue(!auction.settled());
        usd.setHook(address(0), "");
        auction.settle();
    }

    /// @dev The winner's receiver also has a refund due; the prize callback still cannot withdraw it.
    function testPrizeCallbackCannotWithdrawARefund() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        _bid(BOB, 27);
        _bid(address(receiver), 29);
        vm.warp(auction.endsAt());
        auction.settle();
        receiver.configure(
            false, address(auction), abi.encodeCall(auction.withdrawRefund, (address(receiver)))
        );
        vm.prank(address(receiver));
        auction.claimPrize(address(receiver));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(nft.ownerOf(1), address(receiver));
        assertEq(auction.refunds(address(receiver)), 25 * UNIT);
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
            uint256 next = auction.minimumBid();
            vm.prank(ALICE);
            auction.bid(next, 0, 0);
            assertEq(auction.endsAt(), block.timestamp + 10 minutes);
        }
        // No absolute end: extensions have pushed the close past the original duration.
        assertTrue(auction.endsAt() > firstBidAt + 22 hours);
    }

    function _bidMinimum(address user) private {
        uint256 amount = auction.minimumBid();
        vm.prank(user);
        auction.bid(amount, 0, 0);
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
        vm.expectRevert(ERC20EnglishAuction.NoBids.selector);
        auction.settle();
        vm.expectRevert(ERC20EnglishAuction.NotSettled.selector);
        vm.prank(TREASURY);
        auction.claimPrize(TREASURY);
        assertTrue(!nft.masterpieceMinted());
        // Bidding still works whenever someone finally arrives.
        _bid(ALICE, 25);
        assertEq(auction.endsAt(), block.timestamp + 22 hours);
    }

    function testSettlementAndProceedsLeaveRefundsSolvent() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        vm.warp(auction.endsAt());
        vm.prank(CAROL);
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(usd.balanceOf(TREASURY), 27 * UNIT);
        assertEq(usd.balanceOf(address(auction)), 25 * UNIT);
        assertEq(auction.liabilities(), 25 * UNIT);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(auction.liabilities(), 0);
        assertEq(usd.balanceOf(address(auction)), 0);
    }

    function testSettlementTimingAndIdempotence() public {
        vm.expectRevert(ERC20EnglishAuction.NoBids.selector);
        auction.settle();
        _bid(ALICE, 25);
        vm.expectRevert(ERC20EnglishAuction.AuctionNotEnded.selector);
        auction.settle();
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(ERC20EnglishAuction.AlreadySettled.selector);
        auction.settle();
    }

    function testOnlyTreasuryCanWithdrawOnlyAfterSettlement() public {
        _bid(ALICE, 25);
        vm.expectRevert(ERC20EnglishAuction.Unauthorized.selector);
        vm.prank(ALICE);
        auction.withdrawProceeds(ALICE);
        vm.expectRevert(ERC20EnglishAuction.NotSettled.selector);
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
    }

    function testWinnerClaimsExactlyOnePrizeToChosenRecipient() public {
        _bid(ALICE, 25);
        vm.expectRevert(ERC20EnglishAuction.NotSettled.selector);
        vm.prank(ALICE);
        auction.claimPrize(ALICE);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(ERC20EnglishAuction.Unauthorized.selector);
        vm.prank(BOB);
        auction.claimPrize(BOB);
        vm.prank(ALICE);
        auction.claimPrize(CAROL);
        assertEq(nft.ownerOf(1), CAROL);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        vm.prank(ALICE);
        auction.claimPrize(ALICE);
    }

    function testTreasuryCannotClaimPrizeAfterSomeoneBids() public {
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(ERC20EnglishAuction.Unauthorized.selector);
        vm.prank(TREASURY);
        auction.claimPrize(TREASURY);
        vm.prank(ALICE);
        auction.claimPrize(CAROL);
        assertEq(nft.ownerOf(1), CAROL);
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
        vm.prank(address(receiver));
        auction.claimPrize(CAROL);
        assertEq(nft.ownerOf(1), CAROL);
    }

    function testSymbolClaimsBoundedAndNeverForfeitWithRefund() public {
        _bid(ALICE, 100);
        _bid(BOB, 105);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        vm.prank(ALICE);
        auction.claimSymbols(64, CAROL);
        vm.prank(ALICE);
        auction.claimSymbols(36, ALICE);
        assertEq(nft.balanceOf(CAROL), 64);
        assertEq(nft.balanceOf(ALICE), 36);
        assertEq(auction.symbolCredits(ALICE), 0);
        assertEq(auction.symbolsClaimed(), nft.symbolsMinted());
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        vm.prank(ALICE);
        auction.claimSymbols(1, ALICE);
    }

    function testInvalidClaimQuantities() public {
        _bid(ALICE, 100);
        vm.startPrank(ALICE);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.claimSymbols(0, ALICE);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.claimSymbols(65, ALICE);
        vm.stopPrank();
    }

    function testRejectingReceiverDoesNotConsumeSymbolCredits() public {
        _bid(ALICE, 25);
        Receiver receiver = new Receiver();
        receiver.configure(true, address(0), "");
        vm.expectRevert();
        vm.prank(ALICE);
        auction.claimSymbols(4, address(receiver));
        assertEq(auction.symbolCredits(ALICE), 25);
        assertEq(nft.symbolsMinted(), 0);
    }

    function testNftCallbackCannotDoubleClaim() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        receiver.configure(false, address(auction), abi.encodeCall(auction.claimSymbols, (4, CAROL)));
        vm.prank(address(receiver));
        auction.claimSymbols(4, address(receiver));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(auction.symbolCredits(address(receiver)), 21);
        assertEq(nft.symbolsMinted(), 4);
    }

    function testRewardCapDoesNotBlockCompetitiveBids() public {
        KilimAuction.Config memory c = config(address(usd));
        c.symbolCap = 30;
        c.maxSymbolsPerBid = 25;
        auction = new KilimAuction(c);
        _fund(ALICE);
        _fund(BOB);
        vm.warp(auction.startsAt());
        _bid(ALICE, 25);
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        vm.prank(BOB);
        auction.bid(27 * UNIT, 6, 0);
        vm.prank(BOB);
        auction.bid(27 * UNIT, 5, 0);
        _bid(ALICE, 29);
        assertEq(auction.symbolsAllocated(), 30);
        assertEq(auction.highestBid(), 29 * UNIT);
        assertEq(auction.rewardForBid(1000 * UNIT), 0);
    }

    function testPerBidRewardCap() public {
        _bid(ALICE, 1001);
        assertEq(auction.symbolCredits(ALICE), 1000);
    }

    function testDonationsDoNotAlterLiabilitiesOrRewards() public {
        _bid(ALICE, 25);
        usd.mint(address(auction), 100 * UNIT);
        assertEq(auction.liabilities(), 25 * UNIT);
        assertEq(auction.symbolsAllocated(), 25);
        vm.warp(auction.endsAt());
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(usd.balanceOf(TREASURY), 25 * UNIT);
        assertEq(usd.balanceOf(address(auction)), 100 * UNIT);
    }

    function testInvalidRecipientsDoNotDestroyClaims() public {
        _bid(ALICE, 25);
        _bid(BOB, 27);
        address[3] memory bad = [address(0), address(auction), address(nft)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ERC20EnglishAuction.InvalidRecipient.selector);
            vm.prank(ALICE);
            auction.withdrawRefund(bad[i]);
            vm.expectRevert(ERC20EnglishAuction.InvalidRecipient.selector);
            vm.prank(ALICE);
            auction.claimSymbols(1, bad[i]);
            // The recipient is checked before the quantity.
            vm.expectRevert(ERC20EnglishAuction.InvalidRecipient.selector);
            vm.prank(ALICE);
            auction.claimSymbols(0, bad[i]);
        }
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        assertEq(auction.symbolCredits(ALICE), 25);
    }

    function testConstructorRejectsInvalidConfiguration() public {
        KilimAuction.Config memory c = config(address(usd));
        c.treasury = address(0);
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config(address(usd));
        c.startsAt = uint64(block.timestamp);
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config(address(usd));
        c.incrementBps = 0;
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config(address(usd));
        c.reservePrice += 1;
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        c = config(address(new MockUSD(19)));
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    /// @dev The collection's address is known before deployment (the auction's first CREATE), so a config
    ///      can name it as the treasury by mistake. It could never withdraw the proceeds.
    function testTreasuryCannotBeTheCollection() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        KilimAuction.Config memory c = config(address(usd));
        c.treasury = vm.computeCreateAddress(next, 1);
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        // The prediction is right: a valid deployment puts its collection exactly there.
        next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        KilimAuction deployed = new KilimAuction(config(address(usd)));
        assertEq(address(deployed), next);
        assertEq(address(deployed.collection()), vm.computeCreateAddress(next, 1));
    }

    function testFuzzInvalidAuctionConfiguration(uint8 selector) public {
        KilimAuction.Config memory c = config(address(usd));
        uint256 choice = uint256(selector) % 11;
        if (choice == 0) c.paymentToken = ALICE;
        else if (choice == 1) c.duration = 0;
        else if (choice == 2) c.duration = 30 days + 1;
        else if (choice == 3) c.extensionWindow = c.duration + 1;
        else if (choice == 4) c.extensionWindow = 0;
        else if (choice == 5) c.incrementBps = 10001;
        else if (choice == 6) c.symbolCap = 0;
        else if (choice == 7) c.symbolCap = uint256(type(uint64).max) + 1;
        else if (choice == 8) c.maxSymbolsPerBid = 0;
        else if (choice == 9) c.maxSymbolsPerBid = c.symbolCap + 1;
        else c.reservePrice = 0;
        vm.expectRevert(ERC20EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    function testRepeatedProceedsWithdrawalAndFailedPayment() public {
        _bid(ALICE, 25);
        vm.warp(auction.endsAt());
        auction.settle();
        usd.setBlockedRecipient(TREASURY);
        vm.expectRevert();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(auction.proceedsDue(), 25 * UNIT);
        vm.prank(TREASURY);
        auction.withdrawProceeds(CAROL);
        vm.expectRevert(ERC20EnglishAuction.NothingToWithdraw.selector);
        vm.prank(TREASURY);
        auction.withdrawProceeds(CAROL);
    }

    function testNftReceiverCannotDoubleClaimPrize() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        vm.warp(auction.endsAt());
        auction.settle();
        receiver.configure(false, address(auction), abi.encodeCall(auction.claimPrize, (CAROL)));
        vm.prank(address(receiver));
        auction.claimPrize(address(receiver));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(nft.ownerOf(1), address(receiver));
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
        vm.expectRevert(ERC20EnglishAuction.AuctionNotOpen.selector);
        vm.prank(ALICE);
        auction.bid(31 * UNIT, 0, 0);
        auction.settle();
        assertEq(auction.highestBidder(), BOB);
    }

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 symbolReward, uint256 firstSymbolId, uint64 endsAt
    );

    function testTreasuryCannotBid() public {
        _fund(TREASURY);
        vm.expectRevert(ERC20EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(TREASURY);
        auction.bid(25 * UNIT, 0, 0);
        _bid(ALICE, 25);
        vm.expectRevert(ERC20EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(TREASURY);
        auction.bid(27 * UNIT, 0, 0);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.symbolCredits(TREASURY), 0);
    }

    function testSymbolIdsAndTraitsAreFixedAtBidTime() public {
        _bid(ALICE, 25); // IDs 2-26
        _bid(BOB, 27); // IDs 27-53
        bytes32[] memory seeds = new bytes32[](52);
        uint16[] memory motifs = new uint16[](52);
        uint8[] memory materials = new uint8[](52);
        for (uint256 i; i < 52; ++i) {
            (seeds[i], motifs[i], materials[i]) = nft.symbolTraits(2 + i);
        }
        // Claim order, timing, block and recipient do not change which IDs or traits bidders receive.
        vm.warp(block.timestamp + 7 hours);
        vm.roll(block.number + 1000);
        vm.prank(BOB);
        auction.claimSymbols(27, CAROL);
        vm.warp(auction.endsAt());
        vm.roll(block.number + 1000);
        auction.settle();
        vm.prank(ALICE);
        auction.claimSymbols(25, BOB);
        for (uint256 i; i < 52; ++i) {
            uint256 id = 2 + i;
            assertEq(nft.ownerOf(id), id < 27 ? BOB : CAROL);
            Kilim.SymbolData memory symbol = nft.symbolData(id);
            assertEq(symbol.seed, seeds[i]);
            assertEq(symbol.motif, motifs[i]);
            assertEq(symbol.material, materials[i]);
        }
    }

    function testExpectedFirstSymbolIdRejectsMovedRange() public {
        _bid(CAROL, 25); // IDs 2-26; Alice is quoted 27 next.
        _bid(BOB, 27); // Lands first and takes 27-53.
        uint256 before = usd.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KilimAuction.SymbolRangeMoved.selector, 54));
        vm.prank(ALICE);
        auction.bid(40 * UNIT, 40, 27);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.symbolsAllocated(), 52);
        assertEq(auction.symbolCredits(ALICE), 0);
        assertEq(usd.balanceOf(ALICE), before);
        // The matching quote succeeds; 0 accepts whatever is next.
        vm.prank(ALICE);
        auction.bid(40 * UNIT, 40, 54);
        assertEq(auction.unclaimedSymbolRanges(ALICE)[0].nextId, 54);
        vm.prank(CAROL);
        auction.bid(42 * UNIT, 0, 0);
        assertEq(auction.unclaimedSymbolRanges(CAROL)[1].nextId, 94);
    }

    function testExpectedFirstSymbolIdRejectsExhaustedRewards() public {
        KilimAuction.Config memory c = config(address(usd));
        c.symbolCap = 25;
        c.maxSymbolsPerBid = 25;
        auction = new KilimAuction(c);
        _fund(ALICE);
        _fund(BOB);
        vm.warp(auction.startsAt());
        _bid(ALICE, 25);
        vm.expectRevert(abi.encodeWithSelector(KilimAuction.SymbolRangeMoved.selector, 0));
        vm.prank(BOB);
        auction.bid(27 * UNIT, 0, 27);
        vm.prank(BOB);
        auction.bid(27 * UNIT, 0, 0);
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
        auction.claimSymbols(65, ALICE);
        vm.prank(ALICE);
        auction.claimSymbols(64, ALICE);
        assertEq(auction.symbolCredits(ALICE), 23);
    }

    event SymbolsMinted(address indexed recipient, address indexed bidder, uint256 firstId, uint256 count);
    event SymbolsClaimed(
        address indexed bidder, address indexed recipient, uint256 count, uint256 firstTokenId
    );

    function testMultiRangeClaimEvents() public {
        _bid(ALICE, 25); // IDs 2-26
        _bid(BOB, 27); // IDs 27-53
        _bid(ALICE, 29); // IDs 54-82
        vm.expectEmit();
        emit SymbolsMinted(CAROL, ALICE, 2, 25);
        vm.expectEmit();
        emit SymbolsMinted(CAROL, ALICE, 54, 5);
        vm.expectEmit();
        emit SymbolsClaimed(ALICE, CAROL, 30, 2);
        vm.prank(ALICE);
        auction.claimSymbols(30, CAROL);
    }

    function testCreditRangesAreFinalBeforeReceiverCallbacks() public {
        RangeInspector inspector = new RangeInspector(auction);
        _fund(address(inspector));
        vm.prank(address(inspector));
        usd.approve(address(auction), type(uint256).max);
        inspector.execute(address(auction), abi.encodeCall(auction.bid, (25 * UNIT, 0, 0)));
        _bid(BOB, 27);
        inspector.execute(address(auction), abi.encodeCall(auction.bid, (29 * UNIT, 0, 0)));
        // Chunk 1 exhausts the first range; its callbacks must not still see it.
        inspector.execute(address(auction), abi.encodeCall(auction.claimSymbols, (30, address(inspector))));
        assertEq(nft.balanceOf(address(inspector)), 30);
    }

    function testClaimCallbackCannotReenterBid() public {
        Receiver receiver = new Receiver();
        _fund(address(receiver));
        _bid(address(receiver), 25);
        _bid(BOB, 27);
        receiver.configure(false, address(auction), abi.encodeCall(auction.bid, (29 * UNIT, 0, 0)));
        vm.prank(address(receiver));
        auction.claimSymbols(1, address(receiver));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(auction.highestBidder(), BOB);
    }

    function testClaimsSpanBidRangesOldestFirst() public {
        _bid(ALICE, 25); // IDs 2-26
        _bid(BOB, 27); // IDs 27-53
        _bid(ALICE, 29); // IDs 54-82
        KilimAuction.CreditRange[] memory ranges = auction.unclaimedSymbolRanges(ALICE);
        assertEq(ranges.length, 2);
        assertEq(ranges[0].nextId, 2);
        assertEq(ranges[0].remaining, 25);
        assertEq(ranges[1].nextId, 54);
        assertEq(ranges[1].remaining, 29);
        vm.prank(ALICE);
        auction.claimSymbols(30, ALICE);
        for (uint256 id = 2; id < 27; ++id) {
            assertEq(nft.ownerOf(id), ALICE);
        }
        for (uint256 id = 54; id < 59; ++id) {
            assertEq(nft.ownerOf(id), ALICE);
        }
        vm.expectRevert();
        nft.ownerOf(59);
        ranges = auction.unclaimedSymbolRanges(ALICE);
        assertEq(ranges.length, 1);
        assertEq(ranges[0].nextId, 59);
        assertEq(ranges[0].remaining, 24);
        vm.prank(ALICE);
        auction.claimSymbols(24, ALICE);
        assertEq(auction.unclaimedSymbolRanges(ALICE).length, 0);
        assertEq(nft.ownerOf(82), ALICE);
        assertEq(nft.balanceOf(ALICE), 54);
        vm.expectRevert();
        nft.ownerOf(27);
    }

    function testBidEventReportsReservedIds() public {
        vm.expectEmit();
        emit BidPlaced(ALICE, 25 * UNIT, 25, 2, uint64(block.timestamp + 22 hours));
        _bid(ALICE, 25);
        uint64 deadline = auction.endsAt();
        vm.expectEmit();
        emit BidPlaced(BOB, 27 * UNIT, 27, 27, deadline);
        _bid(BOB, 27);
    }

    function testExhaustedRewardsReserveNoIds() public {
        KilimAuction.Config memory c = config(address(usd));
        c.symbolCap = 30;
        c.maxSymbolsPerBid = 25;
        auction = new KilimAuction(c);
        nft = auction.collection();
        _fund(ALICE);
        _fund(BOB);
        vm.warp(auction.startsAt());
        _bid(ALICE, 25); // IDs 2-26
        _bid(BOB, 27); // IDs 27-31, capped
        uint64 deadline = auction.endsAt();
        vm.expectEmit();
        emit BidPlaced(ALICE, 29 * UNIT, 0, 0, deadline);
        _bid(ALICE, 29);
        assertEq(auction.unclaimedSymbolRanges(ALICE).length, 1);
        KilimAuction.CreditRange[] memory bobRanges = auction.unclaimedSymbolRanges(BOB);
        assertEq(bobRanges[0].nextId, 27);
        assertEq(bobRanges[0].remaining, 5);
        vm.prank(BOB);
        auction.claimSymbols(5, BOB);
        assertEq(nft.ownerOf(31), BOB);
    }

    function testGas64SymbolClaimAcrossBids() public {
        _bid(ALICE, 25); // IDs 2-26
        _bid(BOB, 27);
        _bid(ALICE, 29); // IDs 54-82
        _bid(BOB, 31);
        _bid(ALICE, 33); // IDs 114-146
        vm.prank(ALICE);
        uint256 start = gasleft();
        auction.claimSymbols(64, ALICE);
        uint256 used = start - gasleft();
        emit log_named_uint("64-symbol claim across 3 bids, execution gas (before refunds)", used);
        assertTrue(used < 10_000_000);
        assertEq(nft.ownerOf(123), ALICE);
    }

    event log_named_uint(string key, uint256 value);

    function testRefundCyclingAccumulatesRewardsForFreeLosingBids() public {
        uint256 aliceBefore = usd.balanceOf(ALICE);
        _bid(ALICE, 25);
        _bid(BOB, 27);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        _bid(ALICE, 29);
        vm.prank(BOB);
        auction.withdrawRefund(BOB);
        _bid(BOB, 31);
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(usd.balanceOf(ALICE), aliceBefore);
        assertEq(auction.symbolCredits(ALICE), 54);
        assertEq(auction.symbolsAllocated(), 112);
        assertEq(usd.balanceOf(address(auction)), 31 * UNIT);
    }

    function testFuzzBidAccounting(uint96 dollars, uint8 uplift) public {
        uint256 first = 25 + uint256(dollars) % 1e12;
        _bid(ALICE, first);
        uint256 next = auction.minimumBid() + uint256(uplift) * UNIT;
        vm.prank(BOB);
        auction.bid(next, 0, 0);
        assertEq(auction.refunds(ALICE), first * UNIT);
        assertEq(usd.balanceOf(address(auction)), first * UNIT + next);
        assertEq(auction.liabilities(), usd.balanceOf(address(auction)));
        vm.prank(ALICE);
        auction.withdrawRefund(ALICE);
        assertEq(auction.liabilities(), next);
        assertTrue(auction.symbolsAllocated() <= auction.symbolCap());
    }

    function testFuzzDecimalsAndWholeUnitRounding(uint8 decimals_) public {
        decimals_ = uint8(uint256(decimals_) % 19);
        MockUSD token = new MockUSD(decimals_);
        KilimAuction.Config memory c = config(address(token));
        uint256 unit = 10 ** uint256(decimals_);
        c.reservePrice = 25 * unit;
        KilimAuction other = new KilimAuction(c);
        token.mint(ALICE, 100 * unit);
        vm.startPrank(ALICE);
        token.approve(address(other), 100 * unit);
        vm.warp(other.startsAt());
        other.bid(25 * unit, 25, 0);
        vm.stopPrank();
        assertEq(other.minimumBid(), 27 * unit);
        assertEq(other.symbolCredits(ALICE), 25);
    }
}
