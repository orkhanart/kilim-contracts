// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";

contract LifecycleTest is TestBase {
    function testRefundedSymbolsComposeExpandAndTransferThenAllClaimsSettle() public {
        KilimAuction auction = new KilimAuction(config());
        Kilim nft = auction.collection();
        _openBidding(auction);
        assertEq(address(auction).balance, 0);
        _fund(ALICE, 100 * UNIT);
        _fund(BOB, 100 * UNIT);
        vm.prank(ALICE);
        auction.bid{value: RESERVE}(RESERVE, 10, 0);
        assertEq(address(auction).balance, auction.liabilities());
        vm.prank(BOB);
        auction.bid{value: 11 * UNIT}(11 * UNIT, 11, 0);
        // Alice was refunded inside Bob's bid.
        assertEq(ALICE.balance, 100 * UNIT);
        assertEq(auction.refunds(ALICE), 0);
        assertEq(address(auction).balance, 11 * UNIT);
        assertEq(address(auction).balance, auction.liabilities());

        vm.startPrank(ALICE);
        auction.claimSymbols(6, ALICE);
        uint256 artwork = nft.weave(ids(2, 4), 2, 2, INK);
        nft.expand(artwork, 1, ids(2, 6), 3, 2, VERMILION);
        nft.freezeArtwork(artwork);
        nft.transferFrom(ALICE, CAROL, artwork);
        vm.stopPrank();
        assertEq(ALICE.balance, 100 * UNIT);
        assertEq(address(auction).balance, auction.liabilities());
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
        assertEq(address(auction).balance, auction.liabilities());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(auction.collection().ownerOf(1), BOB);
        // Both bidders keep and can claim remaining credits after all ETH has been paid out.
        vm.prank(ALICE);
        auction.claimSymbols(4, ALICE);
        vm.prank(BOB);
        auction.claimSymbols(11, BOB);

        assertEq(TREASURY.balance, 11 * UNIT);
        assertEq(BOB.balance, 89 * UNIT);
        assertEq(ALICE.balance, 100 * UNIT);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);
        assertEq(auction.symbolCredits(ALICE), 0);
        assertEq(auction.symbolCredits(BOB), 0);
        assertEq(auction.symbolsAllocated(), 21);
        assertEq(auction.symbolsClaimed(), 21);
        assertEq(nft.symbolsMinted(), 21);
        assertEq(nft.symbolsBurned(), 6);
        assertEq(nft.ownerOf(1), BOB);
        assertEq(nft.balanceOf(ALICE), 4);
        assertEq(nft.balanceOf(BOB), 12);
        assertEq(nft.balanceOf(CAROL), 1);
    }
}
