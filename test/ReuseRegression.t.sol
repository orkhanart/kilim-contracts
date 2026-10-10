// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {TestBase} from "./TestBase.sol";

/// @dev Test-only exposure of the imported predicate and quote, without duplicating their formulas.
contract BidRulesHarness is EnglishAuction {
    constructor(AuctionConfig memory c) EnglishAuction(c) {}

    function setStandingBid(uint256 amount) external {
        highestBid = amount;
    }

    function upstreamAccepts(uint256 incoming) external view returns (bool) {
        return _isNewWinningBid(reservePrice, highestBid, incoming, incrementBps);
    }
}

/// @dev A bidder that cannot receive ETH until it is opened.
contract ClosedWallet {
    bool public open;

    function setOpen(bool on) external {
        open = on;
    }

    receive() external payable {
        require(open, "no ETH");
    }
}

contract ReuseRegressionTest is TestBase {
    KilimAuction internal auction;

    function setUp() public {
        auction = new KilimAuction(config());
        _openBidding(auction);
        _fund(ALICE, type(uint128).max);
        _fund(BOB, type(uint128).max);
    }

    function _backed() private view {
        assertEq(address(auction).balance, auction.liabilities());
    }

    function testMismatchedValueRevertsWithoutTakingBid() public {
        // Regression for upstream A-15 M-1: a bid must never keep ETH it did not record.
        uint256[3] memory sent = [RESERVE + 1, RESERVE - 1, 0];
        for (uint256 i; i < sent.length; ++i) {
            vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
            vm.prank(ALICE);
            auction.bid{value: sent[i]}(RESERVE, 0, 0);
        }
        assertEq(ALICE.balance, type(uint128).max);
        assertEq(address(auction).balance, 0);
        assertEq(auction.highestBid(), 0);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.symbolsAllocated(), 0);
        assertEq(auction.symbolCredits(ALICE), 0);
    }

    function testMismatchedOutbidLeavesTheLeaderInPlace() public {
        _bid(auction, ALICE, RESERVE);
        uint64 end = auction.endsAt();
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(BOB);
        auction.bid{value: 12 * UNIT}(11 * UNIT, 0, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(BOB);
        auction.bid{value: RESERVE}(11 * UNIT, 0, 0);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), RESERVE);
        assertEq(auction.endsAt(), end);
        assertEq(auction.symbolCredits(BOB), 0);
        assertEq(auction.symbolsAllocated(), 10);
        assertEq(ALICE.balance, type(uint128).max - RESERVE);
        assertEq(BOB.balance, type(uint128).max);
        _backed();
    }

    function testDirectNativePaymentRejected() public {
        vm.prank(ALICE);
        (bool success,) = address(auction).call{value: 1 ether}("");
        assertTrue(!success);
        // An unknown selector with ETH attached is rejected the same way.
        vm.prank(ALICE);
        (success,) = address(auction).call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(!success);
        assertEq(address(auction).balance, 0);
        assertEq(ALICE.balance, type(uint128).max);
    }

    function testBlockedOutbidRecipientCannotStopNextBid() public {
        ClosedWallet wallet = new ClosedWallet();
        _fund(address(wallet), RESERVE);
        _bid(auction, address(wallet), RESERVE);
        _backed();
        // The automatic refund to a wallet that rejects ETH fails quietly and becomes a pull refund.
        _bid(auction, BOB, 11 * UNIT);
        assertEq(auction.highestBidder(), BOB);
        assertEq(auction.refunds(address(wallet)), RESERVE);
        assertEq(auction.refundLiability(), RESERVE);
        assertEq(address(wallet).balance, 0);
        _backed();
        // Pulling it to the same closed wallet fails and keeps the refund.
        vm.expectRevert(EnglishAuction.EthTransferFailed.selector);
        vm.prank(address(wallet));
        auction.withdrawRefund(address(wallet));
        assertEq(auction.refunds(address(wallet)), RESERVE);
        vm.prank(address(wallet));
        auction.withdrawRefund(CAROL);
        assertEq(CAROL.balance, RESERVE);
        assertEq(auction.refunds(address(wallet)), 0);
        assertEq(auction.symbolCredits(address(wallet)), 10);
        _backed();
    }

    function testSlippageRevertRestoresRefundsDeadlineAndLeader() public {
        vm.prank(ALICE);
        auction.bid{value: RESERVE}(RESERVE, 10, 0);
        uint64 end = auction.endsAt();
        vm.warp(end - 1);
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        vm.prank(BOB);
        auction.bid{value: 11 * UNIT}(11 * UNIT, 12, 0);
        assertEq(auction.endsAt(), end);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.highestBid(), RESERVE);
        assertEq(auction.refundLiability(), 0);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.symbolsAllocated(), 10);
        assertEq(auction.symbolCredits(BOB), 0);
        assertEq(address(auction).balance, RESERVE);
        assertEq(ALICE.balance, type(uint128).max - RESERVE);
        assertEq(BOB.balance, type(uint128).max);
        _backed();
    }

    function testLargestWholeBidRemainsSolventAndCanSettle() public {
        uint256 maximum = (uint256(type(uint128).max) / UNIT) * UNIT;
        _bid(auction, ALICE, maximum);
        assertEq(auction.highestBid(), maximum);
        assertEq(auction.liabilities(), maximum);
        assertEq(address(auction).balance, maximum);
        assertTrue(auction.minimumBid() > type(uint128).max);
        // The auction reaches its amount ceiling; it can still settle and pay the exact bid.
        vm.warp(auction.endsAt());
        auction.settle();
        _backed();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, maximum);
        assertEq(auction.liabilities(), 0);
        assertEq(address(auction).balance, 0);
    }

    function testOversizedBidRejectedBeforeUpstreamMultiplication() public {
        _bid(auction, ALICE, RESERVE);
        vm.expectPartialRevert(EnglishAuction.BidTooLow.selector);
        vm.prank(BOB);
        auction.bid(type(uint256).max, 0, 0);
        // One wei past the bound, paid in full, is rejected the same way.
        uint256 over = uint256(type(uint128).max) + 1;
        _fund(BOB, over);
        vm.expectPartialRevert(EnglishAuction.BidTooLow.selector);
        vm.prank(BOB);
        auction.bid{value: over}(over, 0, 0);
        assertEq(BOB.balance, over);
        assertEq(auction.highestBid(), RESERVE);
        assertEq(auction.refundLiability(), 0);
        _backed();
    }

    function testFuzzWholeUnitQuoteIsSmallestUpstreamAcceptedBid(uint128 standingSeed, uint16 bpsSeed)
        public
    {
        BidRulesHarness rules = new BidRulesHarness(
            EnglishAuction.AuctionConfig({
                treasury: TREASURY,
                startsAt: uint64(block.timestamp + 1),
                duration: 1 days,
                extensionWindow: 1 hours,
                incrementBps: uint16(uint256(bpsSeed) % 10000 + 1),
                reservePrice: RESERVE
            })
        );
        assertEq(rules.SYMBOL_PRICE(), UNIT);
        assertEq(rules.minimumBid(), RESERVE);
        assertTrue(rules.upstreamAccepts(rules.minimumBid()));
        assertTrue(!rules.upstreamAccepts(rules.minimumBid() - UNIT));
        uint256 maxWhole = uint256(type(uint128).max) / UNIT;
        uint256 standing = (uint256(standingSeed) % (maxWhole - 9) + 10) * UNIT;
        rules.setStandingBid(standing);
        uint256 quote = rules.minimumBid();
        assertEq(quote % UNIT, 0);
        assertTrue(quote > standing);
        assertTrue(rules.upstreamAccepts(quote));
        assertTrue(!rules.upstreamAccepts(quote - UNIT));
    }

    function testFuzzLargeOverbidIsCollectedInFull(uint128 seed) public {
        // No buyout branch may clamp payment below the bid recorded as a liability.
        uint256 maxWhole = uint256(type(uint128).max) / UNIT;
        uint256 amount = (uint256(seed) % (maxWhole - 99) + 100) * UNIT;
        _bid(auction, ALICE, RESERVE);
        _bid(auction, BOB, amount);
        assertEq(auction.highestBid(), amount);
        assertEq(auction.refunds(ALICE), 0);
        // Alice has her whole bid back; Bob paid exactly what was recorded.
        assertEq(ALICE.balance, type(uint128).max);
        assertEq(BOB.balance, type(uint128).max - amount);
        assertEq(address(auction).balance, amount);
        _backed();
        vm.warp(auction.endsAt());
        auction.settle();
        _backed();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, amount);
        assertEq(auction.liabilities(), 0);
        assertEq(address(auction).balance, 0);
    }
}
