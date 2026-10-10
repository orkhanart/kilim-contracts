// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @dev Review PoC for KilimOneOfOne.tokenURI: the two word-at-a-time encoders, copied verbatim from
///      src/KilimOneOfOne.sol (the review diffs the copy against the source), checked against
///      OpenZeppelin's Base64 and a byte-at-a-time hex loop: every lane with every byte value, with the
///      other lanes empty and with the other lanes full, then random words.
contract OneOfOneEncodersPoC {
    // ------------------------------------------------------------ the copies

    function hexHalfOf(uint256 input) internal pure returns (uint256 out) {
        assembly {
            function hexHalf(x) -> y {
                x := and(
                    or(shl(64, x), x),
                    0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff
                )
                x := and(
                    or(shl(32, x), x),
                    0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff
                )
                x := and(
                    or(shl(16, x), x),
                    0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff
                )
                x := and(or(shl(8, x), x), 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff)
                y := or(
                    shl(4, and(x, 0x00f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f0)),
                    and(x, 0x000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f)
                )
                let letters :=
                    shr(
                        4,
                        and(
                            add(y, 0x0606060606060606060606060606060606060606060606060606060606060606),
                            0x1010101010101010101010101010101010101010101010101010101010101010
                        )
                    )
                y := add(
                    add(y, 0x3030303030303030303030303030303030303030303030303030303030303030),
                    mul(letters, 0x27)
                )
            }
            out := hexHalf(input)
        }
    }

    function base64BlockOf(uint256 input) internal pure returns (uint256 out) {
        assembly {
            function base64Block(x) -> y {
                x := or(
                    and(x, 0x0000000000000000000000000000000000000000ffffffffffffffffffffffff),
                    and(shl(32, x), 0x00000000ffffffffffffffffffffffff00000000000000000000000000000000)
                )
                x := or(
                    and(x, 0x00000000000000000000ffffffffffff00000000000000000000ffffffffffff),
                    and(shl(16, x), 0x0000ffffffffffff00000000000000000000ffffffffffff0000000000000000)
                )
                x := or(
                    and(x, 0x0000000000ffffff0000000000ffffff0000000000ffffff0000000000ffffff),
                    and(shl(8, x), 0x00ffffff0000000000ffffff0000000000ffffff0000000000ffffff00000000)
                )
                x := or(
                    and(x, 0x00000fff00000fff00000fff00000fff00000fff00000fff00000fff00000fff),
                    and(shl(4, x), 0x0fff00000fff00000fff00000fff00000fff00000fff00000fff00000fff0000)
                )
                x := or(
                    and(x, 0x003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f),
                    and(shl(2, x), 0x3f003f003f003f003f003f003f003f003f003f003f003f003f003f003f003f00)
                )
                let a :=
                    shr(
                        6,
                        and(
                            add(x, 0x2626262626262626262626262626262626262626262626262626262626262626),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let b :=
                    shr(
                        6,
                        and(
                            add(x, 0x0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let c :=
                    shr(
                        6,
                        and(
                            add(x, 0x0202020202020202020202020202020202020202020202020202020202020202),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                let d :=
                    shr(
                        6,
                        and(
                            add(x, 0x0101010101010101010101010101010101010101010101010101010101010101),
                            0x4040404040404040404040404040404040404040404040404040404040404040
                        )
                    )
                // No lane borrows: where 75 or 15 is taken the lane already holds at least 123.
                y := sub(
                    add(
                        add(x, 0x4141414141414141414141414141414141414141414141414141414141414141),
                        add(mul(a, 6), mul(d, 3))
                    ),
                    add(mul(b, 75), mul(c, 15))
                )
            }
            out := base64Block(input)
        }
    }

    // ------------------------------------------------------------ references

    /// @dev The 16 bytes of `v`, most significant first, as 32 lowercase hex characters.
    function refHex(uint128 v) internal pure returns (uint256 out) {
        bytes memory table = "0123456789abcdef";
        bytes memory o = new bytes(32);
        for (uint256 i; i < 16; ++i) {
            uint8 b = uint8(v >> (8 * (15 - i)));
            o[2 * i] = table[b >> 4];
            o[2 * i + 1] = table[b & 15];
        }
        assembly ("memory-safe") {
            out := mload(add(o, 32))
        }
    }

    /// @dev The 24 bytes of `v`, most significant first, as 32 base64 characters (OpenZeppelin).
    function refBase64(uint192 v) internal pure returns (uint256 out) {
        bytes memory enc = bytes(Base64.encode(abi.encodePacked(v)));
        require(enc.length == 32, "reference length");
        assembly ("memory-safe") {
            out := mload(add(enc, 32))
        }
    }

    // ------------------------------------------------------------ tests

    /// @dev Every lane with every byte value, the other lanes empty and the other lanes full.
    function testHexHalfEveryLaneAndByteValue() public pure {
        for (uint256 lane; lane < 16; ++lane) {
            uint256 others = type(uint128).max & ~(uint256(0xff) << (8 * lane));
            for (uint256 b; b < 256; ++b) {
                uint256 alone = b << (8 * lane);
                require(hexHalfOf(alone) == refHex(uint128(alone)), "hex lane alone");
                uint256 full = alone | others;
                require(hexHalfOf(full) == refHex(uint128(full)), "hex lane full");
            }
        }
    }

    function testBase64BlockEveryLaneAndByteValue() public pure {
        for (uint256 lane; lane < 24; ++lane) {
            uint256 others = type(uint192).max & ~(uint256(0xff) << (8 * lane));
            for (uint256 b; b < 256; ++b) {
                uint256 alone = b << (8 * lane);
                require(base64BlockOf(alone) == refBase64(uint192(alone)), "base64 lane alone");
                uint256 full = alone | others;
                require(base64BlockOf(full) == refBase64(uint192(full)), "base64 lane full");
            }
        }
    }

    /// @dev Every sextet value in every one of the 32 output positions, with the neighbours at 0 and 63.
    function testBase64BlockEverySextetInEveryPosition() public pure {
        for (uint256 pos; pos < 32; ++pos) {
            uint256 shift = 6 * (31 - pos);
            uint256 others = type(uint192).max & ~(uint256(63) << shift);
            for (uint256 s; s < 64; ++s) {
                uint256 alone = s << shift;
                require(base64BlockOf(alone) == refBase64(uint192(alone)), "sextet alone");
                uint256 full = alone | others;
                require(base64BlockOf(full) == refBase64(uint192(full)), "sextet full");
            }
        }
    }

    function testFuzzHexHalf(uint128 x) public pure {
        require(hexHalfOf(x) == refHex(x), "hex fuzz");
    }

    function testFuzzBase64Block(uint192 x) public pure {
        require(base64BlockOf(x) == refBase64(x), "base64 fuzz");
    }

    /// @dev Bits above the input width: hexHalf keeps them (its first mask covers bits 128..191, where
    ///      an unshifted bit 128 lands), base64Block drops them (its first step keeps only bits 0..95 and
    ///      the shifted 96..191). tokenURI passes shr(128, w), and(w, 2^128 - 1) and shr(64, mload(src)),
    ///      all clean, so neither matters there. Documented, not relied on.
    function testHighBitsAreTheCallersResponsibility() public pure {
        uint256 dirty = (uint256(1) << 128) | 0x0f;
        require(hexHalfOf(dirty) != refHex(0x0f), "hexHalf keeps bits above 128");
        uint256 dirty64 = (uint256(1) << 192) | 0x3f;
        require(base64BlockOf(dirty64) == refBase64(0x3f), "base64Block drops bits above 192");
    }
}
