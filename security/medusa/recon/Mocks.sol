// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";

/// @dev A contract wallet whose ETH and NFT receivers change mood on demand:
///      ACCEPT takes it, REJECT reverts, BURN spins until the gas runs out, REENTER first tries to call
///      back into the contract that is paying it (every such call must hit that contract's guard) and
///      then takes it. It can also approve ERC-1271 registration signatures.
contract MoodyWallet is IERC721Receiver {
    uint8 public constant ACCEPT = 0;
    uint8 public constant REJECT = 1;
    uint8 public constant BURN = 2;
    uint8 public constant REENTER = 3;

    uint8 public ethMood;
    uint8 public nftMood;
    bool public signs;
    KilimAuction public auction;
    KilimBazaar public bazaar;
    address public motifs;
    address public oneOfOne;
    /// Re-entry into a contract while that contract was paying or minting to this wallet, that succeeded.
    uint256 public auctionReentries;
    uint256 public bazaarReentries;

    function wire(KilimAuction auction_, KilimBazaar bazaar_) external {
        auction = auction_;
        bazaar = bazaar_;
        motifs = address(auction_.motifs());
        oneOfOne = address(auction_.oneOfOne());
    }

    function set(uint8 ethMood_, uint8 nftMood_, bool signs_) external {
        ethMood = ethMood_ % 4;
        nftMood = nftMood_ % 4;
        signs = signs_;
    }

    receive() external payable {
        uint8 m = ethMood;
        if (m == REJECT) revert("no ETH");
        if (m == BURN) _burn();
        if (m == REENTER) _reenter(msg.sender);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        uint8 m = nftMood;
        if (m == REJECT) revert("no NFTs");
        if (m == BURN) _burn();
        if (m == REENTER) _reenter(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev ERC-1271: approves every digest while `signs` is set.
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return signs ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function _burn() private view {
        uint256 x;
        while (gasleft() > 0) {
            x += gasleft();
        }
    }

    /// @dev Calls back into whichever contract is paying or minting to this wallet. The auction pays ETH
    ///      itself and mints through the motif collection and the 1/1, all inside its own guarded calls;
    ///      the Bazaar mints kilims inside its guarded calls. None of these calls may succeed.
    function _reenter(address from) private {
        if (from == address(auction) || from == motifs || from == oneOfOne) {
            KilimAuction a = auction;
            try a.settle() {
                ++auctionReentries;
            } catch {}
            try a.withdrawRefund(address(this)) {
                ++auctionReentries;
            } catch {}
            try a.claimMotifs(1, address(this)) {
                ++auctionReentries;
            } catch {}
            try a.claimPrize(address(this)) {
                ++auctionReentries;
            } catch {}
        } else if (from == address(bazaar)) {
            try bazaar.seal(new uint256[](0)) {
                ++bazaarReentries;
            } catch {}
            try bazaar.makeFromLoom(new uint256[](0), address(this)) {
                ++bazaarReentries;
            } catch {}
        }
    }
}

/// @dev Deployed by the harness to make Medusa commit the pending block: Medusa 1.5.1 only commits a block
///      (giving it a hash BLOCKHASH can return) when it holds a contract creation; otherwise it renumbers the
///      one pending block, so no block hash would ever exist for a kilim's seal block.
contract Blank {}
