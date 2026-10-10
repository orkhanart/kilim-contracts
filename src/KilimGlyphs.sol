// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Kilim Glyphs: up to `glyphCap` tokens, ids 1..glyphCap, each showing one of the 1,024 glyphs.
/// @dev No admin, pause, upgrade, metadata setter or ownership role: everything is fixed at construction.
///      The glyph a token shows depends only on the chain, this address and the token id: public from
///      deployment, NOT randomness. The grids and names live in SSTORE2 chunks (runtime code `0x00 || data`)
///      whose contents are hashed at construction, so the 1/1 and every glyph token draw from the same bytes.
contract KilimGlyphs is ERC721, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant GLYPH_COUNT = 1024;
    uint256 public constant MAX_MINT_BATCH = 64;
    /// @notice Grid chunks are cut at 767 grids (24,544 bytes) so no grid straddles two chunks.
    uint256 public constant GRIDS_PER_CHUNK = 767;
    /// @notice The names chunk starts with 1,025 big-endian uint16 offsets, then the names concatenated.
    uint256 public constant NAME_OFFSET_TABLE = 2 * (GLYPH_COUNT + 1);
    /// @notice Resale royalty, fixed forever. Marketplaces may ignore royalties entirely.
    uint96 public constant ROYALTY_BPS = 500;

    address public immutable minter;
    address public immutable royaltyReceiver;
    uint256 public immutable glyphCap;
    bytes32 public immutable gridsHash;
    bytes32 public immutable namesHash;
    address public immutable namesChunk;
    /// @dev Written once in the constructor, never again.
    address[] private _gridChunks;
    string public description;
    string public externalUrl;
    uint256 public glyphsMinted;
    uint256 public glyphsBurned;
    /// @dev A burned id keeps no owner, so this bitmap is what stops it from being minted again.
    mapping(uint256 => uint256) private _burned;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidRecipient();
    error InvalidQuantity();
    error SupplyExceeded();
    error AlreadyMinted();
    error InvalidTokenId(uint256 id);
    error InvalidGlyph(uint16 glyph);

    event GlyphsMinted(address indexed recipient, address indexed bidder, uint256 firstId, uint256 quantity);

    constructor(
        address minter_,
        address royaltyReceiver_,
        uint256 glyphCap_,
        address[] memory gridChunks_,
        bytes32 gridsHash_,
        address namesChunk_,
        bytes32 namesHash_,
        string memory description_,
        string memory externalUrl_
    ) ERC721("Kilim Glyphs", "GLYPH") {
        if (
            minter_ == address(0) || royaltyReceiver_ == address(0) || glyphCap_ == 0
                || glyphCap_ > type(uint32).max || gridChunks_.length == 0
        ) revert InvalidConfiguration();
        // Every grid chunk but the last is full, so a grid's chunk and offset follow from its number.
        uint256 total = 0;
        for (uint256 i; i < gridChunks_.length; ++i) {
            uint256 size = _chunkSize(gridChunks_[i]);
            if (i + 1 < gridChunks_.length && size != GRIDS_PER_CHUNK * 32) revert InvalidConfiguration();
            total += size;
            _gridChunks.push(gridChunks_[i]);
        }
        if (total != GLYPH_COUNT * 32 || keccak256(_grids()) != gridsHash_) revert InvalidConfiguration();
        bytes memory names = new bytes(_chunkSize(namesChunk_));
        _copyChunk(namesChunk_, names);
        if (keccak256(names) != namesHash_) revert InvalidConfiguration();
        _checkNames(names);
        minter = minter_;
        royaltyReceiver = royaltyReceiver_;
        glyphCap = glyphCap_;
        gridsHash = gridsHash_;
        namesHash = namesHash_;
        namesChunk = namesChunk_;
        description = description_;
        externalUrl = externalUrl_;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert Unauthorized();
        _;
    }

    // ------------------------------------------------------------ minting and burning

    /// @notice Mint glyph ids that the auction reserved for `bidder` when the bid was placed.
    /// @dev The minter chooses the ids. Each id can be minted once, even after it is burned.
    function mintGlyphs(address to, address bidder, uint256 firstId, uint256 quantity)
        external
        onlyMinter
        nonReentrant
    {
        _validateRecipient(to);
        if (bidder == address(0)) revert InvalidRecipient();
        if (quantity == 0 || quantity > MAX_MINT_BATCH) revert InvalidQuantity();
        // Ids run 1..glyphCap. The first clause keeps the subtraction below from underflowing.
        if (quantity > glyphCap || firstId == 0 || firstId - 1 > glyphCap - quantity) {
            revert SupplyExceeded();
        }
        glyphsMinted += quantity;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = firstId + i;
            if (_ownerOf(id) != address(0) || burned(id)) revert AlreadyMinted();
            _safeMint(to, id);
        }
        emit GlyphsMinted(to, bidder, firstId, quantity);
    }

    /// @notice Burn a glyph you own. Approvals do not count: trading rights are not destruction rights.
    /// @dev The Weaver will call this after a collector transfers glyphs to it. The id stays taken.
    function burn(uint256 id) external {
        if (ownerOf(id) != msg.sender) revert Unauthorized();
        _burned[id >> 8] |= 1 << (id & 0xff);
        ++glyphsBurned;
        _burn(id);
    }

    /// @notice Whether `id` was minted and then burned. Such an id can never be minted again.
    function burned(uint256 id) public view returns (bool) {
        return _burned[id >> 8] & (1 << (id & 0xff)) != 0;
    }

    // ------------------------------------------------------------ glyph data

    /// @notice Which of the 1,024 glyphs token `id` shows, for any id in 1..glyphCap, minted or not.
    ///         Fixed at deployment, independent of bidder, recipient and claim time. Public, NOT randomness.
    function glyphOf(uint256 id) public view returns (uint16) {
        if (id == 0 || id > glyphCap) revert InvalidTokenId(id);
        return uint16(uint256(keccak256(abi.encode(block.chainid, address(this), id))) % GLYPH_COUNT + 1);
    }

    /// @notice Glyph `glyph`'s 16 x 16 grid: row 0 first, bit (r, c) is bit 255 - (r * 16 + c).
    function grid(uint16 glyph) public view returns (bytes32 out) {
        if (glyph == 0 || glyph > GLYPH_COUNT) revert InvalidGlyph(glyph);
        uint256 index = glyph - 1;
        address chunk = _gridChunks[index / GRIDS_PER_CHUNK];
        uint256 offset = 1 + (index % GRIDS_PER_CHUNK) * 32; // past the chunk's leading 0x00
        assembly ("memory-safe") {
            extcodecopy(chunk, 0, offset, 32)
            out := mload(0)
        }
    }

    /// @notice Glyph `glyph`'s name. Names are plain ASCII and not unique.
    function name(uint16 glyph) public view returns (string memory) {
        if (glyph == 0 || glyph > GLYPH_COUNT) revert InvalidGlyph(glyph);
        address chunk = namesChunk;
        uint256 start;
        uint256 end;
        assembly ("memory-safe") {
            // The two offsets that bound the name sit next to each other in the table.
            extcodecopy(chunk, 0, add(1, shl(1, sub(glyph, 1))), 4)
            let w := mload(0)
            start := shr(240, w)
            end := and(shr(224, w), 0xffff)
        }
        bytes memory out = new bytes(end - start);
        uint256 from = 1 + NAME_OFFSET_TABLE + start;
        assembly ("memory-safe") {
            extcodecopy(chunk, add(out, 32), from, mload(out))
        }
        return string(out);
    }

    /// @notice All 1,024 grids, 32,768 bytes, glyph n at offset (n - 1) * 32. The 1/1 reads this.
    function grids() external view returns (bytes memory) {
        return _grids();
    }

    function gridChunks() external view returns (address[] memory) {
        return _gridChunks;
    }

    // ------------------------------------------------------------ metadata

    /// @notice Fully on-chain metadata: the glyph as an SVG, its number and its name.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        uint16 glyph = glyphOf(id);
        string memory glyphName = _escapeJson(name(glyph));
        string memory number = uint256(glyph).toString();
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        glyphName,
                        " (glyph ",
                        number,
                        ')","description":"',
                        _escapeJson(description),
                        '","image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(svg(glyph))),
                        '","attributes":[{"trait_type":"Glyph","value":',
                        number,
                        '},{"trait_type":"Name","value":"',
                        glyphName,
                        '"}]}'
                    )
                )
            )
        );
    }

    /// @notice The glyph drawn on a 20 x 20 paper, ink at offset (2, 2), one rect per horizontal run.
    function svg(uint16 glyph) public view returns (string memory) {
        uint256 bits = uint256(grid(glyph));
        string memory rects = "";
        for (uint256 r; r < 16; ++r) {
            uint256 row = (bits >> (240 - 16 * r)) & 0xffff; // bit 15 is column 0
            for (uint256 c; c < 16;) {
                if (row & (0x8000 >> c) == 0) {
                    ++c;
                    continue;
                }
                uint256 start = c;
                while (c < 16 && row & (0x8000 >> c) != 0) {
                    ++c;
                }
                rects = string.concat(
                    rects,
                    '<rect x="',
                    (2 + start).toString(),
                    '" y="',
                    (2 + r).toString(),
                    '" width="',
                    (c - start).toString(),
                    '" height="1"/>'
                );
            }
        }
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" shape-rendering="crispEdges">',
            '<rect width="20" height="20" fill="#FFFFFF"/><g fill="#141414">',
            rects,
            "</g></svg>"
        );
    }

    /// @notice Collection-level metadata for marketplace pages.
    function contractURI() external view returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Kilim Glyphs","description":"',
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

    function _grids() private view returns (bytes memory out) {
        out = new bytes(GLYPH_COUNT * 32);
        uint256 pos;
        uint256 count = _gridChunks.length;
        for (uint256 i; i < count; ++i) {
            address chunk = _gridChunks[i];
            assembly ("memory-safe") {
                let size := sub(extcodesize(chunk), 1)
                extcodecopy(chunk, add(add(out, 32), pos), 1, size)
                pos := add(pos, size)
            }
        }
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

    function _copyChunk(address chunk, bytes memory into) private view {
        assembly ("memory-safe") {
            extcodecopy(chunk, add(into, 32), 1, mload(into))
        }
    }

    /// @dev Offsets must not decrease and the last one must end exactly at the end of the section, so
    ///      every name read stays inside the chunk.
    function _checkNames(bytes memory names) private pure {
        if (names.length < NAME_OFFSET_TABLE) revert InvalidConfiguration();
        uint256 previous = 0;
        for (uint256 i; i <= GLYPH_COUNT; ++i) {
            uint256 offset = (uint256(uint8(names[2 * i])) << 8) | uint8(names[2 * i + 1]);
            if (offset < previous) revert InvalidConfiguration();
            previous = offset;
        }
        if (NAME_OFFSET_TABLE + previous != names.length) revert InvalidConfiguration();
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

    function _validateRecipient(address to) private view {
        if (to == address(0) || to == address(this) || to == minter) revert InvalidRecipient();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this) || to == minter) revert InvalidRecipient();
        return super._update(to, tokenId, auth);
    }
}
