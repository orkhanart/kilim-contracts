// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimGlyphs} from "../src/KilimGlyphs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";

interface VmDeploy {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function envString(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function keyExistsJson(string calldata, string calldata) external pure returns (bool);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function getNonce(address) external view returns (uint64);
    function computeCreateAddress(address, uint256) external pure returns (address);
    function toString(uint256) external pure returns (string memory);
    function toString(bytes32) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
}

/// @title DeployKilim
/// @notice Deploys Kilim in the published order, and refuses before sending anything if a check fails:
///           1. runStore():     every SSTORE2 chunk (glyph grids, names, page prefix, head and tail) through
///                              the deterministic CREATE2 deployer, salt 0. A chunk already deployed is
///                              verified and skipped.
///           2. runContracts(): with the deployer at nonce n, KilimGlyphs at n and KilimOneOfOne at n + 1,
///                              both with the auction predicted at n + 2 as minter, then KilimAuction at
///                              n + 2. Every immutable is read back and the auction's address is checked
///                              against the prediction.
///         `run()` does both (the local dry run, `pnpm deploy:dry`, and the testnet rehearsal). The config
///         is a JSON file named by $KILIM_DEPLOY_CONFIG; see deploy/mainnet.example.json,
///         deploy/sepolia.example.json and docs/STORAGE.md. On Ethereum mainnet (chain 1) the deployer
///         must be the artist's wallet, the auction settings must be the decided launch values, the
///         published nonce is always checked and the inspection window must be nonzero. Other chains
///         accept any valid settings and print each one next to the launch value.
/// @dev forge simulates the whole script before broadcasting, so any revert here means nothing is sent.
///      Every heavy step is first dry-run inside a state snapshot to measure its gas (printed per
///      transaction, refused above MAX_TX_GAS) and check its output: the dry run of the contracts also
///      mints a glyph and the 1/1 (as the auction, in the snapshot) to compare both tokenURIs with the
///      golden hashes in the manifests and to measure their gas.
///
///      The manifests are what onchain/pack_glyphs.py and onchain/pack_page.py write:
///        <glyphStore>/manifest.json: glyphCount, create2.deployer, hashes.gridsHash, hashes.namesHash,
///          grids.chunks[], names.chunks[], description (the collection description the golden was
///          computed with) and golden.tokenURI.sha256 for golden.glyph (any token showing that glyph).
///        <pageStore>/manifest.json: create2.deployer, hashes.prefixHash/headHash/tailHash,
///          sections.prefix/head/tail.chunks[], name, description, externalUrl (the 1/1's, as packed)
///          and golden.tokenURI.sha256 (the 1/1's whole tokenURI).
///        A chunk entry is {file, size, keccak, address}; every chunk but a section's last is full.
contract DeployKilim {
    VmDeploy internal constant vm = VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = bytes32(0);
    uint256 public constant CHUNK = 24_575;
    /// @notice Grid chunks are cut at 767 grids so no grid straddles two chunks.
    uint256 public constant GRID_CHUNK = 767 * 32;
    /// @notice Policy ceiling for every transaction and for reading a token, well under the 16,777,216 cap.
    uint256 public constant MAX_TX_GAS = 8_000_000;
    /// @notice No start date further out than this is accepted.
    uint256 public constant MAX_LEAD = 365 days;
    /// @notice A `deployerNonce` of this value skips the published-nonce check. Refused on chain 1.
    uint256 public constant NO_NONCE_CHECK = type(uint256).max;

    // The decided launch settings (checklists/1-pre-deploy.md). On chain 1 any other value is refused.
    uint256 public constant MAINNET_CHAIN_ID = 1;
    /// @notice orkhanart.eth: the deployer, the treasury and the royalty receiver.
    address public constant LAUNCH_DEPLOYER = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    address public constant LAUNCH_TREASURY = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    /// @notice The opening bid, 0.01 ETH: the only reserve the auction constructor accepts.
    uint256 public constant LAUNCH_RESERVE_PRICE = 0.01 ether;
    /// @notice Each raise at least +10%.
    uint16 public constant LAUNCH_INCREMENT_BPS = 1000;
    /// @notice 24 hours from the first bid.
    uint64 public constant LAUNCH_DURATION = 86_400;
    /// @notice A bid in the last 10 minutes moves the close to 10 minutes after it, with no limit.
    uint64 public constant LAUNCH_EXTENSION_WINDOW = 600;
    uint256 public constant LAUNCH_GLYPH_CAP = 1_000_000;
    uint256 public constant LAUNCH_MAX_GLYPHS_PER_BID = 1_000_000;
    /// @notice The 1/1's name, given by the artist (docs/CONTRACTS.md). It is the contract's name, so it is
    ///         the collection name marketplaces show; the glyph collection's name is fixed in its code.
    string public constant LAUNCH_ONE_OF_ONE_NAME = "The Unwoven Kilim";

    struct Config {
        uint256 chainId;
        address deployer;
        /// @dev The published nonce for the glyph collection, the first of the three contract deployments.
        ///      NO_NONCE_CHECK skips the check, except on chain 1, where it is refused.
        uint256 deployerNonce;
        /// @dev The inspection window: `startsAt` must be at least this many seconds after deployment.
        ///      Must be nonzero on chain 1.
        uint256 minLeadSeconds;
        string glyphStore;
        string pageStore;
        KilimAuction.Config auction;
        uint256 glyphCap;
        string collectionDescription;
        string collectionExternalUrl;
        string oneOfOneName;
        string oneOfOneDescription;
        string oneOfOneExternalUrl;
    }

    /// @dev One stored section: its published hash, the chunk files' bytes and their CREATE2 addresses.
    struct Section {
        bytes32 hash;
        bytes[] chunks;
        address[] addresses;
    }

    struct Store {
        string glyphManifest;
        string pageManifest;
        Section grids;
        Section names;
        Section prefix;
        Section head;
        Section tail;
    }

    struct Deployed {
        KilimGlyphs glyphs;
        KilimOneOfOne oneOfOne;
        KilimAuction auction;
    }

    error Refused(string reason);

    // ------------------------------------------------------------ entry points

    /// @notice One-shot deploy for local and Sepolia. Refused on mainnet, where the store is deployed and
    ///         inspected before the contracts: use runStore, then runContracts.
    function run() external {
        if (block.chainid == MAINNET_CHAIN_ID) {
            revert Refused("run() is not for mainnet: use runStore then runContracts");
        }
        Config memory c = loadConfig(vm.envString("KILIM_DEPLOY_CONFIG"));
        deployStore(c);
        deployContracts(c);
    }

    function runStore() external {
        deployStore(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")));
    }

    function runContracts() external {
        deployContracts(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")));
    }

    function loadConfig(string memory path) public view returns (Config memory c) {
        string memory j = vm.readFile(path);
        c.chainId = vm.parseJsonUint(j, ".chainId");
        c.deployer = vm.parseJsonAddress(j, ".deployer");
        c.deployerNonce = vm.parseJsonUint(j, ".deployerNonce");
        c.minLeadSeconds = vm.parseJsonUint(j, ".minLeadSeconds");
        c.glyphStore = vm.parseJsonString(j, ".glyphStore");
        c.pageStore = vm.parseJsonString(j, ".pageStore");
        c.auction.treasury = vm.parseJsonAddress(j, ".auction.treasury");
        c.auction.startsAt = uint64(vm.parseJsonUint(j, ".auction.startsAt"));
        c.auction.duration = uint64(vm.parseJsonUint(j, ".auction.duration"));
        c.auction.extensionWindow = uint64(vm.parseJsonUint(j, ".auction.extensionWindow"));
        c.auction.incrementBps = uint16(vm.parseJsonUint(j, ".auction.incrementBps"));
        c.auction.reservePrice = vm.parseJsonUint(j, ".auction.reservePrice");
        c.auction.maxGlyphsPerBid = vm.parseJsonUint(j, ".auction.maxGlyphsPerBid");
        c.glyphCap = vm.parseJsonUint(j, ".collection.glyphCap");
        c.collectionDescription = vm.parseJsonString(j, ".collection.description");
        c.collectionExternalUrl = vm.parseJsonString(j, ".collection.externalUrl");
        c.oneOfOneName = vm.parseJsonString(j, ".oneOfOne.name");
        c.oneOfOneDescription = vm.parseJsonString(j, ".oneOfOne.description");
        c.oneOfOneExternalUrl = vm.parseJsonString(j, ".oneOfOne.externalUrl");
    }

    // ------------------------------------------------------------ phase 1: the chunks

    /// @notice Verify both stores against their manifests, then deploy whatever chunk is missing.
    function deployStore(Config memory c) public returns (Store memory s) {
        _requireChain(c);
        s = loadStore(c);
        Section[5] memory sections = [s.grids, s.names, s.prefix, s.head, s.tail];
        string[5] memory labels = ["grids ", "names ", "prefix", "head  ", "tail  "];

        // Dry run: measure every chunk deployment that is still missing, and print its gas.
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < sections.length; ++i) {
            _deployMissing(sections[i], labels[i], true);
        }
        vm.revertToState(snap);

        vm.startBroadcast(c.deployer);
        for (uint256 i; i < sections.length; ++i) {
            _deployMissing(sections[i], labels[i], false);
        }
        vm.stopBroadcast();

        for (uint256 i; i < sections.length; ++i) {
            _logSection(labels[i], sections[i]);
        }
    }

    /// @dev Deploys the chunks of one section that are not on the chain yet. `measure` (dry run only)
    ///      prints the gas of each transaction; the policy ceiling is checked either way.
    function _deployMissing(Section memory section, string memory label, bool measure) internal {
        for (uint256 k; k < section.chunks.length; ++k) {
            if (section.addresses[k].code.length != 0) continue;
            uint256 g = _create2(_sstore2(section.chunks[k]), section.addresses[k], "chunk");
            if (measure) {
                _log(string.concat(label, " chunk ", vm.toString(k), " deployment gas ", vm.toString(g)));
            }
        }
    }

    /// @notice Read both manifests and every chunk file, checking sizes, hashes, layout and addresses.
    function loadStore(Config memory c) public view returns (Store memory s) {
        s.glyphManifest = vm.readFile(string.concat(c.glyphStore, "/manifest.json"));
        s.pageManifest = vm.readFile(string.concat(c.pageStore, "/manifest.json"));
        if (vm.parseJsonUint(s.glyphManifest, ".glyphCount") != 1024) revert Refused("glyph count");
        if (
            vm.parseJsonAddress(s.glyphManifest, ".create2.deployer") != CREATE2_DEPLOYER
                || vm.parseJsonAddress(s.pageManifest, ".create2.deployer") != CREATE2_DEPLOYER
        ) revert Refused("deployer");
        string memory g = s.glyphManifest;
        string memory pg = s.pageManifest;
        s.grids = _loadSection(c.glyphStore, g, "grids", ".grids.chunks", GRID_CHUNK);
        s.names = _loadSection(c.glyphStore, g, "names", ".names.chunks", CHUNK);
        s.prefix = _loadSection(c.pageStore, pg, "prefix", ".sections.prefix.chunks", CHUNK);
        s.head = _loadSection(c.pageStore, pg, "head", ".sections.head.chunks", CHUNK);
        s.tail = _loadSection(c.pageStore, pg, "tail", ".sections.tail.chunks", CHUNK);
        if (_total(s.grids) != 1024 * 32) revert Refused("grids are not 32,768 bytes");
        if (s.names.chunks.length != 1) revert Refused("names must be one chunk");
        // The golden hashes were computed with these texts; the contracts must be deployed with the same.
        if (!_sameText(vm.parseJsonString(g, ".description"), c.collectionDescription)) {
            revert Refused("collection description differs from the packed glyphs");
        }
        if (
            !_sameText(vm.parseJsonString(pg, ".name"), c.oneOfOneName)
                || !_sameText(vm.parseJsonString(pg, ".description"), c.oneOfOneDescription)
                || !_sameText(vm.parseJsonString(pg, ".externalUrl"), c.oneOfOneExternalUrl)
        ) revert Refused("1/1 name, description or externalUrl differs from the packed page");
    }

    /// @dev One section: every chunk file must match its manifest entry and its CREATE2 address, every
    ///      chunk but the last must be full, and the concatenation must hash to `.hashes.<label>Hash`.
    function _loadSection(
        string memory dir,
        string memory manifest,
        string memory label,
        string memory key,
        uint256 full
    ) internal view returns (Section memory section) {
        section.hash = vm.parseJsonBytes32(manifest, string.concat(".hashes.", label, "Hash"));
        uint256 count;
        while (vm.keyExistsJson(manifest, string.concat(key, "[", vm.toString(count), "]"))) {
            ++count;
        }
        if (count == 0) revert Refused(string.concat(label, ": no chunks"));
        section.chunks = new bytes[](count);
        section.addresses = new address[](count);
        uint256 total;
        for (uint256 k; k < count; ++k) {
            string memory entry = string.concat(key, "[", vm.toString(k), "]");
            bytes memory data = _loadChunk(dir, manifest, label, entry);
            if (k + 1 < count && data.length != full) revert Refused(string.concat(label, ": chunk layout"));
            section.chunks[k] = data;
            section.addresses[k] = _predict(_sstore2(data));
            if (section.addresses[k] != vm.parseJsonAddress(manifest, string.concat(entry, ".address"))) {
                revert Refused(string.concat(label, ": chunk CREATE2 address"));
            }
            address a = section.addresses[k];
            if (a.code.length != 0 && keccak256(a.code) != keccak256(bytes.concat(hex"00", data))) {
                revert Refused(string.concat(label, ": foreign code at a chunk address"));
            }
            total += data.length;
        }
        // One allocation for the whole section: concatenating chunk by chunk is quadratic in memory.
        if (keccak256(_concat(section.chunks, total)) != section.hash) {
            revert Refused(string.concat(label, ": section hash"));
        }
    }

    function _loadChunk(string memory dir, string memory manifest, string memory label, string memory entry)
        internal
        view
        returns (bytes memory data)
    {
        data = vm.readFileBinary(
            string.concat(dir, "/", vm.parseJsonString(manifest, string.concat(entry, ".file")))
        );
        if (data.length != vm.parseJsonUint(manifest, string.concat(entry, ".size"))) {
            revert Refused(string.concat(label, ": chunk size"));
        }
        if (keccak256(data) != vm.parseJsonBytes32(manifest, string.concat(entry, ".keccak"))) {
            revert Refused(string.concat(label, ": chunk hash"));
        }
        if (data.length == 0 || data.length > CHUNK) revert Refused(string.concat(label, ": chunk layout"));
    }

    function _concat(bytes[] memory parts, uint256 total) internal pure returns (bytes memory all) {
        all = new bytes(total);
        uint256 pos;
        for (uint256 i; i < parts.length; ++i) {
            bytes memory part = parts[i];
            assembly ("memory-safe") {
                mcopy(add(add(all, 32), pos), add(part, 32), mload(part))
            }
            pos += part.length;
        }
    }

    function _total(Section memory section) internal pure returns (uint256 total) {
        for (uint256 k; k < section.chunks.length; ++k) {
            total += section.chunks[k].length;
        }
    }

    // ------------------------------------------------------------ phase 2: the contracts

    /// @notice Deploy KilimGlyphs, KilimOneOfOne and KilimAuction, in that order, from the deployer's nonce.
    function deployContracts(Config memory c) public returns (Deployed memory d) {
        _requireChain(c);
        _printSettings(c);
        _requireLaunchSettings(c);
        Store memory s = loadStore(c);
        _requireStored(s);
        // On every chain: the auction constructor accepts no other reserve (its REGISTRATION_BALANCE).
        if (c.auction.reservePrice != LAUNCH_RESERVE_PRICE) revert Refused("reserve price");
        if (
            c.auction.startsAt < block.timestamp + c.minLeadSeconds
                || c.auction.startsAt > block.timestamp + MAX_LEAD
        ) revert Refused("startsAt outside the inspection window");
        if (c.auction.treasury == address(0)) revert Refused("zero address");
        uint256 nonce = vm.getNonce(c.deployer);
        if (c.deployerNonce != NO_NONCE_CHECK && nonce != c.deployerNonce) revert Refused("deployer nonce");
        address predicted = vm.computeCreateAddress(c.deployer, nonce + 2);

        // Dry run: deploy all three as the deployer (a prank, nothing is sent), measure each, check the
        // auction's address against the prediction, read everything back, then check the two tokenURIs
        // against the golden hashes and measure them.
        uint256 snap = vm.snapshotState();
        vm.startPrank(c.deployer);
        Deployed memory dry = _deployThree(c, s, predicted, true);
        vm.stopPrank();
        if (address(dry.auction) != predicted) revert Refused("auction address differs from the prediction");
        _checkContracts(c, s, dry);
        _checkGolden(c, s, dry);
        vm.revertToState(snap);

        vm.startBroadcast(c.deployer);
        d = _deployThree(c, s, predicted, false);
        vm.stopBroadcast();
        if (address(d.auction) != predicted) revert Refused("auction address differs from the prediction");
        _checkContracts(c, s, d);
        _log(string.concat("KilimGlyphs    ", vm.toString(address(d.glyphs))));
        _log(string.concat("KilimOneOfOne  ", vm.toString(address(d.oneOfOne))));
        _log(string.concat("KilimAuction   ", vm.toString(address(d.auction))));
    }

    /// @dev The three creations in order. `measure` (dry run only) prints each transaction's gas,
    ///      execution plus the intrinsic cost of its creation data, and checks it against the policy.
    function _deployThree(Config memory c, Store memory s, address minter, bool measure)
        internal
        returns (Deployed memory d)
    {
        uint256 g = gasleft();
        d.glyphs = new KilimGlyphs(
            minter,
            c.auction.treasury,
            c.glyphCap,
            s.grids.addresses,
            s.grids.hash,
            s.names.addresses[0],
            s.names.hash,
            c.collectionDescription,
            c.collectionExternalUrl
        );
        g -= gasleft();
        if (measure) {
            _measured(
                g, type(KilimGlyphs).creationCode, _glyphsArgs(c, s, minter), "KilimGlyphs deployment gas"
            );
        }
        g = gasleft();
        d.oneOfOne = new KilimOneOfOne(
            minter,
            c.auction.treasury,
            d.glyphs,
            _page(s),
            c.oneOfOneName,
            c.oneOfOneDescription,
            c.oneOfOneExternalUrl
        );
        g -= gasleft();
        if (measure) {
            _measured(
                g,
                type(KilimOneOfOne).creationCode,
                _oneOfOneArgs(c, s, minter, d.glyphs),
                "KilimOneOfOne deployment gas"
            );
        }
        KilimAuction.Config memory a = c.auction;
        a.glyphs = address(d.glyphs);
        a.oneOfOne = address(d.oneOfOne);
        g = gasleft();
        d.auction = new KilimAuction(a);
        g -= gasleft();
        if (measure) {
            _measured(g, type(KilimAuction).creationCode, abi.encode(a), "KilimAuction deployment gas");
        }
    }

    /// @dev The stored page as the 1/1's constructor takes it.
    function _page(Store memory s) internal pure returns (KilimOneOfOne.Page memory) {
        return KilimOneOfOne.Page({
            prefixChunks: s.prefix.addresses,
            prefixHash: s.prefix.hash,
            headChunks: s.head.addresses,
            headHash: s.head.hash,
            tailChunks: s.tail.addresses,
            tailHash: s.tail.hash
        });
    }

    /// @dev The glyph collection's constructor arguments, ABI-encoded as the creation transaction carries them.
    function _glyphsArgs(Config memory c, Store memory s, address minter)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            minter,
            c.auction.treasury,
            c.glyphCap,
            s.grids.addresses,
            s.grids.hash,
            s.names.addresses[0],
            s.names.hash,
            c.collectionDescription,
            c.collectionExternalUrl
        );
    }

