// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

contract LifecycleTest is TestBase {
    function testRefundedSymbolsComposeExpandAndTransferThenAllClaimsSettle() public {
        MockUSD usd = new MockUSD(6);
        KilimAuction auction = new KilimAuction(config(address(usd)));
        Kilim nft = auction.collection();
        usd.mint(ALICE, 100 * UNIT);
        usd.mint(BOB, 100 * UNIT);
        vm.warp(auction.startsAt());
        vm.startPrank(ALICE);
        usd.approve(address(auction), 25 * UNIT);
        auction.bid(25 * UNIT, 25, 0);
        vm.stopPrank();
        vm.startPrank(BOB);
        usd.approve(address(auction), 27 * UNIT);
        auction.bid(27 * UNIT, 27, 0);
        vm.stopPrank();

        vm.startPrank(ALICE);
        auction.claimSymbols(6, ALICE);
        uint256 artwork = nft.weave(ids(2, 4), 2, 2, INK);
        nft.expand(artwork, 1, ids(2, 6), 3, 2, VERMILION);
        nft.freezeArtwork(artwork);
        nft.transferFrom(ALICE, CAROL, artwork);
        vm.stopPrank();
        assertEq(usd.balanceOf(ALICE), 100 * UNIT);
        assertEq(nft.ownerOf(artwork), CAROL);
        Kilim.ArtworkData memory art = nft.artworkData(artwork);
        assertEq(art.revision, 2);
        assertTrue(art.frozen);
        assertEq(art.cells.length, 6);
        for (uint256 id = 2; id < 8; id++) {
            assertEq(nft.symbolData(id).consumedBy, artwork);
        }

        vm.warp(auction.endsAt());
        vm.prank(CAROL);
        auction.settle();
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        vm.prank(BOB);
        auction.claimPrize(BOB);
        // Both bidders keep and can claim remaining credits after all cash has been paid out.
        vm.prank(ALICE);
        auction.claimSymbols(19, ALICE);
        vm.prank(BOB);
        auction.claimSymbols(27, BOB);

        assertEq(usd.balanceOf(TREASURY), 27 * UNIT);
        assertEq(usd.balanceOf(BOB), 73 * UNIT);
        assertEq(usd.balanceOf(address(auction)), 0);
        assertEq(auction.liabilities(), 0);
        assertEq(auction.symbolCredits(ALICE), 0);
        assertEq(auction.symbolCredits(BOB), 0);
        assertEq(auction.symbolsAllocated(), 52);
        assertEq(auction.symbolsClaimed(), 52);
        assertEq(nft.symbolsMinted(), 52);
        assertEq(nft.symbolsBurned(), 6);
        assertEq(nft.ownerOf(1), BOB);
        assertEq(nft.balanceOf(ALICE), 19);
        assertEq(nft.balanceOf(BOB), 28);
        assertEq(nft.balanceOf(CAROL), 1);
    }
}
