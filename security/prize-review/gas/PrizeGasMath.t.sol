// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Independent review of the PRIZE_GAS 500,000 -> 1,000,000 change (12 October 2026), gas-math lens.
// Run from contracts/ with:
//   FOUNDRY_OUT=.tools-out/prize-gas/out FOUNDRY_CACHE_PATH=.tools-out/prize-gas/cache \
//   FOUNDRY_TEST=security/prize-review/gas nice -n 10 node scripts/forge.mjs test -vv
//
// Everything a test settles was set up in setUp (its own transaction), so inside a test every account and
// slot is cold, as in a real settle() transaction; each probe runs from a snapshot and is rolled back, which
// also restores the cold state (checked: repeated probes give identical gas).

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "../../../test/TestBase.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";
import {KilimAuctionSepolia500k} from "./KilimAuctionSepolia500k.sol";

interface VmGas {
    struct Gas {
        uint64 gasLimit;
        uint64 gasTotalUsed;
        uint64 gasMemoryUsed;
        int64 gasRefunded;
        uint64 gasRemaining;
    }

    function lastCallGas() external view returns (Gas memory);
    // Calibrated in a scratch project: the gas matched is the gas the callee is actually GIVEN (after the
    // 63/64 cap), not the gas requested; a call asking 1,000,000 from a 500,000 frame does not match.
    function expectCall(address callee, uint256 msgValue, uint64 gas, bytes calldata data) external;
    function record() external;
    function accesses(address) external returns (bytes32[] memory reads, bytes32[] memory writes);
    function load(address, bytes32) external view returns (bytes32);
}

