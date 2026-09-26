// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Symbols, evolving compositions, and the auction's single masterpiece.
/// @dev No upgrade, admin transfer, metadata setter, or external renderer call.
///      Symbol traits depend only on the token ID: public from deployment, NOT verifiable randomness.
///      Symbols use IDs FIRST_SYMBOL_ID..symbolCap+1; artworks use the IDs after that range.
contract Kilim is ERC721, ReentrancyGuard {
    using Strings for uint256;

    enum Kind {
        None,
        Symbol,
        Artwork,
        Masterpiece
    }

    struct SymbolData {
        bytes32 seed;
        uint128 consumedBy;
        uint64 lastRevision;
        uint16 motif;
        uint8 material;
    }

    /// @dev Storage form of an artwork: cell IDs packed eight per word (32 bits each), which cuts
    ///      a 256-cell layout from 256 storage slots to 32. The cell count is columns * rows.
    struct ArtworkStore {
        uint256[] packedCells;
        bytes32 appearance;
        uint64 revision;
        uint16 columns;
        uint16 rows;
        bool frozen;
    }

    struct SymbolState {
        uint128 consumedBy;
        uint64 lastRevision;
    }

    struct ArtworkData {
        uint256[] cells;
        bytes32 appearance;
        uint64 revision;
        uint16 columns;
        uint16 rows;
        bool frozen;
    }

    uint256 public constant MASTERPIECE_ID = 1;
    uint256 public constant FIRST_SYMBOL_ID = 2;
    uint256 public constant MAX_MINT_BATCH = 64;
    uint256 public constant HARD_MAX_CELLS = 256;
    /// @notice Resale royalty, fixed forever. Marketplaces may ignore royalties entirely.
    uint96 public constant ROYALTY_BPS = 500;
    address public immutable minter;
    uint256 public immutable symbolCap;
    uint16 public immutable motifCount;
    uint16 public immutable maxCells;
    bytes32 public immutable geometryHash;
    bytes32 public immutable rendererHash;
    uint256 public symbolsMinted;
    uint256 public symbolsBurned;
    uint256 public artworksMinted;
    bool public masterpieceMinted;
    uint128 private _nextArtworkId;
    /// @notice Collection-page role. It can ONLY edit the collection profile and royalty
    ///         recipient below. It cannot mint, burn, move tokens, or touch the auction or funds.
    address public owner;
    address public royaltyReceiver;
    string public collectionDescription;
    string public collectionExternalUrl;

    /// @dev Only burn provenance is stored per symbol. Traits are recomputed from the ID, and a
    ///      token's kind follows from its ID range, so minting a symbol writes no extra state.
    mapping(uint256 => SymbolState) private _symbolState;
    mapping(uint256 => ArtworkStore) private _artworks;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidRecipient();
    error InvalidQuantity();
    error SupplyExceeded();
    error WrongKind(uint256 tokenId);
    error InvalidLayout();
    error DuplicateSymbol(uint256 tokenId);
    error SymbolAlreadyConsumed(uint256 tokenId);
    error MissingExistingSymbols();
    error ArtworkFrozen();
    error StaleRevision();
    error AlreadyMinted();

    event SymbolsMinted(address indexed recipient, address indexed bidder, uint256 firstId, uint256 count);
    /// @dev creator is the weaver; the receiver callback may already have transferred the artwork.
    event ArtworkCreated(uint256 indexed tokenId, address indexed creator, bytes32 layoutHash);
    event ArtworkExpanded(uint256 indexed tokenId, uint64 revision, bytes32 layoutHash);
    event ArtworkPermanentlyFrozen(uint256 indexed tokenId);
    event MetadataUpdate(uint256 tokenId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RoyaltyReceiverUpdated(address indexed receiver);
    event ContractURIUpdated();

    constructor(
        address minter_,
        address owner_,
        address royaltyReceiver_,
        uint256 symbolCap_,
        uint16 motifCount_,
        uint16 maxCells_,
        bytes32 geometryHash_,
        bytes32 rendererHash_
    ) ERC721("Kilim", "KILIM") {
        if (
            minter_ == address(0) || owner_ == address(0) || royaltyReceiver_ == address(0) || symbolCap_ == 0
                || symbolCap_ > type(uint32).max - FIRST_SYMBOL_ID || motifCount_ == 0 || maxCells_ < 4
                || maxCells_ > HARD_MAX_CELLS || geometryHash_ == bytes32(0) || rendererHash_ == bytes32(0)
        ) revert InvalidConfiguration();
        owner = owner_;
        royaltyReceiver = royaltyReceiver_;
        emit OwnershipTransferred(address(0), owner_);
        emit RoyaltyReceiverUpdated(royaltyReceiver_);
        minter = minter_;
        symbolCap = symbolCap_;
        motifCount = motifCount_;
        maxCells = maxCells_;
        geometryHash = geometryHash_;
        rendererHash = rendererHash_;
        // symbolCap_ fits 32 bits, so symbol IDs pack into 32-bit cells and artwork IDs fit uint128.
        _nextArtworkId = uint128(FIRST_SYMBOL_ID + symbolCap_);
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Hand the collection-page role to another address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidRecipient();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Give up the collection-page role permanently. Nothing here can be edited afterwards.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    /// @notice Set where marketplaces send resale royalties. The 5% rate itself cannot change.
    function setRoyaltyReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert InvalidRecipient();
        royaltyReceiver = receiver;
        emit RoyaltyReceiverUpdated(receiver);
    }

    /// @notice Set the collection-page blurb and link. Token metadata is untouched by this.
    function setCollectionInfo(string calldata description, string calldata externalUrl) external onlyOwner {
        collectionDescription = description;
        collectionExternalUrl = externalUrl;
        emit ContractURIUpdated();
    }

    /// @notice ERC-2981. Royalties are advisory: marketplaces decide whether to pay them.
    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 amount)
    {
        return (royaltyReceiver, (salePrice * ROYALTY_BPS) / 10_000);
    }

    /// @notice Collection-level metadata for marketplace pages.
    function contractURI() external view returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Kilim","description":"',
                        _escapeJson(collectionDescription),
                        '","external_link":"',
                        _escapeJson(collectionExternalUrl),
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

    /// @notice Mint symbol IDs that the auction reserved for `bidder` when the bid was placed.
    /// @dev The minter chooses the IDs. Each ID can be minted once, even after it is burned.
    function mintSymbols(address to, address bidder, uint256 firstId, uint256 quantity)
        external
        onlyMinter
        nonReentrant
    {
        _validateRecipient(to);
        if (bidder == address(0)) revert InvalidRecipient();
        if (quantity == 0 || quantity > MAX_MINT_BATCH) revert InvalidQuantity();
        if (
            quantity > symbolCap || firstId < FIRST_SYMBOL_ID
                || firstId - FIRST_SYMBOL_ID > symbolCap - quantity
        ) revert SupplyExceeded();
        symbolsMinted += quantity;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = firstId + i;
            // A burned symbol has no owner but keeps its consumedBy, so it can never be re-minted.
            if (kindOf(id) != Kind.None) revert AlreadyMinted();
            _safeMint(to, id);
        }
        emit SymbolsMinted(to, bidder, firstId, quantity);
    }

    /// @notice Traits of any symbol ID, claimed or not. Fixed at deployment; independent of the
    ///         bidder, recipient, and claim time. Deterministic and public, NOT randomness.
    function symbolTraits(uint256 id) public view returns (bytes32 seed, uint16 motif, uint8 material) {
        if (id < FIRST_SYMBOL_ID || id - FIRST_SYMBOL_ID >= symbolCap) revert WrongKind(id);
        seed = keccak256(abi.encode(block.chainid, address(this), id));
        uint256 roll = uint256(keccak256(abi.encode(seed, "material"))) % 100;
        material = roll < 44 ? 0 : roll < 68 ? 1 : roll < 82 ? 2 : roll < 91 ? 3 : roll < 96 ? 4 : 5;
        motif = uint16(uint256(seed) % motifCount);
    }

    function mintMasterpiece(address to) external onlyMinter nonReentrant {
        _validateRecipient(to);
        if (masterpieceMinted) revert AlreadyMinted();
        masterpieceMinted = true;
        _safeMint(to, MASTERPIECE_ID);
    }

    /// @notice Burn your symbols and mint one artwork. Cell order is row-major.
    /// @dev Approvals to trade an NFT do not authorize its destruction or modification.
    function weave(uint256[] calldata cells, uint16 columns, uint16 rows, bytes32 appearance)
        external
        nonReentrant
        returns (uint256 artworkId)
    {
        _validateLayout(cells.length, columns, rows);
        artworkId = _nextArtworkId++;
        ArtworkStore storage art = _artworks[artworkId];
        art.revision = 1;
        _consumeLayout(artworkId, cells, 1, 0);
        _writeLayout(art, cells, columns, rows, appearance);
        ++artworksMinted;
        // All burns, composition data and counters are final before the receiver callback.
        _safeMint(msg.sender, artworkId);
        emit ArtworkCreated(artworkId, msg.sender, keccak256(abi.encode(cells)));
    }

    /// @notice Add symbols to the same artwork, retaining every previous source exactly once.
    function expand(
        uint256 artworkId,
        uint64 expectedRevision,
        uint256[] calldata cells,
        uint16 columns,
        uint16 rows,
        bytes32 appearance
    ) external nonReentrant {
        _requireArtworkOwner(artworkId);
        ArtworkStore storage art = _artworks[artworkId];
        if (art.frozen) revert ArtworkFrozen();
        if (art.revision != expectedRevision) revert StaleRevision();
        _validateLayout(cells.length, columns, rows);
        uint256 oldLength = uint256(art.columns) * art.rows;
        if (cells.length <= oldLength) revert InvalidLayout();
        uint64 revision = art.revision + 1;
        _consumeLayout(artworkId, cells, revision, oldLength);
        art.revision = revision;
        _writeLayout(art, cells, columns, rows, appearance);
        emit ArtworkExpanded(artworkId, revision, keccak256(abi.encode(cells)));
        emit MetadataUpdate(artworkId);
    }

    function freezeArtwork(uint256 artworkId) external nonReentrant {
        _requireArtworkOwner(artworkId);
        if (_artworks[artworkId].frozen) revert ArtworkFrozen();
        _artworks[artworkId].frozen = true;
        emit ArtworkPermanentlyFrozen(artworkId);
        emit MetadataUpdate(artworkId);
    }

    /// @notice What a token ID is. Symbols exist once minted and stay symbols after being burned;
    ///         artworks are never burned; the masterpiece exists once claimed.
    function kindOf(uint256 id) public view returns (Kind) {
        if (id == MASTERPIECE_ID) return masterpieceMinted ? Kind.Masterpiece : Kind.None;
        if (id < FIRST_SYMBOL_ID) return Kind.None;
        if (id - FIRST_SYMBOL_ID < symbolCap) {
            bool minted = _ownerOf(id) != address(0) || _symbolState[id].consumedBy != 0;
            return minted ? Kind.Symbol : Kind.None;
        }
        return id < _nextArtworkId ? Kind.Artwork : Kind.None;
    }

    /// @notice Burned source data remains queryable to reconstruct compositions.
    function symbolData(uint256 tokenId) external view returns (SymbolData memory data) {
        if (kindOf(tokenId) != Kind.Symbol) revert WrongKind(tokenId);
        (data.seed, data.motif, data.material) = symbolTraits(tokenId);
        SymbolState storage state = _symbolState[tokenId];
        data.consumedBy = state.consumedBy;
        data.lastRevision = state.lastRevision;
    }

    function artworkData(uint256 tokenId) public view returns (ArtworkData memory data) {
        if (kindOf(tokenId) != Kind.Artwork) revert WrongKind(tokenId);
        ArtworkStore storage art = _artworks[tokenId];
        data.cells = _unpackCells(art);
        data.appearance = art.appearance;
        data.revision = art.revision;
        data.columns = art.columns;
        data.rows = art.rows;
        data.frozen = art.frozen;
    }

    /// @dev Self-contained metadata. Artwork media renderer is a separate, unfinished integration.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Kind kind = kindOf(tokenId);
        string memory details;
        if (kind == Kind.Symbol) {
            (bytes32 seed, uint16 motif, uint8 material) = symbolTraits(tokenId);
            details = string.concat(
                '"kind":"symbol","motif":',
                uint256(motif).toString(),
                ',"material":',
                uint256(material).toString(),
                ',"seed":"',
                uint256(seed).toHexString(32),
                '"'
            );
        } else if (kind == Kind.Artwork) {
            ArtworkData memory art = artworkData(tokenId);
            details = string.concat(
                '"kind":"artwork","revision":',
                uint256(art.revision).toString(),
                ',"columns":',
                uint256(art.columns).toString(),
                ',"rows":',
                uint256(art.rows).toString(),
                ',"frozen":',
                art.frozen ? "true" : "false",
                ',"layout_hash":"',
                uint256(keccak256(abi.encode(art.cells))).toHexString(32),
                '","appearance_hash":"',
                uint256(art.appearance).toHexString(32),
                '"'
            );
        } else {
            details = '"kind":"masterpiece"';
        }
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Kilim #',
                        tokenId.toString(),
                        '",',
                        details,
                        ',"geometry_hash":"',
                        uint256(geometryHash).toHexString(32),
                        '","renderer_hash":"',
                        uint256(rendererHash).toHexString(32),
                        '"}'
                    )
                )
            )
        );
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        // ERC-4906 metadata updates and ERC-2981 royalties.
        return interfaceId == 0x49064906 || interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    /// @dev Owner-supplied text is escaped so the collection JSON cannot be broken or spoofed.
    ///      Two passes keep this allocation-exact without assembly.
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

    function _consumeLayout(uint256 artworkId, uint256[] calldata cells, uint64 revision, uint256 oldLength)
        private
    {
        uint256 retained = 0;
        for (uint256 i; i < cells.length; ++i) {
            uint256 id = cells[i];
            if (kindOf(id) != Kind.Symbol) revert WrongKind(id);
            SymbolState storage symbol = _symbolState[id];
            if (symbol.consumedBy == artworkId) {
                if (symbol.lastRevision == revision) revert DuplicateSymbol(id);
                ++retained;
            } else {
                if (symbol.consumedBy != 0) revert SymbolAlreadyConsumed(id);
                if (ownerOf(id) != msg.sender) revert Unauthorized();
                // artworkId was allocated by the checked uint128 _nextArtworkId counter.
                symbol.consumedBy = uint128(artworkId);
                _burn(id);
                ++symbolsBurned;
            }
            symbol.lastRevision = revision;
        }
        if (retained != oldLength) revert MissingExistingSymbols();
    }

    function _writeLayout(
        ArtworkStore storage art,
        uint256[] calldata cells,
        uint16 columns,
        uint16 rows,
        bytes32 appearance
    ) private {
        uint256[] memory packed = new uint256[]((cells.length + 7) / 8);
        for (uint256 i; i < cells.length; ++i) {
            // Every cell is a validated symbol ID, and symbol IDs fit 32 bits (constructor bound).
            packed[i / 8] |= uint256(uint32(cells[i])) << ((i % 8) * 32);
        }
        art.packedCells = packed;
        art.columns = columns;
        art.rows = rows;
        art.appearance = appearance;
    }

    function _unpackCells(ArtworkStore storage art) private view returns (uint256[] memory cells) {
        cells = new uint256[](uint256(art.columns) * art.rows);
        uint256 word;
        for (uint256 i; i < cells.length; ++i) {
            if (i % 8 == 0) word = art.packedCells[i / 8];
            cells[i] = uint32(word >> ((i % 8) * 32));
        }
    }

    function _requireArtworkOwner(uint256 tokenId) private view {
        if (kindOf(tokenId) != Kind.Artwork) revert WrongKind(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
    }

    function _validateLayout(uint256 length, uint16 columns, uint16 rows) private view {
        if (columns < 2 || rows < 2 || length > maxCells || length != uint256(columns) * rows) {
            revert InvalidLayout();
        }
    }

    function _validateRecipient(address to) private view {
        if (to == address(0) || to == address(this) || to == minter) revert InvalidRecipient();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this) || to == minter) revert InvalidRecipient();
        return super._update(to, tokenId, auth);
    }
}
