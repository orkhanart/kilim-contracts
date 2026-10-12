// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {HalmosBase} from "./HalmosBase.sol";

/// @dev The unchanged EnglishAuction source, made concrete: the harness adds a setter for the one state
///      variable minimumBid() reads and an external wrapper for the internal bid predicate. Nothing else.
contract EnglishAuctionHarness is EnglishAuction {
    constructor(AuctionConfig memory c) EnglishAuction(c) {}

    function setHighestBid(uint256 v) external {
        highestBid = v;
    }

    function isNewWinningBid(uint256 minimum, uint256 current, uint256 incoming, uint256 bps)
        external
        pure
        returns (bool)
    {
        return _isNewWinningBid(minimum, current, incoming, bps);
    }
}

/// @notice Bid arithmetic of EnglishAuction, checked against the predicate _handleBid actually enforces.
///         Together: (1) minimumBid() is accepted, (2) no smaller whole-unit amount is, (3) every whole-unit
///         amount at or above it is, so a whole-unit bid is accepted exactly when it is >= minimumBid().
///         check_isNewWinningBid_monotone states (3) for any amounts and any bps (harder for the solver).
///         Highest bids are bounded below T1 = 2^20 units (1,048 ETH). RESULT: none of the predicate checks
///         closes within 300 s (yices 2.6.4; z3 4.12.6 also times out on the saved query). Every path through
///         `(incoming - current) * MAX_BPS` carries solc's checked-multiplication test, which divides by the
///         symbolic left operand, and the predicate then divides by `current`: 256-bit division by a symbolic
///         value, which bit-blasting solvers do not decide here. A first run with a CONCRETE highest bid and
///         a symbolic amount timed out the same way (the multiplication test still divides by the amount),
///         so those variants were removed. They are kept as a record; see the report.
contract AuctionMathHalmos is HalmosBase {
    uint256 internal constant U128 = type(uint128).max;
    uint256 internal constant T1 = 1 << 20;

    EnglishAuctionHarness internal h1000; // mainnet: 10%
    EnglishAuctionHarness internal h10000; // the largest allowed increment

    function setUp() public {
        h1000 = _harness(1000);
        h10000 = _harness(10_000);
    }

    function _harness(uint16 bps) internal returns (EnglishAuctionHarness) {
        return new EnglishAuctionHarness(
            EnglishAuction.AuctionConfig({
                treasury: TREASURY,
                startsAt: uint64(block.timestamp + 1 hours),
                duration: 1 days,
                extensionWindow: 10 minutes,
                incrementBps: bps,
                reservePrice: RESERVE
            })
        );
    }

    // ------------------------------------------------------------ first bid

    /// @dev Before the first bid the minimum is the reserve, and the predicate accepts exactly amounts >= it.
    function check_firstBid_reserveExact(uint256 amount) public {
        assert(h1000.minimumBid() == RESERVE);
        bool ok = h1000.isNewWinningBid(RESERVE, 0, amount, 1000);
        assert(ok == (amount >= RESERVE));
    }

    // ------------------------------------------------------------ (1) minimumBid() is accepted

    function _accepted(EnglishAuctionHarness h, uint256 bps, uint256 hb, uint256 bound) internal {
        vm.assume(hb % UNIT == 0 && hb >= RESERVE && hb < bound * UNIT);
        h.setHighestBid(hb);
        uint256 m = h.minimumBid();
        assert(m % UNIT == 0);
        assert(m > hb);
        assert(h.isNewWinningBid(RESERVE, hb, m, bps));
    }

    function check_minimumBid_accepted_bps1000_T1(uint256 hb) public {
        _accepted(h1000, 1000, hb, T1);
    }

    function check_minimumBid_accepted_bps10000_T1(uint256 hb) public {
        _accepted(h10000, 10_000, hb, T1);
    }

    // ------------------------------------------------------------ (2) nothing smaller is accepted

    function _least(EnglishAuctionHarness h, uint256 bps, uint256 hb, uint256 a, uint256 bound) internal {
        vm.assume(hb % UNIT == 0 && hb >= RESERVE && hb < bound * UNIT);
        h.setHighestBid(hb);
        vm.assume(a % UNIT == 0 && a < h.minimumBid());
        assert(!h.isNewWinningBid(RESERVE, hb, a, bps));
    }

    function check_minimumBid_least_bps1000_T1(uint256 hb, uint256 a) public {
        _least(h1000, 1000, hb, a, T1);
    }

    // ------------------------------------------------------------ (3) everything at or above it is accepted

    function _above(EnglishAuctionHarness h, uint256 bps, uint256 hb, uint256 a, uint256 bound) internal {
        vm.assume(hb % UNIT == 0 && hb >= RESERVE && hb < bound * UNIT);
        h.setHighestBid(hb);
        vm.assume(a % UNIT == 0 && a >= h.minimumBid() && a < 3 * bound * UNIT);
        assert(h.isNewWinningBid(RESERVE, hb, a, bps));
    }

    function check_minimumBid_above_bps1000_T1(uint256 hb, uint256 a) public {
        _above(h1000, 1000, hb, a, T1);
    }

    /// @dev Raising an accepted amount keeps it accepted (any current bid, any bps 1..10000, amounts within
    ///      the uint128 bound _handleBid applies first). Bound: current < 2^80 wei.
    function check_isNewWinningBid_monotone(uint256 current, uint256 a1, uint256 a2, uint256 bps) public view {
        vm.assume(current != 0 && current < (1 << 80) && a1 <= a2 && a2 <= U128);
        vm.assume(bps >= 1 && bps <= 10_000);
        if (h1000.isNewWinningBid(RESERVE, current, a1, bps)) {
            assert(h1000.isNewWinningBid(RESERVE, current, a2, bps));
        }
    }

    // ------------------------------------------------------------ no reverts, no overflow

    /// @dev minimumBid() never reverts for any highest bid up to uint128 max (the bid bound), whole unit or
    ///      not, and is a whole unit strictly above it; from any reachable highest bid (0 or >= the reserve)
    ///      it is also at least the reserve.
    function check_minimumBid_noRevert(uint256 hb) public {
        vm.assume(hb <= U128);
        h1000.setHighestBid(hb);
        (bool ok, bytes memory ret) = address(h1000).staticcall(abi.encodeCall(h1000.minimumBid, ()));
        assert(ok);
        uint256 m = abi.decode(ret, (uint256));
        assert(m % UNIT == 0);
        if (hb != 0) assert(m > hb);
        if (hb == 0 || hb >= RESERVE) assert(m >= RESERVE);
    }

    /// @dev Under _handleBid's bounds (current, incoming <= uint128 max; bps 1..10000) the predicate never
    ///      panics: (incoming - current) * 10000 cannot overflow and current != 0 is the divisor.
    function check_isNewWinningBid_noPanic(uint256 current, uint256 incoming, uint256 bps) public view {
        vm.assume(current <= U128 && incoming <= U128);
        vm.assume(bps >= 1 && bps <= 10_000);
        (bool ok,) =
            address(h1000).staticcall(abi.encodeCall(h1000.isNewWinningBid, (RESERVE, current, incoming, bps)));
        assert(ok);
    }

    /// @dev Why _handleBid bounds the amount BEFORE the predicate: without it the predicate can panic.
    ///      Expected to FAIL (a counterexample is the point): an amount above uint128 max can overflow
    ///      (amount - current) * 10000. _handleBid never reaches this, since it checks the bound first.
    function check_isNewWinningBid_unboundedPanics_EXPECTED_FAIL(uint256 current, uint256 incoming) public view {
        vm.assume(current != 0);
        (bool ok,) =
            address(h1000).staticcall(abi.encodeCall(h1000.isNewWinningBid, (RESERVE, current, incoming, 1000)));
        assert(ok);
    }
}
