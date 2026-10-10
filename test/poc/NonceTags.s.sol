// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev Skeptic PoC for the deploy finding "the nonce check and the 'pending:' print do not see a pending
///      transaction": from inside a forge script forked from a node, print what `vm.getNonce` returns
///      (the value DeployKilim checks and prints as "pending") next to `eth_getTransactionCount` at
///      "latest" and "pending", the latter being what the finding's suggested fix would read.
///      Driven by test/poc/anvil-nonce-tags.mjs; not a deploy script.
interface VmNonce {
    function getNonce(address) external view returns (uint64);
    function rpc(string calldata method, string calldata params) external returns (bytes memory);
    function envAddress(string calldata) external view returns (address);
    function toString(uint256) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
}

contract NonceTags {
    VmNonce internal constant vm = VmNonce(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    function run() external {
        address who = vm.envAddress("NONCE_ACCOUNT");
        _log(string.concat("getNonce ", vm.toString(uint256(vm.getNonce(who)))));
        _log(string.concat("latest ", vm.toString(_count(who, "latest"))));
        _log(string.concat("pending ", vm.toString(_count(who, "pending"))));
    }

    /// @dev eth_getTransactionCount at a block tag. The cheatcode hands the JSON quantity back as its
    ///      big-endian bytes, so the digits are folded in whatever their width.
    function _count(address who, string memory tag) internal returns (uint256 n) {
        bytes memory data =
            vm.rpc("eth_getTransactionCount", string.concat('["', vm.toString(who), '","', tag, '"]'));
        for (uint256 i; i < data.length; ++i) {
            n = (n << 8) | uint8(data[i]);
        }
    }

    function _log(string memory text) internal view {
        (bool ok,) = CONSOLE.staticcall(abi.encodeWithSignature("log(string)", text));
        ok; // best effort
    }
}
