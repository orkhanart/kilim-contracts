/*
 * The reserved motif id ranges behind the credits (KilimAuction._creditRanges / _nextCreditRange).
 * Mirrors of the private arrays are kept by hooks, so the invariants can quantify over them.
 *
 *  - every reserved range lies inside 1..motifsAllocated, so a claim can only mint allocated ids;
 *  - ranges before a bidder's cursor are used up, ranges from the cursor on are nonempty, and the
 *    nonempty ones add up to the bidder's credits: a claim of at most the credits always finds its ids.
 */
import "Motifs.spec";

persistent ghost mapping(address => mapping(uint256 => uint128)) rangeNext {
    init_state axiom forall address b. forall uint256 i. rangeNext[b][i] == 0;
}
persistent ghost mapping(address => mapping(uint256 => uint128)) rangeRem {
    init_state axiom forall address b. forall uint256 i. rangeRem[b][i] == 0;
    init_state axiom forall address b. (usum uint256 i. rangeRem[b][i]) == 0;
}
persistent ghost mapping(address => uint256) rangeLen {
    init_state axiom forall address b. rangeLen[b] == 0;
}
persistent ghost mapping(address => uint256) rangeCursor {
    init_state axiom forall address b. rangeCursor[b] == 0;
}
persistent ghost uint256 allocatedMirror {
    init_state axiom allocatedMirror == 0;
}

hook Sstore currentContract._creditRanges[KEY address b][INDEX uint256 i].nextId uint128 v {
    rangeNext[b][i] = v;
}
hook Sload uint128 v currentContract._creditRanges[KEY address b][INDEX uint256 i].nextId {
    require rangeNext[b][i] == v, "mirror equals storage";
}
hook Sstore currentContract._creditRanges[KEY address b][INDEX uint256 i].remaining uint128 v {
    rangeRem[b][i] = v;
}
hook Sload uint128 v currentContract._creditRanges[KEY address b][INDEX uint256 i].remaining {
    require rangeRem[b][i] == v, "mirror equals storage";
}
hook Sstore currentContract._creditRanges[KEY address b].length uint256 v {
    rangeLen[b] = v;
}
hook Sload uint256 v currentContract._creditRanges[KEY address b].length {
    require rangeLen[b] == v, "mirror equals storage";
}
hook Sstore currentContract._nextCreditRange[KEY address b] uint256 v {
    rangeCursor[b] = v;
}
hook Sload uint256 v currentContract._nextCreditRange[KEY address b] {
    require rangeCursor[b] == v, "mirror equals storage";
}
hook Sstore currentContract.motifsAllocated uint256 v {
    allocatedMirror = v;
}
hook Sload uint256 v currentContract.motifsAllocated {
    require allocatedMirror == v, "mirror equals storage";
}

/// Every reserved range is inside 1..motifsAllocated.
invariant rangesWithinAllocation()
    forall address b. forall uint256 i. i < rangeLen[b] =>
        (rangeNext[b][i] >= 1 && rangeNext[b][i] + rangeRem[b][i] <= allocatedMirror + 1)
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            require allocatedMirror == motifsAllocated(), "mirror equals storage";
            requireInvariant motifAllocationWithinCap();
        }
    }

/// So mintMotifs is never asked for an id outside 1..motifsAllocated.
invariant mintsInsideAllocation()
    !ghostMintOutsideAllocation
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            require allocatedMirror == motifsAllocated(), "mirror equals storage";
            requireInvariant rangesWithinAllocation();
        }
    }

/// A bidder has at most as many ranges as motifs were ever allocated (each range starts nonempty).
invariant rangeCountBounded(address b)
    rangeLen[b] <= allocatedMirror
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            require allocatedMirror == motifsAllocated(), "mirror equals storage";
            requireInvariant motifAllocationWithinCap();
        }
    }

/// The cursor splits a bidder's ranges into used-up ones and nonempty ones; nothing past the end.
invariant cursorSplitsRanges(address b)
    rangeCursor[b] <= rangeLen[b]
        && (forall uint256 i. i < rangeCursor[b] => rangeRem[b][i] == 0)
        && (forall uint256 i. (i >= rangeCursor[b] && i < rangeLen[b]) => rangeRem[b][i] > 0)
        && (forall uint256 i. i >= rangeLen[b] => rangeRem[b][i] == 0)
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            require allocatedMirror == motifsAllocated(), "mirror equals storage";
            requireInvariant motifAllocationWithinCap();
            requireInvariant creditsAreTheUnclaimedRanges(b);
            requireInvariant rangeCountBounded(b);
        }
    }

/// A bidder's credits are exactly what their ranges still hold.
invariant creditsAreTheUnclaimedRanges(address b)
    to_mathint(mirrorCredits[b]) == (usum uint256 i. rangeRem[b][i])
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
            require allocatedMirror == motifsAllocated(), "mirror equals storage";
            requireInvariant motifAllocationWithinCap();
            requireInvariant cursorSplitsRanges(b);
            requireInvariant rangeCountBounded(b);
        }
    }
