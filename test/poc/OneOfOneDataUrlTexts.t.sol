// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimGlyphs} from "../../src/KilimGlyphs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

/// @notice Review PoC (packers lens, skeptic): the 1/1's tokenURI is `data:application/json;utf8,`
///         followed by PREFIX raw. The contract copies PREFIX byte for byte and never inspects it, so
///         a `#` or a `%XX` in the name, description or external_url reaches the URL unescaped. A
///         consumer that treats the answer as a URL (WHATWG fetch, every browser, Node) ends the
///         document at the first `#` and percent-decodes `%XX`; the checks that run before deployment
///         (the golden hash, and parsing the body after the scheme) see the untruncated bytes and pass.
///         The packer's data_url_text() is the only guard; this shows what it guards against.
contract OneOfOneDataUrlTextsTest is TestBase {
    /// @dev PREFIX as a packer that only JSON-escapes would write it for these texts.
    string internal constant PREFIX_WITH_HASH_AND_PERCENT =
        '{"name":"Kilim #1","description":"100%ab wool","external_url":"https://kilim.art/#unwoven","image":"data:image/png;base64,iVBORw0KGgo=","animation_url":"data:text/html;base64,';
    uint256 internal constant SCHEME = 27;

    function testHashAndPercentTravelRawAndAFragmentAwareReaderKeepsAnOpenString() public {
        KilimGlyphs glyphs = newGlyphs(address(this), TREASURY, GLYPH_CAP);
        KilimOneOfOne.Page memory page = pageFrom(
            bytes(PREFIX_WITH_HASH_AND_PERCENT), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST)))
        );
        // The constructor stores the texts next to PREFIX and checks neither for URL-unsafe characters.
        KilimOneOfOne nft = new KilimOneOfOne(
            address(this), TREASURY, glyphs, page, "Kilim #1", "100%ab wool", "https://kilim.art/#unwoven"
        );
        nft.mint(ALICE);
        bytes memory uri = bytes(nft.tokenURI(1));

        // PREFIX is in the answer unchanged, right after the 27-byte scheme.
        bytes memory prefix = bytes(PREFIX_WITH_HASH_AND_PERCENT);
        assertEq(keccak256(_slice(uri, SCHEME, prefix.length)), keccak256(prefix));

        // The first `#` of the URL comes before "animation_url": a fragment-aware reader never sees the
        // image, the page or the closing brace. What it keeps is an open JSON string.
        uint256 hash = _indexOf(uri, "#", SCHEME);
        uint256 anim = _indexOf(uri, "animation_url", SCHEME);
        assertTrue(hash < anim);
        bytes memory kept = _slice(uri, SCHEME, hash - SCHEME);
        assertEq(string(kept), '{"name":"Kilim ');

        // `%ab` is two hex digits after a percent sign: a percent-decoding reader replaces the three
        // characters with the byte 0xAB, which is not UTF-8, inside the description.
        uint256 pct = _indexOf(uri, "%ab", SCHEME);
        assertTrue(pct < anim);

        // The pre-deployment checks look at the bytes, not at the URL: the body after the scheme is
        // valid JSON with the expected name, which is exactly how test/KilimOneOfOne.t.sol and
        // onchain/test/page.test.mjs read it, and the golden hash would match this answer too.
        bytes memory body = _slice(uri, SCHEME, uri.length - SCHEME);
        assertEq(vm.parseJsonString(string(body), ".name"), "Kilim #1");
        assertEq(vm.parseJsonString(string(body), ".description"), "100%ab wool");
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

    /// @dev The first offset at or after `from` where `needle` occurs; reverts if there is none.
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
