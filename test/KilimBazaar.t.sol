// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase, FakeAuction, WrongFormulaMotifs, KilimHolder, NoHook} from "./bazaar/BazaarBase.sol";

/// @notice Kilim Bazaar's behaviour against the real auction run to settlement: the constructor's refusals,
///         the settlement gate, custody and burning, the one-call kilim, the loom, titles, ranks at every
///         boundary and close, numbering, the two tags, recipients, transfers and the views.
contract KilimBazaarTest is BazaarBase {
    event MotifsLoomed(address indexed weaver, uint256 indexed loom, uint256 quantity, uint256 count);
    event KilimMade(
        uint256 indexed tokenId,
        address indexed weaver,
        address indexed to,
        uint256 rank,
        uint256 number,
        uint256 count,
        uint256 title,
        uint256 sealBlock
    );

    uint256[8] internal CLOSES =
        [uint256(0.01 ether), 0.017 ether, 0.3 ether, 0.8 ether, 1 ether, 1.001 ether, 7.3 ether, 10 ether];

    function setUp() public {
        vm.warp(1_800_000_000);
        _standard();
    }

    // ------------------------------------------------------------ constructor

    /// @dev A fake auction with its own motif collection and a 1/1 over `page`, both naming the fake as minter.
    function _fakeWith(KilimOneOfOne.Page memory page) internal returns (FakeAuction fake) {
        fake = new FakeAuction();
        KilimMotifs m = newMotifs(address(fake), TREASURY, 1000);
        KilimOneOfOne o =
            new KilimOneOfOne(address(fake), TREASURY, m, page, ONE_OF_ONE_NAME, DESCRIPTION, "");
        fake.setTokens(m, o);
    }

    function _fixturePage() internal returns (KilimOneOfOne.Page memory) {
        return pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin"));
    }

    function _newFrom(FakeAuction fake) internal returns (KilimBazaar) {
        bytes32 tail = fake.oneOfOne().tailHash();
        return new KilimBazaar(KilimAuction(address(fake)), ARTIST, tail, BAZAAR_DESCRIPTION, "", "");
    }

    /// @dev The fake's Bazaar must be refused. Every read happens before the expectation.
    function _refused(FakeAuction fake) internal {
        bytes32 tail = fake.oneOfOne().tailHash();
        _expectConfig();
        new KilimBazaar(KilimAuction(address(fake)), ARTIST, tail, BAZAAR_DESCRIPTION, "", "");
    }

    function _expectConfig() internal {
        vm.expectRevert(KilimBazaar.InvalidConfiguration.selector);
    }

    function testConstructorRefusesAnAuctionWithoutCode() public {
        bytes32 tail = oneOfOne.tailHash();
        _expectConfig();
        new KilimBazaar(KilimAuction(address(0xBEEF)), ARTIST, tail, BAZAAR_DESCRIPTION, "", "");
    }

    function testConstructorRefusesAZeroRoyaltyReceiver() public {
        bytes32 tail = oneOfOne.tailHash();
        _expectConfig();
        new KilimBazaar(auction, address(0), tail, BAZAAR_DESCRIPTION, "", "");
    }

    function testAFakeAuctionWithAGoodPageIsAccepted() public {
        KilimBazaar b = _newFrom(_fakeWith(_fixturePage()));
        assertEq(b.motifPrice(), 0.001 ether);
    }

    function testConstructorRefusesTokensThatNameAnotherMinter() public {
        FakeAuction fake = new FakeAuction();
        fake.setTokens(motifs, oneOfOne); // both name the real auction as minter
        _refused(fake);
    }

    function testConstructorRefusesAOneOfOneOverOtherMotifs() public {
        FakeAuction fake = _fakeWith(_fixturePage());
        KilimMotifs other = newMotifs(address(fake), TREASURY, 1000);
        fake.setTokens(other, fake.oneOfOne());
        _refused(fake);
    }

    function testConstructorRefusesAOneOfOneMintedByAnother() public {
        FakeAuction fake = _fakeWith(_fixturePage());
        KilimOneOfOne foreign = new KilimOneOfOne(
            address(0x1234), TREASURY, fake.motifs(), _fixturePage(), ONE_OF_ONE_NAME, DESCRIPTION, ""
        );
        fake.setTokens(fake.motifs(), foreign);
        _refused(fake);
    }

    function testConstructorRefusesAZeroMotifPrice() public {
        FakeAuction fake = _fakeWith(_fixturePage());
        fake.setPrice(0);
        _refused(fake);
    }

    function testConstructorRefusesAnotherMotifFormula() public {
        FakeAuction fake = new FakeAuction();
        WrongFormulaMotifs m = new WrongFormulaMotifs(address(fake));
        KilimOneOfOne o = new KilimOneOfOne(
            address(fake), TREASURY, KilimMotifs(address(m)), _fixturePage(), ONE_OF_ONE_NAME, DESCRIPTION, ""
        );
        fake.setTokens(KilimMotifs(address(m)), o);
        _refused(fake);
    }

    function testConstructorRefusesAnotherTailHash() public {
        vm.expectRevert(KilimBazaar.InvalidConfiguration.selector);
        new KilimBazaar(auction, ARTIST, keccak256("another page"), BAZAAR_DESCRIPTION, "", "");
    }

    /// @dev TestBase's stand-in page carries the rest of the loader starting with the quote, so its TAIL
    ///      starts `Jzt…`, not `O2Nv`: rightly refused.
    function testConstructorRefusesTheStandInPage() public {
        _refused(_fakeWith(standInPage()));
    }

    function testConstructorRefusesAHeadThatDoesNotEndAtTheGrids() public {
        _refused(
            _fakeWith(
                pageFrom(_pageFile("prefix.bin"), bytes("<script>{const GRIDS=\""), _pageFile("tail.bin"))
            )
        );
        _refused(
            _fakeWith(
                pageFrom(_pageFile("prefix.bin"), bytes("<script>{const GRIDS = '"), _pageFile("tail.bin"))
            )
        );
    }

    function testConstructorRefusesHeadAndTailChunksTooShortToCheck() public {
        // 12 data bytes in the last HEAD chunk (13 of code): too short to end with the 13-byte marker.
        _refused(_fakeWith(pageFrom(_pageFile("prefix.bin"), bytes("onst GRIDS='"), _pageFile("tail.bin"))));
        // Exactly the marker is enough.
        _newFrom(_fakeWith(pageFrom(_pageFile("prefix.bin"), bytes("const GRIDS='"), _pageFile("tail.bin"))));
        // 3 data bytes in the first TAIL chunk: too short; exactly `O2Nv` is enough.
        _refused(_fakeWith(pageFrom(_pageFile("prefix.bin"), pageHead, bytes("O2N"))));
        _newFrom(_fakeWith(pageFrom(_pageFile("prefix.bin"), pageHead, bytes("O2Nv"))));
    }

    function testConstructorRefusesATailThatDoesNotStartAfterTheQuote() public {
        _refused(
            _fakeWith(pageFrom(_pageFile("prefix.bin"), pageHead, bytes(Base64.encode("const BLOB='x'"))))
        );
        _refused(_fakeWith(pageFrom(_pageFile("prefix.bin"), pageHead, bytes("o2Nv"))));
    }

    function testConstructorRefusesBadCharactersInEveryText() public {
        bytes memory bad = hex"225c23250a001f7fc2ff"; // " \ # % LF NUL US DEL and two non-ASCII
        bytes32 tail = oneOfOne.tailHash();
        for (uint256 i; i < bad.length; ++i) {
            string memory text = string(abi.encodePacked("ok", bad[i], "ok"));
            _expectConfig();
            new KilimBazaar(auction, ARTIST, tail, text, "", "");
            _expectConfig();
            new KilimBazaar(auction, ARTIST, tail, "", text, "");
            _expectConfig();
            new KilimBazaar(auction, ARTIST, tail, "", "", text);
        }
    }

    function testConstructorAcceptsEveryOtherPrintableCharacter() public {
        bytes memory all = new bytes(95 - 4);
        uint256 n;
        for (uint256 c = 0x20; c <= 0x7e; ++c) {
            if (c == 0x22 || c == 0x5c || c == 0x23 || c == 0x25) continue;
            all[n++] = bytes1(uint8(c));
        }
        KilimBazaar b =
            new KilimBazaar(auction, ARTIST, oneOfOne.tailHash(), string(all), string(all), string(all));
        assertEq(b.description(), string(all));
        assertEq(b.imageBase(), string(all));
    }

    function testImmutablesEqualTheAuctions() public view {
        assertEq(address(bazaar.auction()), address(auction));
        assertEq(address(bazaar.motifs()), address(motifs));
        assertEq(address(bazaar.oneOfOne()), address(oneOfOne));
        assertEq(bazaar.motifPrice(), auction.MOTIF_PRICE());
        assertEq(bazaar.motifPrice(), 0.001 ether);
        assertEq(bazaar.motifChainId(), motifs.deploymentChainId());
        assertEq(bazaar.motifChainId(), block.chainid);
        assertEq(bazaar.royaltyReceiver(), ARTIST);
        assertEq(bazaar.description(), BAZAAR_DESCRIPTION);
        assertEq(bazaar.externalUrl(), BAZAAR_URL);
        assertEq(bazaar.imageBase(), "");
        assertEq(bazaar.name(), "Kilim Bazaar");
        assertEq(bazaar.symbol(), "KILIM");
        assertEq(bazaar.totalSupply(), 0);
        assertEq(bazaar.FLOOR(), 10);
        assertEq(bazaar.MAX_BATCH(), 65_535);
        assertEq(bazaar.MASTER(), 6);
        assertEq(bazaar.HISTORY(), HISTORY);
    }

    /// @dev The description carries none of the project's dropped words, in any case; the helper itself
    ///      catches them inside words and lets only "unwoven" (the 1/1's name) through.
    function testTheDescriptionAvoidsTheDroppedWords() public view {
        assertTrue(!_hasDroppedWord(bytes(bazaar.description())));
        assertTrue(!_hasDroppedWord("THE UNWOVEN KILIM, unwoven"));
        assertTrue(_hasDroppedWord("WOVEN") && _hasDroppedWord("hand-woven") && _hasDroppedWord("(woven)"));
        assertTrue(_hasDroppedWord("Interweaving") && _hasDroppedWord("rewoven") && _hasDroppedWord("woven"));
    }

    function testSeedWindowIs8191WithTheHistoryContractAnd256Without() public {
        assertEq(bazaar.seedWindow(), 256);
        assertEq(keccak256(HISTORY_CODE), bazaar.HISTORY_CODEHASH());
        assertEq(HISTORY_CODE.length, 83);
        vmb.etch(HISTORY, HISTORY_CODE);
        assertEq(_newBazaar("", "").seedWindow(), 8191);
        // Any other code there counts as none.
        vmb.etch(HISTORY, hex"00");
        assertEq(_newBazaar("", "").seedWindow(), 256);
    }

    // ------------------------------------------------------------ the settlement gate

    function testEveryWriteWaitsForSettlement() public {
        uint256[] memory list = _fresh(ALICE, 10);
        vm.startPrank(ALICE);
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.make(list, ALICE);
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.deposit(list);
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.makeFromLoom(list, ALICE);
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.makeFromLoom(new uint256[](0), ALICE);
        vm.stopPrank();
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.masterCost();
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.rankFor(10);
        (uint256[6] memory costs, bool open) = bazaar.ladder();
        assertTrue(!open);
        assertEq(costs[0], 10);
        assertEq(costs[1], 30);
        assertEq(costs[2], 100);
        assertEq(costs[3], 300);
        assertEq(costs[4], 1000);
        assertEq(costs[5], 0);
        assertEq(bazaar.seal(ids(1, 3)), 0);
        // A bid alone opens nothing: only settlement does.
        _openBidding(auction);
        vm.deal(WINNER, 1 ether);
        _bid(auction, WINNER, 0.017 ether);
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.NotSettled.selector);
        bazaar.make(list, ALICE);
        vm.warp(auction.endsAt());
        auction.settle();
        assertEq(bazaar.masterCost(), 17);
        assertEq(_make(ALICE, list), 1);
        assertEq(bazaar.kilim(1).rank, 1);
    }

    /// @dev At every close the spec names: the Master's cost, the ladder and every rank boundary.
    function testMasterCostLadderAndRanksAtEveryClose() public {
        uint256 snap = vmb.snapshotState();
        for (uint256 i; i < CLOSES.length; ++i) {
            vmb.revertToState(snap);
            _settle(CLOSES[i]);
            uint256 top = CLOSES[i] / 1e15;
            assertEq(bazaar.masterCost(), top);
            assertEq(bazaar.masterCost(), auction.highestBid() / 1e15);
            (uint256[6] memory costs, bool open) = bazaar.ladder();
            assertTrue(open);
            uint256[5] memory fixedCosts = [uint256(10), 30, 100, 300, 1000];
            for (uint256 r; r < 5; ++r) {
                assertEq(costs[r], fixedCosts[r] < top ? fixedCosts[r] : 0);
            }
            assertEq(costs[5], top);
            uint256[13] memory counts =
                [uint256(9), 10, 29, 30, 99, 100, 299, 300, 999, 1000, top - 1, top, top + 1];
            for (uint256 c; c < counts.length; ++c) {
                assertEq(bazaar.rankFor(counts[c]), _expectedRank(counts[c], top));
            }
            assertEq(bazaar.rankFor(0), 0);
            assertEq(bazaar.rankFor(top), 6);
        }
    }

    // ------------------------------------------------------------ custody and burning

    function testWeaveBurnsEveryMotifAndHoldsNone() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 12);
        uint256 burnedBefore = motifs.motifsBurned();
        uint256 tokenId = _make(ALICE, list);
        assertEq(motifs.motifsBurned(), burnedBefore + 12);
        for (uint256 i; i < list.length; ++i) {
            assertTrue(motifs.burned(list[i]));
            vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", list[i]));
            motifs.ownerOf(list[i]);
        }
        assertEq(motifs.balanceOf(address(bazaar)), 0);
        assertEq(motifs.balanceOf(ALICE), 0);
        assertEq(bazaar.ownerOf(tokenId), ALICE);
        assertEq(bazaar.balanceOf(ALICE), 1);
        assertEq(bazaar.strayMotifs(), 0);
    }

    function testPullsOnlyFromTheCallerEvenWhenAnotherHolderApproved() public {
        _settle(10 ether);
        uint256[] memory bobs = _fresh(BOB, 10);
        _approve(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", ALICE, bobs[0], BOB)
        );
        bazaar.make(bobs, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", ALICE, bobs[0], BOB)
        );
        bazaar.deposit(bobs);
        assertEq(motifs.balanceOf(BOB), 10);
        assertEq(motifs.motifsBurned(), 0);
    }

    function testRevertsWithoutApproval() public {
        _settle(10 ether);
        uint256[] memory list = ids(nextHolderId, 10);
        _give(ALICE, nextHolderId, 10);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", address(bazaar), list[0])
        );
        bazaar.make(list, ALICE);
        assertEq(motifs.motifsBurned(), 0);
    }

    function testWorksWithPerTokenApprove() public {
        _settle(10 ether);
        uint256[] memory list = ids(nextHolderId, 10);
        _give(ALICE, nextHolderId, 10);
        vm.startPrank(ALICE);
        for (uint256 i; i < list.length; ++i) {
            motifs.approve(address(bazaar), list[i]);
        }
        uint256 tokenId = bazaar.make(list, ALICE);
        vm.stopPrank();
        assertEq(bazaar.kilim(tokenId).count, 10);
    }

    function testRevertsOnADuplicateABurnedIdIdZeroAndAnIdAboveTheCap() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 11);
        // A duplicate: the second transferFrom finds the Bazaar already owns it.
        uint256[] memory dup = _slice(list, 0, 10);
        dup[9] = dup[0];
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC721IncorrectOwner(address,uint256,address)", ALICE, dup[0], address(bazaar)
            )
        );
        bazaar.make(dup, ALICE);
        assertEq(motifs.motifsBurned(), 0);
        _make(ALICE, _slice(list, 0, 10));
        // A burned id.
        uint256[] memory more = _fresh(ALICE, 9);
        uint256[] memory withBurned = _concat(more, _slice(list, 0, 1));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", list[0]));
        bazaar.make(withBurned, ALICE);
        // Id 0 and an id above the cap.
        uint256[] memory zero = _concat(more, new uint256[](1));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 0));
        bazaar.make(zero, ALICE);
        uint256[] memory above = _concat(more, ids(BIG_CAP + 1, 1));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", BIG_CAP + 1));
        bazaar.make(above, ALICE);
        assertEq(motifs.motifsBurned(), 10);
        assertEq(motifs.balanceOf(address(bazaar)), 0);
    }

    function testRevertsOnAnEmptyListAndOnMoreThanMaxBatch() public {
        _settle(10 ether);
        uint256[] memory none = new uint256[](0);
        uint256[] memory huge = new uint256[](65_536);
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.TooFewMotifs.selector, 0));
        bazaar.make(none, ALICE);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.TooFewMotifs.selector, 0));
        bazaar.deposit(none);
        vm.expectRevert(KilimBazaar.InvalidQuantity.selector);
        bazaar.make(huge, ALICE);
        vm.expectRevert(KilimBazaar.InvalidQuantity.selector);
        bazaar.deposit(huge);
        vm.stopPrank();
        _deposit(ALICE, _fresh(ALICE, 10));
        vm.startPrank(ALICE);
        vm.expectRevert(KilimBazaar.InvalidQuantity.selector);
        bazaar.deposit(none);
        vm.expectRevert(KilimBazaar.InvalidQuantity.selector);
        bazaar.deposit(huge);
        vm.expectRevert(KilimBazaar.InvalidQuantity.selector);
        bazaar.makeFromLoom(huge, ALICE);
        vm.stopPrank();
        assertEq(motifs.motifsBurned(), 10);
    }

    // ------------------------------------------------------------ make

    function testWeaveRecordsTheHandAndLeavesTheLoomAlone() public {
        _settle(10 ether);
        _deposit(ALICE, _fresh(ALICE, 12));
        KilimBazaar.Loom memory before = bazaar.loomOf(ALICE);
        (uint256[] memory n0, uint256[] memory c0) = bazaar.loomHandOf(ALICE);
        uint256[] memory list = _fresh(ALICE, 37);
        uint256 tokenId = _make(ALICE, list);
        KilimBazaar.Loom memory afterLoom = bazaar.loomOf(ALICE);
        assertEq(keccak256(abi.encode(before)), keccak256(abi.encode(afterLoom)));
        (uint256[] memory n1, uint256[] memory c1) = bazaar.loomHandOf(ALICE);
        assertEq(keccak256(abi.encode(n0, c0)), keccak256(abi.encode(n1, c1)));
        _checkHand(tokenId, list);
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        assertEq(k.count, 37);
        assertEq(k.rank, 2);
        assertEq(k.number, 1);
        assertEq(k.handKey, 2); // the loom took key 1
        assertEq(k.sealBlock, block.number + 1);
        assertEq(k.seed, 0);
    }

    /// @dev handOf equals the multiset of motifOf(ids), ascending; the record's distinct and title agree.
    function _checkHand(uint256 tokenId, uint256[] memory list) internal view {
        uint256[1025] memory want = _counts(list);
        (uint256[] memory n, uint256[] memory c) = bazaar.handOf(tokenId);
        uint256 k;
        uint256 total;
        for (uint256 m = 1; m <= 1024; ++m) {
            if (want[m] == 0) continue;
            assertEq(n[k], m);
            assertEq(c[k], want[m]);
            total += c[k];
            ++k;
        }
        assertEq(k, n.length);
        assertEq(total, list.length);
        (uint256 title, uint256 distinct) = _title(want);
        KilimBazaar.Kilim memory rec = bazaar.kilim(tokenId);
        assertEq(rec.title, title);
        assertEq(rec.distinct, distinct);
        assertEq(rec.count, list.length);
    }

    function testWeaveRefusesNineMotifs() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 9);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.TooFewMotifs.selector, 9));
        bazaar.make(list, ALICE);
    }

    mapping(uint256 => bool) internal _picked;

    /// @dev One fresh id for each of `wanted` (a motif asked for twice gets two ids), minted to ALICE.
    function _idsFor(uint256[] memory wanted) internal returns (uint256[] memory list) {
        list = new uint256[](wanted.length);
        for (uint256 i; i < wanted.length; ++i) {
            uint256 id = 600_000;
            while (_motifOf(id) != wanted[i] || _picked[id]) {
                ++id;
            }
            _picked[id] = true;
            list[i] = id;
            _give(ALICE, id, 1);
        }
        _approve(ALICE);
    }

    function _motifList(uint256[10] memory m) internal pure returns (uint256[] memory out) {
        out = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            out[i] = m[i];
        }
    }

    /// @dev PACKED exactly when ceil(distinct / 8) < touched words, with forced cases either side of it.
    function testPackedOrDenseIsExactlyTheRule() public {
        _settle(10 ether);
        // 10 motifs in 10 words: ceil(10/8) = 2 < 10, PACKED.
        _checkFormat(_motifList([uint256(1), 17, 33, 49, 65, 81, 97, 113, 129, 145]), true);
        // One motif ten times: 1 word, ceil(1/8) = 1, not fewer: DENSE.
        _checkFormat(_motifList([uint256(5), 5, 5, 5, 5, 5, 5, 5, 5, 5]), false);
        // 8 distinct in 2 words: 1 < 2, PACKED.
        _checkFormat(_motifList([uint256(1), 2, 3, 4, 5, 6, 7, 17, 1, 2]), true);
        // 9 distinct in 2 words: 2 < 2 fails, DENSE.
        _checkFormat(_motifList([uint256(1), 2, 3, 4, 5, 6, 7, 8, 17, 1]), false);
        // 10 distinct in 1 word: DENSE.
        _checkFormat(_motifList([uint256(1), 2, 3, 4, 5, 6, 7, 8, 9, 10]), false);
        // The last motif and the first together: PACKED.
        _checkFormat(_motifList([uint256(1024), 1024, 1024, 1, 1, 1, 1, 1, 1, 1]), true);
    }

    function _checkFormat(uint256[] memory wanted, bool packed) internal {
        uint256[] memory list = _idsFor(wanted);
        uint256 tokenId = _make(ALICE, list);
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        assertTrue((k.flags & bazaar.PACKED() != 0) == packed);
        // and the rule computed independently
        uint256[1025] memory c = _counts(list);
        (, uint256 distinct) = _title(c);
        uint256 words;
        for (uint256 w; w < 64; ++w) {
            for (uint256 j; j < 16; ++j) {
                if (c[w * 16 + j + 1] != 0) {
                    ++words;
                    break;
                }
            }
        }
        assertTrue(((distinct + 7) / 8 < words) == packed);
        _checkHand(tokenId, list);
    }

    // ------------------------------------------------------------ the loom

    function testTheFirstDepositNeedsTenAndLaterOnesAnyNumber() public {
        _settle(10 ether);
        uint256[] memory nine = _fresh(ALICE, 9);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.TooFewMotifs.selector, 9));
        bazaar.deposit(nine);
        uint256[] memory first = _fresh(ALICE, 10);
        vm.expectEmit();
        emit MotifsLoomed(ALICE, 1, 10, 10);
        assertEq(_deposit(ALICE, first), 1);
        uint256[] memory one = _fresh(ALICE, 1);
        vm.expectEmit();
        emit MotifsLoomed(ALICE, 1, 1, 11);
        assertEq(_deposit(ALICE, one), 1);
        assertEq(_deposit(ALICE, nine), 1);
        uint256[] memory all = _concat(_concat(first, one), nine);
        _checkLoom(ALICE, all);
    }

    /// @dev The open loom's record and hand equal the multiset of `all`, folded from scratch.
    function _checkLoom(address weaver, uint256[] memory all) internal view {
        KilimBazaar.Loom memory l = bazaar.loomOf(weaver);
        uint256[1025] memory want = _counts(all);
        (uint256 title, uint256 distinct) = _title(want);
        assertEq(l.count, all.length);
        assertEq(l.title, title);
        assertEq(l.titleCount, want[title]);
        assertEq(l.distinct, distinct);
        uint256 lo = type(uint256).max;
        uint256 hi;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] < lo) lo = all[i];
            if (all[i] > hi) hi = all[i];
        }
        assertEq(l.minId, lo);
        assertEq(l.maxId, hi);
        (uint256[] memory n, uint256[] memory c) = bazaar.loomHandOf(weaver);
        assertEq(n.length, distinct);
        uint256 k;
        for (uint256 m = 1; m <= 1024; ++m) {
            if (want[m] == 0) continue;
            assertEq(n[k], m);
            assertEq(c[k], want[m]);
            ++k;
        }
    }

    /// @dev makeFromLoom([]) after the last deposit and makeFromLoom(last batch) make the same kilim.
    function testMakeFromLoomWithOrWithoutIdsGivesTheSameRecord() public {
        _settle(10 ether);
        uint256[] memory a = _fresh(ALICE, 60);
        uint256[] memory b = _fresh(ALICE, 45);
        uint256 snap = vmb.snapshotState();
        _deposit(ALICE, a);
        _deposit(ALICE, b);
        uint256 t1 = _makeFromLoom(ALICE, new uint256[](0));
        KilimBazaar.Kilim memory k1 = bazaar.kilim(t1);
        (uint256[] memory n1, uint256[] memory c1) = bazaar.handOf(t1);
        vmb.revertToState(snap);
        _deposit(ALICE, a);
        uint256 t2 = _makeFromLoom(ALICE, b);
        KilimBazaar.Kilim memory k2 = bazaar.kilim(t2);
        (uint256[] memory n2, uint256[] memory c2) = bazaar.handOf(t2);
        assertEq(t1, t2);
        assertEq(keccak256(abi.encode(k1)), keccak256(abi.encode(k2)));
        assertEq(keccak256(abi.encode(n1, c1)), keccak256(abi.encode(n2, c2)));
        assertEq(k1.count, 105);
        assertEq(k1.rank, 3);
        _checkHand(t1, _concat(a, b));
    }

    function testTheLoomIsDeletedAndTheNextDepositOpensANewKey() public {
        _settle(10 ether);
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.NoLoom.selector);
        bazaar.makeFromLoom(new uint256[](0), ALICE);
        assertEq(_deposit(ALICE, _fresh(ALICE, 10)), 1);
        assertEq(_makeFromLoom(ALICE, new uint256[](0)), 1);
        assertEq(bazaar.loomOf(ALICE).handKey, 0);
        (uint256[] memory n,) = bazaar.loomHandOf(ALICE);
        assertEq(n.length, 0);
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.NoLoom.selector);
        bazaar.makeFromLoom(new uint256[](0), ALICE);
        // a one-call kilim in between takes key 2
        _make(ALICE, _fresh(ALICE, 10));
        assertEq(_deposit(ALICE, _fresh(ALICE, 10)), 3);
        assertEq(bazaar.kilim(1).handKey, 1);
        assertEq(bazaar.kilim(2).handKey, 2);
        // looms are per wallet
        assertEq(_deposit(BOB, _fresh(BOB, 10)), 4);
        assertEq(bazaar.loomOf(ALICE).handKey, 3);
    }

    function testAnotherWalletCannotTouchYourLoom() public {
        _settle(10 ether);
        uint256[] memory mine = _fresh(ALICE, 10);
        _deposit(ALICE, mine);
        _fresh(BOB, 10);
        // BOB's calls act on BOB's own (absent) loom.
        vm.prank(BOB);
        vm.expectRevert(KilimBazaar.NoLoom.selector);
        bazaar.makeFromLoom(new uint256[](0), BOB);
        assertEq(bazaar.loomOf(ALICE).count, 10);
    }

    // ------------------------------------------------------------ titles

    function testTitleTiesGoToTheLowerNumber() public {
        _settle(10 ether);
        // motif 700 three times, motif 300 three times, four others once
        uint256[] memory list = _idsFor(_motifList([uint256(700), 700, 700, 300, 300, 300, 1, 2, 900, 1000]));
        uint256 tokenId = _make(ALICE, list);
        assertEq(bazaar.kilim(tokenId).title, 300);
    }

    /// @dev A lower motif reaching an untouched higher title's count in a later batch takes the title; a
    ///      higher one reaching it does not.
    function testTitleTiesAcrossBatches() public {
        _settle(10 ether);
        uint256[] memory first = _idsFor(_motifList([uint256(900), 900, 1, 2, 3, 4, 5, 6, 7, 8]));
        _deposit(ALICE, first);
        assertEq(bazaar.loomOf(ALICE).title, 900);
        uint256[] memory higher = _idsFor(_twoOf(950));
        _deposit(ALICE, higher);
        assertEq(bazaar.loomOf(ALICE).title, 900);
        uint256[] memory lower = _idsFor(_twoOf(500));
        _deposit(ALICE, lower);
        assertEq(bazaar.loomOf(ALICE).title, 500);
        assertEq(bazaar.loomOf(ALICE).titleCount, 2);
        // a third of 950 now leads outright
        uint256[] memory third = _idsFor(_threeOf(950));
        uint256 tokenId = _makeFromLoom(ALICE, _slice(third, 0, 1));
        assertEq(bazaar.kilim(tokenId).title, 950);
        _checkHand(tokenId, _concat(_concat(_concat(first, higher), lower), _slice(third, 0, 1)));
    }

    // ------------------------------------------------------------ the 16-bit lanes

    /// @dev A loom's record (section 2: `_looms` at slot 10) and its hand word holding `motif` (`_hands`, 12).
    function _loomSlot(address who) internal pure returns (bytes32) {
        return keccak256(abi.encode(who, uint256(10)));
    }

    function _handWordSlot(uint256 key, uint256 motif) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(key, uint256(12)))) + ((motif - 1) >> 4));
    }

    /// @dev Sets the loom's count of `motif` (already in it) to `c` in storage, and keeps the record agreeing:
    ///      the count moves by the difference, and `motif` leads with `c` (it is set far above the rest).
    function _forceLane(address who, uint256 motif, uint256 c) internal {
        KilimBazaar.Loom memory l = bazaar.loomOf(who);
        bytes32 wordSlot = _handWordSlot(l.handKey, motif);
        uint256 w = uint256(vmb.load(address(bazaar), wordSlot));
        uint256 shift = ((motif - 1) & 15) << 4;
        uint256 old = (w >> shift) & 0xffff;
        require(old != 0, "the motif is not in the loom");
        vmb.store(address(bazaar), wordSlot, bytes32((w & ~(uint256(0xffff) << shift)) | (c << shift)));
        uint256 count = l.count + c - old;
        uint256 record = uint256(l.handKey) | (count << 32) | (uint256(l.minId) << 64)
            | (uint256(l.maxId) << 96) | (motif << 128) | (c << 144) | (uint256(l.distinct) << 160);
        vmb.store(address(bazaar), _loomSlot(who), bytes32(record));
        KilimBazaar.Loom memory after_ = bazaar.loomOf(who);
        assertEq(after_.handKey, l.handKey);
        assertEq(after_.count, count);
        assertEq(after_.title, motif);
        assertEq(after_.titleCount, c);
        assertEq(after_.distinct, l.distinct);
    }

    /// @dev The guard in _fold: a count of 0xffff plus one would carry into the next motif's lane (motif 18
    ///      here), silently corrupting the count, distinct and the title; it reverts CountOverflow instead,
    ///      through deposit and through makeFromLoom. At 0xfffe one more fits exactly and the neighbour is untouched.
    function testALoomCountNeverSpillsIntoTheNextMotifsLane() public {
        _settle(10 ether);
        _deposit(ALICE, _idsFor(_motifList([uint256(17), 18, 1, 2, 3, 4, 5, 6, 7, 8])));
        uint256[] memory one = new uint256[](1);
        one[0] = 17;
        one = _idsFor(one);
        uint256 snap = vmb.snapshotState();
        _forceLane(ALICE, 17, 0xffff);
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.CountOverflow.selector);
        bazaar.deposit(one);
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.CountOverflow.selector);
        bazaar.makeFromLoom(one, ALICE);
        assertEq(motifs.ownerOf(one[0]), ALICE); // nothing was burned
        vmb.revertToState(snap);
        _forceLane(ALICE, 17, 0xfffe);
        _deposit(ALICE, one);
        (uint256[] memory n, uint256[] memory c) = bazaar.loomHandOf(ALICE);
        bool saw17;
        bool saw18;
        for (uint256 i; i < n.length; ++i) {
            if (n[i] == 17) {
                assertEq(c[i], 0xffff);
                saw17 = true;
            }
            if (n[i] == 18) {
                assertEq(c[i], 1);
                saw18 = true;
            }
        }
        assertTrue(saw17 && saw18);
        assertEq(n.length, 10);
        assertEq(bazaar.loomOf(ALICE).title, 17);
        assertEq(bazaar.loomOf(ALICE).titleCount, 0xffff);
    }

    function _twoOf(uint256 m) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = m;
        out[1] = m;
    }

    function _threeOf(uint256 m) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = m;
        out[1] = m;
        out[2] = m;
    }

    // ------------------------------------------------------------ ranks and numbering

    function testWeavesAtEveryFixedBoundary() public {
        _settle(10 ether);
        uint256[9] memory sizes = [uint256(10), 29, 30, 99, 100, 299, 300, 999, 1000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 tokenId = _make(ALICE, sizes[i]);
            assertEq(bazaar.kilim(tokenId).rank, _expectedRank(sizes[i], 10_000));
            assertEq(bazaar.kilim(tokenId).count, sizes[i]);
        }
        assertEq(bazaar.madeAt(1), 2);
        assertEq(bazaar.madeAt(2), 2);
        assertEq(bazaar.madeAt(3), 2);
        assertEq(bazaar.madeAt(4), 2);
        assertEq(bazaar.madeAt(5), 1);
        assertEq(bazaar.madeAt(6), 0);
        assertEq(bazaar.totalSupply(), 9);
    }

    /// @dev `size` fresh motifs into one kilim: one call up to 300, the loom in batches of 300 above.
    function _make(address holder, uint256 size) internal returns (uint256) {
        uint256[] memory list = _fresh(holder, size);
        if (size <= 300) return _make(holder, list);
        for (uint256 pos; pos < size; pos += 300) {
            uint256 to = pos + 300 < size ? pos + 300 : size;
            _deposit(holder, _slice(list, pos, to));
        }
        return _makeFromLoom(holder, new uint256[](0));
    }

    function testTheMasterBoundaryAtSeventeen() public {
        _settle(0.017 ether);
        assertEq(bazaar.kilim(_make(ALICE, 16)).rank, 1);
        assertEq(bazaar.kilim(_make(ALICE, 17)).rank, 6);
        assertEq(bazaar.kilim(_make(ALICE, 18)).rank, 6);
        assertEq(bazaar.kilim(_make(ALICE, 30)).rank, 6); // no Spinner at top 17
        assertEq(bazaar.kilim(4).number, 3);
        (uint256[6] memory costs,) = bazaar.ladder();
        assertEq(costs[0], 10);
        assertEq(costs[1], 0);
        assertEq(costs[5], 17);
    }

    function testAtTopTenEveryKilimIsAMaster() public {
        _settle(0.01 ether);
        assertEq(bazaar.kilim(_make(ALICE, 10)).rank, 6);
        assertEq(bazaar.kilim(_make(ALICE, 300)).rank, 6);
        assertEq(bazaar.madeAt(1), 0);
        assertEq(bazaar.madeAt(6), 2);
    }

    function testAtTop800ThereIsNoDyer() public {
        _settle(0.8 ether);
        assertEq(bazaar.kilim(_make(ALICE, 799)).rank, 4);
        assertEq(bazaar.kilim(_make(ALICE, 800)).rank, 6);
        assertEq(bazaar.kilim(_make(ALICE, 1000)).rank, 6);
    }

    function testAtTop1001AThousandIsADyer() public {
        _settle(1.001 ether);
        assertEq(bazaar.kilim(_make(ALICE, 1000)).rank, 5);
        assertEq(bazaar.kilim(_make(ALICE, 1001)).rank, 6);
    }

    function testNumbersAreDensePerRankAndTokenIdsHaveNoGaps() public {
        _settle(10 ether);
        uint256[7] memory sizes = [uint256(10), 10, 30, 10, 100, 30, 10];
        uint8[7] memory ranks = [1, 1, 2, 1, 3, 2, 1];
        uint256[7] memory numbers = [uint256(1), 2, 1, 3, 1, 2, 4];
        for (uint256 i; i < sizes.length; ++i) {
            // alternate one-call kilims and looms, and holders
            address holder = i % 2 == 0 ? ALICE : BOB;
            uint256 tokenId;
            if (i % 3 == 2) {
                _deposit(holder, _fresh(holder, sizes[i]));
                tokenId = _makeFromLoom(holder, new uint256[](0));
            } else {
                tokenId = _make(holder, _fresh(holder, sizes[i]));
            }
            assertEq(tokenId, i + 1);
            KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
            assertEq(k.rank, ranks[i]);
            assertEq(k.number, numbers[i]);
            assertEq(bazaar.ownerOf(tokenId), holder);
        }
        assertEq(bazaar.totalSupply(), 7);
        assertEq(bazaar.madeAt(1), 4);
        assertEq(bazaar.madeAt(2), 2);
        assertEq(bazaar.madeAt(3), 1);
        assertEq(bazaar.madeAt(0), 0);
        assertEq(bazaar.madeAt(7), 0);
    }

    function testKilimMadeCarriesEveryField() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 30);
        (uint256 title,) = _title(_counts(list));
        KilimHolder holder = new KilimHolder();
        vm.expectEmit();
        emit KilimMade(1, ALICE, address(holder), 2, 1, 30, title, block.number + 1);
        vm.prank(ALICE);
        bazaar.make(list, address(holder));
        assertEq(bazaar.ownerOf(1), address(holder));
    }

    // ------------------------------------------------------------ tags

    /// @dev BOB bids first (his ids 1..bobUnits), then WINNER, whose range starts right after.
    function _settleTwo(uint256 bobAmount, uint256 winnerAmount) internal {
        _openBidding(auction);
        vm.deal(BOB, bobAmount);
        vm.deal(WINNER, winnerAmount);
        _bid(auction, BOB, bobAmount);
        _bid(auction, WINNER, winnerAmount);
        vm.warp(auction.endsAt());
        auction.settle();
    }

    function testTheWinningRangeTagsAMaster() public {
        _settle(0.017 ether);
        (uint256 first, uint256 won) = auction.highestBidMotifs();
        assertEq(first, 1);
        assertEq(won, 17);
        _give(WINNER, 1, 17);
        _approve(WINNER);
        uint256 tokenId = _make(WINNER, ids(1, 17));
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        assertEq(k.rank, 6);
        assertTrue(k.flags & bazaar.WINNING_BID() != 0);
        assertEq(k.number, 1);
    }

    function testTheWinningRangeTagsAnyRankAndItsEdgesAreExact() public {
        // BOB: ids 1..10. WINNER: ids 11..30 (first 11, won 20, top 20).
        _settleTwo(0.01 ether, 0.02 ether);
        (uint256 first, uint256 won) = auction.highestBidMotifs();
        assertEq(first, 11);
        assertEq(won, 20);
        _give(BOB, 1, 10);
        _give(WINNER, 11, 20);
        _give(WINNER, 31, 10);
        _approve(BOB);
        _approve(WINNER);
        uint256 snap = vmb.snapshotState();
        // every id inside, at both edges: tagged at Apprentice and at the Master
        assertTrue(_tagged(WINNER, ids(11, 10)));
        assertTrue(_tagged(WINNER, ids(21, 10)));
        vmb.revertToState(snap);
        uint256 master = _make(WINNER, ids(11, 20));
        assertEq(bazaar.kilim(master).rank, 6);
        assertTrue(bazaar.kilim(master).flags & bazaar.WINNING_BID() != 0);
        // one id past either edge: no tag
        vmb.revertToState(snap);
        assertTrue(!_tagged(WINNER, ids(22, 10))); // 31 = first + won
        vmb.revertToState(snap);
        vm.prank(BOB);
        motifs.transferFrom(BOB, WINNER, 10);
        assertTrue(!_tagged(WINNER, ids(10, 10))); // 10 = first - 1
        vmb.revertToState(snap);
        // all 20 and one more: a Master, untagged
        assertTrue(!_tagged(WINNER, ids(11, 21)));
    }

    function _tagged(address holder, uint256[] memory list) internal returns (bool) {
        uint256 tokenId = _make(holder, list);
        return bazaar.kilim(tokenId).flags & bazaar.WINNING_BID() != 0;
    }

    /// @dev The tag is judged on the loom's min and max across its deposits.
    function testTheTagFollowsTheLoomAcrossDeposits() public {
        _settle(0.3 ether); // WINNER: ids 1..300
        _give(WINNER, 1, 300);
        _approve(WINNER);
        _deposit(WINNER, ids(1, 100));
        _deposit(WINNER, ids(201, 100));
        uint256 tokenId = _makeFromLoom(WINNER, ids(101, 100));
        assertEq(bazaar.kilim(tokenId).rank, 6);
        assertTrue(bazaar.kilim(tokenId).flags & bazaar.WINNING_BID() != 0);
        // a loom that once took an outside id stays untagged
        uint256[] memory outside = _fresh(WINNER, 10);
        _deposit(WINNER, outside);
        assertTrue(bazaar.kilim(_makeFromLoom(WINNER, new uint256[](0))).flags & bazaar.WINNING_BID() == 0);
    }

    function testAWinningBidThatEarnedNothingNeverTags() public {
        // A pool of 30: BOB's bid takes all of it, the winning bid earns none.
        _deployAuction(30, FIXTURE_PAGE);
        _deployBazaar();
        _settleTwo(0.03 ether, 0.032 ether);
        (uint256 first, uint256 won) = auction.highestBidMotifs();
        assertEq(first, 0);
        assertEq(won, 0);
        assertEq(bazaar.masterCost(), 32);
        _give(BOB, 1, 30);
        _approve(BOB);
        uint256 tokenId = _make(BOB, ids(1, 30));
        assertEq(bazaar.kilim(tokenId).flags & bazaar.WINNING_BID(), 0);
        assertEq(bazaar.kilim(tokenId).rank, 2);
    }

    /// @dev The pool ran short: the winning bid earned 10, the Master still costs the bid.
    function testAShortPoolKeepsTheMastersPriceAndTagsTheWinnersApprentice() public {
        _deployAuction(1000, FIXTURE_PAGE);
        _deployBazaar();
        _settleTwo(0.99 ether, 1.04 ether);
        (uint256 first, uint256 won) = auction.highestBidMotifs();
        assertEq(first, 991);
        assertEq(won, 10);
        assertEq(bazaar.masterCost(), 1040);
        _give(WINNER, 991, 10);
        _approve(WINNER);
        uint256 tokenId = _make(WINNER, ids(991, 10));
        assertEq(bazaar.kilim(tokenId).rank, 1);
        assertTrue(bazaar.kilim(tokenId).flags & bazaar.WINNING_BID() != 0);
    }

    /// @dev Consecutive ids from `start` until they cover all 1,024 drawings.
    function _covering(uint256 start) internal view returns (uint256[] memory list) {
        bool[1025] memory seen;
        uint256 covered;
        uint256 id = start;
        while (covered < 1024) {
            uint256 m = _motifOf(id);
            if (!seen[m]) {
                seen[m] = true;
                ++covered;
            }
            ++id;
        }
        list = ids(start, id - start);
    }

    function testWholeAtAll1024DrawingsAndNotAt1023() public {
        _settle(10 ether);
        uint256[] memory list = _covering(HOLDER_IDS);
        _give(ALICE, HOLDER_IDS, list.length);
        _approve(ALICE);
        uint256 snap = vmb.snapshotState();
        uint256 tokenId = _loomAll(ALICE, list);
        KilimBazaar.Kilim memory k = bazaar.kilim(tokenId);
        assertEq(k.distinct, 1024);
        assertTrue(k.flags & bazaar.WHOLE() != 0);
        assertEq(k.rank, 5);
        _log(string.concat("Whole: ", vm.toString(list.length), " consecutive ids cover all 1,024 drawings"));
        vmb.revertToState(snap);
        // The last id is the only one showing the last drawing found.
        tokenId = _loomAll(ALICE, _slice(list, 0, list.length - 1));
        k = bazaar.kilim(tokenId);
        assertEq(k.distinct, 1023);
        assertEq(k.flags & bazaar.WHOLE(), 0);
    }

    function _loomAll(address holder, uint256[] memory list) internal returns (uint256) {
        for (uint256 pos; pos < list.length; pos += 1000) {
            uint256 to = pos + 1000 < list.length ? pos + 1000 : list.length;
            _deposit(holder, _slice(list, pos, to));
        }
        return _makeFromLoom(holder, new uint256[](0));
    }

    // ------------------------------------------------------------ recipients and transfers

    function testForbiddenRecipientsRevertBeforeAnyBurn() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 10);
        _deposit(ALICE, _fresh(ALICE, 10));
        address[5] memory bad =
            [address(0), address(bazaar), address(motifs), address(auction), address(oneOfOne)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(KilimBazaar.InvalidRecipient.selector);
            bazaar.make(list, bad[i]);
            vm.prank(ALICE);
            vm.expectRevert(KilimBazaar.InvalidRecipient.selector);
            bazaar.makeFromLoom(list, bad[i]);
        }
        assertEq(motifs.motifsBurned(), 10);
        assertEq(motifs.balanceOf(ALICE), 10);
        assertEq(bazaar.loomOf(ALICE).count, 10);
    }

    function testAWalletWithoutTheHookFailsAndTheLoomStays() public {
        _settle(10 ether);
        _deposit(ALICE, _fresh(ALICE, 10));
        NoHook wallet = new NoHook();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC721InvalidReceiver(address)", address(wallet)));
        bazaar.makeFromLoom(new uint256[](0), address(wallet));
        assertEq(bazaar.loomOf(ALICE).count, 10);
        assertEq(bazaar.totalSupply(), 0);
        assertEq(_makeFromLoom(ALICE, new uint256[](0)), 1);
    }

    function testKilimsTransferButNeverToTheFourContracts() public {
        _settle(10 ether);
        uint256 tokenId = _make(ALICE, _fresh(ALICE, 10));
        address[4] memory bad = [address(bazaar), address(motifs), address(auction), address(oneOfOne)];
        vm.startPrank(ALICE);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(KilimBazaar.InvalidRecipient.selector);
            bazaar.transferFrom(ALICE, bad[i], tokenId);
            vm.expectRevert(KilimBazaar.InvalidRecipient.selector);
            bazaar.safeTransferFrom(ALICE, bad[i], tokenId);
        }
        // unsealed kilims transfer normally
        bazaar.transferFrom(ALICE, BOB, tokenId);
        vm.stopPrank();
        assertEq(bazaar.ownerOf(tokenId), BOB);
        assertEq(bazaar.sealState(tokenId), 1);
    }

    function testStrayMotifs() public {
        _settle(10 ether);
        uint256[] memory list = _fresh(ALICE, 10);
        // A safe transfer to the Bazaar bounces.
        vm.prank(ALICE);
        vm.expectRevert(KilimBazaar.StrayTransfer.selector);
        motifs.safeTransferFrom(ALICE, address(bazaar), list[0]);
        // A plain one cannot be refused: the motif is inert.
        vm.prank(ALICE);
        motifs.transferFrom(ALICE, address(bazaar), list[0]);
        assertEq(bazaar.strayMotifs(), 1);
        uint256[] memory more = _fresh(ALICE, 9);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC721IncorrectOwner(address,uint256,address)", ALICE, list[0], address(bazaar)
            )
        );
        bazaar.make(_concat(more, _slice(list, 0, 1)), ALICE);
        // the rest still make a kilim, and the stray stays where it is
        _make(ALICE, _concat(more, _slice(list, 1, 2)));
        assertEq(bazaar.strayMotifs(), 1);
        assertEq(motifs.ownerOf(list[0]), address(bazaar));
    }

    /// @dev The auction allows a claim to any address but the tokens; to the Bazaar it bounces in _safeMint,
    ///      and the bidder keeps the credits.
    function testAClaimToTheBazaarRevertsAndKeepsTheCredits() public {
        _settle(0.017 ether);
        uint256 credits = auction.motifCredits(WINNER);
        assertEq(credits, 17);
        vm.prank(WINNER);
        vm.expectRevert(KilimBazaar.StrayTransfer.selector);
        auction.claimMotifs(10, address(bazaar));
        assertEq(auction.motifCredits(WINNER), credits);
        assertEq(bazaar.strayMotifs(), 0);
        // claimed to the winner and made into the tagged Master
        vm.prank(WINNER);
        auction.claimMotifs(17, WINNER);
        _approve(WINNER);
        uint256 tokenId = _make(WINNER, ids(1, 17));
        assertTrue(bazaar.kilim(tokenId).flags & bazaar.WINNING_BID() != 0);
    }

    function testNoEtherCanBeSent() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(bazaar).call{value: 1}("");
        assertTrue(!ok);
        vm.prank(ALICE);
        (ok,) = address(bazaar).call{value: 1}(abi.encodeCall(bazaar.seal, (new uint256[](0))));
        assertTrue(!ok);
        assertEq(address(bazaar).balance, 0);
    }

    // ------------------------------------------------------------ views

    function testRoyaltyIsSevenAndAHalfPercentToTheReceiver() public view {
        (address to, uint256 amount) = bazaar.royaltyInfo(1, 1 ether);
        assertEq(to, ARTIST);
        assertEq(amount, 0.075 ether);
        (, amount) = bazaar.royaltyInfo(7, 10_000);
        assertEq(amount, 750);
        (, amount) = bazaar.royaltyInfo(7, 13);
        assertEq(amount, 0);
        assertEq(bazaar.ROYALTY_BPS(), 750);
    }

    function testContractURI() public view {
        string memory uri = bazaar.contractURI();
        bytes memory head = "data:application/json;base64,";
        assertTrue(_startsWith(bytes(uri), head));
        string memory json = string.concat(
            '{"name":"Kilim Bazaar","description":"',
            BAZAAR_DESCRIPTION,
            '","external_link":"',
            BAZAAR_URL,
            '","seller_fee_basis_points":750,"fee_recipient":"0xd6647eeec0c8d810c546f2ab8e025d4664d833ac"}'
        );
        assertEq(uri, string.concat(string(head), Base64.encode(bytes(json))));
        assertEq(vmb.parseJsonUint(json, ".seller_fee_basis_points"), 750);
        assertEq(vmb.parseJsonString(json, ".name"), "Kilim Bazaar");
    }

    function testSupportsInterface() public view {
        assertTrue(bazaar.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(bazaar.supportsInterface(0x5b5e139f)); // metadata
        assertTrue(bazaar.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(bazaar.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(bazaar.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(!bazaar.supportsInterface(0xffffffff));
        assertTrue(!bazaar.supportsInterface(0x780e9d63)); // not enumerable
        assertTrue(!bazaar.supportsInterface(0x150b7a02)); // the receiver hook is not advertised
    }

    function testNoAdminFunctionExists() public {
        string[14] memory sigs = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "setImageBase(string)",
            "setDescription(string)",
            "setExternalUrl(string)",
            "setRoyalty(address,uint96)",
            "withdraw()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "burn(uint256)",
            "mint(address,uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(bazaar).call(abi.encodeWithSignature(sigs[i], address(this)));
            assertTrue(!ok);
        }
    }

    /// @dev The names are written once, in rankName, so renaming a rank is that one line. Which names they are
    ///      is pinned against the stored page's RANKS by onchain/test/kilim-page.test.mjs (and the deploy
    ///      config's pageRanks by the deploy script), not here; this checks only their shape.
    function testRankNamesHaveTheirShape() public view {
        for (uint256 r = 1; r <= 6; ++r) {
            bytes memory name = bytes(bazaar.rankName(r));
            assertTrue(name.length != 0);
            // printable ASCII without the characters JSON or the data: URL would choke on
            for (uint256 i; i < name.length; ++i) {
                bytes1 ch = name[i];
                assertTrue(ch >= 0x20 && ch <= 0x7e && ch != '"' && ch != "\\" && ch != "#" && ch != "%");
            }
            for (uint256 q = 1; q < r; ++q) {
                assertTrue(keccak256(name) != keccak256(bytes(bazaar.rankName(q))));
            }
            // only the Master's trait starts with "The " (the token name drops it)
            assertTrue(_startsWith(name, "The ") == (r == 6));
        }
        assertEq(bazaar.rankName(0), "");
        assertEq(bazaar.rankName(7), "");
        assertEq(bazaar.rankName(type(uint256).max), "");
    }

    function testUnknownKilims() public {
        _settle(10 ether);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.UnknownKilim.selector, 1));
        bazaar.kilim(1);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.UnknownKilim.selector, 1));
        bazaar.handOf(1);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.UnknownKilim.selector, 1));
        bazaar.pieceOf(1);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 1));
        bazaar.tokenURI(1);
        assertEq(bazaar.sealState(1), 0);
        _make(ALICE, _fresh(ALICE, 10));
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.NotSealed.selector, 1));
        bazaar.pieceOf(1);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.UnknownKilim.selector, 2));
        bazaar.kilim(2);
        vm.expectRevert(abi.encodeWithSelector(KilimBazaar.UnknownKilim.selector, 0));
        bazaar.kilim(0);
    }
}
