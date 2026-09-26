// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimWriter as W} from "../../src/render/KilimWriter.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TestBase} from "../TestBase.sol";

/// @dev Exposes the library's writers, each on a fresh `buf` buffer, with sentinels around the output.
contract WriterHarness {
    bytes32 internal constant SENTINEL = keccak256("sentinel");

    function _tables() internal pure returns (uint256 nt) {
        bytes memory tab = W.tables();
        assembly {
            nt := add(tab, 32)
        }
    }

    /// @dev base64 through the pair table. Also checks the word after the input is restored and nothing
    ///      after the output's slack is touched.
    function b64(bytes memory data) external pure returns (string memory) {
        uint256 bt = _tables() + W.NUMBER_TABLE;
        uint256 src = _stage(data);
        uint256 len = W.b64len(data.length);
        uint256 o = W.buf(len);
        uint256 guard = _guard();
        uint256 end = W.check(o, len, W.b64(src, data.length, o, bt));
        _verify(src + data.length, guard);
        return W.str(o, end);
    }

    /// @dev The input in a buf buffer, with a marker word right after it.
    function _stage(bytes memory data) internal pure returns (uint256 src) {
        src = W.buf(data.length);
        assembly {
            mcopy(src, add(data, 32), mload(data))
            mstore(add(src, mload(data)), 0x5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e)
        }
    }

    /// @dev A marked buffer right after the output's slack.
    function _guard() internal pure returns (uint256 guard) {
        guard = W.buf(32);
        assembly {
            mstore(guard, 0x1111111111111111111111111111111111111111111111111111111111111111)
        }
    }

    function _verify(uint256 tail, uint256 guard) internal pure {
        bytes32 a;
        bytes32 b;
        assembly {
            a := mload(tail)
            b := mload(guard)
        }
        require(
            a == 0x5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e, "input tail not restored"
        );
        require(b == 0x1111111111111111111111111111111111111111111111111111111111111111, "overran the slack");
    }

    function path(bytes memory record) external pure returns (string memory) {
        uint256 nt = _tables();
        uint256 src = W.buf(record.length + 32);
        assembly {
            mcopy(src, add(record, 32), mload(record))
        }
        uint256 bound = 3 * record.length;
        uint256 o = W.buf(bound);
        return W.str(o, W.check(o, bound, W.path(o, src, record.length, nt)));
    }

    function numbers(uint256 a, int256 b, bytes32 c) external pure returns (string memory) {
        uint256 o = W.buf(300);
        uint256 e = W.u(o, a);
        e = W.w(e, " ", 1);
        e = W.i(e, b);
        e = W.w(e, " ", 1);
        e = W.hex32(e, c);
        return W.str(o, W.check(o, 300, e));
    }

    function digits(uint256 v) external pure returns (uint256) {
        return W.digits(v);
    }

    function checkFails() external pure {
        uint256 o = W.buf(10);
        W.check(o, 10, o + 11);
    }

    function checkFailsBackwards() external pure {
        uint256 o = W.buf(10);
        W.check(o, 10, o - 1);
    }

    /// @dev Rule 1: a writer that ends exactly at the bound may overrun it by up to 31 bytes, and the next
    ///      Solidity allocation (here a marked 32-byte array) must come through untouched.
    function slackAbsorbsAMaximalOverrun(uint256 bound) external pure returns (bool) {
        uint256 o = W.buf(bound);
        bytes32 mark = keccak256("next allocation");
        bytes memory next = abi.encodePacked(mark);
        W.w(o + bound - 1, bytes32(type(uint256).max), 1); // the last byte, overrunning by 31
        return next.length == 32 && bytes32(next) == mark;
    }

    function exactFails() external pure {
        uint256 o = W.buf(10);
        W.exact(o, 10, o + 9);
    }

    function numberEntry(uint256 z) external pure returns (bytes4) {
        bytes memory tab = W.tables();
        bytes4 e;
        assembly {
            e := mload(add(add(tab, 32), shl(2, z)))
        }
        return e;
    }
}

