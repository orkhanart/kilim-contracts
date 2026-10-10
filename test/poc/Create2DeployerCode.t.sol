// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface VmCreate2Poc {
    function toString(bytes calldata) external pure returns (string memory);
}

/// @notice Review PoC (deploy lens): prints the runtime code forge etches for the deterministic
///         CREATE2 deployer, so a local anvil can be given the same code and the deploy script can be
///         broadcast against it end to end (see test/poc/anvil-broadcast.mjs).
contract Create2DeployerCodeTest {
    VmCreate2Poc internal constant vm = VmCreate2Poc(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function testPrintCreate2DeployerCode() public view {
        bytes memory code = CREATE2_DEPLOYER.code;
        require(code.length != 0, "forge did not etch the CREATE2 deployer");
        (bool ok,) = CONSOLE.staticcall(
            abi.encodeWithSignature("log(string)", string.concat("CREATE2_DEPLOYER_CODE=", vm.toString(code)))
        );
        ok;
    }
}
