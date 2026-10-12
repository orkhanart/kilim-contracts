/*
 * Motif credits: allocation at bid time, claims, and what reaches KilimMotifs.mintMotifs.
 * mintMotifs is summarised (Base.spec): it records quantities, the bidder argument and whether an
 * id fell outside 1..motifsAllocated, and may revert.
 */
import "Base.spec";

/// Credits never exceed the motif cap.
invariant motifAllocationWithinCap()
    motifsAllocated() <= motifCap()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// Every allocated credit is either still held by some bidder or already claimed:
/// sum of motifCredits == motifsAllocated - motifsClaimed (so motifsClaimed <= motifsAllocated).
invariant creditsMatchAllocation()
    sumCredits() == motifsAllocated() - motifsClaimed()
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// Every claimed credit was minted exactly once (counting motifs handed to mintMotifs).
invariant mintedEqualsClaimed()
    ghostMotifsMinted == to_mathint(motifsClaimed())
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// mintMotifs is only ever asked to mint for the bidder who is claiming.
invariant mintsOnlyForTheClaimer()
    !ghostMintForOther
    filtered { f -> auctionEntry(f) }
    {
        preserved with (env e) {
            configOk();
            requireRealCaller(e);
        }
    }

/// A bid allocates exactly rewardForBid(amount) credits to the bidder, reserving the next ids.
rule bidAllocatesReward(env e, uint256 amount, uint256 minReward, uint256 expectedFirst) {
    configOk();
    requireRealCaller(e);
    requireInvariant motifAllocationWithinCap();
    mathint reward = rewardForBid(amount);
    mathint allocated = motifsAllocated();
    mathint credits = motifCredits(e.msg.sender);
    address other;
    require other != e.msg.sender;
    mathint otherCredits = motifCredits(other);
    mathint claimed = motifsClaimed();

    bid(e, amount, minReward, expectedFirst);

    uint256 first; uint256 count;
    (first, count) = highestBidMotifs();
    assert reward >= to_mathint(minReward), "reward slippage guard";
    assert reward == to_mathint(amount / 10^15) || reward == to_mathint(maxMotifsPerBid()) || reward == motifCap() - allocated,
        "reward is the capped bid size";
    assert reward <= to_mathint(amount / 10^15) && reward <= to_mathint(maxMotifsPerBid()), "never above either limit";
    assert to_mathint(motifCredits(e.msg.sender)) == credits + reward, "the bidder gets the reward";
    assert to_mathint(motifCredits(other)) == otherCredits, "nobody else does";
    assert to_mathint(motifsAllocated()) == allocated + reward && motifsAllocated() <= motifCap(), "allocation within the cap";
    assert to_mathint(motifsClaimed()) == claimed, "claims untouched";
    assert to_mathint(count) == reward, "highestBidMotifs count";
    assert reward != 0 => to_mathint(first) == allocated + 1, "ids continue the allocation order";
    assert reward == 0 => first == 0, "no reward, no ids";
    assert expectedFirst != 0 => first == expectedFirst, "expected-id guard";
}

/// claimMotifs mints exactly the requested quantity, never more than the caller's credits, for the
/// caller, and takes it from the caller's credits.
rule claimMotifsNeverExceedsCredits(env e, uint256 quantity, address to) {
    configOk();
    requireRealCaller(e);
    mathint credits = motifCredits(e.msg.sender);
    address other;
    require other != e.msg.sender;
    mathint otherCredits = motifCredits(other);
    mathint minted = ghostMotifsMinted;
    mathint mintedForCaller = ghostMotifsMintedFor[e.msg.sender];
    mathint claimed = motifsClaimed();
    bool forOther = ghostMintForOther;
    require !forOther;

    claimMotifs(e, quantity, to);

    assert quantity >= 1 && quantity <= 64, "batch bound";
    assert to_mathint(quantity) <= credits, "never past the caller's credits";
    assert to_mathint(motifCredits(e.msg.sender)) == credits - quantity, "credits drop by the quantity";
    assert to_mathint(motifCredits(other)) == otherCredits, "nobody else's credits change";
    assert ghostMotifsMinted == minted + quantity, "exactly the quantity is minted";
    assert ghostMotifsMintedFor[e.msg.sender] == mintedForCaller + quantity, "all of it for the caller";
    assert !ghostMintForOther, "no mint names another bidder";
    assert to_mathint(motifsClaimed()) == claimed + quantity, "claimed total moves with it";
}

/// More than the caller's credits always reverts.
rule claimMoreThanCreditsReverts(env e, uint256 quantity, address to) {
    require to_mathint(quantity) > to_mathint(motifCredits(e.msg.sender));
    claimMotifs@withrevert(e, quantity, to);
    assert lastReverted;
}
