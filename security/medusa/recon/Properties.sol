// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {MoodyWallet} from "./Mocks.sol";
import {Setup} from "./Setup.sol";

/// @notice System-wide properties, checked by Medusa after every call (property mode: `property_*` returns
///         bool) and by Foundry as invariants (CryticToFoundry). Each reads the contracts and the ghost
///         ledger the handlers keep; none of them changes state.
abstract contract Properties is Setup {
    // ================================================================ auction ETH

    /// The auction always holds enough ETH for every obligation.
    function property_solvency() public view returns (bool) {
        return address(auction).balance >= auction.liabilities();
    }

    /// The balance is exactly what came in (bids, forced ETH) less what went out (pushed refunds, pulled
    /// refunds, proceeds): no ETH appears or disappears.
    function property_escrowExact() public view returns (bool) {
        return address(auction).balance + ghostPushedTotal + ghostWithdrawnTotal + ghostProceedsPaid
            == ghostBidTotal + ghostDonated;
    }

    /// liabilities() is refunds owed plus, before settlement, the highest bid, after it the proceeds due;
    /// and with forced ETH set aside it is exactly the balance.
    function property_liabilitiesExact() public view returns (bool) {
        uint256 l = auction.refundLiability() + (auction.settled() ? auction.proceedsDue() : auction.highestBid());
        return auction.liabilities() == l && address(auction).balance == l + ghostDonated;
    }

    /// The refund liability is the sum of what each bidder is owed, and each is owed exactly what was
    /// deferred to them less what they withdrew: nobody can take more than they are owed.
    function property_refundsMatchDeferred() public view returns (bool) {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            uint256 owed = auction.refunds(a);
            if (ghostWithdrawnOf[a] > ghostDeferredOf[a]) return false;
            if (owed != ghostDeferredOf[a] - ghostWithdrawnOf[a]) return false;
            sum += owed;
        }
        return auction.refunds(treasury) == 0 && sum == auction.refundLiability();
    }

    /// Every outbid amount was either paid back at once or parked as a refund.
    function property_outbidConserved() public view returns (bool) {
        return ghostOutbidTotal == ghostPushedTotal + ghostDeferredTotal && ghostWithdrawnTotal <= ghostDeferredTotal;
    }

    /// Once the proceeds and every refund are out, only forced ETH (AUDIT.md K-06) is left.
    function property_dustAfterWithdrawals() public view returns (bool) {
        if (!(auction.settled() && auction.proceedsDue() == 0 && auction.refundLiability() == 0)) return true;
        return address(auction).balance == ghostDonated;
    }

    // ================================================================ bids, clock, settlement

    /// The highest bid is the last accepted one, a whole number of units at or above the reserve; the
    /// close is the one the last bid set (it never moves backwards or after the close); no bid, no clock.
    function property_highestBidAndClock() public view returns (bool) {
        uint256 hb = auction.highestBid();
        uint256 ends = auction.endsAt();
        if (hb != ghostLastBid || ends != ghostLastEndsAt) return false;
        if ((auction.highestBidder() == address(0)) != (ends == 0) || (hb == 0) != (ends == 0)) return false;
        if (hb != 0 && (hb < RESERVE || hb % UNIT != 0)) return false;
        if (ends != 0 && ends < startsAt + DURATION) return false;
        if (auction.settled() && block.timestamp < ends) return false;
        return true;
    }

    /// Settled exactly once; the proceeds are paid at most once, only the winning bid, and the outcome
    /// recorded at settlement never changes.
    function property_settledOnce() public view returns (bool) {
        bool s = auction.settled();
        if (ghostSettleCount > 1 || s != (ghostSettleCount == 1)) return false;
        if (ghostProceedsCalls > 1) return false;
        if (ghostProceedsCalls == 1 && ghostProceedsPaid != ghostSettledBid) return false;
        if (s) {
            if (auction.highestBid() != ghostSettledBid || auction.highestBidder() != ghostWinner) return false;
            if (auction.proceedsDue() != (ghostProceedsCalls == 1 ? 0 : ghostSettledBid)) return false;
        } else if (auction.proceedsDue() != 0) {
            return false;
        }
        return true;
    }

    /// Registration: at most 100, never the treasury; bidding needs all 100.
    function property_registration() public view returns (bool) {
        uint256 count = auction.registrationCount();
        uint256 actorsIn;
        for (uint256 i; i < 4; ++i) {
            if (auction.registered(actors[i])) ++actorsIn;
        }
        if (count > 100 || auction.registered(treasury)) return false;
        if (count != ghostRegistrants + actorsIn) return false;
        if (count < 100 && ghostAcceptedBids != 0) return false;
        return true;
    }

    // ================================================================ motif credits

    /// Credits never exceed the cap; allocated = unclaimed credits + claimed = what the bids reserved;
    /// the collection minted exactly the claimed ids.
    function property_credits() public view returns (bool) {
        uint256 allocated = auction.motifsAllocated();
        if (allocated > MOTIF_CAP || allocated > motifs.motifCap() || allocated != ghostAllocated) return false;
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 c = auction.motifCredits(actors[i]);
            if (c != ghostCreditsOf[actors[i]]) return false;
            sum += c;
        }
        if (auction.motifCredits(treasury) != 0) return false;
        if (sum + auction.motifsClaimed() != allocated) return false;
        return motifs.motifsMinted() == auction.motifsClaimed() && motifs.motifsMinted() == ghostMinted;
    }

    /// The winning (highest) bid's motifs are the range its own bid reserved.
    function property_highestBidMotifs() public view returns (bool) {
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        if (first != ghostLastBidFirstMotif || count != ghostLastBidMotifCount) return false;
        if ((first == 0) != (count == 0)) return false;
        if (count != 0 && first + count - 1 > auction.motifsAllocated()) return false;
        return true;
    }

    /// Each actor's unclaimed ranges are the ghost's, non-empty, ascending and within the allocation.
    function property_unclaimedRanges() public view returns (bool) {
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            KilimAuction.CreditRange[] memory r = auction.unclaimedMotifRanges(a);
            uint256 cur = ghostRangeCursor[a];
            if (r.length != ghostRanges[a].length - cur) return false;
            uint256 total;
            for (uint256 j; j < r.length; ++j) {
                if (r[j].nextId != ghostRanges[a][cur + j][0] || r[j].remaining != ghostRanges[a][cur + j][1]) {
                    return false;
                }
                if (r[j].remaining == 0 || r[j].nextId + r[j].remaining - 1 > auction.motifsAllocated()) return false;
                if (j != 0 && r[j - 1].nextId + r[j - 1].remaining > r[j].nextId) return false;
                total += r[j].remaining;
            }
            if (total != auction.motifCredits(a)) return false;
        }
        return true;
    }

    // ================================================================ the 1/1

    /// The 1/1 is minted at most once, only after settlement, and sits with the winner or the
    /// recipient the winner chose.
    function property_oneOfOne() public view returns (bool) {
        bool minted = oneOfOne.minted();
        if (minted != auction.prizeClaimed()) return false;
        if (ghostPrizeDeliveries > 1 || minted != (ghostPrizeDeliveries == 1)) return false;
        if (minted && !auction.settled()) return false;
        if (minted && oneOfOne.ownerOf(1) != ghostPrizeRecipient) return false;
        return true;
    }

    // ================================================================ motifs

    /// Live supply = minted - burned = what the holders hold + strays in the Bazaar; burns are the
    /// owners' own plus the Bazaar's, and each holder's balance is what the ghost moved to it.
    function property_motifSupply() public view returns (bool) {
        uint256 held;
        for (uint256 i; i < 4; ++i) {
            uint256 b = motifs.balanceOf(actors[i]);
            if (b != owned[actors[i]].length) return false;
            held += b;
        }
        if (motifs.balanceOf(treasury) != owned[treasury].length) return false;
        held += owned[treasury].length;
        if (motifs.motifsMinted() - motifs.motifsBurned() != held + ghostStrays) return false;
        return motifs.motifsBurned() == ghostDirectBurns + ghostBazaarBurns;
    }

    // ================================================================ Kilim Bazaar

    /// Nothing happens in the Bazaar before settlement.
    function property_bazaarClosedBeforeSettle() public view returns (bool) {
        if (auction.settled()) return true;
        if (bazaar.totalSupply() != 0 || ghostBazaarBurns != 0) return false;
        for (uint256 i; i < 4; ++i) {
            if (bazaar.loomOf(actors[i]).handKey != 0) return false;
        }
        (, bool open) = bazaar.ladder();
        return !open;
    }

    /// Every kilim: at least 10 motifs, the rank its count earns, numbered densely within its rank, its
    /// made fields never changing, its seal at most once and final.
    function property_kilimRecords() public view returns (bool) {
        uint256 total = bazaar.totalSupply();
        if (total != ghostKilims) return false;
        if (total == 0) return true;
        if (!auction.settled()) return false;
        uint256 top = bazaar.masterCost();
        uint256[7] memory seen;
        uint256[7] memory sumNumbers;
        for (uint256 id = 1; id <= total; ++id) {
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            if (k.count < 10 || k.rank != _expectedRank(k.count, top)) return false;
            if (_madeHash(k) != ghostMadeHash[id]) return false;
            bool isSealed = k.flags & 1 != 0;
            if (isSealed != ghostSealed[id] || ghostSealCount[id] > 1) return false;
            if (isSealed && keccak256(abi.encode(k)) != ghostSealedHash[id]) return false;
            uint8 st = bazaar.sealState(id);
            if (isSealed) {
                if (st != 4) return false;
            } else if (block.number <= k.sealBlock) {
                if (st != 1) return false;
            } else if (block.number - k.sealBlock > bazaar.seedWindow()) {
                if (st != 3) return false;
            } else if (st != 2) {
                return false;
            }
            ++seen[k.rank];
            sumNumbers[k.rank] += k.number;
        }
        uint256 all;
        for (uint8 r = 1; r <= 6; ++r) {
            uint256 w = bazaar.madeAt(r);
            if (seen[r] != w || sumNumbers[r] != (w * (w + 1)) / 2) return false;
            all += w;
        }
        return all == total;
    }

    /// Open looms hold at least 10 motifs and exactly what their owners put in.
    function property_looms() public view returns (bool) {
        for (uint256 i; i < 4; ++i) {
            KilimBazaar.Loom memory l = bazaar.loomOf(actors[i]);
            uint256 key = ghostLoomKey[actors[i]];
            if (l.handKey != key) return false;
            if (key == 0) continue;
            GhostHand storage h = ghostHand[key];
            if (l.count < 10 || l.count != h.count || l.distinct != h.distinct) return false;
            if (l.minId != h.minId || l.maxId != h.maxId) return false;
        }
        return true;
    }

    /// The Bazaar holds only the strays sent to it by plain transfer.
    function property_strays() public view returns (bool) {
        return motifs.balanceOf(address(bazaar)) == ghostStrays && bazaar.strayMotifs() == ghostStrays;
    }

    // ================================================================ reachability (Medusa optimisation mode)
    // Medusa reports the largest value each reached in the campaign: evidence that the paths the
    // properties guard were exercised, not only that nothing failed.

    function optimize_deferredRefunds() public view returns (int256) {
        return int256(hitDeferredRefund);
    }

    function optimize_pulledRefunds() public view returns (int256) {
        return int256(hitWithdrawRefund);
    }

    function optimize_motifsAllocated() public view returns (int256) {
        return int256(auction.motifsAllocated());
    }

    function optimize_settledWithPrizeFallback() public view returns (int256) {
        return int256(hitPrizeFallback);
    }

    function optimize_prizeClaims() public view returns (int256) {
        return int256(hitClaimPrize);
    }

    function optimize_kilims() public view returns (int256) {
        return int256(ghostKilims);
    }

    function optimize_loomCloses() public view returns (int256) {
        return int256(hitMakeFromLoom);
    }

    function optimize_masterKilims() public view returns (int256) {
        return int256(hitMaster);
    }

    function optimize_winningBidKilims() public view returns (int256) {
        return int256(hitWinningBidFlag);
    }

    function optimize_denseOneCallKilims() public view returns (int256) {
        return int256(hitDenseMake);
    }

    function optimize_seals() public view returns (int256) {
        return int256(ghostSeals);
    }

    function optimize_historySeals() public view returns (int256) {
        return int256(ghostHistorySeals);
    }

    function optimize_rearms() public view returns (int256) {
        return int256(ghostRearms);
    }

    /// How often the modelled EIP-2935 contract did not answer with the hash the harness stored.
    function optimize_historyMismatch() public view returns (int256) {
        return int256(historyMismatch);
    }

    // ================================================================ re-entry

    /// No call back into the auction or the Bazaar, made from inside one of their own payments or mints,
    /// ever got through.
    function property_noReentry() public view returns (bool) {
        for (uint256 i = 2; i < 4; ++i) {
            MoodyWallet w = MoodyWallet(payable(actors[i]));
            if (w.auctionReentries() != 0 || w.bazaarReentries() != 0) return false;
        }
        return true;
    }
}
