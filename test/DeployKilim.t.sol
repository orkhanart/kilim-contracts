// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../script/DeployKilim.s.sol";
import {KilimRenderer} from "../src/render/KilimRenderer.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {TestBase} from "./TestBase.sol";

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
    /// orkhanart.eth: treasury and collection-page owner.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;

    DeployKilim internal script;
    string internal manifest;

    function setUp() public {
        script = new DeployKilim();
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
        c.minLeadSeconds = 1 days;
        c.auction.treasury = TREASURY;
        c.auction.collectionOwner = PAGE_OWNER;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = 24 hours;
        c.auction.extensionWindow = 10 minutes;
        c.auction.incrementBps = 1000;
        c.auction.reservePrice = RESERVE;
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
        // any reserve but 0.01 ETH: zero, a wei off, one unit, one unit more
        c.auction.reservePrice = 0;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);
        c.auction.reservePrice = RESERVE + 1;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);
        c.auction.reservePrice = UNIT;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);
        c.auction.reservePrice = RESERVE + UNIT;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);
        c.auction.reservePrice = RESERVE;
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

    /// @dev The store on the local chain, then chain 1.
    function _onMainnet() internal returns (KilimRenderer renderer) {
        renderer = script.deployStore(_config());
        vmd.chainId(1);
    }

    /// @dev Exactly the decided launch settings on chain 1.
    function _mainnetConfig(KilimRenderer renderer) internal view returns (DeployKilim.Config memory c) {
        c = _config();
        c.chainId = 1;
        c.rendererHash = address(renderer).codehash;
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
        assertEq(auction.SYMBOL_PRICE(), 0.001 ether);
        assertEq(auction.REGISTRATION_BALANCE(), 0.01 ether);
        assertEq(auction.REGISTRATION_TARGET(), 100);
        assertEq(address(auction).balance, 0);
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
        c.auction.treasury = TREASURY;
        _expectRefused("mainnet launch value: treasury");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.collectionOwner = PAGE_OWNER;
        _expectRefused("mainnet launch value: collectionOwner");
        script.deployAuction(c, renderer);

        c = _mainnetConfig(renderer);
        c.auction.reservePrice = 20 * UNIT; // a whole number of units, but not the reserve
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
        c.auction.treasury = TREASURY;
        c.auction.collectionOwner = PAGE_OWNER;
        c.auction.duration = 1 hours;
        c.auction.extensionWindow = 1 minutes;
        c.auction.incrementBps = 500;
        c.auction.symbolCap = 10_000;
        c.auction.maxSymbolsPerBid = 250;
        KilimAuction auction = script.deployAuction(c, renderer);
        assertEq(auction.treasury(), TREASURY);
        assertEq(auction.duration(), 1 hours);
        assertEq(auction.extensionWindow(), 1 minutes);
        assertEq(auction.incrementBps(), 500);
        assertEq(auction.symbolCap(), 10_000);
        assertEq(auction.maxSymbolsPerBid(), 250);
        assertEq(auction.reservePrice(), RESERVE);
    }

    /// @dev The reserve is the one setting no chain may change: the constructor accepts only 0.01 ETH.
    function testEveryChainRefusesAnotherReserve() public {
        KilimRenderer renderer = script.deployStore(_config());
        DeployKilim.Config memory c = _config();
        c.rendererHash = address(renderer).codehash;
        c.auction.reservePrice = 20 * UNIT;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);

        vmd.chainId(11_155_111);
        c.chainId = 11_155_111;
        _expectRefused("reserve price");
        script.deployAuction(c, renderer);
    }

    /// @dev The auction the script deploys is the ETH auction: it holds nothing at first, refuses ETH
    ///      sent with no call, takes a bid paid in full and refunds it when it is outbid.
    function testTheDeployedAuctionTakesEthBids() public {
        DeployKilim.Config memory c = _config();
        KilimRenderer renderer = script.deployStore(c);
        c.rendererHash = address(renderer).codehash;
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        KilimAuction auction = script.deployAuction(c, renderer);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);

        _openBidding(auction);
        _fund(ALICE, 1 ether);
        _fund(BOB, 1 ether);
        vm.prank(ALICE);
        (bool sent,) = address(auction).call{value: RESERVE}("");
        assertTrue(!sent);
        assertEq(address(auction).balance, 0);

        // msg.value must be the bid, neither less nor more
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(ALICE);
        auction.bid{value: RESERVE - 1}(RESERVE, 0, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(ALICE);
        auction.bid{value: RESERVE + UNIT}(RESERVE, 0, 0);
        assertEq(address(auction).balance, 0);

        _bid(auction, ALICE, RESERVE);
        assertEq(auction.endsAt(), block.timestamp + c.auction.duration);
        assertEq(address(auction).balance, RESERVE);
        assertEq(address(auction).balance, auction.liabilities());
        assertEq(auction.symbolCredits(ALICE), 10);

        // 10% over 0.01 ETH is 0.011 ETH; ALICE gets her bid back inside BOB's transaction
        assertEq(auction.minimumBid(), 11 * UNIT);
        _bid(auction, BOB, 11 * UNIT);
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, 1 ether - 11 * UNIT);
        assertEq(address(auction).balance, 11 * UNIT);
        assertEq(address(auction).balance, auction.liabilities());

        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(auction.collection().ownerOf(1), BOB);
        assertEq(address(auction).balance, auction.liabilities());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 11 * UNIT);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);
    }

    /// @dev The committed templates carry the launch values the script pins, and stay unreadable until
    ///      every TODO is filled in.
    function testTemplatesCarryTheLaunchValuesAndFailClosed() public {
        _checkTemplate("deploy/mainnet.example.json", 1);
        _checkTemplate("deploy/sepolia.example.json", 11_155_111);
    }

    /// @dev The local dry-run config has no TODO left: it loads, and carries the same launch values.
    function testTheLocalConfigLoadsWithTheLaunchValues() public view {
        DeployKilim.Config memory c = script.loadConfig("deploy/local.json");
        assertEq(c.chainId, 31_337);
        assertEq(c.auction.treasury, script.LAUNCH_TREASURY());
        assertEq(c.auction.collectionOwner, script.LAUNCH_COLLECTION_OWNER());
        assertEq(c.auction.reservePrice, script.LAUNCH_RESERVE_PRICE());
        assertEq(c.auction.incrementBps, script.LAUNCH_INCREMENT_BPS());
        assertEq(c.auction.duration, script.LAUNCH_DURATION());
        assertEq(c.auction.extensionWindow, script.LAUNCH_EXTENSION_WINDOW());
        assertEq(c.auction.symbolCap, script.LAUNCH_SYMBOL_CAP());
        assertEq(c.auction.maxSymbolsPerBid, script.LAUNCH_MAX_SYMBOLS_PER_BID());
        assertEq(c.auction.maxCells, script.LAUNCH_MAX_CELLS());
    }

    function _checkTemplate(string memory path, uint256 chain) internal {
        string memory j = vmd.readFile(path);
        assertEq(vmd.parseJsonUint(j, ".chainId"), chain);
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
