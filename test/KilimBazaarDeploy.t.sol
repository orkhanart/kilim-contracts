// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilimBazaar} from "../script/DeployKilimBazaar.s.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase, FakeAuction} from "./bazaar/BazaarBase.sol";

/// @notice script/DeployKilimBazaar.s.sol against the local chain: a deployment read back, every refusal it
///         promises, the launch values it pins when the chain is switched to Ethereum mainnet, and its config.
contract KilimBazaarDeployTest is BazaarBase {
    address internal constant SENDER = address(0x5E4D);
    string internal constant FRAMES = "https://orkhan.art/kilim/bazaar/frames/";

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

    function _mainnet() internal returns (DeployKilimBazaar.Config memory c) {
        vmb.chainId(1);
        vmb.etch(HISTORY, HISTORY_CODE);
        c = _config();
        c.imageBase = FRAMES;
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
