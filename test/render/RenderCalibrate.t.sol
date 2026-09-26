// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RenderBase} from "./RenderBase.sol";
import {KilimRenderer} from "../../src/render/KilimRenderer.sol";

/// @notice Measurements for refitting onchain/pack_store.py's GAS_MODEL (pnpm gas:calibrate). Skipped
///         unless KILIM_CALIBRATE is set, since it asserts nothing.
contract RenderCalibrateTest is RenderBase {
    event log_string(string s);

    function setUp() public {
        _loadStore();
    }

    function testCalibrationData() public {
        if (!vmr.envOr("KILIM_CALIBRATE", false)) return;
        uint256 n = vmr.parseJsonUint(golden, ".artworkCaseCount");
        for (uint256 i; i < n; ++i) {
            string memory key = string.concat(".artworkCases[", vmr.toString(i), "]");
            uint16[] memory motifs = _uint16s(golden, string.concat(key, ".motifs"));
            uint256 cols = vmr.parseJsonUint(golden, string.concat(key, ".cols"));
            uint256 rows = vmr.parseJsonUint(golden, string.concat(key, ".rows"));
            bytes32 app = vmr.parseJsonBytes32(golden, string.concat(key, ".appearance"));
            uint256 g = _ethCallGas(
                address(renderer),
                abi.encodeCall(
                    KilimRenderer.artworkURI, (1, motifs, uint16(cols), uint16(rows), app, 1, false)
                )
            );
            emit log_string(string.concat("CAL art ", vmr.toString(i), " ", vmr.toString(g)));
        }
        uint256 one = _ethCallGas(address(renderer), abi.encodeCall(KilimRenderer.masterpieceURI, ()));
        emit log_string(string.concat("CAL one ", vmr.toString(one)));
        uint16[3] memory ms = [
            uint16(vmr.parseJsonUint(golden, ".smallest")),
            uint16(vmr.parseJsonUint(golden, ".median")),
            uint16(vmr.parseJsonUint(golden, ".largest"))
        ];
        for (uint256 k; k < 3; ++k) {
            uint256 g = _ethCallGas(
                address(renderer), abi.encodeCall(KilimRenderer.symbolURI, (2, bytes32(0), ms[k], 5))
            );
            emit log_string(string.concat("CAL sym ", vmr.toString(ms[k]), " ", vmr.toString(g)));
        }
    }
}
