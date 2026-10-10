// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";
import {Kilim} from "../../src/Kilim.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";

/// @notice Gas ceilings for every tokenURI kind on the packed geometry, one measurement per test so no call
///         pays for memory an earlier one left behind. Each figure is an eth_call estimate: the callee's gas
///         through a staticcall that copies nothing back, plus 21,000 and 16 gas per calldata byte.
///         `pnpm gas:render` collects the logged values into audit/gas-render.txt.
/// @dev Targets (chosen for RPCs that cap eth_call at 25M; 50M is common but not universal):
///      symbol <= 0.6M, any artwork <= 36M, typical artwork <= 24M, the 1/1 <= 24M, anything <= 45M,
///      every deployment transaction <= 8M (the per-transaction cap is 16,777,216).
contract RenderGasLimitsTest is RenderBase {
    event log_named_uint(string key, uint256 value);

    uint256 internal constant SYMBOL_CEILING = 600_000;
    uint256 internal constant ARTWORK_CEILING = 36_000_000;
    uint256 internal constant TYPICAL_CEILING = 24_000_000;
    uint256 internal constant MASTERPIECE_CEILING = 24_000_000;
    uint256 internal constant HARD_CEILING = 45_000_000;
    uint256 internal constant DEPLOY_CEILING = 8_000_000;

    function setUp() public {
        _loadStore();
    }

    function _report(string memory name, uint256 used, uint256 ceiling) internal {
        emit log_named_uint(string.concat("gas: ", name), used);
        require(used <= ceiling, string.concat(name, " is over its ceiling"));
        require(used <= HARD_CEILING, string.concat(name, " is over the hard cap"));
    }

    function _artwork(string memory key, uint256 cols, uint256 rows) internal view returns (uint256) {
        uint16[] memory motifs = _uint16s(manifest, key);
        return _ethCallGas(
            address(renderer),
            abi.encodeCall(KilimRenderer.artworkURI, (1, motifs, uint16(cols), uint16(rows), INK, 1, false))
        );
    }

    // ------------------------------------------------------------ renderer calls

    function testGasSymbolWorst() public {
        uint16 m = uint16(vmr.parseJsonUint(manifest, ".worst.largestSymbol"));
        uint256 worst;
        for (uint8 mat; mat < 6; ++mat) {
            uint256 g = _ethCallGas(
                address(renderer),
                abi.encodeCall(KilimRenderer.symbolURI, (1_000_001, bytes32(type(uint256).max), m, mat))
            );
            if (g > worst) worst = g;
        }
        _report("symbolURI, largest motif, worst material", worst, SYMBOL_CEILING);
    }

    function testGasSymbolMedian() public {
        uint16 m = uint16(vmr.parseJsonUint(golden, ".median"));
        _report(
            "symbolURI, median motif, dyed wool",
            _ethCallGas(address(renderer), abi.encodeCall(KilimRenderer.symbolURI, (2, bytes32(0), m, 0))),
            SYMBOL_CEILING
        );
    }

    function testGasArtwork16x16HeaviestByPoints() public {
        _report(
            "artworkURI 16x16, 256 heaviest by points", _artwork(".worst.byPoints", 16, 16), ARTWORK_CEILING
        );
    }

    function testGasArtwork16x16HeaviestByChars() public {
        _report(
            "artworkURI 16x16, 256 heaviest by path length",
            _artwork(".worst.byChars", 16, 16),
            ARTWORK_CEILING
        );
    }

    function testGasArtwork2x128Heaviest() public {
        _report("artworkURI 2x128, 256 heaviest", _artwork(".worst.byChars", 2, 128), ARTWORK_CEILING);
    }

    function testGasArtwork128x2Heaviest() public {
        _report("artworkURI 128x2, 256 heaviest", _artwork(".worst.byChars", 128, 2), ARTWORK_CEILING);
    }

    function testGasArtwork16x16Typical() public {
        _report(
            "artworkURI 16x16, typical (random motifs)", _artwork(".worst.typical", 16, 16), TYPICAL_CEILING
        );
    }

    function testGasArtwork2x2Heaviest() public {
        uint16[] memory all = _uint16s(manifest, ".worst.byChars");
        uint16[] memory four = new uint16[](4);
        for (uint256 i; i < 4; ++i) {
            four[i] = all[i];
        }
        _report(
            "artworkURI 2x2, 4 heaviest",
            _ethCallGas(
                address(renderer), abi.encodeCall(KilimRenderer.artworkURI, (1, four, 2, 2, INK, 1, false))
            ),
            ARTWORK_CEILING
        );
    }

    function testGasMasterpiece() public {
        _report(
            "masterpieceURI",
            _ethCallGas(address(renderer), abi.encodeCall(KilimRenderer.masterpieceURI, ())),
            MASTERPIECE_CEILING
        );
    }

    // ------------------------------------------------------------ through Kilim.tokenURI

    function _kilim() internal returns (Kilim nft) {
        nft = new Kilim(
            address(this),
            ALICE,
            TREASURY,
            1_000_000,
            uint16(count),
            256,
            renderer.geometryHash(),
            address(renderer).codehash,
            renderer
        );
    }

    function _seedOf(Kilim nft, uint256 id) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(block.chainid, address(nft), id)));
    }

    function testGasKilimMasterpiece() public {
        Kilim nft = _kilim();
        nft.mintMasterpiece(ALICE);
        _report(
            "Kilim.tokenURI(1), the 1/1",
            _ethCallGas(address(nft), abi.encodeCall(nft.tokenURI, (1))),
            MASTERPIECE_CEILING
        );
    }

    function testGasKilimSymbolWorst() public {
        Kilim nft = _kilim();
        uint256 largest = vmr.parseJsonUint(manifest, ".worst.largestSymbol");
        // find a symbol ID dealt the largest motif in cotton rag (three drawn layers)
        uint256 id = 2;
        while (true) {
            uint256 seed = _seedOf(nft, id);
            if (
                seed % count == largest
                    && uint256(keccak256(abi.encode(bytes32(seed), "material"))) % 100 >= 96
            ) break;
            ++id;
        }
        nft.mintSymbols(ALICE, ALICE, id, 1);
        (, uint16 motif, uint8 material) = nft.symbolTraits(id);
        assertEq(motif, largest);
        assertEq(material, 5);
        _report(
            "Kilim.tokenURI, largest motif in cotton rag",
            _ethCallGas(address(nft), abi.encodeCall(nft.tokenURI, (id))),
            SYMBOL_CEILING
        );
    }

    function testGasKilimArtworkWorst() public {
        Kilim nft = _kilim();
        uint16[] memory targets = _uint16s(manifest, ".worst.byChars");
        // symbol IDs whose seeds deal exactly the 256 heaviest motifs
        uint256[] memory slot = new uint256[](count);
        for (uint256 i; i < targets.length; ++i) {
            slot[targets[i]] = i + 1;
        }
        uint256[] memory cells = new uint256[](256);
        uint256 found;
        for (uint256 id = 2; found < 256; ++id) {
            uint256 m = _seedOf(nft, id) % count;
            if (slot[m] != 0) {
                cells[slot[m] - 1] = id;
                slot[m] = 0;
                ++found;
                nft.mintSymbols(ALICE, ALICE, id, 1);
            }
        }
        vm.prank(ALICE);
        uint256 art = nft.weave(cells, 16, 16, INDIGO);
        _report(
            "Kilim.tokenURI, 16x16 artwork of the 256 heaviest",
            _ethCallGas(address(nft), abi.encodeCall(nft.tokenURI, (art))),
            ARTWORK_CEILING
        );
    }

    // ------------------------------------------------------------ deployment

    /// @dev A creation transaction: 21,000 + 32,000 + calldata (4 per zero byte, 16 otherwise) + initcode
    ///      words, plus the measured execution and code deposit.
    function _intrinsic(bytes memory initcode) internal pure returns (uint256 g) {
        g = 53_000 + 2 * ((initcode.length + 31) / 32);
        for (uint256 i; i < initcode.length; ++i) {
            g += initcode[i] == 0 ? 4 : 16;
        }
    }

    function testGasDeployEveryChunkAndTheRenderer() public {
        string[] memory files = vmr.parseJsonStringArray(manifest, ".chunkFiles");
        uint256 worstChunk;
        uint256 total;
        for (uint256 i; i < files.length; ++i) {
            bytes memory data = vmr.readFileBinary(string.concat(storeDir, "/", files[i]));
            bytes memory code =
                abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
            uint256 g = gasleft();
            address p;
            assembly {
                p := create(0, add(code, 32), mload(code))
            }
            g -= gasleft(); // measured first: the intrinsic loop below must not be metered
            g += _intrinsic(code);
            require(p != address(0), "chunk");
            total += g;
            if (g > worstChunk) worstChunk = g;
        }
        emit log_named_uint("gas: deploy, all chunks", total);
        _report("deploy, largest chunk", worstChunk, DEPLOY_CEILING);
        bytes memory args =
            abi.encode(chunkAddrs, _hash("geometryHash"), _hash("indexHash"), _hash("pageHash"));
        uint256 g0 = gasleft();
        KilimRenderer r =
            new KilimRenderer(chunkAddrs, _hash("geometryHash"), _hash("indexHash"), _hash("pageHash"));
        uint256 used = g0 - gasleft();
        used += _intrinsic(bytes.concat(type(KilimRenderer).creationCode, args));
        _report("deploy, renderer (includes TABLES)", used, DEPLOY_CEILING);
        emit log_named_uint("size: KilimRenderer runtime", address(r).code.length);
        emit log_named_uint("size: TABLES", r.TABLES().code.length);
    }

    function testGasDeployAuctionAndCollection() public {
        KilimAuction.Config memory c = config();
        c.motifCount = uint16(count);
        c.geometryHash = renderer.geometryHash();
        c.rendererHash = address(renderer).codehash;
        c.renderer = address(renderer);
        c.symbolCap = 1_000_000;
        c.maxSymbolsPerBid = 1_000_000;
        uint256 g0 = gasleft();
        KilimAuction auction = new KilimAuction(c);
        uint256 used = g0 - gasleft();
        used += _intrinsic(bytes.concat(type(KilimAuction).creationCode, abi.encode(c)));
        _report("deploy, auction + collection", used, DEPLOY_CEILING);
        emit log_named_uint("size: Kilim runtime", address(auction.collection()).code.length);
        emit log_named_uint("size: KilimAuction runtime", address(auction).code.length);
        emit log_named_uint("size: KilimAuction initcode", type(KilimAuction).creationCode.length);
    }

    /// @dev EIP-170 and EIP-3860 limits.
    function testContractSizes() public {
        require(address(renderer).code.length <= 24_576, "renderer runtime");
        require(type(KilimAuction).creationCode.length <= 49_152, "auction initcode");
        require(type(KilimRenderer).creationCode.length <= 49_152, "renderer initcode");
        require(address(_kilim()).code.length <= 24_576, "kilim runtime");
    }
}
