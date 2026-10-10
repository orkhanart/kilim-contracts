// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";

/// @notice The exact launch settings decided by the artist, exercised end to end in ETH.
///         Only the times, motif count and renderer are fixtures.
contract LaunchConfigTest is TestBase {
    /// orkhanart.eth: treasury, royalty receiver and collection-page owner.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    uint256 internal constant FUNDS = 1000 ether;

    KilimAuction internal auction;
    Kilim internal nft;

    function launchConfig() internal view returns (KilimAuction.Config memory c) {
        c = KilimAuction.Config({
            treasury: ARTIST,
            collectionOwner: ARTIST,
            startsAt: uint64(block.timestamp + 1 days),
            duration: 24 hours,
            extensionWindow: 10 minutes,
            incrementBps: 1000,
            reservePrice: 0.01 ether,
            symbolCap: 1_000_000,
            maxSymbolsPerBid: 1_000_000,
            motifCount: 812,
            maxCells: 256,
            geometryHash: mockRenderer.geometryHash(),
            rendererHash: address(mockRenderer).codehash,
            renderer: address(mockRenderer)
        });
    }

    function setUp() public {
        auction = new KilimAuction(launchConfig());
        nft = auction.collection();
        _fund(ALICE, FUNDS);
        _fund(BOB, FUNDS);
        _fund(ARTIST, FUNDS);
        _openBidding(auction);
    }

    /// @dev Bids `units` thousandths of an ETH and requires one symbol for each.
    function _bid(address user, uint256 units) private {
        vm.prank(user);
        auction.bid{value: units * UNIT}(units * UNIT, units, 0);
        assertEq(address(auction).balance, auction.liabilities());
    }

    function testDeployedValuesMatchTheDecisions() public view {
        assertEq(auction.treasury(), ARTIST);
        assertEq(auction.reservePrice(), 0.01 ether);
        assertEq(auction.REGISTRATION_BALANCE(), 0.01 ether);
        assertEq(auction.REGISTRATION_TARGET(), 100);
        assertEq(auction.SYMBOL_PRICE(), 0.001 ether);
        assertEq(auction.incrementBps(), 1000);
        assertEq(auction.duration(), 24 hours);
        assertEq(auction.extensionWindow(), 10 minutes);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.symbolCap(), 1_000_000);
        assertEq(auction.maxSymbolsPerBid(), 1_000_000);
        assertEq(nft.owner(), ARTIST);
        assertEq(nft.royaltyReceiver(), ARTIST);
        assertEq(uint256(nft.ROYALTY_BPS()), 500);
        assertEq(nft.minter(), address(auction));
        assertEq(nft.maxCells(), 256);
    }

    /// 0.01 ETH, then +10% rounded up to whole thousandths: 10, 11, 13, 15, 17, 19, 21, 24, 27 ...
    function testMinimumBidLadder() public {
        uint256[13] memory expected = [uint256(10), 11, 13, 15, 17, 19, 21, 24, 27, 30, 33, 37, 41];
        for (uint256 i; i < expected.length; ++i) {
            assertEq(auction.minimumBid(), expected[i] * UNIT);
            _bid(i % 2 == 0 ? ALICE : BOB, expected[i]);
        }
        assertEq(auction.minimumBid(), 46 * UNIT);
    }

    function testOneUnitIsOneSymbolWithNoPerBidCap() public {
        _bid(ALICE, 10);
        assertEq(auction.symbolCredits(ALICE), 10);
        // A large jump bid earns every 0.001 ETH in symbols.
        _bid(BOB, 5000);
        assertEq(auction.symbolCredits(BOB), 5000);
        assertEq(auction.symbolsAllocated(), 5010);
        // Alice was outbid: refunded in full inside Bob's bid, symbols kept.
        assertEq(ALICE.balance, FUNDS);
        assertEq(BOB.balance, FUNDS - 5 ether);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.symbolCredits(ALICE), 10);
        // Claims run 64 at a time; 5,000 symbols take 79 claims.
        for (uint256 i; i < 78; ++i) {
            vm.prank(BOB);
            auction.claimSymbols(64, BOB);
        }
        vm.prank(BOB);
        auction.claimSymbols(8, BOB);
        assertEq(nft.balanceOf(BOB), 5000);
        assertEq(auction.symbolCredits(BOB), 0);
    }

    function testClockStartsAtFirstBidAndLateBidsExtendByTenMinutes() public {
        vm.warp(block.timestamp + 3 days);
        _bid(ALICE, 10);
        assertEq(auction.endsAt(), block.timestamp + 24 hours);
        vm.warp(auction.endsAt() - 1 minutes);
        _bid(BOB, 11);
        assertEq(auction.endsAt(), block.timestamp + 10 minutes);
        vm.warp(auction.endsAt());
        vm.expectRevert(EnglishAuction.AuctionNotOpen.selector);
        vm.prank(ALICE);
        auction.bid{value: 13 * UNIT}(13 * UNIT, 0, 0);
        auction.settle();
        vm.prank(ARTIST);
        auction.withdrawProceeds(ARTIST);
        assertEq(ARTIST.balance, FUNDS + 11 * UNIT);
        assertEq(address(auction).balance, 0);
        // Settlement sent the 1/1 to the winner: nothing to claim.
        assertEq(nft.ownerOf(1), BOB);
    }

    function testArtistWalletCannotBidButManagesThePage() public {
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(ARTIST);
        auction.bid{value: 10 * UNIT}(10 * UNIT, 0, 0);
        assertEq(ARTIST.balance, FUNDS);
        vm.prank(ARTIST);
        nft.setCollectionInfo("A living language of symbols", "https://kilim.art");
        (address receiver, uint256 royalty) = nft.royaltyInfo(2, 100 * UNIT);
        assertEq(receiver, ARTIST);
        assertEq(royalty, 5 * UNIT);
    }
}
