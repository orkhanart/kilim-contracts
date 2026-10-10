// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimGlyphs} from "../../src/KilimGlyphs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {Receiver} from "../mocks/Receiver.sol";
import {TestBase} from "../TestBase.sol";

/// @dev Skeptic's PoC for the review finding "any bidder can claim glyphs to the treasury".
///      CONTRACTS.md line 109 says "no path lets the treasury, the token contracts or the minter receive
///      tokens". These tests measure exactly which of that the code keeps and which it does not, so the
///      orchestrator can decide between rewording the line and changing the auction.
contract TreasuryAsRecipientPoC is TestBase {
    KilimAuction internal auction;
    KilimGlyphs internal g;
    KilimOneOfOne internal one;

    function setUp() public {
        auction = new KilimAuction(config());
        g = auction.glyphs();
        one = auction.oneOfOne();
    }

    // ------------------------------------------------------------ the gap, reproduced

    /// @dev A bidder may name the treasury as the recipient of claimGlyphs. Nothing in the auction or
    ///      the glyph contract refuses it.
    function testClaimGlyphsToTheTreasurySucceeds() public {
        _openBidding(auction);
        _fund(ALICE, 1 ether);
        _bid(auction, ALICE, 0.1 ether); // 100 credits
        vm.prank(ALICE);
        auction.claimGlyphs(2, TREASURY);
        assertEq(g.balanceOf(TREASURY), 2);
        assertEq(g.ownerOf(1), TREASURY);
        assertEq(g.ownerOf(2), TREASURY);
    }

    /// @dev When settlement could not deliver the 1/1, the winner may claim it to the treasury.
    function testWinnerMayClaimPrizeToTheTreasuryAfterFailedDelivery() public {
        _openBidding(auction);
        Receiver winner = new Receiver();
        _fund(address(winner), 1 ether);
        _bid(auction, address(winner), 0.1 ether);
        winner.configure(true, address(0), "");
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(address(winner));
        auction.settle();
        assertTrue(!one.minted());
        // The winner claims it to the treasury.
        winner.execute(address(auction), abi.encodeCall(auction.claimPrize, (TREASURY)));
        assertEq(one.ownerOf(1), TREASURY);
    }

    // ------------------------------------------------------------ why a claim-side block would not close it

    /// @dev Even if claimGlyphs refused the treasury, any holder moves a glyph there with a plain
    ///      ERC-721 transfer: the token contracts do not know the treasury, only the minter and
    ///      themselves (KilimGlyphs._update). So the literal spec sentence cannot be kept at the auction.
    function testAnyHolderMayTransferAGlyphToTheTreasury() public {
        _openBidding(auction);
        _fund(ALICE, 1 ether);
        _bid(auction, ALICE, 0.1 ether);
        vm.prank(ALICE);
        auction.claimGlyphs(1, ALICE);
        vm.prank(ALICE);
        g.transferFrom(ALICE, TREASURY, 1);
        assertEq(g.ownerOf(1), TREASURY);
        // The same holds for the 1/1 once minted.
        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(one.ownerOf(1), ALICE);
        vm.prank(ALICE);
        one.transferFrom(ALICE, TREASURY, 1);
        assertEq(one.ownerOf(1), TREASURY);
    }

    // ------------------------------------------------------------ what the code does keep

    /// @dev The treasury cannot register, bid, claim glyphs (it can never hold credits) or claim the
    ///      prize (it can never be the winner). The token contracts and the minter can never receive.
    function testTreasuryCannotActAndTokenContractsCannotReceive() public {
        vm.warp(auction.startsAt());
        _fund(TREASURY, 1 ether);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(TREASURY);
        auction.register();
        _openBidding(auction);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(TREASURY);
        auction.bid{value: 0.1 ether}(0.1 ether, 0, 0);
        assertEq(auction.glyphCredits(TREASURY), 0);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        vm.prank(TREASURY);
        auction.claimGlyphs(1, TREASURY);

        _fund(ALICE, 1 ether);
        _bid(auction, ALICE, 0.1 ether);
        vm.prank(ALICE);
        auction.claimGlyphs(1, ALICE);
        // Minter (the auction) and the token contracts: refused by the auction's recipient rule ...
        address[3] memory bad = [address(auction), address(g), address(one)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(EnglishAuction.InvalidRecipient.selector);
            vm.prank(ALICE);
            auction.claimGlyphs(1, bad[i]);
        }
        // ... and by the glyph contract on transfer, for itself and its minter (not the 1/1, which it
        // does not know: a glyph can be sent to the 1/1 contract and is then stuck there).
        vm.expectRevert(KilimGlyphs.InvalidRecipient.selector);
        vm.prank(ALICE);
        g.transferFrom(ALICE, address(auction), 1);
        vm.expectRevert(KilimGlyphs.InvalidRecipient.selector);
        vm.prank(ALICE);
        g.transferFrom(ALICE, address(g), 1);
        vm.prank(ALICE);
        g.transferFrom(ALICE, address(one), 1);
        assertEq(g.ownerOf(1), address(one));

        vm.warp(auction.endsAt());
        auction.settle();
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(TREASURY);
        auction.claimPrize(TREASURY);
        assertEq(one.ownerOf(1), ALICE);
    }
}
