// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";

/// @dev Bids and claims for itself, checking the auction's credit views from inside each mint callback.
contract RangeInspector is IERC721Receiver {
    KilimAuction public immutable auction;

    constructor(KilimAuction auction_) {
        auction = auction_;
    }

    function execute(address target, bytes calldata data) external {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        KilimAuction.CreditRange[] memory ranges = auction.unclaimedGlyphRanges(address(this));
        uint256 total;
        for (uint256 i; i < ranges.length; ++i) {
            require(ranges[i].remaining != 0, "exhausted range visible in callback");
            total += ranges[i].remaining;
        }
        require(total == auction.glyphCredits(address(this)), "ranges differ from credits in callback");
        return IERC721Receiver.onERC721Received.selector;
    }
}
