// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";

interface VmBazaarDeploy {
    function readFile(string calldata) external view returns (string memory);
    function envString(string calldata) external view returns (string memory);
    function envOr(string calldata, address) external view returns (address);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonStringArray(string calldata, string calldata) external pure returns (string[] memory);
    function parseJsonUintArray(string calldata, string calldata) external pure returns (uint256[] memory);
    function keyExistsJson(string calldata, string calldata) external view returns (bool);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function startPrank(address) external;
    function stopPrank() external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function toString(uint256) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
    function toString(bytes32) external pure returns (string memory);
}

/// @title DeployKilimBazaar
/// @notice Deploys Kilim Bazaar against an auction that already exists, in one creation, and refuses before
///         sending anything if a check fails. The contract has no owner and no setting: nothing follows the
///         creation, and the deployer gets no role.
///
///         The config is the JSON file named by $KILIM_DEPLOY_CONFIG (the same files as DeployKilim), read
///         from its top-level `chainId` and `pageStore` and a `bazaar` block:
///           "bazaar": {"auction": "0x…", "royaltyReceiver": "0x…", "pageTailHash": "0x…",
///                      "description": "…", "externalUrl": "…", "imageBase": "…",
///                      "pageRanks": {"names": ["Apprentice", …, "The Master"], "costs": [10, 30, 100, 300, 1000]},
///                      "motifs": "0x…", "oneOfOne": "0x…"}          (motifs and oneOfOne optional)
///         $KILIM_BAZAAR_AUCTION may name the auction instead; when both do, they must agree.
///
///         It refuses: the wrong chain; an auction without code; an auction, motif collection and 1/1 that do
///         not belong together, or that differ from the config's; a pageTailHash other than the chain's 1/1's
///         or the page store manifest's; a text the token's data: URL cannot carry, or one with the words the
///         project dropped (make, woven, in any case; "unwoven" passes); an imageBase or externalUrl that is
///         not a URL base (https://, ipfs:// or ar://, no space, ending in "/" or "=": the token id is
///         appended to it for ever); a zero royalty receiver; a pageRanks block that is not six names and five
///         costs, and on mainnet and Sepolia a missing one. On Ethereum mainnet (chain 1) also: a sender other
///         than orkhanart.eth or one with code, a royalty receiver other than orkhanart.eth, an empty
///         imageBase (the artist's ruling: marketplaces show each kilim's own opening frame), and a missing
///         page store. After the dry run it refuses a deployment over the gas policy, a runtime over 24,576
///         bytes, any immutable that reads back wrong, rank names or costs other than the config's pageRanks,
///         and, on mainnet and Sepolia, a seed window other than 8,191 (the EIP-2935 history contract).
///
///         pageRanks is the stored page's RANKS. The page's artwork is gzipped inside the 1/1's TAIL, which
///         forge cannot open, so onchain/test/kilim-page.test.mjs checks every deploy config's pageRanks
///         against the artwork in that config's page store, and the contract's own names and costs against
///         it too; this script checks the same pageRanks against the contract it deploys. Run both. Before
///         broadcasting, open the printed URLs of kilim 1 (imageBase + "1", externalUrl + "1"): the bases are
///         permanent, and so is their domain's part in every kilim's marketplace picture.
/// @dev forge simulates the whole script before broadcasting, so any revert here means nothing is sent. Send
///      from contracts/:
///        KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DeployKilimBazaar.s.sol \
///          --rpc-url "$SEPOLIA_RPC" --broadcast --slow --sender <wallet> ...
///      Sepolia runs Glamsterdam: add --skip-simulation --gas-estimate-multiplier 120 there.
contract DeployKilimBazaar {
    VmBazaarDeploy internal constant vm =
        VmBazaarDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    uint256 public constant MAINNET_CHAIN_ID = 1;
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// @notice orkhanart.eth: the mainnet sender and royalty receiver.
    address public constant LAUNCH_ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    /// @notice Policy ceiling for every transaction, as DeployKilim.MAX_TX_GAS.
    uint256 public constant MAX_TX_GAS = 8_000_000;
    uint256 public constant MAX_RUNTIME = 24_576;

    struct Config {
        uint256 chainId;
        address auction;
        /// @dev Expected addresses, compared with the auction's when nonzero.
        address motifs;
        address oneOfOne;
        address royaltyReceiver;
        bytes32 pageTailHash;
        /// @dev The packed page store (onchain/build-page); its manifest's tailHash must equal pageTailHash.
        ///      "" skips that comparison, except on mainnet, where it is required.
        string pageStore;
        string description;
        string externalUrl;
        string imageBase;
        string[] rankNames;
        uint256[] rankCosts;
    }

    error Refused(string reason);

    // ------------------------------------------------------------ entry points

    function run() external returns (KilimBazaar) {
        Config memory c = loadConfig(vm.envString("KILIM_DEPLOY_CONFIG"));
        c.auction = auctionFrom(c.auction, vm.envOr("KILIM_BAZAAR_AUCTION", address(0)));
        return deploy(c, msg.sender);
    }

    function loadConfig(string memory path) public view returns (Config memory) {
        return parseConfig(vm.readFile(path));
    }

    function parseConfig(string memory j) public view returns (Config memory c) {
        c.chainId = vm.parseJsonUint(j, ".chainId");
        if (vm.keyExistsJson(j, ".bazaar.auction")) c.auction = vm.parseJsonAddress(j, ".bazaar.auction");
        if (vm.keyExistsJson(j, ".bazaar.motifs")) c.motifs = vm.parseJsonAddress(j, ".bazaar.motifs");
        if (vm.keyExistsJson(j, ".bazaar.oneOfOne")) c.oneOfOne = vm.parseJsonAddress(j, ".bazaar.oneOfOne");
        c.royaltyReceiver = vm.parseJsonAddress(j, ".bazaar.royaltyReceiver");
        c.pageTailHash = vm.parseJsonBytes32(j, ".bazaar.pageTailHash");
        if (vm.keyExistsJson(j, ".bazaar.pageStore")) {
            c.pageStore = vm.parseJsonString(j, ".bazaar.pageStore");
        } else if (vm.keyExistsJson(j, ".pageStore")) {
            c.pageStore = vm.parseJsonString(j, ".pageStore");
        }
        c.description = vm.parseJsonString(j, ".bazaar.description");
        c.externalUrl = vm.parseJsonString(j, ".bazaar.externalUrl");
        c.imageBase = vm.parseJsonString(j, ".bazaar.imageBase");
        if (vm.keyExistsJson(j, ".bazaar.pageRanks")) {
            c.rankNames = vm.parseJsonStringArray(j, ".bazaar.pageRanks.names");
            c.rankCosts = vm.parseJsonUintArray(j, ".bazaar.pageRanks.costs");
        }
    }

    /// @notice The auction to deploy against: the config's, the environment's, or both when they agree.
    function auctionFrom(address fromConfig, address fromEnv) public pure returns (address) {
        if (fromConfig == address(0) && fromEnv == address(0)) {
            revert Refused("no auction: set bazaar.auction");
        }
        if (fromConfig != address(0) && fromEnv != address(0) && fromConfig != fromEnv) {
            revert Refused("the auction from the environment differs from the config");
        }
        return fromConfig != address(0) ? fromConfig : fromEnv;
    }

    /// @notice Check everything, dry-run the creation as `sender` inside a snapshot, then broadcast it.
    function deploy(Config memory c, address sender) public returns (KilimBazaar bazaar) {
        check(c, sender);
        _printSettings(c, sender);

        uint256 snap = vm.snapshotState();
        vm.startPrank(sender);
        uint256 g = gasleft();
        KilimBazaar dry = _create(c);
        g -= gasleft();
        vm.stopPrank();
        uint256 total = g + _intrinsic(bytes.concat(type(KilimBazaar).creationCode, _args(c)));
        _log(string.concat("KilimBazaar deployment gas ", vm.toString(total)));
        if (total > MAX_TX_GAS) revert Refused("deployment gas over the policy");
        _readBack(c, dry);
        _printLadder(dry);
        vm.revertToState(snap);

        vm.startBroadcast(sender);
        bazaar = _create(c);
        vm.stopBroadcast();
        _readBack(c, bazaar);
        _log(string.concat("KilimBazaar    ", vm.toString(address(bazaar))));
    }

    /// @notice Every refusal that can be decided before the creation.
    function check(Config memory c, address sender) public view {
        if (block.chainid != c.chainId) revert Refused("wrong chain");
        if (c.auction.code.length == 0) revert Refused("the auction has no code");
        if (c.royaltyReceiver == address(0)) revert Refused("zero royalty receiver");
        KilimAuction auction = KilimAuction(c.auction);
        KilimMotifs motifs = auction.motifs();
        KilimOneOfOne oneOfOne = auction.oneOfOne();
        if (
            address(motifs).code.length == 0 || address(oneOfOne).code.length == 0
                || motifs.minter() != c.auction || oneOfOne.minter() != c.auction
                || address(oneOfOne.motifs()) != address(motifs)
        ) revert Refused("the auction, motifs and 1/1 do not belong together");
        if (c.motifs != address(0) && c.motifs != address(motifs)) {
            revert Refused("motifs differ from the config");
        }
        if (c.oneOfOne != address(0) && c.oneOfOne != address(oneOfOne)) {
            revert Refused("oneOfOne differs from the config");
        }
        if (oneOfOne.tailHash() != c.pageTailHash) {
            revert Refused("pageTailHash differs from the chain's 1/1");
        }
        if (bytes(c.pageStore).length != 0) {
            string memory manifest = vm.readFile(string.concat(c.pageStore, "/manifest.json"));
            if (vm.parseJsonBytes32(manifest, ".hashes.tailHash") != c.pageTailHash) {
                revert Refused("pageTailHash differs from the page store's manifest");
            }
        }
        _requireText(c.description, "description");
        _requireText(c.externalUrl, "externalUrl");
        _requireText(c.imageBase, "imageBase");
        _requireUrlBase(c.externalUrl, "externalUrl");
        _requireUrlBase(c.imageBase, "imageBase");
        if (c.rankNames.length != 0 || c.rankCosts.length != 0) {
            if (c.rankNames.length != 6 || c.rankCosts.length != 5) {
                revert Refused("bazaar.pageRanks: six names and five costs");
            }
        } else if (block.chainid == MAINNET_CHAIN_ID || block.chainid == SEPOLIA_CHAIN_ID) {
            revert Refused("Sepolia and mainnet: bazaar.pageRanks is missing");
        }
        if (block.chainid == MAINNET_CHAIN_ID) {
            if (sender != LAUNCH_ARTIST) revert Refused("mainnet: the sender is not orkhanart.eth");
            if (sender.code.length != 0) revert Refused("mainnet: the sender has code");
            if (c.royaltyReceiver != LAUNCH_ARTIST) revert Refused("mainnet launch value: royaltyReceiver");
            if (bytes(c.imageBase).length == 0) revert Refused("mainnet launch value: imageBase is empty");
            if (bytes(c.pageStore).length == 0) revert Refused("mainnet needs the page store");
        }
    }

    // ------------------------------------------------------------ internals

    function _create(Config memory c) internal returns (KilimBazaar) {
        return new KilimBazaar(
            KilimAuction(c.auction),
            c.royaltyReceiver,
            c.pageTailHash,
            c.description,
            c.externalUrl,
            c.imageBase
        );
    }

    function _args(Config memory c) internal pure returns (bytes memory) {
        return
            abi.encode(
                c.auction, c.royaltyReceiver, c.pageTailHash, c.description, c.externalUrl, c.imageBase
            );
    }

    /// @dev Every immutable and text, read back, must be what was deployed.
    function _readBack(Config memory c, KilimBazaar b) internal view {
        KilimAuction auction = KilimAuction(c.auction);
        if (
            address(b.auction()) != c.auction || address(b.motifs()) != address(auction.motifs())
                || address(b.oneOfOne()) != address(auction.oneOfOne())
                || b.motifPrice() != auction.MOTIF_PRICE()
                || b.motifChainId() != auction.motifs().deploymentChainId()
                || b.royaltyReceiver() != c.royaltyReceiver || !_same(b.description(), c.description)
                || !_same(b.externalUrl(), c.externalUrl) || !_same(b.imageBase(), c.imageBase)
                || b.ROYALTY_BPS() != 750 || b.totalSupply() != 0 || !_same(b.name(), "Kilim Bazaar")
                || !_same(b.symbol(), "KILIM")
        ) revert Refused("bazaar read-back");
        if (address(b).code.length > MAX_RUNTIME) revert Refused("runtime over 24,576 bytes");
        _checkRanks(c, b);
        if (
            (block.chainid == MAINNET_CHAIN_ID || block.chainid == SEPOLIA_CHAIN_ID) && b.seedWindow() != 8191
        ) {
            revert Refused("no EIP-2935 history contract: the seed window would be 256");
        }
    }

    /// @dev The three texts travel raw in the token's data: URL: printable ASCII without `"`, `\`, `#` or `%`
    ///      (the contract refuses those too), and without the words the project dropped, in any case and
    ///      inside other words: no "weav" anywhere, and no "woven" but in "unwoven" (The Unwoven Kilim).
    function _requireText(string memory text, string memory what) internal pure {
        bytes memory b = bytes(text);
        bytes memory lower = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch < 0x20 || ch > 0x7e || ch == '"' || ch == "\\" || ch == "#" || ch == "%") {
                revert Refused(string.concat(what, ": a character the data: URL cannot carry"));
            }
            lower[i] = ch >= "A" && ch <= "Z" ? bytes1(uint8(ch) + 32) : ch;
        }
        if (_has(lower, "weav") || _hasWovenNotUnwoven(lower)) {
            revert Refused(string.concat(what, ": the words weave and woven are dropped"));
        }
    }

    /// @dev imageBase and externalUrl get the token id appended as they are, for ever (no setter): so a
    ///      non-empty one must be a URL base, with a scheme marketplaces load (https://, or ipfs:// or ar:// for
    ///      pinned frames), no space, and a trailing "/" (or "=" for a query) before the id.
    function _requireUrlBase(string memory url, string memory what) internal pure {
        bytes memory b = bytes(url);
        if (b.length == 0) return;
        if (_has(b, " ")) revert Refused(string.concat(what, ": a URL base cannot carry a space"));
        if (!_startsWith(b, "https://") && !_startsWith(b, "ipfs://") && !_startsWith(b, "ar://")) {
            revert Refused(string.concat(what, ": a URL base must start with https://, ipfs:// or ar://"));
        }
        bytes1 last = b[b.length - 1];
        if (last != "/" && last != "=") {
            revert Refused(string.concat(what, ": a URL base must end with / or ="));
        }
    }

    /// @dev The stored page's ranks as the config names them (bazaar.pageRanks, six names and five costs)
    ///      must be this contract's: the names exactly as rankName returns them (the trait form, "The Master"),
    ///      and the costs as ladder() shows them. Once the auction is settled ladder() hides the ranks the
    ///      Master undercuts, and the page drops the same ones (bazaar.js readPiece keeps a cost under top),
    ///      so a hidden rank only needs a page cost of at least top. onchain/test/kilim-page.test.mjs checks
    ///      the same config against the stored artwork's RANKS.
    function _checkRanks(Config memory c, KilimBazaar b) internal view {
        if (c.rankNames.length == 0) return;
        for (uint256 r = 1; r <= 6; ++r) {
            if (!_same(b.rankName(r), c.rankNames[r - 1])) {
                revert Refused("bazaar.pageRanks: the names differ from the contract's");
            }
        }
        (uint256[6] memory costs, bool open) = b.ladder();
        for (uint256 i; i < 5; ++i) {
            bool hidden = open && costs[i] == 0;
            if (hidden ? c.rankCosts[i] < costs[5] : c.rankCosts[i] != costs[i]) {
                revert Refused("bazaar.pageRanks: the costs differ from the contract's");
            }
        }
    }

    function _hasWovenNotUnwoven(bytes memory lower) internal pure returns (bool) {
        bytes memory needle = "woven";
        for (uint256 i; i + needle.length <= lower.length; ++i) {
            uint256 j;
            while (j < needle.length && lower[i + j] == needle[j]) {
                ++j;
            }
            if (j == needle.length && !(i >= 2 && lower[i - 2] == "u" && lower[i - 1] == "n")) return true;
        }
        return false;
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) {
                ++j;
            }
            if (j == needle.length) return true;
        }
        return false;
    }

    function _startsWith(bytes memory hay, bytes memory prefix) internal pure returns (bool) {
        if (prefix.length > hay.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (hay[i] != prefix[i]) return false;
        }
        return true;
    }

    function _printSettings(Config memory c, address sender) internal view {
        KilimAuction auction = KilimAuction(c.auction);
        _log(string.concat("Kilim Bazaar for chain ", vm.toString(block.chainid)));
        _log(string.concat("  sender            ", vm.toString(sender)));
        _log(string.concat("  auction           ", vm.toString(c.auction)));
        _log(string.concat("  motifs            ", vm.toString(address(auction.motifs()))));
        _log(string.concat("  oneOfOne          ", vm.toString(address(auction.oneOfOne()))));
        _log(
            string.concat(
                "  auction settled   ", auction.settled() ? "yes" : "no (making opens at settlement)"
            )
        );
        _log(string.concat("  royaltyReceiver   ", vm.toString(c.royaltyReceiver), " (7.5%)"));
        _log(string.concat("  pageTailHash      ", vm.toString(c.pageTailHash)));
        _log(
            string.concat(
                "  pageStore         ", bytes(c.pageStore).length == 0 ? "(not compared)" : c.pageStore
            )
        );
        _log(string.concat("  description       ", c.description));
        _log(string.concat("  externalUrl       ", c.externalUrl));
        _log(
            string.concat(
                "  imageBase         ",
                bytes(c.imageBase).length == 0 ? "(empty: the title motif's drawing)" : c.imageBase
            )
        );
        // The bases get the token id appended as they are: open these before broadcasting.
        if (bytes(c.imageBase).length != 0) _log(string.concat("  kilim 1's image   ", c.imageBase, "1"));
        if (bytes(c.externalUrl).length != 0) {
            _log(string.concat("  kilim 1's link    ", c.externalUrl, "1"));
        }
        _log(
            string.concat(
                "  pageRanks         ",
                c.rankNames.length == 0
                    ? "(not named: not compared)"
                    : "compared with the contract after the dry run"
            )
        );
    }

    function _printLadder(KilimBazaar b) internal view {
        (uint256[6] memory costs, bool open) = b.ladder();
        string memory line = "  ranks             ";
        for (uint256 r = 1; r <= 6; ++r) {
            string memory cost = r == 6
                ? (open ? vm.toString(costs[5]) : "the winning bid")
                : (costs[r - 1] == 0 ? "(undercut by the Master)" : vm.toString(costs[r - 1]));
            line = string.concat(line, r == 1 ? "" : ", ", b.rankName(r), " ", cost);
        }
        _log(line);
        _log(string.concat("  seedWindow        ", vm.toString(b.seedWindow())));
        _log(string.concat("  runtime bytes     ", vm.toString(address(b).code.length)));
    }

    /// @dev Transaction base cost for `data` sent as a creation, beyond CREATE's 32,000 that the measured
    ///      `new` already paid: 21,000 + calldata + initcode words.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000 + 2 * ((data.length + 31) / 32);
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev forge's console.log(string), called low-level: the console address has no code.
    function _log(string memory text) internal view {
        (bool ok,) = CONSOLE.staticcall(abi.encodeWithSignature("log(string)", text));
        ok; // logging is best effort
    }
}
