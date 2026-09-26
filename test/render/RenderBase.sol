// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestBase} from "../TestBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";

/// @dev The cheatcodes the renderer tests need on top of TestBase's.
interface VmRender {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function envOr(string calldata, string calldata) external view returns (string memory);
    function envOr(string calldata, bool) external view returns (bool);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonBool(string calldata, string calldata) external pure returns (bool);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonUintArray(string calldata, string calldata) external pure returns (uint256[] memory);
    function parseJsonBytes32Array(string calldata, string calldata) external pure returns (bytes32[] memory);
    function parseJsonStringArray(string calldata, string calldata) external pure returns (string[] memory);
    function ffi(string[] calldata) external returns (bytes memory);
    function toString(uint256) external pure returns (string memory);
    function toString(bytes32) external pure returns (string memory);
    function expectRevert(bytes calldata) external;
    function expectEmit() external;
    function prank(address) external;
    function etch(address, bytes calldata) external;
    function assume(bool) external pure;
}

/// @notice Deploys the packed STORE (onchain/build, or $KILIM_STORE_DIR for the count-agnostic reruns) as
///         SSTORE2 chunks, then a KilimRenderer over it, and offers memory-flat call helpers.
abstract contract RenderBase is TestBase {
    VmRender internal constant vmr = VmRender(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal storeDir;
    string internal manifest;
    string internal golden;
    address[] internal chunkAddrs;
    KilimRenderer internal renderer;
    uint256 internal count;

    function _loadStore() internal {
        storeDir = vmr.envOr("KILIM_STORE_DIR", string("../onchain/build"));
        manifest = vmr.readFile(string.concat(storeDir, "/manifest.json"));
        golden = vmr.readFile(string.concat(storeDir, "/golden.json"));
        string[] memory files = vmr.parseJsonStringArray(manifest, ".chunkFiles");
        delete chunkAddrs;
        for (uint256 i; i < files.length; ++i) {
            chunkAddrs.push(sstore2(vmr.readFileBinary(string.concat(storeDir, "/", files[i]))));
        }
        renderer = new KilimRenderer(chunkAddrs, _hash("geometryHash"), _hash("indexHash"), _hash("pageHash"));
        count = renderer.motifCount();
    }

    function _hash(string memory name) internal view returns (bytes32) {
        return vmr.parseJsonBytes32(manifest, string.concat(".hashes.", name));
    }

    /// @dev Standard SSTORE2 creation: code = 0x00 || data.
    function sstore2(bytes memory data) internal returns (address p) {
        bytes memory code = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly {
            p := create(0, add(code, 32), mload(code))
        }
        require(p != address(0), "sstore2");
    }

    function _uint16s(string memory json, string memory key) internal pure returns (uint16[] memory out) {
        uint256[] memory a = vmr.parseJsonUintArray(json, key);
        out = new uint16[](a.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = uint16(a[i]);
        }
    }

    /// @dev sha256 and length of the string `target` returns for `data`. The returned data is copied to the
    ///      free pointer without moving it, so hundreds of large calls in one test do not grow memory.
    function _sha(address target, bytes memory data) internal view returns (bytes32 h, uint256 len) {
        assembly {
            let ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
            let p := mload(0x40)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            len := mload(add(p, 32))
            if iszero(staticcall(gas(), 2, add(p, 64), len, 0, 32)) { revert(0, 0) }
            h := mload(0)
        }
    }

    /// @dev Gas used by `target.staticcall(data)` when nothing is copied back, plus the intrinsic cost an
    ///      eth_call of the same calldata would pay (21,000 + 16 per byte, a conservative upper bound).
    function _ethCallGas(address target, bytes memory data) internal view returns (uint256 used) {
        bool ok;
        assembly {
            let g := gas()
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
            used := sub(g, gas())
        }
        require(ok, "call reverted");
        used += 21_000 + 16 * data.length;
    }

    /// @dev Count occurrences of `needle` (<= 32 bytes) in `hay`.
    function _occurrences(bytes memory hay, bytes memory needle) internal pure returns (uint256 n) {
        uint256 k = needle.length;
        if (hay.length < k) return 0;
        bytes32 mask = k == 32 ? bytes32(type(uint256).max) : ~(bytes32(type(uint256).max) >> (8 * k));
        bytes32 want;
        assembly {
            want := and(mload(add(needle, 32)), mask)
        }
        uint256 end = hay.length - k;
        for (uint256 i; i <= end; ++i) {
            bytes32 word;
            assembly {
                word := and(mload(add(add(hay, 32), i)), mask)
            }
            if (word == want) ++n;
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        return _occurrences(hay, needle) > 0;
    }

    /// @dev The payload of a "data:<type>;base64," URI, decoded.
    function _dataUri(bytes memory uri, bytes memory prefix) internal pure returns (bytes memory) {
        require(uri.length >= prefix.length, "short uri");
        for (uint256 i; i < prefix.length; ++i) {
            require(uri[i] == prefix[i], "uri prefix");
        }
        bytes memory body = new bytes(uri.length - prefix.length);
        assembly {
            mcopy(add(body, 32), add(add(uri, 32), mload(prefix)), mload(body))
        }
        return _b64decode(body);
    }

    /// @dev Standard padded base64 decode (test-only; clarity over speed).
    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length % 4 == 0, "b64 length");
        if (data.length == 0) return out;
        uint256 pad = data[data.length - 1] == "=" ? (data[data.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes(data.length / 4 * 3 - pad);
        uint256 o;
        for (uint256 i; i < data.length; i += 4) {
            uint256 v = (_b64v(data[i]) << 18) | (_b64v(data[i + 1]) << 12) | (_b64v(data[i + 2]) << 6)
                | _b64v(data[i + 3]);
            for (uint256 k; k < 3 && o < out.length; ++k) {
                out[o++] = bytes1(uint8(v >> (16 - 8 * k)));
            }
        }
    }

    function _b64v(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        if (x == 61) return 0;
        revert("b64 char");
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly {
            mcopy(add(out, 32), add(add(b, 32), from), sub(to, from))
        }
    }
}
