/*
 * minimumBid() against the bid predicate _handleBid applies (the unchanged thirdweb _isNewWinningBid,
 * exposed by the harness): the quoted minimum is always accepted, and no smaller whole-unit bid is.
 * Nonlinear arithmetic, so it runs apart from Auction.spec.
 *
 * Summary: OpenZeppelin's Math.mulDiv(x, y, d, Rounding.Ceil) is replaced by its definition,
 * ceil(x * y / d), computed exactly. Its one call site (minimumBid) passes highestBid <= uint128 max
 * and incrementBps <= 10,000, so x * y < 2^256 and the 512-bit path of mulDiv is never needed.
 */
import "Solvency.spec";

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal
        returns (uint256) => cvlMulDivCeil(x, y, denominator, rounding);
}

function cvlMulDivCeil(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    require denominator > 0, "minimumBid divides by MAX_BPS";
    require rounding == Math.Rounding.Ceil, "the only call site rounds up";
    mathint product = x * y;
    return require_uint256((product + denominator - 1) / denominator);
}

/// The quoted minimum is always a winning bid.
rule minimumBidIsAccepted() {
    configOk();
    requireInvariant highestBidBounded();
    assert harnessIsNewWinningBid(minimumBid());
}

/// No whole-unit amount below the quoted minimum is a winning bid.
rule nothingBelowMinimumIsAccepted(uint256 amount) {
    configOk();
    requireInvariant highestBidBounded();
    require amount % 10^15 == 0;
    require amount < minimumBid();
    assert !harnessIsNewWinningBid(amount);
}

/// So every accepted bid is at least the minimum quoted just before it.
rule bidAtLeastMinimumBid(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    requireInvariant highestBidBounded();
    uint256 minBefore = minimumBid();
    bid(e, amount, minReward, expectedFirst);
    assert amount >= minBefore;
}

/// The launch ladder named in AUDIT.md: 0.01, then 0.011, then 0.013 ETH (at 10% increments).
rule launchLadder() {
    configOk();
    require incrementBps() == 1000;
    require highestBid() == 0 || highestBid() == 10^16 || highestBid() == 11 * 10^15;
    uint256 m = minimumBid();
    assert highestBid() == 0 => m == 10^16;
    assert highestBid() == 10^16 => m == 11 * 10^15;
    assert highestBid() == 11 * 10^15 => m == 13 * 10^15;
}
