// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

/// @dev A motif source the 1/1 cannot tell from KilimMotifs at construction (it only checks for code),
///      answering grids() in every shape a hostile or broken contract could: the right 32,768 bytes
///      from a seed, one byte short, one byte long, a revert, no return data at all (an EOA-like
///      answer), the right size with a wrong ABI offset or length word, and a 1 MB return bomb.
contract ShapedGrids {
    enum Mode {
        Good,
        Short,
        Long,
        Reverts,
        Empty,
        WrongOffset,
        WrongLength,
        Bomb
    }

    Mode public immutable mode;
    bytes32 public immutable seed;

    constructor(Mode mode_, bytes32 seed_) {
        mode = mode_;
        seed = seed_;
    }

    function words() public view returns (bytes memory out) {
        out = new bytes(32_768);
        for (uint256 i; i < 1024; ++i) {
            bytes32 w = keccak256(abi.encode(seed, i));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), shl(5, i)), w)
            }
        }
    }

    function grids() external view returns (bytes memory) {
        Mode m = mode;
        if (m == Mode.Good) return words();
        if (m == Mode.Reverts) revert("no grids today");
        if (m == Mode.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (m == Mode.Bomb) {
            assembly ("memory-safe") {
                return(0, 0x100000)
            }
        }
        bytes memory w = words();
        if (m == Mode.Short) {
            assembly ("memory-safe") {
                mstore(w, 32767)
            }
            return w;
        }
        if (m == Mode.Long) return bytes.concat(w, hex"00");
        bytes memory enc = abi.encode(w);
        if (m == Mode.WrongOffset) {
            assembly ("memory-safe") {
                mstore(add(enc, 32), 0x40)
            }
        } else {
            assembly ("memory-safe") {
                mstore(add(enc, 64), 32767)
            }
        }
        assembly ("memory-safe") {
            return(add(enc, 32), mload(enc))
        }
    }
}

