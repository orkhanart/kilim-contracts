// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title KilimTexts
/// @notice The one hash of every text a person typed that the contracts store for ever: `expected.texts` in a
///         deploy config. Both deploy scripts recompute it from the config and refuse a mismatch, so a text
///         edited after sign-off is caught. scripts/expected.mjs computes the same value.
///
///         The eight texts, in this order and as the config names them:
///           collection.description, collection.externalUrl          (KilimMotifs)
///           oneOfOne.name, oneOfOne.description, oneOfOne.externalUrl (KilimOneOfOne)
///           bazaar.description, bazaar.externalUrl, bazaar.imageBase  (KilimBazaar; "" without a bazaar block)
///         texts = sha256 of, for each text in turn, its byte length as a 32-byte big-endian integer followed by
///         its bytes. The length prefix keeps the encoding unambiguous: no two lists of texts hash alike unless
///         sha256 collides.
library KilimTexts {
    function hash(string[8] memory texts) internal pure returns (bytes32) {
        bytes memory all;
        for (uint256 i; i < texts.length; ++i) {
            all = bytes.concat(all, abi.encodePacked(bytes(texts[i]).length, bytes(texts[i])));
        }
        return sha256(all);
    }
}
