// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {KilimTexts} from "./KilimTexts.sol";

interface VmDeploy {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function envString(string calldata) external view returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBool(string calldata, string calldata) external pure returns (bool);
    function rpc(string calldata method, string calldata params) external returns (bytes memory);
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
///           1. runStore():     every SSTORE2 chunk (motif grids, names, page prefix, head and tail) through
///                              the deterministic CREATE2 deployer, salt 0. A chunk already deployed is
///                              verified and skipped.
///           2. runContracts(): with the deployer at nonce n, KilimMotifs at n and KilimOneOfOne at n + 1,
///                              both with the auction predicted at n + 2 as minter, then KilimAuction at
///                              n + 2. Every immutable is read back and the auction's address is checked
///                              against the prediction.
///           3. runAuction():   only if the third creation was dropped (never mined): with the two token
///                              contracts already at n and n + 1 and the deployer still at n + 2, deploys
///                              KilimAuction alone, after the same checks, so the published addresses
///                              survive. A mined third creation that reverted, or a replacement at n + 2,
///                              spent that nonce; both token contracts are then void and this refuses.
///         `run()` does 1 and 2 for the local dry run (`pnpm deploy:dry`); the rehearsal uses the two
///         phases as mainnet does. The store is sent by forge's --sender, never by the config's
///         deployer once its nonce is published: 45 chunks would spend that nonce. The config is a JSON
///         file named by $KILIM_DEPLOY_CONFIG; see deploy/mainnet.example.json,
///         deploy/sepolia.example.json and docs/STORAGE.md. On Ethereum mainnet (chain 1) the deployer
///         must be the artist's wallet, the auction settings must be the decided launch values, the
///         config must name the content by hash (`expected`, its `texts` included: every text the four
///         contracts store, the Bazaar's too, see KilimTexts), the artwork must read KILIM_GRIDS, the
///         published nonce is always checked and the inspection window must be nonzero. Other chains
///         accept any valid settings and print each one next to the launch value. On every chain the
///         deployer must be a plain account: no code, so no EIP-7702 delegation and no contract wallet.
/// @dev forge simulates the whole script before broadcasting, so any revert here means nothing is sent.
///      Every heavy step is first dry-run inside a state snapshot to measure its gas (printed per
///      transaction, refused above MAX_TX_GAS) and check its output: the dry run of the contracts also
///      mints a motif and the 1/1 (as the auction, in the snapshot) to compare both tokenURIs with the
///      golden hashes in the manifests and to measure their gas.
///
///      The manifests are what onchain/pack_motifs.py and onchain/pack_page.py write:
///        <motifStore>/manifest.json: motifCount, create2.deployer, hashes.gridsHash, hashes.namesHash,
///          grids.chunks[], names.chunks[], description (the collection description the golden was
///          computed with) and golden.tokenURI.sha256 for golden.motif (any token showing that motif).
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
    uint256 public constant LAUNCH_MOTIF_CAP = 1_000_000;
    uint256 public constant LAUNCH_MAX_MOTIFS_PER_BID = 1_000_000;
    /// @notice The 1/1's name, given by the artist (docs/CONTRACTS.md). It is the contract's name, so it is
    ///         the collection name marketplaces show; the motif collection's name is fixed in its code.
    string public constant LAUNCH_ONE_OF_ONE_NAME = "The Unwoven Kilim";

