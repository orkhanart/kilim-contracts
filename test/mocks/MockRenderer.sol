// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKilimRenderer} from "../../src/render/IKilimRenderer.sol";

/// @dev Stand-in renderer for unit tests that do not need real media. Its answers encode every input, so a
///      test can check what Kilim pushed. Its code hash depends on the two immutables.
contract MockRenderer is IKilimRenderer {
    uint256 public immutable motifCount;
    bytes32 public immutable geometryHash;
    bool public failing;

    error MockRendererFailure(uint256 tokenId);

    constructor(uint256 motifCount_, bytes32 geometryHash_) {
        motifCount = motifCount_;
        geometryHash = geometryHash_;
    }

    function setFailing(bool value) external {
        failing = value;
    }

    function symbolURI(uint256 tokenId, bytes32 seed, uint16 motif, uint8 material)
        external
        view
        returns (string memory)
    {
        if (failing) revert MockRendererFailure(tokenId);
        return string(abi.encode("symbol", tokenId, seed, motif, material));
    }

    function artworkURI(
        uint256 number,
        uint16[] calldata motifs,
        uint16 columns,
        uint16 rows,
        bytes32 appearance,
        uint64 revision,
        bool frozen
    ) external view returns (string memory) {
        if (failing) revert MockRendererFailure(number);
        return string(abi.encode("artwork", number, motifs, columns, rows, appearance, revision, frozen));
    }

    function masterpieceURI() external view returns (string memory) {
        if (failing) revert MockRendererFailure(1);
        return string(abi.encode("masterpiece"));
    }
}
