// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Kilim} from "../src/Kilim.sol";
import {TestBase, InvariantBase} from "./TestBase.sol";

contract CompositionHandler is TestBase {
    Kilim public nft;
    address[3] public actors = [ALICE, BOB, CAROL];
    uint256[] public symbols;
    uint256[] public artworks;
    mapping(uint256 => bytes32) public originalSeed;
    mapping(uint256 => uint256) public lastSize;
    uint256 public weaveCalls;
    uint256 public expandCalls;
    uint256 public transferCalls;

    constructor() {
        nft = newKilim(address(this), ALICE, TREASURY, 256, 812, 64);
        for (uint256 i; i < actors.length; ++i) {
            _mint(actors[i], 12);
        }
    }

    function _mint(address actor, uint256 count) private {
        uint256 first = mintNext(nft, actor, actor, count);
        for (uint256 i; i < count; ++i) {
            symbols.push(first + i);
            originalSeed[first + i] = nft.symbolData(first + i).seed;
        }
    }

    function mint(uint8 actorSeed, uint8 quantitySeed) external {
        uint256 quantity = 1 + uint256(quantitySeed) % 8;
        if (nft.symbolsMinted() + quantity > nft.symbolCap()) return;
        _mint(actors[actorSeed % 3], quantity);
    }

    function _ownedSources(address actor, uint256 count) private view returns (uint256[] memory list) {
        list = new uint256[](count);
        uint256 found;
        for (uint256 i; i < symbols.length && found < count; ++i) {
            uint256 id = symbols[i];
            if (nft.symbolData(id).consumedBy == 0 && nft.ownerOf(id) == actor) list[found++] = id;
        }
        if (found != count) return new uint256[](0);
    }

    function weave(uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256[] memory cells = _ownedSources(actor, 4);
        if (cells.length == 0) return;
        vm.prank(actor);
        uint256 art = nft.weave(cells, 2, 2, INK);
        artworks.push(art);
        lastSize[art] = 4;
        ++weaveCalls;
    }

    function expand(uint8 artSeed, uint8 rotation) external {
        if (artworks.length == 0) return;
        uint256 artId = artworks[uint256(artSeed) % artworks.length];
        Kilim.ArtworkData memory art = nft.artworkData(artId);
        if (art.frozen || art.cells.length + 2 > nft.maxCells()) return;
        address owner = nft.ownerOf(artId);
        uint256[] memory sources = _ownedSources(owner, 2);
        if (sources.length == 0) return;
        uint256 length = art.cells.length + 2;
        uint256[] memory cells = new uint256[](length);
        for (uint256 i; i < art.cells.length; ++i) {
            cells[i] = art.cells[i];
        }
        cells[length - 2] = sources[0];
        cells[length - 1] = sources[1];
        uint256 index = uint256(rotation) % length;
        (cells[0], cells[index]) = (cells[index], cells[0]);
        vm.prank(owner);
        nft.expand(artId, art.revision, cells, uint16(length / 2), 2, appearanceOf(rotation));
        require(length > lastSize[artId], "shrinking composition");
        lastSize[artId] = length;
        ++expandCalls;
    }

    function transferSymbol(uint16 indexSeed, uint8 destination) external {
        uint256 id = symbols[uint256(indexSeed) % symbols.length];
        if (nft.symbolData(id).consumedBy != 0) return;
        address owner = nft.ownerOf(id);
        vm.prank(owner);
        nft.transferFrom(owner, actors[destination % 3], id);
        ++transferCalls;
    }

    function transferArtwork(uint16 indexSeed, uint8 destination) external {
        if (artworks.length == 0) return;
        uint256 id = artworks[uint256(indexSeed) % artworks.length];
        address owner = nft.ownerOf(id);
        vm.prank(owner);
        nft.transferFrom(owner, actors[destination % 3], id);
        ++transferCalls;
    }

    function freeze(uint16 indexSeed) external {
        if (artworks.length == 0) return;
        uint256 id = artworks[uint256(indexSeed) % artworks.length];
        if (nft.artworkData(id).frozen) return;
        address owner = nft.ownerOf(id);
        vm.prank(owner);
        nft.freezeArtwork(id);
    }

    function symbolCount() external view returns (uint256) {
        return symbols.length;
    }

    function artworkCount() external view returns (uint256) {
        return artworks.length;
    }
}

contract CompositionInvariants is InvariantBase {
    CompositionHandler internal handler;
    Kilim internal nft;
    address[] private targets;

    function setUp() public {
        handler = new CompositionHandler();
        nft = handler.nft();
        targets.push(address(handler));
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    function invariantEveryBurnedSymbolOccursExactlyOnceInItsArtwork() public view {
        uint256 burned;
        for (uint256 i; i < handler.symbolCount(); ++i) {
            uint256 id = handler.symbols(i);
            Kilim.SymbolData memory symbol = nft.symbolData(id);
            assertEq(symbol.seed, handler.originalSeed(id));
            if (symbol.consumedBy == 0) {
                assertTrue(nft.ownerOf(id) != address(0));
                continue;
            }
            ++burned;
            Kilim.ArtworkData memory art = nft.artworkData(symbol.consumedBy);
            uint256 occurrences;
            for (uint256 j; j < art.cells.length; ++j) {
                if (art.cells[j] == id) ++occurrences;
            }
            assertEq(occurrences, 1);
            assertEq(symbol.lastRevision, art.revision);
        }
        assertEq(burned, nft.symbolsBurned());
    }

    function invariantAllSourcesAreConservedAndLayoutsAreValid() public view {
        uint256 totalCells;
        for (uint256 i; i < handler.artworkCount(); ++i) {
            uint256 id = handler.artworks(i);
            Kilim.ArtworkData memory art = nft.artworkData(id);
            assertEq(art.cells.length, uint256(art.columns) * art.rows);
            assertEq(art.cells.length, handler.lastSize(id));
            assertTrue(art.cells.length <= nft.maxCells());
            for (uint256 j; j < art.cells.length; ++j) {
                assertEq(nft.symbolData(art.cells[j]).consumedBy, id);
            }
            totalCells += art.cells.length;
        }
        assertEq(totalCells, nft.symbolsBurned());
        assertEq(nft.symbolsMinted(), handler.symbolCount());
        assertEq(nft.artworksMinted(), handler.artworkCount());
        uint256 balances = nft.balanceOf(ALICE) + nft.balanceOf(BOB) + nft.balanceOf(CAROL);
        assertEq(balances, nft.symbolsMinted() - nft.symbolsBurned() + nft.artworksMinted());
    }
}
