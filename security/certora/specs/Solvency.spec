/*
 * Solvency and ledger invariants of the Kilim auction.
 * Each invariant is checked after the constructor and preserved by every external function.
 * payOutbidRefund and deliverPrize are filtered out: they revert for every caller but the auction
 * itself (SelfCalls.spec), and their bodies are checked where bid() and settle() inline them. So is
 * the stand-in OneOfOneMock.mint: the real KilimOneOfOne.mint accepts only the auction.
 */
import "Base.spec";

/// The auction's own ETH always covers every obligation it has recorded.
invariant solvency()
    nativeBalances[currentContract] >= liabilities()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// The deferred-refund total is exactly the sum of the individual deferred refunds.
invariant refundLiabilityIsSumOfRefunds()
    to_mathint(refundLiability()) == sumRefunds()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// No single deferred refund exceeds the total, so withdrawRefund never fails on the subtraction.
invariant refundAtMostLiability(address a)
    refunds(a) <= refundLiability()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            requireInvariant refundLiabilityIsSumOfRefunds();
        }
    }

/// No highest bidder means no bid and no clock.
invariant noBidderNoBid()
    highestBidder() == 0 => (highestBid() == 0 && endsAt() == 0)
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// Settlement needs a bid.
invariant settledHasWinner()
    settled() => highestBidder() != 0
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// Proceeds are either nothing or exactly the winning bid, and only after settlement.
/// Time assumption: block.timestamp never decreases, so after settlement (which required
/// timestamp >= endsAt) every later transaction also has timestamp >= endsAt.
invariant proceedsAreTheWinningBid()
    proceedsDue() == 0 || (settled() && proceedsDue() == highestBid())
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            requireInvariant settledHasWinner();
            require settled() => e.block.timestamp >= endsAt(), "time never runs backwards after settlement";
        }
    }

/// Bids are bounded by uint128 (the bound _handleBid applies before the upstream predicate).
invariant highestBidBounded()
    highestBid() <= max_uint128
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// Bidding needs 100 registrations; registration stops there.
invariant registrationCountBounded()
    registrationCount() <= 100
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// The counter equals the number of registered wallets.
invariant registrationCountMatchesRegistered()
    to_mathint(registrationCount()) == countRegistered
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// A bid exists only once registration is complete.
invariant bidsOnlyAfterRegistration()
    highestBidder() != 0 => registrationCount() == 100
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            requireInvariant registrationCountBounded();
        }
    }

/// The 1/1 is delivered at most once, and only after settlement.
invariant prizeOnlyAfterSettlement()
    prizeClaimed() => settled()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

invariant prizeMintedAtMostOnce()
    ghostPrizeMints == (prizeClaimed() ? 1 : 0)
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            requireInvariant prizeOnlyAfterSettlement();
        }
    }

/// The reentrancy guard is idle between transactions.
invariant guardIdle()
    !harnessGuardEntered()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }
