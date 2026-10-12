/*
 * Bid, refund, settlement and proceeds rules of the Kilim auction.
 */
import "Solvency.spec";

// ------------------------------------------------------------------ bid

/// An accepted bid is the new highest bid, strictly above the old one, paid in full, in whole
/// 0.001 ETH units, once 100 wallets have registered, and not by the treasury.
/// (That it is never below minimumBid() is in MinimumBid.spec: nonlinear arithmetic, run apart.)
rule bidRaisesHighestBid(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    uint256 before = highestBid();

    bid(e, amount, minReward, expectedFirst);

    assert highestBid() > before, "highest bid strictly increases";
    assert highestBid() == amount && highestBidder() == e.msg.sender, "the bid is recorded as the highest";
    assert e.msg.value == amount, "msg.value equals the bid";
    assert amount % 10^15 == 0, "whole bid units";
    assert amount <= max_uint128, "bounded by uint128";
    assert registrationCount() == 100, "bidding needs 100 registrations";
    assert e.msg.sender != treasury(), "the treasury cannot bid";
}

/// Bidding is open only from the 100th registration until the close; the close never moves earlier
/// and an extension puts it at least extensionWindow after the bid.
rule bidTiming(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    requireInvariant noBidderNoBid();
    address bidderBefore = highestBidder();
    uint64 endBefore = endsAt();

    bid(e, amount, minReward, expectedFirst);

    assert bidderBefore != 0 => e.block.timestamp < endBefore, "no bid at or after the close";
    assert bidderBefore == 0 => to_mathint(endsAt()) == e.block.timestamp + duration(), "first bid starts the clock";
    assert endsAt() >= endBefore, "the close never moves earlier";
    assert bidderBefore != 0 => to_mathint(endsAt()) >= e.block.timestamp + extensionWindow(), "late bids extend";
}

/// The outbid bid goes back to the outbid bidder: either paid to them now (exactly that amount, and
/// no ETH to anyone else) or, if that payment fails, recorded in full as their deferred refund. Never
/// both, never neither, never to anyone else's ledger entry.
rule bidRefundsOutbidBidder(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    requireInvariant noBidderNoBid();
    address prev = highestBidder();
    uint256 prevBid = highestBid();
    address other;
    require other != prev;
    uint256 otherRefund = refunds(other);
    mathint prevRefund = refunds(prev);
    mathint liability = refundLiability();
    mathint balance = nativeBalances[currentContract];
    mathint sent = ghostEthSent;
    mathint sentToPrev = ghostEthSentTo[prev];

    bid(e, amount, minReward, expectedFirst);

    mathint paid = ghostEthSent - sent;
    bool deferred = to_mathint(refunds(prev)) != prevRefund;
    assert refunds(other) == otherRefund, "no other ledger entry changes";
    assert paid == ghostEthSentTo[prev] - sentToPrev, "ETH goes only to the outbid bidder";
    assert prev == 0 => (paid == 0 && !deferred && to_mathint(refundLiability()) == liability),
        "first bid: nothing to refund";
    assert prev != 0 => ((paid == to_mathint(prevBid) && !deferred && to_mathint(refundLiability()) == liability)
            || (paid == 0 && deferred && to_mathint(refunds(prev)) == prevRefund + prevBid
                && to_mathint(refundLiability()) == liability + prevBid)),
        "paid in full now, or deferred in full";
    assert to_mathint(nativeBalances[currentContract]) >= balance + amount - paid, "no other ETH leaves";
}

// ------------------------------------------------------------------ refunds

/// withdrawRefund pays the caller's own deferred refund, at most that much, and touches nobody else.
rule withdrawRefundPaysOnlyOwed(env e, address to) {
    configOk();
    requireRealCaller(e);
    address other;
    require other != e.msg.sender;
    uint256 owed = refunds(e.msg.sender);
    uint256 otherBefore = refunds(other);
    mathint liability = refundLiability();
    mathint balance = nativeBalances[currentContract];
    mathint sent = ghostEthSent;
    mathint sentTo = ghostEthSentTo[to];

    withdrawRefund(e, to);

    assert owed > 0, "nothing to withdraw reverts";
    assert refunds(e.msg.sender) == 0, "the caller's refund is cleared";
    assert refunds(other) == otherBefore, "no one else's refund changes";
    assert to_mathint(refundLiability()) == liability - owed, "the total drops by the amount";
    assert ghostEthSent - sent == to_mathint(owed) && ghostEthSentTo[to] - sentTo == to_mathint(owed),
        "exactly the amount owed is sent, to the chosen address";
    assert to_mathint(nativeBalances[currentContract]) >= balance - owed, "no other ETH leaves";
    assert to != 0 && to != currentContract && to != motifs() && to != oneOfOne(), "valid recipient";
}

