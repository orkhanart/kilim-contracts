// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimGlyphs} from "../src/KilimGlyphs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";
import {TestBase} from "./TestBase.sol";

/// @dev A minter whose recipient tries to mint again, through the minter, from inside the receiver
///      callback, and reads the token while it arrives.
contract ReenteringOneOfOneMinter {
    function mint(KilimOneOfOne nft, address to) external {
        nft.mint(to);
    }
}

contract ReenteringOneOfOneRecipient is IERC721Receiver {
    ReenteringOneOfOneMinter public immutable minter;
    bytes public innerRevert;
    uint256 public uriLengthInCallback;

    constructor(ReenteringOneOfOneMinter minter_) {
        minter = minter_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        KilimOneOfOne nft = KilimOneOfOne(msg.sender);
        (bool ok, bytes memory data) = address(minter).call(abi.encodeCall(minter.mint, (nft, address(this))));
        require(!ok, "re-entered mint");
        innerRevert = data;
        uriLengthInCallback = bytes(nft.tokenURI(1)).length;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A glyph source of any 32,768 bytes, derived from a seed, so the hex encoder meets every byte
///      value and the 1/1 is compared against OpenZeppelin's Base64 over grids it has never seen.
contract SeededGrids {
    bytes32 public immutable seed;

    constructor(bytes32 seed_) {
        seed = seed_;
    }

    function grids() external view returns (bytes memory out) {
        out = new bytes(32_768);
        for (uint256 i; i < 1024; ++i) {
            bytes32 w = keccak256(abi.encode(seed, i));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), shl(5, i)), w)
            }
        }
    }
}

