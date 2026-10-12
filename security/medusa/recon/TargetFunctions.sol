// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTargetFunctions} from "../lib/chimera/src/BaseTargetFunctions.sol";
import {vm} from "../lib/chimera/src/Hevm.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";
import {MoodyWallet} from "./Mocks.sol";
import {Properties} from "./Properties.sol";

/// @notice The fuzzer's entry points. Every call the system sees goes through here, as one of the actors
///         (vm.prank), with inputs clamped to mostly-valid values and a share of deliberately invalid ones.
///         Each handler predicts whether the call must succeed, must fail, or may go either way (gas-capped
///         calls, re-entering wallets), checks that prediction, and on success checks the exact effects.
///         Reverts of the handler itself are not failures: only t()/eq() assertions and the properties are.
abstract contract TargetFunctions is BaseTargetFunctions, Properties {
    uint256 internal constant SURE_GAS = 1_200_000; // a bid or settle with at least this much must not run short

    // ================================================================ registration

    function auction_register(uint8 who) public {
        address a = _actor(who);
        bool expectOk = block.timestamp >= startsAt && auction.registrationCount() < 100 && !auction.registered(a)
            && a.balance >= RESERVE;
        uint256 before = auction.registrationCount();
        vm.prank(a);
        bool ok;
        try auction.register() {
            ok = true;
        } catch {}
        t(ok == expectOk, "register: outcome differs from the rules");
        if (ok) {
            t(auction.registered(a) && auction.registrationCount() == before + 1, "register: not recorded");
        }
    }

    /// @dev Throwaway wallets, each funded with exactly the registration balance, fill up to `n` slots.
    function auction_registerMany(uint8 n) public {
        if (block.timestamp < startsAt) return;
        uint256 count = auction.registrationCount();
        uint256 room = 100 - count;
        uint256 k = n == 0 ? room : (uint256(n) % 100) + 1;
        if (k > room) k = room;
        for (uint256 i; i < k; ++i) {
            address w = address(REGISTRANT_BASE + uint160(ghostRegistrants));
            vm.deal(w, RESERVE);
            vm.prank(w);
            auction.register();
            ++ghostRegistrants;
        }
        eq(auction.registrationCount(), count + k, "registerMany: count");
    }

    /// @dev Registration by signature, relayed by the harness. mode: 0 valid, 1 expired, 2 wrong key,
    ///      3 signed for another deadline. Wallets (actors 2, 3) answer ERC-1271 by their `signs` flag.
    function auction_registerFor(uint8 who, uint8 mode, uint32 ahead) public {
        address a = _actor(who);
        uint256 m = mode % 4;
        uint256 deadline;
        if (m == 1) deadline = block.timestamp > 1001 ? block.timestamp - 1 - (ahead % 1000) : 0;
        else deadline = block.timestamp + (ahead % 7 days);
        bytes memory sig;
        bool sigValid;
        if (a == actors[0] || a == actors[1]) {
            uint256 pk = a == actors[0] ? PK_ALICE : PK_BOB;
            if (m == 2) pk = PK_TREASURY;
            uint256 signedDeadline = m == 3 ? deadline + 1 : deadline;
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, auction.registrationDigest(a, signedDeadline));
            sig = abi.encodePacked(r, s, v);
            sigValid = m == 0 || m == 1;
        } else {
            sig = hex"00";
            sigValid = MoodyWallet(payable(a)).signs();
        }
        bool expectOk = block.timestamp <= deadline && sigValid && block.timestamp >= startsAt
            && auction.registrationCount() < 100 && !auction.registered(a) && a.balance >= RESERVE;
        uint256 before = auction.registrationCount();
        bool ok;
        try auction.registerFor(a, deadline, sig) {
            ok = true;
        } catch {}
        t(ok == expectOk, "registerFor: outcome differs from the rules");
        if (ok) eq(auction.registrationCount(), before + 1, "registerFor: count");
    }

    function auction_registerTreasury() public {
        vm.prank(treasury);
        try auction.register() {
            t(false, "treasury registered");
        } catch {}
    }

    /// @dev Makes a wallet too poor to register, or rich again.
    function actor_setBalance(uint8 who, bool poor) public {
        vm.deal(_actor(who), poor ? RESERVE - 1 : FUNDS);
    }

    function wallet_setMood(uint8 which, uint8 ethMood, uint8 nftMood, bool signs) public {
        MoodyWallet(payable(actors[2 + (which % 2)])).set(ethMood, nftMood, signs);
    }

    // ================================================================ bidding

    struct BidCtx {
        address bidder;
        address leader;
        uint256 prevBid;
        uint256 minBid;
        uint256 prevEndsAt;
        uint256 allocBefore;
        uint256 leaderOwed;
        uint256 balBefore;
        uint256 leaderBalBefore;
        uint256 amount;
        uint256 value;
        uint256 reward;
        uint256 minReward;
        uint256 expectedFirst;
        uint256 gasCap;
        bool expectOk;
        bool leaderSure;
    }

    /// @dev kind: 0 valid, 1 one unit under the minimum, 2 not a whole unit, 3 wrong msg.value, 4 reward
    ///      slippage, 5 wrong expected motif id, 6 correct expected id, 7 the treasury bids.
    ///      A quarter of the bids carry a gas limit between 100,000 and 1,600,000.
    function auction_bid(uint8 who, uint32 uplift, uint8 kind, uint32 gasSeed) public {
        BidCtx memory c;
        uint256 k = kind % 8;
        c.bidder = k == 7 ? treasury : _actor(who);
        if (c.bidder.balance < FUNDS / 2) vm.deal(c.bidder, FUNDS);
        c.leader = auction.highestBidder();
        c.prevBid = auction.highestBid();
        c.minBid = auction.minimumBid();
        c.prevEndsAt = auction.endsAt();
        c.allocBefore = auction.motifsAllocated();
        c.leaderOwed = auction.refunds(c.leader);
        c.balBefore = address(auction).balance;
        c.leaderBalBefore = c.leader.balance;
        c.leaderSure = _takesEthSurely(c.leader);

        // Mostly modest raises; one in eight is large enough to hit the per-bid clamp and drain the pool.
        uint256 raise = uplift % 8 == 0 ? uint256(uplift) % 4000 : uint256(uplift) % 64;
        c.amount = c.minBid + raise * UNIT;
        if (k == 1) c.amount = c.minBid - UNIT;
        if (k == 2) c.amount = c.minBid + 1 + uint256(uplift) % (UNIT - 1);
        c.value = c.amount;
        if (k == 3) c.value = uplift % 2 == 0 ? c.amount - 1 : c.amount + 1;
        c.reward = _min(_min(c.amount / UNIT, MAX_PER_BID), MOTIF_CAP - c.allocBefore);
        eq(auction.rewardForBid(c.amount), c.reward, "rewardForBid differs from min(units, per-bid, left)");
        if (k == 4) c.minReward = c.reward + 1;
        uint256 firstId = c.reward == 0 ? 0 : c.allocBefore + 1;
        if (k == 5) c.expectedFirst = firstId + 1;
        if (k == 6) c.expectedFirst = firstId;
        c.gasCap = gasSeed % 4 == 0 ? 100_000 + uint256(gasSeed) % 1_500_000 : 0;

        bool open = auction.registrationCount() == 100 && (c.leader == address(0) || block.timestamp < c.prevEndsAt);
        c.expectOk = open && c.bidder != treasury && c.amount >= c.minBid && c.amount % UNIT == 0
            && c.value == c.amount && c.reward >= c.minReward && (c.expectedFirst == 0 || c.expectedFirst == firstId);

        bool ok = _sendBid(c);

        if (!ok) {
            // A valid bid may fail only for lack of gas, and only below SURE_GAS.
            t(!c.expectOk || (c.gasCap != 0 && c.gasCap < SURE_GAS), "bid: valid bid rejected");
            return;
        }
        t(c.expectOk, "bid: invalid bid accepted");
        _checkBid(c, firstId);
    }

    function _sendBid(BidCtx memory c) private returns (bool ok) {
        vm.prank(c.bidder);
        if (c.gasCap == 0) {
            try auction.bid{value: c.value}(c.amount, c.minReward, c.expectedFirst) {
                ok = true;
            } catch {}
        } else {
            try auction.bid{value: c.value, gas: c.gasCap}(c.amount, c.minReward, c.expectedFirst) {
                ok = true;
            } catch {}
        }
    }

    function _checkBid(BidCtx memory c, uint256 firstId) private {
        ++hitBid;
        // The bid itself.
        t(auction.highestBid() == c.amount && auction.highestBidder() == c.bidder, "bid: not the new highest");
        t(c.amount > c.prevBid && c.amount >= c.minBid && c.amount >= RESERVE, "bid: not strictly higher / min");
        // The clock: the first bid starts the full duration, later ones only push the close out to
        // now + window, and only forwards.
        uint256 ends = auction.endsAt();
        if (c.leader == address(0)) {
            eq(ends, block.timestamp + DURATION, "bid: first bid did not start the full duration");
        } else {
            uint256 pushed = block.timestamp + EXTENSION;
            eq(ends, pushed > c.prevEndsAt ? pushed : c.prevEndsAt, "bid: close moved other than documented");
            t(block.timestamp < c.prevEndsAt, "bid: accepted at or after the close");
        }
        ghostLastEndsAt = ends;
        ghostLastBid = c.amount;
        // Credits: exactly the reward, as the next ids, reported as the highest bid's motifs.
        eq(auction.motifsAllocated(), c.allocBefore + c.reward, "bid: allocation");
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        t(first == firstId && count == c.reward, "bid: highestBidMotifs differ from the bid's reward");
        if (c.reward != 0) ghostRanges[c.bidder].push([firstId, c.reward]);
        ghostCreditsOf[c.bidder] += c.reward;
        ghostAllocated += c.reward;
        ghostLastBidFirstMotif = firstId;
        ghostLastBidMotifCount = c.reward;
        // The outbid amount: paid back in full or parked in full, never split, never lost.
        uint256 deferred = auction.refunds(c.leader) - c.leaderOwed;
        uint256 balAfter = address(auction).balance;
        uint256 pushedBack = c.balBefore + c.value - balAfter;
        eq(pushedBack + deferred, c.prevBid, "bid: outbid amount not conserved");
        t(pushedBack == 0 || deferred == 0, "bid: refund split");
        if (c.leader != address(0) && c.leaderSure) {
            eq(deferred, 0, "bid: refund to a wallet that takes ETH was deferred");
        }
        if (c.leader != address(0) && c.leader != c.bidder && c.leader != address(this)) {
            eq(c.leader.balance, c.leaderBalBefore + pushedBack, "bid: leader balance");
        }
        if (deferred != 0) ++hitDeferredRefund;
        ghostBidTotal += c.value;
        ghostOutbidTotal += c.prevBid;
        ghostPushedTotal += pushedBack;
        ghostDeferredTotal += deferred;
        ghostDeferredOf[c.leader] += deferred;
        ++ghostAcceptedBids;
    }

    // ================================================================ refunds, settlement, proceeds

    function auction_withdrawRefund(uint8 who, uint8 toSel) public {
        address a = _actor(who);
        address to = _recipient(toSel);
        uint256 owed = auction.refunds(a);
        uint256 liability = auction.refundLiability();
        uint256 balBefore = address(auction).balance;
        uint256 toBefore = to.balance;
        bool validTo = to != address(0) && to != address(auction) && to != address(motifs) && to != address(oneOfOne);
        bool expectOk = owed != 0 && validTo && _takesEthSurely(to);
        bool expectFail = owed == 0 || !validTo || _takesEthNever(to);
        vm.prank(a);
        bool ok;
        try auction.withdrawRefund{gas: 3_000_000}(to) {
            ok = true;
        } catch {}
        if (expectOk) t(ok, "withdrawRefund: owed refund not paid");
        if (expectFail) t(!ok, "withdrawRefund: paid when it must not");
        if (!ok) {
            eq(auction.refunds(a), owed, "withdrawRefund: failed call changed the debt");
            return;
        }
        ++hitWithdrawRefund;
        eq(balBefore - address(auction).balance, owed, "withdrawRefund: paid other than owed");
        eq(auction.refunds(a), 0, "withdrawRefund: debt not cleared");
        eq(auction.refundLiability(), liability - owed, "withdrawRefund: liability");
        if (to != address(this)) eq(to.balance, toBefore + owed, "withdrawRefund: recipient balance");
        ghostWithdrawnTotal += owed;
        ghostWithdrawnOf[a] += owed;
        t(ghostWithdrawnOf[a] <= ghostDeferredOf[a], "withdrawRefund: more than was ever deferred");
    }

    function time_warp(uint32 secs) public {
        vm.warp(block.timestamp + uint256(secs) % 2 days);
    }

    function time_warpToStart() public {
        if (block.timestamp < startsAt) vm.warp(startsAt);
    }

    /// @dev mode 0: one second before the close, 1: exactly the close, 2: past it.
    function time_warpToClose(uint8 mode, uint16 past) public {
        uint256 ends = auction.endsAt();
        if (ends == 0) return;
        uint256 target = mode % 3 == 0 ? ends - 1 : (mode % 3 == 1 ? ends : ends + 1 + past);
        if (target > block.timestamp) vm.warp(target);
    }

    function auction_settle(uint8 who, uint32 gasSeed) public {
        address caller = who % 5 == 4 ? address(this) : _actor(who);
        bool wasSettled = auction.settled();
        address winner = auction.highestBidder();
        uint256 top = auction.highestBid();
        uint256 ends = auction.endsAt();
        bool expectOk = !wasSettled && winner != address(0) && block.timestamp >= ends;
        uint256 cap = gasSeed % 3 == 0 ? 50_000 + uint256(gasSeed) % 1_500_000 : 0;
        bool ok;
        if (caller != address(this)) vm.prank(caller);
        if (cap == 0) {
            try auction.settle() {
                ok = true;
            } catch {}
        } else {
            try auction.settle{gas: cap}() {
                ok = true;
            } catch {}
        }
        if (!ok) {
            t(!expectOk || (cap != 0 && cap < SURE_GAS), "settle: valid settle rejected");
            eq(auction.settled() ? 1 : 0, wasSettled ? 1 : 0, "settle: failed call changed settled");
            return;
        }
        t(expectOk, "settle: settled when it must not");
        ++hitSettle;
        ++ghostSettleCount;
        ghostSettledBid = top;
        ghostWinner = winner;
        t(auction.settled() && auction.proceedsDue() == top, "settle: proceeds not the winning bid");
        t(auction.endsAt() == ends && auction.highestBidder() == winner, "settle: outcome moved");
        // Whatever gas settle() was given: a winner that takes NFTs holds the 1/1 now.
        if (_takesNftSurely(winner)) {
            t(auction.prizeClaimed() && oneOfOne.ownerOf(1) == winner, "settle: prize skipped for a willing winner");
        }
        if (_takesNftNever(winner)) t(!auction.prizeClaimed(), "settle: prize delivered to a refusing wallet");
        if (auction.prizeClaimed()) {
            ++ghostPrizeDeliveries;
            ghostPrizeRecipient = winner;
        } else {
            ++hitPrizeFallback;
        }
    }

    function auction_withdrawProceeds(uint8 who, uint8 toSel) public {
        address caller = who % 3 == 0 ? _actor(who / 3) : treasury;
        address to = _recipient(toSel);
        uint256 due = auction.proceedsDue();
        uint256 balBefore = address(auction).balance;
        bool settled_ = auction.settled();
        bool validTo = to != address(0) && to != address(auction) && to != address(motifs) && to != address(oneOfOne);
        bool expectOk = caller == treasury && settled_ && due != 0 && validTo && _takesEthSurely(to);
        bool expectFail = caller != treasury || !settled_ || due == 0 || !validTo || _takesEthNever(to);
        vm.prank(caller);
        bool ok;
        try auction.withdrawProceeds{gas: 3_000_000}(to) {
            ok = true;
        } catch {}
        if (expectOk) t(ok, "withdrawProceeds: treasury could not withdraw");
        if (expectFail) t(!ok, "withdrawProceeds: paid when it must not");
        if (!ok) return;
        ++hitProceeds;
        ++ghostProceedsCalls;
        uint256 paid = balBefore - address(auction).balance;
        eq(paid, due, "withdrawProceeds: paid other than due");
        eq(paid, ghostSettledBid, "withdrawProceeds: not exactly the winning bid");
        eq(auction.proceedsDue(), 0, "withdrawProceeds: due not cleared");
        ghostProceedsPaid += paid;
    }

    /// @dev ETH forced in, as a selfdestruct or a block reward would send it (AUDIT.md K-06).
    function auction_donate(uint32 amount) public {
        uint256 a = uint256(amount) % 1 ether;
        vm.deal(address(auction), address(auction).balance + a);
        ghostDonated += a;
    }

    /// @dev The two self-call entry points must refuse every outside caller.
    function auction_selfCallEntrypoints(uint8 who) public {
        address a = who % 5 == 4 ? treasury : _actor(who);
        vm.prank(a);
        try auction.payOutbidRefund(a, 1) {
            t(false, "payOutbidRefund callable from outside");
        } catch {}
        vm.prank(a);
        try auction.deliverPrize() {
            t(false, "deliverPrize callable from outside");
        } catch {}
    }

    // ================================================================ motif credits and the prize

    function auction_claimMotifs(uint8 who, uint8 qty, uint8 toSel) public {
        address a = _actor(who);
        address to = _recipient(toSel);
        uint256 credits = auction.motifCredits(a);
        uint256 q;
        uint256 s = qty % 16;
        if (s == 0) q = 0;
        else if (s == 1) q = credits + 1;
        else if (s == 2) q = 65;
        else q = 1 + uint256(qty) % _min(64, credits == 0 ? 1 : credits);
        bool validTo = to != address(0) && to != address(auction) && to != address(motifs) && to != address(oneOfOne);
        bool okQty = q >= 1 && q <= 64 && q <= credits;
        bool expectOk = okQty && validTo && to != address(bazaar) && _takesNftSurely(to);
        bool expectFail = !okQty || !validTo || to == address(bazaar) || _takesNftNever(to);
        uint256[] memory predicted = okQty ? _predictClaim(a, q) : new uint256[](0);
        uint256 mintedBefore = motifs.motifsMinted();
        vm.prank(a);
        bool ok;
        try auction.claimMotifs{gas: 10_000_000}(q, to) {
            ok = true;
        } catch {}
        if (expectOk) t(ok, "claimMotifs: valid claim rejected");
        if (expectFail) t(!ok, "claimMotifs: invalid claim accepted");
        if (!ok) return;
        ++hitClaimMotifs;
        eq(motifs.motifsMinted(), mintedBefore + q, "claimMotifs: minted count");
        eq(auction.motifCredits(a), credits - q, "claimMotifs: credits");
        for (uint256 i; i < q; ++i) {
            // Each id came from the claimer's own reserved ranges, oldest bid first.
            t(motifs.ownerOf(predicted[i]) == to, "claimMotifs: id not from the claimer's ranges");
            _ownedAdd(to, predicted[i]);
        }
        _advanceClaim(a, q);
        ghostCreditsOf[a] -= q;
        ghostMinted += q;
    }

    function _predictClaim(address a, uint256 q) private view returns (uint256[] memory list) {
        list = new uint256[](q);
        uint256 cur = ghostRangeCursor[a];
        uint256[2][] storage ranges = ghostRanges[a];
        uint256 n;
        while (n < q) {
            uint256 next = ranges[cur][0];
            uint256 left = ranges[cur][1];
            for (uint256 j; j < left && n < q; ++j) {
                list[n++] = next + j;
            }
            ++cur;
        }
    }

    /// @dev Ranges are kept as [nextId, remaining]: a claim consumes them from the cursor on.
    function _advanceClaim(address a, uint256 q) private {
        uint256[2][] storage ranges = ghostRanges[a];
        uint256 cur = ghostRangeCursor[a];
        while (q != 0) {
            uint256 take = _min(q, ranges[cur][1]);
            ranges[cur][0] += take;
            ranges[cur][1] -= take;
            q -= take;
            if (ranges[cur][1] == 0) ++cur;
        }
        ghostRangeCursor[a] = cur;
    }

    function auction_claimPrize(uint8 who, uint8 toSel) public {
        address caller = who % 5 == 4 ? treasury : _actor(who);
        address to = _recipient(toSel);
        bool settled_ = auction.settled();
        bool claimed = auction.prizeClaimed();
        address winner = auction.highestBidder();
        bool validTo = to != address(0) && to != address(auction) && to != address(motifs) && to != address(oneOfOne);
        bool expectOk = settled_ && caller == winner && !claimed && validTo && to != address(bazaar)
            && _takesNftSurely(to);
        bool expectFail = !settled_ || caller != winner || claimed || !validTo || to == address(bazaar)
            || _takesNftNever(to);
        vm.prank(caller);
        bool ok;
        try auction.claimPrize{gas: 5_000_000}(to) {
            ok = true;
        } catch {}
        if (expectOk) t(ok, "claimPrize: winner could not claim");
        if (expectFail) t(!ok, "claimPrize: claimed when it must not");
        if (!ok) return;
        ++hitClaimPrize;
        ++ghostPrizeDeliveries;
        ghostPrizeRecipient = to;
        t(auction.prizeClaimed() && oneOfOne.ownerOf(1) == to, "claimPrize: 1/1 not with the chosen recipient");
    }

    // ================================================================ motifs moving outside the Bazaar

    function motif_transfer(uint8 from, uint8 to, uint16 idx) public {
        address a = _actor(from);
        uint256 len = owned[a].length;
        if (len == 0) return;
        uint256 id = owned[a][idx % len];
        address b = to % 5 == 4 ? treasury : _actor(to);
        vm.prank(a);
        motifs.transferFrom(a, b, id);
        _ownedRemove(id);
        _ownedAdd(b, id);
    }

    /// @dev The collection itself and its minter (the auction) can never receive a motif.
    function motif_transferToBlocked(uint8 from, uint16 idx, bool toAuction) public {
        address a = _actor(from);
        uint256 len = owned[a].length;
        if (len == 0) return;
        uint256 id = owned[a][idx % len];
        vm.prank(a);
        try motifs.transferFrom(a, toAuction ? address(auction) : address(motifs), id) {
            t(false, "motif moved to the collection or its minter");
        } catch {}
    }

    function motif_burn(uint8 who, uint16 idx) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        if (len == 0) return;
        uint256 id = owned[a][idx % len];
        uint256 burnedBefore = motifs.motifsBurned();
        vm.prank(a);
        motifs.burn(id);
        t(motifs.burned(id), "burn: id not marked");
        eq(motifs.motifsBurned(), burnedBefore + 1, "burn: count");
        _ownedRemove(id);
        ++ghostDirectBurns;
    }

    /// @dev Only the owner may burn: another actor, even an approved operator, may not.
    function motif_burnNotOwner(uint8 who, uint8 other, uint16 idx, bool approve) public {
        address a = _actor(who);
        address b = _actor(other);
        uint256 len = owned[a].length;
        if (len == 0 || a == b) return;
        uint256 id = owned[a][idx % len];
        if (approve) {
            vm.prank(a);
            motifs.setApprovalForAll(b, true);
        }
        vm.prank(b);
        try motifs.burn(id) {
            t(false, "burn by a non-owner");
        } catch {}
    }

    // ================================================================ Kilim Bazaar

    function bazaar_approve(uint8 who, bool on) public {
        address a = _actor(who);
        vm.prank(a);
        motifs.setApprovalForAll(address(bazaar), on);
    }

    struct MakeCtx {
        address a;
        address to;
        uint256 n;
        uint256 totalBefore;
        uint256 burnedBefore;
        uint256 top;
        uint256 first;
        uint256 won;
        bool settled_;
        bool approved;
        bool validTo;
    }

    function _ids(address a, uint256 n, uint256 offset) private view returns (uint256[] memory list) {
        uint256 len = owned[a].length;
        list = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = owned[a][(offset + i) % len];
        }
    }

    function _makeCtx(address a, address to, uint256 n) private view returns (MakeCtx memory c) {
        c.a = a;
        c.to = to;
        c.n = n;
        c.totalBefore = bazaar.totalSupply();
        c.burnedBefore = motifs.motifsBurned();
        c.settled_ = auction.settled();
        if (c.settled_) {
            c.top = bazaar.masterCost();
            (c.first, c.won) = auction.highestBidMotifs();
        }
        c.approved = motifs.isApprovedForAll(a, address(bazaar));
        c.validTo = to != address(0) && to != address(bazaar) && to != address(motifs) && to != address(auction)
            && to != address(oneOfOne);
    }

    /// @dev One kilim from `n` of the actor's motifs. n under 10, no approval, a refused recipient or an
    ///      unsettled auction must fail; otherwise it must succeed, burn exactly those ids and record them.
    function bazaar_make(uint8 who, uint16 size, uint16 offset, uint8 toSel) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        uint256 n = size % 8 == 0 ? size % 10 : 10 + size % 111;
        if (n > len) n = len;
        if (n == 0) return;
        _makeWith(a, _ids(a, n, offset), toSel);
    }

    /// @dev A make whose ids show motifs from as few 16-motif words as possible, so the Bazaar stores the
    ///      hand DENSE (one word per touched group) instead of PACKED: the other branch of _record.
    function bazaar_makeDense(uint8 who, uint8 toSel) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        if (len < 10) return;
        uint256 scan = len < 600 ? len : 600;
        uint256[64] memory perWord;
        for (uint256 i; i < scan; ++i) {
            ++perWord[(_motifOf(owned[a][i]) - 1) >> 4];
        }
        // The two fullest words.
        uint256 w1;
        uint256 w2 = 1;
        for (uint256 w; w < 64; ++w) {
            if (perWord[w] > perWord[w1]) {
                w2 = w1;
                w1 = w;
            } else if (w != w1 && perWord[w] > perWord[w2]) {
                w2 = w;
            }
        }
        uint256 n = perWord[w1] + perWord[w2];
        if (n < 10) return;
        uint256[] memory list = new uint256[](n);
        uint256 k;
        for (uint256 i; i < scan; ++i) {
            uint256 w = (_motifOf(owned[a][i]) - 1) >> 4;
            if (w == w1 || w == w2) list[k++] = owned[a][i];
        }
        _makeWith(a, list, toSel);
    }

    function _makeWith(address a, uint256[] memory list, uint8 toSel) private {
        uint256 n = list.length;
        MakeCtx memory c = _makeCtx(a, toSel % 4 == 0 ? a : _recipient(toSel), n);
        bool expectOk = c.settled_ && n >= 10 && c.approved && c.validTo && _takesNftSurely(c.to);
        bool expectFail = !c.settled_ || n < 10 || !c.approved || !c.validTo || _takesNftNever(c.to);
        uint256 blockMade = block.number;
        vm.prank(a);
        bool ok;
        uint256 tokenId;
        try bazaar.make{gas: 25_000_000}(list, c.to) returns (uint256 id_) {
            ok = true;
            tokenId = id_;
        } catch {}
        if (expectOk) t(ok, "make: valid make rejected");
        if (expectFail) t(!ok, "make: invalid make accepted");
        if (!ok) {
            eq(bazaar.totalSupply(), c.totalBefore, "make: failed call minted");
            eq(motifs.motifsBurned(), c.burnedBefore, "make: failed call burned");
            return;
        }
        ++hitMake;
        uint256 key = bazaar.kilim(tokenId).handKey;
        _foldGhost(key, list);
        for (uint256 i; i < n; ++i) {
            t(motifs.burned(list[i]), "make: id not burned");
            _ownedRemove(list[i]);
        }
        ghostBazaarBurns += n;
        if (bazaar.kilim(tokenId).flags & 8 == 0) ++hitDenseMake;
        _checkNewKilim(c, tokenId, key, blockMade);
        _mine();
    }

    /// @dev Adds `list` to the ghost hand `key` (a fresh key starts empty).
    function _foldGhost(uint256 key, uint256[] memory list) private {
        GhostHand storage h = ghostHand[key];
        if (h.count == 0) h.minId = type(uint256).max;
        for (uint256 i; i < list.length; ++i) {
            uint256 m = _motifOf(list[i]);
            if (ghostHandCount[key][m] == 0) ++h.distinct;
            ++ghostHandCount[key][m];
            if (list[i] < h.minId) h.minId = list[i];
            if (list[i] > h.maxId) h.maxId = list[i];
        }
        h.count += list.length;
    }

    /// @dev Checks a hand as the Bazaar reports it against the ghost hand: same multiset, ascending,
    ///      and the title is the most-burned motif, lowest number among equals.
    function _checkHand(uint256 key, uint256[] memory nums, uint256[] memory cnts, uint256 count, uint256 distinct, uint256 title)
        private
    {
        GhostHand storage h = ghostHand[key];
        eq(nums.length, h.distinct, "hand: distinct differs from the burned ids");
        eq(distinct, h.distinct, "hand: record distinct");
        eq(count, h.count, "hand: count differs from the burned ids");
        uint256 sum;
        uint256 best;
        uint256 bestN;
        for (uint256 i; i < nums.length; ++i) {
            if (i != 0) t(nums[i] > nums[i - 1], "hand: not ascending");
            eq(cnts[i], ghostHandCount[key][nums[i]], "hand: count of a motif differs from the burned ids");
            sum += cnts[i];
            if (cnts[i] > best) {
                best = cnts[i];
                bestN = nums[i];
            }
        }
        eq(sum, h.count, "hand: lanes do not sum to the count");
        eq(title, bestN, "hand: title is not the most-burned, lowest-numbered motif");
    }

    function _checkNewKilim(MakeCtx memory c, uint256 tokenId, uint256 key, uint256 blockMade) private {
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        GhostHand storage h = ghostHand[key];
        eq(tokenId, c.totalBefore + 1, "kilim: token id not the next");
        eq(bazaar.totalSupply(), c.totalBefore + 1, "kilim: supply");
        t(bazaar.ownerOf(tokenId) == c.to, "kilim: not minted to the named recipient");
        eq(motifs.motifsBurned(), c.burnedBefore + c.n, "kilim: burned count differs");
        eq(k.rank, _expectedRank(h.count, c.top), "kilim: rank does not match the count");
        eq(k.number, bazaar.madeAt(k.rank), "kilim: number is not the next in its rank");
        eq(k.sealBlock, blockMade + 1, "kilim: seal block is not the next block");
        eq(k.seed, 0, "kilim: seeded before the seal");
        bool whole = h.distinct == 1024;
        bool won = c.won != 0 && h.minId >= c.first && h.maxId < c.first + c.won;
        eq(k.flags & 1, 0, "kilim: sealed at birth");
        t(((k.flags & 2) != 0) == whole, "kilim: WHOLE flag");
        t(((k.flags & 4) != 0) == won, "kilim: WINNING_BID flag");
        if (won) ++hitWinningBidFlag;
        if (k.rank == 6) ++hitMaster;
        (uint256[] memory nums, uint256[] memory cnts) = bazaar.handOf(tokenId);
        _checkHand(key, nums, cnts, k.count, k.distinct, k.title);
        ghostHandHash[tokenId] = keccak256(abi.encode(nums, cnts));
        ghostMadeHash[tokenId] = _madeHash(k);
        ghostMadeBlock[tokenId] = blockMade;
        ++ghostKilims;
        _recheckAllHands();
    }

    /// @dev Every kilim's hand is unchanged by later writes (hands are keyed; keys must never collide).
    function _recheckAllHands() private {
        uint256 total = bazaar.totalSupply();
        for (uint256 id = 1; id <= total; ++id) {
            if (ghostHandHash[id] == 0) continue;
            t(_handHash(id) == ghostHandHash[id], "hand of an earlier kilim changed");
        }
    }

    function bazaar_deposit(uint8 who, uint16 size, uint16 offset) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        bool hasLoom = bazaar.loomOf(a).handKey != 0;
        uint256 n = hasLoom ? (size % 16 == 0 ? 0 : 1 + size % 60) : (size % 6 == 0 ? size % 10 : 10 + size % 60);
        if (n > len) n = len;
        bool settled_ = auction.settled();
        bool approved = motifs.isApprovedForAll(a, address(bazaar));
        uint256[] memory list = n == 0 ? new uint256[](0) : _ids(a, n, offset);
        bool expectOk = settled_ && approved && n >= (hasLoom ? 1 : 10);
        uint256 burnedBefore = motifs.motifsBurned();
        vm.prank(a);
        bool ok;
        uint256 key;
        try bazaar.deposit{gas: 25_000_000}(list) returns (uint256 key_) {
            ok = true;
            key = key_;
        } catch {}
        t(ok == expectOk, "deposit: outcome differs from the rules");
        if (!ok) {
            eq(motifs.motifsBurned(), burnedBefore, "deposit: failed call burned");
            return;
        }
        ++hitDeposit;
        if (hasLoom) eq(key, ghostLoomKey[a], "deposit: loom key changed");
        else t(key != 0 && ghostHand[key].count == 0, "deposit: new loom reuses a key");
        ghostLoomKey[a] = key;
        _foldGhost(key, list);
        for (uint256 i; i < n; ++i) {
            t(motifs.burned(list[i]), "deposit: id not burned");
            _ownedRemove(list[i]);
        }
        ghostBazaarBurns += n;
        eq(motifs.motifsBurned(), burnedBefore + n, "deposit: burned count");
        _checkLoom(a, key);
        _recheckAllHands();
    }

    function _checkLoom(address a, uint256 key) private {
        KilimBazaar.Loom memory l = bazaar.loomOf(a);
        GhostHand storage h = ghostHand[key];
        t(l.handKey == key && l.count == h.count && l.minId == h.minId && l.maxId == h.maxId, "deposit: loom record");
        (uint256[] memory nums, uint256[] memory cnts) = bazaar.loomHandOf(a);
        _checkHand(key, nums, cnts, l.count, l.distinct, l.title);
        eq(l.titleCount, ghostHandCount[key][l.title], "deposit: title count");
    }

    function bazaar_makeFromLoom(uint8 who, uint16 size, uint16 offset, uint8 toSel) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        uint256 n = size % 4 == 0 ? 0 : size % 30;
        if (n > len) n = len;
        bool hasLoom = bazaar.loomOf(a).handKey != 0;
        MakeCtx memory c = _makeCtx(a, toSel % 4 == 0 ? a : _recipient(toSel), n);
        uint256[] memory list = n == 0 ? new uint256[](0) : _ids(a, n, offset);
        bool expectOk = c.settled_ && hasLoom && (n == 0 || c.approved) && c.validTo && _takesNftSurely(c.to);
        bool expectFail = !c.settled_ || !hasLoom || (n != 0 && !c.approved) || !c.validTo || _takesNftNever(c.to);
        uint256 key = ghostLoomKey[a];
        uint256 blockMade = block.number;
        vm.prank(a);
        bool ok;
        uint256 tokenId;
        try bazaar.makeFromLoom{gas: 25_000_000}(list, c.to) returns (uint256 id_) {
            ok = true;
            tokenId = id_;
        } catch {}
        if (expectOk) t(ok, "makeFromLoom: valid close rejected");
        if (expectFail) t(!ok, "makeFromLoom: invalid close accepted");
        if (!ok) {
            eq(bazaar.totalSupply(), c.totalBefore, "makeFromLoom: failed call minted");
            return;
        }
        ++hitMakeFromLoom;
        eq(bazaar.kilim(tokenId).handKey, key, "makeFromLoom: kilim does not carry the loom's hand");
        _foldGhost(key, list);
        for (uint256 i; i < n; ++i) {
            t(motifs.burned(list[i]), "makeFromLoom: id not burned");
            _ownedRemove(list[i]);
        }
        ghostBazaarBurns += n;
        eq(bazaar.loomOf(a).handKey, 0, "makeFromLoom: loom left open");
        ghostLoomKey[a] = 0;
        _checkNewKilim(c, tokenId, key, blockMade);
        _mine();
    }

    /// @dev A make, deposit or close that slips in one id the caller does not hold: someone else's, a
    ///      burned one, an unminted one, a duplicate, or a stray the Bazaar holds. It must fail and change nothing.
    function bazaar_foreignIds(uint8 who, uint8 mode, uint16 idx, uint8 entry) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        if (len < 10 || !auction.settled()) return;
        uint256[] memory list = _ids(a, 10, idx);
        uint256 bad;
        uint256 m = mode % 5;
        if (m == 0) {
            address b = _actor(uint256(who) + 1 + (mode / 5) % 3);
            if (owned[b].length == 0) return;
            bad = owned[b][idx % owned[b].length];
        } else if (m == 1) {
            bad = ghostMinted == 0 ? 1 : 1 + uint256(idx) % ghostMinted;
            if (!motifs.burned(bad)) return;
        } else if (m == 2) {
            bad = ghostMinted + 1 + uint256(idx) % (MOTIF_CAP + 10);
            if (bad <= MOTIF_CAP && _minted(bad)) return;
        } else if (m == 3) {
            bad = list[0];
        } else {
            if (ghostStrays == 0) return;
            bad = _anyStray(idx);
            if (bad == 0) return;
        }
        list[1 + uint256(mode) % 9] = bad;
        uint256 totalBefore = bazaar.totalSupply();
        uint256 burnedBefore = motifs.motifsBurned();
        uint256 e = entry % 3;
        vm.prank(a);
        bool ok;
        if (e == 0) {
            try bazaar.make(list, a) {
                ok = true;
            } catch {}
        } else if (e == 1) {
            try bazaar.deposit(list) {
                ok = true;
            } catch {}
        } else {
            try bazaar.makeFromLoom(list, a) {
                ok = true;
            } catch {}
        }
        t(!ok, "Bazaar took an id the caller does not hold");
        eq(bazaar.totalSupply(), totalBefore, "foreign ids: minted");
        eq(motifs.motifsBurned(), burnedBefore, "foreign ids: burned");
    }

    function _minted(uint256 id) private view returns (bool) {
        if (motifs.burned(id)) return true;
        try motifs.ownerOf(id) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    uint256[] internal strayIds;

    function _anyStray(uint16 idx) private view returns (uint256) {
        if (strayIds.length == 0) return 0;
        return strayIds[idx % strayIds.length];
    }

    /// @dev A motif sent to the Bazaar by plain transfer stays there for good; a safe transfer bounces.
    function bazaar_stray(uint8 who, uint16 idx, bool safe) public {
        address a = _actor(who);
        uint256 len = owned[a].length;
        if (len == 0) return;
        uint256 id = owned[a][idx % len];
        vm.prank(a);
        if (safe) {
            try motifs.safeTransferFrom(a, address(bazaar), id) {
                t(false, "Bazaar accepted a safe transfer");
            } catch {}
            return;
        }
        motifs.transferFrom(a, address(bazaar), id);
        _ownedRemove(id);
        ++ghostStrays;
        strayIds.push(id);
    }

    function bazaar_transferKilim(uint256 idSeed, uint8 toSel) public {
        uint256 total = bazaar.totalSupply();
        if (total == 0) return;
        uint256 id = 1 + idSeed % total;
        address owner = bazaar.ownerOf(id);
        address to = _recipient(toSel);
        bool blocked = to == address(0) || to == address(bazaar) || to == address(motifs) || to == address(auction)
            || to == address(oneOfOne);
        vm.prank(owner);
        bool ok;
        try bazaar.transferFrom(owner, to, id) {
            ok = true;
        } catch {}
        t(ok == !blocked, "kilim transfer: outcome differs from the rules");
    }

    // ---------------------------------------------------------------- the seal

    struct SealModel {
        uint256 id;
        uint256 sb;
        uint256 sb0;
        bool sealed_;
        bool known;
    }

    /// @dev Seals up to five ids (some unknown, some repeated). The EIP-2935 history contract is modelled
    ///      as the chain fills it: for each kilim whose seal block is 257..8,191 blocks back, its slot holds
    ///      that block's hash (or nothing, while historyOn is false). The outcome per id is predicted from
    ///      block numbers alone and checked: seal once, only from a nonzero hash of a later block; re-arm
    ///      only past the window.
    function bazaar_seal(uint256 seed, uint8 len) public {
        // The chain always has the EIP-2935 contract the Bazaar found at deployment. Medusa 1.5.1 keeps the
        // code hash of code etched in the constructor but not the code itself (a call to it runs nothing and
        // returns no data), so it is put back for this transaction.
        (bool live, bytes memory probe) = HISTORY.staticcall(abi.encode(block.number - 1));
        if (!live || probe.length != 32) ++historyReetched;
        vm.etch(HISTORY, HISTORY_CODE);
        uint256 total = bazaar.totalSupply();
        uint256 n = 1 + len % 5;
        uint256[] memory list = new uint256[](n);
        SealModel[] memory model = new SealModel[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = uint256(keccak256(abi.encode(seed, i))) % (total + 3);
        }
        uint256 window = bazaar.seedWindow();
        // Fill the history slots the call may read, as the chain would hold them.
        for (uint256 i; i < n; ++i) {
            uint256 id = list[i];
            if (id == 0 || id > total) continue;
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            if (block.number > k.sealBlock) {
                uint256 age = block.number - k.sealBlock;
                if (age > 256 && age <= window) {
                    vm.store(HISTORY, bytes32(uint256(k.sealBlock) % 8191), historyOn ? _historyHash(k.sealBlock) : bytes32(0));
                }
            }
        }
        // Predict, in order (a repeated id sees the earlier entry's effect).
        uint256 expectSealed;
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = list[i];
            if (id == 0 || id > total) continue;
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            uint256 sb = k.sealBlock;
            bool isSealed = k.flags & 1 != 0;
            for (uint256 j; j < i; ++j) {
                if (model[j].known && model[j].id == id) {
                    sb = model[j].sb;
                    isSealed = model[j].sealed_;
                }
            }
            model[i] = SealModel(id, sb, k.sealBlock, isSealed, true);
            if (isSealed || block.number <= sb) continue;
            uint256 age = block.number - sb;
            if (age > window) {
                model[i].sb = block.number + 1;
                continue;
            }
            bytes32 h = age <= 256 ? blockhash(sb) : _historyRead(sb);
            if (h == 0) continue;
            model[i].sealed_ = true;
            hashes[i] = h;
            ++expectSealed;
        }
        uint256 got = bazaar.seal(list);
        eq(got, expectSealed, "seal: count differs from the block-number rule");
        for (uint256 i; i < n; ++i) {
            if (!model[i].known) continue;
            uint256 id = model[i].id;
            // Only the last entry for an id carries its final state.
            bool lastForId = true;
            for (uint256 j = i + 1; j < n; ++j) {
                if (model[j].known && model[j].id == id) lastForId = false;
            }
            if (!lastForId) continue;
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            t(_madeHash(k) == ghostMadeHash[id], "seal: changed a made record");
            if (ghostSealed[id]) {
                t(keccak256(abi.encode(k)) == ghostSealedHash[id], "seal: changed a sealed record");
                continue;
            }
            t((k.flags & 1 != 0) == model[i].sealed_, "seal: sealed state differs from the rule");
            eq(k.sealBlock, model[i].sb, "seal: seal block differs from the rule");
            if (model[i].sealed_) {
                bytes32 h;
                for (uint256 j; j <= i; ++j) {
                    if (model[j].known && model[j].id == id && hashes[j] != 0) h = hashes[j];
                }
                t(h != 0, "seal: sealed from a zero hash");
                t(k.sealBlock > ghostMadeBlock[id] && block.number > k.sealBlock, "seal: hash not of a later block");
                eq(k.seed, uint32(uint256(keccak256(abi.encode(h, address(bazaar), id)))), "seal: seed not from the block hash");
                ghostSealed[id] = true;
                ++ghostSealCount[id];
                ghostSealedHash[id] = keccak256(abi.encode(k));
                ++ghostSeals;
                if (block.number - k.sealBlock > 256) ++ghostHistorySeals;
            } else if (model[i].sb != model[i].sb0) {
                ++ghostRearms;
            }
        }
        _mine();
    }

    // ================================================================ shortcuts

    /// @dev Registration, one bid, the close and settlement in one call, through the same checked handlers:
    ///      a short way into the Bazaar stage for the fuzzer (the long ways stay open).
    function shortcut_toSettlement(uint8 who, uint32 uplift, uint32 gasSeed) public {
        if (auction.settled()) return;
        time_warpToStart();
        auction_registerMany(0);
        if (auction.highestBidder() == address(0)) auction_bid(who, uplift, 0, 1);
        time_warpToClose(2, uint16(uplift));
        auction_settle(4, gasSeed % 3 == 0 ? 1 : gasSeed);
    }

    /// @dev Every actor claims up to 64 of its motifs to itself and approves the Bazaar.
    function shortcut_claimAndApprove(uint8 qty) public {
        for (uint8 i; i < 4; ++i) {
            if (auction.motifCredits(actors[i]) != 0) auction_claimMotifs(i, 3 + (qty % 13) * 16, i);
            if (!motifs.isApprovedForAll(actors[i], address(bazaar))) bazaar_approve(i, true);
        }
    }

    // ================================================================ reads

    /// @dev The metadata and read functions, for tokens that exist and ones that do not: an existing token's
    ///      tokenURI never reverts, a missing one's always does; a sealed kilim's piece is exactly its seed,
    ///      its hand in ascending order and the Master's cost, as JSON.stringify writes them.
    function views_read(uint8 which, uint256 idSeed) public {
        uint256 w = which % 5;
        if (w == 0) {
            address a = _actor(idSeed);
            uint256 len = owned[a].length;
            if (len != 0) {
                uint256 id = owned[a][(idSeed >> 8) % len];
                try motifs.tokenURI(id) returns (string memory uri) {
                    t(_startsWith(bytes(uri), "data:application/json;base64,"), "motif tokenURI: scheme");
                } catch {
                    t(false, "motif tokenURI reverted for a held motif");
                }
            }
            uint256 missing = MOTIF_CAP + 1 + idSeed % 1000;
            try motifs.tokenURI(missing) {
                t(false, "motif tokenURI for a missing id");
            } catch {}
            motifs.contractURI();
            motifs.royaltyInfo(1, idSeed % 1e30);
        } else if (w == 1) {
            bool minted = oneOfOne.minted();
            try oneOfOne.tokenURI{gas: 30_000_000}(1) returns (string memory uri) {
                t(minted, "1/1 tokenURI before the mint");
                t(_startsWith(bytes(uri), "data:application/json;utf8,"), "1/1 tokenURI: scheme");
            } catch {
                t(!minted, "1/1 tokenURI reverted after the mint");
            }
            oneOfOne.contractURI();
            oneOfOne.royaltyInfo(1, idSeed % 1e30);
        } else if (w == 2) {
            uint256 total = bazaar.totalSupply();
            uint256 id = total == 0 ? 1 : 1 + idSeed % total;
            bool exists = id <= total;
            try bazaar.tokenURI{gas: 30_000_000}(id) returns (string memory uri) {
                t(exists, "kilim tokenURI for a missing kilim");
                t(_startsWith(bytes(uri), "data:application/json;utf8,"), "kilim tokenURI: scheme");
            } catch {
                t(!exists, "kilim tokenURI reverted for a kilim");
            }
            if (exists) _checkPiece(id);
        } else if (w == 3) {
            (uint256[6] memory costs, bool open) = bazaar.ladder();
            t(open == auction.settled(), "ladder: open differs from settled");
            if (open) {
                uint256 top = bazaar.masterCost();
                eq(costs[5], top, "ladder: Master cost");
                uint256 count = idSeed % 2000;
                eq(bazaar.rankFor(count), _expectedRank(count, top), "rankFor differs from the page rule");
            } else {
                try bazaar.rankFor(idSeed % 2000) {
                    t(false, "rankFor before settlement");
                } catch {}
            }
            bazaar.contractURI();
            bazaar.royaltyInfo(1, idSeed % 1e30);
            bazaar.rankName(idSeed % 8);
            bazaar.strayMotifs();
        } else {
            auction.liabilities();
            auction.unclaimedMotifRanges(_actor(idSeed));
            uint256 total = bazaar.totalSupply();
            if (total != 0) bazaar.sealState(1 + idSeed % total);
            eq(bazaar.sealState(total + 1), 0, "sealState of a missing kilim");
        }
    }

    function _checkPiece(uint256 id) private {
        KilimBazaar.Kilim memory k = bazaar.kilim(id);
        if (k.flags & 1 == 0) {
            try bazaar.pieceOf(id) {
                t(false, "pieceOf before the seal");
            } catch {}
            return;
        }
        (uint256[] memory nums, uint256[] memory cnts) = bazaar.handOf(id);
        bytes memory list;
        for (uint256 i; i < nums.length; ++i) {
            list = bytes.concat(list, i == 0 ? bytes("[") : bytes(",["), bytes(_dec(nums[i])), ",", bytes(_dec(cnts[i])), "]");
        }
        bytes memory expected = bytes.concat(
            '{"seed":"0x', bytes(_hex8(k.seed)), '","motifs":[', list, '],"top":', bytes(_dec(bazaar.masterCost())), "}"
        );
        t(keccak256(bytes(bazaar.pieceOf(id))) == keccak256(expected), "pieceOf differs from the kilim's record");
    }

    function _dec(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = bytes.concat(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }

    function _hex8(uint256 v) private pure returns (string memory) {
        bytes memory out = new bytes(8);
        for (uint256 i; i < 8; ++i) {
            uint256 d = (v >> (28 - 4 * i)) & 15;
            out[i] = bytes1(uint8(d < 10 ? 48 + d : 87 + d));
        }
        return string(out);
    }

    function _startsWith(bytes memory hay, bytes memory prefix) private pure returns (bool) {
        if (prefix.length > hay.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (hay[i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev What the history contract answers for block n, read the way the Bazaar reads it. Under Foundry
    ///      it is the hash the harness stored; under Medusa 1.5.1 the etched contract does not return the
    ///      stored value (see the README), so the model follows whatever it answers.
    function _historyRead(uint256 n) private returns (bytes32 h) {
        (bool ok, bytes memory r) = HISTORY.staticcall(abi.encode(n));
        if (ok && r.length == 32) h = abi.decode(r, (bytes32));
        if (h != (historyOn ? _historyHash(n) : bytes32(0))) ++historyMismatch;
    }

    /// @dev mode 0: 1-3 blocks, 1: about 256, 2: about the 8,191 window, 3: up to 20,000.
    function chain_roll(uint8 mode, uint16 n) public {
        uint256 m = mode % 4;
        uint256 d = m == 0 ? 1 + n % 3 : (m == 1 ? 250 + n % 20 : (m == 2 ? 8180 + n % 30 : 1 + n % 20_000));
        vm.roll(block.number + d);
        _mine();
    }

    /// @dev Ends the current block (Medusa commits it at the next delayed call), so its hash exists.
    function chain_mine() public {
        _mine();
    }

    function chain_history(bool on) public {
        historyOn = on;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
