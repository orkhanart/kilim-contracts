/*
 * "Only X changes Y": for every external function f (the two self-calls are covered by SelfCalls.spec
 * and inside bid/settle), what f may do to each piece of key state.
 */
import "Solvency.spec";

definition stateChanging(method f) returns bool = !f.isView && auctionEntry(f);

/// Only bid moves the highest bid, the highest bidder and the close; the highest bid and the close
/// never go down.
rule onlyBidMovesTheAuction(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    requireInvariant noBidderNoBid();
    uint256 hb = highestBid();
    address hbr = highestBidder();
    uint64 end = endsAt();

    f(e, args);

    assert (highestBid() != hb || highestBidder() != hbr || endsAt() != end) => isBid(f);
    assert highestBid() >= hb, "the highest bid never goes down";
    assert endsAt() >= end, "the close never moves earlier";
}

/// Only settle sets `settled`, and nothing clears it.
rule onlySettleSettles(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    bool before = settled();

    f(e, args);

    assert settled() != before => (isSettle(f) && !before);
}

/// Proceeds appear only at settlement and leave only through withdrawProceeds, by the treasury.
rule proceedsChangeOnlyBySettleOrTreasury(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    requireInvariant proceedsAreTheWinningBid();
    uint256 before = proceedsDue();

    f(e, args);

    assert proceedsDue() > before => isSettle(f);
    assert proceedsDue() < before => (isWithdrawProceeds(f) && e.msg.sender == treasury() && proceedsDue() == 0);
}

/// A deferred refund grows only when its owner is outbid (by exactly the outbid bid), and shrinks
/// only when its owner withdraws it (to zero).
rule refundsChangeOnlyByOutbidOrOwner(method f, address u) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    uint256 before = refunds(u);
    address hbr = highestBidder();
    uint256 hb = highestBid();

    f(e, args);

    assert refunds(u) > before => (isBid(f) && u == hbr && to_mathint(refunds(u)) == before + hb);
    assert refunds(u) < before => (isWithdrawRefund(f) && e.msg.sender == u && refunds(u) == 0);
}

/// Only bid and withdrawRefund move the refund total.
rule refundLiabilityChangesOnlyByBidOrWithdraw(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    uint256 before = refundLiability();

    f(e, args);

    assert refundLiability() > before => isBid(f);
    assert refundLiability() < before => isWithdrawRefund(f);
}

/// ETH leaves the auction only through bid (the outbid refund), withdrawRefund or withdrawProceeds.
rule ethLeavesOnlyThroughPayouts(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    mathint balance = nativeBalances[currentContract];
    mathint sent = ghostEthSent;

    f(e, args);

    assert to_mathint(nativeBalances[currentContract]) < balance + e.msg.value =>
        (isBid(f) || isWithdrawRefund(f) || isWithdrawProceeds(f));
    assert ghostEthSent != sent => (isBid(f) || isWithdrawRefund(f) || isWithdrawProceeds(f));
}

/// Credits grow only for the bidder in bid, and shrink only for the claimer in claimMotifs.
rule creditsChangeOnlyByBidOrOwnClaim(method f, address u) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    uint256 before = motifCredits(u);
    uint256 allocated = motifsAllocated();
    uint256 claimed = motifsClaimed();

    f(e, args);

    assert motifCredits(u) > before => (isBid(f) && e.msg.sender == u);
    assert motifCredits(u) < before => (isClaimMotifs(f) && e.msg.sender == u);
    assert motifsAllocated() != allocated => isBid(f);
    assert motifsClaimed() != claimed => isClaimMotifs(f);
    assert motifsAllocated() >= allocated && motifsClaimed() >= claimed, "both counters only grow";
}

/// Only settlement (delivery) and claimPrize set prizeClaimed, and nothing clears it.
rule prizeClaimedOnlyBySettleOrClaim(method f) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    bool before = prizeClaimed();
    mathint mints = ghostPrizeMints;

    f(e, args);

    assert prizeClaimed() != before => (!before && (isSettle(f) || isClaimPrize(f)));
    assert ghostPrizeMints != mints => (isSettle(f) || isClaimPrize(f));
}

/// Only the two registration functions register, a registration is never undone, and they register
/// one wallet at a time.
rule registrationOnlyByRegister(method f, address w) filtered { f -> stateChanging(f) } {
    env e;
    calldataarg args;
    configOk();
    requireRealCaller(e);
    uint256 count = registrationCount();
    bool was = registered(w);

    f(e, args);

    assert registrationCount() != count => (isRegister(f) && to_mathint(registrationCount()) == count + 1);
    assert registered(w) != was => (isRegister(f) && !was);
}