/// @dev Hook burns block.timestamp - base gas (set with vm.warp, which touches no account).
contract ClockBurnWinner is IERC721Receiver {
    uint256 private immutable base;

    constructor(uint256 base_) {
        base = base_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        uint256 b = block.timestamp - base;
        while (start - gasleft() < b) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Hook reverts with (block.timestamp - base) bytes of revert data: a returndata bomb whose size is
///      set by the clock. Large sizes make the delivery frame run out of gas while bubbling the data, so
///      the self-call consumes its WHOLE allowance: the worst case for the work settle() does after it.
contract ClockBombWinner is IERC721Receiver {
    uint256 private immutable base;

    constructor(uint256 base_) {
        base = base_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 n = block.timestamp - base;
        assembly {
            revert(0, n)
        }
    }

    receive() external payable {}
}

/// @dev Hook records the gas it was handed, then accepts.
contract GasMeterWinner is IERC721Receiver {
    uint256 public seen = 1; // nonzero, so the write in the hook is a plain update

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        seen = gasleft();
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

contract PrizeGasMathReview is TestBase {
    VmGas private constant vmg = VmGas(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PRIZE_GAS = 1_000_000;
    uint256 private constant FLOOR = PRIZE_GAS + PRIZE_GAS / 63 + 50_000; // 1,065,873
    uint256 private constant SEPOLIA_PRIZE_GAS = 500_000;
    uint256 private constant SEPOLIA_FLOOR = SEPOLIA_PRIZE_GAS + SEPOLIA_PRIZE_GAS / 63 + 50_000; // 557,936
    // site/chain.js:25 after the change, and before it (the swarm still holds the old value in memory).
    uint256 private constant SETTLE_GAS = 1_400_000;
    uint256 private constant OLD_SETTLE_GAS = 1_200_000;
    uint256 private constant TX_GAS_CAP = 16_777_216; // EIP-7825
    // settle() as a transaction: 21,000 + 4 nonzero calldata bytes (selector 0x11da60b4) x 16.
    uint256 private constant INTRINSIC = 21_000 + 4 * 16;
    // EIP-8037/8038 Last Call (audit/tools-2026-10-12/ai-ethflow.md): cold new slot 110,020 vs 22,100;
    // cold first update of a nonzero slot 12,100 vs 5,000; warm EXTCODESIZE 200 vs 100.
    uint256 private constant NEW_SLOT_NOW = 22_100;
    uint256 private constant NEW_SLOT_LC = 110_020;
    uint256 private constant UPDATE_NOW = 5_000;
    uint256 private constant UPDATE_LC = 12_100;
    bytes32 private constant GUARD_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    address private constant EOA_WINNER = address(0xE0A0E0A0);

    KilimAuction internal aEoa;
    uint256 internal eoaClose;
    KilimAuction internal aBurn;
    ClockBurnWinner internal burnWinner;
    uint256 internal burnClose;
    KilimAuction internal aBomb;
    ClockBombWinner internal bombWinner;
    uint256 internal bombClose;
    KilimAuction internal aMeter;
    GasMeterWinner internal meter;
    uint256 internal meterClose;
    KilimAuctionSepolia500k internal aSep;
    uint256 internal sepClose;

    event log_named_uint(string key, uint256 value);
    event log_named_int(string key, int256 value);
    event log_string(string value);

    function setUp() public {
        aEoa = new KilimAuction(config());
        _openBidding(aEoa);
        _fund(EOA_WINNER, 1 ether);
        eoaClose = block.timestamp + aEoa.duration();
        _bid(aEoa, EOA_WINNER, RESERVE);
        assertEq(aEoa.endsAt(), eoaClose);

        aBurn = new KilimAuction(config());
        _openBidding(aBurn);
        burnClose = block.timestamp + aBurn.duration();
        burnWinner = new ClockBurnWinner(burnClose);
        _fund(address(burnWinner), 1 ether);
        vm.prank(address(burnWinner));
        aBurn.bid{value: RESERVE}(RESERVE, 0, 0);
        assertEq(aBurn.endsAt(), burnClose);

        aBomb = new KilimAuction(config());
        _openBidding(aBomb);
        bombClose = block.timestamp + aBomb.duration();
        bombWinner = new ClockBombWinner(bombClose);
        _fund(address(bombWinner), 1 ether);
        vm.prank(address(bombWinner));
        aBomb.bid{value: RESERVE}(RESERVE, 0, 0);
        assertEq(aBomb.endsAt(), bombClose);

        aMeter = new KilimAuction(config());
        _openBidding(aMeter);
        meter = new GasMeterWinner();
        _fund(address(meter), 1 ether);
        meterClose = block.timestamp + aMeter.duration();
        vm.prank(address(meter));
        aMeter.bid{value: RESERVE}(RESERVE, 0, 0);
        assertEq(aMeter.endsAt(), meterClose);

        KilimAuction.Config memory c = config();
        aSep = new KilimAuctionSepolia500k(
            KilimAuctionSepolia500k.Config({
                treasury: c.treasury,
                motifs: c.motifs,
                oneOfOne: c.oneOfOne,
                startsAt: c.startsAt,
                duration: c.duration,
                extensionWindow: c.extensionWindow,
                incrementBps: c.incrementBps,
                reservePrice: c.reservePrice,
                maxMotifsPerBid: c.maxMotifsPerBid
            })
        );
        _openBidding(KilimAuction(address(aSep)));
        sepClose = block.timestamp + aSep.duration();
        _bid(KilimAuction(address(aSep)), EOA_WINNER, RESERVE);
        assertEq(aSep.endsAt(), sepClose);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev One settle() with `gas` from the current (cold) state, rolled back.
    function _probe(address a, uint256 gas)
        private
        returns (bool ok, bool delivered, bytes memory data, uint256 remaining, uint256 used)
    {
        uint256 snap = vm.snapshotState();
        (ok, data) = a.call{gas: gas}(abi.encodeCall(EnglishAuction.settle, ()));
        VmGas.Gas memory g = vmg.lastCallGas();
        remaining = g.gasRemaining;
        used = g.gasTotalUsed;
        if (ok) {
            assertTrue(KilimAuction(a).settled());
            delivered = KilimAuction(a).prizeClaimed();
        } else {
            assertTrue(!KilimAuction(a).settled());
        }
        vm.revertToState(snap);
    }

    /// @dev The smallest call gas at which settle() succeeds, to one gas: what eth_estimateGas converges
    ///      to (less the intrinsic gas). Asserts one gas less fails with the auction's own InsufficientGas.
    function _minSettleGas(address a) private returns (uint256 hi) {
        uint256 lo = 200_000;
        hi = 3_000_000;
        (bool okLo,,,,) = _probe(a, lo);
        (bool okHi,,,,) = _probe(a, hi);
        assertTrue(!okLo && okHi);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,,,,) = _probe(a, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        (bool okBelow,, bytes memory data,,) = _probe(a, hi - 1);
        assertTrue(!okBelow);
        assertTrue(data.length == 4);
        assertEq(bytes32(data), bytes32(EnglishAuction.InsufficientGas.selector));
    }

    /// @dev The most gas the burn winner's hook may burn and still be delivered, cold, at 16M gas.
    function _maxBurnCold() private returns (uint256 lo) {
        lo = 800_000;
        uint256 hi = 950_000;
        vm.warp(burnClose + lo);
        (, bool dLo,,,) = _probe(address(aBurn), TX_GAS_CAP);
        vm.warp(burnClose + hi);
        (, bool dHi,,,) = _probe(address(aBurn), TX_GAS_CAP);
        assertTrue(dLo && !dHi);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.warp(burnClose + mid);
            (, bool d,,,) = _probe(address(aBurn), TX_GAS_CAP);
            if (d) lo = mid;
            else hi = mid;
        }
    }

    // ------------------------------------------------------------------ (a) the 63/64 arithmetic

    /// @dev The floor's 1/63 term is exact: PRIZE_GAS + PRIZE_GAS/63 is the least gas available at the CALL
    ///      for which EIP-150 (all but floor(a/64)) still hands the callee the full PRIZE_GAS. Same for 500k.
    function testFloorTermIsTheExact6364Minimum() public pure {
        assertEq(FLOOR, 1_065_873);
        assertEq(SEPOLIA_FLOOR, 557_936);
        uint256[2] memory caps = [PRIZE_GAS, SEPOLIA_PRIZE_GAS];
        for (uint256 i; i < 2; ++i) {
            uint256 p = caps[i];
            uint256 m = p + p / 63;
            assertTrue(m - m / 64 >= p); // enough
            assertTrue((m - 1) - (m - 1) / 64 < p); // one less is not
        }
        // So the full 50,000 is slack for the few hundred gas between the check and the CALL (EXTCODESIZE on
        // itself, the selector, the CALL's warm access) plus the work after the call; the callee's 1/64
        // remainder (15,873) also stays with settle().
    }

    // ------------------------------------------------------------------ (a) the estimate-style minimum

    /// @dev At the smallest gas that settles (what eth_estimateGas finds), the delivery call is made with
    ///      exactly 1,000,000 gas, and the EOA winner is delivered. One gas less is InsufficientGas.
    function testMinimalGasGivesTheDeliveryExactlyPrizeGas() public {
        vm.warp(eoaClose);
        uint256 g = _minSettleGas(address(aEoa));
        emit log_named_uint("EOA winner, cold: least call gas that settles", g);
        emit log_named_uint("  settle() work before the floor check (g - 1,065,873)", g - FLOOR);
        emit log_named_uint("  as a transaction (+21,064 intrinsic)", g + INTRINSIC);
        // The pre-check work is independent of the winner: floor-bound for every winner type below.
        assertTrue(g > FLOOR && g < FLOOR + 40_000);
        // Monotone, so a binary-searching estimator cannot land in a pocket: every limit below the minimum
        // (from 400,000) is the auction's own InsufficientGas, never a settlement.
        for (uint256 x = 400_000; x < g; x += (g - x > 300 ? 997 : 1)) {
            (bool okB,, bytes memory dataB,,) = _probe(address(aEoa), x);
            assertTrue(!okB);
            assertEq(bytes32(dataB), bytes32(EnglishAuction.InsufficientGas.selector));
        }
        vmg.expectCall(address(aEoa), 0, uint64(PRIZE_GAS), abi.encodeCall(KilimAuction.deliverPrize, ()));
        (bool ok,) = address(aEoa).call{gas: g}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok);
        assertTrue(aEoa.settled() && aEoa.prizeClaimed());
    }

    /// @dev The hook sees the same gas at every settle gas limit from the minimum to the 2^24 cap: the
    ///      delivery budget does not depend on the limit the settler (or a wallet's estimate) chose.
    function testHookSeesIdenticalGasAtEveryLimit() public {
        vm.warp(meterClose);
        uint256 g = _minSettleGas(address(aMeter));
        uint256 ref = _meterAt(TX_GAS_CAP);
        emit log_named_uint("gas the hook is handed (cold), at 16,777,216", ref);
        for (uint256 x = g; x < g + 300; ++x) {
            assertEq(_meterAt(x), ref);
        }
        for (uint256 x = g + 300; x < g + 120_000; x += 397) {
            assertEq(_meterAt(x), ref);
        }
        for (uint256 x = g + 120_000; x < TX_GAS_CAP; x += 499_979) {
            assertEq(_meterAt(x), ref);
        }
    }

    function _meterAt(uint256 gas) private returns (uint256 seen) {
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(aMeter).call{gas: gas}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok);
        assertTrue(aMeter.prizeClaimed());
        seen = meter.seen();
        vm.revertToState(snap);
    }

    /// @dev A winner whose hook needs the whole cold budget to the gas: delivered at the estimate-style
    ///      minimum and at every limit above it; one gas more of need fails at the minimum AND at 16M. So no
    ///      gas limit that settles can turn a deliverable winner into a PrizeDeliveryFailed.
    function testOneGasEdgeWinnerOutcomeIsTheSameAtEveryLimitThatSettles() public {
        uint256 maxBurn = _maxBurnCold();
        emit log_named_uint("cold hook budget (most a hook may burn and be delivered)", maxBurn);
        emit log_named_uint("cold delivery overhead (1,000,000 - budget)", PRIZE_GAS - maxBurn);

        vm.warp(burnClose + maxBurn);
        uint256 g = _minSettleGas(address(aBurn));
        if (block.timestamp < eoaClose) vm.warp(eoaClose);
        // The same floor-bound minimum as the EOA winner (the pre-check work does not see the winner).
        uint256 gEoa = _minSettleGas(address(aEoa));
        emit log_named_uint("least call gas, edge winner", g);
        emit log_named_uint("least call gas, EOA winner", gEoa);
        assertEq(g, gEoa);

        vm.warp(burnClose + maxBurn);
        for (uint256 x = g; x < g + 200; ++x) {
            (bool ok, bool d,,,) = _probe(address(aBurn), x);
            assertTrue(ok && d);
        }
        for (uint256 x = g + 200; x < g + 100_000; x += 409) {
            (bool ok, bool d,,,) = _probe(address(aBurn), x);
            assertTrue(ok && d);
        }
        for (uint256 x = g + 100_000; x <= TX_GAS_CAP; x += 1_111_111) {
            (bool ok, bool d,,,) = _probe(address(aBurn), x);
            assertTrue(ok && d);
        }
        vmg.expectCall(address(aBurn), 0, uint64(PRIZE_GAS), abi.encodeCall(KilimAuction.deliverPrize, ()));
        {
            (bool ok,) = address(aBurn).call{gas: g}(abi.encodeCall(EnglishAuction.settle, ()));
            assertTrue(ok && aBurn.prizeClaimed());
        }
    }

    function testOneGasOverTheBudgetFailsAtEveryLimitAlike() public {
        uint256 maxBurn = _maxBurnCold();
        vm.warp(burnClose + maxBurn + 1);
        uint256 g = _minSettleGas(address(aBurn));
        (bool ok1, bool d1,,,) = _probe(address(aBurn), g);
        (bool ok2, bool d2,,,) = _probe(address(aBurn), TX_GAS_CAP);
        assertTrue(ok1 && ok2 && !d1 && !d2);
    }

    // ------------------------------------------------------------------ (b) the work after the call

    /// @dev Worst case for the 50,000: the delivery self-call consumes its whole 1,000,000 (the frame runs
    ///      out of gas bubbling a revert bomb). settle() still succeeds at the same floor-bound minimum, and
    ///      the gas left over at that minimum is the room the post-call work has before the floor would stop
    ///      being the binding constraint.
    function testPostCallReserveWhenTheDeliveryEatsItsWholeAllowance() public {
        uint256[5] memory sizes = [uint256(350_000), 360_000, 380_000, 400_000, 420_000];
        uint256 maxUsed;
        uint256 atMax;
        uint256 saturated;
        for (uint256 i; i < sizes.length; ++i) {
            vm.warp(bombClose + sizes[i]);
            (bool ok, bool d,,, uint256 used) = _probe(address(aBomb), TX_GAS_CAP);
            assertTrue(ok && !d);
            emit log_named_uint("bomb bytes", sizes[i]);
            emit log_named_uint("  settle gas used at 16M", used);
            if (used > maxUsed) {
                maxUsed = used;
                atMax = sizes[i];
                saturated = 1;
            } else if (used == maxUsed) {
                ++saturated;
            }
        }
        // Several sizes use exactly the same gas: the self-call hit its cap (it cannot use more than 1M).
        assertTrue(saturated >= 2);
        vm.warp(bombClose + atMax);
        uint256 g = _minSettleGas(address(aBomb));
        (bool ok2, bool d2,, uint256 left, uint256 usedAtMin) = _probe(address(aBomb), g);
        assertTrue(ok2 && !d2);
        assertEq(usedAtMin, maxUsed); // the outcome and cost do not depend on the limit
        uint256 pre = g - FLOOR; // settle()'s own work before gasleft() is read in the check
        // used = pre + (check..CALL) + 1,000,000 + (after the call); so after-call work incl. the call setup:
        uint256 post = maxUsed - pre - PRIZE_GAS;
        emit log_named_uint("least call gas, worst-case bomb winner", g);
        emit log_named_uint("work from the check to the end, besides the 1,000,000 (Cancun)", post);
        emit log_named_uint("gas left over at the least gas that settles", left);
        // The design keeps 50,000 + 15,873 for this; it uses a few thousand.
        assertTrue(post < 5_000);
        assertTrue(left + post >= FLOOR - PRIZE_GAS - 2); // left = 65,873 - post (to the gas)
        // At Last Call prices the only repriced operation in that stretch is the warm EXTCODESIZE before the
        // CALL (+100; LOG, warm SLOAD, warm CALL and a dirty-slot SSTORE are unchanged), see the write list.
        assertTrue(post + 100 < 50_000);
        // Same minimum as the EOA winner: even the worst case is bound by the floor, not by the post-call work.
        if (block.timestamp < eoaClose) vm.warp(eoaClose);
        assertEq(g, _minSettleGas(address(aEoa)));
    }

    /// @dev Which storage settle() writes and where: the only zero-to-nonzero write (a new slot, the one the
    ///      repricing hits hardest) is proceedsDue, before the floor check; the only write after the delivery
    ///      call is the guard's 2 -> 1, a restore of a dirty slot to its original value (100 gas in both
    ///      schedules). Checked on the failing-delivery path (the catch) and the delivered path.
    function testOnlyTheGuardRestoreIsWrittenAfterTheDelivery() public {
        // failing path: bomb winner
        vm.warp(bombClose + 400_000);
        _checkWrites(address(aBomb), false);
        // delivered path: EOA winner
        if (block.timestamp < eoaClose) vm.warp(eoaClose);
        _checkWrites(address(aEoa), true);
    }

    function _checkWrites(address a, bool expectDelivered) private {
        uint256 snap = vm.snapshotState();
        vmg.record();
        (bool ok,) = a.call{gas: TX_GAS_CAP}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok);
        assertTrue(KilimAuction(a).prizeClaimed() == expectDelivered);
        (, bytes32[] memory writes) = vmg.accesses(a);
        vm.revertToState(snap);
        emit log_named_uint("SSTOREs at the auction's address during settle()", writes.length);
        for (uint256 i; i < writes.length; ++i) {
            emit log_named_uint("  slot", uint256(writes[i]));
        }
        // guard enter, settled (packed with highestBidder), proceedsDue, prizeClaimed (inside deliverPrize,
        // reverted on the failing path), guard exit.
        assertEq(writes.length, 5);
        assertEq(writes[0], GUARD_SLOT);
        assertEq(writes[4], GUARD_SLOT);
        // Values before settle(): guard 1 (nonzero: first update), slot of `settled` nonzero (highestBidder
        // shares it: first update), proceedsDue 0 (NEW slot), prizeClaimed 0 (new slot, inside the 1,000,000).
        assertEq(vmg.load(a, writes[0]), bytes32(uint256(1)));
        assertTrue(vmg.load(a, writes[1]) != bytes32(0));
        assertEq(vmg.load(a, writes[2]), bytes32(0));
        assertEq(vmg.load(a, writes[3]), bytes32(0));
        // writes[3] is the delivery's own write (prizeClaimed): its slot holds the flag after a delivery.
        if (expectDelivered) {
            uint256 snap2 = vm.snapshotState();
            (bool ok2,) = a.call(abi.encodeCall(EnglishAuction.settle, ()));
            assertTrue(ok2);
            assertTrue(vmg.load(a, writes[3]) != bytes32(0));
            assertEq(vmg.load(a, writes[0]), bytes32(uint256(1))); // restored to its original value
            vm.revertToState(snap2);
        }
    }

    // ------------------------------------------------------------------ (c) SETTLE_GAS, both pricings

    /// @dev The implementer's "cold" 1,102,637 is 2,000 below the truly cold minimum: it matches a settle()
    ///      whose endsAt slot was already warm (one cold SLOAD, 2,100 vs 100). A real transaction without an
    ///      access list starts with every slot cold.
    function testDocumentedMinimumHadOneWarmSlot() public {
        vm.warp(eoaClose);
        uint256 cold = _minSettleGas(address(aEoa));
        aEoa.endsAt(); // warms slot 4 (endsAt) for the rest of this test transaction
        uint256 warmEndsAt = _minSettleGas(address(aEoa));
        emit log_named_uint("least call gas, all cold", cold);
        emit log_named_uint("least call gas, endsAt slot warm", warmEndsAt);
        assertEq(cold, 1_104_637);
        assertEq(warmEndsAt, 1_102_637);
        assertEq(cold - warmEndsAt, 2_000);
        // And repeated probes from the snapshot really are cold (no warm state leaks between probes).
        (,,,, uint256 u1) = _probe(address(aBomb), TX_GAS_CAP);
        (,,,, uint256 u2) = _probe(address(aBomb), TX_GAS_CAP);
        assertEq(u1, u2);
    }

    function testSettleGasCoversBothPricingsAndSepolia() public {
        vm.warp(eoaClose);
        uint256 g = _minSettleGas(address(aEoa));
        uint256 txNow = g + INTRINSIC;
        // Before the floor: guard 1->2 (cold first update), settled slot (cold first update), proceedsDue
        // (cold new slot); testOnlyTheGuardRestoreIsWrittenAfterTheDelivery pins exactly these.
        uint256 extraLc = (NEW_SLOT_LC - NEW_SLOT_NOW) + 2 * (UPDATE_LC - UPDATE_NOW);
        uint256 txLc = txNow + extraLc;
        emit log_named_uint("mainnet auction: settle tx need, Cancun", txNow);
        emit log_named_uint("mainnet auction: settle tx need, Last Call", txLc);
        emit log_named_uint("SETTLE_GAS margin over Cancun need", SETTLE_GAS - txNow);
        emit log_named_uint("SETTLE_GAS margin over Last Call need", SETTLE_GAS - txLc);
        assertTrue(SETTLE_GAS > txLc);
        assertTrue(SETTLE_GAS < TX_GAS_CAP);
        // The old 1,200,000 would NOT reach the new floor at Last Call prices (negative margin).
        emit log_named_int("old 1,200,000 margin at Last Call (new floor)", int256(OLD_SETTLE_GAS) - int256(txLc));
        assertTrue(OLD_SETTLE_GAS < txLc);
        // New-slot price at which SETTLE_GAS stops reaching the floor (first-update price held at Last Call).
        uint256 preNow = txNow - FLOOR; // tx-level work before the check, Cancun
        uint256 breakSlot = SETTLE_GAS - FLOOR - (preNow - NEW_SLOT_NOW) - 2 * (UPDATE_LC - UPDATE_NOW);
        emit log_named_uint("new-slot price at which 1,400,000 stops reaching the floor", breakSlot);

        // Sepolia (deployed with 500,000): same pre-check code, floor 557,936.
        vm.warp(sepClose);
        uint256 gs = _minSettleGas(address(aSep));
        emit log_named_uint("Sepolia-500k auction: least call gas, cold", gs);
        emit log_named_uint("  pre-check work", gs - SEPOLIA_FLOOR);
        assertEq(gs - SEPOLIA_FLOOR, g - FLOOR); // identical pre-check work
        uint256 sepLc = gs + INTRINSIC + extraLc; // Sepolia runs Glamsterdam since 6 October
        emit log_named_uint("Sepolia settle tx need at Last Call prices", sepLc);
        assertTrue(sepLc < SETTLE_GAS && sepLc < OLD_SETTLE_GAS);
        // And the Sepolia auction at SETTLE_GAS settles and delivers to its EOA winner (Cancun here).
        (bool ok, bool d,,,) = _probe(address(aSep), SETTLE_GAS);
        assertTrue(ok && d);
    }
}
