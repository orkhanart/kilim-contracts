// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What Kilim needs from its renderer. Kilim pushes every input; the renderer never calls back.
interface IKilimRenderer {
    /// @notice Number of motifs in the stored geometry (its leading varint).
    function motifCount() external view returns (uint256);

    /// @notice keccak256 of the stored geometry bytes (GEOM).
    function geometryHash() external view returns (bytes32);

    /// @notice Metadata of symbol `tokenId`: motif `motif` in material `material` (0..5).
    function symbolURI(uint256 tokenId, bytes32 seed, uint16 motif, uint8 material)
        external
        view
        returns (string memory);

    /// @notice Metadata of the `number`-th artwork (1-based), its cells' motifs in row-major order.
    function artworkURI(
        uint256 number,
        uint16[] calldata motifs,
        uint16 columns,
        uint16 rows,
        bytes32 appearance,
        uint64 revision,
        bool frozen
    ) external view returns (string memory);

    /// @notice Metadata of the 1/1, with its interactive page as animation_url.
    function masterpieceURI() external view returns (string memory);
}
