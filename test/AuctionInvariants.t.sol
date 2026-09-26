// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase, InvariantBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

contract AuctionHandler is TestBase {
    MockUSD public usd;
    KilimAuction public auction;
    address[3] public actors = [ALICE, BOB, CAROL];
    uint256 public deposited;
    uint256 public refunded;
    uint256 public paidProceeds;
    uint256 public donated;
    uint256 public bidCalls;
    uint256 public refundCalls;
    uint256 public claimCalls;

    constructor(MockUSD usd_, KilimAuction auction_) {
        usd = usd_;
        auction = auction_;
        for (uint256 i; i < actors.length; ++i) {
            usd.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            usd.approve(address(auction), type(uint256).max);
        }
        vm.warp(auction.startsAt());
    }

    function placeBid(uint8 actorSeed, uint8 uplift) external {
        uint64 closesAt = auction.endsAt();
        if (auction.settled() || (closesAt != 0 && block.timestamp >= closesAt)) return;
        uint256 amount = auction.minimumBid() + uint256(uplift) % 50 * UNIT;
        vm.prank(actors[actorSeed % 3]);
        auction.bid(amount, 0, 0);
        deposited += amount;
        ++bidCalls;
    }

    function refund(uint8 actorSeed, uint8 destination) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = auction.refunds(actor);
        if (amount == 0) return;
        vm.prank(actor);
        auction.withdrawRefund(actors[destination % 3]);
        refunded += amount;
        ++refundCalls;
    }

    function claim(uint8 actorSeed, uint8 quantitySeed, uint8 destination) external {
        address actor = actors[actorSeed % 3];
        uint256 credits = auction.symbolCredits(actor);
        if (credits == 0) return;
        uint256 quantity = 1 + uint256(quantitySeed) % 64;
        if (quantity > credits) quantity = credits;
        vm.prank(actor);
        auction.claimSymbols(quantity, actors[destination % 3]);
        ++claimCalls;
    }

    function donate(uint32 amount) external {
        usd.mint(address(auction), amount);
        donated += amount;
    }

    function passTime(uint16 delta) external {
        vm.warp(block.timestamp + uint256(delta) % 3601);
    }

    /// @dev Settlement is impossible until a first bid starts the clock.
    function finish(uint8 seed) external {
        uint64 closesAt = auction.endsAt();
        if (auction.settled() || closesAt == 0) return;
        if (seed % 16 == 0 && block.timestamp < closesAt) vm.warp(closesAt);
        if (block.timestamp >= closesAt) auction.settle();
    }

    function proceeds(uint8 destination) external {
        uint256 amount = auction.proceedsDue();
        if (!auction.settled() || amount == 0) return;
        vm.prank(TREASURY);
        auction.withdrawProceeds(actors[destination % 3]);
        paidProceeds += amount;
    }

    function prize(uint8 destination) external {
        if (!auction.settled() || auction.prizeClaimed()) return;
        address winner = auction.highestBidder();
        vm.prank(winner == address(0) ? TREASURY : winner);
        auction.claimPrize(actors[destination % 3]);
    }
}

contract AuctionInvariants is InvariantBase {
    MockUSD internal usd;
    KilimAuction internal auction;
    AuctionHandler internal handler;
    address[] private targets;

    function setUp() public {
        usd = new MockUSD(6);
        // A small pool keeps the run bounded and exercises exhausted rewards, where bids
        // are still accepted but reserve no IDs.
        KilimAuction.Config memory c = config(address(usd));
        c.symbolCap = 600;
        c.maxSymbolsPerBid = 60;
        auction = new KilimAuction(c);
        handler = new AuctionHandler(usd, auction);
        targets.push(address(handler));
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    function invariantEscrowAlwaysCoversExactLiabilities() public view {
        uint256 sum = auction.refunds(ALICE) + auction.refunds(BOB) + auction.refunds(CAROL);
        assertEq(sum, auction.refundLiability());
        assertEq(
            auction.liabilities(), sum + (auction.settled() ? auction.proceedsDue() : auction.highestBid())
        );
        assertEq(usd.balanceOf(address(auction)), auction.liabilities() + handler.donated());
        assertEq(
            usd.balanceOf(address(auction)),
            handler.deposited() + handler.donated() - handler.refunded() - handler.paidProceeds()
        );
    }

    function invariantCreditsCannotBeCreatedTwiceOrOverCap() public view {
        uint256 sum = auction.symbolCredits(ALICE) + auction.symbolCredits(BOB) + auction.symbolCredits(CAROL);
        assertEq(sum + auction.symbolsClaimed(), auction.symbolsAllocated());
        assertEq(auction.collection().symbolsMinted(), auction.symbolsClaimed());
        assertTrue(auction.symbolsAllocated() <= auction.symbolCap());
    }

    /// Reserved ranges match credits exactly, sit inside the allocated block, never overlap,
    /// and contain only unminted IDs.
    function invariantReservedIdsMatchCreditsAndAreUnminted() public view {
        Kilim nft = auction.collection();
        address[3] memory actors = [ALICE, BOB, CAROL];
        uint256 first = nft.FIRST_SYMBOL_ID();
        uint256 end = first + auction.symbolsAllocated();
        KilimAuction.CreditRange[][3] memory all;
        for (uint256 a; a < 3; ++a) {
            all[a] = auction.unclaimedSymbolRanges(actors[a]);
            uint256 total;
            for (uint256 i; i < all[a].length; ++i) {
                KilimAuction.CreditRange memory r = all[a][i];
                assertTrue(r.remaining != 0);
                assertTrue(r.nextId >= first && r.nextId + r.remaining <= end);
                if (i != 0) assertTrue(all[a][i - 1].nextId + all[a][i - 1].remaining <= r.nextId);
                // Endpoints only: scanning every reserved ID is O(supply) per call.
                assertTrue(nft.kindOf(r.nextId) == Kilim.Kind.None);
                assertTrue(nft.kindOf(r.nextId + r.remaining - 1) == Kilim.Kind.None);
                total += r.remaining;
            }
            assertEq(total, auction.symbolCredits(actors[a]));
        }
        for (uint256 a; a < 3; ++a) {
            for (uint256 b = a + 1; b < 3; ++b) {
                for (uint256 i; i < all[a].length; ++i) {
                    for (uint256 j; j < all[b].length; ++j) {
                        KilimAuction.CreditRange memory x = all[a][i];
                        KilimAuction.CreditRange memory y = all[b][j];
                        assertTrue(x.nextId + x.remaining <= y.nextId || y.nextId + y.remaining <= x.nextId);
                    }
                }
            }
        }
    }

    function invariantClosingAndPrizeAreBounded() public view {
        // The clock exists only after a first bid, and settlement implies both.
        assertTrue(auction.endsAt() == 0 || auction.endsAt() > auction.startsAt());
        assertTrue(!auction.settled() || (auction.endsAt() != 0 && auction.highestBidder() != address(0)));
        assertTrue(!auction.prizeClaimed() || auction.settled());
        assertTrue(auction.collection().masterpieceMinted() == auction.prizeClaimed());
    }
}
