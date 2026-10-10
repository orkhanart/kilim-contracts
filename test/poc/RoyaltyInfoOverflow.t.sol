// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

/// @dev The OpenZeppelin reference implementation with the same 5% default, deployed only to compare
///      its arithmetic with ours at the same inputs.
contract OZRoyalty is ERC2981 {
    constructor(address receiver) {
        _setDefaultRoyalty(receiver, 500);
    }
}

/// @dev Skeptic's PoC for the review finding "royaltyInfo reverts for salePrice above uint256.max / 500".
///      It measures three things: the exact threshold where both token contracts start to revert, how far
///      that threshold sits from any amount of wei that can exist, and whether OpenZeppelin's ERC2981
///      (the reference implementation marketplaces are written against) behaves identically.
contract RoyaltyInfoOverflowPoC is TestBase {
    uint256 internal constant THRESHOLD = type(uint256).max / 500;
    /// @dev Panic(uint256) with code 0x11: checked arithmetic overflow.
    bytes internal constant OVERFLOW = abi.encodeWithSelector(0x4e487b71, 0x11);

    KilimMotifs internal g;
    KilimOneOfOne internal one;
    OZRoyalty internal oz;

    function setUp() public {
        g = newMotifs(address(this), TREASURY, MOTIF_CAP);
        one = newOneOfOne(address(this), TREASURY, g);
        oz = new OZRoyalty(TREASURY);
    }

    // ------------------------------------------------------------ the revert, reproduced

    /// @dev Both contracts answer at the threshold and panic one wei above it.
    function testBothContractsRevertExactlyAboveThreshold() public {
        (address r, uint256 amount) = g.royaltyInfo(1, THRESHOLD);
        assertEq(r, TREASURY);
        assertEq(amount, THRESHOLD * 500 / 10_000);
        (r, amount) = one.royaltyInfo(1, THRESHOLD);
        assertEq(r, TREASURY);
        assertEq(amount, THRESHOLD * 500 / 10_000);

        vm.expectRevert(OVERFLOW);
        g.royaltyInfo(1, THRESHOLD + 1);
        vm.expectRevert(OVERFLOW);
        one.royaltyInfo(1, THRESHOLD + 1);
        vm.expectRevert(OVERFLOW);
        g.royaltyInfo(1, type(uint256).max);
    }

    // ------------------------------------------------------------ the reference implementation does the same

    /// @dev OpenZeppelin 5.6.1 `ERC2981.royaltyInfo` computes `(salePrice * fraction) / 10000` with checked
    ///      arithmetic and panics at the identical input. Any marketplace that copes with OZ copes with us.
    function testOpenZeppelinReferenceRevertsAtTheSameInput() public {
        (, uint256 ours) = g.royaltyInfo(1, THRESHOLD);
        (, uint256 theirs) = oz.royaltyInfo(1, THRESHOLD);
        assertEq(ours, theirs);
        vm.expectRevert(OVERFLOW);
        oz.royaltyInfo(1, THRESHOLD + 1);
    }

    // ------------------------------------------------------------ how far the threshold is from reality

    /// @dev The threshold is about 2.3e74 wei. All ether that exists is under 1.3e26 wei, and the EVM
    ///      cannot move more wei than exist. The gap is more than 1e48 times the whole supply.
    function testThresholdExceedsAllEtherByFortyEightOrdersOfMagnitude() public pure {
        uint256 allEther = 130_000_000 ether; // generous upper bound on circulating supply in wei
        assertTrue(THRESHOLD / allEther > 1e48);
        // Even a price denominated in the smallest unit of an 18-decimal token with a supply of
        // 1e30 whole tokens (1e48 units) is far below the threshold.
        assertTrue(THRESHOLD > 1e48 * 1e18);
    }

    /// @dev Any salePrice a marketplace can actually settle in ETH computes without reverting, fuzzed over
    ///      the entire range of wei that could ever exist.
    function testFuzzRoyaltyInfoNeverRevertsForAnyRealPrice(uint256 salePrice) public view {
        salePrice = salePrice % (130_000_000 ether + 1);
        (address r, uint256 amount) = g.royaltyInfo(1, salePrice);
        assertEq(r, TREASURY);
        assertEq(amount, salePrice * 500 / 10_000);
        (r, amount) = one.royaltyInfo(1, salePrice);
        assertEq(r, TREASURY);
        assertEq(amount, salePrice * 500 / 10_000);
    }
}