    struct Config {
        uint256 chainId;
        address deployer;
        /// @dev The published nonce for the motif collection, the first of the three contract deployments.
        ///      NO_NONCE_CHECK skips the check, except on chain 1, where it is refused.
        uint256 deployerNonce;
        /// @dev The inspection window: `startsAt` must be at least this many seconds after deployment.
        ///      Must be nonzero on chain 1.
        uint256 minLeadSeconds;
        string motifStore;
        string pageStore;
        KilimAuction.Config auction;
        uint256 motifCap;
        string collectionDescription;
        string collectionExternalUrl;
        string oneOfOneName;
        string oneOfOneDescription;
        string oneOfOneExternalUrl;
        /// @dev The `bazaar` block's three texts ("" without one). This script deploys no Bazaar; they are
        ///      read only for `expected.texts`, which covers every text the four contracts store.
        string bazaarDescription;
        string bazaarExternalUrl;
        string bazaarImageBase;
        /// @dev The content this config was signed off for, by hash. Required on chain 1; elsewhere it
        ///      is compared whenever the config carries it.
        bool hasExpected;
        Expected expected;
    }

    /// @dev `.expected` in the config. The first five are the keccak hashes the constructors check, the
    ///      two goldens are the sha256 of the tokenURIs, the next four are the sha256 of the files the
    ///      packers read: the artist's page (for the motifs), the artwork page, the still and the loader;
    ///      `texts` is KilimTexts.hash of the eight texts (audit TK-2: the collection link and the Bazaar's
    ///      texts are in no golden). `texts` is required on chain 1; elsewhere a config may leave it out
    ///      (the Sepolia record predates it), and it is compared whenever it is there.
    struct Expected {
        bytes32 gridsHash;
        bytes32 namesHash;
        bytes32 prefixHash;
        bytes32 headHash;
        bytes32 tailHash;
        bytes32 motifGolden;
        bytes32 oneOfOneGolden;
        bytes32 motifSource;
        bytes32 artwork;
        bytes32 still;
        bytes32 loader;
        bytes32 texts;
    }

    /// @dev One stored section: its published hash, the chunk files' bytes and their CREATE2 addresses.
    struct Section {
        bytes32 hash;
        bytes[] chunks;
        address[] addresses;
    }

    struct Store {
        string motifManifest;
        string pageManifest;
        Section grids;
        Section names;
        Section prefix;
        Section head;
        Section tail;
    }

    struct Deployed {
        KilimMotifs motifs;
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
        deployStore(c, msg.sender);
        deployContracts(c);
    }

