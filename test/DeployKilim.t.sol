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
    function chainId(uint256) external;
}

/// @notice The deployment script end to end against the local chain, and every refusal it promises,
///         including the launch settings it pins when the chain is switched to Ethereum mainnet.
contract DeployKilimTest is TestBase {
    VmDeployTest internal constant vmd =
        VmDeployTest(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    string internal constant STORE = "../onchain/build";
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// orkhanart.eth: treasury and collection-page owner.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;

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

    function testRefusesForeignCodeAtTheRendererAddress() public {
        DeployKilim.Config memory c = _config();
        KilimRenderer renderer = script.deployStore(c);
        // Other code where the renderer lives: it is checked like a fresh renderer, and refused.
        vmd.etch(address(renderer), address(mockRenderer).code);
        _expectRefused("renderer immutables");
        script.deployStore(c);
    }

    function testRefusesAnExistingRendererThatIsNotThePublishedOne() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c);
        c.rendererHash = keccak256("the published renderer");
        _expectRefused("renderer code hash differs from the published rendererHash");
        script.deployStore(c);
    }

    function _expectRefused(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployKilim.Refused.selector, reason));
    }

    // ------------------------------------------------------------ Ethereum mainnet

    /// @dev The store on the local chain, then chain 1 with a six-decimal token at the USDC address.
    function _onMainnet() internal returns (KilimRenderer renderer) {
        renderer = script.deployStore(_config());
        vmd.etch(MAINNET_USDC, address(usd).code);
        vmd.chainId(1);
    }

    /// @dev Exactly the decided launch settings on chain 1.
    function _mainnetConfig(KilimRenderer renderer) internal view returns (DeployKilim.Config memory c) {
        c = _config();
        c.chainId = 1;
        c.rendererHash = address(renderer).codehash;
        c.auction.paymentToken = address(0);
        c.tokenDecimals = 18;
        c.auction.reservePrice = 0.01 ether;
        c.auction.treasury = ARTIST;
        c.auction.collectionOwner = ARTIST;
    }

    function testMainnetRefusesTheOneShotRun() public {
        vmd.chainId(1);
        _expectRefused("run() is not for mainnet: use runStore then runAuction");
        script.run();
    }

    function testMainnetDeploysTheExactLaunchSettings() public {
        KilimRenderer renderer = _onMainnet();
        DeployKilim.Config memory c = _mainnetConfig(renderer);
        KilimAuction auction = script.deployAuction(c, renderer);
        assertEq(address(auction.paymentToken()), address(0));
        assertEq(auction.tokenUnit(), 0.001 ether);
        assertEq(auction.treasury(), ARTIST);
        assertEq(auction.reservePrice(), 0.01 ether);
        assertEq(auction.incrementBps(), 1000);
        assertEq(auction.duration(), 86_400);
        assertEq(auction.extensionWindow(), 600);
        assertEq(auction.symbolCap(), 1_000_000);
        assertEq(auction.maxSymbolsPerBid(), 1_000_000);
        Kilim nft = auction.collection();
        assertEq(nft.owner(), ARTIST);
        assertEq(nft.royaltyReceiver(), ARTIST);
        assertEq(nft.maxCells(), 256);
    }

    function testMainnetRefusesEverySettingOtherThanTheLaunchValues() public {
        KilimRenderer renderer = _onMainnet();
        DeployKilim.Config memory c = _mainnetConfig(renderer);
        c.auction.paymentToken = address(usd); // a working six-decimal token, but not USDC
        _expectRefused("mainnet launch value: paymentToken");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.tokenDecimals = 6;
        _expectRefused("mainnet launch value: tokenDecimals");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.treasury = TREASURY;
        _expectRefused("mainnet launch value: treasury");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.collectionOwner = PAGE_OWNER;
        _expectRefused("mainnet launch value: collectionOwner");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.reservePrice = 10 * UNIT; // the stale $10 checklist line
        _expectRefused("mainnet launch value: reservePrice");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.incrementBps = 100;
        _expectRefused("mainnet launch value: incrementBps");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.duration = 8640;
        _expectRefused("mainnet launch value: duration");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.extensionWindow = 60;
        _expectRefused("mainnet launch value: extensionWindow");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.symbolCap = 10_000;
        _expectRefused("mainnet launch value: symbolCap");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.maxSymbolsPerBid = 250;
        _expectRefused("mainnet launch value: maxSymbolsPerBid");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.maxCells = 255;
        _expectRefused("mainnet launch value: maxCells");
        script.deployAuction(c, renderer);
    }

    function testMainnetRequiresThePublishedNonceAndAnInspectionWindow() public {
        KilimRenderer renderer = _onMainnet();
        DeployKilim.Config memory c = _mainnetConfig(renderer);
        c.deployerNonce = script.NO_NONCE_CHECK();
        _expectRefused("mainnet needs the published deployerNonce");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.minLeadSeconds = 0;
        c.auction.startsAt = uint64(block.timestamp + 2 minutes);
        _expectRefused("mainnet needs a nonzero minLeadSeconds");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.deployerNonce = vmd.getNonce(DEPLOYER) + 1;
        _expectRefused("deployer nonce");
        script.deployAuction(c, renderer);
    }

    /// @dev The Sepolia rehearsal and the local chain stay configurable: none of the above is refused there.
    function testOtherChainsAcceptSettingsThatDifferFromTheLaunch() public {
        KilimRenderer renderer = script.deployStore(_config());
        vmd.chainId(11_155_111);
        DeployKilim.Config memory c = _config();
        c.chainId = 11_155_111;
        c.rendererHash = address(renderer).codehash;
        c.deployerNonce = script.NO_NONCE_CHECK();
        c.minLeadSeconds = 0;
        c.auction.startsAt = uint64(block.timestamp + 2 minutes);
        c.auction.reservePrice = 10 * UNIT;
        c.auction.incrementBps = 500;
        c.auction.symbolCap = 10_000;
        c.auction.maxSymbolsPerBid = 250;
        KilimAuction auction = script.deployAuction(c, renderer);
        assertEq(auction.reservePrice(), 10 * UNIT);
        assertEq(auction.incrementBps(), 500);
    }

    /// @dev The committed templates carry the launch values the script pins, and stay unreadable until
    ///      every TODO is filled in.
    function testTemplatesCarryTheLaunchValuesAndFailClosed() public {
        _checkTemplate("deploy/mainnet.example.json", 1, address(0));
        _checkTemplate("deploy/sepolia.example.json", 11_155_111, address(0));
    }

    function _checkTemplate(string memory path, uint256 chain, address token) internal {
        string memory j = vmd.readFile(path);
        assertEq(vmd.parseJsonUint(j, ".chainId"), chain);
        assertEq(vmd.parseJsonAddress(j, ".auction.paymentToken"), token);
        assertEq(vmd.parseJsonUint(j, ".auction.tokenDecimals"), script.LAUNCH_TOKEN_DECIMALS());
        assertEq(vmd.parseJsonAddress(j, ".auction.treasury"), script.LAUNCH_TREASURY());
        assertEq(vmd.parseJsonAddress(j, ".auction.collectionOwner"), script.LAUNCH_COLLECTION_OWNER());
        assertEq(vmd.parseJsonUint(j, ".auction.reservePrice"), script.LAUNCH_RESERVE_PRICE());
        assertEq(vmd.parseJsonUint(j, ".auction.incrementBps"), script.LAUNCH_INCREMENT_BPS());
        assertEq(vmd.parseJsonUint(j, ".auction.duration"), script.LAUNCH_DURATION());
        assertEq(vmd.parseJsonUint(j, ".auction.extensionWindow"), script.LAUNCH_EXTENSION_WINDOW());
        assertEq(vmd.parseJsonUint(j, ".auction.symbolCap"), script.LAUNCH_SYMBOL_CAP());
        assertEq(vmd.parseJsonUint(j, ".auction.maxSymbolsPerBid"), script.LAUNCH_MAX_SYMBOLS_PER_BID());
        assertEq(vmd.parseJsonUint(j, ".auction.maxCells"), script.LAUNCH_MAX_CELLS());
        vm.expectRevert();
        script.loadConfig(path);
    }
}
