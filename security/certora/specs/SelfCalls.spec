/*
 * The two self-call entry points and the reentrancy guard. These rules justify the modelling choice
 * in Base.spec that an outside call cannot change the auction's state (HAVOC_ECF): while any
 * guarded call is in progress, every state-changing entry point reverts for every caller except the
 * auction itself, and the auction calls itself only through the two functions below.
 */
import "Base.spec";

/// payOutbidRefund pays nothing to anyone who calls it from outside.
rule payOutbidRefundOnlyBySelf(env e, address bidder, uint256 amount) {
    require e.msg.sender != currentContract;
    payOutbidRefund@withrevert(e, bidder, amount);
    assert lastReverted;
}

/// deliverPrize mints nothing for anyone who calls it from outside.
rule deliverPrizeOnlyBySelf(env e) {
    require e.msg.sender != currentContract;
    deliverPrize@withrevert(e);
    assert lastReverted;
}

/// Re-entry while a guarded function runs: every state-changing entry point reverts.
rule reentryReverts(method f) filtered { f -> !f.isView && f.contract == currentContract } {
    env e;
    calldataarg args;
    require harnessGuardEntered();
    require e.msg.sender != currentContract;
    f@withrevert(e, args);
    assert lastReverted;
}

/// payOutbidRefund, when the auction does call it, moves at most `amount` out and changes no state.
rule payOutbidRefundMovesOnlyAmount(env e, address bidder, uint256 amount) {
    require e.msg.sender == currentContract;
    require e.msg.value == 0;
    require bidder != currentContract;
    mathint balance = nativeBalances[currentContract];
    uint256 hb = highestBid();
    mathint liability = refundLiability();
    address other;
    uint256 r = refunds(other);

    payOutbidRefund(e, bidder, amount);

    assert to_mathint(nativeBalances[currentContract]) >= balance - amount;
    assert highestBid() == hb && to_mathint(refundLiability()) == liability && refunds(other) == r;
}
