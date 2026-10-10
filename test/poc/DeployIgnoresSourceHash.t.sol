// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {TestBase} from "../TestBase.sol";

interface VmPocSource {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function keyExistsJson(string calldata, string calldata) external pure returns (bool);
    function getNonce(address) external view returns (uint64);
    function prank(address) external;
}

/// @notice Review PoC (packers finding, skeptic): both packers record the file they packed from
///         (`source.sha256` in the motif manifest, `artwork.sha256` / `still.sha256` in the page
///         manifest), and that record is the only link from the artist's file to the store. The deploy
///         script never reads it: a store whose manifests carry no such record at all goes through both
///         phases, every refusal, the read-back and both goldens, and answers the same tokenURIs.
///
///         Run contracts/test/poc/stale-source-store.py first; it writes the two copies this reads.
contract DeployIgnoresSourceHashTest is TestBase {
    VmPocSource internal constant vmp = VmPocSource(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    string internal constant REAL_MOTIFS = "../onchain/build-motifs";
    string internal constant REAL_PAGE = "../onchain/build-page";
    string internal constant POC_MOTIFS = "../onchain/test/fixtures/poc-stale-source/motifs";
    string internal constant POC_PAGE = "../onchain/test/fixtures/poc-stale-source/page";

    DeployKilim internal script;

    function setUp() public {
        script = new DeployKilim();
        vm.warp(1_800_000_000);
    }

    function _config(string memory motifStore, string memory pageStore)
        internal
        view
        returns (DeployKilim.Config memory c)
    {
        c.chainId = block.chainid;
        c.deployer = DEPLOYER;
        c.deployerNonce = vmp.getNonce(DEPLOYER);
        c.minLeadSeconds = 1 days;
        c.motifStore = motifStore;
        c.pageStore = pageStore;
        c.auction.treasury = TREASURY;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = 24 hours;
        c.auction.extensionWindow = 10 minutes;
        c.auction.incrementBps = 1000;
        c.auction.reservePrice = RESERVE;
        c.auction.maxMotifsPerBid = 1_000_000;
        c.motifCap = 1_000_000;
        string memory g = vmp.readFile(string.concat(motifStore, "/manifest.json"));
        string memory pg = vmp.readFile(string.concat(pageStore, "/manifest.json"));
        c.collectionDescription = vmp.parseJsonString(g, ".description");
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = vmp.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmp.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmp.parseJsonString(pg, ".externalUrl");
    }

    /// @dev The real manifests name their files of origin; the PoC copies do not. Nothing else differs.
    function testThePocManifestsCarryNoFileOfOrigin() public view {
        string memory g = vmp.readFile(string.concat(REAL_MOTIFS, "/manifest.json"));
        string memory pg = vmp.readFile(string.concat(REAL_PAGE, "/manifest.json"));
        assertTrue(vmp.keyExistsJson(g, ".source.sha256"));
        assertTrue(vmp.keyExistsJson(pg, ".artwork.sha256"));
        assertTrue(vmp.keyExistsJson(pg, ".still.sha256"));

        string memory pg2 = vmp.readFile(string.concat(POC_MOTIFS, "/manifest.json"));
        string memory pp2 = vmp.readFile(string.concat(POC_PAGE, "/manifest.json"));
        assertTrue(!vmp.keyExistsJson(pg2, ".source"));
        assertTrue(!vmp.keyExistsJson(pp2, ".artwork"));
        assertTrue(!vmp.keyExistsJson(pp2, ".still"));
        // Same hashes and goldens: the copies are the real store minus the record of where it came from.
        assertEq(vmp.parseJsonBytes32(pg2, ".hashes.gridsHash"), vmp.parseJsonBytes32(g, ".hashes.gridsHash"));
        assertEq(
            vmp.parseJsonBytes32(pg2, ".golden.tokenURI.sha256"),
            vmp.parseJsonBytes32(g, ".golden.tokenURI.sha256")
        );
        assertEq(vmp.parseJsonBytes32(pp2, ".hashes.tailHash"), vmp.parseJsonBytes32(pg, ".hashes.tailHash"));
        assertEq(
            vmp.parseJsonBytes32(pp2, ".golden.tokenURI.sha256"),
            vmp.parseJsonBytes32(pg, ".golden.tokenURI.sha256")
        );
    }

    /// @dev Both phases from the copies without a file of origin: no refusal, the same contracts, the
    ///      same goldens. The script's whole gate is manifest-to-chain; the artist's file never enters it.
    function testBothPhasesDeployAStoreWithNoFileOfOrigin() public {
        DeployKilim.Config memory c = _config(POC_MOTIFS, POC_PAGE);
        DeployKilim.Store memory s = script.deployStore(c);
        c.deployerNonce = vmp.getNonce(DEPLOYER);
        DeployKilim.Deployed memory d = script.deployContracts(c);

        // The same chunks as the real store: identical addresses and hashes.
        DeployKilim.Store memory real = script.loadStore(_config(REAL_MOTIFS, REAL_PAGE));
        assertEq(s.grids.hash, real.grids.hash);
        assertEq(s.names.hash, real.names.hash);
        assertEq(s.tail.hash, real.tail.hash);
        assertEq(d.motifs.gridsHash(), real.grids.hash);
        assertEq(d.oneOfOne.tailHash(), real.tail.hash);

        // And the 1/1 answers the golden the real page manifest records.
        string memory pg = vmp.readFile(string.concat(REAL_PAGE, "/manifest.json"));
        vmp.prank(address(d.auction));
        d.oneOfOne.mint(ALICE);
        assertEq(sha256(bytes(d.oneOfOne.tokenURI(1))), vmp.parseJsonBytes32(pg, ".golden.tokenURI.sha256"));
    }
}
