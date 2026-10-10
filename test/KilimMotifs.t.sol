// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {TestBase} from "./TestBase.sol";
import {Receiver} from "./mocks/Receiver.sol";

/// @dev A minter whose recipient tries to mint again, through the minter, from inside the receiver
///      callback of the first mint.
contract ReenteringMinter {
    function mint(KilimMotifs nft, address to, uint256 firstId, uint256 quantity) external {
        nft.mintMotifs(to, to, firstId, quantity);
    }
}

contract ReenteringRecipient is IERC721Receiver {
    ReenteringMinter public immutable minter;
    bytes public innerRevert;
    bool public entered;

    constructor(ReenteringMinter minter_) {
        minter = minter_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (!entered) {
            entered = true;
            (bool ok, bytes memory data) = address(minter)
                .call(abi.encodeCall(minter.mint, (KilimMotifs(msg.sender), address(this), tokenId + 100, 1)));
            require(!ok, "re-entered mint");
            innerRevert = data;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract KilimMotifsTest is TestBase {
    KilimMotifs internal nft;

    function setUp() public {
        nft = newMotifs(address(this), TREASURY, MOTIF_CAP);
        mintNext(nft, ALICE, ALICE, 12); // ids 1-12
        mintNext(nft, BOB, BOB, 4); // ids 13-16
    }

    function _decode(string memory uri) private pure returns (string memory) {
        bytes memory data = bytes(uri);
        bytes memory body = new bytes(data.length - 29);
        for (uint256 i; i < body.length; ++i) {
            body[i] = data[i + 29];
        }
        return string(Base64.decode(string(body)));
    }

    /// @dev The first token id that shows `motif`.
    function _idShowing(KilimMotifs k, uint16 motif) private view returns (uint256 id) {
        for (id = 1; id <= k.motifCap(); ++id) {
            if (k.motifOf(id) == motif) return id;
        }
        revert("no id shows the motif");
    }

    // ------------------------------------------------------------ construction

    function testConstructionStoresEverythingAndNothingCanChange() public view {
        assertEq(nft.minter(), address(this));
        assertEq(nft.royaltyReceiver(), TREASURY);
        assertEq(nft.motifCap(), MOTIF_CAP);
        assertEq(nft.MOTIF_COUNT(), 1024);
        assertEq(nft.MAX_MINT_BATCH(), 64);
        assertEq(nft.gridsHash(), keccak256(standInGrids()));
        assertEq(nft.namesHash(), keccak256(standInNames()));
        assertEq(nft.gridChunks().length, 2);
        assertEq(nft.description(), DESCRIPTION);
        assertEq(nft.externalUrl(), EXTERNAL_URL);
        assertEq(nft.name(), "Motif Bazaar");
        assertEq(nft.symbol(), "MOTIF");
        assertEq(nft.motifsMinted(), 16);
        assertEq(nft.motifsBurned(), 0);
    }

    function testFuzzInvalidConfiguration(uint8 selector) public {
        address minter = address(this);
        address royalty = TREASURY;
        uint256 cap = 1000;
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        address[] memory gridChunks = chunked(grids, 767 * 32);
        bytes32 gridsHash = keccak256(grids);
        address namesChunk = sstore2(names);
        bytes32 namesHash = keccak256(names);
        uint256 choice = uint256(selector) % 13;
        if (choice == 0) {
            minter = address(0);
        } else if (choice == 1) {
            royalty = address(0);
        } else if (choice == 2) {
            cap = 0;
        } else if (choice == 3) {
            cap = uint256(type(uint32).max) + 1;
        } else if (choice == 4) {
            gridsHash = keccak256("other grids");
        } else if (choice == 5) {
            namesHash = keccak256("other names");
        } else if (choice == 6) {
            gridChunks = new address[](0);
        }
        // A first chunk that is not full: a grid would straddle the chunks.
        else if (choice == 7) {
            gridChunks = chunked(grids, 767 * 32 - 32);
        }
        // The right hash of the wrong length cannot happen, but the wrong length is refused on its own.
        else if (choice == 8) {
            bytes memory short = new bytes(767 * 32);
            assembly ("memory-safe") {
                mcopy(add(short, 32), add(grids, 32), mload(short))
            }
            gridChunks = chunked(short, 767 * 32);
            gridsHash = keccak256(short);
        }
        // An offset table that goes backwards.
        else if (choice == 9) {
            names[2] = 0xff;
            namesChunk = sstore2(names);
            namesHash = keccak256(names);
        }
        // Trailing bytes after the last name.
        else if (choice == 10) {
            names = bytes.concat(names, "x");
            namesChunk = sstore2(names);
            namesHash = keccak256(names);
        } else if (choice == 11) {
            namesChunk = ALICE; // no code
        } else {
            gridChunks[1] = address(nft); // code, but not a chunk: no leading 0x00
        }
        vm.expectRevert(KilimMotifs.InvalidConfiguration.selector);
        new KilimMotifs(minter, royalty, cap, gridChunks, gridsHash, namesChunk, namesHash, "", "");
    }

    function testAChunkWithoutCodeIsRefused() public {
        address[] memory gridChunks = chunked(standInGrids(), 767 * 32);
        gridChunks[0] = address(0xC0DE1E55);
        bytes32 gridsHash = keccak256(standInGrids());
        address namesChunk = sstore2(standInNames());
        bytes32 namesHash = keccak256(standInNames());
        vm.expectRevert(KilimMotifs.InvalidConfiguration.selector);
        new KilimMotifs(address(this), TREASURY, 1000, gridChunks, gridsHash, namesChunk, namesHash, "", "");
    }

    // ------------------------------------------------------------ minting

    function testOnlyTheMinterMints() public {
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        vm.prank(ALICE);
        nft.mintMotifs(ALICE, ALICE, 17, 1);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        vm.prank(TREASURY);
        nft.mintMotifs(ALICE, ALICE, 17, 1);
    }

    function testMintBounds() public {
        vm.expectRevert(KilimMotifs.InvalidQuantity.selector);
        nft.mintMotifs(ALICE, ALICE, 17, 0);
        vm.expectRevert(KilimMotifs.InvalidQuantity.selector);
        nft.mintMotifs(ALICE, ALICE, 17, 65);
        // Ids run 1..motifCap: 0 is not an id, and no batch may pass the cap.
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        nft.mintMotifs(ALICE, ALICE, 0, 1);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP + 1, 1);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP, 2);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        nft.mintMotifs(ALICE, ALICE, type(uint256).max, 1);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        nft.mintMotifs(ALICE, ALICE, type(uint256).max - 10, 64);
        // The ends are inclusive.
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP, 1);
        assertEq(nft.ownerOf(MOTIF_CAP), ALICE);
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP - 64, 64);
        assertEq(nft.ownerOf(MOTIF_CAP - 1), ALICE);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP - 64, 1);
        // A batch larger than the whole cap reports SupplyExceeded rather than an arithmetic panic.
        KilimMotifs small = newMotifs(address(this), TREASURY, 4);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        small.mintMotifs(ALICE, ALICE, 1, 5);
        small.mintMotifs(ALICE, ALICE, 1, 4);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        small.mintMotifs(ALICE, ALICE, 5, 1);
    }

    function testMintedIdsCannotBeMintedAgainAndTheWholeBatchRollsBack() public {
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(CAROL, ALICE, 10, 8); // 10-16 exist
        assertEq(nft.balanceOf(CAROL), 0);
        assertEq(nft.motifsMinted(), 16);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(CAROL, ALICE, 16, 2); // the first id of the batch exists
        assertEq(nft.motifsMinted(), 16);
        nft.mintMotifs(CAROL, ALICE, 17, 64); // 17-80 are free
        assertEq(nft.motifsMinted(), 80);
        assertEq(nft.balanceOf(CAROL), 64);
    }

    function testBadMintRecipientsAndBidderRejectedBeforeTheQuantity() public {
        address[3] memory bad = [address(0), address(nft), address(this)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
            nft.mintMotifs(bad[i], ALICE, 17, 1);
            vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
            nft.mintMotifs(bad[i], ALICE, 17, 0);
        }
        vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
        nft.mintMotifs(ALICE, address(0), 17, 1);
    }

    event MotifsMinted(address indexed recipient, address indexed bidder, uint256 firstId, uint256 quantity);

    function testMintEmitsOneEventPerBatchAndSafeMintsEach() public {
        Receiver receiver = new Receiver();
        vm.expectEmit();
        emit MotifsMinted(address(receiver), ALICE, 17, 3);
        nft.mintMotifs(address(receiver), ALICE, 17, 3);
        assertEq(receiver.received(), 3);
        receiver.configure(true, address(0), "");
        vm.expectRevert();
        nft.mintMotifs(address(receiver), ALICE, 20, 1);
        assertEq(nft.motifsMinted(), 19);
    }

    function testMintIsGuardedAgainstReentry() public {
        ReenteringMinter minter = new ReenteringMinter();
        ReenteringRecipient recipient = new ReenteringRecipient(minter);
        KilimMotifs own = newMotifs(address(minter), TREASURY, MOTIF_CAP);
        minter.mint(own, address(recipient), 1, 2);
        assertTrue(recipient.entered());
        assertEq(bytes4(recipient.innerRevert()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(own.balanceOf(address(recipient)), 2);
        assertEq(own.motifsMinted(), 2);
        // Outside the callback the same mint goes through: it failed on the guard, not on its own terms.
        minter.mint(own, address(recipient), 101, 1);
        assertEq(own.ownerOf(101), address(recipient));
    }

    function testFuzzMotifsAreFixedBeforeMintAndIgnoreBidderAndRecipient(
        address bidder,
        uint8 count,
        uint16 offset
    ) public {
        if (bidder == address(0)) bidder = ALICE;
        uint256 quantity = 1 + uint256(count) % 64;
        // Any unminted position in the id range, not only the next one.
        uint256 first = 17 + uint256(offset) % (MOTIF_CAP - 16 - quantity + 1);
        uint16[] memory before = new uint16[](quantity);
        for (uint256 i; i < quantity; ++i) {
            before[i] = nft.motifOf(first + i);
        }
        nft.mintMotifs(CAROL, bidder, first, quantity);
        for (uint256 i; i < quantity; ++i) {
            uint256 id = first + i;
            uint16 motif = nft.motifOf(id);
            assertTrue(motif >= 1 && motif <= 1024);
            assertEq(motif, before[i]);
            // Independent reference derivation, so motifOf cannot drift.
            assertEq(motif, uint256(keccak256(abi.encode(block.chainid, address(nft), id))) % 1024 + 1);
            assertEq(nft.ownerOf(id), CAROL);
        }
    }

    function testMotifOfCoversTheIdRangeOnly() public {
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidTokenId.selector, 0));
        nft.motifOf(0);
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidTokenId.selector, MOTIF_CAP + 1));
        nft.motifOf(MOTIF_CAP + 1);
        // Unminted ids are quoted, and the quote survives the mint and any transfer.
        uint16 quoted = nft.motifOf(MOTIF_CAP);
        nft.mintMotifs(ALICE, ALICE, MOTIF_CAP, 1);
        assertEq(nft.motifOf(MOTIF_CAP), quoted);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, MOTIF_CAP);
        assertEq(nft.motifOf(MOTIF_CAP), quoted);
        assertEq(keccak256(bytes(nft.tokenURI(MOTIF_CAP))), keccak256(bytes(nft.tokenURI(MOTIF_CAP))));
    }

    // ------------------------------------------------------------ burning

    function testBurnIsOwnerOnlyAndApprovalsDoNotCount() public {
        vm.prank(ALICE);
        nft.setApprovalForAll(BOB, true);
        vm.prank(ALICE);
        nft.approve(CAROL, 2);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        vm.prank(BOB);
        nft.burn(2);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        vm.prank(CAROL);
        nft.burn(2);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        nft.burn(2); // the minter has no burn right either
        assertEq(nft.ownerOf(2), ALICE);
        // The approved operator can still move it, as the standard allows.
        vm.prank(BOB);
        nft.transferFrom(ALICE, BOB, 2);
        assertEq(nft.ownerOf(2), BOB);
        vm.prank(BOB);
        nft.burn(2);
        assertTrue(nft.burned(2));
        assertEq(nft.motifsBurned(), 1);
        assertEq(nft.balanceOf(BOB), 4);
    }

    function testBurnedIdsStayTakenAndCannotBeBurnedTwice() public {
        vm.prank(ALICE);
        nft.burn(3);
        vm.expectRevert();
        nft.ownerOf(3);
        vm.expectRevert();
        nft.tokenURI(3);
        vm.expectRevert(); // ERC721NonexistentToken
        vm.prank(ALICE);
        nft.burn(3);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(ALICE, ALICE, 3, 1);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(ALICE, ALICE, 2, 2);
        assertEq(nft.motifsMinted(), 16);
        assertEq(nft.motifsBurned(), 1);
        assertTrue(nft.burned(3));
        assertTrue(!nft.burned(2) && !nft.burned(17));
        // The motif it showed is still quoted for the id.
        assertTrue(nft.motifOf(3) >= 1);
    }

    function testSupplyCapCannotBeBypassedByBurning() public {
        KilimMotifs small = newMotifs(address(this), TREASURY, 4);
        mintNext(small, ALICE, ALICE, 4);
        vm.startPrank(ALICE);
        for (uint256 id = 1; id <= 4; ++id) {
            small.burn(id);
        }
        vm.stopPrank();
        assertEq(small.motifsBurned(), 4);
        assertEq(small.balanceOf(ALICE), 0);
        vm.expectRevert(KilimMotifs.SupplyExceeded.selector);
        small.mintMotifs(ALICE, ALICE, 5, 1);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        small.mintMotifs(ALICE, ALICE, 1, 1);
    }

    function testBurnedBitmapIsExactAcrossWordBoundaries() public {
        // Ids 255, 256 and 257 sit at the end of one word and the start of the next.
        nft.mintMotifs(ALICE, ALICE, 255, 3);
        vm.prank(ALICE);
        nft.burn(256);
        assertTrue(!nft.burned(255) && nft.burned(256) && !nft.burned(257));
        assertEq(nft.ownerOf(255), ALICE);
        assertEq(nft.ownerOf(257), ALICE);
        vm.expectRevert(KilimMotifs.AlreadyMinted.selector);
        nft.mintMotifs(ALICE, ALICE, 256, 1);
    }

    // ------------------------------------------------------------ motif data

    function testGridsAtBothEndsAndAcrossTheChunkBoundary() public view {
        assertEq(nft.grid(1), standInGrid(1));
        assertEq(nft.grid(767), standInGrid(767)); // last grid of the first chunk
        assertEq(nft.grid(768), standInGrid(768)); // first grid of the second chunk
        assertEq(nft.grid(1024), standInGrid(1024));
        assertEq(nft.grid(500), standInGrid(500));
    }

    function testGridRejectsMotifsOutsideTheSet() public {
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, 0));
        nft.grid(0);
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, 1025));
        nft.grid(1025);
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, 0));
        nft.name(0);
        vm.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, 1025));
        nft.name(1025);
    }

    function testNamesAtBothEndsAndInTheMiddle() public view {
        assertEq(nft.name(1), standInName(1));
        assertEq(nft.name(2), standInName(2));
        assertEq(nft.name(29), standInName(29));
        assertEq(nft.name(30), standInName(30)); // the same meaning as motif 1
        assertEq(nft.name(767), standInName(767));
        assertEq(nft.name(768), standInName(768));
        assertEq(nft.name(1023), standInName(1023));
        assertEq(nft.name(1024), standInName(1024));
    }

    function testNamesMayBeEmptyAndLong() public {
        string[] memory names = new string[](1024);
        for (uint256 n = 1; n <= 1024; ++n) {
            names[n - 1] = n == 1 ? "" : n == 1024 ? "The longest name there is, forty-four bytes!" : "x";
        }
        bytes memory section = namesSection(names);
        KilimMotifs own = newMotifs(address(this), TREASURY, 100, standInGrids(), section);
        assertEq(own.name(1), "");
        assertEq(own.name(2), "x");
        assertEq(own.name(1024), "The longest name there is, forty-four bytes!");
        assertEq(own.namesHash(), keccak256(section));
    }

    function testGridsReturnsAllBytesInOrder() public view {
        bytes memory all = nft.grids();
        assertEq(all.length, 32_768);
        assertEq(keccak256(all), nft.gridsHash());
        assertEq(keccak256(all), keccak256(standInGrids()));
        bytes32 last;
        assembly ("memory-safe") {
            last := mload(add(add(all, 32), mul(1023, 32)))
        }
        assertEq(last, standInGrid(1024));
    }

    // ------------------------------------------------------------ metadata

    /// @dev Motif K's grid is replaced by a known pattern so the SVG can be checked byte for byte: row 0
    ///      has runs at columns 0-2 and 14-15, row 7 alternates single set bits, row 15 is full.
    function testTokenUriJsonAndSvgWithMergedRuns() public {
        uint16 motif = 300;
        bytes memory grids = standInGrids();
        uint256 row0 = 0xE003; // 1110 0000 0000 0011
        uint256 row7 = 0x5555; // 0101 0101 0101 0101
        uint256 row15 = 0xFFFF;
        bytes32 pattern = bytes32((row0 << 240) | (row7 << (240 - 16 * 7)) | row15);
        assembly ("memory-safe") {
            mstore(add(add(grids, 32), mul(sub(motif, 1), 32)), pattern)
        }
        KilimMotifs own = newMotifs(address(this), TREASURY, 100_000, grids, standInNames());
        assertEq(own.grid(motif), pattern);
        uint256 id = _idShowing(own, motif);
        own.mintMotifs(ALICE, ALICE, id, 1);

        string memory expectedSvg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" shape-rendering="crispEdges">',
            '<rect width="20" height="20" fill="#FFFFFF"/><g fill="#141414">',
            '<rect x="2" y="2" width="3" height="1"/><rect x="16" y="2" width="2" height="1"/>',
            '<rect x="3" y="9" width="1" height="1"/><rect x="5" y="9" width="1" height="1"/>',
            '<rect x="7" y="9" width="1" height="1"/><rect x="9" y="9" width="1" height="1"/>',
            '<rect x="11" y="9" width="1" height="1"/><rect x="13" y="9" width="1" height="1"/>',
            '<rect x="15" y="9" width="1" height="1"/><rect x="17" y="9" width="1" height="1"/>',
            '<rect x="2" y="17" width="16" height="1"/>',
            "</g></svg>"
        );
        assertEq(own.svg(motif), expectedSvg);
        string memory expectedJson = string.concat(
            '{"name":"',
            standInName(motif),
            ' (motif 300)","description":"',
            DESCRIPTION,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(expectedSvg)),
            '","attributes":[{"trait_type":"Motif","value":300},{"trait_type":"Name","value":"',
            standInName(motif),
            '"}]}'
        );
        string memory uri = own.tokenURI(id);
        assertEq(
            keccak256(bytes(uri)),
            keccak256(
                bytes(string.concat("data:application/json;base64,", Base64.encode(bytes(expectedJson))))
            )
        );
        string memory json = _decode(uri);
        assertEq(vm.parseJsonString(json, ".name"), string.concat(standInName(motif), " (motif 300)"));
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 300);
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), standInName(motif));
    }

    function testAnEmptyGridDrawsNoRectAndAFullOneDrawsSixteen() public {
        bytes memory grids = standInGrids();
        assembly ("memory-safe") {
            mstore(add(grids, 32), 0)
            mstore(add(grids, 64), not(0))
        }
        KilimMotifs own = newMotifs(address(this), TREASURY, 100, grids, standInNames());
        assertEq(
            own.svg(1),
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" shape-rendering="crispEdges">',
                '<rect width="20" height="20" fill="#FFFFFF"/><g fill="#141414"></g></svg>'
            )
        );
        bytes memory full = bytes(own.svg(2));
        uint256 rects;
        for (uint256 i; i + 5 < full.length; ++i) {
            if (
                full[i] == "<" && full[i + 1] == "r" && full[i + 2] == "e" && full[i + 3] == "c"
                    && full[i + 4] == "t"
            ) {
                ++rects;
            }
        }
        assertEq(rects, 17); // the paper and one run per row
    }

    function testTokenUriEscapesNamesAndDescription() public {
        string[] memory names = new string[](1024);
        for (uint256 n = 1; n <= 1024; ++n) {
            names[n - 1] = 'say "hi" \\ there';
        }
        KilimMotifs own = new KilimMotifs(
            address(this),
            TREASURY,
            100,
            chunked(standInGrids(), 767 * 32),
            keccak256(standInGrids()),
            sstore2(namesSection(names)),
            keccak256(namesSection(names)),
            string(bytes.concat("A ", hex"1b", ' "quoted" \\ line')),
            "https://kilim.art"
        );
        own.mintMotifs(ALICE, ALICE, 1, 1);
        string memory json = _decode(own.tokenURI(1));
        uint16 motif = own.motifOf(1);
        assertEq(
            vm.parseJsonString(json, ".name"),
            string.concat('say "hi" \\ there (motif ', vm.toString(motif), ")")
        );
        assertEq(
            vm.parseJsonString(json, ".description"), string(bytes.concat("A ", hex"1b", ' "quoted" \\ line'))
        );
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), 'say "hi" \\ there');
    }

    function testTokenUriExistsOnlyForMintedIds() public {
        vm.expectRevert();
        nft.tokenURI(0);
        vm.expectRevert();
        nft.tokenURI(17);
        vm.expectRevert();
        nft.tokenURI(MOTIF_CAP + 1);
        assertTrue(bytes(nft.tokenURI(16)).length != 0);
    }

    function testContractUriBytesAreExact() public {
        KilimMotifs own = new KilimMotifs(
            address(this),
            TREASURY,
            100,
            chunked(standInGrids(), 767 * 32),
            keccak256(standInGrids()),
            sstore2(standInNames()),
            keccak256(standInNames()),
            string(bytes.concat(hex"1b1f00", " x")),
            'a"b\\c'
        );
        assertEq(
            _decode(own.contractURI()),
            string.concat(
                '{"name":"Motif Bazaar","description":"\\u001b\\u001f\\u0000 x","external_link":"a\\"b\\\\c",',
                '"seller_fee_basis_points":500,"fee_recipient":"0x0000000000000000000000000000000000007777"}'
            )
        );
        string memory json = _decode(nft.contractURI());
        assertEq(vm.parseJsonString(json, ".name"), "Motif Bazaar");
        assertEq(vm.parseJsonString(json, ".description"), DESCRIPTION);
        assertEq(vm.parseJsonString(json, ".external_link"), EXTERNAL_URL);
        assertEq(vm.parseJsonUint(json, ".seller_fee_basis_points"), 500);
    }

    function testRoyaltyIsFivePercentToTheReceiverForever() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(2, 1_000_000);
        assertEq(receiver, TREASURY);
        assertEq(amount, 50_000);
        (receiver, amount) = nft.royaltyInfo(9999, 333);
        assertEq(receiver, TREASURY);
        assertEq(amount, 16); // rounds down
        assertTrue(nft.supportsInterface(0x2a55205a));
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(nft.supportsInterface(0x01ffc9a7));
        assertTrue(!nft.supportsInterface(0xffffffff));
    }

    function testNoTransferReachesTheContractOrTheMinter() public {
        vm.startPrank(ALICE);
        vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(nft), 2);
        vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(this), 2);
        vm.expectRevert(KilimMotifs.InvalidRecipient.selector);
        nft.safeTransferFrom(ALICE, address(this), 2);
        vm.stopPrank();
        assertEq(nft.ownerOf(2), ALICE);
    }

    function testMetadataStaysUnchangedOnTransfer() public {
        bytes32 before = keccak256(bytes(nft.tokenURI(2)));
        uint16 motif = nft.motifOf(2);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 2);
        assertEq(nft.motifOf(2), motif);
        assertEq(before, keccak256(bytes(nft.tokenURI(2))));
    }
}