contract KilimWriterTest is TestBase {
    WriterHarness internal h = new WriterHarness();

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function testBase64MatchesOpenZeppelinForEveryShortLength() public view {
        for (uint256 n; n <= 100; ++n) {
            bytes memory data = new bytes(n);
            for (uint256 i; i < n; ++i) {
                data[i] = bytes1(uint8(uint256(keccak256(abi.encode(n, i)))));
            }
            require(_eq(h.b64(data), Base64.encode(data)), string.concat("length ", vm.toString(n)));
        }
    }

    function testFuzzBase64MatchesOpenZeppelin(bytes memory data) public view {
        assertTrue(_eq(h.b64(data), Base64.encode(data)));
    }

    function testBase64OfLongInputs() public view {
        for (uint256 n = 24_570; n <= 24_580; ++n) {
            bytes memory data = new bytes(n);
            for (uint256 i; i < n; i += 13) {
                data[i] = bytes1(uint8(i));
            }
            require(_eq(h.b64(data), Base64.encode(data)), string.concat("length ", vm.toString(n)));
        }
    }

    function testNumberTable() public view {
        assertEq(bytes32(h.numberEntry(0)), bytes32(bytes4(hex"02203000"))); // " 0"
        assertEq(bytes32(h.numberEntry(1)), bytes32(bytes4(hex"022d3100"))); // "-1"
        assertEq(bytes32(h.numberEntry(126)), bytes32(bytes4(hex"03203633"))); // " 63"
        assertEq(bytes32(h.numberEntry(127)), bytes32(bytes4(hex"032d3634"))); // "-64"
        assertEq(bytes32(h.numberEntry(19)), bytes32(bytes4(hex"032d3130"))); // "-10"
    }

    function testNumbersAndHex() public view {
        assertTrue(_eq(h.numbers(0, 0, bytes32(0)), string.concat("0 0 0x", _zeros())));
        assertTrue(
            _eq(
                h.numbers(type(uint256).max, type(int256).min + 1, keccak256("x")),
                string.concat(
                    Strings.toString(type(uint256).max),
                    " -",
                    Strings.toString(uint256(type(int256).max)),
                    " ",
                    Strings.toHexString(uint256(keccak256("x")), 32)
                )
            )
        );
        for (uint256 v = 1; v < 1e70; v *= 10) {
            assertEq(h.digits(v), bytes(Strings.toString(v)).length);
            assertEq(h.digits(v - 1), bytes(Strings.toString(v - 1)).length);
        }
    }

    function _zeros() internal pure returns (string memory) {
        return "0000000000000000000000000000000000000000000000000000000000000000";
    }

    function testPostconditionsRevert() public {
        vm.expectRevert(W.BufferOverflow.selector);
        h.checkFails();
        vm.expectRevert(W.BufferOverflow.selector);
        h.checkFailsBackwards();
        vm.expectRevert(abi.encodeWithSelector(W.LengthMismatch.selector, 10, 9));
        h.exactFails();
    }

    /// @dev Every bound, aligned or not, leaves at least 32 bytes of slack after the buffer.
    function testBufferSlackAbsorbsTheLargestOverrun() public view {
        for (uint256 bound = 1; bound <= 96; ++bound) {
            require(h.slackAbsorbsAMaximalOverrun(bound), string.concat("bound ", vm.toString(bound)));
        }
    }

    // ------------------------------------------------------------ the geometry decoder

    function _varint(uint256 v) internal pure returns (bytes memory out) {
        do {
            uint256 b = v & 0x7f;
            v >>= 7;
            out = bytes.concat(out, bytes1(uint8(v != 0 ? b | 0x80 : b)));
        } while (v != 0);
    }

    function _zz(int256 v) internal pure returns (bytes memory) {
        return _varint(v >= 0 ? uint256(v) << 1 : (uint256(-v) << 1) - 1);
    }

    function _n(int256 v) internal pure returns (string memory) {
        return v < 0
            ? string.concat("-", Strings.toString(uint256(-v)))
            : string.concat(" ", Strings.toString(uint256(v)));
    }

    function testDecodesTheSmallestMotifExample() public view {
        // "M 22 16l-55 0 39-34 28 34-2 1z" (the spec's motif 133)
        // 1 ring of 5 points: zigzag(22)=44, zigzag(16)=32, zigzag(-55)=109, ...
        assertTrue(_eq(h.path(hex"01052c206d004e4338440302"), "M 22 16l-55 0 39-34 28 34-2 1z"));
    }

    function testDecodesASinglePointRing() public view {
        // one ring of one point: no "l", since there are no relative points after the first
        assertTrue(_eq(h.path(hex"01010204"), "M 1 2z"));
        assertTrue(_eq(h.path(hex"020102040202040304"), "M 1 2zM 1 2l-2 2z"));
    }

    function testDecodesMultiByteVarintsAndLargeCoordinates() public view {
        // 2 rings; 2- and 3-byte varints; the int16 extremes (zigzag 65535 = ff ff 03)
        assertTrue(
            _eq(
                h.path(hex"0203ffff03feff03d804d704d08c01cf8c0103000180017f81018201"),
                "M-32768 32767l 300-300 9000-9000zM 0-1l 64-64-65 65z"
            )
        );
    }

    function testFuzzDecoderMatchesAReferenceEncoding(uint256 seed) public view {
        uint256 rings = 1 + seed % 4;
        bytes memory rec = _varint(rings);
        string memory want;
        for (uint256 r; r < rings; ++r) {
            (bytes memory ringBytes, string memory ringText) = _ring(uint256(keccak256(abi.encode(seed, r))));
            rec = bytes.concat(rec, ringBytes);
            want = string.concat(want, ringText);
        }
        assertTrue(_eq(h.path(rec), want));
    }

    /// @dev A random ring (1..14 points) as stored bytes and as the expected path text.
    function _ring(uint256 seed) internal pure returns (bytes memory rec, string memory text) {
        uint256 n = 1 + seed % 14;
        rec = _varint(n);
        text = "M";
        for (uint256 k; k < n; ++k) {
            (int256 dx, int256 dy) = _delta(uint256(keccak256(abi.encode(seed, k))));
            rec = bytes.concat(rec, _zz(dx), _zz(dy));
            text = string.concat(text, _n(dx), _n(dy), k == 0 && n > 1 ? "l" : "");
        }
        text = string.concat(text, "z");
    }

    /// @dev Mostly small deltas (the table path), sometimes anything in the int16 range.
    function _delta(uint256 x) internal pure returns (int256 dx, int256 dy) {
        int256 span = x % 5 == 0 ? int256(65_535) : int256(129);
        dx = int256((x >> 8) % uint256(span)) - span / 2;
        dy = int256((x >> 40) % uint256(span)) - span / 2;
    }

    function testMalformedRecordsRevert() public {
        assertTrue(_eq(h.path(hex"0103020406080a0c"), "M 1 2l 3 4 5 6z"));
        bytes[6] memory bad = [
            bytes(hex"0103020406080a0c00"), // a trailing byte: not consumed exactly
            hex"0104020406080a0c", // fewer points than the ring claims
            hex"00", // no rings
            hex"0100", // an empty ring
            hex"0203020406080a0c", // a ring missing
            hex"01ffffffffffffffffff010204" // a huge point count: rejected before any point is read
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(W.BadRecord.selector);
            h.path(bad[i]);
        }
        // A point count whose varint runs into the end of the record (ended by the zero word): rejected
        // at once, not decoded as 2^28 - 1 points from memory past the record. The gas cap keeps a
        // regression from running for minutes before it fails.
        vm.expectRevert(W.BadRecord.selector);
        h.path{gas: 10_000_000}(hex"01ffffffff");
    }
}
