// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Proof of concept for a review finding: the KilimGlyphs constructor checks "every chunk but the last is
// full" and "the sizes sum to 32,768", but not the chunk count that grid() hard-codes through
// `_gridChunks[index / GRIDS_PER_CHUNK]`. One chunk of all 32,768 bytes satisfies both checks and leaves
// glyphs 768..1024 unaddressable. The first test shows why this is unreachable on the launch chains:
// such a chunk is past EIP-170 and `create` refuses it. The second plants it with vm.etch to show the
// latent defect in the contract's own logic.
import {KilimGlyphs} from "../../src/KilimGlyphs.sol";
import {TestBase} from "../TestBase.sol";

interface VmEtch {
    function etch(address, bytes calldata) external;
}

contract GridChunkLayoutUncheckedPoc is TestBase {
    VmEtch internal constant vmEtch = VmEtch(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Which world the test EVM is in: `created` is false when EIP-170 refused the 32,769-byte runtime.
    event OneChunkThroughCreate(bool created);

    /// The only thing between a plain CREATE and the one-chunk layout is the chain's code size limit.
    /// Foundry's test EVM leaves the limit off unless `code_size_limit` is set (run this with
    /// FOUNDRY_CODE_SIZE_LIMIT=24576 to see the EIP-170 world of mainnet and Sepolia). When the limit
    /// is off, the chunk is created and the constructor accepts it with no vm.etch involved.
    function testOneChunkThroughCreateIsStoppedOnlyByEip170() public {
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        bytes memory initcode =
            abi.encodePacked(hex"61", uint16(grids.length + 1), hex"80600a3d393df300", grids);
        address chunk;
        assembly ("memory-safe") {
            chunk := create(0, add(initcode, 32), mload(initcode))
        }
        emit OneChunkThroughCreate(chunk != address(0));
        if (chunk == address(0)) return; // EIP-170 enforced: the layout cannot reach the constructor.

        require(chunk.code.length == 32_769, "created size");
        address[] memory chunks = new address[](1);
        chunks[0] = chunk;
        address namesChunk = sstore2(names);
        bytes32 gridsHash = keccak256(grids);
        bytes32 namesHash = keccak256(names);
        KilimGlyphs nft =
            new KilimGlyphs(address(this), TREASURY, 1000, chunks, gridsHash, namesChunk, namesHash, "", "");
        assertEq(nft.gridChunks().length, 1);
        assertEq(nft.grid(767), standInGrid(767));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        nft.grid(768);
    }

    /// Planted past the limit with vm.etch, one 32,768-byte chunk passes every constructor check:
    /// no "chunk but the last" exists to be full, the total is 32,768, and the hash matches. grid()
    /// then reads _gridChunks[1] for glyphs 768..1024, which does not exist: Panic(0x32).
    function testOneChunkPassesConstructorAndGridPanicsPast767() public {
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        address big = address(0xB16C0DE);
        vmEtch.etch(big, abi.encodePacked(hex"00", grids));
        require(big.code.length == 32_769, "etched size");
        address[] memory chunks = new address[](1);
        chunks[0] = big;
        address namesChunk = sstore2(names);
        bytes32 gridsHash = keccak256(grids);
        bytes32 namesHash = keccak256(names);

        KilimGlyphs nft =
            new KilimGlyphs(address(this), TREASURY, 1000, chunks, gridsHash, namesChunk, namesHash, "", "");
        assertEq(nft.gridChunks().length, 1);

        // Everything inside the first 767 grids still reads correctly.
        assertEq(nft.grid(1), standInGrid(1));
        assertEq(nft.grid(767), standInGrid(767));
        // grids() walks the chunk list by real size, so the 1/1's view of the data is intact.
        assertEq(keccak256(nft.grids()), keccak256(grids));

        // Glyphs 768..1024 index a second chunk that was never given.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        nft.grid(768);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        nft.grid(1024);

        // tokenURI goes through grid(), so a minted id whose glyph is past 767 has no metadata.
        uint256 id = 1;
        while (nft.glyphOf(id) <= 767) ++id;
        nft.mintGlyphs(ALICE, ALICE, id, 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        nft.tokenURI(id);
    }

    /// The proposed one-comparison fix pins the count grid() relies on: ceil(1024 / 767) == 2.
    function testProposedCheckPinsTwoChunks() public pure {
        uint256 glyphCount = 1024;
        uint256 perChunk = 767;
        uint256 expected = (glyphCount + perChunk - 1) / perChunk;
        require(expected == 2, "ceil(1024/767)");
    }
}
