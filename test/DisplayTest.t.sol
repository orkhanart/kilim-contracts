// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../script/DeployKilim.s.sol";
import {DisplayTest} from "../script/DisplayTest.s.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {TestBase} from "./TestBase.sol";

interface VmDisplay {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function chainId(uint256) external;
    function warp(uint256) external;
    function expectPartialRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

/// @notice The Sepolia display test (script/DisplayTest.s.sol) on the local chain, over the real packed store:
///         it mints the 1/1 and motifs straight away, both tokenURIs equal the packers' goldens, the collections
///         carry the launch texts, and it refuses to run on Ethereum mainnet.
contract DisplayTestTest is TestBase {
    VmDisplay internal constant vmx = VmDisplay(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant WALLET = address(0xD15);
    address internal constant SENDER = address(0x5E4D);
    string internal constant MOTIF_STORE = "../onchain/build-motifs";
    string internal constant PAGE_STORE = "../onchain/build-page";

    DisplayTest internal script;

    function setUp() public {
        script = new DisplayTest();
        vmx.warp(1_800_000_000);
    }

    function _config() internal view returns (DeployKilim.Config memory c) {
        string memory g = vmx.readFile(string.concat(MOTIF_STORE, "/manifest.json"));
        string memory pg = vmx.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        c.chainId = block.chainid;
        c.deployer = WALLET;
        c.motifStore = MOTIF_STORE;
        c.pageStore = PAGE_STORE;
        c.auction.treasury = TREASURY;
        c.motifCap = 1_000_000;
        c.collectionDescription = vmx.parseJsonString(g, ".description");
        c.collectionExternalUrl = vmx.parseJsonString(g, ".externalUrl");
        c.oneOfOneName = vmx.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmx.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmx.parseJsonString(pg, ".externalUrl");
    }

    function testDisplayMintsTheOneOfOneAndMotifsServedAsMainnetWillServeThem() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c, SENDER);
        DisplayTest.Display memory d = script.displayFrom(c, WALLET);
        assertEq(d.oneOfOne.ownerOf(1), WALLET);
        assertTrue(d.oneOfOne.minted());
        for (uint256 id = 1; id <= script.DISPLAY_MOTIFS(); ++id) {
            assertEq(d.motifs.ownerOf(id), WALLET);
        }
        assertEq(d.motifs.ownerOf(d.goldenId), WALLET);
        assertEq(d.motifs.minter(), d.minter);
        assertEq(d.oneOfOne.minter(), d.minter);
        assertEq(d.oneOfOne.name(), "The Unwoven Kilim");
        assertEq(d.motifs.name(), "Motif Bazaar");
        string memory pg = vmx.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        assertEq(sha256(bytes(d.oneOfOne.tokenURI(1))), vmx.parseJsonBytes32(pg, ".golden.tokenURI.sha256"));
    }

    function testDisplayRefusesAStoreThatIsNotDeployed() public {
        DeployKilim.Config memory c = _config();
        vmx.expectRevert(
            abi.encodeWithSelector(DeployKilim.Refused.selector, "store not deployed: runStore first")
        );
        script.displayFrom(c, WALLET);
    }

    function testDisplayIsRefusedOnMainnet() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c, SENDER);
        vmx.chainId(1);
        vmx.expectRevert(
            abi.encodeWithSelector(DeployKilim.Refused.selector, "the display test is not for mainnet")
        );
        script.displayFrom(c, WALLET);
    }
}
