// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {TestBase} from "./TestBase.sol";

/// @notice The exact launch settings decided by the artist, exercised end to end in ETH.
///         Only the times, the motif data and the page are fixtures.
contract LaunchConfigTest is TestBase {
    /// orkhanart.eth: treasury and royalty receiver.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    uint256 internal constant FUNDS = 1000 ether;
    uint256 internal constant LAUNCH_MOTIF_CAP = 1_000_000;

    KilimAuction internal auction;
    KilimMotifs internal nft;
    KilimOneOfOne internal oneOfOne;

    /// @dev The launch values, with the token contracts deployed for the next creation (see config()).
    function launchConfig() internal returns (KilimAuction.Config memory c) {
        c = KilimAuction.Config({
            treasury: ARTIST,
            motifs: address(0),
            oneOfOne: address(0),
            startsAt: uint64(block.timestamp + 1 days),
            duration: 24 hours,
            extensionWindow: 10 minutes,
            incrementBps: 1000,
            reservePrice: 0.01 ether,
            maxMotifsPerBid: LAUNCH_MOTIF_CAP
        });
        c = withTokens(c, LAUNCH_MOTIF_CAP);
    }

    function setUp() public {
        auction = new KilimAuction(launchConfig());
        nft = auction.motifs();
        oneOfOne = auction.oneOfOne();
        _fund(ALICE, FUNDS);
        _fund(BOB, FUNDS);
        _fund(ARTIST, FUNDS);
        _openBidding(auction);
    }

    /// @dev Bids `units` thousandths of an ETH and requires one motif for each.
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
        assertEq(auction.MOTIF_PRICE(), 0.001 ether);
        assertEq(auction.incrementBps(), 1000);
        assertEq(auction.duration(), 24 hours);
        assertEq(auction.extensionWindow(), 10 minutes);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.motifCap(), LAUNCH_MOTIF_CAP);
        assertEq(auction.maxMotifsPerBid(), LAUNCH_MOTIF_CAP);
        assertEq(nft.motifCap(), LAUNCH_MOTIF_CAP);
        assertEq(nft.royaltyReceiver(), ARTIST);
        assertEq(uint256(nft.ROYALTY_BPS()), 500);
        assertEq(nft.minter(), address(auction));
        assertEq(nft.MAX_MINT_BATCH(), 64);
        assertEq(nft.MOTIF_COUNT(), 1024);
        assertEq(oneOfOne.TOKEN_ID(), 1);
        assertTrue(!oneOfOne.minted());
        assertEq(oneOfOne.minter(), address(auction));
        assertEq(oneOfOne.royaltyReceiver(), ARTIST);
        assertEq(uint256(oneOfOne.ROYALTY_BPS()), 500);
        assertEq(address(oneOfOne.motifs()), address(nft));
        assertEq(oneOfOne.name(), ONE_OF_ONE_NAME);
        assertEq(nft.name(), "Motif Bazaar");
        assertEq(nft.symbol(), "MOTIF");
        assertEq(oneOfOne.name(), "The Unwoven Kilim");
        assertEq(oneOfOne.symbol(), "UNWOVEN");
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

    function testOneUnitIsOneMotifWithNoPerBidCap() public {
        _bid(ALICE, 10);
        assertEq(auction.motifCredits(ALICE), 10);
        // A large jump bid earns every 0.001 ETH in motifs.
        _bid(BOB, 5000);
        assertEq(auction.motifCredits(BOB), 5000);
        assertEq(auction.motifsAllocated(), 5010);
        // Alice was outbid: refunded in full inside Bob's bid, motifs kept.
        assertEq(ALICE.balance, FUNDS);
        assertEq(BOB.balance, FUNDS - 5 ether);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(auction.motifCredits(ALICE), 10);
        // Claims run 64 at a time; 5,000 motifs take 79 claims.
        for (uint256 i; i < 78; ++i) {
            vm.prank(BOB);
            auction.claimMotifs(64, BOB);
        }
        vm.prank(BOB);
        auction.claimMotifs(8, BOB);
        assertEq(nft.balanceOf(BOB), 5000);
        assertEq(auction.motifCredits(BOB), 0);
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
        assertEq(oneOfOne.ownerOf(1), BOB);
    }

    function testArtistWalletCannotBidAndHasNoRoleButRoyalties() public {
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(ARTIST);
        auction.bid{value: 10 * UNIT}(10 * UNIT, 0, 0);
        assertEq(ARTIST.balance, FUNDS);
        (address receiver, uint256 royalty) = nft.royaltyInfo(2, 100 * UNIT);
        assertEq(receiver, ARTIST);
        assertEq(royalty, 5 * UNIT);
        (receiver, royalty) = oneOfOne.royaltyInfo(1, 100 * UNIT);
        assertEq(receiver, ARTIST);
        assertEq(royalty, 5 * UNIT);
        // No contract has a setter or a mint the artist could call.
        vm.startPrank(ARTIST);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        nft.mintMotifs(ARTIST, ARTIST, 1, 1);
        vm.expectRevert(KilimOneOfOne.Unauthorized.selector);
        oneOfOne.mint(ARTIST);
        vm.stopPrank();
    }
}