    /// @notice The store, sent by forge's --sender (any funded wallet).
    function runStore() external {
        deployStore(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")), msg.sender);
    }

    function runContracts() external {
        deployContracts(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")));
    }

    /// @notice Completes a deployment whose third transaction was lost. See `deployAuction`.
    function runAuction() external {
        deployAuction(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")));
    }

    function loadConfig(string memory path) public view returns (Config memory c) {
        string memory j = vm.readFile(path);
        c.chainId = vm.parseJsonUint(j, ".chainId");
        c.deployer = vm.parseJsonAddress(j, ".deployer");
        c.deployerNonce = vm.parseJsonUint(j, ".deployerNonce");
        c.minLeadSeconds = vm.parseJsonUint(j, ".minLeadSeconds");
        c.motifStore = vm.parseJsonString(j, ".motifStore");
        c.pageStore = vm.parseJsonString(j, ".pageStore");
        c.auction.treasury = vm.parseJsonAddress(j, ".auction.treasury");
        c.auction.startsAt = uint64(vm.parseJsonUint(j, ".auction.startsAt"));
        c.auction.duration = uint64(vm.parseJsonUint(j, ".auction.duration"));
        c.auction.extensionWindow = uint64(vm.parseJsonUint(j, ".auction.extensionWindow"));
        c.auction.incrementBps = uint16(vm.parseJsonUint(j, ".auction.incrementBps"));
        c.auction.reservePrice = vm.parseJsonUint(j, ".auction.reservePrice");
        c.auction.maxMotifsPerBid = vm.parseJsonUint(j, ".auction.maxMotifsPerBid");
        c.motifCap = vm.parseJsonUint(j, ".collection.motifCap");
        c.collectionDescription = vm.parseJsonString(j, ".collection.description");
        c.collectionExternalUrl = vm.parseJsonString(j, ".collection.externalUrl");
        c.oneOfOneName = vm.parseJsonString(j, ".oneOfOne.name");
        c.oneOfOneDescription = vm.parseJsonString(j, ".oneOfOne.description");
        c.oneOfOneExternalUrl = vm.parseJsonString(j, ".oneOfOne.externalUrl");
        if (vm.keyExistsJson(j, ".bazaar")) {
            c.bazaarDescription = vm.parseJsonString(j, ".bazaar.description");
            c.bazaarExternalUrl = vm.parseJsonString(j, ".bazaar.externalUrl");
            c.bazaarImageBase = vm.parseJsonString(j, ".bazaar.imageBase");
        }
        c.hasExpected = vm.keyExistsJson(j, ".expected");
        if (c.hasExpected) c.expected = _loadExpected(j);
    }

    /// @dev Every key must be there, `texts` aside: a config that names some of the content names all of it.
    ///      `texts` is new since 12 October (TK-2); chain 1 refuses a config without it (`_requireExpected`).
    function _loadExpected(string memory j) internal pure returns (Expected memory e) {
        e.gridsHash = vm.parseJsonBytes32(j, ".expected.gridsHash");
        e.namesHash = vm.parseJsonBytes32(j, ".expected.namesHash");
        e.prefixHash = vm.parseJsonBytes32(j, ".expected.prefixHash");
        e.headHash = vm.parseJsonBytes32(j, ".expected.headHash");
        e.tailHash = vm.parseJsonBytes32(j, ".expected.tailHash");
        e.motifGolden = vm.parseJsonBytes32(j, ".expected.motifGolden");
        e.oneOfOneGolden = vm.parseJsonBytes32(j, ".expected.oneOfOneGolden");
        e.motifSource = vm.parseJsonBytes32(j, ".expected.motifSource");
        e.artwork = vm.parseJsonBytes32(j, ".expected.artwork");
        e.still = vm.parseJsonBytes32(j, ".expected.still");
        e.loader = vm.parseJsonBytes32(j, ".expected.loader");
        if (vm.keyExistsJson(j, ".expected.texts")) e.texts = vm.parseJsonBytes32(j, ".expected.texts");
    }

    /// @notice `expected.texts` for this config: KilimTexts.hash of the eight texts the contracts store.
    function textsHash(Config memory c) public pure returns (bytes32) {
        return KilimTexts.hash(
            [
                c.collectionDescription,
                c.collectionExternalUrl,
                c.oneOfOneName,
                c.oneOfOneDescription,
                c.oneOfOneExternalUrl,
                c.bazaarDescription,
                c.bazaarExternalUrl,
                c.bazaarImageBase
            ]
        );
    }

    // ------------------------------------------------------------ phase 1: the chunks

    /// @notice Verify both stores against their manifests, then deploy whatever chunk is missing, from
    ///         `sender` (forge's --sender). A chunk's address depends on its bytes alone, so any wallet
    ///         can send it. The config's deployer may send the store only while no nonce is published
    ///         for it: every chunk it sends moves the nonce the three contracts are promised at.
    function deployStore(Config memory c, address sender) public returns (Store memory s) {
        _requireChain(c);
        s = loadStore(c);
        Section[5] memory sections = [s.grids, s.names, s.prefix, s.head, s.tail];
        string[5] memory labels = ["grids ", "names ", "prefix", "head  ", "tail  "];
        uint256 missing;
        for (uint256 i; i < sections.length; ++i) {
            for (uint256 k; k < sections[i].addresses.length; ++k) {
                if (sections[i].addresses[k].code.length == 0) ++missing;
            }
        }
        _log(string.concat("store sender ", vm.toString(sender), ", chunks to send ", vm.toString(missing)));
        if (missing != 0 && sender == c.deployer && c.deployerNonce != NO_NONCE_CHECK) {
            revert Refused("the store would spend the published deployer nonce: send it from another wallet");
        }

        // Dry run: measure every chunk deployment that is still missing, and print its gas.
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < sections.length; ++i) {
            _deployMissing(sections[i], labels[i], true);
        }
        vm.revertToState(snap);

        vm.startBroadcast(sender);
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
        s.motifManifest = vm.readFile(string.concat(c.motifStore, "/manifest.json"));
        s.pageManifest = vm.readFile(string.concat(c.pageStore, "/manifest.json"));
        if (vm.parseJsonUint(s.motifManifest, ".motifCount") != 1024) revert Refused("motif count");
        if (
            vm.parseJsonAddress(s.motifManifest, ".create2.deployer") != CREATE2_DEPLOYER
                || vm.parseJsonAddress(s.pageManifest, ".create2.deployer") != CREATE2_DEPLOYER
        ) revert Refused("deployer");
        string memory g = s.motifManifest;
        string memory pg = s.pageManifest;
        s.grids = _loadSection(c.motifStore, g, "grids", ".grids.chunks", GRID_CHUNK);
        s.names = _loadSection(c.motifStore, g, "names", ".names.chunks", CHUNK);
        s.prefix = _loadSection(c.pageStore, pg, "prefix", ".sections.prefix.chunks", CHUNK);
        s.head = _loadSection(c.pageStore, pg, "head", ".sections.head.chunks", CHUNK);
        s.tail = _loadSection(c.pageStore, pg, "tail", ".sections.tail.chunks", CHUNK);
        if (_total(s.grids) != 1024 * 32) revert Refused("grids are not 32,768 bytes");
        if (s.names.chunks.length != 1) revert Refused("names must be one chunk");
        // The golden hashes were computed with these texts; the contracts must be deployed with the same.
        if (!_sameText(vm.parseJsonString(g, ".description"), c.collectionDescription)) {
            revert Refused("collection description differs from the packed motifs");
        }
        // The collection's link is in no hash or golden: the packer records it so it is compared here.
        if (!_sameText(vm.parseJsonString(g, ".externalUrl"), c.collectionExternalUrl)) {
            revert Refused("collection externalUrl differs from the packed motifs");
        }
        if (
            !_sameText(vm.parseJsonString(pg, ".name"), c.oneOfOneName)
                || !_sameText(vm.parseJsonString(pg, ".description"), c.oneOfOneDescription)
                || !_sameText(vm.parseJsonString(pg, ".externalUrl"), c.oneOfOneExternalUrl)
        ) revert Refused("1/1 name, description or externalUrl differs from the packed page");
        _requireDataUrlSafe(s.prefix);
        _requireExpected(c, s);
        // The 1/1 is handed the motif grids when it is read. A page that never reads them is a stand-in.
        if (
            block.chainid == MAINNET_CHAIN_ID
                && !(vm.keyExistsJson(pg, ".artwork.readsGrids")
                    && vm.parseJsonBool(pg, ".artwork.readsGrids"))
        ) revert Refused("mainnet: the artwork does not read KILIM_GRIDS");
    }

    /// @dev PREFIX travels raw inside the token's data: URL, where '#' cuts the JSON off and '%XX' is
    ///      decoded. The packer refuses both in the texts; this refuses a store edited afterwards.
    function _requireDataUrlSafe(Section memory prefix) internal pure {
        for (uint256 k; k < prefix.chunks.length; ++k) {
            bytes memory data = prefix.chunks[k];
            for (uint256 i; i < data.length; ++i) {
                if (data[i] == "#" || data[i] == "%") revert Refused("prefix: '#' or '%' in the token JSON");
            }
        }
    }

    /// @dev The store must be the content the config names: the five section hashes, both goldens and the
    ///      four files the packers read; and the config's texts must be the ones signed off (`texts`). Chain
    ///      1 refuses a config without them; elsewhere a missing `texts` (zero) is not compared.
    function _requireExpected(Config memory c, Store memory s) internal view {
        if (!c.hasExpected) {
            if (block.chainid == MAINNET_CHAIN_ID) revert Refused("mainnet needs the expected hashes");
            return;
        }
        Expected memory e = c.expected;
        _expect(e.gridsHash, s.grids.hash, "gridsHash");
        _expect(e.namesHash, s.names.hash, "namesHash");
        _expect(e.prefixHash, s.prefix.hash, "prefixHash");
        _expect(e.headHash, s.head.hash, "headHash");
        _expect(e.tailHash, s.tail.hash, "tailHash");
        _expect(e.motifGolden, vm.parseJsonBytes32(s.motifManifest, ".golden.tokenURI.sha256"), "motifGolden");
        _expect(
            e.oneOfOneGolden, vm.parseJsonBytes32(s.pageManifest, ".golden.tokenURI.sha256"), "oneOfOneGolden"
        );
        _expect(e.motifSource, vm.parseJsonBytes32(s.motifManifest, ".source.sha256"), "motifSource");
        _expect(e.artwork, vm.parseJsonBytes32(s.pageManifest, ".artwork.sha256"), "artwork");
        _expect(e.still, vm.parseJsonBytes32(s.pageManifest, ".still.sha256"), "still");
        _expect(e.loader, vm.parseJsonBytes32(s.pageManifest, ".loaderTemplate.sha256"), "loader");
        if (block.chainid == MAINNET_CHAIN_ID || e.texts != bytes32(0)) {
            _expect(e.texts, textsHash(c), "texts");
        }
    }

    function _expect(bytes32 want, bytes32 have, string memory what) internal pure {
        if (want == bytes32(0) || want != have) revert Refused(string.concat("expected ", what));
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

    /// @notice Deploy KilimMotifs, KilimOneOfOne and KilimAuction, in that order, from the deployer's nonce.
    function deployContracts(Config memory c) public returns (Deployed memory d) {
        _requireChain(c);
        _printSettings(c);
        _requireLaunchSettings(c);
        Store memory s = loadStore(c);
        _requireStored(s);
        _requireAuctionSettings(c);
        _requirePlainDeployer(c.deployer);
        uint256 nonce = vm.getNonce(c.deployer);
        if (c.deployerNonce != NO_NONCE_CHECK) {
            if (nonce != c.deployerNonce) {
                _log(string.concat("the deployer's nonce is ", vm.toString(nonce)));
                revert Refused("deployer nonce");
            }
            _requireNothingPending(c.deployer, nonce);
        }
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
        _logDeployed(d);
    }

    /// @notice Completes a deployment whose third creation was dropped from the pool (never mined) after
    ///         the first two succeeded. The two token contracts name the address at nonce n + 2 as their
    ///         minter, so an auction deployed there, and only there, makes them whole: the published
    ///         addresses and the motif layout survive. Needs the published nonce n in the config, the
    ///         deployer still at n + 2, and both tokens reading back exactly as this config would deploy
    ///         them. A third creation that was mined and reverted, or replaced by another transaction at
    ///         n + 2, spent that nonce: nothing can be deployed at the minter's address any more, both
    ///         token contracts are void, and this refuses ("deployer nonce is not the published one plus
    ///         two"). A dropped first creation spends nothing: run runContracts again. A dropped second (the first
    ///         mined) leaves the deployer at n + 1, which no command completes: see checklists/2-deploy.md.
    function deployAuction(Config memory c) public returns (Deployed memory d) {
        _requireChain(c);
        _printSettings(c);
        _requireLaunchSettings(c);
        Store memory s = loadStore(c);
        _requireStored(s);
        _requireAuctionSettings(c);
        _requirePlainDeployer(c.deployer);
        if (c.deployerNonce == NO_NONCE_CHECK) {
            revert Refused("completing needs the published deployerNonce");
        }
        uint256 nonce = vm.getNonce(c.deployer);
        if (nonce != c.deployerNonce + 2) revert Refused("deployer nonce is not the published one plus two");
        _requireNothingPending(c.deployer, nonce);
        address predicted = vm.computeCreateAddress(c.deployer, nonce);
        d.motifs = KilimMotifs(vm.computeCreateAddress(c.deployer, c.deployerNonce));
        d.oneOfOne = KilimOneOfOne(vm.computeCreateAddress(c.deployer, c.deployerNonce + 1));
        if (address(d.motifs).code.length == 0 || address(d.oneOfOne).code.length == 0) {
            revert Refused("the two token contracts are not at the published addresses");
        }
        if (predicted.code.length != 0) revert Refused("the auction is already deployed");
        _checkTokens(c, s, d.motifs, d.oneOfOne, predicted);
        KilimAuction.Config memory a = _auctionConfig(c, d);

        uint256 snap = vm.snapshotState();
        vm.startPrank(c.deployer);
        uint256 g = gasleft();
        d.auction = new KilimAuction(a);
        g -= gasleft();
        vm.stopPrank();
        _measured(g, type(KilimAuction).creationCode, abi.encode(a), "KilimAuction deployment gas");
        if (address(d.auction) != predicted) revert Refused("auction address differs from the prediction");
        _checkContracts(c, s, d);
        _checkGolden(c, s, d);
        vm.revertToState(snap);

        vm.startBroadcast(c.deployer);
        d.auction = new KilimAuction(a);
        vm.stopBroadcast();
        if (address(d.auction) != predicted) revert Refused("auction address differs from the prediction");
        _checkContracts(c, s, d);
        _logDeployed(d);
    }

    function _logDeployed(Deployed memory d) internal view {
        _log(string.concat("KilimMotifs    ", vm.toString(address(d.motifs))));
        _log(string.concat("KilimOneOfOne  ", vm.toString(address(d.oneOfOne))));
        _log(string.concat("KilimAuction   ", vm.toString(address(d.auction))));
    }

    /// @dev What every chain requires of the auction's settings.
    function _requireAuctionSettings(Config memory c) internal view {
        // The auction constructor accepts no other reserve (its REGISTRATION_BALANCE).
        if (c.auction.reservePrice != LAUNCH_RESERVE_PRICE) revert Refused("reserve price");
        if (
            c.auction.startsAt < block.timestamp + c.minLeadSeconds
                || c.auction.startsAt > block.timestamp + MAX_LEAD
        ) revert Refused("startsAt outside the inspection window");
        if (c.auction.treasury == address(0)) revert Refused("zero address");
    }

    /// @dev The deployer must be a plain account. An EIP-7702 delegation (23 bytes, 0xef0100 and the
    ///      delegate) or a contract wallet may let someone else send from it and spend the published nonce,
    ///      or create a contract at n + 2 that would be both tokens' minter (audit FA-17).
    function _requirePlainDeployer(address deployer) internal view {
        if (deployer.code.length != 0) {
            revert Refused("deployer has code (EIP-7702 delegation or contract wallet)");
        }
    }

    /// @dev `vm.getNonce` is the nonce at the latest block. A transaction from the deployer still waiting
    ///      in the pool is invisible to it, and would take the published nonce before the creations do.
    function _requireNothingPending(address deployer, uint256 latest) internal {
        if (_pendingNonce(deployer) != latest) revert Refused("a transaction from the deployer is pending");
    }

    /// @dev eth_getTransactionCount(deployer, "pending") from the node the script runs against. Called
    ///      only when the nonce is checked, so the in-memory dry run (no node) never reaches it. The
    ///      cheatcode returns the JSON quantity as big-endian bytes.
    function _pendingNonce(address who) internal virtual returns (uint256 n) {
        bytes memory data =
            vm.rpc("eth_getTransactionCount", string.concat('["', vm.toString(who), '","pending"]'));
        if (data.length == 0 || data.length > 32) revert Refused("pending nonce unreadable");
        for (uint256 i; i < data.length; ++i) {
            n = (n << 8) | uint8(data[i]);
        }
    }

    /// @dev The three creations in order. `measure` (dry run only) prints each transaction's gas,
    ///      execution plus the intrinsic cost of its creation data, and checks it against the policy.
    function _deployThree(Config memory c, Store memory s, address minter, bool measure)
        internal
        returns (Deployed memory d)
    {
        uint256 g = gasleft();
        d.motifs = new KilimMotifs(
            minter,
            c.auction.treasury,
            c.motifCap,
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
                g, type(KilimMotifs).creationCode, _motifsArgs(c, s, minter), "KilimMotifs deployment gas"
            );
        }
        g = gasleft();
        d.oneOfOne = new KilimOneOfOne(
            minter,
            c.auction.treasury,
            d.motifs,
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
                _oneOfOneArgs(c, s, minter, d.motifs),
                "KilimOneOfOne deployment gas"
            );
        }
        KilimAuction.Config memory a = _auctionConfig(c, d);
        g = gasleft();
        d.auction = new KilimAuction(a);
        g -= gasleft();
        if (measure) {
            _measured(g, type(KilimAuction).creationCode, abi.encode(a), "KilimAuction deployment gas");
        }
    }

    function _auctionConfig(Config memory c, Deployed memory d)
        internal
        pure
        returns (KilimAuction.Config memory a)
    {
        a = c.auction;
        a.motifs = address(d.motifs);
        a.oneOfOne = address(d.oneOfOne);
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

    /// @dev The motif collection's constructor arguments, ABI-encoded as the creation transaction carries them.
    function _motifsArgs(Config memory c, Store memory s, address minter)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            minter,
            c.auction.treasury,
            c.motifCap,
            s.grids.addresses,
            s.grids.hash,
            s.names.addresses[0],
            s.names.hash,
            c.collectionDescription,
            c.collectionExternalUrl
        );
    }

