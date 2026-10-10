// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {TestBase} from "../TestBase.sol";

interface VmPoc {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function keyExistsJson(string calldata, string calldata) external pure returns (bool);
    function getNonce(address) external view returns (uint64);
    function chainId(uint256) external;
    function prank(address) external;
}

/// @notice PoC for the "deploy" review finding on script/DeployKilim.s.sol: on Ethereum mainnet the
///         script pins every auction number and the 1/1's name (`_requireLaunchSettings`), but nothing
///         about the content. Neither the Config struct nor the mainnet template names an expected
///         gridsHash, namesHash, prefixHash, headHash, tailHash or artwork/still sha256, so with the
///         artist's wallet, the published nonce, a nonzero inspection window and every launch value,
///         both phases go through with whatever onchain/build-glyphs and onchain/build-page hold. Today
///         that is the stand-in page onchain/test/fixtures/lean.html and the 161-byte placeholder
///         still, and the 1/1's answer is fixed to them for good.
///
///         Reads the same packed stores as test/DeployKilim.t.sol; without them the file read fails.
contract MainnetAcceptsAnyPackedStoreTest is TestBase {
    VmPoc internal constant vmp = VmPoc(address(uint160(uint256(keccak256("hevm cheat code")))));
    string internal constant GLYPH_STORE = "../onchain/build-glyphs";
    string internal constant PAGE_STORE = "../onchain/build-page";
    string internal constant PLACEHOLDER_STILL = "../onchain/test/fixtures/still-placeholder.png";
    /// orkhanart.eth: the only deployer, treasury and royalty receiver the script accepts on chain 1.
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;

    DeployKilim internal script;

    function setUp() public {
        script = new DeployKilim();
        vm.warp(1_800_000_000);
    }

    /// @dev Exactly what a signed-off mainnet config would carry: every launch value, the artist's
    ///      wallet at its real nonce, a one-day inspection window, and the texts the stores were
    ///      packed with. The store directories are the ones package.json and both templates point at.
    function _launchConfig() internal view returns (DeployKilim.Config memory c) {
        c.chainId = 1;
        c.deployer = ARTIST;
        c.deployerNonce = vmp.getNonce(ARTIST);
        c.minLeadSeconds = 1 days;
        c.glyphStore = GLYPH_STORE;
        c.pageStore = PAGE_STORE;
        c.auction.treasury = ARTIST;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = script.LAUNCH_DURATION();
        c.auction.extensionWindow = script.LAUNCH_EXTENSION_WINDOW();
        c.auction.incrementBps = script.LAUNCH_INCREMENT_BPS();
        c.auction.reservePrice = script.LAUNCH_RESERVE_PRICE();
        c.auction.maxGlyphsPerBid = script.LAUNCH_MAX_GLYPHS_PER_BID();
        c.glyphCap = script.LAUNCH_GLYPH_CAP();
        string memory g = vmp.readFile(string.concat(GLYPH_STORE, "/manifest.json"));
        string memory pg = vmp.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        c.collectionDescription = vmp.parseJsonString(g, ".description");
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = vmp.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmp.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmp.parseJsonString(pg, ".externalUrl");
    }

    /// @dev Both phases on chain 1 with the launch config and today's stores: nothing is refused, the
    ///      deployed PREFIX chunk carries the placeholder PNG, and the minted 1/1 answers the stand-in's
    ///      golden. Every refusal the script knows fires on something else (chain, nonce, window, the
    ///      auction numbers, the name, manifest self-consistency); none compares the store with the
    ///      final work.
    function testMainnetDeploysTheStandInPageAndThePlaceholderStill() public {
        vmp.chainId(1);
        DeployKilim.Config memory c = _launchConfig();
        script.deployStore(c);
        // The store went up from the same key here, so the published nonce is the one after it.
        c.deployerNonce = vmp.getNonce(ARTIST);
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(d.oneOfOne.name(), "The Unwoven Kilim");
        assertEq(d.auction.treasury(), ARTIST);

        // What the chain now holds, by the packer's own record of what it packed.
        string memory pg = vmp.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        assertEq(vmp.parseJsonString(pg, ".artwork.file"), "lean.html");
        assertEq(vmp.parseJsonString(pg, ".still.file"), "still-placeholder.png");
        assertEq(vmp.parseJsonUint(pg, ".still.size"), 161);
        assertEq(vmp.parseJsonString(pg, ".externalUrl"), "");

        // The placeholder, base64, sits inside the PREFIX chunk the 1/1 points at: code, so immutable.
        bytes memory png = vmp.readFileBinary(PLACEHOLDER_STILL);
        assertEq(png.length, 161);
        address[] memory prefix = d.oneOfOne.prefixChunks();
        assertEq(prefix.length, 1);
        bytes memory stored = prefix[0].code; // 0x00 || PREFIX
        assertTrue(_contains(stored, bytes(Base64.encode(png)))); // the placeholder PNG is in PREFIX
        assertTrue(_contains(stored, bytes('"image":"data:image/png;base64,')));

        // Mint the 1/1 as the auction would at settlement: its only answer is the stand-in's golden.
        vmp.prank(address(d.auction));
        d.oneOfOne.mint(ALICE);
        assertEq(sha256(bytes(d.oneOfOne.tokenURI(1))), vmp.parseJsonBytes32(pg, ".golden.tokenURI.sha256"));
    }

    /// @dev The mainnet template carries no expected content hash of any kind: only the two store
    ///      directories and the texts. The script's Config struct has the same shape (see loadConfig).
    function testTheMainnetTemplateNamesNoExpectedContentHash() public view {
        string memory j = vmp.readFile("deploy/mainnet.example.json");
        assertTrue(vmp.keyExistsJson(j, ".glyphStore"));
        assertTrue(vmp.keyExistsJson(j, ".pageStore"));
        assertTrue(!vmp.keyExistsJson(j, ".expectedHashes"));
        assertTrue(!vmp.keyExistsJson(j, ".gridsHash"));
        assertTrue(!vmp.keyExistsJson(j, ".namesHash"));
        assertTrue(!vmp.keyExistsJson(j, ".prefixHash"));
        assertTrue(!vmp.keyExistsJson(j, ".headHash"));
        assertTrue(!vmp.keyExistsJson(j, ".tailHash"));
        assertTrue(!vmp.keyExistsJson(j, ".oneOfOne.artworkSha256"));
        assertTrue(!vmp.keyExistsJson(j, ".oneOfOne.stillSha256"));
    }

    /// @dev Naive substring search; the haystack here is the 394-byte PREFIX chunk.
    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 k; k < needle.length; ++k) {
                if (hay[i + k] != needle[k]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
