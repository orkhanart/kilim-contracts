// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";
import {KilimWriter} from "../../src/render/KilimWriter.sol";

/// @dev Exposes the renderer's store readers.
contract StoreReaderHarness is KilimRenderer {
    constructor(address[] memory c, bytes32 g, bytes32 i, bytes32 p) KilimRenderer(c, g, i, p) {}

    function readAt(uint256 off, uint256 len) external view returns (bytes memory out) {
        out = new bytes(len);
        uint256 dst;
        assembly {
            dst := add(out, 32)
        }
        _read(off, len, dst);
    }

    /// @dev Into the scratch word at 0x00 on purpose: _read must not touch scratch space itself.
    function readToScratch(uint256 off) external view returns (bytes32 w) {
        _read(off, 32, 0);
        assembly {
            w := mload(0)
        }
    }

    function rec(uint256 m) external view returns (uint256) {
        return _rec(m, _tables());
    }
}

/// @notice The renderer's constructor refuses every malformed or mismatched STORE, one test per BadStore
///         code, by corrupting one field of the real packed store at a time.
contract RenderStoreTest is RenderBase {
    uint256 internal constant CHUNK = 24_575;
    bytes internal store;

    function setUp() public {
        _loadStore();
        store = vmr.readFileBinary(string.concat(storeDir, "/store.bin"));
    }

    // ------------------------------------------------------------ helpers

    function _u32(bytes memory s, uint256 pos) internal pure returns (uint256 v) {
        for (uint256 i; i < 4; ++i) {
            v = (v << 8) | uint8(s[pos + i]);
        }
    }

    function _setU32(bytes memory s, uint256 pos, uint256 v) internal pure {
        for (uint256 i; i < 4; ++i) {
            s[pos + i] = bytes1(uint8(v >> (24 - 8 * i)));
        }
    }

    function _setU16(bytes memory s, uint256 pos, uint256 v) internal pure {
        s[pos] = bytes1(uint8(v >> 8));
        s[pos + 1] = bytes1(uint8(v));
    }

    function _copy() internal view returns (bytes memory) {
        return bytes.concat(store);
    }

    function _geoLen(bytes memory s) internal pure returns (uint256) {
        return _u32(s, 4);
    }

    function _idxOff(bytes memory s) internal pure returns (uint256) {
        return 64 + _u32(s, 4);
    }

    /// @dev Section hashes as the header of `s` describes them.
    function _hashes(bytes memory s) internal pure returns (bytes32 gh, bytes32 ih, bytes32 ph) {
        uint256 g = _u32(s, 4);
        uint256 i = _u32(s, 8);
        uint256 p = _u32(s, 12);
        gh = keccak256(_slice(s, 64, 64 + g));
        ih = keccak256(_slice(s, 64 + g, 64 + g + i));
        ph = keccak256(_slice(s, 64 + g + i, 64 + g + i + p));
    }

    function _split(bytes memory s, uint256 first) internal returns (address[] memory cs) {
        uint256 n = s.length <= first ? 1 : 1 + (s.length - first + CHUNK - 1) / CHUNK;
        cs = new address[](n);
        uint256 a;
        for (uint256 k; k < n; ++k) {
            uint256 b = k == 0 ? first : a + CHUNK;
            if (b > s.length) b = s.length;
            cs[k] = sstore2(_slice(s, a, b));
            a = b;
        }
    }

    function _expect(address[] memory cs, bytes32 gh, bytes32 ih, bytes32 ph, uint256 code) internal {
        vmr.expectRevert(abi.encodeWithSelector(KilimRenderer.BadStore.selector, code));
        new KilimRenderer(cs, gh, ih, ph);
    }

    /// @dev Deploy `s` in standard chunks with hashes that match its (possibly corrupted) sections, so only
    ///      the targeted check can fail.
    function _expectStore(bytes memory s, uint256 code) internal {
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(s);
        _expect(_split(s, CHUNK), gh, ih, ph, code);
    }

    /// @dev Write `v` into the leading count varint of GEOM, keeping its byte length (non-minimal if needed).
    function _setCount(bytes memory s, uint256 v) internal pure {
        uint256 k;
        while (uint8(s[64 + k]) >= 0x80) ++k;
        for (uint256 i; i <= k; ++i) {
            s[64 + i] = bytes1(uint8(((v >> (7 * i)) & 0x7f) | (i < k ? 0x80 : 0)));
        }
    }

    // ------------------------------------------------------------ the good store

    function testTheGoodStoreDeploysWithItsFacts() public view {
        address[] memory cs = renderer.chunks();
        assertEq(cs.length, chunkAddrs.length);
        for (uint256 k; k < cs.length; ++k) {
            assertEq(cs[k], chunkAddrs[k]);
        }
        assertEq(keccak256(renderer.TABLES().code), keccak256(bytes.concat(hex"00", KilimWriter.tables())));
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(store);
        assertEq(renderer.geometryHash(), gh);
        assertEq(renderer.indexHash(), ih);
        assertEq(renderer.pageHash(), ph);
        assertEq(store.length, vmr.parseJsonUint(manifest, ".sections.store"));
    }

    /// @dev Reads that straddle chunk boundaries, into any destination, and every index record. (A record
    ///      straddling a boundary once came back corrupted when read through scratch memory.)
    function testReadsAcrossEveryChunkBoundary() public {
        bytes memory s = store;
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(s);
        StoreReaderHarness h = new StoreReaderHarness(chunkAddrs, gh, ih, ph);
        for (uint256 b = CHUNK; b < s.length; b += CHUNK) {
            for (uint256 back = 1; back < 32; back += 5) {
                assertEq(keccak256(h.readAt(b - back, 40)), keccak256(_slice(s, b - back, b - back + 40)));
                assertEq(h.readToScratch(b - back), bytes32(_slice(s, b - back, b - back + 32)));
            }
        }
        uint256 idx = _idxOff(s);
        for (uint256 m; m < count; ++m) {
            assertEq(bytes32(h.rec(m)) >> 128, bytes32(_slice(s, idx + 16 * m, idx + 16 * m + 16)) >> 128);
        }
    }

    // ------------------------------------------------------------ one test per BadStore code

    function testRejectsNoChunks() public {
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(store);
        _expect(new address[](0), gh, ih, ph, 1);
    }

    function testRejectsWrongChunkSizes() public {
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(store);
        _expect(_split(store, CHUNK - 1), gh, ih, ph, 2); // a short chunk before the last
        address[] memory cs = _split(store, CHUNK);
        address[] memory more = new address[](cs.length + 1);
        for (uint256 k; k < cs.length; ++k) {
            more[k] = cs[k];
        }
        more[cs.length] = sstore2(""); // an empty last chunk (code is only the 0x00 prefix)
        _expect(more, gh, ih, ph, 2);
        // The same after full chunks only, so no other chunk is the wrong size: pad the page to a whole
        // number of chunks. The padded store deploys; with an empty chunk after it, it must not.
        bytes memory s = _copy();
        uint256 pad = CHUNK - s.length % CHUNK;
        s = bytes.concat(s, new bytes(pad));
        _setU32(s, 12, _u32(s, 12) + pad);
        (gh, ih, ph) = _hashes(s);
        cs = _split(s, CHUNK);
        new KilimRenderer(cs, gh, ih, ph);
        more = new address[](cs.length + 1);
        for (uint256 k; k < cs.length; ++k) {
            more[k] = cs[k];
        }
        more[cs.length] = sstore2("");
        _expect(more, gh, ih, ph, 2);
    }

    function testRejectsANonZeroPrefixByte() public {
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(store);
        address[] memory cs = _split(store, CHUNK);
        bytes memory data = _slice(store, 0, CHUNK);
        bytes memory code = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df301", data);
        address bad;
        assembly {
            bad := create(0, add(code, 32), mload(code))
        }
        cs[0] = bad;
        _expect(cs, gh, ih, ph, 3);
    }

    function testRejectsBadMagicAndPadding() public {
        bytes memory s = _copy();
        s[0] = "X";
        _expectStore(s, 4);
        s = _copy();
        s[63] = 0x01;
        _expectStore(s, 5);
        s = _copy();
        s[42] = 0x01; // the first padding byte after the nine still motifs
        _expectStore(s, 5);
    }

    function testRejectsLengthsThatDoNotAddUp() public {
        bytes memory s = _copy();
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(s);
        _setU32(s, 4, _geoLen(s) + 1);
        _expect(_split(s, CHUNK), gh, ih, ph, 6);
        s = _copy();
        _setU32(s, 12, _u32(s, 12) - 1);
        _expect(_split(s, CHUNK), gh, ih, ph, 6);
        // Too short to hold even the header.
        address[] memory cs = new address[](1);
        cs[0] = sstore2(new bytes(10));
        _expect(cs, gh, ih, ph, 6);
    }

    function testRejectsSpliceOffsets() public {
        bytes memory s = _copy();
        _setU32(s, 16, _u32(s, 20) + 1); // stillAt after symbolsAt
        _expectStore(s, 7);
        s = _copy();
        _setU32(s, 20, _u32(s, 12) + 1); // symbolsAt beyond the page
        _expectStore(s, 7);
    }

    function testAcceptsSplicePointsAtThePageEnd() public {
        bytes memory s = _copy();
        _setU32(s, 16, _u32(s, 12)); // stillAt == symbolsAt == pageLen
        _setU32(s, 20, _u32(s, 12));
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(s);
        KilimRenderer r = new KilimRenderer(_split(s, CHUNK), gh, ih, ph);
        assertEq(r.motifCount(), count);
    }

    function testRejectsAWrongGeometryHashOrChunkOrder() public {
        (bytes32 gh, bytes32 ih, bytes32 ph) = _hashes(store);
        _expect(_split(store, CHUNK), keccak256("not the geometry"), ih, ph, 8);
        address[] memory cs = _split(store, CHUNK);
        require(cs.length > 3, "store too small to reorder");
        (cs[1], cs[2]) = (cs[2], cs[1]); // same size, so only the content moves
        _expect(cs, gh, ih, ph, 8);
    }

    function testRejectsABadMotifCount() public {
        bytes memory s = _copy();
        _setCount(s, 0);
        _expectStore(s, 9);
        s = _copy();
        s[64] = 0x80;
        s[65] = 0x80;
        s[66] = 0x80; // a count varint longer than three bytes
        _expectStore(s, 9);
        // The same count re-encoded in four bytes, with every index offset shifted to match, so only the
        // varint's length is wrong.
        s = _copy();
        uint256 k;
        while (uint8(s[64 + k]) >= 0x80) ++k;
        uint256 shift = 3 - k; // four bytes replace k + 1
        bytes memory four = abi.encodePacked(
            uint8((count & 0x7f) | 0x80),
            uint8(((count >> 7) & 0x7f) | 0x80),
            uint8(((count >> 14) & 0x7f) | 0x80),
            uint8(count >> 21)
        );
        s = bytes.concat(_slice(s, 0, 64), four, _slice(s, 65 + k, s.length));
        _setU32(s, 4, _geoLen(s) + shift);
        uint256 idx = _idxOff(s);
        for (uint256 m; m < count; ++m) {
            _setU32(s, idx + 16 * m, _u32(s, idx + 16 * m) + shift);
        }
        _expectStore(s, 9);
    }

    function testRejectsAnIndexOfTheWrongLength() public {
        bytes memory s = _copy();
        _setCount(s, count + 1);
        _expectStore(s, 10);
    }

    function testRejectsStillMotifsOutOfRange() public {
        bytes memory s = _copy();
        _setU16(s, 24 + 8, 0xffff); // the hero cell must exist
        _expectStore(s, 11);
        s = _copy();
        _setU16(s, 24, count); // a neighbour must be a motif or empty
        _expectStore(s, 11);
    }

    function testRejectsAWrongIndexHash() public {
        (bytes32 gh,, bytes32 ph) = _hashes(store);
        _expect(_split(store, CHUNK), gh, keccak256("not the index"), ph, 12);
    }

    function testRejectsNonContiguousIndexRecords() public {
        bytes memory s = _copy();
        uint256 r0 = _idxOff(s);
        _setU32(s, r0, _u32(s, r0) + 1); // the first record must start right after the count
        _expectStore(s, 13);
        s = _copy();
        uint256 r3 = r0 + 16 * 3;
        _setU32(s, r3 + 4, 0); // an empty record
        _expectStore(s, 13);
        s = _copy();
        _setU32(s, r3 + 4, _u32(s, r3 + 4) + 1); // a record overlapping the next
        _expectStore(s, 13);
        // An empty record even when the index stays contiguous: record 4 starts where record 3 did and
        // takes over its bytes.
        s = _copy();
        uint256 r4 = r3 + 16;
        uint256 len3 = _u32(s, r3 + 4);
        _setU32(s, r3 + 4, 0);
        _setU32(s, r4, _u32(s, r3));
        _setU32(s, r4 + 4, _u32(s, r4 + 4) + len3);
        _expectStore(s, 13);
    }

    function testRejectsAZeroBboxSide() public {
        bytes memory s = _copy();
        uint256 r5 = _idxOff(s) + 16 * 5;
        _setU16(s, r5 + 12, 0);
        _expectStore(s, 14);
        s = _copy();
        _setU16(s, r5 + 14, 0);
        _expectStore(s, 14);
    }

    function testRejectsAnIndexThatDoesNotEndWithTheGeometry() public {
        bytes memory s = _copy();
        uint256 last = _idxOff(s) + 16 * (count - 1);
        _setU32(s, last + 4, _u32(s, last + 4) - 1);
        _expectStore(s, 15);
    }

    function testRejectsAWrongPageHash() public {
        (bytes32 gh, bytes32 ih,) = _hashes(store);
        _expect(_split(store, CHUNK), gh, ih, keccak256("not the page"), 16);
    }
}
