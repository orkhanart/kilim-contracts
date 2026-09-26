// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Kilim} from "../../src/Kilim.sol";

contract Receiver is IERC721Receiver {
    bool public rejecting;
    address public target;
    bytes public payload;
    bool public callbackSucceeded;
    uint256 public received;
    bool public inspectArtwork;

    function configure(bool reject_, address target_, bytes calldata payload_) external {
        rejecting = reject_;
        target = target_;
        payload = payload_;
    }

    function setInspectArtwork(bool flag) external {
        inspectArtwork = flag;
    }

    function execute(address target_, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory result) = target_.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(!rejecting, "NFT rejected");
        ++received;
        if (inspectArtwork) {
            Kilim nft = Kilim(msg.sender);
            Kilim.ArtworkData memory art = nft.artworkData(tokenId);
            require(art.revision == 1 && art.cells.length >= 4, "incomplete artwork");
            for (uint256 i; i < art.cells.length; ++i) {
                require(nft.symbolData(art.cells[i]).consumedBy == tokenId, "unburned source");
            }
        }
        if (target != address(0)) (callbackSucceeded,) = target.call(payload);
        return IERC721Receiver.onERC721Received.selector;
    }
}
