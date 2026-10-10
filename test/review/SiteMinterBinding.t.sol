// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestBase} from "../TestBase.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {RogueAuction} from "./RogueAuction.sol";

/// @dev PoC (skeptic pass on the "minter() is not checked" site finding, 10 October 2026). What the
///      two reads site/chain.js does not make would tell it, measured on-chain:
///      1. a real KilimAuction can never sit at an address its tokens do not name as minter: the
///         constructor refuses it, so the proposed site check has no false positive;
///      2. the three reads the site does make (auction.motifs(), auction.oneOfOne(), oneOfOne.motifs())
///         all pass for a RogueAuction naming the real tokens, and only motifs.minter() /
///         oneOfOne.minter() tell it apart.
contract SiteMinterBindingPoc is TestBase {
    function testRealAuctionAlwaysPassesTheMinterCheck() public {
        KilimAuction.Config memory c = config();
        KilimAuction auction = new KilimAuction(c);
        // The reads the site makes today.
        assertEq(address(auction.motifs()), c.motifs);
        assertEq(address(auction.oneOfOne()), c.oneOfOne);
        assertEq(address(KilimOneOfOne(c.oneOfOne).motifs()), c.motifs);
        // The two it does not: for a real auction they are implied by the constructor.
        assertEq(KilimMotifs(c.motifs).minter(), address(auction));
        assertEq(KilimOneOfOne(c.oneOfOne).minter(), address(auction));
    }

    function testAuctionAtAnotherAddressCannotBeBuiltOverTheseTokens() public {
        KilimAuction.Config memory c = config();
        // Burn the predicted nonce on something else: the next creation lands one address later,
        // so the tokens' minter is no longer the auction being built.
        new RogueAuction(c.motifs, c.oneOfOne, c.treasury);
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    function testRogueAuctionPassesTheSiteReadsAndFailsTheMinterReads() public {
        KilimAuction.Config memory c = config();
        KilimAuction real = new KilimAuction(c);
        RogueAuction rogue = new RogueAuction(c.motifs, c.oneOfOne, c.treasury);
        // Every binding read chain.js makes at startup answers the same for the rogue.
        assertEq(rogue.motifs(), c.motifs);
        assertEq(rogue.oneOfOne(), c.oneOfOne);
        assertEq(address(KilimOneOfOne(c.oneOfOne).motifs()), c.motifs);
        assertEq(rogue.MOTIF_PRICE(), real.MOTIF_PRICE());
        // Only the tokens' own word differs.
        assertTrue(KilimMotifs(c.motifs).minter() != address(rogue));
        assertTrue(KilimOneOfOne(c.oneOfOne).minter() != address(rogue));
        assertEq(KilimMotifs(c.motifs).minter(), address(real));
        assertEq(KilimOneOfOne(c.oneOfOne).minter(), address(real));
    }
}
