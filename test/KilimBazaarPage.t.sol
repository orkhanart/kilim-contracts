// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimBazaar} from "../src/KilimBazaar.sol";
import {BazaarBase} from "./bazaar/BazaarBase.sol";

/// @notice tokenURI: the sealed answer byte for byte against a reference built with abi.encodePacked and
///         OpenZeppelin's Base64 (HEAD ‖ hex(grids) ‖ ' ‖ S ‖ pad, then TAIL as stored), on the committed page
///         store and on the real one, with every padding; the JSON parsed field by field; the unsealed
///         answer; imageBase; an empty link; hostile motif names; and the read's gas, up to the worst hand.
///         testRealStoreKilimPages also logs the real kilims' tokenURIs for onchain/test/kilim-page.test.mjs.
contract KilimBazaarPageTest is BazaarBase {
    uint256 internal constant B = 2_000_000;
    bytes32 internal constant H = keccak256("seal block");
    /// The policy ceiling for reading a token (DeployKilim.MAX_TX_GAS).
    uint256 internal constant MAX_READ_GAS = 8_000_000;
    /// Chromium drops a URL longer than this when it crosses a process boundary (page.test.mjs).
    uint256 internal constant MAX_URL = 2 * 1024 * 1024;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
    }

    /// The contract's five fixed costs, read from ladder() before settlement (after it, the ranks the Master
    /// undercuts read 0). Logged for kilim-page.test.mjs, which compares them with the stored page's RANKS.
    uint256[5] internal fixedCosts;

    function _open(string memory dir, bool realMotifs, uint256 close) internal {
        if (realMotifs) {
            _deployAuction(
                BIG_CAP,
                dir,
                vmb.readFileBinary(string.concat(REAL_MOTIFS, "/grids.bin")),
                vmb.readFileBinary(string.concat(REAL_MOTIFS, "/names.bin"))
            );
        } else {
            _deployAuction(BIG_CAP, dir);
        }
        _deployBazaar();
        (uint256[6] memory costs, bool open) = bazaar.ladder();
        assertTrue(!open);
        for (uint256 i; i < 5; ++i) {
            fixedCosts[i] = costs[i];
        }
        _settle(close);
    }

    function _sealAll() internal {
        uint256 n = bazaar.totalSupply();
        vm.roll(block.number + 2);
        for (uint256 id = 1; id <= n; ++id) {
            vmb.setBlockhash(bazaar.kilim(id).sealBlock, keccak256(abi.encode(H, id)));
        }
        bazaar.seal(ids(1, n));
    }

    // ------------------------------------------------------------ the reference

    /// @dev The rank as the token name writes it: the contract's rankName (the one place the names are
    ///      written) without a leading "The " ("Master 3").
    function _word(uint256 rank) internal view returns (string memory) {
        bytes memory name = bytes(bazaar.rankName(rank));
        return _startsWith(name, "The ") ? string(_sub(name, 4, name.length)) : string(name);
    }

    function _rankTrait(uint256 rank) internal view returns (string memory) {
        return bazaar.rankName(rank);
    }

    function _spaces(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = " ";
        }
    }

    function _padOf(bytes memory s) internal view returns (uint256) {
        return (3 - (pageHead.length + 65_536 + 1 + s.length) % 3) % 3;
    }

    /// @dev The whole tokenURI as the spec writes it, from the pieces, the plain way. `name` is the title
    ///      motif's name as it must appear in the JSON (already escaped).
    function _expected(uint256 id, string memory name) internal view returns (bytes memory) {
        KilimBazaar.Kilim memory k = bazaar.kilim(id);
        bool isSealed = k.flags & 1 != 0;
        bytes memory open = abi.encodePacked(
            'data:application/json;utf8,{"name":"',
            _word(k.rank),
            " ",
            vm.toString(k.number),
            " \\u00b7 ",
            name,
            '","description":"',
            bazaar.description(),
            '",'
        );
        if (bytes(bazaar.externalUrl()).length != 0) {
            open = abi.encodePacked(open, '"external_url":"', bazaar.externalUrl(), vm.toString(id), '",');
        }
        bytes memory image = isSealed && bytes(bazaar.imageBase()).length != 0
            ? abi.encodePacked(bazaar.imageBase(), vm.toString(id))
            : abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(motifs.svg(k.title))));
        open = abi.encodePacked(open, '"image":"', image, '",');
        bytes memory traits = _expectedTraits(k, name);
        if (!isSealed) return abi.encodePacked(open, traits);
        bytes memory s = _expectedPiece(id);
        bytes memory piece = abi.encodePacked(pageHead, _hexBytes(motifs.grids()), "'", s, _spaces(_padOf(s)));
        assertEq(piece.length % 3, 0);
        return abi.encodePacked(
            open,
            '"animation_url":"data:text/html;base64,',
            Base64.encode(piece),
            _pageFile("tail.bin"),
            '",',
            traits
        );
    }

    function _expectedTraits(KilimBazaar.Kilim memory k, string memory name)
        internal
        view
        returns (bytes memory t)
    {
        t = abi.encodePacked(
            '"attributes":[{"trait_type":"Rank","value":"',
            _rankTrait(k.rank),
            '"},{"trait_type":"Number","display_type":"number","value":',
            vm.toString(k.number),
            '},{"trait_type":"Motifs","display_type":"number","value":',
            vm.toString(k.count),
            '},{"trait_type":"Distinct motifs","display_type":"number","value":',
            vm.toString(k.distinct)
        );
        t = abi.encodePacked(
            t,
            '},{"trait_type":"Title motif","value":"',
            name,
            " (motif ",
            vm.toString(k.title),
            ')"},{"trait_type":"Seed","value":"',
            k.flags & 1 != 0 ? _hex8(k.seed) : "Sealing",
            '"}'
        );
        if (k.flags & 2 != 0) t = abi.encodePacked(t, ',{"trait_type":"Whole","value":"Yes"}');
        if (k.flags & 4 != 0) {
            t = abi.encodePacked(t, ',{"trait_type":"Made from the winning bid","value":"Yes"}');
        }
        t = abi.encodePacked(t, "]}");
    }

    function _check(uint256 id) internal view returns (string memory uri) {
        uri = bazaar.tokenURI(id);
        bytes memory want = _expected(id, motifs.motifName(bazaar.kilim(id).title));
        assertEq(bytes(uri).length, want.length);
        assertEq(keccak256(bytes(uri)), keccak256(want));
    }

    function _json(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        require(_startsWith(b, "data:application/json;utf8,"), "scheme");
        return string(_sub(b, 27, b.length));
    }

    // ------------------------------------------------------------ the committed page store

    function testTheSealedAnswerEqualsTheReferenceWithEveryPadding() public {
        _open(FIXTURE_PAGE, false, 10 ether);
        bool[3] memory seen;
        uint256 size = 10;
        for (uint256 tries; tries < 40 && !(seen[0] && seen[1] && seen[2]); ++tries) {
            _make(ALICE, _fresh(ALICE, size++));
            _sealAll();
            uint256 id = bazaar.totalSupply();
            uint256 pad = _padOf(_expectedPiece(id));
            if (seen[pad]) continue;
            seen[pad] = true;
            _check(id);
            // S is the piece the contract reports, behind its statement
            bytes memory s = _expectedPiece(id);
            assertEq(string(s), string.concat(";window.KILIM_PIECE=", bazaar.pieceOf(id)));
        }
        assertTrue(seen[0] && seen[1] && seen[2]);
    }

    function testEverySealedKilimMatchesItsReference() public {
        _open(FIXTURE_PAGE, false, 0.3 ether);
        // ranks 1, 2, 3 and the tagged Master from the winner's ids 1..300, PACKED and DENSE
        _make(ALICE, _fresh(ALICE, 10));
        _make(ALICE, _fresh(ALICE, 30));
        _make(ALICE, _fresh(ALICE, 100));
        _give(WINNER, 1, 300);
        _approve(WINNER);
        _make(WINNER, ids(1, 300));
        _deposit(BOB, _fresh(BOB, 120));
        _makeFromLoom(BOB, _fresh(BOB, 5));
        _sealAll();
        for (uint256 id = 1; id <= 5; ++id) {
            _check(id);
        }
        // random one-call hands up to several hundred motifs are PACKED; a loom is always DENSE
        assertTrue(bazaar.kilim(1).flags & bazaar.PACKED() != 0);
        assertTrue(bazaar.kilim(3).flags & bazaar.PACKED() != 0);
        assertTrue(bazaar.kilim(5).flags & bazaar.PACKED() == 0);
        assertTrue(bazaar.kilim(4).flags & bazaar.WINNING_BID() != 0);
        assertEq(bazaar.kilim(4).rank, 6);
    }

    function testTheJsonParsesWithEveryFieldAndTrait() public {
        _open(FIXTURE_PAGE, false, 0.017 ether);
        _give(WINNER, 1, 17);
        _approve(WINNER);
        _make(WINNER, ids(1, 17));
        _sealAll();
        KilimBazaar.Kilim memory k = bazaar.kilim(1);
        string memory json = _json(bazaar.tokenURI(1));
        string memory title = motifs.motifName(k.title);
        assertEq(vmb.parseJsonString(json, ".name"), string.concat(_word(6), unicode" 1 · ", title));
        assertEq(vmb.parseJsonString(json, ".description"), BAZAAR_DESCRIPTION);
        assertEq(vmb.parseJsonString(json, ".external_url"), string.concat(BAZAAR_URL, "1"));
        assertTrue(_startsWith(bytes(vmb.parseJsonString(json, ".image")), "data:image/svg+xml;base64,"));
        string memory page = vmb.parseJsonString(json, ".animation_url");
        assertTrue(_startsWith(bytes(page), "data:text/html;base64,"));
        assertEq(vmb.parseJsonString(json, ".attributes[0].trait_type"), "Rank");
        assertEq(vmb.parseJsonString(json, ".attributes[0].value"), bazaar.rankName(6));
        assertTrue(_startsWith(bytes(bazaar.rankName(6)), "The ")); // the trait keeps "The ", the name drops it
        assertEq(vmb.parseJsonString(json, ".attributes[1].trait_type"), "Number");
        assertEq(vmb.parseJsonString(json, ".attributes[1].display_type"), "number");
        assertEq(vmb.parseJsonUint(json, ".attributes[1].value"), 1);
        assertEq(vmb.parseJsonString(json, ".attributes[2].trait_type"), "Motifs");
        assertEq(vmb.parseJsonUint(json, ".attributes[2].value"), 17);
        assertEq(vmb.parseJsonString(json, ".attributes[3].trait_type"), "Distinct motifs");
        assertEq(vmb.parseJsonUint(json, ".attributes[3].value"), k.distinct);
        assertEq(vmb.parseJsonString(json, ".attributes[4].trait_type"), "Title motif");
        assertEq(
            vmb.parseJsonString(json, ".attributes[4].value"),
            string.concat(title, " (motif ", vm.toString(k.title), ")")
        );
        assertEq(vmb.parseJsonString(json, ".attributes[5].trait_type"), "Seed");
        assertEq(vmb.parseJsonString(json, ".attributes[5].value"), _hex8(k.seed));
        assertEq(vmb.parseJsonString(json, ".attributes[6].trait_type"), "Made from the winning bid");
        assertEq(vmb.parseJsonString(json, ".attributes[6].value"), "Yes");
        assertTrue(!vmb.keyExistsJson(json, ".attributes[7]"));
        // the page carries the piece right after the grids' closing quote
        bytes memory s = _expectedPiece(1);
        bytes memory start = abi.encodePacked(pageHead, _hexBytes(motifs.grids()), "'", s, _spaces(_padOf(s)));
        assertTrue(_startsWith(bytes(page), abi.encodePacked("data:text/html;base64,", Base64.encode(start))));
        // and none of the dropped words in any user-facing text: the name, the description and the traits
        bytes memory meta = bytes(json);
        bytes memory texts = abi.encodePacked(
            vmb.parseJsonString(json, ".name"),
            vmb.parseJsonString(json, ".description"),
            _sub(meta, _indexOf(meta, '"attributes"'), meta.length)
        );
        // ("The Unwoven Kilim" is the 1/1's name and stays; the rank "Weaver" is allowed but not in this kilim)
        assertTrue(!_hasDroppedWord(texts));
    }

    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) {
                ++j;
            }
            if (j == needle.length) return i;
        }
        revert("not found");
    }

    function testTheUnsealedAnswer() public {
        _open(FIXTURE_PAGE, false, 10 ether);
        _make(ALICE, _fresh(ALICE, 10));
        string memory uri = _check(1);
        assertTrue(!_contains(bytes(uri), "animation_url"));
        string memory json = _json(uri);
        assertEq(vmb.parseJsonString(json, ".attributes[5].value"), "Sealing");
        assertTrue(_startsWith(bytes(vmb.parseJsonString(json, ".image")), "data:image/svg+xml;base64,"));
        assertEq(
            vmb.parseJsonString(json, ".image"),
            string.concat(
                "data:image/svg+xml;base64,", Base64.encode(bytes(motifs.svg(bazaar.kilim(1).title)))
            )
        );
    }

    function testImageBaseShowsTheFrameOnceSealed() public {
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        bazaar = _newBazaar("https://orkhan.art/kilim/frames/", BAZAAR_URL);
        _settle(10 ether);
        _make(ALICE, _fresh(ALICE, 10));
        _make(ALICE, _fresh(ALICE, 10));
        // unsealed: the title motif's drawing
        assertTrue(_startsWith(bytes(vmb.parseJsonString(_json(_check(2)), ".image")), "data:image/svg+xml"));
        _sealAll();
        assertEq(vmb.parseJsonString(_json(_check(2)), ".image"), "https://orkhan.art/kilim/frames/2");
        _check(1);
    }

    function testAnEmptyLinkLeavesTheKeyOut() public {
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        bazaar = _newBazaar("", "");
        _settle(10 ether);
        _make(ALICE, _fresh(ALICE, 10));
        assertTrue(!vmb.keyExistsJson(_json(_check(1)), ".external_url"));
        _sealAll();
        assertTrue(!vmb.keyExistsJson(_json(_check(1)), ".external_url"));
    }

    /// @dev Motif names with every character JSON or a data: URL could choke on still give valid JSON, with
    ///      no raw `#` or `%` anywhere in the answer, and decode back to the names.
    function testHostileMotifNamesStayValidJson() public {
        string[] memory names = new string[](1024);
        for (uint256 n = 1; n <= 1024; ++n) {
            names[n - 1] =
                string(abi.encodePacked('Q"u\\o#t%e', bytes1(0x01), bytes1(0x1f), " ", vm.toString(n)));
        }
        _deployAuction(BIG_CAP, FIXTURE_PAGE, standInGrids(), namesSection(names));
        _deployBazaar();
        _settle(10 ether);
        _make(ALICE, _fresh(ALICE, 10));
        uint256 title = bazaar.kilim(1).title;
        string memory raw = names[title - 1];
        string memory escaped =
            string(abi.encodePacked('Q\\"u\\\\o\\u0023t\\u0025e\\u0001\\u001f ', vm.toString(title)));
        for (uint256 pass; pass < 2; ++pass) {
            string memory uri = bazaar.tokenURI(1);
            bytes memory want = _expected(1, escaped);
            assertEq(keccak256(bytes(uri)), keccak256(want));
            assertTrue(!_contains(bytes(uri), "#") && !_contains(bytes(uri), "%"));
            string memory json = _json(uri);
            assertEq(vmb.parseJsonString(json, ".name"), string.concat(_word(1), unicode" 1 · ", raw));
            assertEq(
                vmb.parseJsonString(json, ".attributes[4].value"),
                string.concat(raw, " (motif ", vm.toString(title), ")")
            );
            _sealAll();
        }
    }

    function testUnmintedIdsRevert() public {
        _open(FIXTURE_PAGE, false, 10 ether);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 1));
        bazaar.tokenURI(1);
        _make(ALICE, _fresh(ALICE, 10));
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 2));
        bazaar.tokenURI(2);
    }

    // ------------------------------------------------------------ the real store

    /// @dev Gas of a read as a marketplace makes it, everything cold: the call itself, no copy of the answer.
    function _readGas(uint256 id) internal returns (uint256 g) {
        _coolAll();
        bytes memory data = abi.encodeCall(bazaar.tokenURI, (id));
        address target = address(bazaar);
        bool ok;
        g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        require(ok, "tokenURI failed");
    }

    function _coolAll() internal {
        vmb.cool(address(bazaar));
        vmb.cool(address(motifs));
        vmb.cool(address(oneOfOne));
        vmb.cool(address(auction));
        address[] memory chunks = oneOfOne.headChunks();
        for (uint256 i; i < chunks.length; ++i) {
            vmb.cool(chunks[i]);
        }
        chunks = oneOfOne.tailChunks();
        for (uint256 i; i < chunks.length; ++i) {
            vmb.cool(chunks[i]);
        }
        chunks = motifs.gridChunks();
        for (uint256 i; i < chunks.length; ++i) {
            vmb.cool(chunks[i]);
        }
        vmb.cool(motifs.namesChunk());
    }

    /// @dev The real stores (onchain/build-page, onchain/build-motifs) at a 0.3 ETH close: an Apprentice, a
    ///      Journeyman, a Weaver, the winner's tagged Master and a Whole Master, each equal to the reference
    ///      byte for byte, under 2 MiB and under the read ceiling, and logged as `KILIM_FIXTURE <json>` and
    ///      `KILIM_URI <tokenURI>` for onchain/test/kilim-page.test.mjs (forge test --json -vv). The two
    ///      tests below add the other closes the page must handle; the node test reads all three.
    function testRealStoreKilimPages() public {
        _open(REAL_PAGE, true, 0.3 ether);
        assertEq(
            oneOfOne.tailHash(),
            vmb.parseJsonBytes32(vmb.readFile(string.concat(REAL_PAGE, "/manifest.json")), ".hashes.tailHash")
        );
        _make(ALICE, _fresh(ALICE, 10));
        _make(ALICE, _fresh(ALICE, 30));
        _deposit(BOB, _fresh(BOB, 60));
        _makeFromLoom(BOB, _fresh(BOB, 40));
        _give(WINNER, 1, 300);
        _approve(WINNER);
        _make(WINNER, ids(1, 300));
        // a Whole Master: consecutive ids that show all 1,024 drawings, through the loom
        uint256[] memory whole = _covering(nextHolderId);
        _give(CAROL, nextHolderId, whole.length);
        nextHolderId += whole.length;
        _approve(CAROL);
        for (uint256 pos; pos < whole.length; pos += 1000) {
            _deposit(CAROL, _slice(whole, pos, pos + 1000 < whole.length ? pos + 1000 : whole.length));
        }
        _makeFromLoom(CAROL, new uint256[](0));
        _sealAll();
        _logKilims();
        assertEq(bazaar.kilim(4).rank, 6);
        assertTrue(bazaar.kilim(4).flags & bazaar.WINNING_BID() != 0);
        assertEq(bazaar.kilim(5).distinct, 1024);
        assertTrue(bazaar.kilim(5).flags & bazaar.WHOLE() != 0);
    }

    /// @dev The Sepolia launch case on the real stores: a 0.017 ETH close, so the Master costs 17 and every
    ///      fixed rank above the Apprentice falls away (ladder [10, 0, 0, 0, 0, 17]); an Apprentice of 10 (ten
    ///      motifs shown once each: a ten-way tie for the title, won by the lowest number) and the winner's
    ///      tagged Master of 17.
    function testRealStoreKilimPagesAtTheSepoliaClose() public {
        _open(REAL_PAGE, true, 0.017 ether);
        (uint256[6] memory costs, bool open) = bazaar.ladder();
        assertTrue(open);
        assertEq(keccak256(abi.encode(costs)), keccak256(abi.encode([uint256(10), 0, 0, 0, 0, 17])));
        _make(ALICE, _fresh(ALICE, 10));
        _give(WINNER, 1, 17);
        _approve(WINNER);
        _make(WINNER, ids(1, 17));
        _sealAll();
        _logKilims();
        assertEq(bazaar.kilim(1).rank, 1);
        assertEq(bazaar.kilim(2).rank, 6);
        assertTrue(bazaar.kilim(2).flags & bazaar.WINNING_BID() != 0);
    }

    /// @dev A 10 ETH close on the real stores (the Master costs 10,000): a Weaver of 100 and an Artisan of 301.
    function testRealStoreKilimPagesAtTenEther() public {
        _open(REAL_PAGE, true, 10 ether);
        _make(ALICE, _fresh(ALICE, 100));
        _make(BOB, _fresh(BOB, 301));
        _sealAll();
        _logKilims();
        assertEq(bazaar.kilim(1).rank, 3);
        assertEq(bazaar.kilim(2).rank, 4);
    }

    /// @dev Logs the ranks, then every kilim, for kilim-page.test.mjs.
    function _logKilims() internal {
        _log(string.concat("KILIM_RANKS ", _ranksJson()));
        uint256 n = bazaar.totalSupply();
        for (uint256 id = 1; id <= n; ++id) {
            // a call of its own per kilim, so each megabyte-sized answer's memory is let go
            this.checkAndLogKilim(id);
        }
    }

    /// @dev Not a test: testRealStoreKilimPages calls it once per kilim, from outside, for fresh memory.
    function checkAndLogKilim(uint256 id) external {
        string memory uri = _check(id);
        uint256 g = _readGas(id);
        assertTrue(g < MAX_READ_GAS);
        string memory page = vmb.parseJsonString(_json(uri), ".animation_url");
        assertTrue(bytes(page).length < MAX_URL);
        _log(string.concat("KILIM_FIXTURE ", _fixtureJson(id, g, bytes(uri).length, bytes(page).length)));
        _log(string.concat("KILIM_URI ", uri));
    }

    function _covering(uint256 start) internal view returns (uint256[] memory) {
        bool[1025] memory seen;
        uint256 covered;
        uint256 id = start;
        while (covered < 1024) {
            uint256 m = _motifOf(id++);
            if (!seen[m]) {
                seen[m] = true;
                ++covered;
            }
        }
        return ids(start, id - start);
    }

    /// @dev The contract's six names and five fixed costs (the Master's is the auction's: null, as RANKS has it).
    function _ranksJson() internal view returns (string memory out) {
        out = "[";
        for (uint256 r = 1; r <= 6; ++r) {
            out = string.concat(
                out,
                r == 1 ? "" : ",",
                '{"name":"',
                bazaar.rankName(r),
                '","cost":',
                r < 6 ? vm.toString(fixedCosts[r - 1]) : "null",
                "}"
            );
        }
        out = string.concat(out, "]");
    }

    function _fixtureJson(uint256 id, uint256 gas, uint256 uriBytes, uint256 pageBytes)
        internal
        view
        returns (string memory)
    {
        KilimBazaar.Kilim memory k = bazaar.kilim(id);
        string memory a = string.concat(
            '{"tokenId":',
            vm.toString(id),
            ',"rank":',
            vm.toString(k.rank),
            ',"rankName":"',
            bazaar.rankName(k.rank),
            '","number":',
            vm.toString(k.number),
            ',"count":',
            vm.toString(k.count),
            ',"distinct":',
            vm.toString(k.distinct)
        );
        string memory b = string.concat(
            ',"title":',
            vm.toString(k.title),
            ',"titleName":"',
            motifs.motifName(k.title),
            '","seed":"',
            _hex8(k.seed),
            '","top":',
            vm.toString(bazaar.masterCost()),
            ',"flags":',
            vm.toString(k.flags),
            ',"piece":',
            bazaar.pieceOf(id)
        );
        string memory c = string.concat(
            ',"readGas":',
            vm.toString(gas),
            ',"uriBytes":',
            vm.toString(uriBytes),
            ',"animationUrlBytes":',
            vm.toString(pageBytes),
            "}"
        );
        return string.concat(a, b, c);
    }

    /// @dev The heaviest read: 1,024 drawings each burned 65,535 times (every count five digits), written into
    ///      a real kilim's record and hand, with the heaviest drawing (504) and then the longest name (30) as
    ///      title. The counts cannot be reached by burning; the bound is what matters.
    function testRealStoreWorstCaseReadStaysUnderTheCeiling() public {
        _open(REAL_PAGE, true, 10 ether);
        _make(ALICE, _fresh(ALICE, 10));
        _sealAll();
        KilimBazaar.Kilim memory k = bazaar.kilim(1);
        bytes32 recordSlot = keccak256(abi.encode(uint256(1), uint256(11)));
        uint256 handBase = uint256(keccak256(abi.encode(uint256(k.handKey), uint256(12))));
        uint256 full = type(uint256).max; // sixteen lanes of 0xffff
        for (uint256 s; s < 64; ++s) {
            vmb.store(address(bazaar), bytes32(handBase + s), bytes32(full));
        }
        uint16[2] memory titles = [uint16(504), 30];
        for (uint256 t; t < titles.length; ++t) {
            uint256 record = uint256(k.handKey) | (uint256(1024 * 65_535) << 32) | (uint256(1) << 64)
                | (uint256(titles[t]) << 96) | (uint256(1024) << 112) | (uint256(6) << 128)
                | (uint256(1 | 2) << 136) | (uint256(k.sealBlock) << 144) | (uint256(k.seed) << 184);
            vmb.store(address(bazaar), recordSlot, bytes32(record));
            KilimBazaar.Kilim memory w = bazaar.kilim(1);
            assertEq(w.distinct, 1024);
            assertEq(w.title, titles[t]);
            assertEq(w.count, 1024 * 65_535);
            this.checkWorstCase(titles[t]);
        }
    }

    /// @dev Not a test: one worst-case read, from outside, for fresh memory.
    function checkWorstCase(uint256 title) external {
        string memory uri = _check(1);
        uint256 g = _readGas(1);
        string memory page = vmb.parseJsonString(_json(uri), ".animation_url");
        _log(
            string.concat(
                "worst-case tokenURI, title ",
                vm.toString(title),
                ": gas ",
                vm.toString(g),
                ", answer ",
                vm.toString(bytes(uri).length),
                " bytes, animation_url ",
                vm.toString(bytes(page).length)
            )
        );
        assertTrue(g < MAX_READ_GAS);
        assertTrue(bytes(page).length < MAX_URL);
    }
}
