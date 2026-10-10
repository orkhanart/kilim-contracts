// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {KilimGlyphs} from "./KilimGlyphs.sol";

/// @notice The 1/1, "What the weave remembers": exactly one token, id 1, minted by the auction.
/// @dev No admin, pause, upgrade or metadata setter. The page is stored in SSTORE2 chunks (runtime code
///      `0x00 || data`) hashed at construction; the only part read live is the glyph grids, taken from
///      the glyph collection, so the 1/1 provably draws the same glyphs the glyph tokens show.
contract KilimOneOfOne is ERC721 {
    using Strings for uint256;

    /// @dev The stored page in three sections. PREFIX is the raw JSON up to and including
    ///      `"animation_url":"data:text/html;base64,`. HEAD is the raw loader up to and including
    ///      `const GRIDS='`. TAIL is the rest of the loader, already base64, starting with the `;`
    ///      after the closing quote. tokenURI writes the quote and the padding itself.
    struct Page {
        address[] prefixChunks;
        bytes32 prefixHash;
        address[] headChunks;
        bytes32 headHash;
        address[] tailChunks;
        bytes32 tailHash;
    }

    uint256 public constant TOKEN_ID = 1;
    /// @notice Resale royalty, fixed forever. Marketplaces may ignore royalties entirely.
    uint96 public constant ROYALTY_BPS = 500;
    /// @dev 1,024 grids of 32 bytes, and the hex characters they expand to. Direct numbers: assembly reads them.
    uint256 private constant GRID_BYTES = 32_768;
    uint256 private constant HEX_CHARS = 65_536;
    /// @dev "data:application/json;utf8," is 27 bytes; the answer ends in the 2 bytes `"}`.
    uint256 private constant SCHEME = 27;

    address public immutable minter;
    address public immutable royaltyReceiver;
    KilimGlyphs public immutable glyphs;
    bytes32 public immutable prefixHash;
    bytes32 public immutable headHash;
    bytes32 public immutable tailHash;
    /// @dev Written once in the constructor, never again.
    address[] private _prefixChunks;
    address[] private _headChunks;
    address[] private _tailChunks;
    string public description;
    string public externalUrl;
    bool public minted;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidRecipient();
    error AlreadyMinted();
    error GridsUnavailable();

    constructor(
        address minter_,
        address royaltyReceiver_,
        KilimGlyphs glyphs_,
        Page memory page,
        string memory name_,
        string memory description_,
        string memory externalUrl_
    ) ERC721(name_, "KILIM") {
        if (minter_ == address(0) || royaltyReceiver_ == address(0) || address(glyphs_).code.length == 0) {
            revert InvalidConfiguration();
        }
        _store(_prefixChunks, page.prefixChunks, page.prefixHash);
        _store(_headChunks, page.headChunks, page.headHash);
        _store(_tailChunks, page.tailChunks, page.tailHash);
        minter = minter_;
        royaltyReceiver = royaltyReceiver_;
        glyphs = glyphs_;
        prefixHash = page.prefixHash;
        headHash = page.headHash;
        tailHash = page.tailHash;
        description = description_;
        externalUrl = externalUrl_;
    }

    /// @notice The auction mints the 1/1 to the winner, once.
    /// @dev Deliberately NOT nonReentrant: only the auction calls it, it is one-shot, and the auction
    ///      holds its own guard. A guard here could be entered from a receiver callback and make the
    ///      prize delivery fail with settlement already recorded (audit finding R-06).
    function mint(address to) external {
        if (msg.sender != minter) revert Unauthorized();
        if (to == address(0) || to == address(this) || to == minter) revert InvalidRecipient();
        if (minted) revert AlreadyMinted();
        minted = true;
        _safeMint(to, TOKEN_ID);
    }

    function prefixChunks() external view returns (address[] memory) {
        return _prefixChunks;
    }

    function headChunks() external view returns (address[] memory) {
        return _headChunks;
    }

    function tailChunks() external view returns (address[] memory) {
        return _tailChunks;
    }

    /// @notice The whole token: `data:application/json;utf8,` PREFIX base64(HEAD hex(grids) ' pad) TAIL `"}`.
    /// @dev Built in one buffer: the total length is computed first, every chunk is copied straight into
    ///      place with extcodecopy, the grids are expanded to hex in place, and the middle piece is base64
    ///      encoded in place (its raw bytes sit at the end of the room the encoding needs, so the encoder
    ///      never overtakes what it has not read). Both encoders work a word at a time with shifts and
    ///      masks: a byte-at-a-time loop costs about nine million gas here, a word at a time well under one.
    ///      The piece's length is a multiple of 3 by construction, so no `=` padding is ever written and
    ///      the encoded pieces concatenate exactly. Memory expansion is the other cost: the answer is
    ///      about 1 MB. The call ends in `return` from assembly so nothing re-encodes the answer. Because
    ///      it ends the call, tokenURI MUST NEVER BE CALLED INTERNALLY.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        address[] memory prefix = _prefixChunks;
        address[] memory head = _headChunks;
        address[] memory tail = _tailChunks;
        address source = address(glyphs);
        uint256 gridsCall = uint256(uint32(KilimGlyphs.grids.selector)) << 224;
        uint256 unavailable = uint256(uint32(GridsUnavailable.selector)) << 224;
        assembly {
            // Data bytes held by a section's chunks: each chunk's code less its leading 0x00.
            function sectionSize(list) -> size {
                let n := mload(list)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    size := add(size, sub(extcodesize(mload(add(add(list, 32), shl(5, i)))), 1))
                }
            }
            // Copies a section's data bytes to dst, straight from the chunks' code; returns the end.
            function copyChunks(list, dst) -> end {
                end := dst
                let n := mload(list)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    let chunk := mload(add(add(list, 32), shl(5, i)))
                    let size := sub(extcodesize(chunk), 1)
                    extcodecopy(chunk, end, 1, size)
                    end := add(end, size)
                }
            }
            // 16 bytes, right-aligned, to their 32 lowercase hex characters. Four shift-and-mask steps
            // spread the bytes one per 16-bit lane, each nibble then gets a byte of its own, and every
            // byte becomes ASCII: '0' + n, plus 0x27 more where the nibble is 10 or above ('a'..'f').
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
            // 24 bytes, right-aligned, to their 32 base64 characters. Five shift-and-mask steps spread
            // the sextets one per byte; each byte is then moved into the alphabet with four flags
            // (n >= 26, 52, 62, 63): 'A' + n, 'a' + n - 26, '0' + n - 52, '+' for 62, '/' for 63.
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

            // The piece to encode: HEAD, 65,536 hex chars, the quote, then 0-2 spaces to a multiple of 3.
            let m := add(sectionSize(head), add(HEX_CHARS, 1))
            m := add(m, mod(sub(3, mod(m, 3)), 3))
            // The whole answer: scheme, PREFIX, base64 piece (4 bytes per 3), TAIL, `"}`.
            let total :=
                add(add(SCHEME, sectionSize(prefix)), add(div(mul(m, 4), 3), add(sectionSize(tail), 2)))

            // ABI head of the returned string: offset, length, then the bytes.
            let ptr := mload(0x40)
            mstore(ptr, 0x20)
            mstore(add(ptr, 32), total)
            mstore(add(ptr, 64), "data:application/json;utf8,")
            // The base64 piece occupies [piece, piece + 4m/3). Its raw bytes go to the last m of those.
            let piece := copyChunks(prefix, add(ptr, add(64, SCHEME)))
            let raw := add(piece, div(m, 3))
            let hexStart := copyChunks(head, raw)

            {
                // The grids, live from the glyph collection, land in the second half of the hex room and
                // are expanded forward: input word i sits at hexStart + 32768 + 32i, its 64 chars go to
                // hexStart + 64i, which never reaches an unread input word.
                mstore(0, gridsCall)
                if iszero(staticcall(gas(), source, 0, 4, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
                if iszero(eq(returndatasize(), add(64, GRID_BYTES))) {
                    mstore(0, unavailable)
                    revert(0, 4)
                }
                returndatacopy(0, 0, 64)
                if or(iszero(eq(mload(0), 0x20)), iszero(eq(mload(32), GRID_BYTES))) {
                    mstore(0, unavailable)
                    revert(0, 4)
                }
                let scratch := add(hexStart, GRID_BYTES)
                returndatacopy(scratch, 64, GRID_BYTES)
                let out := hexStart
                for { let at := scratch } lt(at, add(scratch, GRID_BYTES)) { at := add(at, 32) } {
                    let w := mload(at)
                    mstore(out, hexHalf(shr(128, w)))
                    mstore(add(out, 32), hexHalf(and(w, 0xffffffffffffffffffffffffffffffff)))
                    out := add(out, 64)
                }
                // The closing quote of the JS string, then the padding spaces up to raw + m.
                mstore8(out, 0x27)
                for { let k := add(out, 1) } lt(k, add(raw, m)) { k := add(k, 1) } { mstore8(k, 0x20) }
            }

            {
                let src := raw
                let dst := piece
                let last := add(raw, m)
                // Whole blocks of 24 bytes: block j is read from raw + 24j and written, 32 bytes, to
                // piece + 32j, which ends below raw + 24j + 24, the next unread byte, since raw = piece + m/3.
                for {} iszero(lt(sub(last, src), 24)) {} {
                    mstore(dst, base64Block(shr(64, mload(src))))
                    src := add(src, 24)
                    dst := add(dst, 32)
                }
                // The last groups of 3 (fewer than 8), one at a time through the alphabet in memory.
                mstore(0, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")
                mstore(32, "ghijklmnopqrstuvwxyz0123456789+/")
                for {} lt(src, last) {} {
                    let v := shr(232, mload(src))
                    mstore8(dst, shr(248, mload(shr(18, v))))
                    mstore8(add(dst, 1), shr(248, mload(and(shr(12, v), 63))))
                    mstore8(add(dst, 2), shr(248, mload(and(shr(6, v), 63))))
                    mstore8(add(dst, 3), shr(248, mload(and(v, 63))))
                    src := add(src, 3)
                    dst := add(dst, 4)
                }
            }

            let pos := copyChunks(tail, add(raw, m))
            mstore8(pos, 0x22) // "
            mstore8(add(pos, 1), 0x7d) // }
            pos := add(pos, 2)
            if iszero(eq(pos, add(add(ptr, 64), total))) { revert(0, 0) }
            // Zero the padding of the last word and hand the ABI-encoded string back as is.
            mstore(pos, 0)
            return(ptr, add(64, and(add(total, 31), not(31))))
        }
    }

    /// @notice Collection-level metadata for marketplace pages.
    function contractURI() external view returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        _escapeJson(name()),
                        '","description":"',
                        _escapeJson(description),
                        '","external_link":"',
                        _escapeJson(externalUrl),
                        '","seller_fee_basis_points":',
                        uint256(ROYALTY_BPS).toString(),
                        ',"fee_recipient":"',
                        uint256(uint160(royaltyReceiver)).toHexString(20),
                        '"}'
                    )
                )
            )
        );
    }

    /// @notice ERC-2981. Royalties are advisory: marketplaces decide whether to pay them.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver, (salePrice * ROYALTY_BPS) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------ internals

    /// @dev Keeps a section's chunk list and checks that their data, concatenated, hashes to `hash`.
    function _store(address[] storage into, address[] memory chunks, bytes32 hash) private {
        if (chunks.length == 0) revert InvalidConfiguration();
        uint256 total;
        for (uint256 i; i < chunks.length; ++i) {
            total += _chunkSize(chunks[i]);
            into.push(chunks[i]);
        }
        bytes memory all = new bytes(total);
        uint256 pos;
        for (uint256 i; i < chunks.length; ++i) {
            address chunk = chunks[i];
            assembly ("memory-safe") {
                let size := sub(extcodesize(chunk), 1)
                extcodecopy(chunk, add(add(all, 32), pos), 1, size)
                pos := add(pos, size)
            }
        }
        if (keccak256(all) != hash) revert InvalidConfiguration();
    }

    /// @dev The data bytes of an SSTORE2 chunk: its code must be `0x00 || data` with at least one data byte.
    function _chunkSize(address chunk) private view returns (uint256) {
        uint256 size = chunk.code.length;
        uint256 lead;
        assembly ("memory-safe") {
            extcodecopy(chunk, 0, 0, 1)
            lead := byte(0, mload(0))
        }
        if (size < 2 || lead != 0) revert InvalidConfiguration();
        return size - 1;
    }

    /// @dev Text is escaped so the JSON cannot be broken. Two passes keep this allocation-exact.
    function _escapeJson(string memory input) private pure returns (string memory) {
        bytes memory data = bytes(input);
        uint256 length = 0;
        for (uint256 i; i < data.length; ++i) {
            bytes1 c = data[i];
            length += (c == '"' || c == "\\") ? 2 : (uint8(c) >= 0x20 ? 1 : 6);
        }
        if (length == data.length) return input;
        bytes memory out = new bytes(length);
        uint256 n = 0;
        for (uint256 i; i < data.length; ++i) {
            bytes1 c = data[i];
            if (c == '"' || c == "\\") {
                out[n++] = "\\";
                out[n++] = c;
            } else if (uint8(c) >= 0x20) {
                out[n++] = c;
            } else {
                // Control characters must be escaped as \u00XX to stay valid JSON.
                out[n++] = "\\";
                out[n++] = "u";
                out[n++] = "0";
                out[n++] = "0";
                out[n++] = bytes1(_hexDigit(uint8(c) >> 4));
                out[n++] = bytes1(_hexDigit(uint8(c) & 0x0f));
            }
        }
        return string(out);
    }

    function _hexDigit(uint8 value) private pure returns (uint8) {
        return value < 10 ? 48 + value : 87 + value;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this) || to == minter) revert InvalidRecipient();
        return super._update(to, tokenId, auth);
    }
}
