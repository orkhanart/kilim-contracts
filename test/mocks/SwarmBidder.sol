// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice A contract wallet for the Sepolia swarm test (scripts/sepolia-swarm.mjs). Its owner bids and
///         claims through exec(). It has no receive function, so an outbid refund to it cannot be pushed:
///         the auction defers it (RefundDeferred) and the owner withdraws it with withdrawRefund. It
///         accepts ERC-721 tokens, so its motifs can be claimed to itself.
contract SwarmBidder is IERC721Receiver {
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address target, bytes calldata data) external payable returns (bytes memory result) {
        require(msg.sender == owner, "owner only");
        bool ok;
        (ok, result) = target.call{value: msg.value}(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