    /// @dev The 1/1's constructor arguments, ABI-encoded as the creation transaction carries them.
    function _oneOfOneArgs(Config memory c, Store memory s, address minter, KilimGlyphs glyphs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            minter,
            c.auction.treasury,
            glyphs,
            _page(s),
            c.oneOfOneName,
            c.oneOfOneDescription,
            c.oneOfOneExternalUrl
        );
    }

    /// @dev A creation transaction's gas: what the constructor used plus the intrinsic cost of sending
    ///      its creation code and arguments. Printed, and refused above the policy ceiling.
    function _measured(uint256 executionGas, bytes memory creationCode, bytes memory args, string memory what)
        internal
        view
    {
        uint256 g = executionGas + _intrinsic(bytes.concat(creationCode, args));
        _log(string.concat(what, " ", vm.toString(g)));
        _gasPolicy(g, what);
    }

    /// @dev Every immutable, read back, must be what was deployed.
    function _checkContracts(Config memory c, Store memory s, Deployed memory d) internal view {
        KilimGlyphs k = d.glyphs;
        if (
            k.minter() != address(d.auction) || k.royaltyReceiver() != c.auction.treasury
                || k.glyphCap() != c.glyphCap || k.gridsHash() != s.grids.hash
                || k.namesHash() != s.names.hash || k.namesChunk() != s.names.addresses[0]
                || !_same(k.gridChunks(), s.grids.addresses)
                || !_sameText(k.description(), c.collectionDescription)
                || !_sameText(k.externalUrl(), c.collectionExternalUrl)
        ) revert Refused("glyphs read-back");
        KilimOneOfOne o = d.oneOfOne;
        if (
            o.minter() != address(d.auction) || o.royaltyReceiver() != c.auction.treasury
                || address(o.glyphs()) != address(k) || o.prefixHash() != s.prefix.hash
                || o.headHash() != s.head.hash || o.tailHash() != s.tail.hash
                || !_same(o.prefixChunks(), s.prefix.addresses) || !_same(o.headChunks(), s.head.addresses)
                || !_same(o.tailChunks(), s.tail.addresses) || !_sameText(o.name(), c.oneOfOneName)
                || !_sameText(o.description(), c.oneOfOneDescription)
                || !_sameText(o.externalUrl(), c.oneOfOneExternalUrl) || o.minted()
        ) revert Refused("1/1 read-back");
        KilimAuction a = d.auction;
        if (
            a.treasury() != c.auction.treasury || a.startsAt() != c.auction.startsAt
                || a.duration() != c.auction.duration || a.extensionWindow() != c.auction.extensionWindow
                || a.incrementBps() != c.auction.incrementBps || a.reservePrice() != c.auction.reservePrice
                || address(a.glyphs()) != address(k) || address(a.oneOfOne()) != address(o)
                || a.glyphCap() != c.glyphCap || a.maxGlyphsPerBid() != c.auction.maxGlyphsPerBid
                || a.endsAt() != 0
        ) revert Refused("auction read-back");
    }

    /// @dev Inside the dry run only: mint one glyph and the 1/1 as the auction would, compare both
    ///      tokenURIs with the golden hashes and keep their gas under the policy ceiling.
    function _checkGolden(Config memory c, Store memory s, Deployed memory d) internal {
        uint256 glyph = vm.parseJsonUint(s.glyphManifest, ".golden.glyph");
        uint256 id = _idShowing(d.glyphs, glyph);
        vm.prank(address(d.auction));
        d.glyphs.mintGlyphs(c.deployer, c.deployer, id, 1);
        if (
            sha256(bytes(d.glyphs.tokenURI(id)))
                != vm.parseJsonBytes32(s.glyphManifest, ".golden.tokenURI.sha256")
        ) {
            revert Refused("glyph tokenURI differs from golden");
        }
        uint256 g = _readGas(address(d.glyphs), abi.encodeCall(d.glyphs.tokenURI, (id)));
        _log(string.concat("glyph tokenURI gas ", vm.toString(g), " (token ", vm.toString(id), ")"));
        _gasPolicy(g, "glyph tokenURI gas");
        vm.prank(address(d.auction));
        d.oneOfOne.mint(c.deployer);
        if (
            sha256(bytes(d.oneOfOne.tokenURI(1)))
                != vm.parseJsonBytes32(s.pageManifest, ".golden.tokenURI.sha256")
        ) revert Refused("1/1 tokenURI differs from golden");
        g = _readGas(address(d.oneOfOne), abi.encodeCall(d.oneOfOne.tokenURI, (1)));
        _log(string.concat("1/1 tokenURI gas ", vm.toString(g)));
        _gasPolicy(g, "1/1 tokenURI gas");
    }

    /// @dev The first token id that shows `glyph`; about 1,024 tries on average.
    function _idShowing(KilimGlyphs k, uint256 glyph) internal view returns (uint256 id) {
        for (id = 1; id <= 1_000_000; ++id) {
            if (k.glyphOf(id) == glyph) return id;
        }
        revert Refused("no token shows the golden glyph");
    }

    /// @dev Gas of a read as a marketplace makes it: the call itself, without copying the answer.
    function _readGas(address target, bytes memory data) internal view returns (uint256 g) {
        bool ok;
        g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        if (!ok) revert Refused("read failed");
    }

    function _requireStored(Store memory s) internal view {
        Section[5] memory sections = [s.grids, s.names, s.prefix, s.head, s.tail];
        for (uint256 i; i < sections.length; ++i) {
            for (uint256 k; k < sections[i].addresses.length; ++k) {
                if (sections[i].addresses[k].code.length == 0) {
                    revert Refused("store not deployed: runStore first");
                }
            }
        }
    }

    /// @dev Chain 1 only: the artist's wallet deploys, every auction setting and the 1/1's name must be
    ///      the decided launch value, the published nonce is always checked, and the inspection window
    ///      must be nonzero.
    function _requireLaunchSettings(Config memory c) internal view {
        if (block.chainid != MAINNET_CHAIN_ID) return;
        KilimAuction.Config memory a = c.auction;
        if (c.deployer != LAUNCH_DEPLOYER) revert Refused("mainnet launch value: deployer");
        if (!_sameText(c.oneOfOneName, LAUNCH_ONE_OF_ONE_NAME)) {
            revert Refused("mainnet launch value: oneOfOne.name");
        }
        if (a.treasury != LAUNCH_TREASURY) revert Refused("mainnet launch value: treasury");
        if (a.reservePrice != LAUNCH_RESERVE_PRICE) revert Refused("mainnet launch value: reservePrice");
        if (a.incrementBps != LAUNCH_INCREMENT_BPS) revert Refused("mainnet launch value: incrementBps");
        if (a.duration != LAUNCH_DURATION) revert Refused("mainnet launch value: duration");
        if (a.extensionWindow != LAUNCH_EXTENSION_WINDOW) {
            revert Refused("mainnet launch value: extensionWindow");
        }
        if (c.glyphCap != LAUNCH_GLYPH_CAP) revert Refused("mainnet launch value: glyphCap");
        if (a.maxGlyphsPerBid != LAUNCH_MAX_GLYPHS_PER_BID) {
            revert Refused("mainnet launch value: maxGlyphsPerBid");
        }
        if (c.deployerNonce == NO_NONCE_CHECK) revert Refused("mainnet needs the published deployerNonce");
        if (c.minLeadSeconds == 0) revert Refused("mainnet needs a nonzero minLeadSeconds");
    }

    /// @dev Prints every setting the contracts phase deploys with. A value that differs from the decided
    ///      launch value is flagged; on chain 1 it is then refused.
    function _printSettings(Config memory c) internal view {
        KilimAuction.Config memory a = c.auction;
        _log(string.concat("settings for chain ", vm.toString(block.chainid)));
        _show("deployer          ", c.deployer, LAUNCH_DEPLOYER);
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
        _log(string.concat("  glyphStore        ", c.glyphStore));
        _log(string.concat("  pageStore         ", c.pageStore));
        _show("treasury          ", a.treasury, LAUNCH_TREASURY);
        _show("reservePrice      ", a.reservePrice, LAUNCH_RESERVE_PRICE);
        _show("incrementBps      ", a.incrementBps, LAUNCH_INCREMENT_BPS);
        _show("duration          ", a.duration, LAUNCH_DURATION);
        _show("extensionWindow   ", a.extensionWindow, LAUNCH_EXTENSION_WINDOW);
        _show("glyphCap          ", c.glyphCap, LAUNCH_GLYPH_CAP);
        _show("maxGlyphsPerBid   ", a.maxGlyphsPerBid, LAUNCH_MAX_GLYPHS_PER_BID);
        _log(string.concat("  collection        ", c.collectionDescription, " | ", c.collectionExternalUrl));
        _show("1/1 name          ", c.oneOfOneName, LAUNCH_ONE_OF_ONE_NAME);
        _log(string.concat("  1/1 externalUrl   ", c.oneOfOneExternalUrl));
    }

    function _show(string memory name, uint256 value, uint256 launch) internal view {
        string memory line = string.concat("  ", name, vm.toString(value));
        _log(value == launch ? line : string.concat(line, "   <- launch value ", vm.toString(launch)));
    }

    function _show(string memory name, string memory value, string memory launch) internal view {
        string memory line = string.concat("  ", name, value);
        _log(_sameText(value, launch) ? line : string.concat(line, "   <- launch value ", launch));
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

    function _logSection(string memory name, Section memory section) internal view {
        for (uint256 k; k < section.addresses.length; ++k) {
            _log(string.concat(name, " chunk ", vm.toString(k), "  ", vm.toString(section.addresses[k])));
        }
    }

    function _requireChain(Config memory c) internal view {
        if (block.chainid != c.chainId) revert Refused("wrong chain");
    }

    function _gasPolicy(uint256 used, string memory what) internal pure {
        if (used > MAX_TX_GAS) revert Refused(what);
    }

    function _same(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _sameText(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
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

    /// @dev One CREATE2 through the deterministic deployer; checks the address and the gas policy and
    ///      returns the transaction's gas (execution plus the intrinsic cost of the call data).
    function _create2(bytes memory initcode, address expected, string memory what)
        internal
        returns (uint256 g)
    {
        bytes memory data = bytes.concat(SALT, initcode);
        g = gasleft();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(data);
        g -= gasleft();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != expected || expected.code.length == 0) {
            revert Refused(string.concat(what, " deployment failed"));
        }
        g += _intrinsic(data) - 32_000; // a call, not a creation transaction
        if (g > MAX_TX_GAS) revert Refused(string.concat(what, " deployment gas"));
    }

    /// @dev Transaction base cost for `data` sent as a creation: 53,000 + calldata + initcode words.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 53_000 + 2 * ((data.length + 31) / 32);
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }
}
