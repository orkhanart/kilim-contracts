// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimBazaar} from "kilim/KilimBazaar.sol";
import {KilimAuction} from "kilim/KilimAuction.sol";

/// @notice Verification harness only: KilimBazaar unchanged, plus read-only views of private state.
/// @dev Not deployed. Lives outside src/ so the code freeze is untouched.
contract KilimBazaarHarness is KilimBazaar {
    constructor(
        KilimAuction auction_,
        address royaltyReceiver_,
        bytes32 pageTailHash_,
        string memory description_,
        string memory externalUrl_,
        string memory imageBase_
    ) KilimBazaar(auction_, royaltyReceiver_, pageTailHash_, description_, externalUrl_, imageBase_) {}
}
