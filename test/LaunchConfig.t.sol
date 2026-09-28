// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20EnglishAuction} from "../src/auction/ERC20EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice The exact launch settings decided by the artist, exercised end to end against a
///         six-decimal USDC stand-in. Only the times, token, motif count and renderer are fixtures.
contract LaunchConfigTest is TestBase {
    /// orkhanart.eth: treasury, royalty receiver and collection-page owner.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;

    MockUSD internal usdc;
    KilimAuction internal auction;
    Kilim internal nft;

    function launchConfig(address token) internal view returns (KilimAuction.Config memory c) {
        c = KilimAuction.Config({
            paymentToken: token,
            treasury: ARTIST,
            collectionOwner: ARTIST,
            startsAt: uint64(block.timestamp + 1 days),
            duration: 24 hours,
            extensionWindow: 10 minutes,
            incrementBps: 1000,
            reservePrice: 1 * UNIT,
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
        usdc = new MockUSD(6);
        auction = new KilimAuction(launchConfig(address(usdc)));
        nft = auction.collection();
        _fund(ALICE);
        _fund(BOB);
        _fund(ARTIST);
        vm.warp(auction.startsAt());
    }

    function _fund(address user) private {
        usdc.mint(user, 1e30);
        vm.prank(user);
        usdc.approve(address(auction), type(uint256).max);
    }

    function _bid(address user, uint256 dollars) private {
        vm.prank(user);
        auction.bid(dollars * UNIT, dollars, 0);
    }

    function testDeployedValuesMatchTheDecisions() public view {
        assertEq(auction.treasury(), ARTIST);
        assertEq(auction.reservePrice(), 1 * UNIT);
        assertEq(auction.tokenUnit(), UNIT);
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

    /// $1, then +10% rounded up to whole dollars: 1, 2, 3 ... 10, 11, 13, 15, 17, 19, 21, 24.
    function testMinimumBidLadder() public {
        uint256[13] memory expected = [uint256(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15];
        for (uint256 i; i < expected.length; ++i) {
            assertEq(auction.minimumBid(), expected[i] * UNIT);
            _bid(i % 2 == 0 ? ALICE : BOB, expected[i]);
        }
        assertEq(auction.minimumBid(), 17 * UNIT);
    }

    function testOneDollarIsOneSymbolWithNoPerBidCap() public {
        _bid(ALICE, 1);
        assertEq(auction.symbolCredits(ALICE), 1);
        // A large jump bid earns every dollar in symbols.
        _bid(BOB, 5000);
        assertEq(auction.symbolCredits(BOB), 5000);
        assertEq(auction.symbolsAllocated(), 5001);
        // Alice was outbid: refunded in full inside Bob's bid, symbol kept.
        assertEq(usdc.balanceOf(ALICE), 1e30);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.symbolCredits(ALICE), 1);
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
        _bid(ALICE, 1);
        assertEq(auction.endsAt(), block.timestamp + 24 hours);
        vm.warp(auction.endsAt() - 1 minutes);
        _bid(BOB, 2);
        assertEq(auction.endsAt(), block.timestamp + 10 minutes);
        vm.warp(auction.endsAt());
        vm.expectRevert(ERC20EnglishAuction.AuctionNotOpen.selector);
        vm.prank(ALICE);
        auction.bid(3 * UNIT, 0, 0);
        auction.settle();
        vm.prank(ARTIST);
        auction.withdrawProceeds(ARTIST);
        assertEq(usdc.balanceOf(ARTIST), 1e30 + 2 * UNIT);
        vm.prank(BOB);
        auction.claimPrize(BOB);
        assertEq(nft.ownerOf(1), BOB);
    }

    function testArtistWalletCannotBidButManagesThePage() public {
        vm.expectRevert(ERC20EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(ARTIST);
        auction.bid(1 * UNIT, 0, 0);
        vm.prank(ARTIST);
        nft.setCollectionInfo("A living language of symbols", "https://kilim.art");
        (address receiver, uint256 royalty) = nft.royaltyInfo(2, 100 * UNIT);
        assertEq(receiver, ARTIST);
        assertEq(royalty, 5 * UNIT);
    }
}
