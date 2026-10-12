// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {HalmosBase} from "./HalmosBase.sol";

/// @notice rewardForBid() for ALL amounts and ALL allocation levels, on the mainnet parameters
///         (motifCap 1,000,000 = maxMotifsPerBid) and the test fixture's (10,000 and 1,000).
contract RewardForBidHalmos is HalmosBase {
    uint256 internal constant SLOT_ALLOCATED = 11;
    KilimAuction internal mainnet;
    KilimAuction internal fixture;

    function setUp() public {
        (,, mainnet) = deployTrio(1_000_000, 1_000_000, 1000, 1 days, 10 minutes);
        (,, fixture) = deployTrio(10_000, 1000, 500, 22 hours, 10 minutes);
    }

    /// @dev Amounts up to uint128 max: every amount a bid can carry (_handleBid refuses more).
    function _check(KilimAuction a, uint256 allocated, uint256 amount) internal {
        uint256 cap = a.motifCap();
        uint256 maxPer = a.maxMotifsPerBid();
        vm.assume(allocated <= cap && amount <= type(uint128).max);
        vm.store(address(a), bytes32(SLOT_ALLOCATED), bytes32(allocated));
        (bool ok, bytes memory ret) = address(a).staticcall(abi.encodeCall(a.rewardForBid, (amount)));
        assert(ok); // never reverts while allocated <= cap (the auction keeps it so)
        uint256 r = abi.decode(ret, (uint256));
        assert(r <= maxPer);
        assert(r <= amount / UNIT);
        assert(allocated + r <= cap);
        assert(r == _min(_min(amount / UNIT, maxPer), cap - allocated));
        // A bid the auction can accept (at least the reserve) earns nothing only when the pool is empty.
        if (amount >= RESERVE) assert((r == 0) == (allocated == cap));
    }

    /// @dev Monotone in the amount.
    function _monotone(KilimAuction a, uint256 allocated, uint256 amount, uint256 amount2) internal {
        vm.assume(allocated <= a.motifCap() && amount <= amount2 && amount2 <= type(uint128).max);
        vm.store(address(a), bytes32(SLOT_ALLOCATED), bytes32(allocated));
        assert(a.rewardForBid(amount) <= a.rewardForBid(amount2));
    }

    function check_rewardForBid_mainnet(uint256 allocated, uint256 amount) public {
        _check(mainnet, allocated, amount);
    }

    function check_rewardForBid_fixture(uint256 allocated, uint256 amount) public {
        _check(fixture, allocated, amount);
    }

    function check_rewardForBid_monotone_mainnet(uint256 allocated, uint256 amount, uint256 amount2) public {
        _monotone(mainnet, allocated, amount, amount2);
    }

    function check_rewardForBid_monotone_fixture(uint256 allocated, uint256 amount, uint256 amount2) public {
        _monotone(fixture, allocated, amount, amount2);
    }
}

/// @notice Four symbolic bids (amounts symbolic, bidders A, B, A, B) on a small pool (cap 26, at most 12 per
///         bid) so the cap binds within the sequence. After every bid: the reward is rewardForBid quoted just
///         before it, the reserved ids are the next ones in order (contiguous with the previous bid's),
///         highestBidMotifs() names exactly that bid's ids, credits and allocation add up, and nothing
///         passes the cap.
contract MotifAllocationHalmos is HalmosBase {
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    KilimAuction internal auction;
    uint256 internal constant CAP = 26;

    function setUp() public {
        (,, auction) = deployTrio(CAP, 12, 1000, 1 days, 10 minutes);
        openBidding(auction);
        vm.deal(A, 1e24);
        vm.deal(B, 1e24);
    }

    function _bid(address who, uint256 units, uint256 nextExpected) internal returns (uint256 next) {
        vm.assume(units < 1_000_000_000);
        uint256 amount = units * UNIT;
        uint256 allocatedBefore = auction.motifsAllocated();
        uint256 quoted = auction.rewardForBid(amount);
        uint256 creditsBefore = auction.motifCredits(who);
        uint256 rangesBefore = auction.unclaimedMotifRanges(who).length;
        vm.prank(who);
        (bool ok,) = address(auction).call{value: amount}(abi.encodeCall(auction.bid, (amount, 0, 0)));
        vm.assume(ok);
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        assert(count == quoted);
        assert(auction.motifsAllocated() == allocatedBefore + count);
        assert(auction.motifsAllocated() <= CAP);
        assert(auction.motifCredits(who) == creditsBefore + count);
        KilimAuction.CreditRange[] memory ranges = auction.unclaimedMotifRanges(who);
        if (count == 0) {
            assert(first == 0);
            assert(ranges.length == rangesBefore);
            next = nextExpected;
        } else {
            // Contiguous with every earlier reservation, and recorded as the bidder's newest range.
            assert(first == allocatedBefore + 1);
            assert(first == nextExpected);
            assert(first + count - 1 <= CAP);
            assert(ranges.length == rangesBefore + 1);
            assert(ranges[ranges.length - 1].nextId == first && ranges[ranges.length - 1].remaining == count);
            next = first + count;
        }
    }

    function check_allocation_fourBids(uint256 u1, uint256 u2, uint256 u3, uint256 u4) public {
        uint256 next = _bid(A, u1, 1);
        next = _bid(B, u2, next);
        next = _bid(A, u3, next);
        next = _bid(B, u4, next);
        assert(auction.motifCredits(A) + auction.motifCredits(B) == auction.motifsAllocated());
        assert(next == auction.motifsAllocated() + 1);
    }

    /// @dev Reachability probe (EXPECTED to FAIL): four accepted bids that exhaust the pool exist, with the
    ///      last earning nothing, so check_allocation_fourBids covers the capped branch.
    function check_reach_poolExhausted_EXPECTED_FAIL(uint256 u1, uint256 u2, uint256 u3, uint256 u4) public {
        uint256 next = _bid(A, u1, 1);
        next = _bid(B, u2, next);
        next = _bid(A, u3, next);
        next = _bid(B, u4, next);
        (, uint256 count) = auction.highestBidMotifs();
        assert(!(auction.motifsAllocated() == CAP && count == 0));
    }

    /// @dev A bid naming the wrong first id reverts; the right one (or 0) is accepted.
    function check_expectedFirstMotifId(uint256 amount, uint256 expected) public {
        // A whole-unit amount, stated as a remainder (not units * UNIT: the solver cannot undo that product).
        vm.assume(amount % UNIT == 0 && amount >= RESERVE && amount <= 1e24);
        vm.prank(A);
        (bool ok,) = address(auction).call{value: amount}(abi.encodeCall(auction.bid, (amount, 0, expected)));
        assert(ok == (expected == 0 || expected == 1));
    }
}