contract KilimOneOfOneTest is TestBase {
    event log_named_uint(string key, uint256 value);

    KilimGlyphs internal glyphs;
    KilimOneOfOne internal nft;

    function setUp() public {
        glyphs = newGlyphs(address(this), TREASURY, GLYPH_CAP);
        nft = newOneOfOne(address(this), TREASURY, glyphs);
    }

    // ------------------------------------------------------------ reference

    function _hex(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "0123456789abcdef";
        out = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            out[2 * i] = table[uint8(data[i]) >> 4];
            out[2 * i + 1] = table[uint8(data[i]) & 0xf];
        }
    }

    /// @dev What tokenURI(1) must return, built with OpenZeppelin's Base64 from the same pieces:
    ///      scheme, PREFIX, base64(HEAD hex(grids) ' pad), TAIL, `"}`.
    function _reference(bytes memory prefix, bytes memory head, bytes memory tail, bytes memory grids)
        internal
        pure
        returns (bytes memory)
    {
        uint256 pad = (3 - (head.length + 65_536 + 1) % 3) % 3;
        bytes memory piece = bytes.concat(head, _hex(grids), "'");
        for (uint256 i; i < pad; ++i) {
            piece = bytes.concat(piece, " ");
        }
        assertEq(piece.length % 3, 0);
        return bytes.concat("data:application/json;utf8,", prefix, bytes(Base64.encode(piece)), tail, '"}');
    }

    function _decode(string memory uri) private pure returns (string memory) {
        bytes memory data = bytes(uri);
        bytes memory body = new bytes(data.length - 29);
        for (uint256 i; i < body.length; ++i) {
            body[i] = data[i + 29];
        }
        return string(Base64.decode(string(body)));
    }

    /// @dev Gas of a read as a marketplace makes it: the call itself, without copying the answer.
    function _readGas(address target, bytes memory data) internal view returns (uint256 g) {
        bool ok;
        g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        g -= gasleft();
        assertTrue(ok);
    }

    // ------------------------------------------------------------ construction

    function testConstructionStoresEverything() public view {
        assertEq(nft.minter(), address(this));
        assertEq(nft.royaltyReceiver(), TREASURY);
        assertEq(address(nft.glyphs()), address(glyphs));
        assertEq(nft.name(), ONE_OF_ONE_NAME);
        assertEq(nft.symbol(), "UNWOVEN");
        assertEq(nft.description(), DESCRIPTION);
        assertEq(nft.externalUrl(), EXTERNAL_URL);
        assertEq(nft.TOKEN_ID(), 1);
        assertEq(nft.prefixHash(), keccak256(bytes(PAGE_PREFIX)));
        assertEq(nft.headHash(), keccak256(bytes(PAGE_HEAD)));
        assertEq(nft.tailHash(), keccak256(bytes(Base64.encode(bytes(PAGE_REST)))));
        assertEq(nft.prefixChunks().length, 1);
        assertEq(nft.headChunks().length, 1);
        assertEq(nft.tailChunks().length, 1);
        assertTrue(!nft.minted());
    }

    function testFuzzInvalidConfiguration(uint8 selector) public {
        address minter = address(this);
        address royalty = TREASURY;
        KilimGlyphs source = glyphs;
        KilimOneOfOne.Page memory page = standInPage();
        uint256 choice = uint256(selector) % 10;
        if (choice == 0) {
            minter = address(0);
        } else if (choice == 1) {
            royalty = address(0);
        } else if (choice == 2) {
            source = KilimGlyphs(ALICE); // no code
        } else if (choice == 3) {
            page.prefixHash = keccak256("other");
        } else if (choice == 4) {
            page.headHash = keccak256("other");
        } else if (choice == 5) {
            page.tailHash = keccak256("other");
        } else if (choice == 6) {
            page.prefixChunks = new address[](0);
        } else if (choice == 7) {
            page.tailChunks[0] = ALICE; // no code
        } else if (choice == 8) {
            page.headChunks[0] = address(glyphs); // code, but no leading 0x00
        } else {
            // The right bytes in the wrong order.
            (page.headChunks, page.tailChunks) = (page.tailChunks, page.headChunks);
        }
        vm.expectRevert(KilimOneOfOne.InvalidConfiguration.selector);
        new KilimOneOfOne(minter, royalty, source, page, ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL);
    }

    // ------------------------------------------------------------ minting

    function testOnlyTheMinterMintsOnceToAValidRecipient() public {
        vm.expectRevert(KilimOneOfOne.Unauthorized.selector);
        vm.prank(ALICE);
        nft.mint(ALICE);
        address[3] memory bad = [address(0), address(nft), address(this)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
            nft.mint(bad[i]);
        }
        assertTrue(!nft.minted());
        vm.expectRevert();
        nft.ownerOf(1);
        nft.mint(ALICE);
        assertTrue(nft.minted());
        assertEq(nft.ownerOf(1), ALICE);
        assertEq(nft.balanceOf(ALICE), 1);
        vm.expectRevert(KilimOneOfOne.AlreadyMinted.selector);
        nft.mint(BOB);
        vm.expectRevert(KilimOneOfOne.AlreadyMinted.selector);
        nft.mint(ALICE);
        // The recipient is checked before the once-only rule.
        vm.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        nft.mint(address(0));
    }

    /// @dev mint has no reentrancy guard on purpose: the auction is the only caller and keeps its own
    ///      guard, and a shared guard could be entered from a receiver callback and make the prize delivery
    ///      fail with settlement already recorded (audit finding R-06). So a second mint from inside the
    ///      callback fails on AlreadyMinted, never on a guard, and the token is readable while it arrives.
    function testMintHasNoGuardAndIsOneShotFromInsideItsOwnCallback() public {
        ReenteringOneOfOneMinter minter = new ReenteringOneOfOneMinter();
        ReenteringOneOfOneRecipient recipient = new ReenteringOneOfOneRecipient(minter);
        KilimOneOfOne own = newOneOfOne(address(minter), TREASURY, glyphs);
        minter.mint(own, address(recipient));
        assertEq(bytes4(recipient.innerRevert()), KilimOneOfOne.AlreadyMinted.selector);
        assertTrue(recipient.uriLengthInCallback() > 65_536);
        assertEq(own.ownerOf(1), address(recipient));
    }

    function testNoTransferReachesTheContractOrTheMinter() public {
        nft.mint(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(nft), 1);
        vm.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        nft.transferFrom(ALICE, address(this), 1);
        vm.expectRevert(KilimOneOfOne.InvalidRecipient.selector);
        nft.safeTransferFrom(ALICE, address(this), 1);
        nft.transferFrom(ALICE, BOB, 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), BOB);
    }

    // ------------------------------------------------------------ tokenURI

    function testTokenUriExistsOnlyForTheMintedToken() public {
        vm.expectRevert();
        nft.tokenURI(1);
        nft.mint(ALICE);
        vm.expectRevert();
        nft.tokenURI(0);
        vm.expectRevert();
        nft.tokenURI(2);
        assertTrue(bytes(nft.tokenURI(1)).length != 0);
    }

    function testTokenUriMatchesTheReferenceByteForByte() public {
        nft.mint(ALICE);
        emit log_named_uint(
            "1/1 tokenURI(1) gas with the stand-in page",
            _readGas(address(nft), abi.encodeCall(nft.tokenURI, (1)))
        );
        bytes memory expected = _reference(
            bytes(PAGE_PREFIX), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST))), glyphs.grids()
        );
        bytes memory actual = bytes(nft.tokenURI(1));
        assertEq(actual.length, expected.length);
        assertEq(keccak256(actual), keccak256(expected));
        // And the page a browser would see: the JSON's animation_url decodes to the loader with the hex
        // grids inside the quotes, followed by the stored rest of the page.
        string memory json = string(_afterScheme(actual));
        string memory page = string(Base64.decode(_afterMarker(vm.parseJsonString(json, ".animation_url"))));
        bytes memory grids = glyphs.grids();
        bytes memory pad = _spaces((3 - (bytes(PAGE_HEAD).length + 65_537) % 3) % 3);
        assertEq(page, string(bytes.concat(bytes(PAGE_HEAD), _hex(grids), "'", pad, bytes(PAGE_REST))));
        assertEq(vm.parseJsonString(json, ".name"), ONE_OF_ONE_NAME);
    }

    /// @dev HEAD lengths of every residue mod 3 exercise the 0, 1 and 2 space paddings.
    function testEveryPaddingLengthConcatenatesExactly() public {
        for (uint256 extra; extra < 3; ++extra) {
            bytes memory head = bytes.concat(bytes(PAGE_HEAD), _spaces(extra));
            // The spaces moved out of the quote keep the JS valid: `const GRIDS=  '`.
            head = bytes.concat(bytes("<script>const GRIDS="), _spaces(extra), "'");
            bytes memory tail = bytes(Base64.encode(bytes(PAGE_REST)));
            KilimOneOfOne own = new KilimOneOfOne(
                address(this),
                TREASURY,
                glyphs,
                pageFrom(bytes(PAGE_PREFIX), head, tail),
                ONE_OF_ONE_NAME,
                DESCRIPTION,
                EXTERNAL_URL
            );
            own.mint(ALICE);
            bytes memory actual = bytes(own.tokenURI(1));
            bytes memory expected = _reference(bytes(PAGE_PREFIX), head, tail, glyphs.grids());
            assertEq(actual.length, expected.length);
            assertEq(keccak256(actual), keccak256(expected));
            uint256 pad = (3 - (head.length + 65_537) % 3) % 3;
            assertEq(pad, (3 - (extra + bytes("<script>const GRIDS='").length + 65_537) % 3) % 3);
        }
    }

    function testTokenUriDrawsTheGridsLiveFromTheGlyphCollection() public {
        bytes memory grids = standInGrids();
        assembly ("memory-safe") {
            mstore(add(grids, 32), 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
        }
        KilimGlyphs other = newGlyphs(address(this), TREASURY, GLYPH_CAP, grids, standInNames());
        KilimOneOfOne own = newOneOfOne(address(this), TREASURY, other);
        own.mint(ALICE);
        nft.mint(ALICE);
        bytes memory expected = _reference(
            bytes(PAGE_PREFIX), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST))), other.grids()
        );
        assertEq(keccak256(bytes(own.tokenURI(1))), keccak256(expected));
        assertTrue(keccak256(bytes(own.tokenURI(1))) != keccak256(bytes(nft.tokenURI(1))));
    }

    /// @dev Random grids and random, possibly binary, section bytes against OpenZeppelin's Base64 and a
    ///      byte-at-a-time hex loop: every byte value reaches hexHalf through the grids and base64Block
    ///      through HEAD, and every HEAD length exercises the block loop's remainder and the padding.
    function testFuzzTokenUriMatchesOpenZeppelinForAnyGridsAndSections(
        bytes32 seed,
        bytes memory prefix,
        bytes memory head,
        bytes memory tail
    ) public {
        // A section needs at least one byte to be a chunk.
        if (prefix.length == 0) prefix = "p";
        if (head.length == 0) head = "h";
        if (tail.length == 0) tail = "t";
        SeededGrids source = new SeededGrids(seed);
        KilimOneOfOne own = new KilimOneOfOne(
            address(this),
            TREASURY,
            KilimGlyphs(address(source)),
            pageFrom(prefix, head, tail),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            EXTERNAL_URL
        );
        own.mint(ALICE);
        bytes memory actual = bytes(own.tokenURI(1));
        bytes memory expected = _reference(prefix, head, tail, source.grids());
        assertEq(actual.length, expected.length);
        assertEq(keccak256(actual), keccak256(expected));
    }

    /// @dev A page of launch size: a 70 KB prefix (the still image), a real loader head and a 600 KB
    ///      tail across 25 chunks. The read must stay under the 8,000,000 policy ceiling.
    function testTokenUriGasWithARealisticPage() public {
        bytes memory prefix = bytes.concat(
            bytes('{"name":"The Unwoven Kilim","description":"x","image":"data:image/png;base64,'),
            _fill(70_000, "QUJD"),
            bytes('","animation_url":"data:text/html;base64,')
        );
        bytes memory head = bytes(
            '<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><style>html,body{margin:0;background:#fff}</style></head><body><script>const GRIDS=\''
        );
        bytes memory tail = _fill(600_000, "a0B1");
        KilimOneOfOne big = new KilimOneOfOne(
            address(this),
            TREASURY,
            glyphs,
            pageFrom(prefix, head, tail),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            EXTERNAL_URL
        );
        assertEq(big.tailChunks().length, 25);
        big.mint(ALICE);
        uint256 used = _readGas(address(big), abi.encodeCall(big.tokenURI, (1)));
        bytes memory actual = bytes(big.tokenURI(1));
        emit log_named_uint("1/1 tokenURI(1) gas with a 600 KB tail", used);
        emit log_named_uint("1/1 tokenURI(1) answer bytes", actual.length);
        assertTrue(used < 8_000_000);
        bytes memory expected = _reference(prefix, head, tail, glyphs.grids());
        assertEq(actual.length, expected.length);
        assertEq(keccak256(actual), keccak256(expected));
    }

    // ------------------------------------------------------------ collection metadata

    function testContractUriBytesAreExact() public {
        KilimOneOfOne own = new KilimOneOfOne(
            address(this),
            TREASURY,
            glyphs,
            standInPage(),
            'What "the" weave\\remembers',
            string(bytes.concat(hex"1b1f00", " x")),
            'a"b\\c'
        );
        assertEq(
            _decode(own.contractURI()),
            string.concat(
                '{"name":"What \\"the\\" weave\\\\remembers","description":"\\u001b\\u001f\\u0000 x",',
                '"external_link":"a\\"b\\\\c","seller_fee_basis_points":500,',
                '"fee_recipient":"0x0000000000000000000000000000000000007777"}'
            )
        );
        string memory json = _decode(nft.contractURI());
        assertEq(vm.parseJsonString(json, ".name"), ONE_OF_ONE_NAME);
        assertEq(vm.parseJsonString(json, ".description"), DESCRIPTION);
        assertEq(vm.parseJsonString(json, ".external_link"), EXTERNAL_URL);
        assertEq(vm.parseJsonUint(json, ".seller_fee_basis_points"), 500);
    }

    function testRoyaltyIsFivePercentToTheReceiverForever() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1_000_000);
        assertEq(receiver, TREASURY);
        assertEq(amount, 50_000);
        (receiver, amount) = nft.royaltyInfo(7, 333);
        assertEq(receiver, TREASURY);
        assertEq(amount, 16); // rounds down
        assertTrue(nft.supportsInterface(0x2a55205a));
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(!nft.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------ helpers

    function _spaces(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = " ";
        }
    }

    /// @dev `n` bytes of the 4-byte pattern repeated (a stand-in for base64 content).
    function _fill(uint256 n, bytes4 pattern) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = pattern[i % 4];
        }
    }

    function _afterScheme(bytes memory uri) internal pure returns (bytes memory out) {
        out = new bytes(uri.length - 27);
        for (uint256 i; i < out.length; ++i) {
            out[i] = uri[i + 27];
        }
    }

    /// @dev The part of `data:text/html;base64,...` after the comma.
    function _afterMarker(string memory url) internal pure returns (string memory) {
        bytes memory u = bytes(url);
        bytes memory out = new bytes(u.length - 22);
        for (uint256 i; i < out.length; ++i) {
            out[i] = u[i + 22];
        }
        return string(out);
    }
}
