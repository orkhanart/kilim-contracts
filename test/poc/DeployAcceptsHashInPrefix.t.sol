// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {TestBase} from "../TestBase.sol";

interface VmPocPrefix {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function getNonce(address) external view returns (uint64);
    function prank(address) external;
}

/// @notice Review PoC (oneofone finding, skeptic): the deploy script checks the page store against its
///         own manifest (chunk sizes, keccaks, CREATE2 addresses, section hashes, the golden tokenURI
///         sha256) and the texts against the config, but never looks at what the PREFIX bytes are. A
///         store whose PREFIX carries `#` and `%` with a manifest recomputed from those bytes passes
///         both phases, and the 1/1 then answers a URL that a WHATWG reader cuts at the `#`.
///
///         The packer refuses these texts (pack_page.data_url_text), so this store is the hand-edited
///         one that contracts/test/poc/hand-edited-page-store.py writes; run it first.
contract DeployAcceptsHashInPrefixTest is TestBase {
    VmPocPrefix internal constant vmp = VmPocPrefix(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEPLOYER = address(0xD3910);
    string internal constant GLYPH_STORE = "../onchain/build-glyphs";
    string internal constant PAGE_STORE = "../onchain/test/fixtures/poc-hash-in-prefix";
    uint256 internal constant SCHEME = 27;

    DeployKilim internal script;

    function setUp() public {
        script = new DeployKilim();
        vm.warp(1_800_000_000);
    }

    function _config() internal view returns (DeployKilim.Config memory c) {
        c.chainId = block.chainid;
        c.deployer = DEPLOYER;
        c.deployerNonce = vmp.getNonce(DEPLOYER);
        c.minLeadSeconds = 1 days;
        c.glyphStore = GLYPH_STORE;
        c.pageStore = PAGE_STORE;
        c.auction.treasury = TREASURY;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = 24 hours;
        c.auction.extensionWindow = 10 minutes;
        c.auction.incrementBps = 1000;
        c.auction.reservePrice = RESERVE;
        c.auction.maxGlyphsPerBid = 1_000_000;
        c.glyphCap = 1_000_000;
        string memory g = vmp.readFile(string.concat(GLYPH_STORE, "/manifest.json"));
        string memory pg = vmp.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        c.collectionDescription = vmp.parseJsonString(g, ".description");
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = vmp.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmp.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmp.parseJsonString(pg, ".externalUrl");
    }

    function testBothPhasesAcceptAPrefixWithHashAndPercent() public {
        DeployKilim.Config memory c = _config();
        assertEq(c.oneOfOneName, "Kilim #1");
        assertEq(c.oneOfOneDescription, "100% on-chain");
        script.deployStore(c);
        c = _config(); // the nonce moved with the store
        // deployContracts runs the dry run, _checkContracts and _checkGolden before broadcasting; none refuses.
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(d.oneOfOne.name(), "Kilim #1");

        vmp.prank(address(d.auction));
        d.oneOfOne.mint(ALICE);
        bytes memory uri = bytes(d.oneOfOne.tokenURI(1));
        // The `#` sits in the name, before the image and the page: a fragment-aware reader keeps `{"name":"Kilim `.
        uint256 hash = _indexOf(uri, "#", SCHEME);
        uint256 anim = _indexOf(uri, "animation_url", SCHEME);
        assertTrue(hash < anim);
        assertEq(string(_slice(uri, SCHEME, hash - SCHEME)), '{"name":"Kilim ');
        uint256 pct = _indexOf(uri, "%", SCHEME);
        assertTrue(pct < anim);
    }

    function _slice(bytes memory data, uint256 start, uint256 length)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[start + i];
        }
    }

    function _indexOf(bytes memory data, bytes memory needle, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + needle.length <= data.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (data[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        revert("needle not found");
    }
}
