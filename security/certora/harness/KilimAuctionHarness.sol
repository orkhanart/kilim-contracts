// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "kilim/KilimAuction.sol";

/// @notice Verification harness only. It adds read-only views; it changes no behaviour of KilimAuction.
/// @dev Not deployed. Lives outside src/ so the code freeze is untouched.
contract KilimAuctionHarness is KilimAuction {
    constructor(Config memory config) KilimAuction(config) {}

    /// @dev OpenZeppelin's guard state, which the parent keeps internal.
    function harnessGuardEntered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @dev The unchanged upstream bid predicate, as _handleBid applies it to `amount` right now.
    function harnessIsNewWinningBid(uint256 amount) external view returns (bool) {
        return _isNewWinningBid(reservePrice, highestBid, amount, incrementBps);
    }
}
