// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "../TestBase.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {GasHungryWinner} from "../AttackPatterns.t.sol";

/// @dev AttackPatterns' GasHungryWinner with the burn taken from the clock, block.timestamp - close, so the
///      winner can be built in setUp and measured in the test without being touched first (vm.warp warms
///      no account; a setter would).
contract ClockHungryWinner is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256 private immutable close;

    constructor(KilimAuction a, uint256 close_) {
        auction = a;
        close = close_;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        uint256 burn = block.timestamp - close;
        while (start - gasleft() < burn) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Skeptic's check of the review finding on AttackPatterns.testPrizeDeliveryAtGlamsterdamPrices
///         (10 October 2026): the suite's binary search builds the auction, its 1/1 and the winner inside
///         the test transaction, so the 500,000-gas delivery frame sees all of them warm. Here the same
///         loop is narrowed to one gas and run three ways: as the suite does it, with everything built in
///         setUp (cold, as a settle() sent by anyone), and cold but with the two accounts touched first.
contract PrizeBudgetWarmVsColdPoC is TestBase {
    uint256 private constant PRIZE_GAS = 500_000;
    // As the suite's model: EIP-8037 state gas + EIP-8038 execution gas for a new slot, less today.
    uint256 private constant NEW_SLOT_EXTRA = 110_020 - 22_100;
    // New slots the delivery writes, as the suite logs (prizeClaimed, minted, _owners[1], _balances[winner]).
    uint256 private constant FRESH_SLOTS = 4;
    // What the suite's model leaves out (EIP-8038): COLD_ACCOUNT_ACCESS 2,600 -> 3,000 on the auction's
    // call into the 1/1 and on the 1/1's EXTCODESIZE of the winner, plus one WARM_ACCESS on EXTCODESIZE.
    uint256 private constant COLD_ACCOUNT_RISE = 3_000 - 2_600;
    uint256 private constant EXTCODESIZE_EXTRA = 100;

    KilimAuction private cold;
    address private coldOne;
    ClockHungryWinner private coldWinner;
    uint256 private coldClose;

    event log_named_uint(string key, uint256 value);

    function setUp() public {
        cold = new KilimAuction(config());
        coldOne = address(cold.oneOfOne());
        _openBidding(cold);
        // The first bid, placed right below, closes the clock at now + duration.
        coldClose = block.timestamp + cold.duration();
        coldWinner = new ClockHungryWinner(cold, coldClose);
        _fund(address(coldWinner), 1 ether);
        coldWinner.bid(RESERVE);
        assertEq(cold.endsAt(), coldClose);
    }

    /// @dev The suite's loop body, verbatim: auction, 1/1 and winner created in this transaction.
    function _deliveredWarm(uint256 burn) private returns (bool delivered) {
        uint256 s = vm.snapshotState();
        KilimAuction a2 = new KilimAuction(config());
        _openBidding(a2);
        GasHungryWinner w = new GasHungryWinner(a2, burn);
        _fund(address(w), 1 ether);
        w.bid(RESERVE);
        vm.warp(a2.endsAt());
        a2.settle();
        delivered = a2.prizeClaimed();
        vm.revertToState(s);
    }

    /// @dev Everything from setUp: the auction's slots, the 1/1 and the winner are cold when settle()
    ///      runs, as in a settle() transaction sent by anyone on mainnet.
    function _deliveredCold(uint256 burn) private returns (bool delivered) {
        uint256 s = vm.snapshotState();
        vm.warp(coldClose + burn);
        cold.settle();
        delivered = cold.prizeClaimed();
        vm.revertToState(s);
    }

    /// @dev The cold state after the test touches just the two accounts (one EXTCODESIZE each).
    function _deliveredColdTouched(uint256 burn) private returns (bool delivered) {
        uint256 s = vm.snapshotState();
        vm.warp(coldClose + burn);
        assertTrue(coldOne.code.length != 0);
        assertTrue(address(coldWinner).code.length != 0);
        cold.settle();
        delivered = cold.prizeClaimed();
        vm.revertToState(s);
    }

    function _max(function(uint256) returns (bool) probe, uint256 lo, uint256 hi) private returns (uint256) {
        assertTrue(probe(lo));
        assertTrue(!probe(hi));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (probe(mid)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function testSuiteLoopIsWarmAndItsNumberIsHigh() public {
        // 1. The suite's search exactly as written (1,000-gas granularity) reproduces its log line.
        uint256 lo = 300_000;
        uint256 hi = 500_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            if (_deliveredWarm(mid)) lo = mid;
            else hi = mid;
        }
        emit log_named_uint("suite's loop as written, 1,000-gas granularity", lo);
        assertEq(lo, 391_406);

        // 2. The same three measurements to one gas.
        uint256 warm = _max(_deliveredWarm, 380_000, 400_000);
        uint256 coldBudget = _max(_deliveredCold, 370_000, 400_000);
        uint256 touched = _max(_deliveredColdTouched, 370_000, 400_000);
        emit log_named_uint("hook budget, suite's state (all warm), to one gas", warm);
        emit log_named_uint("hook budget, setUp state (all cold), to one gas", coldBudget);
        emit log_named_uint("hook budget, cold but the 1/1 and the winner touched first", touched);
        assertTrue(warm >= lo && warm < lo + 1_000);
        assertTrue(coldBudget < warm);
        uint256 gap = warm - coldBudget;
        emit log_named_uint("warm minus cold", gap);
        // Two cold accounts at 2,500 each, less the 1/64 kept at one or two call depths: about 4,900.
        assertTrue(gap >= 4_000 && gap <= 6_000);
        // Touching the two accounts alone recovers almost all of it; the rest is the auction's own
        // storage read cold inside deliverPrize, which the suite's in-transaction construction also warms.
        emit log_named_uint("recovered by touching the two accounts", touched - coldBudget);
        assertTrue(touched > coldBudget);
        assertTrue(warm - touched < 1_000);

        // 3. The projection, the suite's way and the cold way.
        uint256 overheadSuite = (PRIZE_GAS - lo) + FRESH_SLOTS * NEW_SLOT_EXTRA;
        assertEq(overheadSuite, 460_274); // what the suite logs
        uint256 overheadCold = (PRIZE_GAS - coldBudget) + FRESH_SLOTS * NEW_SLOT_EXTRA + 2 * COLD_ACCOUNT_RISE
            + EXTCODESIZE_EXTRA;
        emit log_named_uint("headroom after the fork, suite's number", PRIZE_GAS - overheadSuite);
        emit log_named_uint(
            "headroom after the fork, cold with EIP-8038 account prices", PRIZE_GAS - overheadCold
        );
        emit log_named_uint("difference", overheadCold - overheadSuite);
        // The property the suite asserts still holds in the cold state.
        assertTrue(overheadCold < PRIZE_GAS);
        assertTrue(overheadCold > overheadSuite);
    }
}
