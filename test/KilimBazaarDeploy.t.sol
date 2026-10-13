// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../script/DeployKilim.s.sol";
import {DeployKilimBazaar} from "../script/DeployKilimBazaar.s.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase, FakeAuction} from "./bazaar/BazaarBase.sol";

interface VmBazaarDeployTest {
    function setNonce(address, uint64) external;
    function readFile(string calldata) external view returns (string memory);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
}

/// @dev DeployKilim with the one call that needs a live node (the pending nonce) answered from the chain.
contract DeployKilimOffline is DeployKilim {
    function _pendingNonce(address who) internal view override returns (uint256) {
        return vm.getNonce(who);
    }
}

/// @notice script/DeployKilimBazaar.s.sol against the local chain: a deployment read back, every refusal it
///         promises, the launch values it pins when the chain is switched to Ethereum mainnet, and its config.
contract KilimBazaarDeployTest is BazaarBase {
    VmBazaarDeployTest internal constant vmx =
        VmBazaarDeployTest(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant SENDER = address(0x5E4D);
    string internal constant FRAMES = "https://orkhan.art/kilim/bazaar/frames/";
    string internal constant MAINNET_JSON = "deploy/mainnet.json";
    /// orkhanart.eth's nonce when the mainnet addresses were first published (checklists/0-launch-steps.md),
    /// and the three contracts DeployKilim puts there: Motif Bazaar at n, The Unwoven Kilim at n + 1, the
    /// auction at n + 2.
    uint256 internal constant PUBLISHED_NONCE = 1568;
    address internal constant PUBLISHED_MOTIFS = 0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF;
    address internal constant PUBLISHED_ONE_OF_ONE = 0xeD82CE5F5E943ef80F3D32a907281936186742eC;
    address internal constant PUBLISHED_AUCTION = 0xb4817D07a14503dCEf49Bd25B17557e7CBb23423;

    DeployKilimBazaar internal script;
    /// The contract's rank names and fixed costs, read from a Bazaar made here (the names are written once,
    /// in KilimBazaar.rankName; onchain/test/kilim-page.test.mjs pins them to the stored page's RANKS).
    string[] internal pageNames;
    uint256[] internal pageCosts;

    function setUp() public {
        vm.warp(1_800_000_000);
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        script = new DeployKilimBazaar();
        KilimBazaar ref = _newBazaar("", BAZAAR_URL);
        (uint256[6] memory costs, bool open) = ref.ladder();
        assertTrue(!open);
        for (uint256 r = 1; r <= 6; ++r) {
            pageNames.push(ref.rankName(r));
            if (r < 6) pageCosts.push(costs[r - 1]);
        }
    }

    function _config() internal view returns (DeployKilimBazaar.Config memory c) {
        c.chainId = block.chainid;
        c.auction = address(auction);
        c.motifs = address(motifs);
        c.oneOfOne = address(oneOfOne);
        c.royaltyReceiver = ARTIST;
        c.pageTailHash = oneOfOne.tailHash();
        c.pageStore = FIXTURE_PAGE;
        c.description = BAZAAR_DESCRIPTION;
        c.externalUrl = BAZAAR_URL;
        c.imageBase = "";
        c.rankNames = pageNames;
        c.rankCosts = pageCosts;
    }

    function _expectRefused(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployKilimBazaar.Refused.selector, reason));
    }

    function testDeploysBeforeSettlementAndReadsBack() public {
        DeployKilimBazaar.Config memory c = _config();
        uint256 nonce = vmb.getNonce(SENDER);
        KilimBazaar b = script.deploy(c, SENDER);
        // one creation from the sender, nothing else: the dry run left no trace
        assertEq(address(b), vmb.computeCreateAddress(SENDER, nonce));
        assertEq(vmb.getNonce(SENDER), nonce + 1);
        assertEq(address(b.auction()), address(auction));
        assertEq(address(b.motifs()), address(motifs));
        assertEq(address(b.oneOfOne()), address(oneOfOne));
        assertEq(b.royaltyReceiver(), ARTIST);
        assertEq(b.description(), BAZAAR_DESCRIPTION);
        assertEq(b.externalUrl(), BAZAAR_URL);
        assertEq(b.imageBase(), "");
        assertEq(b.seedWindow(), 256);
        assertTrue(!auction.settled());
        // and it opens at settlement
        bazaar = b;
        _settle(0.017 ether);
        assertEq(_make(ALICE, _fresh(ALICE, 10)), 1);
    }

    function testTheAuctionMayComeFromTheEnvironment() public view {
        assertEq(script.auctionFrom(address(auction), address(0)), address(auction));
        assertEq(script.auctionFrom(address(0), address(auction)), address(auction));
        assertEq(script.auctionFrom(address(auction), address(auction)), address(auction));
    }

    function testRefusesTwoDifferentAuctionsOrNone() public {
        _expectRefused("the auction from the environment differs from the config");
        script.auctionFrom(address(auction), address(0xA));
        _expectRefused("no auction: set bazaar.auction");
        script.auctionFrom(address(0), address(0));
    }

    function testRefusesTheWrongChain() public {
        DeployKilimBazaar.Config memory c = _config();
        c.chainId = 11_155_111;
        _expectRefused("wrong chain");
        script.deploy(c, SENDER);
    }

    function testRefusesAnAuctionWithoutCode() public {
        DeployKilimBazaar.Config memory c = _config();
        c.auction = address(0xBEEF);
        _expectRefused("the auction has no code");
        script.deploy(c, SENDER);
    }

    function testRefusesAnAuctionWhoseTokensAreNotItsOwn() public {
        FakeAuction fake = new FakeAuction();
        fake.setTokens(motifs, oneOfOne);
        DeployKilimBazaar.Config memory c = _config();
        c.auction = address(fake);
        _expectRefused("the auction, motifs and 1/1 do not belong together");
        script.deploy(c, SENDER);
    }

    function testRefusesTokensOtherThanTheConfigs() public {
        DeployKilimBazaar.Config memory c = _config();
        c.motifs = address(0x1234);
        _expectRefused("motifs differ from the config");
        script.deploy(c, SENDER);
        c = _config();
        c.oneOfOne = address(0x1234);
        _expectRefused("oneOfOne differs from the config");
        script.deploy(c, SENDER);
        // unnamed, they are not compared
        c = _config();
        c.motifs = address(0);
        c.oneOfOne = address(0);
        script.deploy(c, SENDER);
    }

    function testRefusesAnotherTailHash() public {
        DeployKilimBazaar.Config memory c = _config();
        c.pageTailHash = keccak256("another page");
        _expectRefused("pageTailHash differs from the chain's 1/1");
        script.deploy(c, SENDER);
    }

    function testRefusesAPageStoreWhoseManifestDiffers() public {
        DeployKilimBazaar.Config memory c = _config();
        c.pageStore = "../onchain/test/fixtures/page-store-no-grids";
        _expectRefused("pageTailHash differs from the page store's manifest");
        script.deploy(c, SENDER);
        c.pageStore = "";
        script.deploy(c, SENDER);
    }

    function testRefusesAZeroRoyaltyReceiver() public {
        DeployKilimBazaar.Config memory c = _config();
        c.royaltyReceiver = address(0);
        _expectRefused("zero royalty receiver");
        script.deploy(c, SENDER);
    }

    function testRefusesTextsTheDataUrlCannotCarry() public {
        DeployKilimBazaar.Config memory c = _config();
        c.description = "Kilims #1";
        _expectRefused("description: a character the data: URL cannot carry");
        script.deploy(c, SENDER);
        c = _config();
        c.externalUrl = "https://orkhan.art/%20/";
        _expectRefused("externalUrl: a character the data: URL cannot carry");
        script.deploy(c, SENDER);
        c = _config();
        c.imageBase = 'https://"x"/';
        _expectRefused("imageBase: a character the data: URL cannot carry");
        script.deploy(c, SENDER);
        c = _config();
        c.description = string(abi.encodePacked("tab", bytes1(0x09)));
        _expectRefused("description: a character the data: URL cannot carry");
        script.deploy(c, SENDER);
    }

    function testRefusesTheDroppedWordsButKeepsTheOneOfOnesName() public {
        string[5] memory bad = [
            "Kilims woven from burned motifs.",
            "Weave a kilim.",
            "Each one weaving its seed.",
            "woven kilims",
            "WEAVING"
        ];
        for (uint256 i; i < bad.length; ++i) {
            DeployKilimBazaar.Config memory c = _config();
            c.description = bad[i];
            _expectRefused("description: the words weave and woven are dropped");
            script.deploy(c, SENDER);
        }
        DeployKilimBazaar.Config memory ok = _config();
        ok.description = "Made by the engine of The Unwoven Kilim.";
        script.deploy(ok, SENDER);
    }

    /// @dev The dropped words in any case and inside other words; only "unwoven" (the 1/1's name) passes.
    function testRefusesTheDroppedWordsInAnyCaseAndInsideWords() public {
        string[8] memory bad = [
            "WOVEN",
            "Hand-woven kilims.",
            "Kilims (woven).",
            "rewoven",
            "Interweaving motifs.",
            "WeAvEs",
            "Unwoven, then woven.",
            "wovenness"
        ];
        for (uint256 i; i < bad.length; ++i) {
            DeployKilimBazaar.Config memory c = _config();
            c.description = bad[i];
            _expectRefused("description: the words weave and woven are dropped");
            script.deploy(c, SENDER);
        }
        DeployKilimBazaar.Config memory u = _config();
        u.externalUrl = "https://orkhan.art/woven/";
        _expectRefused("externalUrl: the words weave and woven are dropped");
        script.deploy(u, SENDER);
        u = _config();
        u.imageBase = "https://orkhan.art/WEAVE/frames/";
        _expectRefused("imageBase: the words weave and woven are dropped");
        script.deploy(u, SENDER);
        string[3] memory fine = ["THE UNWOVEN KILIM", "From The Unwoven Kilim.", "unwoven"];
        for (uint256 i; i < fine.length; ++i) {
            DeployKilimBazaar.Config memory ok = _config();
            ok.description = fine[i];
            script.deploy(ok, SENDER);
        }
    }

    // ------------------------------------------------------------ the two URL bases

    /// @dev The token id is appended to imageBase and externalUrl as they are, for ever: a base that does not
    ///      end in "/" (or "=" for a query) would make every image and link wrong.
    function testRefusesAUrlBaseWithoutItsSeparator() public {
        string[3] memory bad = [
            "https://orkhan.art/kilim/bazaar/frames",
            "https://orkhan.art/kilim/bazaar",
            "https://orkhan.art/k?id"
        ];
        for (uint256 i; i < bad.length; ++i) {
            DeployKilimBazaar.Config memory c = _config();
            c.imageBase = bad[i];
            _expectRefused("imageBase: a URL base must end with / or =");
            script.deploy(c, SENDER);
            c = _config();
            c.externalUrl = bad[i];
            _expectRefused("externalUrl: a URL base must end with / or =");
            script.deploy(c, SENDER);
        }
    }

    function testRefusesAUrlBaseWithoutAKnownScheme() public {
        string[5] memory bad = [
            "http://orkhan.art/kilim/",
            "orkhan.art/kilim/",
            "//orkhan.art/kilim/",
            "data:image/png;base64,/",
            "HTTPS://orkhan.art/"
        ];
        for (uint256 i; i < bad.length; ++i) {
            DeployKilimBazaar.Config memory c = _config();
            c.imageBase = bad[i];
            _expectRefused("imageBase: a URL base must start with https://, ipfs:// or ar://");
            script.deploy(c, SENDER);
            c = _config();
            c.externalUrl = bad[i];
            _expectRefused("externalUrl: a URL base must start with https://, ipfs:// or ar://");
            script.deploy(c, SENDER);
        }
    }

    function testRefusesASpaceInAUrlBase() public {
        DeployKilimBazaar.Config memory c = _config();
        c.imageBase = "https://orkhan.art/kilim frames/";
        _expectRefused("imageBase: a URL base cannot carry a space");
        script.deploy(c, SENDER);
        c = _config();
        c.externalUrl = "https://orkhan.art/kilim/ bazaar/";
        _expectRefused("externalUrl: a URL base cannot carry a space");
        script.deploy(c, SENDER);
    }

    function testAcceptsTheUrlBasesItAllows() public {
        string[4] memory good = [
            "https://orkhan.art/kilim/bazaar/frames/",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/",
            "ar://kilim-frames/",
            "https://orkhan.art/kilim/frame?id="
        ];
        for (uint256 i; i < good.length; ++i) {
            DeployKilimBazaar.Config memory c = _config();
            c.imageBase = good[i];
            c.externalUrl = good[i];
            KilimBazaar b = script.deploy(c, SENDER);
            assertEq(b.imageBase(), good[i]);
        }
        // and empty means none: the on-chain drawing, and no link
        DeployKilimBazaar.Config memory none = _config();
        none.externalUrl = "";
        assertEq(script.deploy(none, SENDER).externalUrl(), "");
    }

    // ------------------------------------------------------------ the page's ranks

    function testRefusesRankNamesOtherThanTheContracts() public {
        DeployKilimBazaar.Config memory c = _config();
        c.rankNames = new string[](6);
        for (uint256 i; i < 6; ++i) {
            c.rankNames[i] = pageNames[i];
        }
        c.rankNames[1] = string.concat(pageNames[1], " II"); // the page renamed, the contract not
        _expectRefused("bazaar.pageRanks: the names differ from the contract's");
        script.deploy(c, SENDER);
        c.rankNames[1] = pageNames[1];
        c.rankNames[5] = string(_sub(bytes(pageNames[5]), 4, bytes(pageNames[5]).length)); // "The " dropped
        _expectRefused("bazaar.pageRanks: the names differ from the contract's");
        script.deploy(c, SENDER);
    }

    function testRefusesRankCostsOtherThanTheContracts() public {
        DeployKilimBazaar.Config memory c = _config();
        c.rankCosts = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            c.rankCosts[i] = pageCosts[i];
        }
        c.rankCosts[2] = 99;
        _expectRefused("bazaar.pageRanks: the costs differ from the contract's");
        script.deploy(c, SENDER);
    }

    function testRefusesMisshapenPageRanks() public {
        DeployKilimBazaar.Config memory c = _config();
        c.rankNames = new string[](5);
        _expectRefused("bazaar.pageRanks: six names and five costs");
        script.deploy(c, SENDER);
        c = _config();
        c.rankCosts = new uint256[](6);
        _expectRefused("bazaar.pageRanks: six names and five costs");
        script.deploy(c, SENDER);
    }

    /// @dev Once the auction is settled the contract shows only the ranks under the Master's cost (ladder()):
    ///      the page must keep exactly those, and drop the same others (both drop a rank costing at least top).
    function testAfterSettlementTheRanksUnderTheMastersCostAreCompared() public {
        _settle(0.017 ether); // top 17: only the Apprentice stays under the Master
        script.deploy(_config(), SENDER);
        DeployKilimBazaar.Config memory c = _config();
        c.rankCosts = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            c.rankCosts[i] = pageCosts[i];
        }
        c.rankCosts[1] = 15; // the page would keep a rank at 15 that the contract drops
        _expectRefused("bazaar.pageRanks: the costs differ from the contract's");
        script.deploy(c, SENDER);
        c.rankCosts[1] = pageCosts[1];
        c.rankCosts[0] = 11;
        _expectRefused("bazaar.pageRanks: the costs differ from the contract's");
        script.deploy(c, SENDER);
    }

    function testSepoliaAndMainnetNeedThePageRanks() public {
        DeployKilimBazaar.Config memory c = _config();
        c.rankNames = new string[](0);
        c.rankCosts = new uint256[](0);
        script.deploy(c, SENDER); // a local chain may leave them out
        vmb.etch(HISTORY, HISTORY_CODE);
        vmb.chainId(11_155_111);
        c.chainId = 11_155_111;
        _expectRefused("Sepolia and mainnet: bazaar.pageRanks is missing");
        script.deploy(c, SENDER);
        c = _mainnet();
        c.rankNames = new string[](0);
        c.rankCosts = new uint256[](0);
        _expectRefused("Sepolia and mainnet: bazaar.pageRanks is missing");
        script.deploy(c, ARTIST);
    }

    // ------------------------------------------------------------ mainnet

    /// @dev Chain 1 as the Bazaar meets it: the auction and its two tokens created by orkhanart.eth at nonces
    ///      n, n + 1 and n + 2, as DeployKilim sends them, and a config that names the deployer, n and the
    ///      signed-off texts but no address (the script derives all three).
    function _mainnet() internal returns (DeployKilimBazaar.Config memory c) {
        vmb.chainId(1);
        vmb.etch(HISTORY, HISTORY_CODE);
        if (PUBLISHED_AUCTION.code.length == 0) {
            _deployTrioFromArtist(PUBLISHED_NONCE, FIXTURE_PAGE);
        } else {
            auction = KilimAuction(PUBLISHED_AUCTION);
            motifs = auction.motifs();
            oneOfOne = auction.oneOfOne();
        }
        c = _config();
        c.deployer = ARTIST;
        c.deployerNonce = PUBLISHED_NONCE;
        c.auction = address(0);
        c.motifs = address(0);
        c.oneOfOne = address(0);
        c.imageBase = FRAMES;
        c = _signTexts(c);
    }

    /// @dev The token texts BazaarBase deploys with, and `expected.texts` over them and the Bazaar's three.
    function _signTexts(DeployKilimBazaar.Config memory c)
        internal
        view
        returns (DeployKilimBazaar.Config memory)
    {
        c.collectionDescription = DESCRIPTION;
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = ONE_OF_ONE_NAME;
        c.oneOfOneDescription = DESCRIPTION;
        c.oneOfOneExternalUrl = EXTERNAL_URL;
        c.expectedTexts = script.textsHash(c);
        return c;
    }

    /// @dev The store chunks from this contract (any wallet may send them), then the three creations from
    ///      orkhanart.eth at nonce n, in DeployKilim's order, the auction's address predicted as both minters.
    function _deployTrioFromArtist(uint256 n, string memory dir) internal {
        vmx.setNonce(ARTIST, uint64(n));
        pageDir = dir;
        pageHead = _pageFile("head.bin");
        KilimOneOfOne.Page memory page = pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin"));
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        address[] memory gridChunks = chunked(grids, 767 * 32);
        address namesChunk = sstore2(names);
        address minter = vm.computeCreateAddress(ARTIST, n + 2);
        vm.startPrank(ARTIST);
        motifs = new KilimMotifs(
            minter,
            ARTIST,
            BIG_CAP,
            gridChunks,
            keccak256(grids),
            namesChunk,
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
        oneOfOne = new KilimOneOfOne(minter, ARTIST, motifs, page, ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL);
        auction = new KilimAuction(
            KilimAuction.Config({
                treasury: ARTIST,
                motifs: address(motifs),
                oneOfOne: address(oneOfOne),
                startsAt: uint64(block.timestamp + 1 hours),
                duration: 24 hours,
                extensionWindow: 10 minutes,
                incrementBps: 1000,
                reservePrice: RESERVE,
                maxMotifsPerBid: BIG_CAP
            })
        );
        vm.stopPrank();
        motifChain = motifs.deploymentChainId();
        require(address(auction) == minter, "auction address");
    }

    function testMainnetDeploysFromTheArtistWithTheLaunchValues() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        KilimBazaar b = script.deploy(c, ARTIST);
        assertEq(b.royaltyReceiver(), ARTIST);
        assertEq(b.imageBase(), FRAMES);
        assertEq(b.seedWindow(), 8191);
        assertEq(b.ROYALTY_BPS(), 750);
    }

    function testMainnetRefusesAnotherSender() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        _expectRefused("mainnet: the sender is not orkhanart.eth");
        script.deploy(c, SENDER);
    }

    function testMainnetRefusesASenderWithCode() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        vmb.etch(ARTIST, hex"ef0100000000000000000000000000000000000000dead");
        _expectRefused("mainnet: the sender has code");
        script.deploy(c, ARTIST);
    }

    function testMainnetRefusesAnotherRoyaltyReceiver() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.royaltyReceiver = TREASURY;
        _expectRefused("mainnet launch value: royaltyReceiver");
        script.deploy(c, ARTIST);
    }

    function testMainnetRefusesAnEmptyImageBase() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.imageBase = "";
        _expectRefused("mainnet launch value: imageBase is empty");
        script.deploy(c, ARTIST);
    }

    function testMainnetRefusesWithoutThePageStore() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.pageStore = "";
        _expectRefused("mainnet needs the page store");
        script.deploy(c, ARTIST);
    }

    function testMainnetAndSepoliaRefuseAChainWithoutTheHistoryContract() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        vmb.etch(HISTORY, "");
        _expectRefused("no EIP-2935 history contract: the seed window would be 256");
        script.deploy(c, ARTIST);
        vmb.chainId(11_155_111);
        c = _config();
        _expectRefused("no EIP-2935 history contract: the seed window would be 256");
        script.deploy(c, SENDER);
        vmb.etch(HISTORY, HISTORY_CODE);
        assertEq(script.deploy(c, SENDER).seedWindow(), 8191);
    }

    // ------------------------------------------------------------ mainnet: the three addresses (audit TK-1)

    /// @dev The offsets are DeployKilim's: at the nonce first published, the derived addresses are the ones
    ///      published for it.
    function testTheLaunchAddressesFollowDeployKilimsOrder() public view {
        (address m, address o, address a) = script.launchAddresses(PUBLISHED_NONCE);
        assertEq(m, PUBLISHED_MOTIFS);
        assertEq(o, PUBLISHED_ONE_OF_ONE);
        assertEq(a, PUBLISHED_AUCTION);
        // and at 1,570, the nonce read on 12 October at 23:51 UTC (checklists/0-launch-steps.md, step 9)
        (m, o, a) = script.launchAddresses(1570);
        assertEq(m, 0xb4817D07a14503dCEf49Bd25B17557e7CBb23423);
        assertEq(o, 0xf2bf089aa3b9E7D8664147e2Db42e84499717c7e);
        assertEq(a, 0x89c531b660DA287BB16f971023cCDddf302D80A2);
    }

    /// @dev No address is typed in on mainnet: the script takes orkhanart.eth's creations at deployerNonce,
    ///      + 1 and + 2. Naming them as well is allowed when they are those.
    function testMainnetDerivesTheAuctionFromTheDeployerNonce() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        assertEq(c.auction, address(0));
        KilimBazaar b = script.deploy(c, ARTIST);
        assertEq(address(b.auction()), PUBLISHED_AUCTION);
        assertEq(address(b.motifs()), PUBLISHED_MOTIFS);
        assertEq(address(b.oneOfOne()), PUBLISHED_ONE_OF_ONE);
        c = _mainnetNamed();
        assertEq(address(script.deploy(c, ARTIST).auction()), PUBLISHED_AUCTION);
    }

    /// @dev Audit TK-1, the PoC turned round: a look-alike trio that anyone can deploy over the public page
    ///      (an auction, a motif collection and a 1/1 naming each other, the real TAIL, so pageTailHash and the
    ///      page store agree) passed every check while `bazaar.auction` was typed in. On mainnet the auction,
    ///      and the motifs and 1/1, must now be orkhanart.eth's creations at the config's nonce.
    function testMainnetRefusesALookAlikeAuction() public {
        DeployKilimBazaar.Config memory c = _mainnetNamed();
        // Someone else's trio over the same page store (here this test contract's).
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        address lookAuction = address(auction);
        address lookMotifs = address(motifs);
        address lookOneOfOne = address(oneOfOne);
        assertTrue(lookAuction != c.auction);
        assertEq(oneOfOne.tailHash(), c.pageTailHash);
        DeployKilimBazaar.Config memory fake = c;
        fake.auction = lookAuction;
        fake.motifs = lookMotifs;
        fake.oneOfOne = lookOneOfOne;
        _expectRefused("mainnet: the auction is not orkhanart.eth's creation at deployerNonce + 2");
        script.deploy(fake, ARTIST);
        // only the auction typed in wrong: the derived motifs and 1/1 do not save it
        fake = _mainnet();
        fake.auction = lookAuction;
        _expectRefused("mainnet: the auction is not orkhanart.eth's creation at deployerNonce + 2");
        script.deploy(fake, ARTIST);
        fake = _mainnet();
        fake.motifs = lookMotifs;
        _expectRefused("mainnet: motifs are not orkhanart.eth's creation at deployerNonce");
        script.deploy(fake, ARTIST);
        fake = _mainnet();
        fake.oneOfOne = lookOneOfOne;
        _expectRefused("mainnet: oneOfOne is not orkhanart.eth's creation at deployerNonce + 1");
        script.deploy(fake, ARTIST);
        // run() hands $KILIM_BAZAAR_AUCTION to the same check: auctionFrom only makes the two agree
        fake = _mainnet();
        fake.auction = script.auctionFrom(fake.auction, lookAuction);
        _expectRefused("mainnet: the auction is not orkhanart.eth's creation at deployerNonce + 2");
        script.deploy(fake, ARTIST);
        // and the real trio, unnamed, still deploys
        assertEq(address(script.deploy(_mainnet(), ARTIST).auction()), PUBLISHED_AUCTION);
    }

    /// @dev The derivation needs orkhanart.eth and a nonce; a wrong nonce derives addresses without code, or
    ///      other contracts, and is refused either way, in words that name deployerNonce (final rehearsal F5).
    function testMainnetRefusesAnotherDeployerOrNonce() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.deployer = SENDER;
        _expectRefused("mainnet launch value: deployer");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.deployerNonce = script.NO_NONCE();
        _expectRefused("mainnet needs the published deployerNonce");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.deployerNonce = PUBLISHED_NONCE + 1; // the 1/1 and the auction at n + 1 and n + 2, nothing at n + 3
        _expectRefused(_notTheNonce(PUBLISHED_NONCE + 1));
        script.deploy(c, ARTIST);
        c = _mainnetNamed();
        c.deployerNonce = PUBLISHED_NONCE + 1; // the real addresses, named, no longer match
        _expectRefused("mainnet: the auction is not orkhanart.eth's creation at deployerNonce + 2");
        script.deploy(c, ARTIST);
    }

    /// @dev Off mainnet nothing is derived: the deployer and nonce are not read, and the auction is the
    ///      config's (the Sepolia rehearsal's Bazaar was deployed so).
    function testOtherChainsTakeTheAuctionFromTheConfig() public {
        DeployKilimBazaar.Config memory c = _config();
        c.deployer = SENDER;
        c.deployerNonce = 7;
        script.deploy(c, SENDER);
        c.auction = address(0);
        _expectRefused("no auction: set bazaar.auction");
        script.deploy(c, SENDER);
    }

    /// @dev Final rehearsal F5, B4: deployerNonce moved to the wallet's nonce after the three creations. Nothing
    ///      is there, and the refusal says what deployerNonce must be, not only "the auction has no code".
    function testMainnetRefusesTheWalletsNonceNowAsDeployerNonce() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        uint256 now_ = vmb.getNonce(ARTIST);
        assertEq(now_, PUBLISHED_NONCE + 3);
        c.deployerNonce = now_;
        _expectRefused(_noContracts(now_));
        script.deploy(c, ARTIST);
    }

    /// @dev Final rehearsal F5, B5: a deployerNonce below the real one derives an "auction" that is the trio's
    ///      1/1 or Motif Bazaar. motifs() answers there and oneOfOne() reverts, which came out as an undecoded
    ///      revert; now it is a refusal that names deployerNonce. Nothing is sent either way.
    function testMainnetRefusesAnEarlierDeployerNonceByName() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.deployerNonce = PUBLISHED_NONCE - 1; // "auction" = the real 1/1, "1/1" = the real Motif Bazaar
        _expectRefused(_notTheNonce(PUBLISHED_NONCE - 1));
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.deployerNonce = PUBLISHED_NONCE - 2; // "auction" = the real Motif Bazaar, nothing at n - 2
        _expectRefused(_notTheNonce(PUBLISHED_NONCE - 2));
        script.deploy(c, ARTIST);
        // the published nonce still deploys
        assertEq(address(script.deploy(_mainnet(), ARTIST).auction()), PUBLISHED_AUCTION);
    }

    /// @dev The two token contracts are out and name n + 2 as their minter, but the auction is not (lost, as in
    ///      checklist 2's "If the third was dropped"): the refusal points to runAuction.
    function testMainnetRefusesBeforeTheAuctionIsOutAndNamesRunAuction() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        vmb.etch(PUBLISHED_AUCTION, "");
        _expectRefused(
            string.concat(
                "mainnet: the auction at deployerNonce ",
                vmb.toString(PUBLISHED_NONCE),
                " + 2 has no code (orkhanart.eth's nonce is ",
                vmb.toString(uint256(vmb.getNonce(ARTIST))),
                "): finish the contracts with DeployKilim's runAuction first"
            )
        );
        script.deploy(c, ARTIST);
    }

    /// @dev The three deployerNonce refusals' words, with orkhanart.eth's nonce now.
    function _noContracts(uint256 n) internal view returns (string memory) {
        return string.concat(
            "mainnet: no contracts at deployerNonce ",
            vmb.toString(n),
            ", + 1 and + 2 (orkhanart.eth's nonce is ",
            vmb.toString(uint256(vmb.getNonce(ARTIST))),
            "): deployerNonce is the nonce the three contracts were deployed at, not the wallet's nonce now; if they are not deployed yet, run DeployKilim first"
        );
    }

    function _notTheNonce(uint256 n) internal view returns (string memory) {
        return string.concat(
            "mainnet: deployerNonce ",
            vmb.toString(n),
            " is not the nonce the three contracts were deployed at: orkhanart.eth's creations there are not Motif Bazaar, The Unwoven Kilim and their auction (its nonce is ",
            vmb.toString(uint256(vmb.getNonce(ARTIST))),
            ")"
        );
    }

    function _mainnetNamed() internal returns (DeployKilimBazaar.Config memory c) {
        c = _mainnet();
        (c.motifs, c.oneOfOne, c.auction) = script.launchAddresses(PUBLISHED_NONCE);
    }

    // ------------------------------------------------------------ the signed-off texts (audit TK-2)

    /// @dev Every text the Bazaar stores, and the token texts, are pinned on mainnet by `expected.texts`: an
    ///      edit after sign-off is refused even when it passes every other check.
    function testMainnetRefusesTextsOtherThanTheSignedOffOnes() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.description = "Kilims made from burned motifs.";
        _expectRefused("expected texts");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.externalUrl = "https://orkhan.art/kilim/elsewhere/";
        _expectRefused("expected texts");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.imageBase = "https://attacker.example/frames/";
        _expectRefused("expected texts");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.collectionExternalUrl = "https://attacker.example/kilim";
        _expectRefused("expected texts");
        script.deploy(c, ARTIST);
        // a config without the value (zero) is refused on mainnet
        c = _mainnet();
        c.expectedTexts = bytes32(0);
        _expectRefused("expected texts");
        script.deploy(c, ARTIST);
    }

    /// @dev Re-signing a changed token text does not help: the hash covers the token texts as the config
    ///      names them, and those must be what the chain's motif collection and 1/1 hold.
    function testTheTokenTextsTheHashCoversMustBeTheChains() public {
        DeployKilimBazaar.Config memory c = _mainnet();
        c.collectionExternalUrl = "https://attacker.example/kilim";
        c.expectedTexts = script.textsHash(c);
        _expectRefused("the token texts differ from the chain's");
        script.deploy(c, ARTIST);
        c = _mainnet();
        c.oneOfOneDescription = "Another description";
        c.expectedTexts = script.textsHash(c);
        _expectRefused("the token texts differ from the chain's");
        script.deploy(c, ARTIST);
    }

    /// @dev Off mainnet `expected.texts` is optional (the Sepolia record predates it); a config that carries it
    ///      is held to it.
    function testOtherChainsCompareTheTextsWhenNamed() public {
        DeployKilimBazaar.Config memory c = _signTexts(_config());
        script.deploy(c, SENDER);
        c.imageBase = FRAMES;
        _expectRefused("expected texts");
        script.deploy(c, SENDER);
        c.expectedTexts = bytes32(0);
        script.deploy(c, SENDER);
    }

    /// @dev Each text moves the hash, and the length prefix keeps texts from sliding into each other.
    function testTheTextsHashCoversEachTextUnambiguously() public view {
        DeployKilimBazaar.Config memory c = _signTexts(_config());
        bytes32 base = c.expectedTexts;
        for (uint256 i; i < 8; ++i) {
            DeployKilimBazaar.Config memory e = _signTexts(_config());
            if (i == 0) e.collectionDescription = "x";
            else if (i == 1) e.collectionExternalUrl = "x";
            else if (i == 2) e.oneOfOneName = "x";
            else if (i == 3) e.oneOfOneDescription = "x";
            else if (i == 4) e.oneOfOneExternalUrl = "x";
            else if (i == 5) e.description = "x";
            else if (i == 6) e.externalUrl = "x";
            else e.imageBase = "x";
            assertTrue(script.textsHash(e) != base);
        }
        // "ab" + "" and "a" + "b" differ
        DeployKilimBazaar.Config memory p = _signTexts(_config());
        DeployKilimBazaar.Config memory q = _signTexts(_config());
        p.externalUrl = "https://a/";
        p.imageBase = "";
        q.externalUrl = "";
        q.imageBase = "https://a/";
        assertTrue(script.textsHash(p) != script.textsHash(q));
    }

    // ------------------------------------------------------------ deploy/mainnet.json end to end

    /// @dev deploy/mainnet.json as it stands, through both scripts on a chain switched to 1 with the real
    ///      stores: DeployKilim deploys the three contracts from orkhanart.eth at `deployerNonce` (only the
    ///      `startsAt` TODO filled in), then DeployKilimBazaar, with no address in the config, finds them from
    ///      the same nonce. Both scripts hash the config's texts to its `expected.texts`. Before the contracts
    ///      exist the Bazaar is refused, and a look-alike trio over the real page is refused throughout.
    function testMainnetJsonDeploysTheBazaarAgainstTheContractsItsNonceNames() public {
        string memory j = vmx.readFile(MAINNET_JSON);
        DeployKilim.Config memory dc = _deployKilimConfig(j);
        DeployKilimBazaar.Config memory bc = script.loadConfig(MAINNET_JSON);
        DeployKilimOffline dk = new DeployKilimOffline();
        assertEq(dk.textsHash(dc), vmx.parseJsonBytes32(j, ".expected.texts"));
        assertEq(script.textsHash(bc), vmx.parseJsonBytes32(j, ".expected.texts"));
        assertEq(bc.expectedTexts, vmx.parseJsonBytes32(j, ".expected.texts"));
        assertEq(bc.auction, address(0)); // nothing typed in
        assertEq(bc.deployer, ARTIST);

        vmb.chainId(1);
        vmb.etch(HISTORY, HISTORY_CODE);
        // A look-alike trio over the real page, by someone else.
        _deployAuction(BIG_CAP, REAL_PAGE);
        address lookAlike = address(auction);
        dk.deployStore(dc, address(0x5704E)); // any wallet but the deployer
        // Before runContracts there is nothing at the derived addresses, and the refusal says so by deployerNonce.
        _expectRefused(_noContracts(dc.deployerNonce));
        script.deploy(bc, ARTIST);

        vmx.setNonce(ARTIST, uint64(dc.deployerNonce));
        DeployKilim.Deployed memory d = dk.deployContracts(dc);
        (address m, address o, address a) = script.launchAddresses(dc.deployerNonce);
        assertEq(address(d.motifs), m);
        assertEq(address(d.oneOfOne), o);
        assertEq(address(d.auction), a);

        DeployKilimBazaar.Config memory wrong = script.loadConfig(MAINNET_JSON);
        wrong.auction = lookAlike;
        _expectRefused("mainnet: the auction is not orkhanart.eth's creation at deployerNonce + 2");
        script.deploy(wrong, ARTIST);

        KilimBazaar b = script.deploy(bc, ARTIST);
        assertEq(address(b.auction()), address(d.auction));
        assertEq(address(b.motifs()), address(d.motifs));
        assertEq(address(b.oneOfOne()), address(d.oneOfOne));
        assertEq(b.imageBase(), bc.imageBase);
        assertEq(b.seedWindow(), 8191);
    }

    /// @dev DeployKilim's config from mainnet.json, by hand: DeployKilim.loadConfig refuses the file while
    ///      `auction.startsAt` is its TODO text, so that one value is set here.
    function _deployKilimConfig(string memory j) internal view returns (DeployKilim.Config memory c) {
        c.chainId = vmx.parseJsonUint(j, ".chainId");
        c.deployer = vmx.parseJsonAddress(j, ".deployer");
        c.deployerNonce = vmx.parseJsonUint(j, ".deployerNonce");
        c.minLeadSeconds = vmx.parseJsonUint(j, ".minLeadSeconds");
        c.motifStore = vmx.parseJsonString(j, ".motifStore");
        c.pageStore = vmx.parseJsonString(j, ".pageStore");
        c.auction.treasury = vmx.parseJsonAddress(j, ".auction.treasury");
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = uint64(vmx.parseJsonUint(j, ".auction.duration"));
        c.auction.extensionWindow = uint64(vmx.parseJsonUint(j, ".auction.extensionWindow"));
        c.auction.incrementBps = uint16(vmx.parseJsonUint(j, ".auction.incrementBps"));
        c.auction.reservePrice = vmx.parseJsonUint(j, ".auction.reservePrice");
        c.auction.maxMotifsPerBid = vmx.parseJsonUint(j, ".auction.maxMotifsPerBid");
        c.motifCap = vmx.parseJsonUint(j, ".collection.motifCap");
        c.collectionDescription = vmx.parseJsonString(j, ".collection.description");
        c.collectionExternalUrl = vmx.parseJsonString(j, ".collection.externalUrl");
        c.oneOfOneName = vmx.parseJsonString(j, ".oneOfOne.name");
        c.oneOfOneDescription = vmx.parseJsonString(j, ".oneOfOne.description");
        c.oneOfOneExternalUrl = vmx.parseJsonString(j, ".oneOfOne.externalUrl");
        c.bazaarDescription = vmx.parseJsonString(j, ".bazaar.description");
        c.bazaarExternalUrl = vmx.parseJsonString(j, ".bazaar.externalUrl");
        c.bazaarImageBase = vmx.parseJsonString(j, ".bazaar.imageBase");
        c.hasExpected = true;
        c.expected.gridsHash = vmx.parseJsonBytes32(j, ".expected.gridsHash");
        c.expected.namesHash = vmx.parseJsonBytes32(j, ".expected.namesHash");
        c.expected.prefixHash = vmx.parseJsonBytes32(j, ".expected.prefixHash");
        c.expected.headHash = vmx.parseJsonBytes32(j, ".expected.headHash");
        c.expected.tailHash = vmx.parseJsonBytes32(j, ".expected.tailHash");
        c.expected.motifGolden = vmx.parseJsonBytes32(j, ".expected.motifGolden");
        c.expected.oneOfOneGolden = vmx.parseJsonBytes32(j, ".expected.oneOfOneGolden");
        c.expected.motifSource = vmx.parseJsonBytes32(j, ".expected.motifSource");
        c.expected.artwork = vmx.parseJsonBytes32(j, ".expected.artwork");
        c.expected.still = vmx.parseJsonBytes32(j, ".expected.still");
        c.expected.loader = vmx.parseJsonBytes32(j, ".expected.loader");
        c.expected.texts = vmx.parseJsonBytes32(j, ".expected.texts");
    }

    // ------------------------------------------------------------ the config

    function testParsesTheBazaarBlock() public view {
        string memory j = string.concat(
            '{"chainId":11155111,"pageStore":"../onchain/build-page","bazaar":{"auction":"',
            vmb.toString(address(auction)),
            '","royaltyReceiver":"0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","pageTailHash":"',
            vmb.toString(oneOfOne.tailHash()),
            '","description":"',
            BAZAAR_DESCRIPTION,
            '","externalUrl":"',
            BAZAAR_URL,
            '","imageBase":"","pageRanks":{"names":["A","B","C","D","E","The F"],"costs":[10,30,100,300,1000]}}}'
        );
        DeployKilimBazaar.Config memory c = script.parseConfig(j);
        assertEq(c.rankNames.length, 6);
        assertEq(c.rankNames[5], "The F");
        assertEq(c.rankCosts.length, 5);
        assertEq(c.rankCosts[4], 1000);
        assertEq(c.chainId, 11_155_111);
        assertEq(c.auction, address(auction));
        assertEq(c.motifs, address(0));
        assertEq(c.oneOfOne, address(0));
        assertEq(c.royaltyReceiver, ARTIST);
        assertEq(c.pageTailHash, oneOfOne.tailHash());
        assertEq(c.pageStore, "../onchain/build-page");
        assertEq(c.description, BAZAAR_DESCRIPTION);
        assertEq(c.externalUrl, BAZAAR_URL);
        assertEq(c.imageBase, "");
        string memory k = string.concat(
            '{"chainId":1,"bazaar":{"royaltyReceiver":"0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","motifs":"',
            vmb.toString(address(motifs)),
            '","oneOfOne":"',
            vmb.toString(address(oneOfOne)),
            '","pageStore":"x","pageTailHash":"0x00000000000000000000000000000000000000000000000000000000000000aa",',
            '"description":"d","externalUrl":"","imageBase":"https://orkhan.art/f/"}}'
        );
        c = script.parseConfig(k);
        assertEq(c.rankNames.length, 0); // no pageRanks block: none
        assertEq(c.rankCosts.length, 0);
        assertEq(c.auction, address(0));
        assertEq(c.motifs, address(motifs));
        assertEq(c.oneOfOne, address(oneOfOne));
        assertEq(c.pageStore, "x");
        assertEq(c.imageBase, "https://orkhan.art/f/");
    }
}