    /// @dev The 1/1's constructor arguments, ABI-encoded as the creation transaction carries them.
    function _oneOfOneArgs(Config memory c, Store memory s, address minter, KilimMotifs motifs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            minter,
            c.auction.treasury,
            motifs,
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
        _checkTokens(c, s, d.motifs, d.oneOfOne, address(d.auction));
        KilimMotifs k = d.motifs;
        KilimOneOfOne o = d.oneOfOne;
        KilimAuction a = d.auction;
        if (
            a.treasury() != c.auction.treasury || a.startsAt() != c.auction.startsAt
                || a.duration() != c.auction.duration || a.extensionWindow() != c.auction.extensionWindow
                || a.incrementBps() != c.auction.incrementBps || a.reservePrice() != c.auction.reservePrice
                || address(a.motifs()) != address(k) || address(a.oneOfOne()) != address(o)
                || a.motifCap() != c.motifCap || a.maxMotifsPerBid() != c.auction.maxMotifsPerBid
                || a.endsAt() != 0
        ) revert Refused("auction read-back");
    }

    /// @dev The two token contracts, read back: `minter` must be the auction's address, deployed or not yet.
    function _checkTokens(Config memory c, Store memory s, KilimMotifs k, KilimOneOfOne o, address minter)
        internal
        view
    {
        if (
            k.minter() != minter || k.royaltyReceiver() != c.auction.treasury
                || k.deploymentChainId() != block.chainid || k.motifCap() != c.motifCap
                || k.gridsHash() != s.grids.hash || k.namesHash() != s.names.hash
                || k.namesChunk() != s.names.addresses[0] || !_same(k.gridChunks(), s.grids.addresses)
                || !_sameText(k.description(), c.collectionDescription)
                || !_sameText(k.externalUrl(), c.collectionExternalUrl)
        ) revert Refused("motifs read-back");
        if (
            o.minter() != minter || o.royaltyReceiver() != c.auction.treasury
                || address(o.motifs()) != address(k) || o.prefixHash() != s.prefix.hash
                || o.headHash() != s.head.hash || o.tailHash() != s.tail.hash
                || !_same(o.prefixChunks(), s.prefix.addresses) || !_same(o.headChunks(), s.head.addresses)
                || !_same(o.tailChunks(), s.tail.addresses) || !_sameText(o.name(), c.oneOfOneName)
                || !_sameText(o.description(), c.oneOfOneDescription)
                || !_sameText(o.externalUrl(), c.oneOfOneExternalUrl) || o.minted()
        ) revert Refused("1/1 read-back");
    }

