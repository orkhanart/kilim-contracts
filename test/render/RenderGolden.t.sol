// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice Byte-for-byte equality with onchain/render_ref.py, through the sha256 golden hashes that
///         onchain/pack_store.py writes next to the store. Nothing here assumes a motif count: every loop runs
///         to the renderer's motifCount, which must agree with the manifest and the golden file.
contract RenderGoldenTest is RenderBase {
    function setUp() public {
        _loadStore();
    }

    function testCountAndOpeningFrameComeFromTheStore() public view {
        assertEq(count, vmr.parseJsonUint(manifest, ".motifCount"));
        assertEq(count, vmr.parseJsonUint(golden, ".count"));
        uint256[] memory still = vmr.parseJsonUintArray(manifest, ".opening.still");
        uint16[9] memory got = renderer.stillMotifs();
        for (uint256 k; k < 9; ++k) {
            assertEq(got[k], still[k]);
        }
        assertEq(renderer.heroMotif(), vmr.parseJsonUint(manifest, ".opening.heroMotif"));
        assertEq(renderer.heroMotif(), got[4]);
        bytes memory geo = renderer.geometry();
        assertEq(keccak256(geo), renderer.geometryHash());
        assertEq(sha256(geo), vmr.parseJsonBytes32(golden, ".geometry"));
        assertEq(geo.length, vmr.parseJsonUint(manifest, ".sections.geometry"));
    }

    function testGoldenMotifPathsForEveryMotif() public view {
        bytes32[] memory want = vmr.parseJsonBytes32Array(golden, ".paths");
        assertEq(want.length, count);
        for (uint256 m; m < count; ++m) {
            (bytes32 h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.motifPath, (m)));
            require(h == want[m], string.concat("motif path ", vmr.toString(m)));
        }
    }

    function testGoldenSymbolsInWoolForEveryMotif() public view {
        bytes32[] memory want = vmr.parseJsonBytes32Array(golden, ".symbols0");
        assertEq(want.length, count);
        for (uint256 m; m < count; ++m) {
            (bytes32 h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.symbolSVG, (m, 0)));
            require(h == want[m], string.concat("symbol ", vmr.toString(m)));
        }
    }

    function testGoldenSymbolsInEveryMaterial() public view {
        uint256 n = vmr.parseJsonUint(golden, ".symbolCaseCount");
        for (uint256 i; i < n; ++i) {
            string memory key = string.concat(".symbolCases[", vmr.toString(i), "]");
            uint256 m = vmr.parseJsonUint(golden, string.concat(key, ".motif"));
            uint256 mat = vmr.parseJsonUint(golden, string.concat(key, ".material"));
            (bytes32 h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.symbolSVG, (m, mat)));
            require(
                h == vmr.parseJsonBytes32(golden, string.concat(key, ".sha256")), string.concat("case ", key)
            );
        }
    }

    function testGoldenArtworksInEveryAppearanceAndSize() public view {
        uint256 n = vmr.parseJsonUint(golden, ".artworkCaseCount");
        for (uint256 i; i < n; ++i) {
            string memory key = string.concat(".artworkCases[", vmr.toString(i), "]");
            uint16[] memory motifs = _uint16s(golden, string.concat(key, ".motifs"));
            uint256 cols = vmr.parseJsonUint(golden, string.concat(key, ".cols"));
            uint256 rows = vmr.parseJsonUint(golden, string.concat(key, ".rows"));
            bytes32 app = vmr.parseJsonBytes32(golden, string.concat(key, ".appearance"));
            (bytes32 h, uint256 len) =
                _sha(address(renderer), abi.encodeCall(KilimRenderer.artworkSVG, (motifs, cols, rows, app)));
            require(
                len == vmr.parseJsonUint(golden, string.concat(key, ".length")), string.concat("length ", key)
            );
            require(
                h == vmr.parseJsonBytes32(golden, string.concat(key, ".sha256")), string.concat("case ", key)
            );
        }
    }

    function testGoldenStillPageAndMasterpiece() public view {
        (bytes32 h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.stillSVG, ()));
        assertEq(h, vmr.parseJsonBytes32(golden, ".still"));
        (h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.masterpieceHTML, ()));
        assertEq(h, vmr.parseJsonBytes32(golden, ".html"));
        (h,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.masterpieceURI, ()));
        assertEq(h, vmr.parseJsonBytes32(golden, ".masterpieceURI"));
    }

    function testGoldenSymbolURIs() public view {
        uint256 n = vmr.parseJsonUint(golden, ".symbolURICaseCount");
        for (uint256 i; i < n; ++i) {
            string memory key = string.concat(".symbolURICases[", vmr.toString(i), "]");
            uint256 id = vmr.parseJsonUint(golden, string.concat(key, ".tokenId"));
            bytes32 seed = vmr.parseJsonBytes32(golden, string.concat(key, ".seed"));
            uint16 m = uint16(vmr.parseJsonUint(golden, string.concat(key, ".motif")));
            uint8 mat = uint8(vmr.parseJsonUint(golden, string.concat(key, ".material")));
            (bytes32 h,) =
                _sha(address(renderer), abi.encodeCall(KilimRenderer.symbolURI, (id, seed, m, mat)));
            require(
                h == vmr.parseJsonBytes32(golden, string.concat(key, ".sha256")), string.concat("case ", key)
            );
        }
    }

    function testGoldenArtworkURIs() public view {
        uint256 n = vmr.parseJsonUint(golden, ".artworkURICaseCount");
        for (uint256 i; i < n; ++i) {
            string memory key = string.concat(".artworkURICases[", vmr.toString(i), "]");
            string memory art = string.concat(
                ".artworkCases[", vmr.toString(vmr.parseJsonUint(golden, string.concat(key, ".case"))), "]"
            );
            bytes memory call = abi.encodeCall(
                KilimRenderer.artworkURI,
                (
                    vmr.parseJsonUint(golden, string.concat(key, ".number")),
                    _uint16s(golden, string.concat(art, ".motifs")),
                    uint16(vmr.parseJsonUint(golden, string.concat(art, ".cols"))),
                    uint16(vmr.parseJsonUint(golden, string.concat(art, ".rows"))),
                    vmr.parseJsonBytes32(golden, string.concat(art, ".appearance")),
                    uint64(vmr.parseJsonUint(golden, string.concat(key, ".revision"))),
                    vmr.parseJsonBool(golden, string.concat(key, ".frozen"))
                )
            );
            (bytes32 h,) = _sha(address(renderer), call);
            require(
                h == vmr.parseJsonBytes32(golden, string.concat(key, ".sha256")), string.concat("case ", key)
            );
        }
    }

    // ------------------------------------------------------------ decoded metadata

    function _json(string memory uri) internal pure returns (string memory) {
        return string(_dataUri(bytes(uri), "data:application/json;base64,"));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function testSymbolMetadataDecodesToTraitsAndImage() public {
        uint16 m = uint16(vmr.parseJsonUint(golden, ".largest"));
        string[6] memory en =
            ["Dyed wool", "Terracotta", "Aged brass", "Black lacquer", "Nephrite", "Cotton rag"];
        string[6] memory az = ["Yun", "Palciq", "Misgar", "Gece", "Yashm", "Kagiz"];
        for (uint8 mat; mat < 6; ++mat) {
            string memory j = _json(renderer.symbolURI(1_000_001, bytes32(uint256(7)), m, mat));
            require(_eq(vmr.parseJsonString(j, ".name"), "Kilim Symbol #1000001"), "name");
            require(_eq(vmr.parseJsonString(j, ".attributes[0].trait_type"), "Kind"), "kind");
            require(_eq(vmr.parseJsonString(j, ".attributes[0].value"), "Symbol"), "kind value");
            require(
                _eq(vmr.parseJsonString(j, ".attributes[1].value"), string.concat("#", vmr.toString(m + 1))),
                "motif"
            );
            require(_eq(vmr.parseJsonString(j, ".attributes[2].trait_type"), "Material"), "material");
            require(_eq(vmr.parseJsonString(j, ".attributes[2].value"), en[mat]), "material value");
            require(_eq(vmr.parseJsonString(j, ".attributes[3].trait_type"), "Material (Azerbaijani)"), "az");
            require(_eq(vmr.parseJsonString(j, ".attributes[3].value"), az[mat]), "az value");
            assertEq(vmr.parseJsonBytes32(j, ".seed"), bytes32(uint256(7)));
            assertEq(vmr.parseJsonBytes32(j, ".geometry_hash"), renderer.geometryHash());
            bytes memory svg = _dataUri(bytes(vmr.parseJsonString(j, ".image")), "data:image/svg+xml;base64,");
            assertEq(keccak256(svg), keccak256(bytes(renderer.symbolSVG(m, mat))));
            // content-stable ids: two tokens inlined in one document never clash
            assertTrue(_contains(svg, bytes(string.concat('<symbol id="m', vmr.toString(m), '"'))));
            if (mat != 5) assertTrue(_contains(svg, bytes(string.concat('id="g', vmr.toString(mat), '"'))));
        }
        vm.expectRevert(KilimRenderer.UnknownMaterial.selector);
        renderer.symbolURI(2, 0, m, 6); // leaf gold is never a symbol material
        vm.expectRevert(KilimRenderer.UnknownMotif.selector);
        renderer.symbolURI(2, 0, uint16(count), 0);
    }

    function testArtworkMetadataDecodesToTraitsAndColours() public {
        uint16[] memory motifs = new uint16[](6);
        uint16 a = uint16(vmr.parseJsonUint(golden, ".smallest"));
        uint16 b = uint16(vmr.parseJsonUint(golden, ".median"));
        (motifs[0], motifs[1], motifs[2], motifs[3], motifs[4], motifs[5]) = (a, b, a, a, b, a);
        bytes32[3] memory apps = [INK, INDIGO, VERMILION];
        string[3] memory labels = ["Ink on paper", "Indigo textile", "Vermilion print"];
        string[3] memory inks = ["#171914", "#eee6d4", "#a63425"];
        string[3] memory plates = ["#f7f6f2", "#283c60", "#f1e5cd"];
        for (uint256 i; i < 3; ++i) {
            string memory j = _json(renderer.artworkURI(42, motifs, 3, 2, apps[i], 5, i == 1));
            require(_eq(vmr.parseJsonString(j, ".name"), "Kilim Artwork #42"), "name");
            require(_eq(vmr.parseJsonString(j, ".attributes[0].value"), "Artwork"), "kind");
            require(_eq(vmr.parseJsonString(j, ".attributes[1].value"), labels[i]), "appearance");
            assertEq(vmr.parseJsonUint(j, ".attributes[2].value"), 3);
            assertEq(vmr.parseJsonUint(j, ".attributes[3].value"), 2);
            assertEq(vmr.parseJsonUint(j, ".attributes[4].value"), 6);
            assertEq(vmr.parseJsonUint(j, ".attributes[5].value"), a == b ? 1 : 2);
            assertEq(vmr.parseJsonUint(j, ".attributes[6].value"), 5);
            require(_eq(vmr.parseJsonString(j, ".attributes[7].value"), i == 1 ? "Yes" : "No"), "frozen");
            require(_eq(vmr.parseJsonString(j, ".attributes[2].display_type"), "number"), "display");
            bytes memory svg = _dataUri(bytes(vmr.parseJsonString(j, ".image")), "data:image/svg+xml;base64,");
            assertTrue(_contains(svg, bytes(string.concat('<g fill="', inks[i], '">'))));
            assertTrue(_contains(svg, bytes(string.concat('fill="', plates[i], '"/><g'))));
            assertEq(_occurrences(svg, "<use "), 6);
            assertEq(_occurrences(svg, "<symbol "), a == b ? 1 : 2);
        }
        vm.expectRevert(KilimRenderer.UnknownAppearance.selector);
        renderer.artworkURI(1, motifs, 3, 2, bytes32("flat/gold"), 1, false);
        vm.expectRevert(KilimRenderer.BadLayout.selector);
        renderer.artworkURI(1, motifs, 2, 3 + 1, INK, 1, false);
        vm.expectRevert(KilimRenderer.BadLayout.selector);
        renderer.artworkURI(1, motifs, 6, 1, INK, 1, false);
    }

    function testMasterpieceAnimationIsThePageWithTheGeometrySpliced() public view {
        string memory j = _json(renderer.masterpieceURI());
        require(_eq(vmr.parseJsonString(j, ".name"), "Kilim 1/1"), "name");
        require(_eq(vmr.parseJsonString(j, ".attributes[0].value"), "Masterpiece"), "kind");
        assertEq(vmr.parseJsonUint(j, ".attributes[1].value"), count);
        bytes memory still = _dataUri(bytes(vmr.parseJsonString(j, ".image")), "data:image/svg+xml;base64,");
        assertEq(keccak256(still), keccak256(bytes(renderer.stillSVG())));
        bytes memory html =
            _dataUri(bytes(vmr.parseJsonString(j, ".animation_url")), "data:text/html;base64,");
        // PAGE[0:stillAt] ++ still ++ PAGE[stillAt:symbolsAt] ++ base64(GEOM) ++ PAGE[symbolsAt:]
        bytes memory store = vmr.readFileBinary(string.concat(storeDir, "/store.bin"));
        uint256 pageOff = 64 + vmr.parseJsonUint(manifest, ".sections.geometry")
            + vmr.parseJsonUint(manifest, ".sections.index");
        uint256 pageLen = vmr.parseJsonUint(manifest, ".sections.page");
        uint256 stillAt = vmr.parseJsonUint(manifest, ".stillAt");
        uint256 symbolsAt = vmr.parseJsonUint(manifest, ".symbolsAt");
        bytes memory geo = renderer.geometry();
        bytes memory expected = bytes.concat(
            _slice(store, pageOff, pageOff + stillAt),
            still,
            _slice(store, pageOff + stillAt, pageOff + symbolsAt),
            bytes(Base64.encode(geo)),
            _slice(store, pageOff + symbolsAt, pageOff + pageLen)
        );
        assertEq(keccak256(html), keccak256(expected));
        assertEq(keccak256(html), keccak256(bytes(renderer.masterpieceHTML())));
        // the base64 embedded in the page decodes to exactly the stored geometry
        uint256 at = stillAt + still.length + (symbolsAt - stillAt);
        bytes memory embedded = _slice(html, at, at + 4 * ((geo.length + 2) / 3));
        assertEq(keccak256(Base64.decode(string(embedded))), renderer.geometryHash());
        // the still is also the page's static fallback, visible before (or without) the script
        assertTrue(_contains(html, bytes('<div id="f"><svg xmlns=')));
    }

    /// @dev The public views take any input, so each must refuse the first value past its range with its own
    ///      error: motif == motifCount would otherwise read past the index.
    function testViewsRejectTheFirstValueOutOfRange() public {
        uint16[] memory motifs = new uint16[](4);
        motifs[3] = uint16(count - 1);
        renderer.artworkSVG(motifs, 2, 2, INK);
        motifs[3] = uint16(count);
        vm.expectRevert(KilimRenderer.UnknownMotif.selector);
        renderer.artworkSVG(motifs, 2, 2, INK);
        vm.expectRevert(KilimRenderer.UnknownMotif.selector);
        renderer.artworkURI(1, motifs, 2, 2, INK, 1, false);
        renderer.motifPath(count - 1);
        vm.expectRevert(KilimRenderer.UnknownMotif.selector);
        renderer.motifPath(count);
        vm.expectRevert(KilimRenderer.UnknownMotif.selector);
        renderer.symbolSVG(count, 0);
        renderer.symbolSVG(0, 6); // leaf gold: drawable, though no token uses it
        vm.expectRevert(KilimRenderer.UnknownMaterial.selector);
        renderer.symbolSVG(0, 7);
    }

    /// @dev The ABI padding after a returned string is zero, as the encoding requires. Kilim.tokenURI forwards
    ///      these bytes verbatim, so strict decoders and byte comparisons see them too.
    function testReturnedAbiPaddingIsZero() public view {
        uint256 checked;
        for (uint256 m; m < 24; ++m) {
            checked += _zeroPadding(
                abi.encodeCall(KilimRenderer.symbolURI, (2 + m, bytes32(m), uint16(m), uint8(m % 6)))
            );
            checked += _zeroPadding(abi.encodeCall(KilimRenderer.motifPath, (m)));
        }
        assertTrue(checked != 0);
    }

    /// @dev Calls the renderer and returns how many padding bytes it checked.
    function _zeroPadding(bytes memory data) private view returns (uint256 n) {
        (bool ok, bytes memory rd) = address(renderer).staticcall(data);
        require(ok, "call reverted");
        uint256 offset;
        uint256 len;
        assembly {
            offset := mload(add(rd, 32))
            len := mload(add(rd, 64))
        }
        assertEq(offset, 32);
        assertEq(rd.length, 64 + (len + 31) / 32 * 32);
        for (uint256 i = 64 + len; i < rd.length; ++i) {
            require(rd[i] == 0, "dirty padding");
            ++n;
        }
    }
}
