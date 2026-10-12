// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";

/// @dev Halmos symbolic-value cheatcodes (a16z/halmos-cheatcodes), declared here: the repo has no forge-std.
interface SVM {
    function createUint256(string calldata) external pure returns (uint256);
    function createUint(uint256 bits, string calldata) external pure returns (uint256);
    function createAddress(string calldata) external pure returns (address);
    function createBool(string calldata) external pure returns (bool);
    function createBytes32(string calldata) external pure returns (bytes32);
    function enableSymbolicStorage(address) external;
}

/// @dev The subset of the hevm cheatcodes Halmos 0.3.3 implements and these tests use.
interface HVm {
    function assume(bool) external pure;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function warp(uint256) external;
    function roll(uint256) external;
    function etch(address, bytes calldata) external;
}

/// @dev Marks the next CREATE address: Halmos hands out sequential addresses, so a contract created right
///      after this one sits at address(probe) + 1, the next at + 2, and so on. Halmos-only (not RLP).
contract Probe {}

/// @dev A wallet that refuses ETH: an automatic refund to it fails and becomes a pull refund.
contract Rejecter {
    receive() external payable {
        revert("no ETH");
    }
}

/// @dev A wallet that, on receiving ETH, tries to re-enter the auction (withdraw a refund and bid again),
///      ignores the outcome and accepts the ETH. Exercises the nonReentrant guards on the refund path.
contract Reenterer {
    KilimAuction public auction;

    function setAuction(KilimAuction a) external {
        auction = a;
    }

    receive() external payable {
        KilimAuction a = auction;
        if (address(a) == address(0)) return;
        try a.withdrawRefund(address(this)) {} catch {}
        try a.bid{value: 0}(0, 0, 0) {} catch {}
        try a.settle() {} catch {}
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        KilimAuction a = auction;
        if (address(a) != address(0)) {
            try a.claimPrize(address(this)) {} catch {}
            try a.settle() {} catch {}
        }
        return this.onERC721Received.selector;
    }
}

