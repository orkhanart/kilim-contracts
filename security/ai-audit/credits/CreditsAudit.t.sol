// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TestBase} from "../../../test/TestBase.sol";
import {BazaarBase} from "../../../test/bazaar/BazaarBase.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";

// =====================================================================================================
// AI audit, lens "motif credits, motif minting and the 1/1 prize" (12 October 2026).
// Every test here is a check of a property the lens was asked about. None of them is a Medium+ exploit:
// the lens found none. CR-1 and CR-2 are Low/Info items whose behaviour these tests pin.
// =====================================================================================================

/// @dev A single-purpose bidding contract, the kind a sniping bot is: it can bid and take its refund, and
///      nothing else. No onERC721Received, no generic call, so it can call neither claimPrize nor claimMotifs.
contract BidOnlyBot {
    KilimAuction private immutable auction;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    receive() external payable {}
}

/// @dev A recipient that, on every motif it receives, tries every auction entry point that could move a
///      token or ETH, and records how each attempt failed.
contract HostileClaimRecipient is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256 public received;
    uint256 public reentrySucceeded;
    uint256 public guardRefusals;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function claim(uint256 q, address to) external {
        auction.claimMotifs(q, to);
    }

    function _try(bytes memory data) private {
        (bool ok, bytes memory ret) = address(auction).call(data);
        if (ok) ++reentrySucceeded;
        else if (ret.length >= 4 && bytes4(ret) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector) {
            ++guardRefusals;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++received;
        _try(abi.encodeCall(auction.claimMotifs, (1, address(this))));
        _try(abi.encodeCall(auction.claimPrize, (address(this))));
        _try(abi.encodeCall(auction.settle, ()));
        _try(abi.encodeCall(auction.withdrawRefund, (address(this))));
        _try(abi.encodeCall(auction.bid, (1 ether, 0, 0)));
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

contract CreditsAuditTest is TestBase {
    event log_named_uint(string key, uint256 value);

    address[3] private bidders = [ALICE, BOB, CAROL];

    function _auction(uint256 cap, uint256 perBid) private returns (KilimAuction auction) {
        KilimAuction.Config memory c = config(cap);
        c.maxMotifsPerBid = perBid;
        auction = new KilimAuction(c);
        _openBidding(auction);
    }

    // -------------------------------------------------------------------------------- cap and ranges

    /// @dev Any bid sequence, any cap and per-bid limit: every bid's reward is exactly
    ///      min(units, perBid, cap - allocated); the ranges of all bidders partition 1..allocated with no gap
    ///      and no overlap; credits equal the ranges; highestBidMotifs is always the last bid's range; and
    ///      claiming everything mints exactly the reserved ids to their reservers, and nothing more.
    function testFuzzCapBoundaryAndRangesPartitionTheIds(uint8 cap_, uint8 perBid_, uint8[14] memory extra)
        public
    {
        uint256 cap = 1 + uint256(cap_) % 60;
        uint256 perBid = 1 + uint256(perBid_) % cap;
        KilimAuction auction = _auction(cap, perBid);
        KilimMotifs motifs = auction.motifs();
        for (uint256 i; i < 3; ++i) {
            vm.deal(bidders[i], 1000 ether);
        }
        address[] memory reserver = new address[](cap + 1);
        uint256 allocated;
        for (uint256 i; i < extra.length; ++i) {
            address who = bidders[i % 3];
            uint256 amount = auction.minimumBid() + (uint256(extra[i]) % 40) * UNIT;
            uint256 units = amount / UNIT;
            uint256 expected = units < perBid ? units : perBid;
            if (expected > cap - allocated) expected = cap - allocated;
            assertEq(auction.rewardForBid(amount), expected);
            _bid(auction, who, amount);
            (uint256 first, uint256 count) = auction.highestBidMotifs();
            assertEq(count, expected);
            assertEq(first, expected == 0 ? 0 : allocated + 1);
            for (uint256 id = first; id < first + count; ++id) {
                reserver[id] = who;
            }
            allocated += expected;
            assertEq(auction.motifsAllocated(), allocated);
        }
        assertTrue(allocated <= cap);

        // The ranges partition 1..allocated.
        bool[] memory seen = new bool[](cap + 1);
        uint256 total;
        for (uint256 b; b < 3; ++b) {
            KilimAuction.CreditRange[] memory r = auction.unclaimedMotifRanges(bidders[b]);
            uint256 sum;
            for (uint256 k; k < r.length; ++k) {
                assertTrue(r[k].remaining != 0);
                for (uint256 id = r[k].nextId; id < r[k].nextId + r[k].remaining; ++id) {
                    assertTrue(id >= 1 && id <= allocated);
                    assertTrue(!seen[id]);
                    seen[id] = true;
                    assertEq(reserver[id], bidders[b]);
                }
                sum += r[k].remaining;
            }
            assertEq(sum, auction.motifCredits(bidders[b]));
            total += sum;
        }
        assertEq(total, allocated);

        // Claim everything; each id goes to its reserver; then nothing is left to claim.
        for (uint256 b; b < 3; ++b) {
            address who = bidders[b];
            while (auction.motifCredits(who) != 0) {
                uint256 left = auction.motifCredits(who);
                uint256 q = left < 64 ? left : 64;
                vm.prank(who);
                auction.claimMotifs(q, who);
            }
            vm.expectRevert(KilimAuction.InvalidQuantity.selector);
            vm.prank(who);
            auction.claimMotifs(1, who);
        }
        for (uint256 id = 1; id <= allocated; ++id) {
            assertEq(motifs.ownerOf(id), reserver[id]);
        }
        assertEq(motifs.motifsMinted(), allocated);
        assertEq(auction.motifsClaimed(), allocated);
        // The id past the cap can never be minted, by anyone.
        vm.prank(address(auction));
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        motifs.mintMotifs(ALICE, ALICE, cap + 1, 1);
    }

    /// @dev The exact edge: the last id is motifCap, the bid that fills the pool gets the remainder, the next
    ///      bid reserves nothing, and both slippage guards refuse it when asked to.
    function testExactCapEdge() public {
        KilimAuction auction = _auction(25, 25);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        _bid(auction, ALICE, 0.01 ether); // ids 1..10
        _bid(auction, BOB, auction.minimumBid()); // 0.011: ids 11..21
        uint256 next = auction.minimumBid(); // 0.012: 12 units, 4 left
        assertEq(auction.rewardForBid(next), 4);
        vm.prank(ALICE);
        auction.bid{value: next}(next, 4, 22);
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        assertEq(first, 22);
        assertEq(count, 4);
        assertEq(auction.motifsAllocated(), 25);

        uint256 after_ = auction.minimumBid();
        assertEq(auction.rewardForBid(after_), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(KilimAuction.MotifRangeMoved.selector, 0));
        auction.bid{value: after_}(after_, 0, 26);
        vm.prank(BOB);
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        auction.bid{value: after_}(after_, 1, 0);
        _bid(auction, BOB, after_);
        (first, count) = auction.highestBidMotifs();
        assertEq(first, 0);
        assertEq(count, 0);
        assertEq(auction.motifCredits(BOB), 11);

        vm.prank(ALICE);
        auction.claimMotifs(14, ALICE);
        assertEq(auction.motifs().ownerOf(25), ALICE);
        assertEq(auction.motifs().ownerOf(10), ALICE);
    }

    // -------------------------------------------------------------------------------- claims

    /// @dev A recipient that tries every auction entry point from each motif's receiver callback, across a
    ///      claim that spans three bid ranges: every attempt meets the guard, the claim completes, and
    ///      credits drop by exactly the quantity.
    function testClaimCallbacksCannotReenterAnyAuctionEntryPoint() public {
        KilimAuction auction = _auction(10_000, 1000);
        HostileClaimRecipient r = new HostileClaimRecipient(auction);
        vm.deal(address(r), 10 ether);
        vm.deal(BOB, 10 ether);
        r.bid(0.01 ether); // 10
        _bid(auction, BOB, auction.minimumBid());
        r.bid(auction.minimumBid()); // 12
        _bid(auction, BOB, auction.minimumBid());
        r.bid(auction.minimumBid()); // 14
        uint256 credits = auction.motifCredits(address(r));
        assertEq(credits, 10 + 12 + 14);
        r.claim(30, address(r));
        assertEq(r.received(), 30);
        assertEq(r.reentrySucceeded(), 0);
        assertEq(r.guardRefusals(), 30 * 5);
        assertEq(auction.motifCredits(address(r)), credits - 30);
        assertEq(auction.motifsClaimed(), 30);
        // Nobody else can claim r's remaining credits: BOB's own credits are what limits BOB.
        uint256 bobCredits = auction.motifCredits(BOB);
        vm.prank(BOB);
        vm.expectRevert(KilimAuction.InvalidQuantity.selector);
        auction.claimMotifs(bobCredits + 1, BOB);
    }

    /// @dev Worst case for one claim: 64 ranges of one id each, so 64 external mints. On mainnet a range
    ///      holds at least 10 ids (every bid is at least 10 units) except the one the cap cuts, so a 64-claim
    ///      touches at most 7 ranges; this bounds the call count from above.
    function testWorstCaseClaimGas() public {
        KilimAuction auction = _auction(10_000, 1);
        vm.deal(ALICE, 100 ether);
        for (uint256 i; i < 64; ++i) {
            _bid(auction, ALICE, auction.minimumBid());
        }
        assertEq(auction.unclaimedMotifRanges(ALICE).length, 64);
        uint256 g = gasleft();
        vm.prank(ALICE);
        auction.claimMotifs(64, ALICE);
        g -= gasleft();
        emit log_named_uint("64-id claim over 64 ranges, gas", g);
        assertTrue(g < 5_000_000);
        assertEq(auction.unclaimedMotifRanges(ALICE).length, 0);
    }

    /// @dev CR-2 (Info). Claims run oldest bid first, and there is no way to claim a chosen range: a winner
    ///      must mint every older range before reaching the winning bid's own ids (highestBidMotifs), the
    ///      ids the Bazaar's "made from the winning bid" tag needs.
    function testWinnerReachesTheWinningRangeOnlyAfterEveryOlderRange() public {
        KilimAuction auction = _auction(10_000, 1000);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        _bid(auction, ALICE, 0.01 ether); // ids 1..10
        _bid(auction, BOB, auction.minimumBid()); // 11..21
        _bid(auction, ALICE, 0.2 ether); // 22..221, the winning bid
        vm.warp(auction.endsAt());
        auction.settle();
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        assertEq(first, 22);
        assertEq(count, 200);
        KilimAuction.CreditRange[] memory r = auction.unclaimedMotifRanges(ALICE);
        assertEq(r.length, 2);
        assertEq(r[1].nextId, first);
        // Asking for 10 mints the oldest ten, not ten of the winning bid's.
        KilimMotifs motifs = auction.motifs();
        vm.prank(ALICE);
        auction.claimMotifs(10, ALICE);
        assertEq(motifs.ownerOf(1), ALICE);
        assertEq(motifs.balanceOf(ALICE), 10);
        vm.expectRevert();
        motifs.ownerOf(first);
    }

    // -------------------------------------------------------------------------------- the 1/1

    /// @dev CR-1 (Low, documented class). A winner that can bid but cannot call claimPrize, and whose address
    ///      cannot take an ERC-721 by _safeMint, leaves the 1/1 unminted for good: settlement records it,
    ///      nobody else may claim, there is no rescue function, and the 1/1's tokenURI never exists. Its motif
    ///      credits are stranded the same way. The proceeds are unaffected.
    function testBidOnlyContractWinnerLeavesThePrizeUnmintedForever() public {
        KilimAuction auction = _auction(10_000, 1000);
        KilimOneOfOne oneOfOne = auction.oneOfOne();
        BidOnlyBot bot = new BidOnlyBot(auction);
        vm.deal(address(this), 10 ether);
        vm.deal(ALICE, 10 ether);
        _bid(auction, ALICE, 0.01 ether);
        bot.bid{value: 0.05 ether}(0.05 ether);
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(address(bot));
        auction.settle();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        assertTrue(!oneOfOne.minted());

        // Nobody but the winner may claim it; the winner has no way to call. No other entry point mints.
        address[3] memory others = [ALICE, TREASURY, address(this)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(EnglishAuction.Unauthorized.selector);
            auction.claimPrize(others[i]);
        }
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        auction.deliverPrize();
        vm.expectRevert(EnglishAuction.AlreadySettled.selector);
        auction.settle();
        vm.expectRevert(KilimOneOfOne.Unauthorized.selector);
        oneOfOne.mint(ALICE);
        vm.expectRevert();
        oneOfOne.tokenURI(1);

        // The treasury is paid regardless; the bot's 50 credits are stranded.
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 0.05 ether);
        assertEq(auction.motifCredits(address(bot)), 50);
        assertEq(auction.motifsAllocated() - auction.motifsClaimed(), 60);
    }

    /// @dev The prize goes to highestBidder whoever settles and whenever, and exactly once across both paths.
    function testFuzzPrizeGoesOnlyToTheWinnerOnce(address settler, address to) public {
        KilimAuction auction = _auction(10_000, 1000);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        _bid(auction, ALICE, 0.01 ether);
        _bid(auction, BOB, auction.minimumBid());
        vm.warp(auction.endsAt() + 1 days);
        vm.prank(settler);
        auction.settle();
        assertEq(auction.oneOfOne().ownerOf(1), BOB);
        assertTrue(auction.prizeClaimed());
        vm.prank(BOB);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        auction.claimPrize(to);
        vm.prank(ALICE);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        auction.claimPrize(to);
    }
}

/// @dev Holds the winning bid, approves the Bazaar, and from the receiver callback of its own motif claim
///      (after settlement) burns the ten ids already minted into a kilim, while the claim is still minting
///      the rest of its range.
contract ClaimWeaver is IERC721Receiver {
    KilimAuction private immutable auction;
    KilimBazaar private bazaar;
    uint256 public motifsReceived;
    uint256 public kilimMade;
    bool private weaving;

    constructor(KilimAuction a) {
        auction = a;
    }

    function setBazaar(KilimBazaar b) external {
        bazaar = b;
        auction.motifs().setApprovalForAll(address(b), true);
    }

    function bid(uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function claim(uint256 q) external {
        auction.claimMotifs(q, address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(auction.motifs())) {
            ++motifsReceived;
            if (motifsReceived == 10 && !weaving) {
                weaving = true;
                uint256[] memory list = new uint256[](10);
                for (uint256 i; i < 10; ++i) {
                    list[i] = i + 1;
                }
                kilimMade = bazaar.make(list, address(this));
                weaving = false;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

contract CreditsBazaarCrossTest is BazaarBase {
    /// @dev Cross-contract re-entry: the Bazaar is entered from inside the auction's claim (the auction's
    ///      guard is held, the Bazaar's is not). It burns ids 1..10 while mintMotifs is still minting 11..20.
    ///      Everything stays consistent: the claim finishes, the burned ids stay taken, the kilim carries the
    ///      winning-bid tag (all its ids are in highestBidMotifs' range), and no credit is lost or created.
    function testBazaarEnteredFromAClaimCallbackStaysConsistent() public {
        _standard();
        _openBidding(auction);
        ClaimWeaver w = new ClaimWeaver(auction);
        vm.deal(address(w), 1 ether);
        w.bid(0.02 ether); // ids 1..20, the winning bid
        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(oneOfOne.ownerOf(1), address(w));
        w.setBazaar(bazaar);
        w.claim(20);
        assertEq(w.motifsReceived(), 20);
        assertEq(w.kilimMade(), 1);
        assertEq(motifs.motifsMinted(), 20);
        assertEq(motifs.motifsBurned(), 10);
        assertEq(motifs.balanceOf(address(w)), 10);
        for (uint256 id = 1; id <= 10; ++id) {
            assertTrue(motifs.burned(id));
        }
        for (uint256 id = 11; id <= 20; ++id) {
            assertEq(motifs.ownerOf(id), address(w));
        }
        assertEq(auction.motifCredits(address(w)), 0);
        assertEq(auction.motifsClaimed(), 20);
        KilimBazaar.Kilim memory k = bazaar.kilim(1);
        assertTrue(k.flags & bazaar.WINNING_BID() != 0);
        assertEq(bazaar.ownerOf(1), address(w));
        // A burned id can never come back through the auction either.
        vm.prank(address(auction));
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        motifs.mintMotifs(address(w), address(w), 1, 1);
    }
}
