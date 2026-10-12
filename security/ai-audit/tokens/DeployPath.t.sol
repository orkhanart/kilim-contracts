// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../../script/DeployKilim.s.sol";
import {DeployKilimBazaar} from "../../../script/DeployKilimBazaar.s.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {BazaarBase} from "../../../test/bazaar/BazaarBase.sol";

interface VmDp {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonStringArray(string calldata, string calldata) external pure returns (string[] memory);
    function parseJsonUintArray(string calldata, string calldata) external pure returns (uint256[] memory);
    function getNonce(address) external view returns (uint64);
    function setNonce(address, uint64) external;
    function computeCreateAddress(address, uint256) external pure returns (address);
    function chainId(uint256) external;
    function etch(address, bytes calldata) external;
    function warp(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function toString(address) external pure returns (string memory);
}

/// @dev DeployKilim with the pending-nonce RPC replaced, as test/DeployKilim.t.sol does.
contract DeployKilimNoNode is DeployKilim {
    function _pendingNonce(address who) internal view override returns (uint256) {
        return vm.getNonce(who);
    }
}

/// @notice Token audit of 12 October 2026, deploy lens: deploy/mainnet.json as it stands, both scripts.
contract DeployPathAudit is BazaarBase {
    VmDp internal constant vd = VmDp(address(uint160(uint256(keccak256("hevm cheat code")))));
    string internal constant MAINNET = "deploy/mainnet.json";
    /// The addresses AUDIT.md and checklists/0-launch-steps.md publish for nonce 1,568.
    address internal constant PUBLISHED_MOTIFS = 0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF;
    address internal constant PUBLISHED_ONE_OF_ONE = 0xeD82CE5F5E943ef80F3D32a907281936186742eC;
    address internal constant PUBLISHED_AUCTION = 0xb4817D07a14503dCEf49Bd25B17557e7CBb23423;

    /// @dev Both scripts refuse deploy/mainnet.json while a TODO is text: DeployKilim on auction.startsAt,
    ///      DeployKilimBazaar on bazaar.auction (and KILIM_BAZAAR_AUCTION cannot override it: the key exists).
    function testMainnetConfigFailsClosedOnItsTodos() public {
        DeployKilim dk = new DeployKilim();
        vd.expectRevert();
        dk.loadConfig(MAINNET);
        DeployKilimBazaar db = new DeployKilimBazaar();
        vd.expectRevert();
        db.loadConfig(MAINNET);
    }

    /// @dev Every value of deploy/mainnet.json but the TODO startsAt, through both DeployKilim phases on a
    ///      chain switched to 1, with orkhanart.eth at nonce 1,568 and the REAL stores: nothing is refused, the
    ///      three contracts land at the published addresses, and the Bazaar block's pageTailHash is the 1/1's.
    function testMainnetJsonDeploysAtThePublishedAddresses() public {
        vd.warp(1_800_000_000);
        string memory j = vd.readFile(MAINNET);
        DeployKilim.Config memory c = _mainnetFromJson(j);
        DeployKilimNoNode script = new DeployKilimNoNode();
        vd.chainId(1);
        script.deployStore(c, address(0x5704E)); // any wallet but the deployer
        vd.setNonce(c.deployer, uint64(c.deployerNonce));
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(address(d.motifs), PUBLISHED_MOTIFS);
        assertEq(address(d.oneOfOne), PUBLISHED_ONE_OF_ONE);
        assertEq(address(d.auction), PUBLISHED_AUCTION);
        assertEq(d.oneOfOne.tailHash(), vd.parseJsonBytes32(j, ".bazaar.pageTailHash"));
        assertEq(d.motifs.royaltyReceiver(), vd.parseJsonAddress(j, ".bazaar.royaltyReceiver"));
    }

    /// @dev TK-1. On chain 1 DeployKilimBazaar accepts an auction orkhanart.eth never deployed: any self-consistent
    ///      trio whose 1/1 points at the public page chunks passes every check, with every other value exactly as
    ///      deploy/mainnet.json has it. The same file names the deployer and its nonce, from which the real
    ///      auction's address follows, but the script never compares them.
    function testMainnetBazaarScriptAcceptsAnAuctionTheArtistNeverDeployed() public {
        vd.warp(1_800_000_000);
        // A look-alike trio deployed by someone else (here, this test contract), over the real public page.
        _deployAuction(BIG_CAP, REAL_PAGE);
        string memory j = vd.readFile(MAINNET);
        address realAuction =
            vd.computeCreateAddress(vd.parseJsonAddress(j, ".deployer"), vd.parseJsonUint(j, ".deployerNonce") + 2);
        assertEq(realAuction, PUBLISHED_AUCTION);
        assertTrue(address(auction) != realAuction);

        DeployKilimBazaar.Config memory c;
        c.chainId = 1;
        c.auction = address(auction); // the TODO, filled with the wrong address
        c.royaltyReceiver = vd.parseJsonAddress(j, ".bazaar.royaltyReceiver");
        c.pageTailHash = vd.parseJsonBytes32(j, ".bazaar.pageTailHash");
        c.pageStore = vd.parseJsonString(j, ".pageStore");
        c.description = vd.parseJsonString(j, ".bazaar.description");
        c.externalUrl = vd.parseJsonString(j, ".bazaar.externalUrl");
        c.imageBase = vd.parseJsonString(j, ".bazaar.imageBase");
        c.rankNames = vd.parseJsonStringArray(j, ".bazaar.pageRanks.names");
        c.rankCosts = vd.parseJsonUintArray(j, ".bazaar.pageRanks.costs");

        vd.chainId(1);
        vd.etch(HISTORY, HISTORY_CODE);
        DeployKilimBazaar script = new DeployKilimBazaar();
        KilimBazaar b = script.deploy(c, ARTIST); // from orkhanart.eth, every mainnet check passes
        assertEq(address(b.auction()), address(auction));
        assertTrue(address(b.auction()) != PUBLISHED_AUCTION);
        assertEq(b.royaltyReceiver(), ARTIST);
        assertEq(b.seedWindow(), 8191);
    }

    function _mainnetFromJson(string memory j) internal view returns (DeployKilim.Config memory c) {
        c.chainId = vd.parseJsonUint(j, ".chainId");
        c.deployer = vd.parseJsonAddress(j, ".deployer");
        c.deployerNonce = vd.parseJsonUint(j, ".deployerNonce");
        c.minLeadSeconds = vd.parseJsonUint(j, ".minLeadSeconds");
        c.motifStore = vd.parseJsonString(j, ".motifStore");
        c.pageStore = vd.parseJsonString(j, ".pageStore");
        c.auction.treasury = vd.parseJsonAddress(j, ".auction.treasury");
        c.auction.startsAt = uint64(block.timestamp + 2 days); // the one TODO
        c.auction.duration = uint64(vd.parseJsonUint(j, ".auction.duration"));
        c.auction.extensionWindow = uint64(vd.parseJsonUint(j, ".auction.extensionWindow"));
        c.auction.incrementBps = uint16(vd.parseJsonUint(j, ".auction.incrementBps"));
        c.auction.reservePrice = vd.parseJsonUint(j, ".auction.reservePrice");
        c.auction.maxMotifsPerBid = vd.parseJsonUint(j, ".auction.maxMotifsPerBid");
        c.motifCap = vd.parseJsonUint(j, ".collection.motifCap");
        c.collectionDescription = vd.parseJsonString(j, ".collection.description");
        c.collectionExternalUrl = vd.parseJsonString(j, ".collection.externalUrl");
        c.oneOfOneName = vd.parseJsonString(j, ".oneOfOne.name");
        c.oneOfOneDescription = vd.parseJsonString(j, ".oneOfOne.description");
        c.oneOfOneExternalUrl = vd.parseJsonString(j, ".oneOfOne.externalUrl");
        c.hasExpected = true;
        c.expected.gridsHash = vd.parseJsonBytes32(j, ".expected.gridsHash");
        c.expected.namesHash = vd.parseJsonBytes32(j, ".expected.namesHash");
        c.expected.prefixHash = vd.parseJsonBytes32(j, ".expected.prefixHash");
        c.expected.headHash = vd.parseJsonBytes32(j, ".expected.headHash");
        c.expected.tailHash = vd.parseJsonBytes32(j, ".expected.tailHash");
        c.expected.motifGolden = vd.parseJsonBytes32(j, ".expected.motifGolden");
        c.expected.oneOfOneGolden = vd.parseJsonBytes32(j, ".expected.oneOfOneGolden");
        c.expected.motifSource = vd.parseJsonBytes32(j, ".expected.motifSource");
        c.expected.artwork = vd.parseJsonBytes32(j, ".expected.artwork");
        c.expected.still = vd.parseJsonBytes32(j, ".expected.still");
        c.expected.loader = vd.parseJsonBytes32(j, ".expected.loader");
    }
}
