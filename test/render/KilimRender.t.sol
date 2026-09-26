// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";
import {IKilimRenderer} from "../../src/render/IKilimRenderer.sol";
import {Kilim} from "../../src/Kilim.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {MockUSD} from "../mocks/MockUSD.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Kilim wired to the real renderer over the packed store: what Kilim pushes, what comes back, and
///         the wiring checks, for whatever motif count the store holds.
contract KilimRenderTest is RenderBase {
    Kilim internal nft;
    uint256 internal constant CAP = 10_000;

    event MetadataUpdate(uint256 tokenId);

    function setUp() public {
        _loadStore();
        nft = _kilim(uint16(count), renderer.geometryHash(), address(renderer).codehash, renderer);
        mintNext(nft, ALICE, ALICE, 12); // IDs 2-13
        mintNext(nft, BOB, BOB, 4); // IDs 14-17
    }

    function _kilim(uint16 motifs, bytes32 gh, bytes32 rh, IKilimRenderer r) internal returns (Kilim) {
        return new Kilim(address(this), ALICE, TREASURY, CAP, motifs, 256, gh, rh, r);
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(_dataUri(bytes(nft.tokenURI(id)), "data:application/json;base64,"));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _motifs(uint256 first, uint256 n) internal view returns (uint16[] memory motifs) {
        motifs = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            motifs[i] = nft.symbolData(first + i).motif;
        }
    }

    function testWiringChecksTheRendererAgainstEveryPublishedValue() public {
        bytes32 gh = renderer.geometryHash();
        bytes32 rh = address(renderer).codehash;
        assertEq(address(nft.renderer()), address(renderer));
        assertEq(nft.rendererHash(), rh);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        _kilim(uint16(count - 1), gh, rh, renderer);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        _kilim(uint16(count), keccak256("other geometry"), rh, renderer);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        _kilim(uint16(count), gh, keccak256("other renderer"), renderer);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        _kilim(uint16(count), gh, rh, IKilimRenderer(address(mockRenderer)));
    }

    function testSymbolTokenURIIsTheRenderersAnswerForItsTraits() public view {
        for (uint256 id = 2; id < 18; ++id) {
            (bytes32 seed, uint16 motif, uint8 material) = nft.symbolTraits(id);
            assertEq(
                keccak256(bytes(nft.tokenURI(id))),
                keccak256(bytes(renderer.symbolURI(id, seed, motif, material)))
            );
        }
        string memory j = _json(5);
        Kilim.SymbolData memory s = nft.symbolData(5);
        require(_eq(vmr.parseJsonString(j, ".name"), "Kilim Symbol #5"), "name");
        require(
            _eq(
                vmr.parseJsonString(j, ".attributes[1].value"), string.concat("#", vmr.toString(s.motif + 1))
            ),
            "motif"
        );
        assertEq(vmr.parseJsonBytes32(j, ".seed"), s.seed);
        string[6] memory names =
            ["Dyed wool", "Terracotta", "Aged brass", "Black lacquer", "Nephrite", "Cotton rag"];
        require(_eq(vmr.parseJsonString(j, ".attributes[2].value"), names[s.material]), "material");
    }

    function testArtworkTokenURIFollowsExpandAndFreeze() public {
        vm.prank(ALICE);
        uint256 art = nft.weave(ids(2, 4), 2, 2, INDIGO);
        assertEq(art, CAP + 2);
        assertEq(
            keccak256(bytes(nft.tokenURI(art))),
            keccak256(bytes(renderer.artworkURI(1, _motifs(2, 4), 2, 2, INDIGO, 1, false)))
        );
        string memory j = _json(art);
        require(_eq(vmr.parseJsonString(j, ".name"), "Kilim Artwork #1"), "name");
        require(_eq(vmr.parseJsonString(j, ".attributes[1].value"), "Indigo textile"), "appearance");
        assertEq(vmr.parseJsonUint(j, ".attributes[6].value"), 1);
        require(_eq(vmr.parseJsonString(j, ".attributes[7].value"), "No"), "frozen");

        uint256[] memory cells = ids(2, 6);
        (cells[0], cells[5]) = (cells[5], cells[0]);
        vmr.expectEmit();
        emit MetadataUpdate(art);
        vm.prank(ALICE);
        nft.expand(art, 1, cells, 3, 2, VERMILION);
        uint16[] memory motifs = new uint16[](6);
        for (uint256 i; i < 6; ++i) {
            motifs[i] = nft.symbolData(cells[i]).motif;
        }
        assertEq(
            keccak256(bytes(nft.tokenURI(art))),
            keccak256(bytes(renderer.artworkURI(1, motifs, 3, 2, VERMILION, 2, false)))
        );
        j = _json(art);
        assertEq(vmr.parseJsonUint(j, ".attributes[2].value"), 3);
        assertEq(vmr.parseJsonUint(j, ".attributes[4].value"), 6);
        assertEq(vmr.parseJsonUint(j, ".attributes[6].value"), 2);
        bytes memory svg = _dataUri(bytes(vmr.parseJsonString(j, ".image")), "data:image/svg+xml;base64,");
        assertTrue(_contains(svg, '<g fill="#a63425">'));
        assertEq(_occurrences(svg, "<use "), 6);

        vmr.expectEmit();
        emit MetadataUpdate(art);
        vm.prank(ALICE);
        nft.freezeArtwork(art);
        require(_eq(vmr.parseJsonString(_json(art), ".attributes[7].value"), "Yes"), "frozen after");

        // a second artwork is number 2
        vm.prank(ALICE);
        uint256 second = nft.weave(ids(8, 4), 2, 2, INK);
        require(_eq(vmr.parseJsonString(_json(second), ".name"), "Kilim Artwork #2"), "second name");
    }

    function testBurnedSymbolsHaveNoTokenURI() public {
        vm.prank(ALICE);
        nft.weave(ids(2, 4), 2, 2, INK);
        for (uint256 id = 2; id < 6; ++id) {
            vmr.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
            nft.tokenURI(id);
        }
    }

    function testMasterpieceTokenURIIsTheRenderersAnswer() public {
        vmr.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.tokenURI(1);
        nft.mintMasterpiece(ALICE);
        (bytes32 viaKilim,) = _sha(address(nft), abi.encodeCall(nft.tokenURI, (1)));
        (bytes32 direct,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.masterpieceURI, ()));
        assertEq(viaKilim, direct);
    }

    /// @dev The whole launch path with the real renderer: auction creates Kilim, a bid reserves IDs, a claim
    ///      mints them, and their metadata is drawn.
    function testAuctionCreatesACollectionWiredToTheRenderer() public {
        MockUSD usd = new MockUSD(6);
        KilimAuction.Config memory c = config(address(usd));
        c.motifCount = uint16(count);
        c.geometryHash = renderer.geometryHash();
        c.rendererHash = address(renderer).codehash;
        c.renderer = address(renderer);
        KilimAuction auction = new KilimAuction(c);
        Kilim collection = auction.collection();
        assertEq(address(collection.renderer()), address(renderer));
        usd.mint(ALICE, 100 * UNIT);
        vm.warp(auction.startsAt());
        vm.startPrank(ALICE);
        usd.approve(address(auction), 25 * UNIT);
        auction.bid(25 * UNIT, 25, 0);
        auction.claimSymbols(4, ALICE);
        vm.stopPrank();
        (bytes32 seed, uint16 motif, uint8 material) = collection.symbolTraits(3);
        assertEq(
            keccak256(bytes(collection.tokenURI(3))),
            keccak256(bytes(renderer.symbolURI(3, seed, motif, material)))
        );
        c.renderer = address(mockRenderer);
        vm.expectRevert(Kilim.InvalidConfiguration.selector);
        new KilimAuction(c);
    }
}
