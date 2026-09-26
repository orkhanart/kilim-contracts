// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../script/DeployKilim.s.sol";
import {KilimRenderer} from "../src/render/KilimRenderer.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

interface VmDeployTest {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function getNonce(address) external view returns (uint64);
    function etch(address, bytes calldata) external;
    function setNonce(address, uint64) external;
    function computeCreateAddress(address, uint256) external pure returns (address);
}

/// @notice The deployment script end to end against the local chain, and every refusal it promises.
contract DeployKilimTest is TestBase {
    VmDeployTest internal constant vmd =
        VmDeployTest(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    string internal constant STORE = "../onchain/build";

    DeployKilim internal script;
    MockUSD internal usd;
    string internal manifest;

    function setUp() public {
        script = new DeployKilim();
        usd = new MockUSD(6);
        manifest = vmd.readFile(string.concat(STORE, "/manifest.json"));
        vm.warp(1_800_000_000);
    }

    function _config() internal view returns (DeployKilim.Config memory c) {
        c.chainId = block.chainid;
        c.store = STORE;
        c.deployer = DEPLOYER;
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        c.motifCount = vmd.parseJsonUint(manifest, ".motifCount");
        c.geometryHash = vmd.parseJsonBytes32(manifest, ".hashes.geometryHash");
        c.indexHash = vmd.parseJsonBytes32(manifest, ".hashes.indexHash");
        c.pageHash = vmd.parseJsonBytes32(manifest, ".hashes.pageHash");
        c.tokenDecimals = 6;
        c.minLeadSeconds = 1 days;
        c.auction.paymentToken = address(usd);
        c.auction.treasury = TREASURY;
        c.auction.collectionOwner = PAGE_OWNER;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = 24 hours;
        c.auction.extensionWindow = 10 minutes;
        c.auction.incrementBps = 1000;
        c.auction.reservePrice = 1 * UNIT;
        c.auction.symbolCap = 1_000_000;
        c.auction.maxSymbolsPerBid = 1_000_000;
        c.auction.maxCells = 256;
    }

    function testDeploysChunksRendererAndAuctionInOrder() public {
        DeployKilim.Config memory c = _config();
        KilimRenderer renderer = script.deployStore(c);
        // chunks land at the manifest's CREATE2 addresses, the renderer at its own
        address[] memory chunks = renderer.chunks();
        for (uint256 k; k < chunks.length; ++k) {
            assertEq(
                chunks[k],
                vmd.parseJsonAddress(manifest, string.concat(".chunks[", vm.toString(k), "].create2"))
            );
        }
        c.rendererHash = address(renderer).codehash;
        uint256 nonce = vmd.getNonce(DEPLOYER);
        c.deployerNonce = nonce;
        KilimAuction auction = script.deployAuction(c, renderer);
        assertEq(address(auction), vmd.computeCreateAddress(DEPLOYER, nonce));
        Kilim nft = auction.collection();
        assertEq(address(nft.renderer()), address(renderer));
        assertEq(nft.rendererHash(), c.rendererHash);
        assertEq(nft.motifCount(), c.motifCount);
    }

    function testTheStorePhaseIsIdempotent() public {
        DeployKilim.Config memory c = _config();
        KilimRenderer first = script.deployStore(c);
        uint256 nonce = vmd.getNonce(DEPLOYER);
        c.rendererHash = address(first).codehash; // now published: it must match on a rerun
        KilimRenderer second = script.deployStore(c);
        assertEq(address(first), address(second));
        assertEq(vmd.getNonce(DEPLOYER), nonce); // nothing was sent the second time
    }

    function testRefusesTheWrongChain() public {
        DeployKilim.Config memory c = _config();
        c.chainId = 1;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
    }

    function testRefusesHashesOrCountsThatDifferFromTheConfig() public {
        DeployKilim.Config memory c = _config();
        c.geometryHash = keccak256("other");
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
        c = _config();
        c.pageHash = keccak256("other");
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
        c = _config();
        c.motifCount += 1;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
        c = _config();
        c.rendererHash = keccak256("a different renderer");
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
    }

    function testRefusesForeignCodeAtAChunkAddress() public {
        DeployKilim.Config memory c = _config();
        vmd.etch(vmd.parseJsonAddress(manifest, ".chunks[2].create2"), hex"00deadbeef");
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployStore(c);
    }

    function testAuctionPhaseRefusals() public {
        DeployKilim.Config memory c = _config();
        KilimRenderer renderer = script.deployStore(c);
        // rendererHash must be published and match
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.rendererHash = keccak256("not the renderer");
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.rendererHash = address(renderer).codehash;
        // the published nonce
        c.deployerNonce = vmd.getNonce(DEPLOYER) + 1;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        // inside the inspection window
        c.auction.startsAt = uint64(block.timestamp + 1 hours);
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        // the token's decimals and a whole-unit reserve
        c.tokenDecimals = 18;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.tokenDecimals = 6;
        c.auction.reservePrice = UNIT + 1;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, renderer);
        c.auction.reservePrice = UNIT;
        // a renderer that is not the published one
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployAuction(c, KilimRenderer(address(mockRenderer)));
        // and with everything right, it deploys
        script.deployAuction(c, renderer);
    }
}
