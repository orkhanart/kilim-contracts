// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseSetup} from "../lib/chimera/src/BaseSetup.sol";
import {vm} from "../lib/chimera/src/Hevm.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {Blank, MoodyWallet} from "./Mocks.sol";

/// @dev The one cheatcode used here that Chimera's IHevm does not declare. Medusa and Foundry both have it.
interface IHevmNonce {
    function getNonce(address) external view returns (uint64);
}

/// @notice The whole Kilim system, deployed the way the deploy script orders it: the stores, the motif
///         collection and the 1/1 (both naming the auction's predicted address as minter), the auction,
///         then Kilim Bazaar (before settlement, so the closed Bazaar is reachable). The EIP-2935 history
///         contract is etched first, so the Bazaar's seed window is 8,191 blocks, as on mainnet.
abstract contract Setup is BaseSetup {
    using Strings for uint256;

    IHevmNonce internal constant vmNonce = IHevmNonce(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // ------------------------------------------------------------ configuration
    /// Mainnet auction terms (deploy/mainnet.json) except the motif cap and per-bid limit, cut down so
    /// that exhausting the pool and the per-bid clamp are both reachable in a short call sequence.
    uint64 internal constant DURATION = 86_400;
    uint64 internal constant EXTENSION = 600;
    uint16 internal constant INCREMENT_BPS = 1000;
    uint256 internal constant RESERVE = 0.01 ether;
    uint256 internal constant UNIT = 0.001 ether;
    uint256 internal constant MOTIF_CAP = 4000;
    uint256 internal constant MAX_PER_BID = 1500;
    uint256 internal constant MOTIF_COUNT = 1024;
    uint256 internal constant CHUNK = 24_575;
    uint256 internal constant FUNDS = 1e30;

    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    /// The canonical EIP-2935 runtime (83 bytes), as on mainnet and Sepolia (same bytes as test/bazaar/BazaarBase.sol).
    bytes internal constant HISTORY_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";

    uint256 internal constant PK_ALICE = 0xA11CE;
    uint256 internal constant PK_BOB = 0xB0B;
    uint256 internal constant PK_TREASURY = 0x7EA5;
    uint160 internal constant REGISTRANT_BASE = 0x5EED0000;

    // ------------------------------------------------------------ the system
    KilimAuction internal auction;
    KilimMotifs internal motifs;
    KilimOneOfOne internal oneOfOne;
    KilimBazaar internal bazaar;
    address internal treasury;
    /// 0, 1: EOAs with known keys; 2, 3: MoodyWallet contract wallets.
    address[4] internal actors;
    uint256 internal startsAt;

    // ------------------------------------------------------------ ghost state: auction
    uint256 internal ghostRegistrants; // throwaway wallets registered so far
    uint256 internal ghostBidTotal; // every wei taken in by accepted bids
    uint256 internal ghostOutbidTotal; // every outbid amount
    uint256 internal ghostPushedTotal; // outbid amounts paid straight back
    uint256 internal ghostDeferredTotal; // outbid amounts parked as pull refunds
    uint256 internal ghostWithdrawnTotal; // pull refunds paid out
    uint256 internal ghostProceedsPaid;
    uint256 internal ghostProceedsCalls;
    uint256 internal ghostDonated;
    uint256 internal ghostSettleCount;
    uint256 internal ghostSettledBid; // highestBid at settlement
    address internal ghostWinner;
    uint256 internal ghostAcceptedBids;
    uint256 internal ghostLastEndsAt;
    uint256 internal ghostLastBid;
    uint256 internal ghostLastBidFirstMotif;
    uint256 internal ghostLastBidMotifCount;
    uint256 internal ghostAllocated;
    uint256 internal ghostPrizeDeliveries; // settle deliveries + claimPrize successes
    address internal ghostPrizeRecipient;
    mapping(address => uint256) internal ghostDeferredOf;
    mapping(address => uint256) internal ghostWithdrawnOf;
    mapping(address => uint256) internal ghostCreditsOf;
    /// Ranges reserved by each actor's bids, in bid order, and the claim cursor into them (id, remaining).
    mapping(address => uint256[2][]) internal ghostRanges;
    mapping(address => uint256) internal ghostRangeCursor;

    // ------------------------------------------------------------ ghost state: motifs
    /// Motif ids each actor holds, as the harness moved them (claims, transfers, burns, kilims).
    mapping(address => uint256[]) internal owned;
    mapping(uint256 => uint256) internal ownedIndex; // id => index + 1 in its holder's list
    mapping(uint256 => address) internal ownedBy;
    uint256 internal ghostMinted;
    uint256 internal ghostDirectBurns;
    uint256 internal ghostBazaarBurns;
    uint256 internal ghostStrays;

    // ------------------------------------------------------------ ghost state: Bazaar
    struct GhostHand {
        uint256 count;
        uint256 distinct;
        uint256 minId;
        uint256 maxId;
    }

    /// Hands keyed by the Bazaar's hand key: motif => count, plus totals.
    mapping(uint256 => mapping(uint256 => uint256)) internal ghostHandCount;
    mapping(uint256 => GhostHand) internal ghostHand;
    mapping(address => uint256) internal ghostLoomKey; // 0 = no open loom
    mapping(uint256 => bytes32) internal ghostHandHash; // tokenId => keccak(handOf) at creation
    mapping(uint256 => bytes32) internal ghostMadeHash; // tokenId => fields that never change
    mapping(uint256 => uint256) internal ghostMadeBlock; // tokenId => block.number at make
    mapping(uint256 => bool) internal ghostSealed;
    mapping(uint256 => bytes32) internal ghostSealedHash; // tokenId => whole record once sealed
    mapping(uint256 => uint256) internal ghostSealCount;
    uint256 internal ghostKilims;
    uint256 internal ghostSeals;
    uint256 internal ghostRearms;
    uint256 internal ghostHistorySeals; // seals through the EIP-2935 path (age > 256)
    bool internal historyOn = true;

    // ------------------------------------------------------------ coverage counters (read by the report)
    uint256 public hitBid;
    uint256 public hitDeferredRefund;
    uint256 public hitWithdrawRefund;
    uint256 public hitSettle;
    uint256 public hitPrizeFallback;
    uint256 public hitClaimPrize;
    uint256 public hitProceeds;
    uint256 public hitClaimMotifs;
    uint256 public hitMake;
    uint256 public hitDeposit;
    uint256 public hitMakeFromLoom;
    uint256 public hitMaster;
    uint256 public hitWinningBidFlag;
    uint256 public historyReetched;
    uint256 public historyMismatch;
    uint256 public hitDenseMake;

    function setup() internal virtual override {
        vm.etch(HISTORY, HISTORY_CODE);
        treasury = vm.addr(PK_TREASURY);
        actors[0] = vm.addr(PK_ALICE);
        actors[1] = vm.addr(PK_BOB);
        actors[2] = address(new MoodyWallet());
        actors[3] = address(new MoodyWallet());
        vm.deal(address(this), FUNDS);
        for (uint256 i; i < 4; ++i) {
            vm.deal(actors[i], FUNDS);
        }

        // The stores spend nonces, so they come before the address prediction.
        bytes memory grids = _grids();
        bytes memory names = _names();
        address[] memory gridChunks = _chunked(grids, 767 * 32);
        address namesChunk = _sstore2(names);
        KilimOneOfOne.Page memory page = _page();

        startsAt = block.timestamp + 1 hours;
        address predicted = _createAddress(address(this), vmNonce.getNonce(address(this)) + 2);
        motifs = new KilimMotifs(
            predicted,
            treasury,
            MOTIF_CAP,
            gridChunks,
            keccak256(grids),
            namesChunk,
            keccak256(names),
            "Stand-in motif description",
            "https://kilim.example"
        );
        oneOfOne = new KilimOneOfOne(
            predicted, treasury, motifs, page, "The Unwoven Kilim", "Stand-in 1/1", "https://kilim.example"
        );
        auction = new KilimAuction(
            KilimAuction.Config({
                treasury: treasury,
                motifs: address(motifs),
                oneOfOne: address(oneOfOne),
                startsAt: uint64(startsAt),
                duration: DURATION,
                extensionWindow: EXTENSION,
                incrementBps: INCREMENT_BPS,
                reservePrice: RESERVE,
                maxMotifsPerBid: MAX_PER_BID
            })
        );
        require(address(auction) == predicted, "auction address");
        bazaar = new KilimBazaar(
            auction, treasury, oneOfOne.tailHash(), "Stand-in Bazaar", "https://kilim.example/k/", ""
        );
        require(bazaar.seedWindow() == 8191, "history not found");
        MoodyWallet(payable(actors[2])).wire(auction, bazaar);
        MoodyWallet(payable(actors[3])).wire(auction, bazaar);
    }

    // ------------------------------------------------------------ stand-in data and stores

    function _grids() private pure returns (bytes memory out) {
        out = new bytes(MOTIF_COUNT * 32);
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            bytes32 g = keccak256(abi.encode("kilim stand-in grid", n));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(sub(n, 1), 32)), g)
            }
        }
    }

    /// @dev The packer's layout: 1,025 big-endian uint16 offsets, then the names ("Meaning k", repeating).
    function _names() private pure returns (bytes memory out) {
        bytes[] memory names = new bytes[](MOTIF_COUNT);
        uint256 total;
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            names[n - 1] = bytes(string.concat("Meaning ", (n % 29 + 1).toString()));
            total += names[n - 1].length;
        }
        out = new bytes(2 * (MOTIF_COUNT + 1) + total);
        uint256 offset;
        uint256 pos = 2 * (MOTIF_COUNT + 1);
        for (uint256 i; i <= MOTIF_COUNT; ++i) {
            out[2 * i] = bytes1(uint8(offset >> 8));
            out[2 * i + 1] = bytes1(uint8(offset));
            if (i == MOTIF_COUNT) break;
            bytes memory name = names[i];
            for (uint256 k; k < name.length; ++k) {
                out[pos++] = name[k];
            }
            offset += name.length;
        }
    }

    /// @dev A stand-in page: HEAD ends with `const GRIDS='` and TAIL (base64) starts with `O2Nv` (`;co`),
    ///      the splice point the Bazaar's constructor checks.
    function _page() private returns (KilimOneOfOne.Page memory page) {
        bytes memory prefix = bytes(
            '{"name":"The Unwoven Kilim","description":"stand-in","image":"data:image/png;base64,iVBORw0KGgo=","animation_url":"data:text/html;base64,'
        );
        bytes memory head = bytes("<!doctype html><html><body><script>const GRIDS='");
        bytes memory tail = bytes(
            Base64.encode(bytes(";const BLOB=1;document.body.textContent=GRIDS.length</script></body></html>"))
        );
        page.prefixChunks = _chunked(prefix, CHUNK);
        page.prefixHash = keccak256(prefix);
        page.headChunks = _chunked(head, CHUNK);
        page.headHash = keccak256(head);
        page.tailChunks = _chunked(tail, CHUNK);
        page.tailHash = keccak256(tail);
    }

    function _sstore2(bytes memory data) private returns (address chunk) {
        require(data.length != 0 && data.length <= CHUNK, "chunk size");
        bytes memory initcode = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            chunk := create(0, add(initcode, 32), mload(initcode))
        }
        require(chunk != address(0), "chunk deployment failed");
    }

    function _chunked(bytes memory data, uint256 size) private returns (address[] memory chunks) {
        uint256 count = (data.length + size - 1) / size;
        chunks = new address[](count);
        for (uint256 k; k < count; ++k) {
            uint256 from = k * size;
            uint256 to = from + size < data.length ? from + size : data.length;
            bytes memory piece = new bytes(to - from);
            assembly ("memory-safe") {
                mcopy(add(piece, 32), add(add(data, 32), from), sub(to, from))
            }
            chunks[k] = _sstore2(piece);
        }
    }

    /// @dev CREATE address from the deployer and nonce (RLP), for nonces below 2^16.
    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0) data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        else if (nonce <= 0x7f) data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        else if (nonce <= 0xff) data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        else data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        return address(uint160(uint256(keccak256(data))));
    }

    // ------------------------------------------------------------ helpers shared by handlers and properties

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _isWallet(address a) internal view returns (bool) {
        return a == actors[2] || a == actors[3];
    }

    /// @dev Takes ETH for certain: an EOA (actors 0/1, the treasury, any address without code) or a wallet
    ///      in ACCEPT mood. A REENTER wallet usually takes it too, but its probes may run it out of gas.
    function _takesEthSurely(address a) internal view returns (bool) {
        if (_isWallet(a)) return MoodyWallet(payable(a)).ethMood() == 0;
        return a.code.length == 0;
    }

    function _takesEthNever(address a) internal view returns (bool) {
        if (!_isWallet(a)) return false;
        uint8 m = MoodyWallet(payable(a)).ethMood();
        return m == 1 || m == 2;
    }

    function _takesNftSurely(address a) internal view returns (bool) {
        if (_isWallet(a)) return MoodyWallet(payable(a)).nftMood() == 0;
        return a.code.length == 0;
    }

    function _takesNftNever(address a) internal view returns (bool) {
        if (!_isWallet(a)) return false;
        uint8 m = MoodyWallet(payable(a)).nftMood();
        return m == 1 || m == 2;
    }

    /// @dev The recipients a call may name: the four actors, the treasury, and the addresses the contracts
    ///      refuse (zero, the auction, the motif collection, the 1/1, the Bazaar).
    function _recipient(uint256 seed) internal view returns (address) {
        uint256 s = seed % 16;
        if (s < 4) return actors[s];
        if (s < 10) return actors[s % 4];
        if (s == 10) return treasury;
        if (s == 11) return address(0);
        if (s == 12) return address(auction);
        if (s == 13) return address(motifs);
        if (s == 14) return address(oneOfOne);
        return address(bazaar);
    }

    function _ownedAdd(address who, uint256 id) internal {
        owned[who].push(id);
        ownedIndex[id] = owned[who].length;
        ownedBy[id] = who;
    }

    function _ownedRemove(uint256 id) internal {
        address who = ownedBy[id];
        uint256 idx = ownedIndex[id];
        require(idx != 0, "ghost: not held");
        uint256[] storage list = owned[who];
        uint256 last = list[list.length - 1];
        list[idx - 1] = last;
        ownedIndex[last] = idx;
        list.pop();
        delete ownedIndex[id];
        delete ownedBy[id];
    }

    function _motifOf(uint256 id) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(motifs.deploymentChainId(), address(motifs), id))) % MOTIF_COUNT + 1;
    }

    function _expectedRank(uint256 count, uint256 top) internal pure returns (uint8) {
        if (count < 10) return 0;
        if (count >= top) return 6;
        if (count >= 1000) return 5;
        if (count >= 300) return 4;
        if (count >= 100) return 3;
        if (count >= 30) return 2;
        return 1;
    }

    function _handHash(uint256 tokenId) internal view returns (bytes32) {
        (uint256[] memory n, uint256[] memory c) = bazaar.handOf(tokenId);
        return keccak256(abi.encode(n, c));
    }

    function _madeHash(KilimBazaar.Kilim memory k) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(k.handKey, k.count, k.number, k.title, k.distinct, k.rank, k.flags & ~uint8(1))
        );
    }

    /// @dev Lets Medusa commit the current block (see Blank).
    function _mine() internal {
        new Blank();
    }

    /// @dev The value the chain's EIP-2935 contract holds for block n in this model: a fixed nonzero hash.
    function _historyHash(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("eip-2935 block", n));
    }
}