/// @notice Claims. setUp places three bids: A reserves ids 1..10, B 11..21, A 22..26 (cap 26 binds).
///         A's 15 credits are claimed in two symbolic parts to two recipients: every one of A's ids is
///         minted exactly once, to the right recipient, in order; B's ids and ids past the cap stay unminted.
contract MotifClaimHalmos is HalmosBase {
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    address internal constant R1 = address(0x1111);
    address internal constant R2 = address(0x2222);
    KilimMotifs internal motifs;
    KilimAuction internal auction;

    function setUp() public {
        (motifs,, auction) = deployTrio(26, 12, 1000, 1 days, 10 minutes);
        openBidding(auction);
        vm.deal(A, 1 ether);
        vm.deal(B, 1 ether);
        vm.prank(A);
        auction.bid{value: 10 * UNIT}(10 * UNIT, 10, 1); // ids 1..10
        vm.prank(B);
        auction.bid{value: 11 * UNIT}(11 * UNIT, 11, 11); // ids 11..21
        vm.prank(A);
        auction.bid{value: 13 * UNIT}(13 * UNIT, 5, 22); // ids 22..26: the cap leaves 5
        require(auction.motifCredits(A) == 15 && auction.motifCredits(B) == 11, "setup");
    }

    /// @dev A's k-th reserved id, k = 0..14.
    function _idOfA(uint256 k) internal pure returns (uint256) {
        return k < 10 ? 1 + k : 22 + (k - 10);
    }

    function _owner(uint256 id) internal view returns (bool exists, address owner) {
        (bool ok, bytes memory ret) = address(motifs).staticcall(abi.encodeCall(motifs.ownerOf, (id)));
        if (ok) owner = abi.decode(ret, (address));
        exists = ok;
    }

    /// @dev q1 is symbolic over 1..15, split into concrete paths (q1 == c): the auction allocates arrays of
    ///      length `quantity`, and Halmos cannot copy a symbolic number of bytes.
    function check_claim_twoParts(uint256 q, uint256 k, uint256 j) public {
        for (uint256 c = 1; c <= 15; ++c) {
            if (q == c) {
                _claimTwoParts(c, k, j);
                return;
            }
        }
        vm.assume(false); // q outside 1..15
    }

    function _claimTwoParts(uint256 q1, uint256 k, uint256 j) internal {
        vm.prank(A);
        (bool ok1,) = address(auction).call(abi.encodeCall(auction.claimMotifs, (q1, R1)));
        assert(ok1); // a claim within one's credits always succeeds: no id is ever minted twice

        // The cursor: what is left unclaimed is exactly the tail of A's ids.
        KilimAuction.CreditRange[] memory left = auction.unclaimedMotifRanges(A);
        if (q1 < 10) {
            assert(left.length == 2);
            assert(left[0].nextId == 1 + q1 && left[0].remaining == 10 - q1);
            assert(left[1].nextId == 22 && left[1].remaining == 5);
        } else if (q1 < 15) {
            assert(left.length == 1);
            assert(left[0].nextId == 22 + (q1 - 10) && left[0].remaining == 15 - q1);
        } else {
            assert(left.length == 0);
        }

        if (q1 < 15) {
            vm.prank(A);
            (bool ok2,) = address(auction).call(abi.encodeCall(auction.claimMotifs, (15 - q1, R2)));
            assert(ok2);
        }
        assert(auction.motifCredits(A) == 0);
        assert(auction.motifsClaimed() == 15);
        assert(motifs.motifsMinted() == 15);
        assert(auction.unclaimedMotifRanges(A).length == 0);
        assert(motifs.balanceOf(R1) == q1 && motifs.balanceOf(R2) == 15 - q1);

        // Any one of A's ids: minted, to R1 if it is among the first q1, else to R2.
        vm.assume(k < 15);
        (bool exists, address owner) = _owner(_idOfA(k));
        assert(exists);
        assert(owner == (k < q1 ? R1 : R2));

        // Any id that is not A's (B's 11..21, 0, or past the cap): not minted.
        vm.assume(j == 0 || (j >= 11 && j <= 21) || j > 26);
        (bool jExists,) = _owner(j);
        assert(!jExists);

        // Nothing left: a further claim reverts.
        vm.prank(A);
        (bool ok3,) = address(auction).call(abi.encodeCall(auction.claimMotifs, (1, R1)));
        assert(!ok3);
    }

    /// @dev More than one's credits, 0, or above the batch limit is refused, for every caller.
    function check_claim_quantityLimits(address caller, uint256 q) public {
        uint256 credits = auction.motifCredits(caller);
        vm.assume(q == 0 || q > credits || q > 64);
        vm.prank(caller);
        (bool ok,) = address(auction).call(abi.encodeCall(auction.claimMotifs, (q, R1)));
        assert(!ok);
    }
}
