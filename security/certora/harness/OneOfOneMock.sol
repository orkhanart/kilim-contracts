// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Stand-in for KilimOneOfOne.mint in the auction specs (verification only, never deployed).
/// @dev The prover dispatches the auction's oneOfOne.mint(to) here. `rejects` is left symbolic, so any
///      recipient may refuse the token, as a wallet whose onERC721Received reverts would. A Solidity-level
///      revert is used on purpose: a CVL `revert` inside a summary was not caught by the auction's
///      try/catch around its deliverPrize self-call (see the report).
contract OneOfOneMock {
    uint256 public mints;
    address public lastTo;
    mapping(address => bool) public rejects;

    function mint(address to) external {
        require(!rejects[to], "receiver rejected the 1/1");
        mints += 1;
        lastTo = to;
    }
}
