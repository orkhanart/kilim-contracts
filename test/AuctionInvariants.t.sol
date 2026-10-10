// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {TestBase, InvariantBase} from "./TestBase.sol";

/// @dev A bidder wallet whose ETH receiver can accept, reject, or burn all the gas it is given,
///      and which can refuse NFTs. Rejecting and burning both turn an automatic refund into a
///      pull refund; refusing NFTs leaves the 1/1 to claimPrize.
contract MoodyWallet is IERC721Receiver {
    uint8 public constant ACCEPT = 0;
    uint8 public constant REJECT = 1;
    uint8 public constant BURN = 2;
    uint8 public mood;
    bool public refusesNfts;

    function set(uint8 mood_, bool refusesNfts_) external {
        mood = mood_;
        refusesNfts = refusesNfts_;
    }

    receive() external payable {
        if (mood == REJECT) revert("no ETH");
        if (mood == BURN) while (gasleft() > 0) {}
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(!refusesNfts, "NFT rejected");
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AuctionHandler is TestBase {
    uint256 public constant FUNDS = 1e30;
    KilimAuction public auction;
    address[3] public actors;
    uint256 public deposited;
    uint256 public refunded;
    uint256 public paidProceeds;
    uint256 public donated;
    uint256 public bidCalls;
    uint256 public deferredRefunds;
    uint256 public refundCalls;
    uint256 public claimCalls;
    uint256 public prizeCalls;

    constructor(KilimAuction auction_) {
        auction = auction_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(new MoodyWallet());
            vm.deal(actors[i], FUNDS);
        }
        _openBidding(auction);
    }

    function _takesEth(address to) private view returns (bool) {
        return MoodyWallet(payable(to)).mood() == 0;
    }

    function _takesNfts(address to) private view returns (bool) {
        return !MoodyWallet(payable(to)).refusesNfts();
    }

    function placeBid(uint8 actorSeed, uint8 uplift) external {
        uint64 closesAt = auction.endsAt();
        if (auction.settled() || (closesAt != 0 && block.timestamp >= closesAt)) return;
        uint256 amount = auction.minimumBid() + uint256(uplift) % 50 * UNIT;
        address bidder = actors[actorSeed % 3];
        address leader = auction.highestBidder();
        uint256 outbid = auction.highestBid();
        uint256 owedBefore = auction.refunds(leader);
        uint256 heldBefore = leader.balance;
        vm.prank(bidder);
        auction.bid{value: amount}(amount, 0, 0);
        deposited += amount;
        // The outbid amount either arrived in the old leader's wallet or waits as a pull refund.
        uint256 deferred = auction.refunds(leader) - owedBefore;
        uint256 pushed = leader.balance + (leader == bidder ? amount : 0) - heldBefore;
        assertEq(pushed + deferred, outbid);
        assertTrue(pushed == 0 || deferred == 0);
        refunded += pushed;
        if (deferred != 0) ++deferredRefunds;
        ++bidCalls;
    }

    function refund(uint8 actorSeed, uint8 destination) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = auction.refunds(actor);
        address to = actors[destination % 3];
        if (amount == 0 || !_takesEth(to)) return;
        uint256 heldBefore = to.balance;
        vm.prank(actor);
        auction.withdrawRefund(to);
        assertEq(to.balance - heldBefore, amount);
        refunded += amount;
        ++refundCalls;
    }

    function claim(uint8 actorSeed, uint8 quantitySeed, uint8 destination) external {
        address actor = actors[actorSeed % 3];
        uint256 credits = auction.motifCredits(actor);
        address to = actors[destination % 3];
        if (credits == 0 || !_takesNfts(to)) return;
        uint256 quantity = 1 + uint256(quantitySeed) % 64;
        if (quantity > credits) quantity = credits;
        vm.prank(actor);
        auction.claimMotifs(quantity, to);
        ++claimCalls;
    }

    /// @dev Wallets that stop and start taking ETH or NFTs: automatic refunds to one that rejects
    ///      ETH or burns the gas defer to pull refunds, and a winner that refuses NFTs must claim.
    function changeMood(uint8 actorSeed, uint8 moodSeed, bool refusesNfts) external {
        MoodyWallet(payable(actors[actorSeed % 3])).set(moodSeed % 3, refusesNfts);
    }

    /// @dev ETH forced into the auction, as a selfdestruct or a block reward would send it.
    function donate(uint32 amount) external {
        vm.deal(address(auction), address(auction).balance + amount);
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
        address to = actors[destination % 3];
        if (!auction.settled() || amount == 0 || !_takesEth(to)) return;
        uint256 heldBefore = to.balance;
        vm.prank(TREASURY);
        auction.withdrawProceeds(to);
        assertEq(to.balance - heldBefore, amount);
        paidProceeds += amount;
    }

    /// @dev Only reachable when settlement could not send the 1/1 to the winner.
    function prize(uint8 destination) external {
        address to = actors[destination % 3];
        if (!auction.settled() || auction.prizeClaimed() || !_takesNfts(to)) return;
        vm.prank(auction.highestBidder());
        auction.claimPrize(to);
        ++prizeCalls;
    }

    /// @dev Anyone may send the 1/1 to the winner again once the winner's wallet takes NFTs.
    function sendPrizeAgain(uint8 callerSeed) external {
        address winner = auction.highestBidder();
        if (!auction.settled() || auction.prizeClaimed() || !_takesNfts(winner)) return;
        vm.prank(actors[callerSeed % 3]);
        auction.deliverPrizeToWinner();
        assertEq(auction.oneOfOne().ownerOf(1), winner);
        ++prizeCalls;
    }
}

