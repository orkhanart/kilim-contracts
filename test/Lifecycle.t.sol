// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimGlyphs} from "../src/KilimGlyphs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {TestBase} from "./TestBase.sol";

contract LifecycleTest is TestBase {
    function testRefundedGlyphsAreClaimedBurnedAndTransferredThenAllClaimsSettle() public {
        KilimAuction auction = new KilimAuction(config());
        KilimGlyphs nft = auction.glyphs();
        KilimOneOfOne oneOfOne = auction.oneOfOne();
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

        // Alice claims six glyphs (ids 1-6), burns four of them as the Weaver will, and sells one.
        vm.startPrank(ALICE);
        auction.claimGlyphs(6, ALICE);
        for (uint256 id = 1; id <= 4; ++id) {
            nft.burn(id);
        }
        nft.transferFrom(ALICE, CAROL, 5);
        vm.stopPrank();
        assertEq(ALICE.balance, 100 * UNIT);
        assertEq(address(auction).balance, auction.liabilities());
        assertEq(nft.ownerOf(5), CAROL);
        assertEq(nft.ownerOf(6), ALICE);
        for (uint256 id = 1; id <= 4; ++id) {
            assertTrue(nft.burned(id));
            vm.expectRevert();
            nft.ownerOf(id);
        }

        vm.warp(auction.endsAt());
        vm.prank(CAROL);
        auction.settle();
        assertEq(address(auction).balance, auction.liabilities());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(oneOfOne.ownerOf(1), BOB);
        // Both bidders keep and can claim remaining credits after all ETH has been paid out.
        vm.prank(ALICE);
        auction.claimGlyphs(4, ALICE);
        vm.prank(BOB);
        auction.claimGlyphs(11, BOB);

        assertEq(TREASURY.balance, 11 * UNIT);
        assertEq(BOB.balance, 89 * UNIT);
        assertEq(ALICE.balance, 100 * UNIT);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);
        assertEq(auction.glyphCredits(ALICE), 0);
        assertEq(auction.glyphCredits(BOB), 0);
        assertEq(auction.glyphsAllocated(), 21);
        assertEq(auction.glyphsClaimed(), 21);
        assertEq(nft.glyphsMinted(), 21);
        assertEq(nft.glyphsBurned(), 4);
        assertEq(oneOfOne.ownerOf(1), BOB);
        assertEq(oneOfOne.balanceOf(BOB), 1);
        assertEq(nft.balanceOf(ALICE), 5);
        assertEq(nft.balanceOf(BOB), 11);
        assertEq(nft.balanceOf(CAROL), 1);
        // Burned ids stay taken: the next claim never reuses them.
        assertEq(nft.ownerOf(21), BOB);
        vm.expectRevert();
        nft.ownerOf(22);
    }
}
