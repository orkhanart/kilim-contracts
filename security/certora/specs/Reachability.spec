/*
 * Witnesses (satisfy): the interesting paths are reachable in the model, so the safety rules are not
 * passing because a path was accidentally cut away (for example a self-call that never succeeds).
 */
import "Solvency.spec";

/// An outbid refund paid straight back: the auction's ETH drops by the old bid net of the new one.
rule witnessRefundPaidDirectly(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    address prev = highestBidder();
    uint256 prevBid = highestBid();
    require prev != 0 && prev != currentContract && prev != e.msg.sender;
    mathint balance = nativeBalances[currentContract];
    uint256 prevRefund = refunds(prev);

    bid(e, amount, minReward, expectedFirst);

    satisfy refunds(prev) == prevRefund
        && to_mathint(nativeBalances[currentContract]) == balance + amount - prevBid;
}

/// An outbid refund the receiver rejected: it waits in refunds.
rule witnessRefundDeferred(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    address prev = highestBidder();
    uint256 prevBid = highestBid();
    require prev != 0 && prev != e.msg.sender;
    uint256 prevRefund = refunds(prev);

    bid(e, amount, minReward, expectedFirst);

    satisfy to_mathint(refunds(prev)) == prevRefund + prevBid && prevBid > 0;
}

/// Settlement that delivers the 1/1, and settlement whose delivery fails.
rule witnessSettleDelivers(env e) {
    configOk();
    requireRealCaller(e);
    settle(e);
    satisfy prizeClaimed();
}

rule witnessSettleDeliveryFails(env e) {
    configOk();
    requireRealCaller(e);
    require !prizeClaimed();
    settle(e);
    satisfy !prizeClaimed();
}

/// A claim that spans two credit ranges (two mintMotifs calls).
rule witnessClaimAcrossTwoRanges(env e, uint256 quantity, address to) {
    configOk();
    requireRealCaller(e);
    mathint calls = ghostMintCalls;
    claimMotifs(e, quantity, to);
    satisfy ghostMintCalls == calls + 2;
}

/// The payouts succeed in the model.
rule witnessWithdrawRefund(env e, address to) {
    configOk();
    requireRealCaller(e);
    mathint balance = nativeBalances[currentContract];
    uint256 owed = refunds(e.msg.sender);
    withdrawRefund(e, to);
    satisfy to_mathint(nativeBalances[currentContract]) == balance - owed;
}

rule witnessWithdrawProceeds(env e, address to) {
    configOk();
    requireRealCaller(e);
    withdrawProceeds(e, to);
    satisfy true;
}

rule witnessRegisterFor(env e, address wallet, uint256 deadline, bytes signature) {
    configOk();
    requireRealCaller(e);
    registerFor(e, wallet, deadline, signature);
    satisfy registered(wallet);
}

/// The 100th registration, then a first bid.
rule witnessHundredthRegistrationThenBid(env e1, env e2, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e1);
    requireRealCaller(e2);
    require registrationCount() == 99 && highestBidder() == 0;
    register(e1);
    bid(e2, amount, minReward, expectedFirst);
    satisfy highestBidder() == e2.msg.sender;
}
