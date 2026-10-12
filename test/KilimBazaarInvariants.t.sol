// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {InvariantBase, TestBase} from "./TestBase.sol";
import {BazaarBase} from "./bazaar/BazaarBase.sol";

/// @dev Three holders make kilims, fill and close looms, seal, roll the chain, pass kilims around and send
///      strays. Every action is guarded so it never reverts (the profile fails on any revert).
contract BazaarHandler is TestBase {
    KilimBazaar public immutable bazaar;
    KilimMotifs public immutable motifs;
    address[3] public actors;
    uint256 public constant PER_ACTOR = 3000;
    mapping(address => uint256) public nextId;
    mapping(address => uint256) public lastId;
    uint256 public strays;
    /// The fields of a record that must never change once made: everything but the seed, the SEALED bit
    /// and (before the seal) the seal block.
    mapping(uint256 => bytes32) public madeHash;
    /// The whole record once sealed: it must never change again.
    mapping(uint256 => bytes32) public sealedHash;
    uint256 public sealsDone;
    uint256 public rearmsSeen;

    constructor(KilimBazaar bazaar_, KilimAuction auction_) {
        bazaar = bazaar_;
        motifs = bazaar_.motifs();
        for (uint256 i; i < 3; ++i) {
            address a = address(uint160(0xAC7000 + i));
            actors[i] = a;
            uint256 first = 100_001 + i * 10_000;
            for (uint256 done; done < PER_ACTOR; done += 64) {
                uint256 q = PER_ACTOR - done < 64 ? PER_ACTOR - done : 64;
                vm.prank(address(auction_));
                motifs.mintMotifs(a, a, first + done, q);
            }
            nextId[a] = first;
            lastId[a] = first + PER_ACTOR;
            vm.prank(a);
            motifs.setApprovalForAll(address(bazaar_), true);
        }
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _take(address a, uint256 n) internal returns (uint256[] memory list) {
        list = ids(nextId[a], n);
        nextId[a] += n;
    }

    function _left(address a) internal view returns (uint256) {
        return lastId[a] - nextId[a];
    }

    function _made(uint256 tokenId) internal {
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        madeHash[tokenId] =
            keccak256(abi.encode(k.handKey, k.count, k.number, k.title, k.distinct, k.rank, k.flags));
    }

    function make(uint8 who, uint16 size) external {
        address a = actors[who % 3];
        uint256 n = _bound(size, 10, 40);
        if (_left(a) < n) return;
        vm.prank(a);
        _made(bazaar.make(_take(a, n), a));
    }

    function deposit(uint8 who, uint16 size) external {
        address a = actors[who % 3];
        uint256 n = bazaar.loomOf(a).handKey == 0 ? _bound(size, 10, 30) : _bound(size, 1, 30);
        if (_left(a) < n) return;
        vm.prank(a);
        bazaar.deposit(_take(a, n));
    }

    function makeFromLoom(uint8 who, uint16 size) external {
        address a = actors[who % 3];
        if (bazaar.loomOf(a).handKey == 0) return;
        uint256 n = _bound(size, 0, 5);
        if (_left(a) < n) n = 0;
        vm.prank(a);
        _made(bazaar.makeFromLoom(_take(a, n), a));
    }

    function seal(uint256 seed, uint8 blocks) external {
        vm.roll(block.number + _bound(blocks, 1, 3));
        uint256 total = bazaar.totalSupply();
        uint256[] memory list = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            list[i] = uint256(keccak256(abi.encode(seed, i))) % (total + 3);
        }
        uint256[] memory before = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            before[i] = list[i] != 0 && list[i] <= total ? bazaar.kilim(list[i]).sealBlock : 0;
        }
        sealsDone += bazaar.seal(list);
        for (uint256 i; i < 4; ++i) {
            uint256 id = list[i];
            if (id == 0 || id > total) continue;
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            if (k.flags & 1 != 0 && sealedHash[id] == 0) sealedHash[id] = keccak256(abi.encode(k));
            if (k.flags & 1 == 0 && k.sealBlock != before[i]) ++rearmsSeen;
        }
    }

    function roll(uint16 blocks) external {
        vm.roll(block.number + _bound(blocks, 1, 400));
    }

    function transferKilim(uint8 to, uint256 idSeed) external {
        uint256 total = bazaar.totalSupply();
        if (total == 0) return;
        uint256 id = 1 + idSeed % total;
        address owner = bazaar.ownerOf(id);
        vm.prank(owner);
        bazaar.transferFrom(owner, actors[to % 3], id);
    }

    function stray(uint8 who) external {
        address a = actors[who % 3];
        if (_left(a) == 0) return;
        uint256 id = _take(a, 1)[0];
        vm.prank(a);
        motifs.transferFrom(a, address(bazaar), id);
        ++strays;
    }
}

