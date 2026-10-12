// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {HalmosBase, Rejecter, Reenterer} from "./HalmosBase.sol";

/// @notice One symbolic call to the real KilimAuction (mainnet parameters) from ANY symbolic auction state
///         that satisfies the invariant set below, by ANY caller, with ANY amounts and msg.value. The
///         outbid leader and any payout recipient are drawn from one of each kind (a wallet, a contract that
///         refuses ETH, a contract that re-enters, and every address the auction must refuse).
///         Each check asserts the whole set again afterwards, so the set is inductive for that entry point:
///         with the deployment state satisfying it, it holds after any number of such calls.
///
///         The set (S): balance >= liabilities(); highestBid == 0 iff highestBidder == 0; a nonzero
///         highestBid is a whole unit, >= the reserve, <= uint128 max; highestBidder is never the treasury
///         or the auction; a started auction has endsAt != 0 and an unstarted one endsAt == 0; settled
///         implies started and now >= endsAt; proceedsDue is 0 before settlement and 0 or highestBid after;
///         refunds of the two accounts in play sum to at most refundLiability; motifsAllocated <= motifCap.
///         Plus, per call: after settlement highestBid, highestBidder and highestBidMotifs never change, and
///         endsAt never moves back.
contract AuctionSolvencyHalmos is HalmosBase {
    uint256 internal constant U128 = type(uint128).max;
    address internal constant EOA_B = address(0xB1D0);
    address internal constant EOA_T = address(0x7070);
    /// @dev 0: the outbid leader's kind is symbolic; k > 0: it is kind k - 1 (used by two probes only).
    uint256 internal forcedKind;
    // KilimAuction storage slots (forge storageLayout).
    uint256 internal constant SLOT_ENDS_AT = 4;
    uint256 internal constant SLOT_HIGHEST_BID = 5;
    uint256 internal constant SLOT_BIDDER_SETTLED = 6; // highestBidder (bits 0..159), settled (bit 160)
    uint256 internal constant SLOT_PROCEEDS = 7;
    uint256 internal constant SLOT_REFUND_LIABILITY = 8;
    uint256 internal constant SLOT_REFUNDS = 9;
    uint256 internal constant SLOT_ALLOCATED = 11;
    uint256 internal constant SLOT_HIGHEST_MOTIFS = 16; // first (low 128 bits), count (high 128 bits)

    KilimMotifs internal motifs;
    KilimOneOfOne internal oneOfOne;
    KilimAuction internal auction;
    Rejecter internal rejecter;
    Reenterer internal reenterer;

    struct Pre {
        uint256 hb;
        address bidder;
        bool settled;
        uint64 endsAt;
        uint256 pd;
        uint256 rl;
        uint256 bal;
        uint256 rCaller;
        uint256 rBidder;
        uint256 motifsWord;
        address caller;
    }

    function setUp() public {
        (motifs, oneOfOne, auction) = deployTrio(1_000_000, 1_000_000, 1000, 1 days, 10 minutes);
        openBidding(auction);
        rejecter = new Rejecter();
        reenterer = new Reenterer();
        reenterer.setAuction(auction);
    }

    // ------------------------------------------------------------ the symbolic pre-state

    function _refundSlot(address who) internal pure returns (bytes32) {
        return keccak256(abi.encode(who, SLOT_REFUNDS));
    }

    function _put(uint256 slot, uint256 value) internal {
        vm.store(address(auction), bytes32(slot), bytes32(value));
    }

    function _symbolicState(address caller) internal returns (Pre memory p) {
        return _symbolicState(caller, svm.createUint256("hb"));
    }

    /// @dev The same with the highest bid given (symbolic or concrete).
    function _symbolicState(address caller, uint256 hb) internal returns (Pre memory p) {
        p.caller = caller;
        p.hb = hb;
        p.bidder = _pickBidder();
        p.settled = svm.createBool("settled");
        p.endsAt = uint64(svm.createUint(64, "endsAt"));
        p.pd = svm.createUint256("proceedsDue");
        p.rl = svm.createUint256("refundLiability");
        p.bal = svm.createUint256("balance");
        p.rCaller = svm.createUint256("refundsCaller");
        p.rBidder = svm.createUint256("refundsBidder");
        uint256 allocated = svm.createUint256("motifsAllocated");
        uint256 first = svm.createUint(128, "highestFirst");
        uint256 count = svm.createUint(128, "highestCount");
        uint256 nowTs = svm.createUint(64, "now");

        // Shape of a reachable state. One assume over branch-free conjunctions: every `&&`, `?:` or `if`
        // here would fork the path (see the helpers in HalmosBase).
        bool started = p.bidder != address(0);
        bool same = caller == p.bidder;
        bool ok = (p.hb == 0) == !started;
        ok = _and(ok, _imp(started, _and(_and(p.hb % UNIT == 0, p.hb >= RESERVE), p.hb <= U128)));
        ok = _and(ok, _and(p.bidder != TREASURY, p.bidder != address(auction)));
        ok = _and(ok, (p.endsAt != 0) == started);
        ok = _and(ok, _and(nowTs >= auction.startsAt(), nowTs < (1 << 63)));
        ok = _and(ok, _imp(p.settled, _and(started, nowTs >= p.endsAt)));
        ok = _and(ok, _imp(p.settled, _or(p.pd == p.hb, p.pd == 0)));
        ok = _and(ok, _imp(!p.settled, p.pd == 0));
        ok = _and(ok, p.rl <= U128);
        ok = _and(ok, _imp(same, _and(p.rCaller == p.rBidder, p.rCaller <= p.rl)));
        ok = _and(ok, _imp(!same, _and(p.rCaller <= p.rl, p.rBidder <= _usub(p.rl, p.rCaller))));
        ok = _and(ok, allocated <= auction.motifCap());
        ok = _and(ok, _and(count <= 1_000_000, first <= 1_000_000));
        // Solvency, the induction hypothesis.
        ok = _and(ok, p.bal >= _uadd(p.rl, _ite(p.settled, p.pd, p.hb)));
        vm.assume(ok);

        _put(SLOT_ENDS_AT, p.endsAt);
        _put(SLOT_HIGHEST_BID, p.hb);
        _put(SLOT_BIDDER_SETTLED, uint256(uint160(p.bidder)) | _ite(p.settled, 1 << 160, 0));
        _put(SLOT_PROCEEDS, p.pd);
        _put(SLOT_REFUND_LIABILITY, p.rl);
        _put(SLOT_ALLOCATED, allocated);
        p.motifsWord = first | (count << 128);
        _put(SLOT_HIGHEST_MOTIFS, p.motifsWord);
        vm.store(address(auction), _refundSlot(p.bidder), bytes32(p.rBidder));
        vm.store(address(auction), _refundSlot(caller), bytes32(p.rCaller));
        vm.deal(address(auction), p.bal);
        vm.warp(nowTs);
    }

    /// @dev The outbid leader, one of each kind of receiver: none yet, a wallet without code (accepts ETH), a
    ///      contract that refuses ETH (the refund is deferred), a contract that re-enters on receipt and
    ///      accepts. Concrete addresses keep Halmos from branching over every contract in the test.
    function _pickBidder() internal returns (address) {
        uint256 kind = forcedKind != 0 ? forcedKind - 1 : svm.createUint(8, "bidderKind");
        if (kind == 0) return address(0);
        if (kind == 1) return EOA_B;
        if (kind == 2) return address(rejecter);
        vm.assume(kind == 3);
        return address(reenterer);
    }

    /// @dev A recipient: a wallet, the two test contracts, and every address the auction must refuse.
    function _pickTo(uint256 kind) internal view returns (address) {
        if (kind == 0) return EOA_T;
        if (kind == 1) return address(rejecter);
        if (kind == 2) return address(reenterer);
        if (kind == 3) return address(0);
        if (kind == 4) return address(auction);
        if (kind == 5) return address(motifs);
        if (kind == 6) return address(oneOfOne);
        if (kind == 7) return TREASURY;
        vm.assume(false);
        return address(0);
    }

    /// @dev Any caller a transaction can come from: not the auction itself (its self-calls are modelled by
    ///      its own code) and not address(0), which no key controls. (A first run without the address(0)
    ///      exclusion found that a bid "from" address(0) would leave highestBid > 0 with highestBidder 0;
    ///      unreachable on chain.)
    function _caller() internal returns (address caller) {
        caller = svm.createAddress("caller");
        vm.assume(caller != address(auction) && caller != address(this) && caller != address(0));
    }

    // ------------------------------------------------------------ the invariant set, after the call

    function _assertSet(Pre memory p) internal view {
        uint256 hb = auction.highestBid();
        address bidder = auction.highestBidder();
        bool settled = auction.settled();
        uint256 pd = auction.proceedsDue();
        uint256 rl = auction.refundLiability();
        uint64 endsAt = auction.endsAt();

        assert(address(auction).balance >= auction.liabilities());
        bool started = bidder != address(0);
        bool shape = (hb == 0) == !started;
        shape = _and(shape, _imp(started, _and(_and(hb % UNIT == 0, hb >= RESERVE), hb <= U128)));
        shape = _and(shape, _and(bidder != TREASURY, bidder != address(auction)));
        shape = _and(shape, (endsAt != 0) == started);
        shape = _and(shape, _imp(settled, _and(started, block.timestamp >= endsAt)));
        shape = _and(shape, _imp(settled, _or(pd == hb, pd == 0)));
        shape = _and(shape, _imp(!settled, pd == 0));
        assert(shape);
        uint256 rc = auction.refunds(p.caller);
        uint256 rb = auction.refunds(p.bidder);
        bool same = p.caller == p.bidder;
        assert(_and(_imp(same, rc <= rl), _imp(!same, _and(rc <= rl, rb <= _usub(rl, rc)))));
        assert(auction.motifsAllocated() <= auction.motifCap());
        // Monotone close; final terms after settlement.
        assert(endsAt >= p.endsAt);
        assert(_imp(p.settled, _fixedTerms(p)));
    }

    /// @dev After settlement the outcome and the winning bid's motif ids are exactly as before the call.
    function _fixedTerms(Pre memory p) internal view returns (bool) {
        (uint256 f, uint256 c) = auction.highestBidMotifs();
        bool same = _and(auction.highestBid() == p.hb, auction.highestBidder() == p.bidder);
        return _and(_and(auction.settled(), same), (f | (c << 128)) == p.motifsWord);
    }

    // ------------------------------------------------------------ one check per entry point

    /// @dev Which way a bid went, for the reachability probes below.
    struct BidPath {
        bool ok;
        bool outbidOther;
        bool paid;
        bool deferred;
    }

    function _stepBid(uint256 hb, uint256 amount, uint256 value, uint256 minReward, uint256 expectedFirst)
        internal
        returns (BidPath memory r)
    {
        address caller = _caller();
        Pre memory p = _symbolicState(caller, hb);
        vm.assume(value <= U128);
        vm.deal(caller, value);
        uint256 bidderBalance = p.bidder.balance;
        vm.prank(caller);
        (r.ok,) =
            address(auction).call{value: value}(abi.encodeCall(auction.bid, (amount, minReward, expectedFirst)));
        _assertSet(p);
        if (r.ok) {
            // Exactly the amount came in, and the outbid bid was either paid back or recorded, never both.
            bool placed = _and(auction.highestBid() == amount, auction.highestBidder() == caller);
            assert(_and(_and(value == amount, !p.settled), placed));
            r.outbidOther = _and(p.bidder != address(0), p.bidder != caller);
            r.paid = p.bidder.balance == _uadd(bidderBalance, p.hb);
            r.deferred = auction.refunds(p.bidder) == _uadd(p.rBidder, p.hb);
            bool books = _and(
                address(auction).balance == _usub(_uadd(p.bal, amount), _ite(r.paid, p.hb, 0)),
                auction.refundLiability() == _uadd(p.rl, _ite(r.deferred, p.hb, 0))
            );
            assert(_imp(r.outbidOther, _and(r.paid != r.deferred, books)));
            // The close: the first bid sets now + duration; a later one never brings it forward and leaves
            // at least extensionWindow.
            bool first = p.bidder == address(0);
            uint256 endsAt = auction.endsAt();
            bool opened = endsAt == _uadd(block.timestamp, 1 days); // now < 2^63
            bool extended = endsAt >= _uadd(block.timestamp, 10 minutes);
            assert(_and(_imp(first, opened), _imp(!first, extended)));
        }
    }

    /// @dev Everything symbolic, the highest bid and the amount included. EXPECTED TIMEOUT: outbidding runs
    ///      the upstream predicate, whose 256-bit divisions by symbolic values the solver does not close
    ///      (AuctionMathHalmos). The two checks below split it so each closes.
    function check_step_bid(uint256 hb, uint256 amount, uint256 value, uint256 minReward, uint256 expectedFirst)
        public
    {
        _stepBid(hb, amount, value, minReward, expectedFirst);
    }

    /// @dev The first bid (no highest bid yet): amount, msg.value, caller and the rest of the state symbolic.
    function check_step_bid_first(uint256 amount, uint256 value, uint256 minReward, uint256 expectedFirst) public {
        _stepBid(0, amount, value, minReward, expectedFirst);
    }

    /// @dev Outbidding with the highest bid and the amount taken from a table (so the predicate is concrete),
    ///      everything else symbolic: caller, msg.value, the outbid leader's kind, balance, refunds,
    ///      refundLiability, endsAt, now, gas, settled. The table: the minimum steps at the reserve, an exact
    ///      10% step at 1 ETH, a jump, amounts just below and equal to the minimum (refused), and the top of
    ///      the uint128 range.
    function check_step_bid_outbid(uint256 pick, uint256 value, uint256 minReward, uint256 expectedFirst) public {
        uint256 hb;
        uint256 amount;
        if (pick == 0) (hb, amount) = (10 * UNIT, 11 * UNIT);
        else if (pick == 1) (hb, amount) = (11 * UNIT, 13 * UNIT);
        else if (pick == 2) (hb, amount) = (13 * UNIT, 15 * UNIT);
        else if (pick == 3) (hb, amount) = (1 ether, 1.1 ether);
        else if (pick == 4) (hb, amount) = (1 ether, 1.099 ether);
        else if (pick == 5) (hb, amount) = (5 ether, 5 ether);
        else if (pick == 6) (hb, amount) = (93.9 ether, 1000 ether);
        else if (pick == 7) (hb, amount) = ((1 << 127) / UNIT * UNIT, U128 / UNIT * UNIT);
        else vm.assume(false);
        _stepBid(hb, amount, value, minReward, expectedFirst);
    }

    function _stepWithdrawRefund(uint256 toKind) internal returns (bool ok) {
        address to = _pickTo(toKind);
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (ok,) = address(auction).call(abi.encodeCall(auction.withdrawRefund, (to)));
        _assertSet(p);
        if (ok) {
            assert(p.rCaller != 0);
            assert(auction.refunds(caller) == 0);
            assert(auction.refundLiability() == p.rl - p.rCaller);
            assert(address(auction).balance == p.bal - p.rCaller);
        }
    }

    function check_step_withdrawRefund(uint256 toKind) public {
        _stepWithdrawRefund(toKind);
    }

    function _stepSettle() internal returns (bool ok) {
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (ok,) = address(auction).call(abi.encodeCall(auction.settle, ()));
        _assertSet(p);
        if (ok) {
            assert(!p.settled && p.bidder != address(0));
            assert(auction.settled() && auction.proceedsDue() == p.hb);
            assert(address(auction).balance == p.bal);
        }
    }

    function check_step_settle() public {
        _stepSettle();
    }

    function _stepWithdrawProceeds(uint256 toKind) internal returns (bool ok) {
        address to = _pickTo(toKind);
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (ok,) = address(auction).call(abi.encodeCall(auction.withdrawProceeds, (to)));
        _assertSet(p);
        if (ok) {
            assert(caller == TREASURY && p.settled && p.pd != 0);
            assert(auction.proceedsDue() == 0);
            assert(address(auction).balance == p.bal - p.pd);
        }
    }

    function check_step_withdrawProceeds(uint256 toKind) public {
        _stepWithdrawProceeds(toKind);
    }

    function _stepClaimPrize(uint256 toKind) internal returns (bool ok) {
        address to = _pickTo(toKind);
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (ok,) = address(auction).call(abi.encodeCall(auction.claimPrize, (to)));
        _assertSet(p);
        assert(address(auction).balance == p.bal);
        if (ok) assert(p.settled && caller == p.bidder && oneOfOne.ownerOf(1) == to);
    }

    function check_step_claimPrize(uint256 toKind) public {
        _stepClaimPrize(toKind);
    }

    function check_step_payOutbidRefund(address bidder, uint256 amount) public {
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (bool ok,) = address(auction).call(abi.encodeCall(auction.payOutbidRefund, (bidder, amount)));
        assert(!ok); // only the auction may call it
        _assertSet(p);
    }

    function check_step_deliverPrize() public {
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (bool ok,) = address(auction).call(abi.encodeCall(auction.deliverPrize, ()));
        assert(!ok); // only the auction may call it
        _assertSet(p);
    }

    function check_step_register() public {
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (bool ok,) = address(auction).call(abi.encodeCall(auction.register, ()));
        assert(!ok); // the 100 registrations are complete
        _assertSet(p);
    }

    /// @dev claimMotifs moves no ETH and touches none of the slots in the set (credits here are 0 for every
    ///      caller, so it reverts: the credit logic is covered by MotifCreditsHalmos).
    function check_step_claimMotifs(uint256 quantity, uint256 toKind) public {
        address to = _pickTo(toKind);
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.prank(caller);
        (bool ok,) = address(auction).call(abi.encodeCall(auction.claimMotifs, (quantity, to)));
        ok;
        _assertSet(p);
        assert(address(auction).balance == p.bal);
    }

    /// @dev Plain ETH (no receive or fallback) is refused, and so are three selectors the auction does not
    ///      have, with ETH or without. (A first version took a symbolic selector: Halmos then forks at every
    ///      one of the ~45 dispatcher comparisons and the run did not finish in an hour.)
    function check_step_plainTransferAndUnknownSelector(uint256 value) public {
        address caller = _caller();
        Pre memory p = _symbolicState(caller);
        vm.assume(value <= U128);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(auction).call{value: value}("");
        assert(!ok);
        bytes4[3] memory unknown = [bytes4(0x00000000), bytes4(0xdeadbeef), bytes4(0xffffffff)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(caller);
            (ok,) = address(auction).call{value: value}(abi.encodePacked(unknown[i]));
            assert(!ok);
        }
        _assertSet(p);
        assert(address(auction).balance == p.bal);
    }

    // ------------------------------------------------------------ reachability probes (EXPECTED to FAIL)
    // Each asserts that a success path of a check above can NOT happen. A counterexample proves the path is
    // reachable, so the PASS of the check above is not vacuous there.

    /// @dev Outbidding 1 ETH with 1.1 ETH (row 3 of check_step_bid_outbid's table), the rest symbolic.
    function check_reach_bidPaid_EXPECTED_FAIL(uint256 value) public {
        BidPath memory r = _stepBid(1 ether, 1.1 ether, value, 0, 0);
        assert(!(r.ok && r.outbidOther && r.paid));
    }

    function check_reach_bidDeferred_EXPECTED_FAIL(uint256 value) public {
        BidPath memory r = _stepBid(1 ether, 1.1 ether, value, 0, 0);
        assert(!(r.ok && r.outbidOther && r.deferred));
    }

    /// @dev The same two probes with the leader's kind fixed (an EOA; the ETH-rejecting contract), so a
    ///      counterexample is found without exploring the other kinds first.
    function check_reach_bidPaidEOA_EXPECTED_FAIL(uint256 value) public {
        forcedKind = 2;
        BidPath memory r = _stepBid(1 ether, 1.1 ether, value, 0, 0);
        assert(!(r.ok && r.outbidOther && r.paid));
    }

    function check_reach_bidDeferredRejecter_EXPECTED_FAIL(uint256 value) public {
        forcedKind = 3;
        BidPath memory r = _stepBid(1 ether, 1.1 ether, value, 0, 0);
        assert(!(r.ok && r.outbidOther && r.deferred));
    }

    function check_reach_withdrawRefund_EXPECTED_FAIL(uint256 toKind) public {
        assert(!_stepWithdrawRefund(toKind));
    }

    function check_reach_settle_EXPECTED_FAIL() public {
        assert(!_stepSettle());
    }

    function check_reach_withdrawProceeds_EXPECTED_FAIL(uint256 toKind) public {
        assert(!_stepWithdrawProceeds(toKind));
    }

    function check_reach_claimPrize_EXPECTED_FAIL(uint256 toKind) public {
        assert(!_stepClaimPrize(toKind));
    }
}
