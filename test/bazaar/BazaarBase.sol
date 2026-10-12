// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../../src/KilimBazaar.sol";
import {TestBase} from "../TestBase.sol";

interface VmBazaar {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function setBlockhash(uint256, bytes32) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function etch(address, bytes calldata) external;
    function roll(uint256) external;
    function warp(uint256) external;
    function cool(address) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function expectEmit(bool, bool, bool, bool, address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function expectRevert() external;
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function keyExistsJson(string calldata, string calldata) external view returns (bool);
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function toString(uint256) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
    function toString(bytes32) external pure returns (string memory);
    function getNonce(address) external view returns (uint64);
    function computeCreateAddress(address, uint256) external pure returns (address);
    function chainId(uint256) external;
}

/// @dev A receiver that accepts every kilim.
contract KilimHolder is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A contract with no receiver hook: _safeMint to it reverts.
contract NoHook {}

/// @dev Stands in for an auction in the constructor's refusals and in the terms the real one cannot reach
///      on demand: every read the Bazaar makes, each settable.
contract FakeAuction {
    KilimMotifs public motifs;
    KilimOneOfOne public oneOfOne;
    uint256 public MOTIF_PRICE = 0.001 ether;
    bool public settled;
    uint256 public highestBid;
    uint256 internal _first;
    uint256 internal _won;

    function setTokens(KilimMotifs motifs_, KilimOneOfOne oneOfOne_) external {
        motifs = motifs_;
        oneOfOne = oneOfOne_;
    }

    function setPrice(uint256 price) external {
        MOTIF_PRICE = price;
    }

    function settle(uint256 bid, uint256 first, uint256 won) external {
        settled = true;
        highestBid = bid;
        _first = first;
        _won = won;
    }

    function highestBidMotifs() external view returns (uint256, uint256) {
        return (_first, _won);
    }
}

/// @dev Motifs whose motifOf disagrees with the collection's formula, for the constructor's formula check.
contract WrongFormulaMotifs {
    address public minter;
    uint256 public constant deploymentChainId = 31337;
    uint256 public constant motifCap = 1000;

    constructor(address minter_) {
        minter = minter_;
    }

    function motifOf(uint256) external pure returns (uint16) {
        return 1;
    }
}

/// @dev The Bazaar's fixtures: the real KilimAuction run to settlement over a motif collection and a 1/1
///      built from a packed page store, and the Bazaar deployed against it. Motifs reach holders through
///      the auction's minter role (vm.prank), the winning bid's ids on the winner.
abstract contract BazaarBase is TestBase {
    VmBazaar internal constant vmb = VmBazaar(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant FIXTURE_PAGE = "../onchain/test/fixtures/page-store";
    string internal constant REAL_PAGE = "../onchain/build-page";
    string internal constant REAL_MOTIFS = "../onchain/build-motifs";
    /// The artist's description (11 October 2026) and link base.
    string internal constant BAZAAR_DESCRIPTION =
        "Kilims made from burned motifs by the engine of The Unwoven Kilim. Each is fixed by its seed and drawn only in the motifs that went into it.";
    string internal constant BAZAAR_URL = "https://orkhan.art/kilim/bazaar/";
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    address internal constant WINNER = address(0xE3FA0855);
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    /// The canonical EIP-2935 runtime (83 bytes), as on mainnet and Sepolia.
    bytes internal constant HISTORY_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";
    /// Holders other than the winner get ids from here up, outside any winning range the tests make.
    uint256 internal constant HOLDER_IDS = 500_001;
    uint256 internal constant BIG_CAP = 1_000_000;

    KilimAuction internal auction;
    KilimMotifs internal motifs;
    KilimOneOfOne internal oneOfOne;
    KilimBazaar internal bazaar;
    /// The page store the 1/1 was built from, and its HEAD (small). TAIL and PREFIX are read from the files
    /// when needed: the real ones are about a megabyte, too much to keep in test storage.
    string internal pageDir;
    bytes internal pageHead;
    /// The next unminted id handed to a holder by _fresh.
    uint256 internal nextHolderId = HOLDER_IDS;
    /// The motif collection's recorded chain id, kept for the local formula.
    uint256 internal motifChain;

    // ------------------------------------------------------------ deployment

    /// @dev The auction and its two tokens: stand-in grids and names, the 1/1 over the page store in `dir`.
    function _deployAuction(uint256 cap, string memory dir) internal {
        _deployAuction(cap, dir, standInGrids(), standInNames());
    }

    /// @dev The same over the given grids and names section.
    function _deployAuction(uint256 cap, string memory dir, bytes memory grids, bytes memory names) internal {
        pageDir = dir;
        pageHead = _pageFile("head.bin");
        _deployAuctionWithPage(
            cap, pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin")), grids, names
        );
    }

    function _pageFile(string memory name) internal view returns (bytes memory) {
        return vmb.readFileBinary(string.concat(pageDir, "/", name));
    }

    function _deployAuctionWithPage(
        uint256 cap,
        KilimOneOfOne.Page memory page,
        bytes memory grids,
        bytes memory names
    ) internal {
        KilimAuction.Config memory c = KilimAuction.Config({
            treasury: TREASURY,
            motifs: address(0),
            oneOfOne: address(0),
            startsAt: uint64(block.timestamp + 1 hours),
            duration: 22 hours,
            extensionWindow: 10 minutes,
            incrementBps: 500,
            reservePrice: RESERVE,
            maxMotifsPerBid: cap
        });
        // The store chunks first (they spend nonces), then the three contracts in order.
        address[] memory gridChunks = chunked(grids, 767 * 32);
        address namesChunk = sstore2(names);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        motifs = new KilimMotifs(
            next,
            TREASURY,
            cap,
            gridChunks,
            keccak256(grids),
            namesChunk,
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
        oneOfOne = new KilimOneOfOne(next, TREASURY, motifs, page, ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL);
        motifChain = motifs.deploymentChainId();
        c.motifs = address(motifs);
        c.oneOfOne = address(oneOfOne);
        auction = new KilimAuction(c);
        require(address(auction) == next, "auction address");
    }

    function _deployBazaar() internal {
        bazaar = _newBazaar("", BAZAAR_URL);
    }

    function _newBazaar(string memory imageBase, string memory url) internal returns (KilimBazaar) {
        return new KilimBazaar(auction, ARTIST, oneOfOne.tailHash(), BAZAAR_DESCRIPTION, url, imageBase);
    }

    /// @dev The usual fixture: cap 1,000,000, the committed page store, the Bazaar deployed before settlement.
    function _standard() internal {
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        _deployBazaar();
    }

    /// @dev One bid of `amount` by WINNER, then the close passes and anyone settles.
    function _settle(uint256 amount) internal {
        _openBidding(auction);
        vm.deal(WINNER, amount);
        _bid(auction, WINNER, amount);
        vm.warp(auction.endsAt());
        auction.settle();
        require(auction.settled(), "not settled");
    }

    // ------------------------------------------------------------ motifs

    /// @dev Mints ids first..first+qty-1 to `to`, as the auction's claim would.
    function _give(address to, uint256 first, uint256 qty) internal {
        for (uint256 done; done < qty;) {
            uint256 q = qty - done < 64 ? qty - done : 64;
            vm.prank(address(auction));
            motifs.mintMotifs(to, to, first + done, q);
            done += q;
        }
    }

    /// @dev `qty` fresh ids for `to` (approved for the Bazaar), from the holder range.
    function _fresh(address to, uint256 qty) internal returns (uint256[] memory list) {
        list = ids(nextHolderId, qty);
        _give(to, nextHolderId, qty);
        nextHolderId += qty;
        _approve(to);
    }

    function _approve(address holder) internal {
        vm.prank(holder);
        motifs.setApprovalForAll(address(bazaar), true);
    }

    function _make(address holder, uint256[] memory list) internal returns (uint256) {
        vm.prank(holder);
        return bazaar.make(list, holder);
    }

    function _deposit(address holder, uint256[] memory list) internal returns (uint256) {
        vm.prank(holder);
        return bazaar.deposit(list);
    }

    function _makeFromLoom(address holder, uint256[] memory list) internal returns (uint256) {
        vm.prank(holder);
        return bazaar.makeFromLoom(list, holder);
    }

    /// @dev The collection's own formula, recomputed here.
    ///      Hashed in scratch memory: a test scans thousands of ids, and abi.encode would allocate each time.
    function _motifOf(uint256 id) internal view returns (uint256 motif) {
        uint256 chain = motifChain;
        address m = address(motifs);
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, chain)
            mstore(add(p, 32), m)
            mstore(add(p, 64), id)
            motif := add(mod(keccak256(p, 96), 1024), 1)
        }
    }

    /// @dev The first id at or after `from` that shows `motif`.
    function _idShowing(uint256 motif, uint256 from) internal view returns (uint256 id) {
        for (id = from;; ++id) {
            if (_motifOf(id) == motif) return id;
        }
    }

    /// @dev The multiset of motifs `list` shows, as 1,024 counts.
    function _counts(uint256[] memory list) internal view returns (uint256[1025] memory c) {
        for (uint256 i; i < list.length; ++i) {
            ++c[_motifOf(list[i])];
        }
    }

    /// @dev The page's title rule: most burned, the lowest number among equals.
    function _title(uint256[1025] memory c) internal pure returns (uint256 title, uint256 distinct) {
        uint256 best;
        for (uint256 n = 1; n <= 1024; ++n) {
            if (c[n] != 0) ++distinct;
            if (c[n] > best) {
                best = c[n];
                title = n;
            }
        }
    }

    function _concat(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            out[a.length + i] = b[i];
        }
    }