/// A refund cannot be withdrawn twice.
rule withdrawRefundOnce(env e1, env e2, address to1, address to2) {
    configOk();
    requireRealCaller(e1);
    require e2.msg.sender == e1.msg.sender;
    withdrawRefund(e1, to1);
    withdrawRefund@withrevert(e2, to2);
    assert lastReverted, "second withdrawal reverts";
}

// ------------------------------------------------------------------ settlement and proceeds

/// settle() works only after the close, only with a bid, and only once; it fixes the proceeds at
/// the winning bid.
rule settleOnlyAfterCloseOnce(env e, env e2) {
    configOk();
    requireRealCaller(e);
    bool settledBefore = settled();
    uint64 endBefore = endsAt();
    address winner = highestBidder();
    uint256 winning = highestBid();

    settle(e);

    assert !settledBefore, "only once";
    assert winner != 0, "needs a bid";
    assert e.block.timestamp >= endBefore, "only after the close";
    assert settled() && proceedsDue() == winning, "proceeds are the winning bid";
    assert highestBidder() == winner && highestBid() == winning, "the outcome does not move";

    settle@withrevert(e2);
    assert lastReverted, "a second settle reverts";
}

/// withdrawProceeds pays only the treasury's chosen address, only after settlement, only the winning
/// bid, and only once.
rule withdrawProceedsOnlyTreasuryOnce(env e, address to, env e2, address to2) {
    configOk();
    requireRealCaller(e);
    requireInvariant proceedsAreTheWinningBid();
    uint256 due = proceedsDue();
    uint256 winning = highestBid();
    bool settledBefore = settled();
    mathint balance = nativeBalances[currentContract];
    mathint liability = refundLiability();
    mathint sent = ghostEthSent;
    mathint sentTo = ghostEthSentTo[to];

    withdrawProceeds(e, to);

    assert e.msg.sender == treasury(), "only the treasury";
    assert settledBefore, "only after settlement";
    assert due == winning && due > 0, "exactly the winning bid";
    assert proceedsDue() == 0, "cleared";
    assert to_mathint(refundLiability()) == liability, "refunds untouched";
    assert ghostEthSent - sent == to_mathint(winning) && ghostEthSentTo[to] - sentTo == to_mathint(winning),
        "exactly the winning bid is sent, to the chosen address";
    assert to_mathint(nativeBalances[currentContract]) >= balance - winning, "no other ETH leaves";

    withdrawProceeds@withrevert(e2, to2);
    assert lastReverted, "a second withdrawal reverts";
}

/// Nobody but the treasury can take the proceeds.
rule withdrawProceedsRevertsForOthers(env e, address to) {
    require e.msg.sender != treasury();
    withdrawProceeds@withrevert(e, to);
    assert lastReverted;
}

// ------------------------------------------------------------------ the 1/1

/// claimPrize: only the winner, only after settlement, only if settlement could not deliver it.
rule claimPrizeOnlyWinnerOnce(env e, address to, env e2, address to2) {
    configOk();
    requireRealCaller(e);
    bool claimedBefore = prizeClaimed();
    mathint mints = ghostPrizeMints;

    claimPrize(e, to);

    assert settled() && e.msg.sender == highestBidder(), "only the winner, after settlement";
    assert !claimedBefore && prizeClaimed(), "only once";
    assert ghostPrizeMints == mints + 1 && ghostPrizeTo == to, "one 1/1 mint, to the chosen address";

    claimPrize@withrevert(e2, to2);
    assert lastReverted, "a second claim reverts";
}

/// Settlement either delivers the 1/1 to the winner (one mint, prizeClaimed) or leaves it claimable.
rule settleDeliversPrizeOrLeavesItClaimable(env e) {
    configOk();
    requireRealCaller(e);
    requireInvariant prizeOnlyAfterSettlement();
    requireInvariant prizeMintedAtMostOnce();
    mathint mints = ghostPrizeMints;
    address winner = highestBidder();

    settle(e);

    assert prizeClaimed() => (ghostPrizeMints == mints + 1 && ghostPrizeTo == winner), "delivered to the winner";
    assert !prizeClaimed() => ghostPrizeMints == mints, "not delivered: nothing minted, still claimable";
}
