// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract Receiver is IERC721Receiver {
    bool public rejecting;
    address public target;
    bytes public payload;
    bool public callbackSucceeded;
    uint256 public received;

    function configure(bool reject_, address target_, bytes calldata payload_) external {
        rejecting = reject_;
        target = target_;
        payload = payload_;
    }

    function execute(address target_, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory result) = target_.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejecting, "NFT rejected");
        ++received;
        if (target != address(0)) (callbackSucceeded,) = target.call(payload);
        return IERC721Receiver.onERC721Received.selector;
    }
}
