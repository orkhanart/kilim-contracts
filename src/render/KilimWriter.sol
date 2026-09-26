// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title KilimWriter
/// @notice The text writers behind KilimRenderer: output buffers, decimal and hex numbers, base64, and the
///         varint geometry decoder. Every function writes by pointer into memory reserved with `buf`.
/// @dev These are the only memory-unsafe routines in the renderer, kept together so they can be audited as
///      one unit (and unit-tested through test/render/KilimWriter.t.sol). They follow four rules:
///
///      1. `buf(bound)` reserves a buffer: `bound` bytes at `start`, 64 head bytes before `start` (used by
///         `ret` for the ABI head) and at least 32 slack bytes after `start + bound`. The free-memory pointer
///         moves past all of it, so later Solidity allocations never land inside.
///      2. A writer takes a cursor `o` and returns the new cursor. It may store whole 32-byte words at or
///         after `o`. The bytes it touched past the returned cursor are its OVERRUN, stated on each writer,
///         always < 32 bytes, and garbage until the next write covers them.
///      3. So while every cursor stays <= start + bound, every overrun lands in the buffer's own slack.
///         Callers close each document with `check` (cursor <= bound) or `exact` (cursor == expected) before
///         anything reads it. A document that fails either check reverts, so no corrupt output escapes.
///      4. Inputs to `b64` and `path` need 32 writable bytes after them (a `buf` buffer's slack, or the
///         renderer's record scratch). `b64` zeroes that word while it runs and restores it; `path` zeroes it.
library KilimWriter {
    /// @notice A document outgrew the buffer reserved for it.
    error BufferOverflow();
    /// @notice A writer ended somewhere other than where its exact length says it must.
    error LengthMismatch(uint256 expected, uint256 actual);
    /// @notice A geometry record is malformed: it was not consumed exactly, or a ring is impossible.
    error BadRecord();

    /// @dev The number table: for each 1-byte zigzag varint u < 128, 4 bytes [len, sign, digit, digit].
    uint256 internal constant NUMBER_TABLE = 512;
    /// @dev The base64 pair table: for each 12-bit value, its 2 base64 characters.
    uint256 internal constant PAIR_TABLE = 8192;
    uint256 internal constant TABLES_SIZE = NUMBER_TABLE + PAIR_TABLE;

    // ------------------------------------------------------------------ buffers

    /// @notice Reserve a buffer for `bound` bytes of output. See rule 1.
    function buf(uint256 bound) internal pure returns (uint256 start) {
        assembly ("memory-safe") {
            start := add(mload(0x40), 64)
            mstore(0x40, and(add(add(start, bound), 63), not(31)))
        }
    }

    /// @notice Postcondition: the document [start, end) fits the `bound` it was reserved with.
    function check(uint256 start, uint256 bound, uint256 end) internal pure returns (uint256) {
        if (end < start || end > start + bound) revert BufferOverflow();
        return end;
    }

    /// @notice Postcondition: the document [start, end) is exactly `length` bytes long.
    function exact(uint256 start, uint256 length, uint256 end) internal pure returns (uint256) {
        if (end != start + length) revert LengthMismatch(length, end - start);
        return end;
    }

    /// @notice View [start, end) as a Solidity `string` (writes the length word into the buffer head).
    function str(uint256 start, uint256 end) internal pure returns (string memory out) {
        assembly ("memory-safe") {
            out := sub(start, 32)
            mstore(out, sub(end, start))
        }
    }

    /// @notice END THE CALL, returning [start, end) ABI-encoded as `string` or `bytes`, without copying it.
    /// @dev Uses the 64 head bytes before `start` and zeroes the padding word after `end`. Only ever call this
    ///      as the last statement of an EXTERNAL function: it halts execution, so an internal caller would
    ///      never get control back.
    function ret(uint256 start, uint256 end) internal pure {
        assembly {
            let len := sub(end, start)
            mstore(sub(start, 64), 0x20)
            mstore(sub(start, 32), len)
            mstore(end, 0)
            return(sub(start, 64), add(64, and(add(len, 31), not(31))))
        }
    }

    // ------------------------------------------------------------------ literals and numbers

    /// @notice Copy a byte string. Overrun: none.
    function s(uint256 o, bytes memory text) internal pure returns (uint256) {
        assembly ("memory-safe") {
            mcopy(o, add(text, 32), mload(text))
            o := add(o, mload(text))
        }
        return o;
    }

    /// @notice Write the first `n` (<= 32) bytes of `word`, a left-aligned literal. Overrun: 32 - n bytes.
    /// @dev For literals inside loops: no allocation, unlike `s` with a string literal.
    function w(uint256 o, bytes32 word, uint256 n) internal pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(o, word)
            o := add(o, n)
        }
        return o;
    }

    /// @notice Number of decimal digits of `v` (1 for 0).
    function digits(uint256 v) internal pure returns (uint256 n) {
        n = 1;
        while (v >= 10) {
            v /= 10;
            ++n;
        }
    }

    /// @notice Write `v` in decimal. Overrun: none.
    function u(uint256 o, uint256 v) internal pure returns (uint256) {
        assembly ("memory-safe") {
            let n := 1
            for { let t := div(v, 10) } t { t := div(t, 10) } { n := add(n, 1) }
            let e := add(o, n)
            for { let q := e } 1 {} {
                q := sub(q, 1)
                mstore8(q, add(48, mod(v, 10)))
                v := div(v, 10)
                if iszero(v) { break }
            }
            o := e
        }
        return o;
    }

    /// @notice Write a signed decimal ("-" only for negatives). Overrun: none.
    function i(uint256 o, int256 v) internal pure returns (uint256) {
        if (v < 0) {
            assembly ("memory-safe") {
                mstore8(o, 0x2d)
            }
            return u(o + 1, uint256(-v));
        }
        return u(o, uint256(v));
    }

    /// @notice Write "0x" and 64 lowercase hex digits. Overrun: none.
    function hex32(uint256 o, bytes32 v) internal pure returns (uint256) {
        assembly ("memory-safe") {
            mstore8(o, 0x30)
            mstore8(add(o, 1), 0x78)
            o := add(o, 2)
            for { let k := 0 } lt(k, 32) { k := add(k, 1) } {
                let b := byte(k, v)
                let hi := shr(4, b)
                let lo := and(b, 15)
                mstore8(o, add(hi, add(48, mul(gt(hi, 9), 39))))
                mstore8(add(o, 1), add(lo, add(48, mul(gt(lo, 9), 39))))
                o := add(o, 2)
            }
        }
        return o;
    }

    // ------------------------------------------------------------------ base64

    /// @notice Length of the padded base64 encoding of `n` bytes.
    function b64len(uint256 n) internal pure returns (uint256) {
        return ((n + 2) / 3) << 2; // 4 characters per started 3-byte group
    }

    /// @notice Standard padded base64 (RFC 4648) of [src, src + len), written at `o`. Returns the end,
    ///         always exactly o + b64len(len). `bt` is the pair table (rule 4 applies to the input).
    /// @dev 24 input bytes become one 32-byte store through twelve 12-bit lookups. Overrun: <= 28 bytes.
    function b64(uint256 src, uint256 len, uint256 o, uint256 bt) internal pure returns (uint256 end) {
        uint256 last;
        assembly ("memory-safe") {
            end := add(o, shl(2, div(add(len, 2), 3)))
            let dEnd := add(src, len)
            let saved := mload(dEnd)
            mstore(dEnd, 0) // the last group reads past the input: those bits must be zero
            for {} lt(src, dEnd) {} {
                let x := mload(src)
                let a := shr(240, mload(add(bt, shl(1, shr(244, x)))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(232, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(220, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(208, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(196, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(184, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(172, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(160, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(148, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(136, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(124, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(112, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(100, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(88, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(76, x), 0xfff))))))
                a := or(shl(16, a), shr(240, mload(add(bt, shl(1, and(shr(64, x), 0xfff))))))
                mstore(o, a)
                o := add(o, 32)
                src := add(src, 24)
            }
            mstore(dEnd, saved)
            switch mod(len, 3)
            case 1 { mstore(sub(end, 2), or(shl(240, 0x3d3d), shr(16, mload(end)))) }
            case 2 { mstore8(sub(end, 1), 0x3d) }
            last := o
        }
        // Postcondition: the loop wrote ceil(len / 24) words, so it stopped within one word after `end`.
        if (last < end || last >= end + 32) revert LengthMismatch(end, last);
    }

    // ------------------------------------------------------------------ geometry

    /// @notice Decode one motif record at [p, p + len) into SVG path text at `o`, using the number table at
    ///         `nt`. Per ring: "M" N(x0) N(y0), then "l" and N(dx) N(dy) for the other points, then "z", where
    ///         N(v) is "-"|v| for negatives and " "v otherwise, straight from the stored zigzag varints.
    /// @dev Writes 32 zero bytes at p + len first (rule 4). Reverts BadRecord unless the record is consumed
    ///      exactly, every ring has at least one point and enough bytes remain for its points: a malformed
    ///      record can only revert, never loop long or read beyond its zero word. For a well-formed record the
    ///      text is at most 3 bytes per record byte ("M", "l", "z" per point-count varint; sign + digits per
    ///      coordinate varint). Overrun: <= 30 bytes (the table path stores a word for 2-3 characters).
    function path(uint256 o, uint256 p, uint256 len, uint256 nt) internal pure returns (uint256) {
        uint256 end = p + len;
        uint256 bad;
        assembly ("memory-safe") {
            mstore(end, 0)
            function rv(q) -> v, nq {
                let b := byte(0, mload(q))
                v := and(b, 0x7f)
                nq := add(q, 1)
                for { let sh := 7 } gt(b, 0x7f) { sh := add(sh, 7) } {
                    b := byte(0, mload(nq))
                    v := or(v, shl(sh, and(b, 0x7f)))
                    nq := add(nq, 1)
                }
            }
            // one signed coordinate: the table for 1-byte varints, general itoa otherwise
            function num(q, pp, t) -> nq, np {
                let b := byte(0, mload(pp))
                switch lt(b, 0x80)
                case 1 {
                    let e := shr(224, mload(add(t, shl(2, b))))
                    mstore(q, shl(232, e))
                    nq := add(q, shr(24, e))
                    np := add(pp, 1)
                }
                default {
                    let zz
                    zz, np := rv(pp)
                    let v := shr(1, zz)
                    switch and(zz, 1)
                    case 1 {
                        mstore8(q, 0x2d)
                        v := add(v, 1)
                    }
                    default { mstore8(q, 0x20) }
                    q := add(q, 1)
                    let n := 1
                    for { let x := div(v, 10) } x { x := div(x, 10) } { n := add(n, 1) }
                    nq := add(q, n)
                    for { let e := nq } 1 {} {
                        e := sub(e, 1)
                        mstore8(e, add(48, mod(v, 10)))
                        v := div(v, 10)
                        if iszero(v) { break }
                    }
                }
            }
            let rings
            rings, p := rv(p)
            if iszero(rings) { bad := 1 }
            for {} rings { rings := sub(rings, 1) } {
                let n
                n, p := rv(p)
                // a ring needs a first point, and every point needs at least two bytes
                if or(iszero(n), or(gt(p, end), gt(n, shr(1, sub(end, p))))) {
                    bad := 1
                    break
                }
                mstore8(o, 0x4d) // M
                o := add(o, 1)
                o, p := num(o, p, nt)
                o, p := num(o, p, nt)
                if gt(n, 1) {
                    mstore8(o, 0x6c) // l
                    o := add(o, 1)
                }
                for { let k := shl(1, sub(n, 1)) } k { k := sub(k, 1) } {
                    let b := byte(0, mload(p))
                    switch lt(b, 0x80)
                    case 1 {
                        b := shr(224, mload(add(nt, shl(2, b))))
                        mstore(o, shl(232, b))
                        o := add(o, shr(24, b))
                        p := add(p, 1)
                    }
                    default { o, p := num(o, p, nt) }
                }
                mstore8(o, 0x7a) // z
                o := add(o, 1)
            }
        }
        if (bad != 0 || p != end) revert BadRecord();
        return o;
    }

    // ------------------------------------------------------------------ tables

    /// @notice The number table (512 B) followed by the base64 pair table (8,192 B).
    function tables() internal pure returns (bytes memory tab) {
        tab = new bytes(TABLES_SIZE);
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        assembly ("memory-safe") {
            let nt := add(tab, 32)
            for { let z := 0 } lt(z, 128) { z := add(z, 1) } {
                let v := add(shr(1, z), and(z, 1)) // |zigzag(z)|
                let q := add(nt, shl(2, z))
                let sign := 0x20
                if and(z, 1) { sign := 0x2d }
                switch lt(v, 10)
                case 1 {
                    mstore8(q, 2)
                    mstore8(add(q, 1), sign)
                    mstore8(add(q, 2), add(48, v))
                }
                default {
                    mstore8(q, 3)
                    mstore8(add(q, 1), sign)
                    mstore8(add(q, 2), add(48, div(v, 10)))
                    mstore8(add(q, 3), add(48, mod(v, 10)))
                }
            }
            let a := add(alphabet, 32)
            let bt := add(nt, NUMBER_TABLE)
            for { let hi := 0 } lt(hi, 64) { hi := add(hi, 1) } {
                let c := byte(0, mload(add(a, hi)))
                let row := add(bt, shl(7, hi))
                for { let lo := 0 } lt(lo, 64) { lo := add(lo, 1) } {
                    let q := add(row, shl(1, lo))
                    mstore8(q, c)
                    mstore8(add(q, 1), byte(0, mload(add(a, lo))))
                }
            }
        }
    }
}