contract AuctionInvariants is InvariantBase {
    KilimAuction internal auction;
    AuctionHandler internal handler;
    address[] private targets;

    function setUp() public {
        // A small pool keeps the run bounded and exercises exhausted rewards, where bids
        // are still accepted but reserve no IDs.
        KilimAuction.Config memory c = config(600);
        c.maxMotifsPerBid = 60;
        auction = new KilimAuction(c);
        handler = new AuctionHandler(auction);
        targets.push(address(handler));
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    function invariantEscrowAlwaysCoversExactLiabilities() public view {
        uint256 sum;
        uint256 held;
        for (uint256 i; i < 3; ++i) {
            sum += auction.refunds(handler.actors(i));
            held += handler.actors(i).balance;
        }
        assertEq(sum, auction.refundLiability());
        assertEq(
            auction.liabilities(), sum + (auction.settled() ? auction.proceedsDue() : auction.highestBid())
        );
        assertTrue(address(auction).balance >= auction.liabilities());
        assertEq(address(auction).balance, auction.liabilities() + handler.donated());
        assertEq(
            address(auction).balance,
            handler.deposited() + handler.donated() - handler.refunded() - handler.paidProceeds()
        );
        // Every wei bid was paid back out, as a refund or as proceeds, or is still owed.
        assertEq(handler.deposited(), handler.refunded() + handler.paidProceeds() + auction.liabilities());
        // And it went to the three wallets, nowhere else.
        assertEq(
            held, 3 * handler.FUNDS() - handler.deposited() + handler.refunded() + handler.paidProceeds()
        );
    }

    function invariantCreditsCannotBeCreatedTwiceOrOverCap() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += auction.motifCredits(handler.actors(i));
        }
        assertEq(sum + auction.motifsClaimed(), auction.motifsAllocated());
        assertEq(auction.motifs().motifsMinted(), auction.motifsClaimed());
        assertTrue(auction.motifsAllocated() <= auction.motifCap());
    }

    /// Reserved ranges match credits exactly, sit inside the allocated block, never overlap,
    /// and contain only unminted IDs.
    function invariantReservedIdsMatchCreditsAndAreUnminted() public view {
        KilimMotifs nft = auction.motifs();
        uint256 first = 1;
        uint256 end = first + auction.motifsAllocated();
        KilimAuction.CreditRange[][3] memory all;
        for (uint256 a; a < 3; ++a) {
            all[a] = auction.unclaimedMotifRanges(handler.actors(a));
            uint256 total;
            for (uint256 i; i < all[a].length; ++i) {
                KilimAuction.CreditRange memory r = all[a][i];
                assertTrue(r.remaining != 0);
                assertTrue(r.nextId >= first && r.nextId + r.remaining <= end);
                if (i != 0) assertTrue(all[a][i - 1].nextId + all[a][i - 1].remaining <= r.nextId);
                // Endpoints only: scanning every reserved ID is O(supply) per call.
                assertTrue(_unminted(nft, r.nextId));
                assertTrue(_unminted(nft, r.nextId + r.remaining - 1));
                total += r.remaining;
            }
            assertEq(total, auction.motifCredits(handler.actors(a)));
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
        assertTrue(auction.oneOfOne().minted() == auction.prizeClaimed());
    }

    /// @dev An id that was never minted: no owner now and never burned.
    function _unminted(KilimMotifs nft, uint256 id) private view returns (bool) {
        if (nft.burned(id)) return false;
        try nft.ownerOf(id) returns (address) {
            return false;
        } catch {
            return true;
        }
    }

    function _checkAll() private view {
        invariantEscrowAlwaysCoversExactLiabilities();
        invariantCreditsCannotBeCreatedTwiceOrOverCap();
        invariantReservedIdsMatchCreditsAndAreUnminted();
        invariantClosingAndPrizeAreBounded();
    }

    /// The handler reaches the two fallback paths the random runs rely on: a deferred refund that
    /// is later pulled, and a 1/1 the winner must claim.
    function testHandlerReachesDeferredRefundAndPrizeFallback() public {
        address first = handler.actors(0);
        handler.placeBid(0, 0);
        _checkAll();
        // The leader stops taking ETH and NFTs, is outbid, then burns gas instead and is outbid again.
        handler.changeMood(0, 1, true);
        handler.placeBid(1, 3);
        assertEq(auction.refunds(first), RESERVE);
        assertEq(handler.deferredRefunds(), 1);
        _checkAll();
        handler.placeBid(0, 0);
        handler.changeMood(0, 2, true);
        handler.placeBid(2, 0);
        assertEq(handler.deferredRefunds(), 2);
        handler.placeBid(0, 0);
        handler.donate(12345);
        _checkAll();
        handler.finish(0);
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        _checkAll();
        handler.prize(0);
        assertTrue(!auction.prizeClaimed());
        handler.prize(1);
        assertEq(auction.oneOfOne().ownerOf(1), handler.actors(1));
        handler.refund(0, 0);
        assertEq(handler.refundCalls(), 0);
        handler.refund(0, 2);
        assertEq(handler.refundCalls(), 1);
        assertEq(auction.refundLiability(), 0);
        handler.proceeds(1);
        handler.claim(1, 255, 2);
        _checkAll();
        assertEq(auction.liabilities(), 0);
        assertEq(address(auction).balance, handler.donated());
    }
}