abstract contract HalmosBase {
    SVM internal constant svm = SVM(address(uint160(uint256(keccak256("svm cheat code")))));
    HVm internal constant vm = HVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant TREASURY = address(0x7777);
    uint256 internal constant UNIT = 0.001 ether;
    uint256 internal constant RESERVE = 0.01 ether;
    uint160 internal constant REGISTRANT_BASE = 0x5EED0000;
    uint256 internal constant MOTIF_COUNT = 1024;
    uint256 internal constant CHUNK = 24_575;

    /// @dev Store chunks, created once per test contract and shared by every collection it deploys.
    address[] internal _gridChunks;
    address internal _namesChunk;
    bytes32 internal _gridsHash;
    bytes32 internal _namesHash;
    KilimOneOfOne.Page internal _page;
    bool internal _storeReady;

    // ------------------------------------------------------------ stand-in store

    /// @dev One SSTORE2 chunk: runtime code 0x00 || data.
    function sstore2(bytes memory data) internal returns (address chunk) {
        require(data.length != 0 && data.length <= CHUNK, "chunk size");
        bytes memory initcode =
            abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            chunk := create(0, add(initcode, 32), mload(initcode))
        }
        require(chunk != address(0), "chunk deployment failed");
    }

    function chunked(bytes memory data, uint256 size) internal returns (address[] memory chunks) {
        uint256 count = (data.length + size - 1) / size;
        chunks = new address[](count);
        for (uint256 k; k < count; ++k) {
            uint256 from = k * size;
            uint256 to = from + size < data.length ? from + size : data.length;
            bytes memory piece = new bytes(to - from);
            assembly ("memory-safe") {
                mcopy(add(piece, 32), add(add(data, 32), from), sub(to, from))
            }
            chunks[k] = sstore2(piece);
        }
    }

    /// @dev Grids: 1,024 words, word n-1 = n (any bytes do; the contracts only hash and copy them).
    ///      Names: the 1,025-entry offset table, all zero (every name empty), which _checkNames accepts.
    ///      Page: PREFIX any text, HEAD ending in `const GRIDS='`, TAIL starting `O2Nv` (base64 of `;co`):
    ///      exactly the splice point KilimBazaar's constructor checks.
    function _store() internal {
        if (_storeReady) return;
        bytes memory grids = new bytes(MOTIF_COUNT * 32);
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            assembly ("memory-safe") {
                mstore(add(add(grids, 32), mul(sub(n, 1), 32)), n)
            }
        }
        _gridChunks = chunked(grids, 767 * 32);
        _gridsHash = keccak256(grids);
        bytes memory names = new bytes(2 * (MOTIF_COUNT + 1));
        _namesChunk = sstore2(names);
        _namesHash = keccak256(names);
        bytes memory prefix = bytes('{"name":"stand-in","animation_url":"data:text/html;base64,');
        bytes memory head = bytes("<p>const GRIDS='");
        bytes memory tail = bytes(Base64.encode(bytes(";const BLOB=1;")));
        _page.prefixChunks = chunked(prefix, CHUNK);
        _page.prefixHash = keccak256(prefix);
        _page.headChunks = chunked(head, CHUNK);
        _page.headHash = keccak256(head);
        _page.tailChunks = chunked(tail, CHUNK);
        _page.tailHash = keccak256(tail);
        _storeReady = true;
    }

    function newMotifs(address minter, uint256 cap) internal returns (KilimMotifs) {
        _store();
        return new KilimMotifs(
            minter, TREASURY, cap, _gridChunks, _gridsHash, _namesChunk, _namesHash, "d", "https://x"
        );
    }

    function newOneOfOne(address minter, KilimMotifs motifs) internal returns (KilimOneOfOne) {
        _store();
        return new KilimOneOfOne(minter, TREASURY, motifs, _page, "The Unwoven Kilim", "d", "https://x");
    }

    /// @dev The motif collection, the 1/1 and the auction, in the deploy script's order. The auction's
    ///      address is predicted from Halmos's sequential CREATE addresses (see Probe).
    function deployTrio(
        uint256 cap,
        uint256 maxPerBid,
        uint16 incrementBps,
        uint64 duration,
        uint64 extensionWindow
    ) internal returns (KilimMotifs motifs, KilimOneOfOne oneOfOne, KilimAuction auction) {
        _store();
        address probe = address(new Probe());
        address predicted = address(uint160(probe) + 3);
        motifs = newMotifs(predicted, cap);
        require(address(motifs) == address(uint160(probe) + 1), "motifs address");
        oneOfOne = newOneOfOne(predicted, motifs);
        auction = new KilimAuction(
            KilimAuction.Config({
                treasury: TREASURY,
                motifs: address(motifs),
                oneOfOne: address(oneOfOne),
                startsAt: uint64(block.timestamp + 1 hours),
                duration: duration,
                extensionWindow: extensionWindow,
                incrementBps: incrementBps,
                reservePrice: RESERVE,
                maxMotifsPerBid: maxPerBid
            })
        );
        require(address(auction) == predicted, "auction address");
    }

    /// @dev Warps to startsAt and registers the 100 wallets that open bidding (each holding exactly 0.01 ETH).
    function openBidding(KilimAuction auction) internal {
        if (block.timestamp < auction.startsAt()) vm.warp(auction.startsAt());
        uint256 first = auction.registrationCount();
        for (uint256 i = first; i < 100; ++i) {
            address wallet = address(REGISTRANT_BASE + uint160(i));
            vm.deal(wallet, RESERVE);
            vm.prank(wallet);
            auction.register();
        }
        require(auction.registrationCount() == 100, "registration");
    }

    // ------------------------------------------------------------ helpers

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The 4-byte selector at the start of revert data (0 if shorter).
    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(ret, 32))
        }
    }

    // Branch-free logic. Solidity's `&&`, `||`, `?:` and checked arithmetic compile to JUMPIs, and Halmos
    // forks a path at every JUMPI whose condition is symbolic; these keep a conjunction on one path. The
    // unchecked add/sub are only used where the operands are bounded (stated at each use).

    function _and(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(a, b)
        }
    }

    function _or(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := or(a, b)
        }
    }

    function _imp(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := or(iszero(a), b)
        }
    }

    function _ite(bool c, uint256 x, uint256 y) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := xor(y, mul(xor(x, y), c))
        }
    }

    function _uadd(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := add(a, b)
        }
    }

    function _usub(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := sub(a, b)
        }
    }

    /// @dev True when revert data is a Solidity Panic(uint256) (arithmetic overflow, division by zero, ...).
    function _isPanic(bytes memory ret) internal pure returns (bool) {
        return _sel(ret) == bytes4(0x4e487b71);
    }
}
