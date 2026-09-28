// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20EnglishAuction} from "../src/auction/ERC20EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @dev Test-only exposure of the imported predicate and quote, without duplicating their formulas.
contract BidRulesHarness is ERC20EnglishAuction {
    constructor(AuctionConfig memory c) ERC20EnglishAuction(c) {}

    function setStandingBid(uint256 amount) external {
        highestBid = amount;
    }

    function upstreamAccepts(uint256 incoming) external view returns (bool) {
        return _isNewWinningBid(reservePrice, highestBid, incoming, incrementBps);
    }
}

contract ReuseRegressionTest is TestBase {
    MockUSD internal usd;
    KilimAuction internal auction;

    function setUp() public {
        usd = new MockUSD(6);
        auction = new KilimAuction(config(address(usd)));
        usd.mint(ALICE, type(uint128).max);
        usd.mint(BOB, type(uint128).max);
        vm.prank(ALICE);
        usd.approve(address(auction), type(uint256).max);
        vm.prank(BOB);
        usd.approve(address(auction), type(uint256).max);
        vm.warp(auction.startsAt());
    }

    function testAccidentalNativeValueRevertsWithoutTakingBid() public {
        // Regression for upstream A-15 M-1: payable ERC-20 bids used to trap attached ETH.
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool success,) =
            address(auction).call{value: 1 ether}(abi.encodeCall(auction.bid, (25 * UNIT, 0, 0)));
        assertTrue(!success);
        assertEq(address(auction).balance, 0);
        assertEq(auction.highestBid(), 0);
        assertEq(auction.symbolsAllocated(), 0);
        assertEq(usd.balanceOf(address(auction)), 0);
    }

    function testDirectNativePaymentRejected() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool success,) = address(auction).call{value: 1 ether}("");
        assertTrue(!success);
        assertEq(address(auction).balance, 0);
    }

    function testBlockedOutbidRecipientCannotStopNextBid() public {
        vm.prank(ALICE);
        auction.bid(25 * UNIT, 25, 0);
        // The automatic refund to a blocked old bidder fails quietly and becomes a pull refund.
        usd.setBlockedRecipient(ALICE);
        vm.prank(BOB);
        auction.bid(27 * UNIT, 27, 0);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.refunds(ALICE), 25 * UNIT);
        assertEq(auction.liabilities(), usd.balanceOf(address(auction)));
        vm.prank(ALICE);
        auction.withdrawRefund(CAROL);
        assertEq(usd.balanceOf(CAROL), 25 * UNIT);
        assertEq(auction.symbolCredits(ALICE), 25);
    }

    function testSlippageRevertRestoresRefundsDeadlineAndLeader() public {
        vm.prank(ALICE);
        auction.bid(25 * UNIT, 25, 0);
        uint64 end = auction.endsAt();
        vm.warp(end - 1);
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        vm.prank(BOB);
        auction.bid(27 * UNIT, 28, 0);
        assertEq(auction.endsAt(), end);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), 25 * UNIT);
        assertEq(auction.refundLiability(), 0);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.symbolsAllocated(), 25);
        assertEq(auction.symbolCredits(BOB), 0);
        assertEq(usd.balanceOf(address(auction)), 25 * UNIT);
    }

    function testLargestWholeBidRemainsSolventAndCanSettle() public {
        uint256 maximum = (uint256(type(uint128).max) / UNIT) * UNIT;
        vm.prank(ALICE);
        auction.bid(maximum, 0, 0);
        assertEq(auction.highestBid(), maximum);
        assertEq(auction.liabilities(), maximum);
        assertTrue(auction.minimumBid() > type(uint128).max);
        // The auction reaches its amount ceiling; it can still settle and pay the exact bid.
        vm.warp(auction.endsAt());
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(usd.balanceOf(TREASURY), maximum);
        assertEq(auction.liabilities(), 0);
    }

    function testOversizedBidRejectedBeforeUpstreamMultiplication() public {
        vm.prank(ALICE);
        auction.bid(25 * UNIT, 0, 0);
        vm.expectPartialRevert(ERC20EnglishAuction.BidTooLow.selector);
        vm.prank(BOB);
        auction.bid(type(uint256).max, 0, 0);
        assertEq(auction.highestBid(), 25 * UNIT);
        assertEq(auction.refundLiability(), 0);
    }

    function testFuzzWholeUnitQuoteIsSmallestUpstreamAcceptedBid(
        uint128 standingSeed,
        uint16 bpsSeed,
        uint8 decimalsSeed
    ) public {
        uint8 decimals = decimalsSeed % 19;
        MockUSD token = new MockUSD(decimals);
        uint256 unit = 10 ** uint256(decimals);
        BidRulesHarness rules = new BidRulesHarness(
            ERC20EnglishAuction.AuctionConfig({
                paymentToken: address(token),
                treasury: TREASURY,
                startsAt: uint64(block.timestamp + 1),
                duration: 1 days,
                extensionWindow: 1 hours,
                incrementBps: uint16(uint256(bpsSeed) % 10000 + 1),
                reservePrice: 25 * unit
            })
        );
        assertEq(rules.minimumBid(), 25 * unit);
        assertTrue(rules.upstreamAccepts(rules.minimumBid()));
        assertTrue(!rules.upstreamAccepts(rules.minimumBid() - unit));
        uint256 maxWhole = uint256(type(uint128).max) / unit;
        uint256 standing = (uint256(standingSeed) % (maxWhole - 24) + 25) * unit;
        rules.setStandingBid(standing);
        uint256 quote = rules.minimumBid();
        assertEq(quote % unit, 0);
        assertTrue(quote > standing);
        assertTrue(rules.upstreamAccepts(quote));
        assertTrue(!rules.upstreamAccepts(quote - unit));
    }

    function testFuzzLargeOverbidIsCollectedInFull(uint128 seed) public {
        // No buyout branch may clamp payment below the bid recorded as a liability.
        uint256 maxWhole = uint256(type(uint128).max) / UNIT;
        uint256 amount = (uint256(seed) % (maxWhole - 99) + 100) * UNIT;
        vm.prank(ALICE);
        auction.bid(25 * UNIT, 0, 0);
        vm.prank(BOB);
        auction.bid(amount, 0, 0);
        assertEq(auction.highestBid(), amount);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(usd.balanceOf(address(auction)), amount);
        assertEq(auction.liabilities(), usd.balanceOf(address(auction)));
        vm.warp(auction.endsAt());
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(usd.balanceOf(TREASURY), amount);
        assertEq(auction.liabilities(), 0);
        assertEq(usd.balanceOf(address(auction)), 0);
    }
}
