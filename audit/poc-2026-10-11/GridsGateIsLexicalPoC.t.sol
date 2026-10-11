// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {TestBase} from "../TestBase.sol";

interface VmFiles {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
}

/// @dev The script with the one node call replaced: nothing is pending in a test.
contract GateHarness is DeployKilim {
    function _pendingNonce(address who) internal view override returns (uint256) {
        return vm.getNonce(who);
    }
}

/// @title Review PoC (10 October 2026, V-03 angle): the mainnet KILIM_GRIDS gate is a byte-substring test
///        on an unhashed manifest boolean; nothing proves the page uses the grids.
/// @dev The chain-1 refusal `mainnet: the artwork does not read KILIM_GRIDS` (script/DeployKilim.s.sol
///      lines 322-326) reads `.artwork.readsGrids` from the page manifest. The packer sets that flag as
///      `GRIDS_GLOBAL in artwork` (onchain/pack_page.py:179, GRIDS_GLOBAL = b'KILIM_GRIDS'): a byte search,
///      satisfied by a comment, a dead branch, a string literal or a `typeof` guard. No hash in `expected`
///      covers the flag, and no test opens the page to check that the drawing came from the grids.
///
///      Scenario (the art session half-fixing blocker #2 before the freeze): an artwork that names
///      KILIM_GRIDS but whose pixels take nothing from it (here `const G = window.KILIM_GRIDS || DATA`
///      with the drawing still read from DATA; in the committed fixture a `typeof KILIM_GRIDS` guard with a
///      literal drawing). pack_page.py writes readsGrids: true, `pnpm -s expected` pins that store, and
///      runStore / runContracts on chain 1 pass with every hash matching. The 1/1 is deployed forever with
///      README.md:20 "provably draws the same motifs the motif tokens show" false.
///
///      The committed fixture onchain/test/fixtures/page-store IS such a page: synthetic-artwork.html
///      names KILIM_GRIDS in a comment and in one `typeof` guard, and draws sixteen literal rectangles,
///      the same statement its "no-grids" twin draws. The test asserts the desired property: the twin
///      that only names the global is refused on chain 1 like the one that never names it. It fails
///      because the gate accepts it.
contract GridsGateIsLexicalPoC is TestBase {
    VmFiles internal constant vmf = VmFiles(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    /// orkhanart.eth: deployer, treasury and royalty receiver on mainnet.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    /// The wallet that sends the store: forge's --sender.
    address internal constant SENDER = address(0x5E4D);
    string internal constant MOTIF_STORE = "../onchain/build-motifs";
    string internal constant FIXTURES = "../onchain/test/fixtures";
    string internal constant PAGE_NAMES_GRIDS = "../onchain/test/fixtures/page-store";
    string internal constant PAGE_NO_GRIDS = "../onchain/test/fixtures/page-store-no-grids";
    /// The two places synthetic-artwork.html names KILIM_GRIDS: a comment, and a type-and-shape guard.
    bytes internal constant COMMENT = "reading its motifs from KILIM_GRIDS.";
    bytes internal constant GUARD =
        "var ok = typeof KILIM_GRIDS === 'string' && /^[0-9a-f]{65536}$/.test(KILIM_GRIDS);";
    /// The one drawing statement of both synthetic artworks: literal coordinates, nothing from the grids.
    bytes internal constant DRAW = "for (var i = 0; i < 16; i++) ctx.fillRect(i * 4, 0, 2, 2);";

    GateHarness internal script;

    function setUp() public {
        script = new GateHarness();
        vm.warp(1_800_000_000);
    }

    // ------------------------------------------------------------ the gate

    /// @dev Desired property: on chain 1, with the launch settings and every `expected` hash matching, a
    ///      page whose drawing takes nothing from KILIM_GRIDS is refused, whether or not its source happens
    ///      to spell the name. The deaf twin is refused; the twin that only names the global passes.
    function testMainnetRefusesAnArtworkThatOnlyNamesTheGrids() public {
        _assertTheTwoArtworksDrawTheSameAndDifferOnlyInTheName();

        // The store off mainnet, as the rehearsal would leave it; then chain 1 with the launch config.
        script.deployStore(_config(PAGE_NAMES_GRIDS), SENDER);
        vm.chainId(1);

        // Control: the twin that never names KILIM_GRIDS is refused, as V-03's fix promises.
        _expectRefused("mainnet: the artwork does not read KILIM_GRIDS");
        script.deployContracts(_mainnetConfig(PAGE_NO_GRIDS));

        // The twin that names it in a guard and draws the same sixteen literal rectangles must be refused
        // too: its pixels owe nothing to the grids the 1/1 hands it.
        _expectRefused("mainnet: the artwork does not read KILIM_GRIDS");
        script.deployContracts(_mainnetConfig(PAGE_NAMES_GRIDS));
    }

    /// @dev What the accepted store's pinned artwork is: the file the manifest's sha256 names, with
    ///      readsGrids true, KILIM_GRIDS only inside the guard, and the drawing a literal. Its twin draws
    ///      the identical statement and differs only by not spelling the name.
    function _assertTheTwoArtworksDrawTheSameAndDifferOnlyInTheName() internal view {
        bytes memory names = bytes(vmf.readFile(string.concat(FIXTURES, "/synthetic-artwork.html")));
        bytes memory deaf = bytes(vmf.readFile(string.concat(FIXTURES, "/synthetic-artwork-no-grids.html")));
        string memory manifest = vmf.readFile(string.concat(PAGE_NAMES_GRIDS, "/manifest.json"));
        // The artwork the `expected` block pins (by sha256) is this file, and the packer flagged it true.
        assertEq(sha256(names), vmf.parseJsonBytes32(manifest, ".artwork.sha256"));
        assertTrue(vm.parseJsonBool(manifest, ".artwork.readsGrids"));
        string memory deafManifest = vmf.readFile(string.concat(PAGE_NO_GRIDS, "/manifest.json"));
        assertEq(sha256(deaf), vmf.parseJsonBytes32(deafManifest, ".artwork.sha256"));
        assertTrue(!vm.parseJsonBool(deafManifest, ".artwork.readsGrids"));
        // KILIM_GRIDS occurs exactly three times: once in a comment, twice in the one guard line (a
        // comment alone would set the flag just the same); the drawing is literal.
        assertEq(_count(names, "KILIM_GRIDS"), 3);
        assertEq(_count(names, COMMENT), 1);
        assertEq(_count(names, GUARD), 1);
        assertEq(_count(names, DRAW), 1);
        // The deaf twin: the same drawing statement, the name nowhere.
        assertEq(_count(deaf, "KILIM_GRIDS"), 0);
        assertEq(_count(deaf, DRAW), 1);
    }

    // ------------------------------------------------------------ configs, as DeployKilim.t.sol builds them

    function _config(string memory pageStore) internal view returns (DeployKilim.Config memory c) {
        c.chainId = block.chainid;
        c.deployer = DEPLOYER;
        c.deployerNonce = vm.getNonce(DEPLOYER);
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
        string memory g = vmf.readFile(string.concat(MOTIF_STORE, "/manifest.json"));
        string memory pg = vmf.readFile(string.concat(pageStore, "/manifest.json"));
        c.collectionDescription = vm.parseJsonString(g, ".description");
        c.collectionExternalUrl = vm.parseJsonString(g, ".externalUrl");
        c.oneOfOneName = vm.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vm.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vm.parseJsonString(pg, ".externalUrl");
    }

    /// @dev The launch settings on chain 1 with the `expected` block read from the two manifests: every
    ///      hash the script compares matches, as a signed-off mainnet config would.
    function _mainnetConfig(string memory pageStore) internal view returns (DeployKilim.Config memory c) {
        c = _config(pageStore);
        string memory g = vmf.readFile(string.concat(MOTIF_STORE, "/manifest.json"));
        string memory pg = vmf.readFile(string.concat(pageStore, "/manifest.json"));
        c.hasExpected = true;
        c.expected.gridsHash = vmf.parseJsonBytes32(g, ".hashes.gridsHash");
        c.expected.namesHash = vmf.parseJsonBytes32(g, ".hashes.namesHash");
        c.expected.prefixHash = vmf.parseJsonBytes32(pg, ".hashes.prefixHash");
        c.expected.headHash = vmf.parseJsonBytes32(pg, ".hashes.headHash");
        c.expected.tailHash = vmf.parseJsonBytes32(pg, ".hashes.tailHash");
        c.expected.motifGolden = vmf.parseJsonBytes32(g, ".golden.tokenURI.sha256");
        c.expected.oneOfOneGolden = vmf.parseJsonBytes32(pg, ".golden.tokenURI.sha256");
        c.expected.motifSource = vmf.parseJsonBytes32(g, ".source.sha256");
        c.expected.artwork = vmf.parseJsonBytes32(pg, ".artwork.sha256");
        c.expected.still = vmf.parseJsonBytes32(pg, ".still.sha256");
        c.expected.loader = vmf.parseJsonBytes32(pg, ".loaderTemplate.sha256");
        c.chainId = 1;
        c.deployer = ARTIST;
        c.deployerNonce = vm.getNonce(ARTIST);
        c.auction.reservePrice = 0.01 ether;
        c.auction.treasury = ARTIST;
    }

    function _expectRefused(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployKilim.Refused.selector, reason));
    }

    // ------------------------------------------------------------ helpers

    /// @dev Non-overlapping occurrences of `needle` in `hay`.
    function _count(bytes memory hay, bytes memory needle) internal pure returns (uint256 n) {
        if (needle.length == 0 || needle.length > hay.length) return 0;
        for (uint256 i; i + needle.length <= hay.length;) {
            bool hit = true;
            for (uint256 k; k < needle.length; ++k) {
                if (hay[i + k] != needle[k]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                ++n;
                i += needle.length;
            } else {
                ++i;
            }
        }
    }
}
