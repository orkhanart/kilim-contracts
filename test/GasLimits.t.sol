// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";

contract GasLimitsTest is TestBase {
    event log_named_uint(string key, uint256 value);
    Kilim internal nft;

    function setUp() public {
        nft = new Kilim(
            address(this), ALICE, TREASURY, 2048, 812, 256, bytes32(uint256(1)), bytes32(uint256(1))
        );
        for (uint256 i; i < 4; ++i) {
            mintNext(nft, ALICE, ALICE, 64);
        }
    }

    function testGas256CellWeave() public {
        uint256[] memory cells = ids(2, 256);
        vm.prank(ALICE);
        uint256 start = gasleft();
        nft.weave(cells, 16, 16, bytes32(0));
        uint256 used = start - gasleft();
        emit log_named_uint("256-cell weave execution gas (before refunds)", used);
        assertTrue(used < 11_000_000); // well under the 16,777,216 per-transaction cap
    }

    function testGasExpandToMaximumCanvas() public {
        vm.prank(ALICE);
        uint256 art = nft.weave(ids(2, 4), 2, 2, bytes32(0));
        uint256[] memory cells = ids(2, 256);
        vm.prank(ALICE);
        uint256 start = gasleft();
        nft.expand(art, 1, cells, 16, 16, bytes32(0));
        uint256 used = start - gasleft();
        emit log_named_uint("4-to-256-cell expansion execution gas (before refunds)", used);
        assertTrue(used < 11_000_000);
    }

    function testGas64SymbolClaim() public {
        uint256 first = nft.FIRST_SYMBOL_ID() + nft.symbolsMinted();
        uint256 start = gasleft();
        nft.mintSymbols(BOB, BOB, first, 64);
        uint256 used = start - gasleft();
        emit log_named_uint("64-symbol mint execution gas (before refunds)", used);
        assertTrue(used < 2_500_000); // traits are computed, not stored
    }
}
