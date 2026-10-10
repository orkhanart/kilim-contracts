// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

/// @dev Skeptic's check of the "launch-size gas test understates the real page" finding. The question
///      that decides whether the gap matters: with the tail at today's packed size (808,872 bytes, 33
///      chunks), how large can the still's base64 grow before tokenURI(1) crosses the 8,000,000 policy
///      ceiling? If no plausible still gets near it, the test's 600 KB / 70 KB constants are a labelling
///      nit, not a measurement gap. The sweep also runs the design's own still size (about 50 KB of PNG,
///      ~67 KB of base64, onchain/ARTWORK-ONCHAIN.md) so the launch shape is actually measured once.
contract OneOfOneStillSizeSweepPoC is TestBase {
    event log_named_uint(string key, uint256 value);
    event log_string(string);

    bytes constant HEAD =
        "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><style>html,body{margin:0;background:#fff}</style></head><body><script>const GRIDS='";
    uint256 constant REAL_TAIL = 808_872;

    KilimMotifs internal motifs;

    function setUp() public {
        motifs = newMotifs(address(this), TREASURY, MOTIF_CAP);
    }

    function _measure(uint256 stillChars, uint256 tailBytes) internal returns (uint256 used, uint256 answer) {
        bytes memory prefix = bytes.concat(
            bytes('{"name":"The Unwoven Kilim","description":"x","image":"data:image/png;base64,'),
            _fill(stillChars, "QUJD"),
            bytes('","animation_url":"data:text/html;base64,')
        );
        bytes memory tail = _fill(tailBytes, "a0B1");
        KilimOneOfOne big = new KilimOneOfOne(
            address(this),
            TREASURY,
            motifs,
            pageFrom(prefix, HEAD, tail),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            EXTERNAL_URL
        );
        big.mint(ALICE);
        used = _readGas(address(big), abi.encodeCall(big.tokenURI, (1)));
        answer = bytes(big.tokenURI(1)).length;
    }

    function _report(uint256 stillChars) internal {
        (uint256 used, uint256 answer) = _measure(stillChars, REAL_TAIL);
        emit log_named_uint("still base64 chars", stillChars);
        emit log_named_uint("  tokenURI(1) gas", used);
        emit log_named_uint("  answer bytes", answer);
        emit log_string(used < 8_000_000 ? "  under 8,000,000" : "  OVER 8,000,000");
    }

    /// @dev The real tail with stills from the placeholder up to 400,000 base64 characters. Each
    ///      measurement deploys about 900 KB of chunks, so the larger stills get a test each to stay
    ///      inside the 4,000,000,000 per-test gas limit.
    function testStillSizeSweepOverTheRealTail() public {
        uint256[5] memory stills = [uint256(216), 67_000, 100_000, 200_000, 400_000];
        for (uint256 i; i < stills.length; ++i) {
            _report(stills[i]);
        }
    }

    function testStill600kOverTheRealTail() public {
        _report(600_000);
    }

    function testStill800kOverTheRealTail() public {
        _report(800_000);
    }

    function testStill1000kOverTheRealTail() public {
        _report(1_000_000);
    }

    /// @dev The launch shape as the design describes it: today's tail and a ~50 KB PNG still.
    function testDesignStillOverTheRealTailStaysUnderPolicy() public {
        (uint256 used, uint256 answer) = _measure(67_000, REAL_TAIL);
        emit log_named_uint("design still (67,000 chars) + real tail: gas", used);
        emit log_named_uint("design still (67,000 chars) + real tail: answer bytes", answer);
        assertTrue(used < 8_000_000);
    }

    function _readGas(address target, bytes memory data) internal view returns (uint256 g) {
        bool ok;
        g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        assertTrue(ok);
    }

    function _fill(uint256 n, bytes4 pattern) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = pattern[i % 4];
        }
    }
}
