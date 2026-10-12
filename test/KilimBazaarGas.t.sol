// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase} from "./bazaar/BazaarBase.sol";

/// @notice Gas, on the Cancun schedule of this repo's foundry.toml, with the contracts the call touches made
///         cold first (vm.cool) so each call is priced as its own transaction would be. Figures are gross
///         execution (refunds are not subtracted) plus the intrinsic cost of the calldata. Ceilings are the
///         spec's (section 8.7); every figure is logged (forge test -vv) for the published gas table.
contract KilimBazaarGasTest is BazaarBase {
    uint256 internal constant B = 3_000_000;
    /// Ids for fresh-bucket batches: one id per untouched 256-id `_burned` bucket.
    uint256 internal constant FRESH_BASE = 600_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
        _standard();
        _settle(10 ether);
    }

    function _cool() internal {
        vmb.cool(address(bazaar));
        vmb.cool(address(motifs));
        vmb.cool(address(auction));
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev One call as its own transaction: execution with everything it touches cold, plus the intrinsic cost.
    function _tx(address from, bytes memory data) internal returns (uint256 execution, uint256 total) {
        _cool();
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(bazaar).call(data);
        execution = g - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        total = execution + _intrinsic(data);
    }

    function _report(string memory what, uint256 n, uint256 total) internal view {
        _log(
            string.concat(
                what,
                ": ",
                vm.toString(total),
                " gas",
                n == 0 ? "" : string.concat(" (", vm.toString(total / n), " per motif)")
            )
        );
    }

    /// @dev `n` ids, each the first in its own untouched bucket.
    function _freshBuckets(address to, uint256 n) internal returns (uint256[] memory list) {
        list = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = FRESH_BASE + (nextFresh++) * 256;
            _give(to, list[i], 1);
        }
        _approve(to);
    }

    uint256 internal nextFresh;

    function _weaveTx(address holder, uint256[] memory list) internal returns (uint256 total) {
        (, total) = _tx(holder, abi.encodeCall(KilimBazaar.make, (list, holder)));
    }

    function _depositTx(address holder, uint256[] memory list) internal returns (uint256 total) {
        (, total) = _tx(holder, abi.encodeCall(KilimBazaar.deposit, (list)));
    }

    // ------------------------------------------------------------ one call

    function testWeaveGasAt10_30_100_300And1000() public {
        uint256[5] memory sizes = [uint256(10), 30, 100, 300, 1000];
        uint256[5] memory totals;
        for (uint256 i; i < sizes.length; ++i) {
            // a first kilim each time, from consecutive (market-like, started-bucket after the first) ids
            address holder = address(uint160(0xA000 + i));
            totals[i] = _weaveTx(holder, _fresh(holder, sizes[i]));
            KilimBazaar.Kilim memory k = bazaar.kilim(bazaar.totalSupply());
            _report(
                string.concat(
                    "make ",
                    vm.toString(sizes[i]),
                    " consecutive ids (",
                    bazaar.rankName(k.rank),
                    k.flags & bazaar.PACKED() != 0 ? ", PACKED" : ", DENSE",
                    ")"
                ),
                sizes[i],
                totals[i]
            );
        }
        assertTrue(totals[0] < 500_000);
        _log(string.concat("  slope 10 -> 300: ", vm.toString((totals[3] - totals[0]) / 290), " per motif"));
        _log(string.concat("  slope 300 -> 1000: ", vm.toString((totals[4] - totals[3]) / 700), " per motif"));
    }

    /// @dev The spec's 0.5M ceiling for an Apprentice is for market ids, whose buckets are started (the test
    ///      above, < 0.5M); ten ids that each start a bucket pay about 20,000 more apiece.
    function testWeave10And300FromFreshBuckets() public {
        uint256 t10 = _weaveTx(ALICE, _freshBuckets(ALICE, 10));
        _report("make 10, every id in an untouched bucket", 10, t10);
        assertTrue(t10 < 750_000);
        uint256 t300 = _weaveTx(BOB, _freshBuckets(BOB, 300));
        _report("make 300, every id in an untouched bucket", 300, t300);
        assertTrue(t300 < 15_000_000);
    }

    // ------------------------------------------------------------ the loom

    function testDepositGas() public {
        // 300 fresh-bucket ids opening a loom
        uint256 open = _depositTx(ALICE, _freshBuckets(ALICE, 300));
        _report("deposit 300 fresh-bucket ids, opening a loom", 300, open);
        assertTrue(open < 15_000_000);
        // 300 more into the open loom
        uint256 more = _depositTx(ALICE, _freshBuckets(ALICE, 300));
        _report("deposit 300 fresh-bucket ids into an open loom", 300, more);
        // close it
        (, uint256 close) = _tx(ALICE, abi.encodeCall(KilimBazaar.makeFromLoom, (new uint256[](0), ALICE)));
        _report("makeFromLoom([]) of 600", 0, close);
        assertTrue(close < 150_000);
    }

    /// @dev 600 ids whose buckets were already started by an earlier burn, and 760 consecutive ids.
    function testDepositsOf600StartedBucketIdsAnd760ConsecutiveFit16M() public {
        // start 600 buckets: burn one id in each (BOB), then deposit another id from each (ALICE)
        uint256[] memory starters = new uint256[](600);
        uint256[] memory list = new uint256[](600);
        for (uint256 i; i < 600; ++i) {
            starters[i] = FRESH_BASE + i * 256;
            list[i] = starters[i] + 1;
            _give(BOB, starters[i], 2);
        }
        _approve(BOB);
        vm.prank(BOB);
        bazaar.deposit(_slice(starters, 0, 300));
        vm.prank(BOB);
        bazaar.deposit(_slice(starters, 300, 600));
        for (uint256 i; i < 600; ++i) {
            vm.prank(BOB);
            motifs.transferFrom(BOB, ALICE, list[i]);
        }
        _approve(ALICE);
        uint256 started = _depositTx(ALICE, list);
        _report("deposit 600 ids in started buckets, opening a loom", 600, started);
        assertTrue(started < 16_000_000);
        uint256 consecutive = _depositTx(CAROL, _fresh(CAROL, 760));
        _report("deposit 760 consecutive ids, opening a loom", 760, consecutive);
        assertTrue(consecutive < 16_000_000);
    }

    /// @dev A Master of 10,000 at a 10 ETH close, gathered in 34 deposits of up to 300 and closed with
    ///      makeFromLoom([]): the whole cost of the top kilim, however the motifs were claimed.
    function testALargeLoomOfTenThousand() public {
        uint256[] memory all = _fresh(ALICE, 10_000);
        uint256 total;
        uint256 first;
        uint256 heaviest;
        uint256 txs;
        for (uint256 pos; pos < all.length; pos += 300) {
            uint256 to = pos + 300 < all.length ? pos + 300 : all.length;
            uint256 g = _depositTx(ALICE, _slice(all, pos, to));
            if (pos == 0) first = g;
            if (g > heaviest) heaviest = g;
            total += g;
            ++txs;
        }
        (, uint256 close) = _tx(ALICE, abi.encodeCall(KilimBazaar.makeFromLoom, (new uint256[](0), ALICE)));
        total += close;
        ++txs;
        KilimBazaar.Kilim memory k = bazaar.kilim(1);
        assertEq(k.count, 10_000);
        assertEq(k.rank, 6);
        (uint256 title, uint256 distinct) = _title(_counts(all));
        assertEq(k.distinct, distinct);
        assertEq(k.title, title);
        assertTrue((k.flags & bazaar.WHOLE() != 0) == (distinct == 1024));
        _report(string.concat("Master of 10,000 in ", vm.toString(txs), " transactions"), 10_000, total);
        _report("  the opening deposit of 300", 300, first);
        _report("  the heaviest deposit", 300, heaviest);
        _report("  makeFromLoom([]) of 10,000", 0, close);
        assertTrue(heaviest < 15_000_000);
        assertTrue(close < 150_000);
    }

    // ------------------------------------------------------------ seal, read, deploy

    function testSealGas() public {
        uint256[] memory one = new uint256[](1);
        uint256[] memory many = new uint256[](500);
        for (uint256 i; i < 501; ++i) {
            address holder = address(uint160(0xB000 + i));
            _make(holder, _fresh(holder, 10));
        }
        vm.roll(B + 2);
        one[0] = 1;
        for (uint256 i; i < 500; ++i) {
            many[i] = i + 2;
        }
        (uint256 exec, uint256 single) = _tx(CAROL, abi.encodeCall(KilimBazaar.seal, (one)));
        _report("seal, one kilim", 0, single);
        _log(string.concat("  execution only: ", vm.toString(exec)));
        assertTrue(single < 40_000);
        (, uint256 batch) = _tx(CAROL, abi.encodeCall(KilimBazaar.seal, (many)));
        _report("seal, 500 kilims in one call", 0, batch);
        assertTrue(batch < 16_700_000);
        _log(string.concat("  per kilim: ", vm.toString(batch / 500)));
        assertEq(bazaar.sealState(501), 4);
    }

    function testSealGasOnTheHistoryPathAndAReArm() public {
        vmb.etch(HISTORY, HISTORY_CODE);
        _deployBazaar();
        _make(ALICE, _fresh(ALICE, 10));
        _make(BOB, _fresh(BOB, 10));
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.roll(B + 1 + 300);
        vmb.store(HISTORY, bytes32(uint256(B + 1) % 8191), keccak256("h"));
        vmb.cool(HISTORY);
        (, uint256 history) = _tx(CAROL, abi.encodeCall(KilimBazaar.seal, (one)));
        _report("seal, one kilim, from the EIP-2935 history", 0, history);
        assertTrue(history < 40_000);
        one[0] = 2;
        vm.roll(B + 1 + 9000);
        (, uint256 rearm) = _tx(CAROL, abi.encodeCall(KilimBazaar.seal, (one)));
        _report("seal, one kilim, re-arm", 0, rearm);
        assertTrue(rearm < 40_000);
        assertEq(bazaar.sealState(2), 1);
    }

    function testDeploymentGasAndRuntimeSize() public {
        bytes memory args =
            abi.encode(auction, ARTIST, oneOfOne.tailHash(), BAZAAR_DESCRIPTION, BAZAAR_URL, "");
        uint256 g = gasleft();
        KilimBazaar b = _newBazaar("", BAZAAR_URL);
        g -= gasleft();
        bytes memory creation = bytes.concat(type(KilimBazaar).creationCode, args);
        // `new` already paid CREATE's 32,000; add the transaction's 21,000, the calldata and the initcode words.
        uint256 intrinsic = _intrinsic(creation) + 2 * ((creation.length + 31) / 32);
        uint256 total = g + intrinsic;
        _log(
            string.concat(
                "deployment: ",
                vm.toString(total),
                " gas; runtime ",
                vm.toString(address(b).code.length),
                " bytes"
            )
        );
        assertTrue(total < 8_000_000);
        assertTrue(address(b).code.length <= 24_576);
        assertTrue(address(bazaar).code.length <= 24_576);
    }

    function testReadGasOfASealedApprentice() public {
        _make(ALICE, _fresh(ALICE, 10));
        vm.roll(B + 2);
        bazaar.seal(ids(1, 1));
        _cool();
        vmb.cool(address(oneOfOne));
        bytes memory data = abi.encodeCall(bazaar.tokenURI, (1));
        address target = address(bazaar);
        bool ok;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        assertTrue(ok);
        _log(string.concat("tokenURI, sealed Apprentice (committed page store): ", vm.toString(g)));
        assertTrue(g < 8_000_000);
    }
}
