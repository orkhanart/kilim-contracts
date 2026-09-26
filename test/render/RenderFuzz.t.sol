// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";

/// @notice Random layouts: the artwork never reverts or outgrows its buffer, has one <use> per cell and one
///         <symbol> per distinct motif; with FFI enabled (pnpm test:render-ffi) every output is compared with
///         onchain/render_ref.py byte for byte.
contract RenderFuzzTest is RenderBase {
    function setUp() public {
        _loadStore();
    }

    /// @dev cols 2..128, rows 2..256/cols, motifs drawn from a pool of 1..count motifs at a random offset.
    function _layout(uint256 seed)
        internal
        view
        returns (uint16[] memory motifs, uint256 cols, uint256 rows, uint256 distinct)
    {
        cols = 2 + seed % 127;
        rows = 2 + (seed >> 8) % (256 / cols - 1);
        motifs = new uint16[](cols * rows);
        uint256 pool = 1 + (seed >> 16) % count;
        uint256 offset = (seed >> 32) % count;
        bool[] memory seen = new bool[](count);
        for (uint256 i; i < motifs.length; ++i) {
            uint256 m = (offset + uint256(keccak256(abi.encode(seed, i))) % pool) % count;
            motifs[i] = uint16(m);
            if (!seen[m]) {
                seen[m] = true;
                ++distinct;
            }
        }
    }

    /// forge-config: default.fuzz.runs = 96
    /// forge-config: ci.fuzz.runs = 512
    function testFuzzArtworkHasOneUsePerCellAndOneSymbolPerMotif(uint256 seed) public view {
        (uint16[] memory motifs, uint256 cols, uint256 rows, uint256 distinct) = _layout(seed);
        bytes memory svg = bytes(renderer.artworkSVG(motifs, cols, rows, appearanceOf(seed >> 64)));
        assertEq(_occurrences(svg, "<use "), motifs.length);
        assertEq(_occurrences(svg, "<symbol "), distinct);
        assertEq(_occurrences(svg, "</svg>"), 1);
    }

    function testFuzzLayoutsOutsideTheRulesRevert(uint16 cols, uint16 rows) public {
        uint256 n = uint256(cols) * rows;
        vmr.assume(cols < 2 || rows < 2 || n > 256);
        n = n > 300 ? 300 : n;
        vmr.expectRevert(abi.encodeWithSelector(KilimRenderer.BadLayout.selector));
        renderer.artworkSVG(new uint16[](n), cols, rows, INK);
    }

    // ------------------------------------------------------------ differential (FFI, opt-in)

    function _ffi() internal view returns (bool) {
        return vmr.envOr("KILIM_FFI", false);
    }

    function _join(uint16[] memory motifs) internal pure returns (string memory s) {
        for (uint256 i; i < motifs.length; ++i) {
            s = string.concat(s, i == 0 ? "" : ",", vmr.toString(uint256(motifs[i])));
        }
    }

    function testFuzzArtworkMatchesTheReference(uint256 seed) public {
        if (!_ffi()) return;
        (uint16[] memory motifs, uint256 cols, uint256 rows,) = _layout(seed);
        bytes32 app = appearanceOf(seed >> 64);
        string[] memory cmd = new string[](8);
        cmd[0] = "python3";
        cmd[1] = "../onchain/render_ref.py";
        cmd[2] = "artwork";
        cmd[3] = storeDir;
        cmd[4] = vmr.toString(cols);
        cmd[5] = vmr.toString(rows);
        cmd[6] = vmr.toString(app);
        cmd[7] = _join(motifs);
        bytes32 want = bytes32(vmr.ffi(cmd));
        (bytes32 got,) =
            _sha(address(renderer), abi.encodeCall(KilimRenderer.artworkSVG, (motifs, cols, rows, app)));
        assertEq(got, want);
    }

    function testFuzzSymbolMatchesTheReference(uint256 motif, uint8 material) public {
        if (!_ffi()) return;
        motif %= count;
        material %= 7;
        string[] memory cmd = new string[](6);
        cmd[0] = "python3";
        cmd[1] = "../onchain/render_ref.py";
        cmd[2] = "symbol";
        cmd[3] = storeDir;
        cmd[4] = vmr.toString(motif);
        cmd[5] = vmr.toString(uint256(material));
        bytes32 want = bytes32(vmr.ffi(cmd));
        (bytes32 got,) = _sha(address(renderer), abi.encodeCall(KilimRenderer.symbolSVG, (motif, material)));
        assertEq(got, want);
    }
}