/// @notice Invariants over any sequence of the handler's actions (spec section 8.6).
contract KilimBazaarInvariants is InvariantBase, BazaarBase {
    BazaarHandler internal handler;
    address[] private targets;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(5_000_000);
        _standard();
        _settle(0.3 ether); // top 300: a few of the handler's looms can reach the Master
        handler = new BazaarHandler(bazaar, auction);
        targets.push(address(handler));
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    /// Σ lanes over open looms and kilims == burns made by the Bazaar (the only burner here).
    function invariantEveryBurnIsCountedOnce() public view {
        uint256 sum;
        uint256 total = bazaar.totalSupply();
        for (uint256 id = 1; id <= total; ++id) {
            (, uint256[] memory c) = bazaar.handOf(id);
            for (uint256 i; i < c.length; ++i) {
                sum += c[i];
            }
        }
        for (uint256 i; i < 3; ++i) {
            (, uint256[] memory c) = bazaar.loomHandOf(handler.actors(i));
            for (uint256 j; j < c.length; ++j) {
                sum += c[j];
            }
        }
        assertEq(sum, motifs.motifsBurned());
    }

    /// Each hand's lanes sum to its count, its nonzero lanes are `distinct`, ascending, and the title is the
    /// maximum with the lowest number among equals; the rank is the page's for that count.
    function invariantEveryHandIsConsistent() public view {
        uint256 top = bazaar.masterCost();
        uint256 total = bazaar.totalSupply();
        for (uint256 id = 1; id <= total; ++id) {
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            (uint256[] memory n, uint256[] memory c) = bazaar.handOf(id);
            _checkHand(n, c, k.count, k.distinct, k.title);
            assertEq(k.rank, _expectedRank(k.count, top));
            assertTrue(k.count >= 10);
        }
        for (uint256 i; i < 3; ++i) {
            KilimBazaar.Loom memory l = bazaar.loomOf(handler.actors(i));
            if (l.handKey == 0) continue;
            assertTrue(l.count >= 10);
            (uint256[] memory n, uint256[] memory c) = bazaar.loomHandOf(handler.actors(i));
            _checkHand(n, c, l.count, l.distinct, l.title);
        }
    }

    function _checkHand(
        uint256[] memory n,
        uint256[] memory c,
        uint256 count,
        uint256 distinct,
        uint256 title
    ) internal pure {
        assertEq(n.length, distinct);
        uint256 sum;
        uint256 best;
        uint256 bestN;
        for (uint256 i; i < n.length; ++i) {
            if (i != 0) assertTrue(n[i] > n[i - 1]);
            assertTrue(c[i] != 0);
            sum += c[i];
            if (c[i] > best) {
                best = c[i];
                bestN = n[i];
            }
        }
        assertEq(sum, count);
        assertEq(bestN, title);
    }

    function invariantStraysAreAllTheBazaarHolds() public view {
        assertEq(motifs.balanceOf(address(bazaar)), handler.strays());
        assertEq(bazaar.strayMotifs(), handler.strays());
    }

    /// Token ids run 1..totalSupply, each owned; numbers run 1..madeAt(rank) in each rank, each once.
    function invariantNumberingIsDense() public view {
        uint256 total = bazaar.totalSupply();
        uint256[7] memory seen;
        uint256[7] memory sumNumbers;
        for (uint256 id = 1; id <= total; ++id) {
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            assertTrue(bazaar.ownerOf(id) != address(0));
            ++seen[k.rank];
            sumNumbers[k.rank] += k.number;
            assertTrue(k.number >= 1 && k.number <= bazaar.madeAt(k.rank));
        }
        uint256 all;
        for (uint8 r = 1; r <= 6; ++r) {
            uint256 w = bazaar.madeAt(r);
            assertEq(seen[r], w);
            assertEq(sumNumbers[r], (w * (w + 1)) / 2);
            all += w;
        }
        assertEq(all, total);
        assertEq(seen[0], 0);
    }

    /// A made record never changes but for the seal; a sealed record never changes at all.
    function invariantRecordsChangeOnlyBySealing() public view {
        uint256 total = bazaar.totalSupply();
        for (uint256 id = 1; id <= total; ++id) {
            KilimBazaar.Kilim memory k = bazaar.kilim(id);
            uint8 flags = k.flags & ~uint8(1);
            assertEq(
                keccak256(abi.encode(k.handKey, k.count, k.number, k.title, k.distinct, k.rank, flags)),
                handler.madeHash(id)
            );
            bytes32 s = handler.sealedHash(id);
            if (s != 0) assertEq(keccak256(abi.encode(k)), s);
        }
    }
}