    /// @dev Inside the dry run only: mint one motif and the 1/1 as the auction would, compare both
    ///      tokenURIs with the golden hashes and keep their gas under the policy ceiling.
    function _checkGolden(Config memory c, Store memory s, Deployed memory d) internal {
        uint256 motif = vm.parseJsonUint(s.motifManifest, ".golden.motif");
        uint256 id = _idShowing(d.motifs, motif);
        vm.prank(address(d.auction));
        d.motifs.mintMotifs(c.deployer, c.deployer, id, 1);
        if (
            sha256(bytes(d.motifs.tokenURI(id)))
                != vm.parseJsonBytes32(s.motifManifest, ".golden.tokenURI.sha256")
        ) {
            revert Refused("motif tokenURI differs from golden");
        }
        uint256 g = _readGas(address(d.motifs), abi.encodeCall(d.motifs.tokenURI, (id)));
        _log(string.concat("motif tokenURI gas ", vm.toString(g), " (token ", vm.toString(id), ")"));
        _gasPolicy(g, "motif tokenURI gas");
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

    /// @dev The first token id that shows `motif`; about 1,024 tries on average.
    function _idShowing(KilimMotifs k, uint256 motif) internal view returns (uint256 id) {
        for (id = 1; id <= 1_000_000; ++id) {
            if (k.motifOf(id) == motif) return id;
        }
        revert Refused("no token shows the golden motif");
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
    ///      must be nonzero. `loadStore` adds the content: the expected hashes and an artwork that reads
    ///      the grids.
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
        if (c.motifCap != LAUNCH_MOTIF_CAP) revert Refused("mainnet launch value: motifCap");
        if (a.maxMotifsPerBid != LAUNCH_MAX_MOTIFS_PER_BID) {
            revert Refused("mainnet launch value: maxMotifsPerBid");
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
                " (at the latest block: ",
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
        _log(string.concat("  motifStore        ", c.motifStore));
        _log(string.concat("  pageStore         ", c.pageStore));
        _show("treasury          ", a.treasury, LAUNCH_TREASURY);
        _show("reservePrice      ", a.reservePrice, LAUNCH_RESERVE_PRICE);
        _show("incrementBps      ", a.incrementBps, LAUNCH_INCREMENT_BPS);
        _show("duration          ", a.duration, LAUNCH_DURATION);
        _show("extensionWindow   ", a.extensionWindow, LAUNCH_EXTENSION_WINDOW);
        _show("motifCap          ", c.motifCap, LAUNCH_MOTIF_CAP);
        _show("maxMotifsPerBid   ", a.maxMotifsPerBid, LAUNCH_MAX_MOTIFS_PER_BID);
        _log(string.concat("  collection        ", c.collectionDescription, " | ", c.collectionExternalUrl));
        _show("1/1 name          ", c.oneOfOneName, LAUNCH_ONE_OF_ONE_NAME);
        _log(string.concat("  1/1 externalUrl   ", c.oneOfOneExternalUrl));
        _log(
            string.concat(
                "  texts             ",
                vm.toString(textsHash(c)),
                c.expected.texts == bytes32(0) ? " (no expected.texts: not compared)" : " (expected.texts)"
            )
        );
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