    function _slice(uint256[] memory a, uint256 from, uint256 to)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = a[i];
        }
    }

    // ------------------------------------------------------------ references

    /// @dev The page's ranks: the Master at or above top, else the highest fixed cost at or under count.
    function _expectedRank(uint256 count, uint256 top) internal pure returns (uint8) {
        if (count < 10) return 0;
        if (count >= top) return 6;
        if (count >= 1000) return 5;
        if (count >= 300) return 4;
        if (count >= 100) return 3;
        if (count >= 30) return 2;
        return 1;
    }

    /// @dev S, built the plain way from the kilim's record and hand: each `[n,c]` written by vm.toString,
    ///      joined once (appending in a loop would make memory quadratic for a 1,024-entry hand).
    function _expectedPiece(uint256 tokenId) internal view returns (bytes memory s) {
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        (uint256[] memory n, uint256[] memory c) = bazaar.handOf(tokenId);
        bytes[] memory parts = new bytes[](n.length);
        uint256 total;
        for (uint256 i; i < n.length; ++i) {
            parts[i] =
                abi.encodePacked(i == 0 ? "" : ",", "[", vm.toString(n[i]), ",", vm.toString(c[i]), "]");
            total += parts[i].length;
        }
        bytes memory list = new bytes(total);
        uint256 pos;
        for (uint256 i; i < parts.length; ++i) {
            bytes memory part = parts[i];
            assembly ("memory-safe") {
                mcopy(add(add(list, 32), pos), add(part, 32), mload(part))
            }
            pos += part.length;
        }
        s = abi.encodePacked(
            ';window.KILIM_PIECE={"seed":"',
            _hex8(k.seed),
            '","motifs":[',
            list,
            '],"top":',
            vm.toString(bazaar.masterCost()),
            "}"
        );
    }

    function _hex8(uint256 v) internal pure returns (string memory) {
        bytes memory out = new bytes(10);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 8; ++i) {
            uint256 d = (v >> (28 - 4 * i)) & 15;
            out[2 + i] = bytes1(uint8(d < 10 ? 48 + d : 87 + d));
        }
        return string(out);
    }

    function _hexBytes(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "0123456789abcdef";
        out = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            out[2 * i] = table[uint8(data[i]) >> 4];
            out[2 * i + 1] = table[uint8(data[i]) & 0xf];
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev The words the project dropped, in any case and inside other words: "weav" anywhere, or "woven"
    ///      anywhere but in "unwoven" (The Unwoven Kilim). The deploy script refuses texts by the same rule.
    function _hasDroppedWord(bytes memory text) internal pure returns (bool) {
        bytes memory lower = new bytes(text.length);
        for (uint256 i; i < text.length; ++i) {
            bytes1 ch = text[i];
            lower[i] = ch >= "A" && ch <= "Z" ? bytes1(uint8(ch) + 32) : ch;
        }
        if (_contains(lower, "weav")) return true;
        for (uint256 i; i + 5 <= lower.length; ++i) {
            if (
                lower[i] == "w" && lower[i + 1] == "o" && lower[i + 2] == "v" && lower[i + 3] == "e"
                    && lower[i + 4] == "n" && !(i >= 2 && lower[i - 2] == "u" && lower[i - 1] == "n")
            ) return true;
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

    function _sub(bytes memory data, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(data, 32), from), sub(to, from))
        }
    }

    function _base64(bytes memory data) internal pure returns (string memory) {
        return Base64.encode(data);
    }

    /// @dev forge's console.log(string), called low-level: the console address has no code.
    function _log(string memory text) internal view {
        (bool ok,) = address(0x000000000000000000636F6e736F6c652e6c6f67)
            .staticcall(abi.encodeWithSignature("log(string)", text));
        ok;
    }
}
