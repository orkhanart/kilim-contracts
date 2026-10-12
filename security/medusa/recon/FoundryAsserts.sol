// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Asserts} from "../lib/chimera/src/Asserts.sol";

/// @notice Chimera's Asserts for Foundry without forge-std (this repo does not vendor it; Chimera's own
///         FoundryAsserts inherits forge-std's Test). A failed check reverts with its reason: the Foundry
///         run keeps the repo's `fail_on_revert = true`, so a failed handler check fails the invariant run,
///         and the handlers are written never to revert otherwise.
abstract contract FoundryAsserts is Asserts {
    function gt(uint256 a, uint256 b, string memory reason) internal virtual override {
        require(a > b, reason);
    }

    function gte(uint256 a, uint256 b, string memory reason) internal virtual override {
        require(a >= b, reason);
    }

    function lt(uint256 a, uint256 b, string memory reason) internal virtual override {
        require(a < b, reason);
    }

    function lte(uint256 a, uint256 b, string memory reason) internal virtual override {
        require(a <= b, reason);
    }

    function eq(uint256 a, uint256 b, string memory reason) internal virtual override {
        require(a == b, reason);
    }

    function t(bool b, string memory reason) internal virtual override {
        require(b, reason);
    }

    function between(uint256 value, uint256 low, uint256 high) internal virtual override returns (uint256) {
        if (value < low || value > high) return low + (value % (high - low + 1));
        return value;
    }

    function between(int256 value, int256 low, int256 high) internal virtual override returns (int256) {
        if (value < low || value > high) {
            int256 range = high - low + 1;
            int256 clamped = (value - low) % range;
            if (clamped < 0) clamped += range;
            return low + clamped;
        }
        return value;
    }

    function precondition(bool p) internal virtual override {
        require(p);
    }
}
