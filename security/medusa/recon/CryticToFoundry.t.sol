// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "../lib/chimera/src/Hevm.sol";
import {FoundryAsserts} from "./FoundryAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

/// @notice The same handlers and properties under Foundry's invariant runner (Chimera's CryticToFoundry,
///         without forge-std). Run from contracts/ with the commands in ../README.md; the profile keeps
///         the repo's `fail_on_revert = true`, so a failed handler check (it reverts) fails the run.
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = true
contract CryticToFoundry is TargetFunctions, FoundryAsserts {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    struct FuzzArtifactSelector {
        string artifact;
        bytes4[] selectors;
    }

    struct FuzzInterface {
        address addr;
        string[] artifacts;
    }

    address[] private _targets;

    function setUp() public {
        setup();
        _targets.push(address(this));
    }

    // ------------------------------------------------------------ Foundry target discovery

    function targetContracts() public view returns (address[] memory) {
        return _targets;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory s) {
        bytes4[] memory sel = new bytes4[](39);
        sel[0] = this.auction_register.selector;
        sel[1] = this.auction_registerMany.selector;
        sel[2] = this.auction_registerFor.selector;
        sel[3] = this.auction_registerTreasury.selector;
        sel[4] = this.actor_setBalance.selector;
        sel[5] = this.wallet_setMood.selector;
        sel[6] = this.auction_bid.selector;
        sel[7] = this.auction_withdrawRefund.selector;
        sel[8] = this.time_warp.selector;
        sel[9] = this.time_warpToStart.selector;
        sel[10] = this.time_warpToClose.selector;
        sel[11] = this.auction_settle.selector;
        sel[12] = this.auction_withdrawProceeds.selector;
        sel[13] = this.auction_donate.selector;
        sel[14] = this.auction_selfCallEntrypoints.selector;
        sel[15] = this.auction_claimMotifs.selector;
        sel[16] = this.auction_claimPrize.selector;
        sel[17] = this.motif_transfer.selector;
        sel[18] = this.motif_transferToBlocked.selector;
        sel[19] = this.motif_burn.selector;
        sel[20] = this.motif_burnNotOwner.selector;
        sel[21] = this.bazaar_approve.selector;
        sel[22] = this.bazaar_make.selector;
        sel[23] = this.bazaar_deposit.selector;
        sel[24] = this.bazaar_makeFromLoom.selector;
        sel[25] = this.bazaar_foreignIds.selector;
        sel[26] = this.bazaar_stray.selector;
        sel[27] = this.bazaar_transferKilim.selector;
        sel[28] = this.bazaar_seal.selector;
        sel[29] = this.chain_roll.selector;
        sel[30] = this.chain_history.selector;
        // Weighted: the lifecycle steps that open the later stages.
        sel[31] = this.auction_bid.selector;
        sel[32] = this.auction_claimMotifs.selector;
        sel[33] = this.bazaar_make.selector;
        sel[34] = this.bazaar_makeDense.selector;
        sel[35] = this.views_read.selector;
        sel[36] = this.chain_mine.selector;
        sel[37] = this.shortcut_toSettlement.selector;
        sel[38] = this.shortcut_claimAndApprove.selector;
        s = new FuzzSelector[](1);
        s[0] = FuzzSelector(address(this), sel);
    }

    function targetArtifactSelectors() public pure returns (FuzzArtifactSelector[] memory) {
        return new FuzzArtifactSelector[](0);
    }

    function targetArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function excludeArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function targetSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeContracts() public pure returns (address[] memory) {
        return new address[](0);
    }

    function targetInterfaces() public pure returns (FuzzInterface[] memory) {
        return new FuzzInterface[](0);
    }

    function excludeSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    // ------------------------------------------------------------ the properties as invariants

    function invariant_solvency() public view {
        require(property_solvency(), "solvency");
    }

    function invariant_escrowExact() public view {
        require(property_escrowExact(), "escrowExact");
    }

    function invariant_liabilitiesExact() public view {
        require(property_liabilitiesExact(), "liabilitiesExact");
    }

    function invariant_refundsMatchDeferred() public view {
        require(property_refundsMatchDeferred(), "refundsMatchDeferred");
    }

    function invariant_outbidConserved() public view {
        require(property_outbidConserved(), "outbidConserved");
    }

    function invariant_dustAfterWithdrawals() public view {
        require(property_dustAfterWithdrawals(), "dustAfterWithdrawals");
    }

    function invariant_highestBidAndClock() public view {
        require(property_highestBidAndClock(), "highestBidAndClock");
    }

    function invariant_settledOnce() public view {
        require(property_settledOnce(), "settledOnce");
    }

    function invariant_registration() public view {
        require(property_registration(), "registration");
    }

    function invariant_credits() public view {
        require(property_credits(), "credits");
    }

    function invariant_highestBidMotifs() public view {
        require(property_highestBidMotifs(), "highestBidMotifs");
    }

    function invariant_unclaimedRanges() public view {
        require(property_unclaimedRanges(), "unclaimedRanges");
    }

    function invariant_oneOfOne() public view {
        require(property_oneOfOne(), "oneOfOne");
    }

    function invariant_motifSupply() public view {
        require(property_motifSupply(), "motifSupply");
    }

    function invariant_bazaarClosedBeforeSettle() public view {
        require(property_bazaarClosedBeforeSettle(), "bazaarClosedBeforeSettle");
    }

    function invariant_kilimRecords() public view {
        require(property_kilimRecords(), "kilimRecords");
    }

    function invariant_looms() public view {
        require(property_looms(), "looms");
    }

    function invariant_strays() public view {
        require(property_strays(), "strays");
    }

    function invariant_noReentry() public view {
        require(property_noReentry(), "noReentry");
    }

    // ------------------------------------------------------------ a scripted walk through every stage

    function _s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }

    function _all() internal view {
        require(property_solvency(), "solvency");
        require(property_escrowExact(), "escrowExact");
        require(property_liabilitiesExact(), "liabilitiesExact");
        require(property_refundsMatchDeferred(), "refundsMatchDeferred");
        require(property_outbidConserved(), "outbidConserved");
        require(property_dustAfterWithdrawals(), "dustAfterWithdrawals");
        require(property_highestBidAndClock(), "highestBidAndClock");
        require(property_settledOnce(), "settledOnce");
        require(property_registration(), "registration");
        require(property_credits(), "credits");
        require(property_highestBidMotifs(), "highestBidMotifs");
        require(property_unclaimedRanges(), "unclaimedRanges");
        require(property_oneOfOne(), "oneOfOne");
        require(property_motifSupply(), "motifSupply");
        require(property_bazaarClosedBeforeSettle(), "bazaarClosedBeforeSettle");
        require(property_kilimRecords(), "kilimRecords");
        require(property_looms(), "looms");
        require(property_strays(), "strays");
        require(property_noReentry(), "noReentry");
    }

    /// The handlers can drive the system from registration to sealed kilims, through the fallback paths
    /// (deferred refund, prize claim, history-contract seal, re-arm), with every property holding.
    function test_lifecycleReachesEveryStage() public {
        // Before the start: closed Bazaar, no registration.
        bazaar_make(0, 10, 0, 0);
        auction_register(0);
        time_warpToStart();
        auction_register(0);
        auction_registerFor(1, 0, 3600); // Bob by signature
        wallet_setMood(0, 0, 0, true); // wallet 2 signs ERC-1271
        auction_registerFor(2, 0, 3600);
        auction_registerTreasury();
        auction_registerMany(0);
        _all();
        // Bids: Alice, then wallet 2 (which then rejects ETH), outbid by Bob: a deferred refund.
        auction_bid(0, 200, 0, 1); // 0.21 ETH: 210 credits
        auction_bid(2, 160, 0, 1); // 0.391 ETH
        wallet_setMood(0, 1, 1, false); // wallet 2: rejects ETH and NFTs
        auction_bid(1, 400, 0, 1); // 0.831 ETH, outbidding a wallet that rejects ETH
        require(hitDeferredRefund == 1, "deferred refund not reached");
        auction_bid(2, 2, 0, 1); // wallet 2 leads again; it refuses NFTs, so it must claim the 1/1
        auction_bid(1, 1, 1, 1); // under the minimum: must fail
        auction_bid(0, 1, 2, 1); // not a whole unit: must fail
        auction_bid(0, 1, 7, 1); // the treasury: must fail
        auction_donate(12345);
        _all();
        time_warpToClose(1, 0);
        auction_bid(0, 1, 0, 1); // at the close: must fail
        auction_settle(0, 1);
        require(auction.settled() && !auction.prizeClaimed(), "prize fallback not reached");
        auction_claimPrize(0, 1); // Alice is not the winner: must fail
        auction_claimPrize(2, 0); // the wallet claims it to Alice
        require(oneOfOne.ownerOf(1) == actors[0], "prize not claimed");
        wallet_setMood(0, 0, 0, false);
        auction_withdrawRefund(2, 2);
        auction_withdrawProceeds(1, 0); // treasury -> Alice
        _all();
        // Motifs to everyone, then the Bazaar.
        for (uint8 r; r < 6; ++r) {
            auction_claimMotifs(0, 63, 0);
            auction_claimMotifs(1, 63, 1);
            auction_claimMotifs(2, 63, 2);
        }
        bazaar_approve(0, true);
        bazaar_approve(1, true);
        bazaar_approve(2, true);
        bazaar_make(0, 31, 0, 0);
        bazaar_deposit(1, 12, 0); // 2 motifs: too few to open a loom
        bazaar_deposit(1, 13, 0); // 23 motifs
        bazaar_deposit(1, 7, 3);
        bazaar_makeFromLoom(1, 5, 0, 1);
        bazaar_foreignIds(0, 0, 3, 0);
        bazaar_foreignIds(0, 3, 3, 1);
        bazaar_stray(2, 0, false);
        bazaar_stray(2, 0, true);
        motif_burn(2, 1);
        motif_transfer(2, 0, 2);
        _all();
        chain_roll(0, 1); // two blocks: the seal block is in the past
        bazaar_seal(1, 4);
        chain_roll(1, 10); // about 260 blocks: the history-contract path
        bazaar_seal(2, 4);
        bazaar_make(0, 11, 50, 0); // a kilim left unsealed past the window
        chain_roll(2, 20); // past the 8,191 window: re-arm
        for (uint256 s = 3; s < 40 && ghostRearms == 0; ++s) {
            bazaar_seal(s, 4);
        }
        bazaar_transferKilim(1, 1);
        for (uint8 v; v < 10; ++v) {
            views_read(v, uint256(v) * 7919);
        }
        bazaar_makeDense(1, 1);
        bazaar_makeDense(0, 0);
        require(hitDenseMake >= 1, string.concat("no DENSE one-call kilim; owned ", _s(owned[actors[0]].length)));
        _all();
        require(hitMake >= 1 && hitDeposit >= 2 && hitMakeFromLoom >= 1, "Bazaar stages not reached");
        require(ghostStrays == 1 && ghostDirectBurns == 1, "strays / burns not reached");
        require(ghostSeals >= 1, string.concat("no seal: seals ", _s(ghostSeals), " history ", _s(ghostHistorySeals), " rearms ", _s(ghostRearms), " kilims ", _s(ghostKilims)));
        require(ghostHistorySeals >= 1, "no seal through the history contract");
        require(ghostRearms >= 1, "no re-arm");
    }
}
