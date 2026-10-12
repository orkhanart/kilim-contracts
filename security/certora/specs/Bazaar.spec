/*
 * Kilim Bazaar (stretch): the rank rule and the seal. make/deposit/makeFromLoom are NOT covered here:
 * a kilim needs at least 10 burned ids and its hand is counted over 64 words x 16 lanes, loops the
 * prover would have to unroll a thousand times (see the report).
 *
 * The auction is not in the scene. Its two reads the rank rule uses are summarised by fixed ghost
 * values for the whole rule (the auction is final once settled: no bid lands after the close).
 */

methods {
    function rankFor(uint256) external returns (uint8) envfree;
    function masterCost() external returns (uint256) envfree;
    function motifPrice() external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
    function madeAt(uint8) external returns (uint256) envfree;
    function ladder() external returns (uint256[6], bool) envfree;

    function _.settled() external => cvlSettled() expect bool;
    function _.highestBid() external => cvlHighestBid() expect uint256;
}

ghost bool ghostSettled;
ghost uint256 ghostHighestBid;

function cvlSettled() returns bool {
    return ghostSettled;
}

function cvlHighestBid() returns uint256 {
    return ghostHighestBid;
}

/// After settlement: the bid unit is 0.001 ETH (constructor reads the auction's MOTIF_PRICE), and the
/// winning bid is a whole number of units, at least the 0.01 ETH reserve and below uint128.
function settledAuction() {
    require motifPrice() == 10^15, "constructor: motifPrice = auction.MOTIF_PRICE()";
    require ghostSettled, "after settlement";
    require ghostHighestBid >= 10^16 && ghostHighestBid % 10^15 == 0 && ghostHighestBid <= max_uint128,
        "auction invariants: whole units, at least the reserve";
}

definition cost(mathint r) returns mathint =
    r == 1 ? 10 : (r == 2 ? 30 : (r == 3 ? 100 : (r == 4 ? 300 : 1000)));

/// Rank 0 exactly under the floor of 10; never above the Master (6).
rule rankZeroOnlyUnderFloor(uint256 count) {
    settledAuction();
    uint8 r = rankFor(count);
    assert (r == 0) <=> (count < 10);
    assert r <= 6;
}

/// More motifs never make a lower rank.
rule rankMonotone(uint256 a, uint256 b) {
    settledAuction();
    require a <= b;
    assert rankFor(a) <= rankFor(b);
}

/// The Master exactly at or above its cost (the winning bid in units).
rule masterExactlyAtTop(uint256 count) {
    settledAuction();
    uint8 r = rankFor(count);
    assert masterCost() == ghostHighestBid / 10^15;
    assert (r == 6) <=> (count >= masterCost());
}

/// Below the Master: the highest fixed cost the count reaches.
rule fixedRankIsHighestCostReached(uint256 count) {
    settledAuction();
    uint8 r = rankFor(count);
    require r >= 1 && r <= 5;
    assert to_mathint(count) >= cost(r);
    assert r < 5 => to_mathint(count) < cost(r + 1);
    assert count < masterCost();
}

/// No rank before settlement.
rule rankForRevertsBeforeSettlement(uint256 count) {
    require !ghostSettled;
    rankFor@withrevert(count);
    assert lastReverted;
}

/// The ladder the page shows agrees with rankFor: each listed cost reaches its rank.
rule ladderAgreesWithRankFor(uint256 i) {
    settledAuction();
    uint256[6] costs;
    bool open;
    (costs, open) = ladder();
    require i < 5;
    assert open;
    assert costs[5] == masterCost();
    assert costs[i] != 0 => rankFor(costs[i]) == assert_uint8(i + 1);
    assert costs[i] == 0 => cost(i + 1) >= to_mathint(masterCost());
}

/// seal() never unseals a kilim, never changes a sealed seed, never changes anything but the seal
/// fields, never creates a kilim and never changes the tally.
rule sealOnlySeals(env e, uint256[] tokenIds, uint256 id) {
    uint8 flags = currentContract._kilims[id].flags;
    uint32 seed = currentContract._kilims[id].seed;
    uint8 rank = currentContract._kilims[id].rank;
    uint32 count = currentContract._kilims[id].count;
    uint32 handKey = currentContract._kilims[id].handKey;
    uint32 number = currentContract._kilims[id].number;
    uint16 title = currentContract._kilims[id].title;
    uint16 distinct = currentContract._kilims[id].distinct;
    uint40 sealBlock = currentContract._kilims[id].sealBlock;
    uint256 tally = currentContract._tally;

    seal(e, tokenIds);

    uint8 flagsAfter = currentContract._kilims[id].flags;
    assert currentContract._tally == tally, "seal never touches the tally";
    assert currentContract._kilims[id].rank == rank && currentContract._kilims[id].count == count
        && currentContract._kilims[id].handKey == handKey && currentContract._kilims[id].number == number
        && currentContract._kilims[id].title == title && currentContract._kilims[id].distinct == distinct,
        "a kilim's hand and rank never change";
    assert flags & 1 != 0 => (flagsAfter == flags && currentContract._kilims[id].seed == seed
        && currentContract._kilims[id].sealBlock == sealBlock), "a sealed kilim is final";
    assert rank == 0 => (flagsAfter == flags && currentContract._kilims[id].seed == seed
        && currentContract._kilims[id].sealBlock == sealBlock), "no kilim, nothing written";
    assert flagsAfter != flags => flagsAfter == (flags | 1), "the only flag seal sets is SEALED";
}
