// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {TestBase} from "../../../test/TestBase.sol";
import {MotifReferenceHashes} from "./MotifReferenceHashes.sol";

interface VmTok {
    function readFile(string calldata) external view returns (string memory);
    function readFileBinary(string calldata) external view returns (bytes memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function prank(address) external;
    function toString(uint256) external pure returns (string memory);
    function load(address, bytes32) external view returns (bytes32);
    function etch(address, bytes calldata) external;
    function store(address, bytes32, bytes32) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
}

/// @notice Token audit of 12 October 2026 (lens: token contracts and on-chain rendering), on the REAL packed
///         stores (onchain/build-motifs, onchain/build-page) that deploy/mainnet.json pins.
contract TokenRenderingAudit is TestBase {
    VmTok internal constant vt = VmTok(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;
    string internal constant MOTIFS = "../onchain/build-motifs";
    string internal constant PAGE = "../onchain/build-page";
    uint256 internal constant CAP = 1_000_000;

    function _log(string memory s) internal view {
        (bool ok,) = CONSOLE.staticcall(abi.encodeWithSignature("log(string)", s));
        ok;
    }

    /// @dev The real motif store, with this test contract as minter.
    function _realMotifs() internal returns (KilimMotifs k, bytes memory grids, bytes memory names) {
        string memory m = vt.readFile(string.concat(MOTIFS, "/manifest.json"));
        grids = vt.readFileBinary(string.concat(MOTIFS, "/grids.bin"));
        names = vt.readFileBinary(string.concat(MOTIFS, "/names.bin"));
        require(keccak256(grids) == vt.parseJsonBytes32(m, ".hashes.gridsHash"), "gridsHash");
        require(keccak256(names) == vt.parseJsonBytes32(m, ".hashes.namesHash"), "namesHash");
        k = new KilimMotifs(
            address(this),
            TREASURY,
            CAP,
            chunked(grids, 767 * 32),
            keccak256(grids),
            sstore2(names),
            keccak256(names),
            vt.parseJsonString(m, ".description"),
            vt.parseJsonString(m, ".externalUrl")
        );
    }

    // ------------------------------------------------------------ KilimMotifs

    /// @dev Every one of the 1,024 motifs: the tokenURI of a real token showing it equals, byte for byte (sha256),
    ///      the Python reference renderer onchain/pack_motifs.py motif_token_uri (whose 1,024 JSONs were all
    ///      parsed by Python's json module, Motif trait a string), and its read gas stays under 8M.
    function testEveryMotifTokenURIEqualsTheReferenceRenderer() public {
        (KilimMotifs k,,) = _realMotifs();
        bytes memory ref = MotifReferenceHashes.SHA256;
        require(ref.length == 1024 * 32, "reference size");
        bool[1025] memory done;
        uint256 seen;
        uint256 maxGas;
        uint256 maxMotif;
        uint256 maxLen;
        uint256 lastId;
        for (uint256 id = 1; seen < 1024; ++id) {
            uint16 motif = k.motifOf(id);
            if (done[motif]) continue;
            done[motif] = true;
            ++seen;
            lastId = id;
            k.mintMotifs(ALICE, ALICE, id, 1);
            uint256 g = gasleft();
            string memory uri = k.tokenURI(id);
            g -= gasleft();
            bytes32 want;
            assembly ("memory-safe") {
                want := mload(add(add(ref, 32), mul(sub(motif, 1), 32)))
            }
            require(sha256(bytes(uri)) == want, string.concat("tokenURI differs from reference, motif ", vt.toString(motif)));
            if (g > maxGas) {
                maxGas = g;
                maxMotif = motif;
            }
            if (bytes(uri).length > maxLen) maxLen = bytes(uri).length;
        }
        _log(string.concat("all 1024 motifs match the reference; ids scanned ", vt.toString(lastId)));
        _log(string.concat("max motif tokenURI gas ", vt.toString(maxGas), " (motif ", vt.toString(maxMotif), ")"));
        _log(string.concat("max motif tokenURI bytes ", vt.toString(maxLen)));
        assertTrue(maxGas < 8_000_000);
    }

    /// @dev grid(n) and motifName(n) for every n against grids.bin and names.bin, including both sides of the
    ///      grid-chunk boundary (767 | 768) and the last name, and the reverts at 0 and 1,025.
    function testEveryGridAndNameReadsExactlyItsBytes() public {
        (KilimMotifs k, bytes memory grids, bytes memory names) = _realMotifs();
        for (uint256 n = 1; n <= 1024; ++n) {
            bytes32 g;
            assembly ("memory-safe") {
                g := mload(add(add(grids, 32), mul(sub(n, 1), 32)))
            }
            require(k.grid(uint16(n)) == g, string.concat("grid ", vt.toString(n)));
            uint256 a = (uint256(uint8(names[2 * (n - 1)])) << 8) | uint8(names[2 * (n - 1) + 1]);
            uint256 b = (uint256(uint8(names[2 * n])) << 8) | uint8(names[2 * n + 1]);
            bytes memory want = new bytes(b - a);
            for (uint256 i; i < b - a; ++i) {
                want[i] = names[2050 + a + i];
            }
            require(keccak256(bytes(k.motifName(uint16(n)))) == keccak256(want), string.concat("name ", vt.toString(n)));
        }
        assertEq(keccak256(k.grids()), k.gridsHash());
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, uint16(0)));
        k.grid(0);
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, uint16(1025)));
        k.grid(1025);
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, uint16(0)));
        k.motifName(0);
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidMotif.selector, uint16(1025)));
        k.motifName(1025);
    }

    /// @dev Ids at the edges: 1, motifCap, a full batch ending at motifCap, one past it, 0, uint256 max; a burned
    ///      id stays burned and unreadable.
    function testIdsAtTheBoundaries() public {
        (KilimMotifs k,,) = _realMotifs();
        k.mintMotifs(ALICE, ALICE, 1, 1);
        k.mintMotifs(ALICE, ALICE, CAP, 1);
        k.mintMotifs(ALICE, ALICE, CAP - 64, 64); // CAP - 64 .. CAP - 1
        assertEq(k.motifsMinted(), 66);
        bytes(k.tokenURI(1));
        bytes(k.tokenURI(CAP));
        vt.expectRevert(KilimMotifs.SupplyExceeded.selector);
        k.mintMotifs(ALICE, ALICE, CAP + 1, 1);
        vt.expectRevert(KilimMotifs.SupplyExceeded.selector);
        k.mintMotifs(ALICE, ALICE, CAP - 62, 64);
        vt.expectRevert(KilimMotifs.SupplyExceeded.selector);
        k.mintMotifs(ALICE, ALICE, 0, 1);
        vt.expectRevert(KilimMotifs.SupplyExceeded.selector);
        k.mintMotifs(ALICE, ALICE, type(uint256).max, 1);
        vt.expectRevert(KilimMotifs.InvalidQuantity.selector);
        k.mintMotifs(ALICE, ALICE, 2, 65);
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidTokenId.selector, CAP + 1));
        k.motifOf(CAP + 1);
        vt.expectRevert(abi.encodeWithSelector(KilimMotifs.InvalidTokenId.selector, 0));
        k.motifOf(0);
        vt.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        k.tokenURI(2);
        // burn: owner only, the id is never minted again, and its tokenURI is gone
        vt.expectRevert(KilimMotifs.Unauthorized.selector);
        k.burn(CAP);
        vt.prank(ALICE);
        k.burn(CAP);
        assertTrue(k.burned(CAP));
        vt.expectRevert(KilimMotifs.AlreadyMinted.selector);
        k.mintMotifs(ALICE, ALICE, CAP, 1);
        vt.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, CAP));
        k.tokenURI(CAP);
        // no mint path for anyone but the minter, and the minter can never hold a motif
        vt.prank(ALICE);
        vt.expectRevert(KilimMotifs.Unauthorized.selector);
        k.mintMotifs(ALICE, ALICE, 5, 1);
        vt.expectRevert(KilimMotifs.InvalidRecipient.selector);
        k.mintMotifs(address(this), ALICE, 5, 1);
        vt.prank(ALICE);
        vt.expectRevert(KilimMotifs.InvalidRecipient.selector);
        k.transferFrom(ALICE, address(this), 1);
    }

    /// @dev ERC-165 answers on both token contracts.
    function testInterfaces() public {
        (KilimMotifs k,,) = _realMotifs();
        KilimOneOfOne o = new KilimOneOfOne(address(this), TREASURY, k, standInPage(), ONE_OF_ONE_NAME, "d", "");
        bytes4[4] memory yes = [bytes4(0x01ffc9a7), 0x80ac58cd, 0x5b5e139f, 0x2a55205a];
        for (uint256 i; i < 4; ++i) {
            assertTrue(k.supportsInterface(yes[i]) && o.supportsInterface(yes[i]));
        }
        assertTrue(!k.supportsInterface(0xffffffff) && !o.supportsInterface(0xffffffff));
        assertTrue(!k.supportsInterface(0x780e9d63) && !o.supportsInterface(0x780e9d63)); // not Enumerable
        (address r, uint256 amt) = k.royaltyInfo(7, 1 ether);
        assertEq(r, TREASURY);
        assertEq(amt, 0.05 ether);
    }

    // ------------------------------------------------------------ KilimOneOfOne over the real page

    /// @dev The real 1/1 over the real page and motifs, this contract as minter, the token minted to ALICE.
    function _realOneOfOne() internal returns (KilimMotifs k, KilimOneOfOne o, string memory pm) {
        (k,,) = _realMotifs();
        pm = vt.readFile(string.concat(PAGE, "/manifest.json"));
        KilimOneOfOne.Page memory p = pageFrom(
            vt.readFileBinary(string.concat(PAGE, "/prefix.bin")),
            vt.readFileBinary(string.concat(PAGE, "/head.bin")),
            vt.readFileBinary(string.concat(PAGE, "/tail.bin"))
        );
        assertEq(p.prefixHash, vt.parseJsonBytes32(pm, ".hashes.prefixHash"));
        assertEq(p.headHash, vt.parseJsonBytes32(pm, ".hashes.headHash"));
        assertEq(p.tailHash, vt.parseJsonBytes32(pm, ".hashes.tailHash"));
        o = new KilimOneOfOne(
            address(this),
            TREASURY,
            k,
            p,
            vt.parseJsonString(pm, ".name"),
            vt.parseJsonString(pm, ".description"),
            vt.parseJsonString(pm, ".externalUrl")
        );
        vt.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        o.tokenURI(1);
        o.mint(ALICE);
    }

    /// @dev The real page and the real motifs: tokenURI(1) equals the packer's golden, the
    ///      answer is a clean ABI string (offset, length, zeroed padding), and every other id reverts.
    function testOneOfOneRealPageGoldenAndFraming() public {
        (, KilimOneOfOne o, string memory pm) = _realOneOfOne();
        vt.expectRevert(KilimOneOfOne.AlreadyMinted.selector);
        o.mint(BOB);
        vt.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        o.tokenURI(0);
        vt.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        o.tokenURI(2);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(o).staticcall(abi.encodeCall(o.tokenURI, (1)));
        g -= gasleft();
        assertTrue(ok);
        assertEq(uint256(bytes32(_slice(ret, 0))), 0x20);
        uint256 len = uint256(bytes32(_slice(ret, 32)));
        assertEq(ret.length, 64 + ((len + 31) / 32) * 32);
        for (uint256 i = 64 + len; i < ret.length; ++i) {
            require(ret[i] == 0, "nonzero padding");
        }
        assertEq(sha256(bytes(abi.decode(ret, (string)))), vt.parseJsonBytes32(pm, ".golden.tokenURI.sha256"));
        // g includes copying the 1 MB answer into this test frame, which already holds the page files (about
        // 2 MB of memory): it is not the read's cost. testOneOfOneReadGasFloor measures the read itself.
        _log(string.concat("1/1 tokenURI bytes ", vt.toString(len), ", caller-side gas incl. copy ", vt.toString(g)));
    }

    /// @dev The smallest gas that reads tokenURI(1) (warm), and a read below it fails whole, with no partial answer.
    function testOneOfOneReadGasFloor() public {
        (, KilimOneOfOne o,) = _realOneOfOne();
        bytes memory call = abi.encodeCall(o.tokenURI, (1));
        uint256 lo = 1_000_000;
        uint256 hi = 8_000_000;
        while (hi - lo > 10_000) {
            uint256 mid = (lo + hi) / 2;
            (bool okMid,) = address(o).staticcall{gas: mid}(call);
            if (okMid) hi = mid;
            else lo = mid;
        }
        _log(string.concat("1/1 tokenURI needs about ", vt.toString(hi), " gas (warm)"));
        assertTrue(hi < 8_000_000);
        (bool okLow, bytes memory retLow) = address(o).staticcall{gas: lo}(call);
        assertTrue(!okLow && retLow.length == 0);
    }

    /// @dev The 1/1's transfer guards: never to the 1/1 itself, its minter or the motif collection.
    function testOneOfOneTransferGuards() public {
        (KilimMotifs k, KilimOneOfOne o,) = _realOneOfOne();
        vt.prank(ALICE);
        vt.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        o.transferFrom(ALICE, address(k), 1);
        vt.prank(ALICE);
        vt.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        o.transferFrom(ALICE, address(o), 1);
        vt.prank(ALICE);
        vt.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        o.transferFrom(ALICE, address(this), 1);
        vt.prank(ALICE);
        o.transferFrom(ALICE, BOB, 1);
        assertEq(o.ownerOf(1), BOB);
    }

    /// @dev The check the operator can run on the DEPLOYED 1/1 before startsAt, when it is not minted yet: an
    ///      eth_call to tokenURI(1) with a state override that sets _owners[1] (OpenZeppelin ERC721, slot 2) to any
    ///      address. Shown here on an unminted 1/1: one storage write makes tokenURI(1) answer the golden, and the
    ///      slot is the one the real mint writes.
    function testUnmintedOneOfOneReadsTheGoldenWithAStateOverride() public {
        (KilimMotifs k,,) = _realMotifs();
        string memory pm = vt.readFile(string.concat(PAGE, "/manifest.json"));
        KilimOneOfOne o = new KilimOneOfOne(
            address(this),
            TREASURY,
            k,
            pageFrom(
                vt.readFileBinary(string.concat(PAGE, "/prefix.bin")),
                vt.readFileBinary(string.concat(PAGE, "/head.bin")),
                vt.readFileBinary(string.concat(PAGE, "/tail.bin"))
            ),
            vt.parseJsonString(pm, ".name"),
            vt.parseJsonString(pm, ".description"),
            vt.parseJsonString(pm, ".externalUrl")
        );
        bytes32 slot = keccak256(abi.encode(uint256(1), uint256(2)));
        uint256 snap = vt.snapshotState();
        vt.store(address(o), slot, bytes32(uint256(uint160(ALICE))));
        assertEq(sha256(bytes(o.tokenURI(1))), vt.parseJsonBytes32(pm, ".golden.tokenURI.sha256"));
        vt.revertToState(snap);
        assertTrue(!o.minted());
        o.mint(BOB);
        assertEq(vt.load(address(o), slot), bytes32(uint256(uint160(BOB))));
    }

    /// @dev Unreachable on a real chain (a chunk's code starts with STOP and cannot self-destruct), but the
    ///      assembly's behaviour if a store chunk had no code: sectionSize underflows and the read runs out of
    ///      gas. It reverts; it never answers a wrong or truncated string.
    function testOneOfOneWithAChunkGoneRevertsRatherThanAnswering() public {
        (KilimMotifs k,,) = _realMotifs();
        KilimOneOfOne o = new KilimOneOfOne(address(this), TREASURY, k, standInPage(), ONE_OF_ONE_NAME, "d", "");
        o.mint(ALICE);
        bytes memory call = abi.encodeCall(o.tokenURI, (1));
        (bool ok,) = address(o).staticcall{gas: 5_000_000}(call);
        assertTrue(ok);
        vt.etch(o.tailChunks()[0], "");
        (bool ok2, bytes memory ret2) = address(o).staticcall{gas: 5_000_000}(call);
        assertTrue(!ok2 && ret2.length == 0);
    }

    // ------------------------------------------------------------ JSON escaping, fuzzed

    address[] internal _fuzzGrids;
    address internal _fuzzNames;
    bytes32 internal _fuzzGridsHash;
    bytes32 internal _fuzzNamesHash;

    /// @dev Any description (every byte value, any length): contractURI decodes, the description field ends at
    ///      the first unescaped quote, holds no raw control byte, and unescapes back to exactly the input; the
    ///      rest of the JSON follows intact. tokenURI uses the same _escapeJson.
    function testFuzzEscapeJsonRoundTrips(bytes memory desc) public {
        if (_fuzzGrids.length == 0) {
            bytes memory grids = standInGrids();
            bytes memory names = standInNames();
            _fuzzGrids = chunked(grids, 767 * 32);
            _fuzzNames = sstore2(names);
            _fuzzGridsHash = keccak256(grids);
            _fuzzNamesHash = keccak256(names);
        }
        KilimMotifs k = new KilimMotifs(
            address(this), TREASURY, 10, _fuzzGrids, _fuzzGridsHash, _fuzzNames, _fuzzNamesHash, string(desc), "u"
        );
        string memory uri = k.contractURI();
        bytes memory head = bytes("data:application/json;base64,");
        bytes memory u = bytes(uri);
        for (uint256 i; i < head.length; ++i) {
            require(u[i] == head[i], "scheme");
        }
        bytes memory b64 = new bytes(u.length - head.length);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = u[head.length + i];
        }
        bytes memory json = Base64.decode(string(b64));
        bytes memory open = bytes('{"name":"Motif Bazaar","description":"');
        for (uint256 i; i < open.length; ++i) {
            require(json[i] == open[i], "open");
        }
        bytes memory got = new bytes(desc.length);
        uint256 n;
        uint256 pos = open.length;
        while (true) {
            bytes1 ch = json[pos];
            require(uint8(ch) >= 0x20, "raw control byte in the JSON string");
            if (ch == '"') break;
            if (ch == "\\") {
                bytes1 e = json[pos + 1];
                if (e == '"' || e == "\\") {
                    got[n++] = e;
                    pos += 2;
                } else {
                    require(e == "u" && json[pos + 2] == "0" && json[pos + 3] == "0", "escape");
                    got[n++] = bytes1(uint8((_hex(json[pos + 4]) << 4) | _hex(json[pos + 5])));
                    pos += 6;
                }
            } else {
                got[n++] = ch;
                pos += 1;
            }
        }
        require(n == desc.length && keccak256(got) == keccak256(desc), "round trip");
        bytes memory rest = bytes('","external_link":"u","seller_fee_basis_points":500,"fee_recipient":"');
        for (uint256 i; i < rest.length; ++i) {
            require(json[pos + i] == rest[i], "rest");
        }
    }

    function _hex(bytes1 c) internal pure returns (uint8) {
        uint8 v = uint8(c);
        if (v >= 48 && v <= 57) return v - 48;
        require(v >= 97 && v <= 102, "hex digit");
        return v - 87;
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            out[i] = b[from + i];
        }
    }
}
