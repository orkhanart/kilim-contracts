// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev An NFT receiver that burns all the gas it is given, to grief a delivery.
contract GasBurner {
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        while (gasleft() > 0) {}
        return this.onERC721Received.selector;
    }
}
