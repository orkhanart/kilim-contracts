// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKilimRenderer} from "./IKilimRenderer.sol";
import {KilimWriter as W} from "./KilimWriter.sol";

/// @title KilimRenderer
/// @notice Draws the metadata and media of every Kilim token (symbols, artworks and the 1/1) from geometry and
///         a page stored on Ethereum, and returns them as base64 data URIs.
/// @dev Immutable: no owner, no setters, no delegatecall, no selfdestruct. Every view is a pure function of its
///      arguments and STORE, one byte string held as SSTORE2 code in the data contracts listed by `chunks()`:
///
///        [0, 64)  header: "KLM1", u32 geoLen, idxLen, pageLen, stillAt, symbolsAt, u16 still[9], zero padding
///        GEOM     the raw varint geometry              (keccak256 = geometryHash)
///        INDEX    16 B per motif: u32 offset, u32 length, i16 minX, i16 minY, u16 w, u16 h (= indexHash)
///        PAGE     the 1/1 page with its two splice tokens removed at stillAt and symbolsAt (= pageHash)
///
///      onchain/pack_store.py writes it; docs/RENDERER.md publishes the recipe. The constructor proves STORE is
///      well formed and hashes to the three committed values, then deploys TABLES (lookup tables it derives).
///      Output formats are specified byte for byte by onchain/render_ref.py and pinned by golden tests.
///      All text is written through KilimWriter (read its memory rules first). Every external view ends with
///      KilimWriter.ret, which halts the call: none of them can be called internally.
contract KilimRenderer is IKilimRenderer {
    // ============================================================ artist-facing constants
    // Change freely before deploy. onchain/render_ref.py repeats them, and the golden tests fail until the
    // two agree. Descriptions must stay ASCII with no quote, backslash or control character (they go into
    // JSON verbatim).
    bytes private constant NAME_SYMBOL = "Kilim Symbol #";
    bytes private constant NAME_ARTWORK = "Kilim Artwork #";
    bytes private constant NAME_MASTERPIECE = "Kilim 1/1";
    bytes private constant DESC_SYMBOL =
        "One Kilim symbol: a motif in its material, drawn by this contract from geometry stored on Ethereum. Motif and material were fixed when the collection was deployed.";
    bytes private constant DESC_ARTWORK =
        "A Kilim artwork, woven on-chain from burned symbols and drawn by this contract from geometry stored on Ethereum.";
    bytes private constant DESC_MASTERPIECE =
        "Kilim 1/1. Every motif in the collection on the grid of the original RELIC print. Interactive: click to re-weave. Served entirely from Ethereum.";
    bytes private constant KIND_MASTERPIECE = "Masterpiece";
    /// @dev Symbol ground (site/lib.js:8). The 1/1 still uses the page's own resting colours instead.
    bytes private constant PAPER = "#f7f6f2";
    bytes private constant STILL_GROUND = "#fff";
    bytes private constant STILL_INK = "#0b0b0b";
    bytes32 private constant APPEARANCE_INK = "flat/ink";
    bytes32 private constant APPEARANCE_INDIGO = "flat/indigo";
    bytes32 private constant APPEARANCE_VERMILION = "flat/vermilion";

    /// @dev Cotton rag (material 5) is a blind emboss of three copies: shadow, highlight, face.
    function _emboss(uint256 k) private pure returns (bytes memory x, bytes memory y, bytes memory colour) {
        if (k == 0) return ("92", "108", "#cbcac7");
        if (k == 1) return ("108", "92", "#ffffff");
        return ("100", "100", "#eae9e8");
    }

    /// @dev Gradient stops per material, lit from the upper right (x1=1 y1=0 -> x2=0 y2=1).
    function _stops(uint256 mat) private pure returns (bytes memory) {
        if (mat == 0) {
            return '<stop offset="0" stop-color="#2b532c"/><stop offset="1" stop-color="#1f4022"/>';
        }
        if (mat == 1) {
            return '<stop offset="0" stop-color="#9b684e"/><stop offset="1" stop-color="#7c5039"/>';
        }
        if (mat == 2) {
            return '<stop offset="0" stop-color="#deca9c"/><stop offset="0.35" stop-color="#a89361"/><stop offset="1" stop-color="#78704c"/>';
        }
        if (mat == 3) {
            return '<stop offset="0" stop-color="#29402a"/><stop offset="1" stop-color="#0e2610"/>';
        }
        if (mat == 4) {
            return '<stop offset="0" stop-color="#236243"/><stop offset="1" stop-color="#115031"/>';
        }
        return '<stop offset="0" stop-color="#e8d59a"/><stop offset="0.35" stop-color="#cab06e"/><stop offset="1" stop-color="#88743d"/>';
    }

    /// @dev English trait names (site/lib.js:210-212, title-cased).
    function _materialName(uint256 mat) private pure returns (bytes memory) {
        if (mat == 0) return "Dyed wool";
        if (mat == 1) return "Terracotta";
        if (mat == 2) return "Aged brass";
        if (mat == 3) return "Black lacquer";
        if (mat == 4) return "Nephrite";
        return "Cotton rag";
    }

    /// @dev Azerbaijani trait names: the material codes of site/engine.js:448-450, title-cased.
    function _materialNameAz(uint256 mat) private pure returns (bytes memory) {
        if (mat == 0) return "Yun";
        if (mat == 1) return "Palciq";
        if (mat == 2) return "Misgar";
        if (mat == 3) return "Gece";
        if (mat == 4) return "Yashm";
        return "Kagiz";
    }

    /// @dev Artwork appearance -> (trait label, ink, plate), site/merge-render.js:6-8.
    function _appearance(bytes32 a)
        private
        pure
        returns (bytes memory label, bytes memory ink, bytes memory plate)
    {
        if (a == APPEARANCE_INK) return ("Ink on paper", "#171914", "#f7f6f2");
        if (a == APPEARANCE_INDIGO) return ("Indigo textile", "#eee6d4", "#283c60");
        if (a == APPEARANCE_VERMILION) return ("Vermilion print", "#a63425", "#f1e5cd");
        revert UnknownAppearance();
    }

    // ============================================================ store

    uint256 private constant CHUNK = 24_575;
    uint256 private constant HDR = 64;
    /// @dev GEOM is base64'd for the 1/1 in pieces of this size, a multiple of 24 (and so of 3): the pieces'
    ///      encodings concatenate to the encoding of the whole, and the staging buffer stays small.
    uint256 private constant STAGE = 24_576;
    uint16 private constant EMPTY = type(uint16).max;
    uint256 private constant MAX_CELLS = 256;
    /// @dev The 1/1 still: a 3x3 window of the sheet in quarter units, cell pitch rounded from 175.9 x 182.1.
    uint256 private constant STILL_PX = 176;
    uint256 private constant STILL_PY = 182;

    /// @notice STORE failed a constructor check. Codes: 1 no chunks, 2 chunk size, 3 chunk prefix byte,
    ///         4 magic, 5 header padding, 6 section lengths, 7 splice offsets, 8 geometry hash, 9 motif count,
    ///         10 index length, 11 still motifs, 12 index hash, 13 index offsets, 14 zero bbox side,
    ///         15 index end, 16 page hash, 17 TABLES deployment.
    error BadStore(uint256 code);
    error BadLayout();
    error UnknownAppearance();
    error UnknownMotif();
    error UnknownMaterial();

    address[] private _chunks;
    /// @notice Data contract holding the number table and the base64 pair table (KilimWriter.tables()).
    address public immutable TABLES;
    uint256 public immutable motifCount;
    bytes32 public immutable geometryHash;
    bytes32 public immutable indexHash;
    bytes32 public immutable pageHash;
    uint256 private immutable GEO_LEN;
    uint256 private immutable IDX_OFF;
    uint256 private immutable PAGE_OFF;
    uint256 private immutable PAGE_LEN;
    uint256 private immutable STILL_AT;
    uint256 private immutable SYMBOLS_AT;
    uint256 private immutable MAX_REC;
    /// @dev The 1/1 still's nine motifs, 16 bits each, still[0] in the top bits.
    uint256 private immutable STILL;

    struct Layout {
        uint256 count;
        uint256 geoLen;
        uint256 idxLen;
        uint256 pageLen;
        uint256 stillAt;
        uint256 symbolsAt;
        uint256 still;
        uint256 maxRec;
    }

    /// @param chunks_ The data contracts, in order, whose code (after a 0x00 byte) concatenates to STORE.
    constructor(address[] memory chunks_, bytes32 geometryHash_, bytes32 indexHash_, bytes32 pageHash_) {
        Layout memory l = _verify(chunks_, geometryHash_, indexHash_, pageHash_);
        bytes memory code =
            abi.encodePacked(hex"61", uint16(W.TABLES_SIZE + 1), hex"80600a3d393df300", W.tables());
        address t;
        assembly ("memory-safe") {
            t := create(0, add(code, 32), mload(code))
        }
        if (t == address(0)) revert BadStore(17);
        TABLES = t;
        motifCount = l.count;
        geometryHash = geometryHash_;
        indexHash = indexHash_;
        pageHash = pageHash_;
        GEO_LEN = l.geoLen;
        IDX_OFF = HDR + l.geoLen;
        PAGE_OFF = HDR + l.geoLen + l.idxLen;
        PAGE_LEN = l.pageLen;
        STILL_AT = l.stillAt;
        SYMBOLS_AT = l.symbolsAt;
        MAX_REC = l.maxRec;
        STILL = l.still;
    }

    function _verify(address[] memory chunks_, bytes32 gh, bytes32 ih, bytes32 ph)
        private
        returns (Layout memory l)
    {
        uint256 n = chunks_.length;
        if (n == 0) revert BadStore(1);
        uint256 total;
        for (uint256 k; k < n; ++k) {
            address c = chunks_[k];
            uint256 size = c.code.length;
            if (size < 2 || size > CHUNK + 1 || (k + 1 < n && size != CHUNK + 1)) revert BadStore(2);
            uint256 first;
            assembly ("memory-safe") {
                extcodecopy(c, 0, 0, 1)
                first := byte(0, mload(0))
            }
            if (first != 0) revert BadStore(3);
            total += size - 1;
            _chunks.push(c);
        }
        uint256 slot;
        assembly ("memory-safe") {
            slot := _chunks.slot
        }
        assert(slot == 0); // _read's CHUNKS_DATA is keccak256(0)
        if (total < HDR) revert BadStore(6);
        bytes memory h = _readMem(0, HDR);
        uint256 w0;
        uint256 w1;
        assembly ("memory-safe") {
            w0 := mload(add(h, 32))
            w1 := mload(add(h, 64))
        }
        if (w0 >> 224 != 0x4b4c4d31) revert BadStore(4); // "KLM1"
        if (w1 & ((1 << 176) - 1) != 0) revert BadStore(5);
        l.geoLen = (w0 >> 192) & 0xffffffff;
        l.idxLen = (w0 >> 160) & 0xffffffff;
        l.pageLen = (w0 >> 128) & 0xffffffff;
        l.stillAt = (w0 >> 96) & 0xffffffff;
        l.symbolsAt = (w0 >> 64) & 0xffffffff;
        l.still = ((w0 & 0xffffffffffffffff) << 80) | (w1 >> 176);
        if (HDR + l.geoLen + l.idxLen + l.pageLen != total) revert BadStore(6);
        if (l.stillAt > l.symbolsAt || l.symbolsAt > l.pageLen) revert BadStore(7);

        bytes memory geo = _readMem(HDR, l.geoLen);
        if (keccak256(geo) != gh) revert BadStore(8);
        uint256 p;
        (l.count, p) = _count(geo);
        if (l.idxLen != 16 * l.count) revert BadStore(10);
        for (uint256 k; k < 9; ++k) {
            uint256 m = (l.still >> (16 * (8 - k))) & 0xffff;
            if ((m == EMPTY && k == 4) || (m != EMPTY && m >= l.count)) revert BadStore(11);
        }
        bytes memory idx = _readMem(HDR + l.geoLen, l.idxLen);
        if (keccak256(idx) != ih) revert BadStore(12);
        for (uint256 m; m < l.count; ++m) {
            uint256 r;
            assembly ("memory-safe") {
                r := mload(add(add(idx, 32), shl(4, m)))
            }
            uint256 len = (r >> 192) & 0xffffffff;
            if (r >> 224 != p || len == 0) revert BadStore(13);
            if ((r >> 144) & 0xffff == 0 || (r >> 128) & 0xffff == 0) revert BadStore(14);
            p += len;
            if (len > l.maxRec) l.maxRec = len;
        }
        if (p != l.geoLen) revert BadStore(15);
        if (keccak256(_readMem(HDR + l.geoLen + l.idxLen, l.pageLen)) != ph) revert BadStore(16);
    }

    /// @dev The leading varint of GEOM: 1..65535, at most 3 bytes, inside GEOM.
    function _count(bytes memory geo) private pure returns (uint256 count, uint256 p) {
        uint256 shift;
        while (true) {
            if (p >= geo.length || p == 3) revert BadStore(9);
            uint8 b = uint8(geo[p++]);
            count |= uint256(b & 0x7f) << shift;
            shift += 7;
            if (b < 0x80) break;
        }
        if (count == 0 || count > type(uint16).max) revert BadStore(9);
    }

    // ============================================================ views: data

    /// @notice The data contracts holding STORE, in order.
    function chunks() external view returns (address[] memory) {
        return _chunks;
    }

    /// @notice The 1/1 still's motifs: the 3x3 cells of the page's opening pattern around its hero cell,
    ///         row-major; 65535 where the sheet has no cell.
    function stillMotifs() external view returns (uint16[9] memory out) {
        for (uint256 k; k < 9; ++k) {
            out[k] = uint16(STILL >> (16 * (8 - k)));
        }
    }

    /// @notice The motif the 1/1 page opens on.
    function heroMotif() external view returns (uint256) {
        return uint16(STILL >> 64);
    }

    /// @notice The stored geometry, exactly (keccak256 of this equals geometryHash).
    function geometry() external view returns (bytes memory) {
        uint256 start = W.buf(GEO_LEN);
        _read(HDR, GEO_LEN, start);
        W.ret(start, start + GEO_LEN);
    }

    // ============================================================ views: images and page

    /// @notice SVG path text of one motif, in its own quarter-unit coordinates.
    function motifPath(uint256 motif) external view returns (string memory) {
        if (motif >= motifCount) revert UnknownMotif();
        uint256 nt = _tables();
        uint256 r = _rec(motif, nt);
        uint256 bound = 3 * _len(r);
        uint256 start = W.buf(bound);
        W.ret(start, W.check(start, bound, _path(start, r, nt)));
    }

    /// @notice One motif in one material (0..6; 6 is leaf gold, used by no token) as a 1000 x 1000 SVG.
    function symbolSVG(uint256 motif, uint256 material) external view returns (string memory) {
        if (motif >= motifCount) revert UnknownMotif();
        if (material > 6) revert UnknownMaterial();
        uint256 nt = _tables();
        (uint256 start, uint256 end) = _symbolDoc(motif, material, nt);
        W.ret(start, end);
    }

    /// @notice An artwork's image: motifs in row-major order on a square canvas.
    function artworkSVG(uint16[] calldata motifs, uint256 columns, uint256 rows, bytes32 appearance)
        external
        view
        returns (string memory)
    {
        uint256 nt = _tables();
        (uint256 start, uint256 end,) = _artworkDoc(motifs, columns, rows, appearance, nt);
        W.ret(start, end);
    }

    /// @notice The 1/1's `image`: the page's opening frame (the hero cell and its neighbours) as a still,
    ///         the same drawing the page shows before, or instead of, running its script.
    function stillSVG() external view returns (string memory) {
        uint256 nt = _tables();
        (uint256 start, uint256 end) = _stillDoc(nt);
        W.ret(start, end);
    }

    /// @notice The 1/1's interactive page as raw HTML, for archiving or opening full-window (browsers block
    ///         top-level navigation to the data: URI in animation_url).
    function masterpieceHTML() external view returns (string memory) {
        uint256 nt = _tables();
        (uint256 still, uint256 stillEnd) = _stillDoc(nt);
        (uint256 start, uint256 end) = _htmlDoc(still, stillEnd - still, nt);
        W.ret(start, end);
    }

    // ============================================================ views: token metadata

    /// @inheritdoc IKilimRenderer
    function symbolURI(uint256 tokenId, bytes32 seed, uint16 motif, uint8 material)
        external
        view
        returns (string memory)
    {
        if (motif >= motifCount) revert UnknownMotif();
        if (material > 5) revert UnknownMaterial();
        uint256 nt = _tables();
        (uint256 svg, uint256 svgEnd) = _symbolDoc(motif, material, nt);
        bytes memory en = _materialName(material);
        bytes memory az = _materialNameAz(material);
        uint256 len = 271 + NAME_SYMBOL.length + DESC_SYMBOL.length + W.digits(tokenId)
            + W.digits(uint256(motif) + 1) + en.length + az.length + W.b64len(svgEnd - svg) + 132;
        uint256 j = W.buf(len);
        uint256 o = W.s(j, '{"name":"');
        o = W.s(o, NAME_SYMBOL);
        o = W.u(o, tokenId);
        o = W.s(o, '","description":"');
        o = W.s(o, DESC_SYMBOL);
        o = W.s(o, '","image":"data:image/svg+xml;base64,');
        o = W.b64(svg, svgEnd - svg, o, nt + W.NUMBER_TABLE);
        o = W.s(o, '","attributes":[{"trait_type":"Kind","value":"Symbol"},{"trait_type":"Motif","value":"#');
        o = W.u(o, uint256(motif) + 1);
        o = W.s(o, '"},{"trait_type":"Material","value":"');
        o = W.s(o, en);
        o = W.s(o, '"},{"trait_type":"Material (Azerbaijani)","value":"');
        o = W.s(o, az);
        o = W.s(o, '"}],"seed":"');
        o = W.hex32(o, seed);
        o = W.s(o, '","geometry_hash":"');
        o = W.hex32(o, geometryHash);
        o = W.s(o, '"}');
        _wrap(j, W.exact(j, len, o), nt);
    }

    /// @inheritdoc IKilimRenderer
    function artworkURI(
        uint256 number,
        uint16[] calldata motifs,
        uint16 columns,
        uint16 rows,
        bytes32 appearance,
        uint64 revision,
        bool frozen
    ) external view returns (string memory) {
        uint256 nt = _tables();
        Art memory a = Art(number, columns, rows, 0, revision, frozen, appearance);
        (uint256 svg, uint256 svgEnd, uint256 distinct) = _artworkDoc(motifs, columns, rows, appearance, nt);
        a.distinct = distinct;
        _artworkJson(a, svg, svgEnd, nt);
    }

    struct Art {
        uint256 number;
        uint256 cols;
        uint256 rows;
        uint256 distinct;
        uint256 revision;
        bool frozen;
        bytes32 appearance;
    }

    /// @dev Writes the artwork JSON around its image and ends the call through _wrap.
    function _artworkJson(Art memory a, uint256 svg, uint256 svgEnd, uint256 nt) private view {
        (bytes memory label,,) = _appearance(a.appearance);
        uint256 len = 507 + NAME_ARTWORK.length + DESC_ARTWORK.length + W.digits(a.number) + label.length
            + W.digits(a.cols) + W.digits(a.rows) + W.digits(a.cols * a.rows) + W.digits(a.distinct)
            + W.digits(a.revision) + (a.frozen ? 3 : 2) + W.b64len(svgEnd - svg) + 66;
        uint256 j = W.buf(len);
        uint256 o = W.s(j, '{"name":"');
        o = W.s(o, NAME_ARTWORK);
        o = W.u(o, a.number);
        o = W.s(o, '","description":"');
        o = W.s(o, DESC_ARTWORK);
        o = W.s(o, '","image":"data:image/svg+xml;base64,');
        o = W.b64(svg, svgEnd - svg, o, nt + W.NUMBER_TABLE);
        o = W.s(
            o, '","attributes":[{"trait_type":"Kind","value":"Artwork"},{"trait_type":"Appearance","value":"'
        );
        o = W.s(o, label);
        o = W.s(o, '"},{"display_type":"number","trait_type":"Columns","value":');
        o = W.u(o, a.cols);
        o = W.s(o, '},{"display_type":"number","trait_type":"Rows","value":');
        o = W.u(o, a.rows);
        o = W.s(o, '},{"display_type":"number","trait_type":"Cells","value":');
        o = W.u(o, a.cols * a.rows);
        o = W.s(o, '},{"display_type":"number","trait_type":"Distinct motifs","value":');
        o = W.u(o, a.distinct);
        o = W.s(o, '},{"display_type":"number","trait_type":"Revision","value":');
        o = W.u(o, a.revision);
        o = W.s(o, '},{"trait_type":"Frozen","value":"');
        o = W.s(o, a.frozen ? bytes("Yes") : bytes("No"));
        o = W.s(o, '"}],"geometry_hash":"');
        o = W.hex32(o, geometryHash);
        o = W.s(o, '"}');
        _wrap(j, W.exact(j, len, o), nt);
    }

    /// @inheritdoc IKilimRenderer
    function masterpieceURI() external view returns (string memory) {
        uint256 nt = _tables();
        (uint256 still, uint256 stillEnd) = _stillDoc(nt);
        (uint256 html, uint256 htmlEnd) = _htmlDoc(still, stillEnd - still, nt);
        uint256 len = 230 + NAME_MASTERPIECE.length + DESC_MASTERPIECE.length + KIND_MASTERPIECE.length
            + W.b64len(stillEnd - still) + W.b64len(htmlEnd - html) + W.digits(motifCount) + 66;
        uint256 j = W.buf(len);
        uint256 bt = nt + W.NUMBER_TABLE;
        uint256 o = W.s(j, '{"name":"');
        o = W.s(o, NAME_MASTERPIECE);
        o = W.s(o, '","description":"');
        o = W.s(o, DESC_MASTERPIECE);
        o = W.s(o, '","image":"data:image/svg+xml;base64,');
        o = W.b64(still, stillEnd - still, o, bt);
        o = W.s(o, '","animation_url":"data:text/html;base64,');
        o = W.b64(html, htmlEnd - html, o, bt);
        o = W.s(o, '","attributes":[{"trait_type":"Kind","value":"');
        o = W.s(o, KIND_MASTERPIECE);
        o = W.s(o, '"},{"display_type":"number","trait_type":"Motifs","value":');
        o = W.u(o, motifCount);
        o = W.s(o, '}],"geometry_hash":"');
        o = W.hex32(o, geometryHash);
        o = W.s(o, '"}');
        _wrap(j, W.exact(j, len, o), nt);
    }

    // ============================================================ documents

    bytes private constant SVG_HEAD =
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ';

    /// @dev "data:application/json;base64," + base64(json[j, end)), returned directly. Ends the call.
    function _wrap(uint256 j, uint256 end, uint256 nt) private pure {
        uint256 len = 29 + W.b64len(end - j);
        uint256 start = W.buf(len);
        uint256 o = W.s(start, "data:application/json;base64,");
        o = W.b64(j, end - j, o, nt + W.NUMBER_TABLE);
        W.ret(start, W.exact(start, len, o));
    }

    function _symbolDoc(uint256 motif, uint256 mat, uint256 nt)
        private
        view
        returns (uint256 start, uint256)
    {
        uint256 r = _rec(motif, nt);
        uint256 bound = 1300 + 3 * _len(r);
        start = W.buf(bound);
        uint256 o = W.s(start, SVG_HEAD);
        o = W.s(o, '1000 1000" width="1000" height="1000"><defs>');
        if (mat != 5) {
            o = W.s(o, '<linearGradient id="g');
            o = W.u(o, mat);
            o = W.s(o, '" x1="1" y1="0" x2="0" y2="1">');
            o = W.s(o, _stops(mat));
            o = W.s(o, "</linearGradient>");
        }
        o = _symbolDef(o, motif, r, nt);
        o = W.s(o, '</defs><rect width="1000" height="1000" fill="');
        o = W.s(o, PAPER);
        o = W.s(o, '"/>');
        if (mat != 5) {
            o = W.s(o, '<use xlink:href="#m');
            o = W.u(o, motif);
            o = W.s(o, '" x="100" y="100" width="800" height="800" fill="url(#g');
            o = W.u(o, mat);
            o = W.s(o, ')"/>');
        } else {
            for (uint256 k; k < 3; ++k) {
                (bytes memory x, bytes memory y, bytes memory colour) = _emboss(k);
                o = W.s(o, '<use xlink:href="#m');
                o = W.u(o, motif);
                o = W.s(o, '" x="');
                o = W.s(o, x);
                o = W.s(o, '" y="');
                o = W.s(o, y);
                o = W.s(o, '" width="800" height="800" fill="');
                o = W.s(o, colour);
                o = W.s(o, '"/>');
            }
        }
        o = W.s(o, "</svg>");
        return (start, W.check(start, bound, o));
    }

    /// @dev Pass 1 validates the layout, marks each distinct motif in the seen-map and sizes the buffer:
    ///      700 + 90 per cell + (140 + 3 x record bytes) per distinct motif. Pass 2 writes one <symbol> per
    ///      distinct motif in order of first appearance, then one <use> per cell.
    function _artworkDoc(uint16[] calldata motifs, uint256 cols, uint256 rows, bytes32 appearance, uint256 nt)
        private
        view
        returns (uint256 start, uint256 end, uint256 distinct)
    {
        uint256 bound = _artworkBound(motifs, cols, rows, appearance, nt);
        start = W.buf(bound);
        uint256 size = cols * 2000 > rows * 2150 ? cols * 2000 : rows * 2150;
        uint256 o = W.s(start, SVG_HEAD);
        o = W.u(o, size);
        o = W.w(o, " ", 1);
        o = W.u(o, size);
        o = W.s(o, '" width="2000" height="2000"><defs>');
        (o, distinct) = _artworkDefs(o, motifs, nt);
        o = _artworkPlate(o, size, cols, rows, appearance);
        o = _artworkCells(o, motifs, size, cols, rows);
        end = W.check(start, bound, W.s(o, "</g></svg>"));
    }

    /// @dev Pass 1: validate the layout and appearance, mark each distinct motif 1 in the zeroed seen-map, and
    ///      return the buffer bound.
    function _artworkBound(
        uint16[] calldata motifs,
        uint256 cols,
        uint256 rows,
        bytes32 appearance,
        uint256 nt
    ) private view returns (uint256 bound) {
        if (
            cols < 2 || rows < 2 || cols > MAX_CELLS || rows > MAX_CELLS || motifs.length != cols * rows
                || motifs.length > MAX_CELLS
        ) revert BadLayout();
        _appearance(appearance); // an unknown appearance reverts before any work
        uint256 count = motifCount;
        uint256 seen = _seen(nt);
        bound = 700 + 90 * motifs.length;
        for (uint256 k; k < motifs.length; ++k) {
            uint256 m = motifs[k];
            if (m >= count) revert UnknownMotif();
            uint256 f;
            assembly ("memory-safe") {
                f := byte(0, mload(add(seen, m)))
            }
            if (f == 0) {
                assembly ("memory-safe") {
                    mstore8(add(seen, m), 1)
                }
                bound += 140 + 3 * _len(_rec(m, nt));
            }
        }
    }

    /// @dev Pass 2: one <symbol> per motif marked 1, in order of first appearance, marking it 2.
    function _artworkDefs(uint256 o, uint16[] calldata motifs, uint256 nt)
        private
        view
        returns (uint256, uint256 distinct)
    {
        uint256 seen = _seen(nt);
        for (uint256 k; k < motifs.length; ++k) {
            uint256 m = motifs[k];
            uint256 f;
            assembly ("memory-safe") {
                f := byte(0, mload(add(seen, m)))
            }
            if (f == 1) {
                assembly ("memory-safe") {
                    mstore8(add(seen, m), 2)
                }
                ++distinct;
                o = _symbolDef(o, m, _rec(m, nt), nt);
            }
        }
        return (o, distinct);
    }

    /// @dev The paper, the plate 0.1 cell beyond the grid on every side, and the ink group's opening tag.
    function _artworkPlate(uint256 o, uint256 size, uint256 cols, uint256 rows, bytes32 appearance)
        private
        pure
        returns (uint256)
    {
        (, bytes memory ink, bytes memory plate) = _appearance(appearance);
        o = W.s(o, '</defs><rect width="');
        o = W.u(o, size);
        o = W.s(o, '" height="');
        o = W.u(o, size);
        o = W.s(o, '" fill="');
        o = W.s(o, PAPER);
        o = W.s(o, '"/><rect x="');
        o = W.u(o, (size - 1720 * cols) / 2 - 172);
        o = W.s(o, '" y="');
        o = W.u(o, (size - 1720 * rows) / 2 - 172);
        o = W.s(o, '" width="');
        o = W.u(o, 1720 * cols + 344);
        o = W.s(o, '" height="');
        o = W.u(o, 1720 * rows + 344);
        o = W.s(o, '" fill="');
        o = W.s(o, plate);
        o = W.s(o, '"/><g fill="');
        o = W.s(o, ink);
        return W.s(o, '">');
    }

    /// @dev One <use> per cell, row-major, each symbol at 70% of its 1720-unit cell. Loop literals are
    ///      written as words (KilimWriter.w) so the loop allocates nothing.
    function _artworkCells(uint256 o, uint16[] calldata motifs, uint256 size, uint256 cols, uint256 rows)
        private
        pure
        returns (uint256)
    {
        uint256 x0 = (size - 1720 * cols) / 2 + 258;
        uint256 y0 = (size - 1720 * rows) / 2 + 258;
        for (uint256 k; k < motifs.length; ++k) {
            o = W.w(o, '<use xlink:href="#m', 19);
            o = W.u(o, motifs[k]);
            o = W.w(o, '" x="', 5);
            o = W.u(o, x0 + 1720 * (k % cols));
            o = W.w(o, '" y="', 5);
            o = W.u(o, y0 + 1720 * (k / cols));
            o = W.w(o, '" width="1204" height="1204"/>', 30);
        }
        return o;
    }

    /// @dev <symbol id="m{m}" viewBox="{minX} {minY} {w} {h}" overflow="visible"><path .../></symbol>
    function _symbolDef(uint256 o, uint256 m, uint256 r, uint256 nt) private view returns (uint256) {
        o = W.w(o, '<symbol id="m', 13);
        o = W.u(o, m);
        o = W.w(o, '" viewBox="', 11);
        o = W.i(o, int16(uint16(r >> 176)));
        o = W.w(o, " ", 1);
        o = W.i(o, int16(uint16(r >> 160)));
        o = W.w(o, " ", 1);
        o = W.u(o, (r >> 144) & 0xffff);
        o = W.w(o, " ", 1);
        o = W.u(o, (r >> 128) & 0xffff);
        o = W.w(o, '" overflow="visible"><path fill-', 32);
        o = W.w(o, 'rule="evenodd" d="', 18);
        o = _path(o, r, nt);
        return W.w(o, '"/></symbol>', 12);
    }

    /// @dev The page's opening frame at natural scale: each still motif translated to its cell in a 3x3 window
    ///      around the hero, ink on white, as the page draws it (evenodd, no normalisation).
    function _stillDoc(uint256 nt) private view returns (uint256 start, uint256) {
        uint256 bound = 400;
        for (uint256 k; k < 9; ++k) {
            uint256 m = uint16(STILL >> (16 * (8 - k)));
            if (m != EMPTY) bound += 60 + 3 * _len(_rec(m, nt));
        }
        start = W.buf(bound);
        uint256 o = W.s(
            start,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-273 -273 546 546" width="1000" height="1000"><rect x="-273" y="-273" width="546" height="546" fill="'
        );
        o = W.s(o, STILL_GROUND);
        o = W.s(o, '"/><g fill="');
        o = W.s(o, STILL_INK);
        o = W.s(o, '" fill-rule="evenodd">');
        for (uint256 k; k < 9; ++k) {
            uint256 m = uint16(STILL >> (16 * (8 - k)));
            if (m == EMPTY) continue;
            o = W.w(o, '<path transform="translate(', 27);
            o = W.i(o, (int256(k % 3) - 1) * int256(STILL_PX));
            o = W.w(o, " ", 1);
            o = W.i(o, (int256(k / 3) - 1) * int256(STILL_PY));
            o = W.w(o, ')" d="', 6);
            o = _path(o, _rec(m, nt), nt);
            o = W.w(o, '"/>', 3);
        }
        o = W.s(o, "</g></svg>");
        return (start, W.check(start, bound, o));
    }

    /// @dev PAGE[0:stillAt] ++ still ++ PAGE[stillAt:symbolsAt] ++ base64(GEOM) ++ PAGE[symbolsAt:], exactly.
    function _htmlDoc(uint256 still, uint256 stillLen, uint256 nt)
        private
        view
        returns (uint256 start, uint256)
    {
        uint256 stage = W.buf(STAGE);
        uint256 len = PAGE_LEN + stillLen + W.b64len(GEO_LEN);
        start = W.buf(len);
        uint256 o = start;
        _read(PAGE_OFF, STILL_AT, o);
        o += STILL_AT;
        assembly ("memory-safe") {
            mcopy(o, still, stillLen)
        }
        o += stillLen;
        _read(PAGE_OFF + STILL_AT, SYMBOLS_AT - STILL_AT, o);
        o += SYMBOLS_AT - STILL_AT;
        for (uint256 off; off < GEO_LEN; off += STAGE) {
            uint256 piece = GEO_LEN - off < STAGE ? GEO_LEN - off : STAGE;
            _read(HDR + off, piece, stage);
            o = W.b64(stage, piece, o, nt + W.NUMBER_TABLE);
        }
        _read(PAGE_OFF + SYMBOLS_AT, PAGE_LEN - SYMBOLS_AT, o);
        o += PAGE_LEN - SYMBOLS_AT;
        return (start, W.exact(start, len, o));
    }

    // ============================================================ store access

    /// @dev Where the elements of `_chunks` live: keccak256(0), `_chunks` being storage slot 0 (checked in
    ///      the constructor). Read with a plain sload so _read never hashes: Solidity's own array indexing
    ///      hashes in the scratch space at 0x00, which a read in progress must never share.
    uint256 private constant CHUNKS_DATA = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;

    /// @dev Copy STORE[off, off + len) to memory at dst, across chunk boundaries. Overrun: none. Every caller
    ///      reads inside STORE's verified sections, so every chunk index is in range.
    function _read(uint256 off, uint256 len, uint256 dst) internal view {
        uint256 c = off / CHUNK;
        uint256 pos = off % CHUNK;
        while (len != 0) {
            uint256 k = CHUNK - pos;
            if (k > len) k = len;
            assembly ("memory-safe") {
                extcodecopy(sload(add(CHUNKS_DATA, c)), dst, add(pos, 1), k)
            }
            dst += k;
            len -= k;
            pos = 0;
            ++c;
        }
    }

    function _readMem(uint256 off, uint256 len) private view returns (bytes memory out) {
        out = new bytes(len);
        uint256 dst;
        assembly ("memory-safe") {
            dst := add(out, 32)
        }
        _read(off, len, dst);
    }

    /// @dev Index record of motif m in the top 128 bits: u32 off | u32 len | i16 minX | i16 minY | u16 w | u16 h.
    ///      Read into the reserved index word (a record may straddle two chunks).
    function _rec(uint256 m, uint256 nt) internal view returns (uint256 r) {
        uint256 word = nt + W.TABLES_SIZE;
        _read(IDX_OFF + 16 * m, 16, word);
        assembly ("memory-safe") {
            r := mload(word)
        }
    }

    function _len(uint256 r) private pure returns (uint256) {
        return (r >> 192) & 0xffffffff;
    }

    /// @dev Decode the record `r` into path text at o, through the record scratch.
    function _path(uint256 o, uint256 r, uint256 nt) private view returns (uint256) {
        uint256 len = _len(r);
        uint256 src = nt + W.TABLES_SIZE + 32;
        _read(HDR + (r >> 224), len, src);
        return W.path(o, src, len, nt);
    }

    /// @dev Record scratch size: the record, the zero word KilimWriter.path writes after it, read slack.
    function _scratchSize() private view returns (uint256) {
        return (MAX_REC + 95) & ~uint256(31);
    }

    /// @dev Reserve, once per call, in this order: the tables (copied from TABLES), the index word (32 B),
    ///      the record scratch, and a zeroed seen-map of motifCount bytes (+32 read slack). Returns the
    ///      tables' address; the others follow at fixed offsets (_rec, _path, _seen).
    function _tables() internal view returns (uint256 nt) {
        address t = TABLES;
        uint256 fixedPart = W.TABLES_SIZE + 32 + _scratchSize();
        uint256 seen = (motifCount + 63) & ~uint256(31);
        uint256 size = W.TABLES_SIZE;
        assembly ("memory-safe") {
            nt := mload(0x40)
            extcodecopy(t, nt, 1, size)
            let z := add(nt, fixedPart)
            calldatacopy(z, calldatasize(), seen) // zero bytes: reading past calldata returns zeros
            mstore(0x40, add(z, seen))
        }
    }

    function _seen(uint256 nt) private view returns (uint256) {
        return nt + W.TABLES_SIZE + 32 + _scratchSize();
    }
}
