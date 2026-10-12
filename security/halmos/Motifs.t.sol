// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {HalmosBase} from "./HalmosBase.sol";

/// @notice KilimMotifs supply arithmetic for ALL first ids and quantities: the id range check, the burned
///         bitmap, and that no id is ever minted twice. Mainnet cap (1,000,000); the test contract is the minter.
contract MotifsHalmos is HalmosBase {
    uint256 internal constant CAP = 1_000_000;
    address internal constant R = address(0xBEEF);
    KilimMotifs internal motifs;

    function setUp() public {
        motifs = newMotifs(address(this), CAP);
    }

    function _exists(uint256 id) internal view returns (bool ok) {
        (ok,) = address(motifs).staticcall(abi.encodeCall(motifs.ownerOf, (id)));
    }

    function _mint(uint256 first, uint256 q) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(motifs).call(abi.encodeCall(motifs.mintMotifs, (R, R, first, q)));
    }

    /// @dev SupplyExceeded exactly when [firstId, firstId + quantity - 1] leaves 1..cap; inside, the whole
    ///      range is minted to the recipient and nothing next to it. quantity 1..64 (MAX_MINT_BATCH).
    function check_mint_rangeExact(uint256 firstId, uint256 quantity) public {
        vm.assume(quantity >= 1 && quantity <= 64);
        bool inRange = firstId >= 1 && firstId <= CAP && quantity <= CAP - firstId + 1;
        (bool ok, bytes memory ret) = _mint(firstId, quantity);
        if (!inRange) {
            assert(!ok && _sel(ret) == KilimMotifs.SupplyExceeded.selector);
            assert(motifs.motifsMinted() == 0);
        } else {
            assert(ok);
            assert(motifs.motifsMinted() == quantity && motifs.balanceOf(R) == quantity);
            assert(motifs.ownerOf(firstId) == R && motifs.ownerOf(firstId + quantity - 1) == R);
            assert(!_exists(firstId - 1));
            assert(!_exists(firstId + quantity));
        }
    }

    function check_mint_quantityLimits(uint256 firstId, uint256 quantity) public {
        vm.assume(quantity == 0 || quantity > 64);
        (bool ok, bytes memory ret) = _mint(firstId, quantity);
        assert(!ok && _sel(ret) == KilimMotifs.InvalidQuantity.selector);
    }

    function check_mint_onlyMinter(address caller, uint256 firstId, uint256 quantity) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        (bool ok, bytes memory ret) = _mint(firstId, quantity);
        assert(!ok && _sel(ret) == KilimMotifs.Unauthorized.selector);
    }

    /// @dev Two mints: the second succeeds exactly when its range misses the first's (AlreadyMinted
    ///      otherwise). Quantities 1..4.
    function check_mint_neverTwice(uint256 f1, uint256 q1, uint256 f2, uint256 q2) public {
        vm.assume(q1 >= 1 && q1 <= 4 && q2 >= 1 && q2 <= 4);
        vm.assume(f1 >= 1 && f1 <= CAP + 1 - q1 && f2 >= 1 && f2 <= CAP + 1 - q2);
        (bool ok1,) = _mint(f1, q1);
        assert(ok1);
        bool overlap = f2 < f1 + q1 && f1 < f2 + q2;
        (bool ok2, bytes memory ret) = _mint(f2, q2);
        assert(ok2 == !overlap);
        if (!ok2) assert(_sel(ret) == KilimMotifs.AlreadyMinted.selector);
        assert(motifs.motifsMinted() == q1 + (ok2 ? q2 : 0));
    }

    /// @dev The burned bitmap marks exactly the burned id, which then can never be minted again, while
    ///      every other id is unaffected. Only the owner can burn; approval is not enough.
    function check_burn_bitmapExact(uint256 id, uint256 other, address approved) public {
        vm.assume(id >= 1 && id <= CAP);
        (bool ok,) = _mint(id, 1);
        assert(ok);
        vm.assume(approved != R);
        vm.prank(R);
        motifs.approve(approved, id);
        vm.prank(approved);
        (bool okApproved,) = address(motifs).call(abi.encodeCall(motifs.burn, (id)));
        assert(!okApproved);
        vm.prank(R);
        motifs.burn(id);
        assert(motifs.burned(id));
        assert(motifs.burned(other) == (other == id));
        assert(motifs.motifsBurned() == 1);
        assert(!_exists(id));
        (bool again, bytes memory ret) = _mint(id, 1);
        assert(!again && _sel(ret) == KilimMotifs.AlreadyMinted.selector);
        if (other != id && other >= 1 && other <= CAP) {
            (bool okOther,) = _mint(other, 1);
            assert(okOther);
        }
    }
}
