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

/// @dev The script with the one call that needs a live node replaced: the deployer's pending nonce is
///      the latest one plus whatever the test says is waiting in the pool.
contract DeployKilimHarness is DeployKilim {
    uint256 public pendingAhead;

    function setPendingAhead(uint256 count) external {
        pendingAhead = count;
    }

    function _pendingNonce(address who) internal view override returns (uint256) {
        return vm.getNonce(who) + pendingAhead;
    }
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

    /// The wallet that sends the store: forge's --sender. Never the deployer once its nonce is published.
    address internal constant SENDER = address(0x5E4D);
    /// Small committed page stores (onchain/test/pack_fixtures.py): one whose artwork reads KILIM_GRIDS,
    /// as mainnet requires, one whose artwork does not, and one edited by hand to carry '#' and '%'.
    string internal constant PAGE_FIXTURE = "../onchain/test/fixtures/page-store";
    string internal constant PAGE_NO_GRIDS = "../onchain/test/fixtures/page-store-no-grids";
    string internal constant PAGE_HASH_IN_PREFIX = "../onchain/test/fixtures/page-store-hash-in-prefix";

    DeployKilimHarness internal script;

    function setUp() public {
        script = new DeployKilimHarness();
        vm.warp(1_800_000_000);
    }

    function _config() internal view returns (DeployKilim.Config memory c) {
        return _config(PAGE_STORE);
    }

    function _config(string memory pageStore) internal view returns (DeployKilim.Config memory c) {
        c.chainId = block.chainid;
        c.deployer = DEPLOYER;
        c.deployerNonce = vmd.getNonce(DEPLOYER);
        c.minLeadSeconds = 1 days;
        c.motifStore = MOTIF_STORE;
        c.pageStore = pageStore;
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
        string memory pg = vmd.readFile(string.concat(pageStore, "/manifest.json"));
        c.collectionDescription = vmd.parseJsonString(g, ".description");
        c.collectionExternalUrl = vmd.parseJsonString(g, ".externalUrl");
        c.oneOfOneName = vmd.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmd.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmd.parseJsonString(pg, ".externalUrl");
    }

    function _motifManifest() internal view returns (string memory) {
        return vmd.readFile(string.concat(MOTIF_STORE, "/manifest.json"));
    }

    /// @dev The `expected` block a signed-off config carries, read from the two manifests.
    function _withExpected(DeployKilim.Config memory c) internal view returns (DeployKilim.Config memory) {
        string memory g = _motifManifest();
        string memory pg = vmd.readFile(string.concat(c.pageStore, "/manifest.json"));
        c.hasExpected = true;
        c.expected.gridsHash = vmd.parseJsonBytes32(g, ".hashes.gridsHash");
        c.expected.namesHash = vmd.parseJsonBytes32(g, ".hashes.namesHash");
        c.expected.prefixHash = vmd.parseJsonBytes32(pg, ".hashes.prefixHash");
        c.expected.headHash = vmd.parseJsonBytes32(pg, ".hashes.headHash");
        c.expected.tailHash = vmd.parseJsonBytes32(pg, ".hashes.tailHash");
        c.expected.motifGolden = vmd.parseJsonBytes32(g, ".golden.tokenURI.sha256");
        c.expected.oneOfOneGolden = vmd.parseJsonBytes32(pg, ".golden.tokenURI.sha256");
        c.expected.motifSource = vmd.parseJsonBytes32(g, ".source.sha256");
        c.expected.artwork = vmd.parseJsonBytes32(pg, ".artwork.sha256");
        c.expected.still = vmd.parseJsonBytes32(pg, ".still.sha256");
        c.expected.loader = vmd.parseJsonBytes32(pg, ".loaderTemplate.sha256");
        return c;
    }

    function testDeploysChunksAndContractsInOrder() public {
        DeployKilim.Config memory c = _config();
        DeployKilim.Store memory s = script.deployStore(c, SENDER);
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
        uint256 before = vmd.getNonce(SENDER);
        script.deployStore(c, SENDER);
        uint256 nonce = vmd.getNonce(SENDER);
        assertTrue(nonce > before);
        script.deployStore(c, SENDER);
        assertEq(vmd.getNonce(SENDER), nonce); // nothing was sent the second time
    }

    /// @dev Review round: the store goes out from forge's --sender and leaves the deployer's nonce alone.
    ///      The deployer itself may send it only while no nonce is published for it; after that every
    ///      chunk would move the nonce the three contracts are promised at.
    function testTheStoreNeverSpendsAPublishedDeployerNonce() public {
        DeployKilim.Config memory c = _config();
        uint256 published = vmd.getNonce(DEPLOYER);
        _expectRefused("the store would spend the published deployer nonce: send it from another wallet");
        script.deployStore(c, DEPLOYER);
        script.deployStore(c, SENDER);
        assertEq(vmd.getNonce(DEPLOYER), published);
        // With every chunk on the chain nothing is sent, so the deployer may run the phase again.
        script.deployStore(c, DEPLOYER);
        assertEq(vmd.getNonce(DEPLOYER), published);
        script.deployContracts(c);
    }

    function testTheDeployerMaySendTheStoreBeforeItsNonceIsPublished() public {
        DeployKilim.Config memory c = _config();
        c.deployerNonce = script.NO_NONCE_CHECK();
        uint256 before = vmd.getNonce(DEPLOYER);
        script.deployStore(c, DEPLOYER);
        assertTrue(vmd.getNonce(DEPLOYER) > before);
    }

    function testRefusesTheWrongChain() public {
        DeployKilim.Config memory c = _config();
        c.chainId = 1;
        _expectRefused("wrong chain");
        script.deployStore(c, SENDER);
        _expectRefused("wrong chain");
        script.deployContracts(c);
    }

    function testRefusesForeignCodeAtAChunkAddress() public {
        DeployKilim.Config memory c = _config();
        string memory manifest = _motifManifest();
        vmd.etch(vmd.parseJsonAddress(manifest, ".grids.chunks[1].address"), hex"00deadbeef");
        _expectRefused("grids: foreign code at a chunk address");
        script.deployStore(c, SENDER);
    }

    function testContractsPhaseRefusals() public {
        DeployKilim.Config memory c = _config();
        // the store must be deployed first
        _expectRefused("store not deployed: runStore first");
        script.deployContracts(c);
        script.deployStore(c, SENDER);
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
        // the collection's link is in no golden: it must be the one recorded when the motifs were packed
        string memory link = c.collectionExternalUrl;
        c.collectionExternalUrl = "https://kilim.art.example";
        _expectRefused("collection externalUrl differs from the packed motifs");
        script.deployContracts(c);
        c.collectionExternalUrl = link;
        // a transaction from the deployer still in the pool: the latest nonce is right, the pending one is not
        script.setPendingAhead(1);
        _expectRefused("a transaction from the deployer is pending");
        script.deployContracts(c);
        script.setPendingAhead(0);
        // and with everything right, it deploys
        script.deployContracts(c);
    }

    /// @dev Review round: a page store edited after packing, with '#' and '%' in the token's texts and
    ///      every hash and golden recomputed to match. Raw in the data: URL they would cut the JSON off.
    function testRefusesAPrefixThatADataUrlWouldCut() public {
        DeployKilim.Config memory c = _config(PAGE_HASH_IN_PREFIX);
        assertEq(c.oneOfOneName, "Kilim #1");
        _expectRefused("prefix: '#' or '%' in the token JSON");
        script.deployStore(c, SENDER);
        _expectRefused("prefix: '#' or '%' in the token JSON");
        script.deployContracts(c);
    }

    /// @dev Review round: off mainnet the `expected` block is optional, but when a config carries it the
    ///      store must be that content, hash by hash, in both phases.
    function testAConfigThatNamesItsContentIsHeldToIt() public {
        DeployKilim.Config memory c = _withExpected(_config(PAGE_FIXTURE));
        script.deployStore(c, SENDER);
        script.deployContracts(c);

        for (uint256 field; field < 11; ++field) {
            c = _withExpected(_config(PAGE_FIXTURE));
            string memory name = _spoil(c, field, bytes32(uint256(1)));
            _expectRefused(string.concat("expected ", name));
            script.deployStore(c, SENDER);
            _expectRefused(string.concat("expected ", name));
            script.deployContracts(c);
            // a zero is a value nobody filled in
            c = _withExpected(_config(PAGE_FIXTURE));
            _spoil(c, field, bytes32(0));
            _expectRefused(string.concat("expected ", name));
            script.deployStore(c, SENDER);
        }
    }

    /// @dev Replaces one of the eleven expected values and returns its name.
    function _spoil(DeployKilim.Config memory c, uint256 field, bytes32 value)
        internal
        pure
        returns (string memory)
    {
        DeployKilim.Expected memory e = c.expected;
        if (field == 0) (e.gridsHash = value);
        else if (field == 1) e.namesHash = value;
        else if (field == 2) e.prefixHash = value;
        else if (field == 3) e.headHash = value;
        else if (field == 4) e.tailHash = value;
        else if (field == 5) e.motifGolden = value;
        else if (field == 6) e.oneOfOneGolden = value;
        else if (field == 7) e.motifSource = value;
        else if (field == 8) e.artwork = value;
        else if (field == 9) e.still = value;
        else e.loader = value;
        string[11] memory names = [
            "gridsHash",
            "namesHash",
            "prefixHash",
            "headHash",
            "tailHash",
            "motifGolden",
            "oneOfOneGolden",
            "motifSource",
            "artwork",
            "still",
            "loader"
        ];
        return names[field];
    }

    // ------------------------------------------------------------ completing a deployment

    /// @dev The first two creations of a deployment, as the script sends them, with the third one lost.
    function _deployTwoTokens(DeployKilim.Config memory c) internal returns (KilimMotifs k, KilimOneOfOne o) {
        return _deployTwoTokens(c, vmd.computeCreateAddress(c.deployer, vmd.getNonce(c.deployer) + 2));
    }

    function _deployTwoTokens(DeployKilim.Config memory c, address minter)
        internal
        returns (KilimMotifs k, KilimOneOfOne o)
    {
        DeployKilim.Store memory s = script.loadStore(c);
        vm.startPrank(c.deployer);
        k = new KilimMotifs(
            minter,
            c.auction.treasury,
            c.motifCap,
            s.grids.addresses,
            s.grids.hash,
            s.names.addresses[0],
            s.names.hash,
            c.collectionDescription,
            c.collectionExternalUrl
        );
        o = new KilimOneOfOne(
            minter,
            c.auction.treasury,
            k,
            KilimOneOfOne.Page({
                prefixChunks: s.prefix.addresses,
                prefixHash: s.prefix.hash,
                headChunks: s.head.addresses,
                headHash: s.head.hash,
                tailChunks: s.tail.addresses,
                tailHash: s.tail.hash
            }),
            c.oneOfOneName,
            c.oneOfOneDescription,
            c.oneOfOneExternalUrl
        );
        vm.stopPrank();
    }

    /// @dev Review round: when only the third creation is lost, the two token contracts already name the
    ///      address at nonce n + 2 as their minter. Deploying the auction there, after every check, keeps
    ///      the published addresses and the motif layout.
    function testCompletesADeploymentWhoseThirdCreationWasLost() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c, SENDER);
        uint256 n = vmd.getNonce(DEPLOYER);
        c.deployerNonce = n;
        // Nothing to complete yet: the deployer is still at the published nonce.
        _expectRefused("deployer nonce is not the published one plus two");
        script.deployAuction(c);

        (KilimMotifs k, KilimOneOfOne o) = _deployTwoTokens(c);
        assertEq(vmd.getNonce(DEPLOYER), n + 2);
        // The whole deployment is refused now, and so is completing with a transaction pending.
        _expectRefused("deployer nonce");
        script.deployContracts(c);
        script.setPendingAhead(1);
        _expectRefused("a transaction from the deployer is pending");
        script.deployAuction(c);
        script.setPendingAhead(0);
        c.deployerNonce = script.NO_NONCE_CHECK();
        _expectRefused("completing needs the published deployerNonce");
        script.deployAuction(c);
        c.deployerNonce = n;

        DeployKilim.Deployed memory d = script.deployAuction(c);
        assertEq(address(d.motifs), address(k));
        assertEq(address(d.oneOfOne), address(o));
        assertEq(address(d.auction), vmd.computeCreateAddress(DEPLOYER, n + 2));
        assertEq(k.minter(), address(d.auction));
        assertEq(o.minter(), address(d.auction));
        assertEq(address(d.auction.motifs()), address(k));
        assertEq(address(d.auction.oneOfOne()), address(o));
        assertEq(vmd.getNonce(DEPLOYER), n + 3);
        assertTrue(!o.minted());
        assertEq(k.motifsMinted(), 0);
        // Once done it cannot be done again.
        _expectRefused("deployer nonce is not the published one plus two");
        script.deployAuction(c);
    }

    function testCompletingRefusesTokensThatAreNotTheOnesThisConfigDeploys() public {
        DeployKilim.Config memory c = _config();
        script.deployStore(c, SENDER);
        uint256 n = vmd.getNonce(DEPLOYER);
        c.deployerNonce = n;
        // Two unrelated transactions took the nonces: no token contract is at the published addresses.
        uint256 snap = vm.snapshotState();
        vmd.setNonce(DEPLOYER, uint64(n + 2));
        _expectRefused("the two token contracts are not at the published addresses");
        script.deployAuction(c);
        vm.revertToState(snap);

        // Tokens built for another minter, or with another setting, are not completed either.
        snap = vm.snapshotState();
        _deployTwoTokens(c, address(0xBAD));
        _expectRefused("motifs read-back");
        script.deployAuction(c);
        vm.revertToState(snap);

        _deployTwoTokens(c);
        c.motifCap = 10_000;
        _expectRefused("motifs read-back");
        script.deployAuction(c);
        c.motifCap = 1_000_000;
        c.auction.startsAt = uint64(block.timestamp + 1 hours);
        _expectRefused("startsAt outside the inspection window");
        script.deployAuction(c);
    }

    function _expectRefused(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployKilim.Refused.selector, reason));
    }

    // ------------------------------------------------------------ Ethereum mainnet

    /// @dev Exactly the decided launch settings on chain 1, with the fixture page whose artwork reads
    ///      KILIM_GRIDS and the `expected` block read from the manifests.
    function _mainnetConfig() internal view returns (DeployKilim.Config memory c) {
        return _mainnetConfig(PAGE_FIXTURE);
    }

    function _mainnetConfig(string memory pageStore) internal view returns (DeployKilim.Config memory c) {
        c = _withExpected(_config(pageStore));
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
        script.deployStore(_config(PAGE_FIXTURE), SENDER);
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        // The store phase passes the same content checks on chain 1; everything is there, nothing is sent.
        script.deployStore(c, SENDER);
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

    /// @dev Review round: mainnet deploys only content its config names by hash. Without the block, with
    ///      one hash wrong, or with one left at zero, both phases refuse before anything is sent.
    function testMainnetRefusesContentItsConfigDoesNotName() public {
        script.deployStore(_config(PAGE_FIXTURE), SENDER);
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        c.hasExpected = false;
        _expectRefused("mainnet needs the expected hashes");
        script.deployStore(c, SENDER);
        _expectRefused("mainnet needs the expected hashes");
        script.deployContracts(c);
        for (uint256 field; field < 11; ++field) {
            c = _mainnetConfig();
            string memory name = _spoil(c, field, keccak256("another pack"));
            _expectRefused(string.concat("expected ", name));
            script.deployStore(c, SENDER);
            _expectRefused(string.concat("expected ", name));
            script.deployContracts(c);
        }
        // The real page store is other content than this config names.
        c = _mainnetConfig();
        c.pageStore = PAGE_STORE;
        vm.expectPartialRevert(DeployKilim.Refused.selector);
        script.deployContracts(c);
    }

    /// @dev Review round: the 1/1 is handed the motif grids when it is read, and the claim that it draws
    ///      the motifs the motif tokens show holds only if its page reads them. A page that never names
    ///      KILIM_GRIDS is a stand-in: fine for a rehearsal, refused on mainnet even when the config
    ///      names it hash for hash.
    function testMainnetRefusesAnArtworkThatIgnoresTheGrids() public {
        DeployKilim.Config memory c = _withExpected(_config(PAGE_NO_GRIDS));
        script.deployStore(c, SENDER);
        uint256 snap = vm.snapshotState();
        script.deployContracts(c);
        vm.revertToState(snap);
        vmd.chainId(1);
        c = _mainnetConfig(PAGE_NO_GRIDS);
        _expectRefused("mainnet: the artwork does not read KILIM_GRIDS");
        script.deployStore(c, SENDER);
        _expectRefused("mainnet: the artwork does not read KILIM_GRIDS");
        script.deployContracts(c);
    }

    function testMainnetRefusesAPendingTransactionAndCompletesALostThird() public {
        script.deployStore(_config(PAGE_FIXTURE), SENDER);
        vmd.chainId(1);
        DeployKilim.Config memory c = _mainnetConfig();
        script.setPendingAhead(1);
        _expectRefused("a transaction from the deployer is pending");
        script.deployContracts(c);
        script.setPendingAhead(0);
        _deployTwoTokens(c);
        DeployKilim.Deployed memory d = script.deployAuction(c);
        assertEq(d.motifs.minter(), address(d.auction));
        assertEq(d.auction.treasury(), ARTIST);
        assertEq(d.motifs.deploymentChainId(), 1);
    }

    /// @dev The Sepolia rehearsal and the local chain stay configurable: none of the above is refused there.
    function testOtherChainsAcceptSettingsThatDifferFromTheLaunch() public {
        script.deployStore(_config(), SENDER);
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
        script.deployStore(_config(), SENDER);
        script.deployStore(_config(PAGE_FIXTURE), SENDER);
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
        script.deployStore(_config(), SENDER);
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
        script.deployStore(c, SENDER);
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
        // The chunks go out from whoever runs the script (here this test); the deployer sends only the
        // three contracts.
        DeployKilim.Store memory s = script.loadStore(c);
        assertTrue(s.tail.addresses[0].code.length != 0);
        assertEq(vmd.getNonce(c.deployer), nonce + 3);
        KilimAuction auction = KilimAuction(vmd.computeCreateAddress(c.deployer, nonce + 2));
        assertEq(address(auction.motifs()), vmd.computeCreateAddress(c.deployer, nonce));
        assertEq(address(auction.oneOfOne()), vmd.computeCreateAddress(c.deployer, nonce + 1));
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
        // The content block is there with every key, each still zero: refused until it is filled in.
        string[11] memory keys = [
            "gridsHash",
            "namesHash",
            "prefixHash",
            "headHash",
            "tailHash",
            "motifGolden",
            "oneOfOneGolden",
            "motifSource",
            "artwork",
            "still",
            "loader"
        ];
        for (uint256 i; i < keys.length; ++i) {
            assertEq(vmd.parseJsonBytes32(j, string.concat(".expected.", keys[i])), bytes32(0));
        }
        vm.expectRevert();
        script.loadConfig(path);
    }
}
