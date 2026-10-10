// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../script/DeployKilim.s.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {TestBase} from "./TestBase.sol";

interface VmDeployTest {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function getNonce(address) external view returns (uint64);
    function etch(address, bytes calldata) external;
    function setNonce(address, uint64) external;
    function computeCreateAddress(address, uint256) external pure returns (address);
    function chainId(uint256) external;
    function setEnv(string calldata, string calldata) external;
    function warp(uint256) external;
}

/// @notice The deployment script end to end against the local chain, and every refusal it promises,
///         including the launch settings it pins when the chain is switched to Ethereum mainnet.
///         The store tests read the packed stores that onchain/pack_motifs.py and onchain/pack_page.py
///         write; without them every test that deploys the store fails at the file read.
contract DeployKilimTest is TestBase {
    VmDeployTest internal constant vmd =
        VmDeployTest(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    string internal constant MOTIF_STORE = "../onchain/build-motifs";
    string internal constant PAGE_STORE = "../onchain/build-page";
    /// orkhanart.eth: deployer, treasury and royalty receiver on mainnet.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;

    DeployKilim internal script;

    function setUp() public {
        script = new DeployKilim();
        vm.warp(1_800_000_000);
    }

    function _config() internal view returns (DeployKilim.Config memory c) {
        c.chainId = block.chainid;
        c.deployer = DEPLOYER;
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        c.minLeadSeconds = 1 days;
        c.motifStore = MOTIF_STORE;
        c.pageStore = PAGE_STORE;
        c.auction.treasury = TREASURY;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = 24 hours;
        c.auction.extensionWindow = 10 minutes;
        c.auction.incrementBps = 1000;
        c.auction.reservePrice = RESERVE;
        c.auction.maxMotifsPerBid = 1_000_000;
        c.motifCap = 1_000_000;
        // The golden hashes in the manifests were computed with these texts.
        string memory g = _motifManifest();
        string memory pg = vmd.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        c.collectionDescription = vmd.parseJsonString(g, ".description");
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = vmd.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmd.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmd.parseJsonString(pg, ".externalUrl");
    }

    function _motifManifest() internal view returns (string memory) {
        return vmd.readFile(string.concat(MOTIF_STORE, "/manifest.json"));
    }

    function testDeploysChunksAndContractsInOrder() public {
        DeployKilim.Config memory c = _config();
        DeployKilim.Store memory s = script.deployStore(c);
        string memory manifest = _motifManifest();
        for (uint256 k; k < s.grids.addresses.length; ++k) {
            assertEq(
                s.grids.addresses[k],
                vmd.parseJsonAddress(manifest, string.concat(".grids.chunks[", vm.toString(k), "].address"))
            );
            assertTrue(s.grids.addresses[k].code.length != 0);
        }
        uint256 nonce = vmd.getNonce(DEPLOYER);
        c.deployerNonce = nonce;
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(address(d.motifs), vmd.computeCreateAddress(DEPLOYER, nonce));
        assertEq(address(d.oneOfOne), vmd.computeCreateAddress(DEPLOYER, nonce + 1));
        assertEq(address(d.auction), vmd.computeCreateAddress(DEPLOYER, nonce + 2));
        assertEq(d.motifs.minter(), address(d.auction));
        assertEq(d.oneOfOne.minter(), address(d.auction));
        assertEq(address(d.oneOfOne.motifs()), address(d.motifs));
        assertEq(address(d.auction.motifs()), address(d.motifs));
        assertEq(address(d.auction.oneOfOne()), address(d.oneOfOne));
        assertEq(d.motifs.gridsHash(), s.grids.hash);
        assertEq(d.oneOfOne.tailHash(), s.tail.hash);
        assertTrue(!d.oneOfOne.minted());
        assertEq(d.motifs.motifsMinted(), 0);
    }

    function testTheStorePhaseIsIdempotent() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c);
        uint256 nonce = vmd.getNonce(DEPLOYER);
        script.deployStore(c);
        assertEq(vmd.getNonce(DEPLOYER), nonce); // nothing was sent the second time
    }

    function testRefusesTheWrongChain() public {
        DeployKilim.Config memory c = _config();
        c.chainId = 1;
        _expectRefused("wrong chain");
        script.deployStore(c);
        _expectRefused("wrong chain");
        script.deployContracts(c);
    }

    function testRefusesForeignCodeAtAChunkAddress() public {
        DeployKilim.Config memory c = _config();
        string memory manifest = _motifManifest();
        vmd.etch(vmd.parseJsonAddress(manifest, ".grids.chunks[1].address"), hex"00deadbeef");
        _expectRefused("grids: foreign code at a chunk address");
        script.deployStore(c);
    }

    function testContractsPhaseRefusals() public {
        DeployKilim.Config memory c = _config();
        // the store must be deployed first
        _expectRefused("store not deployed: runStore first");
        script.deployContracts(c);
        script.deployStore(c);
        // the published nonce
        c.deployerNonce = vmd.getNonce(DEPLOYER) + 1;
        _expectRefused("deployer nonce");
        script.deployContracts(c);
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        // inside the inspection window
        c.auction.startsAt = uint64(block.timestamp + 1 hours);
        _expectRefused("startsAt outside the inspection window");
        script.deployContracts(c);
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        // any reserve but 0.01 ETH: zero, a wei off, one unit, one unit more
        c.auction.reservePrice = 0;
        _expectRefused("reserve price");
        script.deployContracts(c);
        c.auction.reservePrice = RESERVE + 1;
        _expectRefused("reserve price");
        script.deployContracts(c);
        c.auction.reservePrice = UNIT;
        _expectRefused("reserve price");
        script.deployContracts(c);
        c.auction.reservePrice = RESERVE + UNIT;
        _expectRefused("reserve price");
        script.deployContracts(c);
        c.auction.reservePrice = RESERVE;
        // a description that is not the one the golden hash was computed with
        string memory packed = c.collectionDescription;
        c.collectionDescription = "another description";
        _expectRefused("collection description differs from the packed motifs");
        script.deployContracts(c);
        c.collectionDescription = packed;
        c.oneOfOneExternalUrl = "https://elsewhere.example";
        _expectRefused("1/1 name, description or externalUrl differs from the packed page");
        script.deployContracts(c);
        c.oneOfOneExternalUrl =
            vmd.parseJsonString(vmd.readFile(string.concat(PAGE_STORE, "/manifest.json")), ".externalUrl");
        // and with everything right, it deploys
        script.deployContracts(c);
    }

    function _expectRefused(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployKilim.Refused.selector, reason));
    }

    // ------------------------------------------------------------ Ethereum mainnet

    /// @dev Exactly the decided launch settings on chain 1. Every refusal below happens before the store
    ///      is read, so these tests need no store; only the deployment itself does.
    function _mainnetConfig() internal view returns (DeployKilim.Config memory c) {
        c = _config();
        c.chainId = 1;
        c.deployer = ARTIST;
        c.deployerNonce = vmd.getNonce(ARTIST);
        c.auction.reservePrice = 0.01 ether;
        c.auction.treasury = ARTIST;
    }

    function testMainnetRefusesTheOneShotRun() public {
        vmd.chainId(1);
        _expectRefused("run() is not for mainnet: use runStore then runContracts");
        script.run();
    }

    function testMainnetDeploysTheExactLaunchSettings() public {
        DeployKilim.Config memory local = _config();
        local.deployer = ARTIST;
        script.deployStore(local);
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        DeployKilim.Deployed memory d = script.deployContracts(c);
        KilimAuction auction = d.auction;
        assertEq(auction.MOTIF_PRICE(), 0.001 ether);
        assertEq(auction.REGISTRATION_BALANCE(), 0.01 ether);
        assertEq(auction.REGISTRATION_TARGET(), 100);
        assertEq(address(auction).balance, 0);
        assertEq(auction.treasury(), ARTIST);
        assertEq(auction.reservePrice(), 0.01 ether);
        assertEq(auction.incrementBps(), 1000);
        assertEq(auction.duration(), 86_400);
        assertEq(auction.extensionWindow(), 600);
        assertEq(auction.motifCap(), 1_000_000);
        assertEq(auction.maxMotifsPerBid(), 1_000_000);
        assertEq(d.motifs.royaltyReceiver(), ARTIST);
        assertEq(d.oneOfOne.royaltyReceiver(), ARTIST);
        assertEq(d.motifs.minter(), address(auction));
        assertEq(d.oneOfOne.minter(), address(auction));
        assertEq(d.oneOfOne.name(), script.LAUNCH_ONE_OF_ONE_NAME());
        assertEq(d.oneOfOne.name(), "The Unwoven Kilim");
    }

    function testMainnetRefusesEverySettingOtherThanTheLaunchValues() public {
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        c.deployer = DEPLOYER;
        _expectRefused("mainnet launch value: deployer");
        script.deployContracts(c);

        // The artwork's inner title is not the token's name.
        c = _mainnetConfig();
        c.oneOfOneName = "What the weave remembers";
        _expectRefused("mainnet launch value: oneOfOne.name");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.treasury = TREASURY;
        _expectRefused("mainnet launch value: treasury");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.reservePrice = 20 * UNIT; // a whole number of units, but not the reserve
        _expectRefused("mainnet launch value: reservePrice");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.incrementBps = 100;
        _expectRefused("mainnet launch value: incrementBps");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.duration = 8640;
        _expectRefused("mainnet launch value: duration");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.extensionWindow = 60;
        _expectRefused("mainnet launch value: extensionWindow");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.motifCap = 10_000;
        _expectRefused("mainnet launch value: motifCap");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.auction.maxMotifsPerBid = 250;
        _expectRefused("mainnet launch value: maxMotifsPerBid");
        script.deployContracts(c);
    }

    function testMainnetRequiresThePublishedNonceAndAnInspectionWindow() public {
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        c.deployerNonce = script.NO_NONCE_CHECK();
        _expectRefused("mainnet needs the published deployerNonce");
        script.deployContracts(c);

        c = _mainnetConfig();
        c.minLeadSeconds = 0;
        c.auction.startsAt = uint64(block.timestamp + 2 minutes);
        _expectRefused("mainnet needs a nonzero minLeadSeconds");
        script.deployContracts(c);
    }

    /// @dev The Sepolia rehearsal and the local chain stay configurable: none of the above is refused there.
    function testOtherChainsAcceptSettingsThatDifferFromTheLaunch() public {
        script.deployStore(_config());
        vmd.chainId(11_155_111);
        DeployKilim.Config memory c = _config();
        c.chainId = 11_155_111;
        c.deployerNonce = script.NO_NONCE_CHECK();
        c.minLeadSeconds = 0;
        c.auction.startsAt = uint64(block.timestamp + 2 minutes);
        c.auction.treasury = TREASURY;
        c.auction.duration = 1 hours;
        c.auction.extensionWindow = 1 minutes;
        c.auction.incrementBps = 500;
        c.motifCap = 10_000;
        c.auction.maxMotifsPerBid = 250;
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(d.auction.treasury(), TREASURY);
        assertEq(d.auction.duration(), 1 hours);
        assertEq(d.auction.extensionWindow(), 1 minutes);
        assertEq(d.auction.incrementBps(), 500);
        assertEq(d.auction.motifCap(), 10_000);
        assertEq(d.motifs.motifCap(), 10_000);
        assertEq(d.auction.maxMotifsPerBid(), 250);
        assertEq(d.auction.reservePrice(), RESERVE);
    }

    /// @dev The 1/1's name is pinned on chain 1 only, before the store is read. Elsewhere another name
    ///      passes the launch check and meets only the rule every chain applies: the name must be the one
    ///      the page was packed with, because the golden tokenURI hash was computed with it. So the same
    ///      config is refused for the launch value on chain 1 and for the packed page on Sepolia.
    function testOnlyMainnetPinsTheOneOfOneName() public {
        script.deployStore(_config());
        DeployKilim.Config memory c = _config();
        c.oneOfOneName = "Another name";
        vmd.chainId(11_155_111);
        c.chainId = 11_155_111;
        _expectRefused("1/1 name, description or externalUrl differs from the packed page");
        script.deployContracts(c);

        vmd.chainId(1);
        c = _mainnetConfig();
        c.oneOfOneName = "Another name";
        _expectRefused("mainnet launch value: oneOfOne.name");
        script.deployContracts(c);
        // The packed page carries the launch name, so the launch config deploys on chain 1.
        c = _mainnetConfig();
        assertEq(c.oneOfOneName, script.LAUNCH_ONE_OF_ONE_NAME());
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(d.oneOfOne.name(), script.LAUNCH_ONE_OF_ONE_NAME());
    }

    /// @dev The reserve is the one setting no chain may change: the constructor accepts only 0.01 ETH.
    function testEveryChainRefusesAnotherReserve() public {
        script.deployStore(_config());
        DeployKilim.Config memory c = _config();
        c.auction.reservePrice = 20 * UNIT;
        _expectRefused("reserve price");
        script.deployContracts(c);

        vmd.chainId(11_155_111);
        c.chainId = 11_155_111;
        _expectRefused("reserve price");
        script.deployContracts(c);
    }

    /// @dev The auction the script deploys is the ETH auction: it holds nothing at first, refuses ETH
    ///      sent with no call, takes a bid paid in full and refunds it when it is outbid.
    function testTheDeployedAuctionTakesEthBids() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c);
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        DeployKilim.Deployed memory d = script.deployContracts(c);
        KilimAuction auction = d.auction;
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
        assertEq(auction.motifCredits(ALICE), 10);

        // 10% over 0.01 ETH is 0.011 ETH; ALICE gets her bid back inside BOB's transaction
        assertEq(auction.minimumBid(), 11 * UNIT);
        _bid(auction, BOB, 11 * UNIT);
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, 1 ether - 11 * UNIT);
        assertEq(address(auction).balance, 11 * UNIT);
        assertEq(address(auction).balance, auction.liabilities());

        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(d.oneOfOne.ownerOf(1), BOB);
        assertEq(address(auction).balance, auction.liabilities());
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, 11 * UNIT);
        assertEq(address(auction).balance, 0);
        assertEq(auction.liabilities(), 0);
        // The motifs the real store holds come back through the collection.
        vm.prank(ALICE);
        auction.claimMotifs(10, ALICE);
        assertEq(d.motifs.ownerOf(1), ALICE);
        assertTrue(bytes(d.motifs.tokenURI(1)).length != 0);
    }

    /// @dev The committed templates carry the launch values the script pins, and stay unreadable until
    ///      every TODO is filled in.
    function testTemplatesCarryTheLaunchValuesAndFailClosed() public {
        _checkTemplate("deploy/mainnet.example.json", 1);
        _checkTemplate("deploy/sepolia.example.json", 11_155_111);
        string memory j = vmd.readFile("deploy/mainnet.example.json");
        assertEq(vmd.parseJsonAddress(j, ".deployer"), script.LAUNCH_DEPLOYER());
    }

    /// @dev The local dry-run config has no TODO left: it loads, and carries the same launch values.
    function testTheLocalConfigLoadsWithTheLaunchValues() public view {
        DeployKilim.Config memory c = script.loadConfig("deploy/local.json");
        assertEq(c.chainId, 31_337);
        assertEq(c.auction.treasury, script.LAUNCH_TREASURY());
        assertEq(c.auction.reservePrice, script.LAUNCH_RESERVE_PRICE());
        assertEq(c.auction.incrementBps, script.LAUNCH_INCREMENT_BPS());
        assertEq(c.auction.duration, script.LAUNCH_DURATION());
        assertEq(c.auction.extensionWindow, script.LAUNCH_EXTENSION_WINDOW());
        assertEq(c.motifCap, script.LAUNCH_MOTIF_CAP());
        assertEq(c.auction.maxMotifsPerBid, script.LAUNCH_MAX_MOTIFS_PER_BID());
        assertEq(c.oneOfOneName, script.LAUNCH_ONE_OF_ONE_NAME());
        assertTrue(bytes(c.motifStore).length != 0 && bytes(c.pageStore).length != 0);
    }

    /// @dev What `pnpm deploy:dry` runs: run() with the local config on forge's in-memory chain, whose
    ///      clock starts at 1. Both phases go through, from the config's deployer, and the three
    ///      contracts land at its next three nonces.
    function testRunDeploysBothPhasesFromTheLocalConfig() public {
        DeployKilim.Config memory c = script.loadConfig("deploy/local.json");
        vmd.warp(1);
        vmd.setEnv("KILIM_DEPLOY_CONFIG", "deploy/local.json");
        uint256 nonce = vmd.getNonce(c.deployer);
        script.run();
        // 38 chunks, then the three contracts.
        DeployKilim.Store memory s = script.loadStore(c);
        uint256 chunks = s.grids.chunks.length + s.names.chunks.length + s.prefix.chunks.length
            + s.head.chunks.length + s.tail.chunks.length;
        assertEq(vmd.getNonce(c.deployer), nonce + chunks + 3);
        KilimAuction auction = KilimAuction(vmd.computeCreateAddress(c.deployer, nonce + chunks + 2));
        assertEq(address(auction.motifs()), vmd.computeCreateAddress(c.deployer, nonce + chunks));
        assertEq(address(auction.oneOfOne()), vmd.computeCreateAddress(c.deployer, nonce + chunks + 1));
        assertEq(auction.motifs().minter(), address(auction));
        assertEq(auction.oneOfOne().minter(), address(auction));
        assertEq(auction.startsAt(), c.auction.startsAt);
        assertEq(auction.treasury(), script.LAUNCH_TREASURY());
        assertTrue(!auction.oneOfOne().minted());
    }

    function _checkTemplate(string memory path, uint256 chain) internal {
        string memory j = vmd.readFile(path);
        assertEq(vmd.parseJsonUint(j, ".chainId"), chain);
        assertEq(vmd.parseJsonAddress(j, ".auction.treasury"), script.LAUNCH_TREASURY());
        assertEq(vmd.parseJsonUint(j, ".auction.reservePrice"), script.LAUNCH_RESERVE_PRICE());
        assertEq(vmd.parseJsonUint(j, ".auction.incrementBps"), script.LAUNCH_INCREMENT_BPS());
        assertEq(vmd.parseJsonUint(j, ".auction.duration"), script.LAUNCH_DURATION());
        assertEq(vmd.parseJsonUint(j, ".auction.extensionWindow"), script.LAUNCH_EXTENSION_WINDOW());
        assertEq(vmd.parseJsonUint(j, ".collection.motifCap"), script.LAUNCH_MOTIF_CAP());
        assertEq(vmd.parseJsonUint(j, ".auction.maxMotifsPerBid"), script.LAUNCH_MAX_MOTIFS_PER_BID());
        assertEq(vmd.parseJsonString(j, ".oneOfOne.name"), script.LAUNCH_ONE_OF_ONE_NAME());
        vm.expectRevert();
        script.loadConfig(path);
    }
}
