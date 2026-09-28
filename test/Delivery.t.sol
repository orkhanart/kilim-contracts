// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20EnglishAuction} from "../src/auction/ERC20EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";
import {Receiver} from "./mocks/Receiver.sol";
import {GasBurner} from "./mocks/GasBurner.sol";

/// @notice Automatic delivery: every reserved symbol reaches the wallet that bid for it, without the
///         bidder doing anything, in batches anyone can send. A wallet that cannot take the tokens
///         is skipped, never blocks the others, and keeps its symbols to claim by hand.
contract DeliveryTest is TestBase {
    MockUSD internal usd;
    KilimAuction internal auction;
    Kilim internal nft;

    function setUp() public {
        usd = new MockUSD(6);
        auction = new KilimAuction(config(address(usd)));
        nft = auction.collection();
        vm.warp(auction.startsAt());
    }

    function _bid(address user, uint256 dollars) private {
        usd.mint(user, dollars * UNIT);
        vm.prank(user);
        usd.approve(address(auction), dollars * UNIT);
        vm.prank(user);
        auction.bid(dollars * UNIT, 0, 0);
    }

    function testDeliversEveryBidderOldestFirstWithNoActionFromThem() public {
        _bid(ALICE, 30);
        _bid(BOB, 40);
        _bid(ALICE, 50);
        assertEq(auction.symbolsPending(), 120);
        // Anyone sends the batches; here a stranger.
        vm.prank(CAROL);
        assertEq(auction.deliverSymbols(64), 64);
        // Alice's first entry takes all 80 of her symbols, oldest first: 64 now.
        assertEq(nft.balanceOf(ALICE), 64);
        assertEq(nft.ownerOf(2), ALICE);
        assertEq(auction.deliverSymbols(64), 56);
        assertEq(nft.balanceOf(ALICE), 80);
        assertEq(nft.balanceOf(BOB), 40);
        assertEq(nft.ownerOf(32), BOB);
        assertEq(auction.symbolsPending(), 0);
        assertEq(auction.symbolCredits(ALICE), 0);
        assertEq(auction.symbolCredits(BOB), 0);
        // Nothing left: a further call delivers nothing and walks past the spent entries.
        assertEq(auction.deliverSymbols(64), 0);
        assertEq(auction.deliveryCursor(), 3);
        assertEq(nft.symbolsMinted(), auction.symbolsAllocated());
    }

    function testNewBidsAfterADeliveryAreDeliveredToo() public {
        _bid(ALICE, 25);
        auction.deliverSymbols(64);
        _bid(BOB, 28);
        assertEq(auction.deliverSymbols(64), 28);
        assertEq(nft.balanceOf(BOB), 28);
    }

    function testManualClaimsAreSkippedNotDoubleMinted() public {
        _bid(ALICE, 25);
        _bid(BOB, 28);
        vm.prank(ALICE);
        auction.claimSymbols(4, CAROL);
        assertEq(auction.deliverSymbols(64), 49);
        assertEq(nft.balanceOf(CAROL), 4);
        assertEq(nft.balanceOf(ALICE), 21);
        assertEq(nft.balanceOf(BOB), 28);
        assertEq(auction.symbolsPending(), 0);
    }

    function testRejectingWalletIsSkippedAndClaimsByHand() public {
        Receiver shut = new Receiver();
        shut.configure(true, address(0), "");
        _bid(address(shut), 25);
        _bid(BOB, 28);
        vm.expectEmit();
        emit KilimAuction.DeliveryFailed(address(shut), 25);
        assertEq(auction.deliverSymbols(64), 28);
        assertEq(nft.balanceOf(BOB), 28);
        assertEq(auction.symbolCredits(address(shut)), 25);
        assertEq(auction.deliveryCursor(), 2);
        // The skipped wallet still owns its reservation and sends it elsewhere.
        vm.prank(address(shut));
        auction.claimSymbols(25, CAROL);
        assertEq(nft.balanceOf(CAROL), 25);
    }

    function testGasBurningWalletCannotStallTheQueue() public {
        GasBurner burner = new GasBurner();
        _bid(address(burner), 25);
        _bid(BOB, 28);
        uint256 before = gasleft();
        assertEq(auction.deliverSymbols(64), 28);
        // It burned at most its own allowance, 25 x 150k, and Bob was still delivered.
        assertTrue(before - gasleft() < 25 * 150_000 + 2_500_000);
        assertEq(auction.symbolCredits(address(burner)), 25);
        assertEq(nft.balanceOf(BOB), 28);
    }

    function testTooLittleGasStopsWithoutSkippingAnyone() public {
        _bid(ALICE, 64);
        (bool ok,) = address(auction).call{gas: 2_000_000}(abi.encodeCall(auction.deliverSymbols, (64)));
        assertTrue(ok);
        // 64 x 150k does not fit in 2M: nothing was attempted, nobody was marked failed.
        assertEq(auction.symbolCredits(ALICE), 64);
        assertEq(auction.deliveryCursor(), 0);
        assertEq(auction.deliverSymbols(64), 64);
    }

    function testBatchLimitsAndInternalEntry() public {
        _bid(ALICE, 25);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.deliverSymbols(0);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.deliverSymbols(65);
        vm.expectRevert(ERC20EnglishAuction.Unauthorized.selector);
        vm.prank(ALICE);
        auction.deliverTo(ALICE, 5);
    }

    function testExhaustedPoolBidsQueueNothing() public {
        KilimAuction.Config memory c = config(address(usd));
        c.symbolCap = 5;
        c.maxSymbolsPerBid = 5;
        auction = new KilimAuction(c);
        nft = auction.collection();
        vm.warp(auction.startsAt());
        _bid(ALICE, 25);
        _bid(BOB, 28);
        assertEq(auction.deliverSymbols(64), 5);
        assertEq(nft.balanceOf(BOB), 0);
        assertEq(auction.deliveryCursor(), 1);
    }

    function testGas64SymbolDelivery() public {
        _bid(ALICE, 64);
        uint256 before = gasleft();
        auction.deliverSymbols(64);
        uint256 used = before - gasleft();
        emit log_named_uint("gas: deliver 64 symbols to one wallet", used);
        assertTrue(used < 10_000_000);
    }

    event log_named_uint(string key, uint256 value);
}
