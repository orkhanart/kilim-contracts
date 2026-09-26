// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {Receiver} from "./mocks/Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract KilimTest is TestBase {
    Kilim internal nft;

    function setUp() public {
        nft = new Kilim(
            address(this), ALICE, TREASURY, 10000, 812, 256, keccak256("geometry"), keccak256("renderer")
        );
        mintNext(nft, ALICE, ALICE, 12); // IDs 2-13
        mintNext(nft, BOB, BOB, 4); // IDs 14-17
    }

    function _weave() internal returns (uint256 art) {
        vm.prank(ALICE);
        art = nft.weave(ids(2, 4), 2, 2, keccak256("appearance"));
    }

    function testOnlyMinterCanCreateSymbolsOrMasterpiece() public {
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(ALICE);
        nft.mintSymbols(ALICE, ALICE, 18, 1);
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(ALICE);
        nft.mintMasterpiece(ALICE);
    }

    function testTraitsAndMetadataStayUnchangedOnTransfer() public {
        Kilim.SymbolData memory before = nft.symbolData(2);
        bytes32 uriBefore = keccak256(bytes(nft.tokenURI(2)));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 2);
        Kilim.SymbolData memory after_ = nft.symbolData(2);
        assertEq(before.seed, after_.seed);
        assertEq(before.motif, after_.motif);
        assertEq(before.material, after_.material);
        assertEq(uriBefore, keccak256(bytes(nft.tokenURI(2))));
    }

    function testWeaveBurnsExactlyOnceAndPreservesTraits() public {
        Kilim.SymbolData memory before = nft.symbolData(2);
        uint256 art = _weave();
        assertEq(nft.ownerOf(art), ALICE);
        assertEq(nft.symbolsBurned(), 4);
        assertEq(nft.artworksMinted(), 1);
        assertEq(nft.balanceOf(ALICE), 9);
        Kilim.ArtworkData memory data = nft.artworkData(art);
        assertEq(data.cells.length, 4);
        assertEq(data.columns, 2);
        assertEq(data.rows, 2);
        assertEq(data.revision, 1);
        assertEq(data.appearance, keccak256("appearance"));
        assertEq(nft.symbolData(2).seed, before.seed);
        assertEq(nft.symbolData(2).consumedBy, art);
        for (uint256 i = 2; i < 6; ++i) {
            vm.expectRevert();
            nft.ownerOf(i);
            vm.expectRevert();
            nft.tokenURI(i);
        }
    }

    function testDuplicateInputsRevertEveryBurn() public {
        uint256[] memory cells = ids(2, 4);
        cells[3] = 2;
        vm.expectPartialRevert(Kilim.DuplicateSymbol.selector);
        vm.prank(ALICE);
        nft.weave(cells, 2, 2, bytes32(0));
        assertEq(nft.ownerOf(2), ALICE);
        assertEq(nft.ownerOf(3), ALICE);
        assertEq(nft.symbolsBurned(), 0);
        assertEq(nft.artworksMinted(), 0);
    }

    function testApprovedOperatorCannotBurnOrMutate() public {
        vm.prank(ALICE);
        nft.setApprovalForAll(BOB, true);
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(BOB);
        nft.weave(ids(2, 4), 2, 2, bytes32(0));
        uint256 art = _weave();
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(BOB);
        nft.expand(art, 1, ids(2, 6), 3, 2, bytes32(0));
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(BOB);
        nft.freezeArtwork(art);
        // Standard marketplace transfer approval still works.
        vm.prank(BOB);
        nft.transferFrom(ALICE, BOB, art);
        assertEq(nft.ownerOf(art), BOB);
    }

    function testCannotBurnAnotherHoldersSymbol() public {
        uint256[] memory cells = ids(2, 4);
        cells[3] = 14;
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(ALICE);
        nft.weave(cells, 2, 2, bytes32(0));
        assertEq(nft.symbolsBurned(), 0);
        assertEq(nft.ownerOf(14), BOB);
    }

    function testInvalidDimensionsAndMissingTokensRejected() public {
        vm.startPrank(ALICE);
        vm.expectRevert(Kilim.InvalidLayout.selector);
        nft.weave(ids(2, 4), 1, 4, bytes32(0));
        vm.expectRevert(Kilim.InvalidLayout.selector);
        nft.weave(ids(2, 4), 2, 3, bytes32(0));
        vm.expectRevert(Kilim.InvalidLayout.selector);
        nft.weave(ids(2, 0), 0, 0, bytes32(0));
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        nft.weave(ids(100, 4), 2, 2, bytes32(0));
        vm.stopPrank();
    }

    function testExpandPreservesTokenAndEveryExistingSource() public {
        uint256 art = _weave();
        bytes32 uri = keccak256(bytes(nft.tokenURI(art)));
        uint256[] memory cells = ids(2, 6);
        (cells[0], cells[5]) = (cells[5], cells[0]);
        vm.prank(ALICE);
        nft.expand(art, 1, cells, 3, 2, keccak256("new appearance"));
        assertEq(nft.ownerOf(art), ALICE);
        assertEq(nft.artworksMinted(), 1);
        assertEq(nft.symbolsBurned(), 6);
        Kilim.ArtworkData memory data = nft.artworkData(art);
        assertEq(data.cells[0], 7);
        assertEq(data.cells.length, 6);
        assertEq(data.revision, 2);
        assertEq(data.appearance, keccak256("new appearance"));
        assertTrue(uri != keccak256(bytes(nft.tokenURI(art))));
    }

    function testExpansionCannotOmitExistingSourceEvenWithEnoughNewOnes() public {
        uint256 art = _weave();
        // Replaces existing source 2 with a new source 8.
        vm.expectRevert(Kilim.MissingExistingSymbols.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, ids(3, 6), 3, 2, bytes32(0));
        assertEq(nft.symbolsBurned(), 4);
        assertEq(nft.ownerOf(6), ALICE);
        assertEq(nft.artworkData(art).revision, 1);
    }

    function testExpansionRejectsDuplicateOldAndNewSources() public {
        uint256 art = _weave();
        uint256[] memory cells = ids(2, 6);
        cells[5] = 2;
        vm.expectPartialRevert(Kilim.DuplicateSymbol.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, cells, 3, 2, bytes32(0));
        cells[5] = 6;
        vm.expectPartialRevert(Kilim.DuplicateSymbol.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, cells, 3, 2, bytes32(0));
        assertEq(nft.ownerOf(6), ALICE);
        assertEq(nft.symbolsBurned(), 4);
    }

    function testCannotReuseSourcesFromAnotherArtwork() public {
        uint256 art = _weave();
        vm.expectPartialRevert(Kilim.SymbolAlreadyConsumed.selector);
        vm.prank(ALICE);
        nft.weave(ids(2, 4), 2, 2, bytes32(0));
        vm.prank(ALICE);
        uint256 second = nft.weave(ids(6, 4), 2, 2, bytes32(0));
        vm.expectPartialRevert(Kilim.SymbolAlreadyConsumed.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, ids(2, 6), 3, 2, bytes32(0));
        assertEq(nft.ownerOf(second), ALICE);
    }

    function testStaleRevisionAndSameSizeExpansionRejected() public {
        uint256 art = _weave();
        vm.expectRevert(Kilim.StaleRevision.selector);
        vm.prank(ALICE);
        nft.expand(art, 0, ids(2, 6), 3, 2, bytes32(0));
        vm.expectRevert(Kilim.InvalidLayout.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, ids(2, 4), 2, 2, bytes32(0));
    }

    function testTransferredArtworkCanUseSecondaryMarketSymbols() public {
        uint256 art = _weave();
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, art);
        uint256[] memory cells = ids(2, 6);
        cells[4] = 14;
        cells[5] = 15;
        vm.prank(BOB);
        nft.expand(art, 1, cells, 3, 2, bytes32(0));
        assertEq(nft.ownerOf(art), BOB);
        assertEq(nft.symbolData(14).consumedBy, art);
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(ALICE);
        nft.freezeArtwork(art);
    }

    function testPermanentFreezeSurvivesTransfer() public {
        uint256 art = _weave();
        vm.prank(ALICE);
        nft.freezeArtwork(art);
        vm.expectRevert(Kilim.ArtworkFrozen.selector);
        vm.prank(ALICE);
        nft.expand(art, 1, ids(2, 6), 3, 2, bytes32(0));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, art);
        assertTrue(nft.artworkData(art).frozen);
        vm.expectRevert(Kilim.ArtworkFrozen.selector);
        vm.prank(BOB);
        nft.freezeArtwork(art);
    }

    function testRejectingArtworkReceiverRollsBackAllBurns() public {
        Receiver receiver = new Receiver();
        uint256 first = mintNext(nft, address(receiver), ALICE, 4);
        receiver.configure(true, address(0), "");
        vm.expectRevert();
        vm.prank(address(receiver));
        nft.weave(ids(first, 4), 2, 2, bytes32(0));
        assertEq(nft.ownerOf(first), address(receiver));
        assertEq(nft.symbolsBurned(), 0);
    }

    function testArtworkCallbackSeesFinalStateAndCannotReenter() public {
        Receiver receiver = new Receiver();
        uint256 first = mintNext(nft, address(receiver), ALICE, 4);
        receiver.configure(false, address(nft), abi.encodeCall(nft.weave, (ids(first, 4), 2, 2, bytes32(0))));
        receiver.setInspectArtwork(true);
        vm.prank(address(receiver));
        uint256 art = nft.weave(ids(first, 4), 2, 2, bytes32(0));
        assertTrue(!receiver.callbackSucceeded());
        assertEq(nft.ownerOf(art), address(receiver));
        assertEq(nft.artworksMinted(), 1);
    }

    function testMasterpieceCannotBeBurnedAndOnlyMintsOnce() public {
        nft.mintMasterpiece(ALICE);
        vm.expectRevert(Kilim.AlreadyMinted.selector);
        nft.mintMasterpiece(ALICE);
        uint256[] memory cells = ids(2, 4);
        cells[0] = 1;
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        vm.prank(ALICE);
        nft.weave(cells, 2, 2, bytes32(0));
        assertEq(nft.ownerOf(1), ALICE);
    }

    function testSupplyAndBatchCapsCannotBeBypassedByBurning() public {
        Kilim small =
            new Kilim(address(this), ALICE, TREASURY, 4, 812, 4, bytes32(uint256(1)), bytes32(uint256(1)));
        mintNext(small, ALICE, ALICE, 4);
        vm.prank(ALICE);
        small.weave(ids(2, 4), 2, 2, bytes32(0));
        vm.expectRevert(Kilim.SupplyExceeded.selector);
        small.mintSymbols(ALICE, ALICE, 6, 1);
        // A batch larger than the whole cap reports SupplyExceeded rather than an arithmetic panic.
        vm.expectRevert(Kilim.SupplyExceeded.selector);
        small.mintSymbols(ALICE, ALICE, 2, 5);
        // Burned IDs stay reserved: they can never be minted again.
        vm.expectRevert(Kilim.AlreadyMinted.selector);
        small.mintSymbols(ALICE, ALICE, 2, 1);
        vm.expectRevert(Kilim.InvalidQuantity.selector);
        nft.mintSymbols(ALICE, ALICE, 18, 65);
        vm.expectRevert(Kilim.InvalidQuantity.selector);
        nft.mintSymbols(ALICE, ALICE, 18, 0);
    }

    function testUnsafeTransfersToProtocolContractsAreRejected() public {
        vm.startPrank(ALICE);
        vm.expectRevert(Kilim.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(nft), 2);
        vm.expectRevert(Kilim.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(this), 2);
        vm.stopPrank();
    }

    function testTokenKindsAndInterfaces() public {
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(nft.supportsInterface(0x49064906));
        assertTrue(!nft.supportsInterface(0xffffffff));
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        nft.symbolData(1000);
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        nft.artworkData(2);
        vm.expectRevert();
        nft.tokenURI(1000);
    }

    function _decode(string memory uri) private pure returns (string memory) {
        bytes memory data = bytes(uri);
        bytes memory body = new bytes(data.length - 29);
        for (uint256 i; i < body.length; ++i) {
            body[i] = data[i + 29];
        }
        return string(Base64.decode(string(body)));
    }

    function _json(uint256 id) private view returns (string memory) {
        bytes memory uri = bytes(nft.tokenURI(id));
        bytes memory body = new bytes(uri.length - 29);
        for (uint256 i; i < body.length; ++i) {
            body[i] = uri[i + 29];
        }
        return string(Base64.decode(string(body)));
    }

    function testMetadataParsesAndMatchesOnchainState() public {
        string memory symbol = _json(2);
        assertEq(keccak256(bytes(vm.parseJsonString(symbol, ".kind"))), keccak256("symbol"));
        assertEq(vm.parseJsonUint(symbol, ".motif"), nft.symbolData(2).motif);
        assertEq(vm.parseJsonUint(symbol, ".material"), nft.symbolData(2).material);
        uint256 art = _weave();
        string memory artwork = _json(art);
        assertEq(vm.parseJsonUint(artwork, ".revision"), 1);
        assertEq(vm.parseJsonUint(artwork, ".columns"), 2);
        assertTrue(!vm.parseJsonBool(artwork, ".frozen"));
        vm.prank(ALICE);
        nft.freezeArtwork(art);
        assertTrue(vm.parseJsonBool(_json(art), ".frozen"));
        nft.mintMasterpiece(ALICE);
        assertEq(keccak256(bytes(vm.parseJsonString(_json(1), ".kind"))), keccak256("masterpiece"));
    }

    function testBadMintRecipientsAndSeedOwnerRejected() public {
        address[3] memory bad = [address(0), address(nft), address(this)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Kilim.InvalidRecipient.selector);
            nft.mintSymbols(bad[i], ALICE, 18, 1);
            vm.expectRevert(Kilim.InvalidRecipient.selector);
            nft.mintMasterpiece(bad[i]);
        }
        vm.expectRevert(Kilim.InvalidRecipient.selector);
        nft.mintSymbols(ALICE, address(0), 18, 1);
    }

    function testCannotExpandOrFreezeASymbol() public {
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        vm.prank(ALICE);
        nft.expand(2, 1, ids(2, 6), 3, 2, bytes32(0));
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        vm.prank(ALICE);
        nft.freezeArtwork(2);
    }

    function testRoyaltyIsFivePercentToTheReceiver() public {
        (address receiver, uint256 amount) = nft.royaltyInfo(2, 1_000_000);
        assertEq(receiver, TREASURY);
        assertEq(amount, 50_000);
        assertTrue(nft.supportsInterface(0x2a55205a));
        vm.prank(ALICE);
        nft.setRoyaltyReceiver(BOB);
        (receiver, amount) = nft.royaltyInfo(9999, 333);
        assertEq(receiver, BOB);
        assertEq(amount, 16); // rounds down
    }

    function testOnlyPageOwnerEditsPageAndCannotTouchTokens() public {
        assertEq(nft.owner(), ALICE);
        vm.startPrank(BOB);
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.setCollectionInfo("x", "y");
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.setRoyaltyReceiver(BOB);
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.transferOwnership(BOB);
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.renounceOwnership();
        vm.stopPrank();
        // The page owner has no power over tokens, supply or compositions.
        vm.startPrank(ALICE);
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.mintSymbols(ALICE, ALICE, 18, 1);
        vm.expectRevert(Kilim.Unauthorized.selector);
        nft.mintMasterpiece(ALICE);
        vm.expectRevert(); // standard ERC-721 approval error: the role grants no token rights
        nft.transferFrom(BOB, ALICE, 14);
        vm.stopPrank();
        assertEq(nft.ownerOf(14), BOB);
        // A symbol it does not own cannot be woven away either.
        uint256[] memory cells = ids(14, 4);
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(ALICE);
        nft.weave(cells, 2, 2, bytes32(0));
    }

    function testContractUriCarriesEscapedTextAndRoyalty() public {
        vm.prank(ALICE);
        nft.setCollectionInfo('A "living" language\n\\ of symbols', "https://kilim.art");
        string memory json = _decode(nft.contractURI());
        assertEq(keccak256(bytes(vm.parseJsonString(json, ".name"))), keccak256("Kilim"));
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".description"))),
            keccak256(bytes('A "living" language\n\\ of symbols'))
        );
        assertEq(keccak256(bytes(vm.parseJsonString(json, ".external_link"))), keccak256("https://kilim.art"));
        assertEq(vm.parseJsonUint(json, ".seller_fee_basis_points"), 500);
    }

    function testOwnershipTransferAndRenounce() public {
        vm.prank(ALICE);
        nft.transferOwnership(BOB);
        assertEq(nft.owner(), BOB);
        vm.prank(BOB);
        nft.setCollectionInfo("new", "link");
        vm.prank(BOB);
        nft.renounceOwnership();
        assertEq(nft.owner(), address(0));
        // Nothing can be edited afterwards, and royalties keep paying the last receiver.
        vm.expectRevert(Kilim.Unauthorized.selector);
        vm.prank(BOB);
        nft.setCollectionInfo("x", "y");
        (address receiver,) = nft.royaltyInfo(2, 100);
        assertEq(receiver, TREASURY);
    }

    function testFuzzInvalidCollectionConfiguration(uint8 selector) public {
        address minter = address(this);
        address pageOwner = ALICE;
        address royalty = TREASURY;
        uint256 cap = 1000;
        uint16 motifs = 812;
        uint16 cells = 256;
        bytes32 geometry = bytes32(uint256(1));
        bytes32 renderer = bytes32(uint256(1));
        uint256 choice = uint256(selector) % 10;
        if (choice == 0) minter = address(0);
        else if (choice == 1) cap = 0;
        else if (choice == 2) cap = uint256(type(uint64).max) + 1;
        else if (choice == 3) motifs = 0;
        else if (choice == 4) cells = 3;
        else if (choice == 5) cells = 257;
        else if (choice == 6) geometry = bytes32(0);
        else if (choice == 7) renderer = bytes32(0);
        else if (choice == 8) pageOwner = address(0);
        else royalty = address(0);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        new Kilim(minter, pageOwner, royalty, cap, motifs, cells, geometry, renderer);
    }

    function testMaximumCanvasGasAndLimit() public {
        Kilim large = new Kilim(
            address(this), ALICE, TREASURY, 2048, 812, 256, bytes32(uint256(1)), bytes32(uint256(1))
        );
        for (uint256 i; i < 4; ++i) {
            mintNext(large, ALICE, ALICE, 64);
        }
        vm.prank(ALICE);
        uint256 art = large.weave(ids(2, 256), 16, 16, bytes32(0));
        assertEq(large.artworkData(art).cells.length, 256);
        assertEq(large.symbolsBurned(), 256);
        vm.expectRevert(Kilim.InvalidLayout.selector);
        vm.prank(ALICE);
        large.expand(art, 1, ids(2, 272), 17, 16, bytes32(0));
    }

    function testFuzzTraitsAreFixedBeforeClaimAndIgnoreBidder(address bidder, uint8 count, uint16 offset)
        public
    {
        if (bidder == address(0)) bidder = ALICE;
        uint256 quantity = 1 + uint256(count) % 64;
        // Any unminted position in the symbol range, not only the next one.
        uint256 first = 18 + uint256(offset) % (10000 - 16 - quantity + 1);
        bytes32[] memory seeds = new bytes32[](quantity);
        uint16[] memory motifs = new uint16[](quantity);
        uint8[] memory materials = new uint8[](quantity);
        for (uint256 i; i < quantity; ++i) {
            (seeds[i], motifs[i], materials[i]) = nft.symbolTraits(first + i);
        }
        nft.mintSymbols(CAROL, bidder, first, quantity);
        for (uint256 i; i < quantity; ++i) {
            Kilim.SymbolData memory symbol = nft.symbolData(first + i);
            assertTrue(symbol.motif < 812);
            assertTrue(symbol.material < 6);
            // Independent reference derivation, so symbolTraits and minting cannot drift together.
            bytes32 seed = keccak256(abi.encode(block.chainid, address(nft), first + i));
            uint256 roll = uint256(keccak256(abi.encode(seed, "material"))) % 100;
            uint256[6] memory upper = [uint256(44), 68, 82, 91, 96, 100];
            uint256 material;
            while (roll >= upper[material]) ++material;
            assertEq(symbol.seed, seed);
            assertEq(symbol.motif, uint256(seed) % 812);
            assertEq(symbol.material, material);
            assertEq(symbol.seed, seeds[i]);
            assertEq(symbol.motif, motifs[i]);
            assertEq(symbol.material, materials[i]);
        }
    }

    function testSymbolRangeBoundariesAndArtworkIds() public {
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        nft.symbolTraits(1);
        vm.expectPartialRevert(Kilim.WrongKind.selector);
        nft.symbolTraits(10002);
        nft.symbolTraits(10001);
        vm.expectRevert(Kilim.SupplyExceeded.selector);
        nft.mintSymbols(ALICE, ALICE, 1, 1);
        vm.expectRevert(Kilim.SupplyExceeded.selector);
        nft.mintSymbols(ALICE, ALICE, 10001, 2);
        vm.expectRevert(Kilim.SupplyExceeded.selector);
        nft.mintSymbols(ALICE, ALICE, type(uint256).max, 1);
        nft.mintSymbols(ALICE, ALICE, 10001, 1);
        assertEq(nft.ownerOf(10001), ALICE);
        vm.expectRevert(Kilim.AlreadyMinted.selector);
        nft.mintSymbols(ALICE, ALICE, 10000, 2);
        // Artworks start after the reserved symbol range, whatever has been claimed so far.
        assertEq(_weave(), 10002);
    }

    function testFuzzDuplicatePositionAlwaysReverts(uint8 position) public {
        uint256[] memory cells = ids(2, 4);
        uint256 p = uint256(position) % 4;
        cells[p] = cells[(p + 1) % 4];
        vm.expectPartialRevert(Kilim.DuplicateSymbol.selector);
        vm.prank(ALICE);
        nft.weave(cells, 2, 2, bytes32(0));
        assertEq(nft.symbolsBurned(), 0);
    }
}