/// @dev Review PoC for KilimOneOfOne.tokenURI: the live grids call against every answer shape, the raw
///      ABI return as a caller decodes it, a fuzz of whole answers against OpenZeppelin's Base64 with
///      random grids and random section bytes, and the gas at launch size (a 75 KB still, the real
///      809 KB tail) against the 8,000,000 policy ceiling and EIP-7825's 16,777,216 cap.
contract OneOfOneGridsSourcePoC is TestBase {
    event log_named_uint(string key, uint256 value);

    function _hex(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "0123456789abcdef";
        out = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            out[2 * i] = table[uint8(data[i]) >> 4];
            out[2 * i + 1] = table[uint8(data[i]) & 0xf];
        }
    }

    function _reference(bytes memory prefix, bytes memory head, bytes memory tail, bytes memory grids)
        internal
        pure
        returns (bytes memory)
    {
        uint256 pad = (3 - (head.length + 65_536 + 1) % 3) % 3;
        bytes memory piece = bytes.concat(head, _hex(grids), "'");
        for (uint256 i; i < pad; ++i) {
            piece = bytes.concat(piece, " ");
        }
        assertEq(piece.length % 3, 0);
        return bytes.concat("data:application/json;utf8,", prefix, bytes(Base64.encode(piece)), tail, '"}');
    }

    function _own(ShapedGrids source, bytes memory prefix, bytes memory head, bytes memory tail)
        internal
        returns (KilimOneOfOne own)
    {
        own = new KilimOneOfOne(
            address(this),
            TREASURY,
            KilimMotifs(address(source)),
            pageFrom(prefix, head, tail),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            EXTERNAL_URL
        );
        own.mint(ALICE);
    }

    function _stand(ShapedGrids source) internal returns (KilimOneOfOne) {
        return _own(source, bytes(PAGE_PREFIX), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST))));
    }

    // ------------------------------------------------------------ the grids call

    function testGoodShapeMatchesTheReference() public {
        ShapedGrids source = new ShapedGrids(ShapedGrids.Mode.Good, keccak256("seed"));
        KilimOneOfOne own = _stand(source);
        bytes memory expected = _reference(
            bytes(PAGE_PREFIX), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST))), source.words()
        );
        assertEq(keccak256(bytes(own.tokenURI(1))), keccak256(expected));
    }

    function testEveryWrongShapeIsGridsUnavailable() public {
        ShapedGrids.Mode[6] memory bad = [
            ShapedGrids.Mode.Short,
            ShapedGrids.Mode.Long,
            ShapedGrids.Mode.Empty,
            ShapedGrids.Mode.WrongOffset,
            ShapedGrids.Mode.WrongLength,
            ShapedGrids.Mode.Bomb
        ];
        for (uint256 i; i < bad.length; ++i) {
            KilimOneOfOne own = _stand(new ShapedGrids(bad[i], keccak256("seed")));
            vm.expectRevert(KilimOneOfOne.GridsUnavailable.selector);
            own.tokenURI(1);
        }
    }

    function testARevertingSourceBubblesItsReason() public {
        KilimOneOfOne own = _stand(new ShapedGrids(ShapedGrids.Mode.Reverts, keccak256("seed")));
        vm.expectRevert(bytes("no grids today"));
        own.tokenURI(1);
    }

    /// @dev The constructor accepts any contract as the motif source: a KilimMotifs over other grids,
    ///      or anything with code. Only the deploy script's golden hash ties the 1/1 to the real grids.
    function testAnyContractPassesAsTheMotifSource() public {
        new KilimOneOfOne(
            address(this),
            TREASURY,
            KilimMotifs(address(this)),
            standInPage(),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            EXTERNAL_URL
        );
    }

    // ------------------------------------------------------------ the ABI return

    function testRawReturnIsACanonicalAbiString() public {
        KilimOneOfOne own = _stand(new ShapedGrids(ShapedGrids.Mode.Good, keccak256("abi")));
        (bool ok, bytes memory ret) = address(own).staticcall(abi.encodeCall(own.tokenURI, (1)));
        assertTrue(ok);
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(ret, 32))
            length := mload(add(ret, 64))
        }
        assertEq(offset, 0x20);
        uint256 padded = (length + 31) / 32 * 32;
        assertEq(ret.length, 64 + padded);
        for (uint256 i = 64 + length; i < ret.length; ++i) {
            assertTrue(ret[i] == 0);
        }
        string memory decoded = abi.decode(ret, (string));
        assertEq(bytes(decoded).length, length);
        assertEq(keccak256(bytes(decoded)), keccak256(bytes(own.tokenURI(1))));
        // The scheme and the two closing bytes are where the layout says.
        assertEq(string(_slice(ret, 64, 27)), "data:application/json;utf8,");
        assertEq(string(_slice(ret, 64 + length - 2, 2)), '"}');
    }

    // ------------------------------------------------------------ whole answers, fuzzed

    /// @dev Random grids (every byte value reaches hexHalf) and random, possibly binary, section bytes
    ///      (every byte value reaches base64Block through HEAD) against OpenZeppelin's Base64.
    function testFuzzWholeAnswerMatchesOpenZeppelin(
        bytes32 seed,
        bytes memory prefix,
        bytes memory head,
        bytes memory tail
    ) public {
        if (prefix.length == 0) prefix = "p";
        if (head.length == 0) head = "h";
        if (tail.length == 0) tail = "t";
        ShapedGrids source = new ShapedGrids(ShapedGrids.Mode.Good, seed);
        KilimOneOfOne own = _own(source, prefix, head, tail);
        bytes memory actual = bytes(own.tokenURI(1));
        bytes memory expected = _reference(prefix, head, tail, source.words());
        assertEq(actual.length, expected.length);
        assertEq(keccak256(actual), keccak256(expected));
    }

    /// @dev Heads around the 24-byte block boundary of the base64 piece, so the scalar tail loop sees
    ///      0..7 groups of 3 and every padding (m mod 24 runs through every multiple of 3).
    function testEveryTailGroupCountAndPadding() public {
        ShapedGrids source = new ShapedGrids(ShapedGrids.Mode.Good, keccak256("tail"));
        bytes memory grids = source.words();
        for (uint256 n = 1; n <= 24; ++n) {
            bytes memory head = new bytes(n);
            for (uint256 i; i < n; ++i) {
                head[i] = bytes1(uint8(0xf0 + i));
            }
            KilimOneOfOne own = _own(source, bytes(PAGE_PREFIX), head, "T");
            bytes memory expected = _reference(bytes(PAGE_PREFIX), head, "T", grids);
            assertEq(keccak256(bytes(own.tokenURI(1))), keccak256(expected));
        }
    }

    // ------------------------------------------------------------ gas at launch size

    /// @dev The packed page (onchain/build-page/manifest.json): prefix 393 bytes with a 161-byte
    ///      placeholder still, head 196, tail 808,872 in 33 chunks. The launch still will be larger:
    ///      this measures a 75 KB PNG (100,000 base64 characters) over the real tail size.
    function testGasAtLaunchSizeWithARealStill() public {
        bytes memory prefix = bytes.concat(
            bytes('{"name":"The Unwoven Kilim","description":"x","image":"data:image/png;base64,'),
            _fill(100_000, "QUJD"),
            bytes('","animation_url":"data:text/html;base64,')
        );
        bytes memory head = bytes(
            "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:#fff}</style></head><body><script>const GRIDS='"
        );
        assertEq(head.length, 196);
        bytes memory tail = _fill(808_872, "a0B1");
        KilimOneOfOne big = _own(new ShapedGrids(ShapedGrids.Mode.Good, keccak256("gas")), prefix, head, tail);
        assertEq(big.tailChunks().length, 33);
        uint256 used = _readGas(address(big), abi.encodeCall(big.tokenURI, (1)));
        bytes memory actual = bytes(big.tokenURI(1));
        emit log_named_uint("1/1 tokenURI(1) gas, 100 KB still + 809 KB tail", used);
        emit log_named_uint("1/1 tokenURI(1) answer bytes", actual.length);
        emit log_named_uint("margin under the 8,000,000 policy ceiling", 8_000_000 - used);
        emit log_named_uint("margin under EIP-7825's 16,777,216 cap", 16_777_216 - used);
        assertTrue(used < 8_000_000);
    }

    // ------------------------------------------------------------ helpers

    function _readGas(address target, bytes memory data) internal view returns (uint256 g) {
        bool ok;
        g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        assertTrue(ok);
    }

    function _fill(uint256 n, bytes4 pattern) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = pattern[i % 4];
        }
    }

    function _slice(bytes memory data, uint256 from, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = data[from + i];
        }
    }
}
