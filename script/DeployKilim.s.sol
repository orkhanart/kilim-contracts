// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimRenderer} from "../src/render/KilimRenderer.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";

interface VmDeploy {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function envString(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonStringArray(string calldata, string calldata) external pure returns (string[] memory);
    function parseJsonUintArray(string calldata, string calldata) external pure returns (uint256[] memory);
    function parseJsonBool(string calldata, string calldata) external pure returns (bool);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function getNonce(address) external view returns (uint64);
    function computeCreateAddress(address, uint256) external pure returns (address);
    function toString(uint256) external pure returns (string memory);
    function toString(bytes32) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title DeployKilim
/// @notice Deploys Kilim in the published order, and refuses before sending anything if a check fails:
///           1. runStore():   the STORE chunks through the deterministic CREATE2 deployer (any already
///                            deployed is verified and skipped), then KilimRenderer, also by CREATE2.
///                            Prints the addresses and rendererHash to publish.
///           2. runAuction(): KilimAuction, which creates Kilim, from the signed-off config, at the
///                            published deployer nonce. Prints every setting it deploys with.
///         `run()` does both (testnet rehearsal). The config is a JSON file named by $KILIM_DEPLOY_CONFIG;
///         see deploy/mainnet.example.json, deploy/sepolia.example.json and docs/RENDERER.md.
///         On Ethereum mainnet (chain 1) the auction settings must be the decided launch values below,
///         the published nonce is always checked and the inspection window must be nonzero. Other chains
///         (the Sepolia rehearsal, the local chain) accept any valid settings and print each one next to
///         the launch value it differs from.
/// @dev forge simulates the whole script before broadcasting, so any revert here means nothing is sent.
///      Every heavy step is first dry-run inside a state snapshot to measure its gas and check its output.
contract DeployKilim {
    VmDeploy internal constant vm = VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = bytes32(0);
    uint256 public constant CHUNK = 24_575;
    /// @notice Policy ceiling for every transaction, well under the 16,777,216 per-transaction cap.
    uint256 public constant MAX_TX_GAS = 8_000_000;
    /// @notice No start date further out than this is accepted.
    uint256 public constant MAX_LEAD = 365 days;
    /// @notice A `deployerNonce` of this value skips the published-nonce check. Refused on chain 1.
    uint256 public constant NO_NONCE_CHECK = type(uint256).max;

    // The decided launch settings (checklists/1-pre-deploy.md). On chain 1 any other value is refused.
    uint256 public constant MAINNET_CHAIN_ID = 1;
    /// @notice Native ETH on Ethereum mainnet, 18 decimals.
    address public constant LAUNCH_PAYMENT_TOKEN = address(0);
    uint8 public constant LAUNCH_TOKEN_DECIMALS = 18;
    /// @notice orkhanart.eth: the treasury, royalty receiver and collection-page owner.
    address public constant LAUNCH_TREASURY = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    address public constant LAUNCH_COLLECTION_OWNER = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    /// @notice The 100th registration places the 0.01 ETH opening bid.
    uint256 public constant LAUNCH_RESERVE_PRICE = 0.01 ether;
    /// @notice Each raise at least +10%.
    uint16 public constant LAUNCH_INCREMENT_BPS = 1000;
    /// @notice 24 hours from the first bid.
    uint64 public constant LAUNCH_DURATION = 86_400;
    /// @notice A bid in the last 10 minutes moves the close to 10 minutes after it, with no limit.
    uint64 public constant LAUNCH_EXTENSION_WINDOW = 600;
    uint256 public constant LAUNCH_SYMBOL_CAP = 1_000_000;
    uint256 public constant LAUNCH_MAX_SYMBOLS_PER_BID = 1_000_000;
    uint16 public constant LAUNCH_MAX_CELLS = 256;

    struct Config {
        uint256 chainId;
        string store;
        address deployer;
        /// @dev The published nonce for the auction deployment. NO_NONCE_CHECK skips the check, except on
        ///      chain 1, where it is refused.
        uint256 deployerNonce;
        uint256 motifCount;
        bytes32 geometryHash;
        bytes32 indexHash;
        bytes32 pageHash;
        /// @dev Zero until the renderer is deployed and its hash published; required by the auction phase.
        bytes32 rendererHash;
        uint8 tokenDecimals;
        /// @dev The inspection window: `startsAt` must be at least this many seconds after deployment.
        ///      Must be nonzero on chain 1.
        uint256 minLeadSeconds;
        KilimAuction.Config auction;
    }

    struct Store {
        string manifest;
        string golden;
        bytes[] chunks;
        address[] addresses;
    }

    error Refused(string reason);

    // ------------------------------------------------------------ entry points

    /// @notice One-shot deploy for local and Sepolia. Refused on mainnet, where rendererHash must be
    ///         published before the auction is deployed: use runStore, publish, then runAuction.
    function run() external {
        if (block.chainid == MAINNET_CHAIN_ID) {
            revert Refused("run() is not for mainnet: use runStore then runAuction");
        }
        Config memory c = loadConfig(vm.envString("KILIM_DEPLOY_CONFIG"));
        KilimRenderer renderer = deployStore(c);
        if (c.rendererHash == bytes32(0)) c.rendererHash = address(renderer).codehash;
        deployAuction(c, renderer);
    }

    function runStore() external {
        deployStore(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")));
    }

    function runAuction() external {
        Config memory c = loadConfig(vm.envString("KILIM_DEPLOY_CONFIG"));
        (address renderer,) = _predictRenderer(c, _loadStore(c));
        deployAuction(c, KilimRenderer(renderer));
    }

    function loadConfig(string memory path) public view returns (Config memory c) {
        string memory j = vm.readFile(path);
        c.chainId = vm.parseJsonUint(j, ".chainId");
        c.store = vm.parseJsonString(j, ".store");
        c.deployer = vm.parseJsonAddress(j, ".deployer");
        c.deployerNonce = vm.parseJsonUint(j, ".deployerNonce");
        c.motifCount = vm.parseJsonUint(j, ".expected.motifCount");
        c.geometryHash = vm.parseJsonBytes32(j, ".expected.geometryHash");
        c.indexHash = vm.parseJsonBytes32(j, ".expected.indexHash");
        c.pageHash = vm.parseJsonBytes32(j, ".expected.pageHash");
        c.rendererHash = vm.parseJsonBytes32(j, ".expected.rendererHash");
        c.tokenDecimals = uint8(vm.parseJsonUint(j, ".auction.tokenDecimals"));
        c.minLeadSeconds = vm.parseJsonUint(j, ".minLeadSeconds");
        c.auction.paymentToken = vm.parseJsonAddress(j, ".auction.paymentToken");
        c.auction.treasury = vm.parseJsonAddress(j, ".auction.treasury");
        c.auction.collectionOwner = vm.parseJsonAddress(j, ".auction.collectionOwner");
        c.auction.startsAt = uint64(vm.parseJsonUint(j, ".auction.startsAt"));
        c.auction.duration = uint64(vm.parseJsonUint(j, ".auction.duration"));
        c.auction.extensionWindow = uint64(vm.parseJsonUint(j, ".auction.extensionWindow"));
        c.auction.incrementBps = uint16(vm.parseJsonUint(j, ".auction.incrementBps"));
        c.auction.reservePrice = vm.parseJsonUint(j, ".auction.reservePrice");
        c.auction.symbolCap = vm.parseJsonUint(j, ".auction.symbolCap");
        c.auction.maxSymbolsPerBid = vm.parseJsonUint(j, ".auction.maxSymbolsPerBid");
        c.auction.maxCells = uint16(vm.parseJsonUint(j, ".auction.maxCells"));
    }

    // ------------------------------------------------------------ phase 1: chunks and renderer

    /// @notice Verify the packed store, then deploy whatever of it is missing, then the renderer.
    function deployStore(Config memory c) public returns (KilimRenderer renderer) {
        _requireChain(c);
        Store memory s = _loadStore(c);
        (address predicted, bytes memory initcode) = _predictRenderer(c, s);

        // Dry run: measure every transaction and check the renderer's answers against the golden file.
        uint256 snap = vm.snapshotState();
        bool[] memory missing = new bool[](s.chunks.length);
        for (uint256 k; k < s.chunks.length; ++k) {
            missing[k] = s.addresses[k].code.length == 0;
            if (missing[k]) _create2(_sstore2(s.chunks[k]), s.addresses[k], "chunk");
        }
        // A renderer already at `predicted` came from this same initcode (CREATE2 commits to it), so it is
        // not compared with anything here: it goes through the same immutables, chunk-list and golden checks
        // as a fresh one, and below its code hash must equal a published rendererHash.
        if (predicted.code.length == 0) _create2(initcode, predicted, "renderer");
        bytes32 codehash = predicted.codehash;
        _checkRenderer(c, s, KilimRenderer(predicted));
        vm.revertToState(snap);

        if (c.rendererHash != bytes32(0) && c.rendererHash != codehash) {
            revert Refused("renderer code hash differs from the published rendererHash");
        }

        vm.startBroadcast(c.deployer);
        for (uint256 k; k < s.chunks.length; ++k) {
            if (missing[k]) _create2(_sstore2(s.chunks[k]), s.addresses[k], "chunk");
        }
        if (predicted.code.length == 0) _create2(initcode, predicted, "renderer");
        vm.stopBroadcast();

        renderer = KilimRenderer(predicted);
        _checkRenderer(c, s, renderer);
        _log(string.concat("KilimRenderer ", vm.toString(predicted)));
        _log(string.concat("rendererHash  ", vm.toString(address(renderer).codehash)));
        for (uint256 k; k < s.addresses.length; ++k) {
            _log(string.concat("chunk ", vm.toString(k), "       ", vm.toString(s.addresses[k])));
        }
    }

    function _loadStore(Config memory c) internal view returns (Store memory s) {
        s.manifest = vm.readFile(string.concat(c.store, "/manifest.json"));
        s.golden = vm.readFile(string.concat(c.store, "/golden.json"));
        if (vm.parseJsonUint(s.manifest, ".motifCount") != c.motifCount) {
            revert Refused("motif count differs");
        }
        if (vm.parseJsonBytes32(s.manifest, ".hashes.geometryHash") != c.geometryHash) {
            revert Refused("manifest geometryHash differs from the config");
        }
        if (vm.parseJsonBytes32(s.manifest, ".hashes.indexHash") != c.indexHash) {
            revert Refused("indexHash differs");
        }
        if (vm.parseJsonBytes32(s.manifest, ".hashes.pageHash") != c.pageHash) {
            revert Refused("pageHash differs");
        }
        if (vm.parseJsonAddress(s.manifest, ".create2.deployer") != CREATE2_DEPLOYER) {
            revert Refused("deployer");
        }
        string[] memory files = vm.parseJsonStringArray(s.manifest, ".chunkFiles");
        if (files.length == 0) revert Refused("no chunks");
        s.chunks = new bytes[](files.length);
        s.addresses = new address[](files.length);
        bytes memory store;
        for (uint256 k; k < files.length; ++k) {
            bytes memory data = vm.readFileBinary(string.concat(c.store, "/", files[k]));
            string memory key = string.concat(".chunks[", vm.toString(k), "]");
            if (data.length != vm.parseJsonUint(s.manifest, string.concat(key, ".size"))) {
                revert Refused("chunk size");
            }
            if (keccak256(data) != vm.parseJsonBytes32(s.manifest, string.concat(key, ".keccak"))) {
                revert Refused("chunk hash");
            }
            if (data.length == 0 || data.length > CHUNK || (k + 1 < files.length && data.length != CHUNK)) {
                revert Refused("chunk layout");
            }
            s.chunks[k] = data;
            s.addresses[k] = _predict(_sstore2(data));
            if (s.addresses[k] != vm.parseJsonAddress(s.manifest, string.concat(key, ".create2"))) {
                revert Refused("chunk CREATE2 address");
            }
            address a = s.addresses[k];
            if (a.code.length != 0 && keccak256(a.code) != keccak256(bytes.concat(hex"00", data))) {
                revert Refused("foreign code at a chunk address");
            }
            store = bytes.concat(store, data);
        }
        _checkSections(c, store);
    }

    /// @dev Recompute the three published hashes from the exact bytes that will be deployed.
    function _checkSections(Config memory c, bytes memory store) internal pure {
        uint256 g = _u32(store, 4);
        uint256 i = _u32(store, 8);
        uint256 p = _u32(store, 12);
        if (64 + g + i + p != store.length) revert Refused("store sections do not add up");
        if (keccak256(_slice(store, 64, 64 + g)) != c.geometryHash) revert Refused("geometry bytes");
        if (keccak256(_slice(store, 64 + g, 64 + g + i)) != c.indexHash) revert Refused("index bytes");
        if (keccak256(_slice(store, 64 + g + i, 64 + g + i + p)) != c.pageHash) revert Refused("page bytes");
    }

    function _predictRenderer(Config memory c, Store memory s)
        internal
        pure
        returns (address predicted, bytes memory initcode)
    {
        initcode = bytes.concat(
            type(KilimRenderer).creationCode, abi.encode(s.addresses, c.geometryHash, c.indexHash, c.pageHash)
        );
        predicted = _predict(initcode);
    }

    /// @dev The renderer must describe the published store and give the golden answers.
    function _checkRenderer(Config memory c, Store memory s, KilimRenderer r) internal view {
        if (
            r.motifCount() != c.motifCount || r.geometryHash() != c.geometryHash
                || r.indexHash() != c.indexHash || r.pageHash() != c.pageHash
        ) revert Refused("renderer immutables");
        address[] memory chunks = r.chunks();
        for (uint256 j; j < chunks.length; ++j) {
            if (chunks[j] != s.addresses[j]) revert Refused("renderer chunk list");
        }
        if (sha256(bytes(r.masterpieceURI())) != vm.parseJsonBytes32(s.golden, ".masterpieceURI")) {
            revert Refused("1/1 differs from golden");
        }
        string memory k = ".symbolURICases[0]";
        string memory uri = r.symbolURI(
            vm.parseJsonUint(s.golden, string.concat(k, ".tokenId")),
            vm.parseJsonBytes32(s.golden, string.concat(k, ".seed")),
            uint16(vm.parseJsonUint(s.golden, string.concat(k, ".motif"))),
            uint8(vm.parseJsonUint(s.golden, string.concat(k, ".material")))
        );
        if (sha256(bytes(uri)) != vm.parseJsonBytes32(s.golden, string.concat(k, ".sha256"))) {
            revert Refused("symbol differs from golden");
        }
        if (
            sha256(bytes(_goldenArtwork(s.golden, r)))
                != vm.parseJsonBytes32(s.golden, ".artworkURICases[0].sha256")
        ) {
            revert Refused("artwork differs from golden");
        }
    }

    /// @dev The renderer's answer for the first golden artwork URI case.
    function _goldenArtwork(string memory golden, KilimRenderer r) internal view returns (string memory) {
        string memory k = string.concat(
            ".artworkCases[", vm.toString(vm.parseJsonUint(golden, ".artworkURICases[0].case")), "]"
        );
        uint256[] memory raw = vm.parseJsonUintArray(golden, string.concat(k, ".motifs"));
        uint16[] memory motifs = new uint16[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            motifs[i] = uint16(raw[i]);
        }
        return r.artworkURI(
            vm.parseJsonUint(golden, ".artworkURICases[0].number"),
            motifs,
            uint16(vm.parseJsonUint(golden, string.concat(k, ".cols"))),
            uint16(vm.parseJsonUint(golden, string.concat(k, ".rows"))),
            vm.parseJsonBytes32(golden, string.concat(k, ".appearance")),
            uint64(vm.parseJsonUint(golden, ".artworkURICases[0].revision")),
            vm.parseJsonBool(golden, ".artworkURICases[0].frozen")
        );
    }

    // ------------------------------------------------------------ phase 2: the auction

    /// @notice Deploy KilimAuction (and with it Kilim) against the deployed renderer.
    function deployAuction(Config memory c, KilimRenderer renderer) public returns (KilimAuction auction) {
        _requireChain(c);
        _printSettings(c, renderer);
        _requireLaunchSettings(c);
        if (address(renderer).code.length == 0) revert Refused("renderer not deployed");
        if (c.rendererHash == bytes32(0)) revert Refused("publish rendererHash in the config first");
        if (address(renderer).codehash != c.rendererHash) revert Refused("renderer code hash differs");
        if (renderer.motifCount() != c.motifCount || renderer.geometryHash() != c.geometryHash) {
            revert Refused("renderer describes other geometry");
        }
        KilimAuction.Config memory a = c.auction;
        a.motifCount = uint16(c.motifCount);
        a.geometryHash = c.geometryHash;
        a.rendererHash = c.rendererHash;
        a.renderer = address(renderer);
        if (a.paymentToken == address(0)) {
            if (c.tokenDecimals != 18) revert Refused("token decimals");
        } else {
            if (a.paymentToken.code.length == 0) revert Refused("payment token has no code");
            if (IERC20Decimals(a.paymentToken).decimals() != c.tokenDecimals) {
                revert Refused("token decimals");
            }
        }
        uint256 unit = a.paymentToken == address(0) ? 0.001 ether : 10 ** c.tokenDecimals;
        if (a.reservePrice == 0 || a.reservePrice % unit != 0) {
            revert Refused("reserve price");
        }
        if (a.startsAt < block.timestamp + c.minLeadSeconds || a.startsAt > block.timestamp + MAX_LEAD) {
            revert Refused("startsAt outside the inspection window");
        }
        if (a.treasury == address(0) || a.collectionOwner == address(0)) revert Refused("zero address");
        uint256 nonce = vm.getNonce(c.deployer);
        if (c.deployerNonce != NO_NONCE_CHECK && nonce != c.deployerNonce) {
            revert Refused("deployer nonce");
        }
        address predicted = vm.computeCreateAddress(c.deployer, nonce);

        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        KilimAuction dry = new KilimAuction(a);
        g -= gasleft();
        g += _intrinsic(bytes.concat(type(KilimAuction).creationCode, abi.encode(a)));
        if (g > MAX_TX_GAS) revert Refused("auction deployment gas");
        _checkAuction(c, a, dry);
        vm.revertToState(snap);

        vm.startBroadcast(c.deployer);
        auction = new KilimAuction(a);
        vm.stopBroadcast();
        if (address(auction) != predicted) revert Refused("auction address differs from the prediction");
        _checkAuction(c, a, auction);
        _log(string.concat("KilimAuction  ", vm.toString(address(auction))));
        _log(string.concat("Kilim         ", vm.toString(address(auction.collection()))));
        _log(string.concat("deploy gas    ", vm.toString(g)));
    }

    function _checkAuction(Config memory c, KilimAuction.Config memory a, KilimAuction auction)
        internal
        view
    {
        Kilim k = auction.collection();
        if (
            address(auction.paymentToken()) != a.paymentToken || auction.treasury() != a.treasury
                || auction.startsAt() != a.startsAt || auction.duration() != a.duration
                || auction.extensionWindow() != a.extensionWindow || auction.incrementBps() != a.incrementBps
                || auction.reservePrice() != a.reservePrice || auction.symbolCap() != a.symbolCap
                || auction.maxSymbolsPerBid() != a.maxSymbolsPerBid || auction.endsAt() != 0
        ) revert Refused("auction read-back");
        if (
            k.minter() != address(auction) || k.owner() != a.collectionOwner
                || k.royaltyReceiver() != a.treasury || k.symbolCap() != a.symbolCap
                || k.motifCount() != c.motifCount || k.maxCells() != a.maxCells
                || k.geometryHash() != c.geometryHash || k.rendererHash() != c.rendererHash
                || address(k.renderer()) != a.renderer
        ) revert Refused("collection read-back");
    }

    /// @dev Chain 1 only: every auction setting must be the decided launch value, the published nonce is
    ///      always checked, and the inspection window must be nonzero. Other chains stay configurable.
    function _requireLaunchSettings(Config memory c) internal view {
        if (block.chainid != MAINNET_CHAIN_ID) return;
        KilimAuction.Config memory a = c.auction;
        if (a.paymentToken != LAUNCH_PAYMENT_TOKEN) revert Refused("mainnet launch value: paymentToken");
        if (c.tokenDecimals != LAUNCH_TOKEN_DECIMALS) revert Refused("mainnet launch value: tokenDecimals");
        if (a.treasury != LAUNCH_TREASURY) revert Refused("mainnet launch value: treasury");
        if (a.collectionOwner != LAUNCH_COLLECTION_OWNER) {
            revert Refused("mainnet launch value: collectionOwner");
        }
        if (a.reservePrice != LAUNCH_RESERVE_PRICE) revert Refused("mainnet launch value: reservePrice");
        if (a.incrementBps != LAUNCH_INCREMENT_BPS) revert Refused("mainnet launch value: incrementBps");
        if (a.duration != LAUNCH_DURATION) revert Refused("mainnet launch value: duration");
        if (a.extensionWindow != LAUNCH_EXTENSION_WINDOW) {
            revert Refused("mainnet launch value: extensionWindow");
        }
        if (a.symbolCap != LAUNCH_SYMBOL_CAP) revert Refused("mainnet launch value: symbolCap");
        if (a.maxSymbolsPerBid != LAUNCH_MAX_SYMBOLS_PER_BID) {
            revert Refused("mainnet launch value: maxSymbolsPerBid");
        }
        if (a.maxCells != LAUNCH_MAX_CELLS) revert Refused("mainnet launch value: maxCells");
        if (c.deployerNonce == NO_NONCE_CHECK) revert Refused("mainnet needs the published deployerNonce");
        if (c.minLeadSeconds == 0) revert Refused("mainnet needs a nonzero minLeadSeconds");
    }

    /// @dev Prints every setting the auction phase deploys with. A value that differs from the decided
    ///      launch value is flagged; on chain 1 it is then refused. The payment token is compared only on
    ///      chain 1, since each chain has its own USDC address.
    function _printSettings(Config memory c, KilimRenderer renderer) internal view {
        KilimAuction.Config memory a = c.auction;
        bool mainnet = block.chainid == MAINNET_CHAIN_ID;
        _log(string.concat("auction settings for chain ", vm.toString(block.chainid)));
        _log(string.concat("  deployer          ", vm.toString(c.deployer)));
        _log(
            string.concat(
                "  deployerNonce     ",
                c.deployerNonce == NO_NONCE_CHECK ? string("not checked") : vm.toString(c.deployerNonce),
                " (pending: ",
                vm.toString(uint256(vm.getNonce(c.deployer))),
                ")"
            )
        );
        _log(string.concat("  minLeadSeconds    ", vm.toString(c.minLeadSeconds)));
        _log(
            string.concat(
                "  startsAt          ",
                vm.toString(uint256(a.startsAt)),
                a.startsAt > block.timestamp
                    ? string.concat(" (in ", vm.toString(a.startsAt - block.timestamp), " s)")
                    : string(" (not in the future)")
            )
        );
        _log(string.concat("  renderer          ", vm.toString(address(renderer))));
        _log(string.concat("  rendererHash      ", vm.toString(c.rendererHash)));
        _log(string.concat("  motifCount        ", vm.toString(c.motifCount)));
        _log(string.concat("  geometryHash      ", vm.toString(c.geometryHash)));
        _show("paymentToken      ", a.paymentToken, mainnet ? LAUNCH_PAYMENT_TOKEN : a.paymentToken);
        _show("tokenDecimals     ", c.tokenDecimals, LAUNCH_TOKEN_DECIMALS);
        _show("treasury          ", a.treasury, LAUNCH_TREASURY);
        _show("collectionOwner   ", a.collectionOwner, LAUNCH_COLLECTION_OWNER);
        _show("reservePrice      ", a.reservePrice, LAUNCH_RESERVE_PRICE);
        _show("incrementBps      ", a.incrementBps, LAUNCH_INCREMENT_BPS);
        _show("duration          ", a.duration, LAUNCH_DURATION);
        _show("extensionWindow   ", a.extensionWindow, LAUNCH_EXTENSION_WINDOW);
        _show("symbolCap         ", a.symbolCap, LAUNCH_SYMBOL_CAP);
        _show("maxSymbolsPerBid  ", a.maxSymbolsPerBid, LAUNCH_MAX_SYMBOLS_PER_BID);
        _show("maxCells          ", a.maxCells, LAUNCH_MAX_CELLS);
    }

    function _show(string memory name, uint256 value, uint256 launch) internal view {
        string memory line = string.concat("  ", name, vm.toString(value));
        _log(value == launch ? line : string.concat(line, "   <- launch value ", vm.toString(launch)));
    }

    function _show(string memory name, address value, address launch) internal view {
        string memory line = string.concat("  ", name, vm.toString(value));
        _log(value == launch ? line : string.concat(line, "   <- launch value ", vm.toString(launch)));
    }

    // ------------------------------------------------------------ helpers

    /// @dev forge's console.log(string), called low-level: the console address has no code.
    function _log(string memory text) internal view {
        (bool ok,) = CONSOLE.staticcall(abi.encodeWithSignature("log(string)", text));
        ok; // logging is best effort
    }

    function _requireChain(Config memory c) internal view {
        if (block.chainid != c.chainId) revert Refused("wrong chain");
    }

    /// @dev SSTORE2 creation code: runtime = 0x00 || data.
    function _sstore2(bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
    }

    function _predict(bytes memory initcode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initcode)))
                )
            )
        );
    }

    /// @dev One CREATE2 through the deterministic deployer; checks the address and the gas policy.
    function _create2(bytes memory initcode, address expected, string memory what)
        internal
        returns (address)
    {
        bytes memory data = bytes.concat(SALT, initcode);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(data);
        g -= gasleft();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != expected || expected.code.length == 0) {
            revert Refused(string.concat(what, " deployment failed"));
        }
        g += _intrinsic(data) - 32_000; // a call, not a creation transaction
        if (g > MAX_TX_GAS) revert Refused(string.concat(what, " deployment gas"));
        return expected;
    }

    /// @dev Transaction base cost for `data` sent as a creation: 53,000 + calldata + initcode words.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 53_000 + 2 * ((data.length + 31) / 32);
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _u32(bytes memory s, uint256 pos) internal pure returns (uint256 v) {
        for (uint256 i; i < 4; ++i) {
            v = (v << 8) | uint8(s[pos + i]);
        }
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(b, 32), from), sub(to, from))
        }
    }
}
