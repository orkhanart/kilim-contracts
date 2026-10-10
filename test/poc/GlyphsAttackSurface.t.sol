// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimGlyphs} from "../../src/KilimGlyphs.sol";
import {TestBase} from "../TestBase.sol";

/// @dev Review PoCs for KilimGlyphs as an attacker and as an ERC-721 integrator. Each test states what
///      it probes; a passing test is evidence the property holds, a failing one is a finding.
contract GlyphsAttackSurfacePoC is TestBase {
    KilimGlyphs internal nft;

    function setUp() public {
        nft = newGlyphs(address(this), TREASURY, GLYPH_CAP);
    }

    // ------------------------------------------------------------ burned bitmap: high bits

    /// @dev `1 << (id & 0xff)` must be a uint256 shift: ids whose low byte is 0xff set bit 255.
    function testBurnedBitmapHighBitsStayTaken() public {
        uint256[4] memory highIds = [uint256(255), 511, 767, 0xff + 256 * 30];
        for (uint256 i; i < highIds.length; ++i) {
            uint256 id = highIds[i];
            nft.mintGlyphs(ALICE, ALICE, id, 1);
            vm.prank(ALICE);
            nft.burn(id);
            assertTrue(nft.burned(id));
            assertTrue(!nft.burned(id - 1) && !nft.burned(id + 1));
            vm.expectRevert(KilimGlyphs.AlreadyMinted.selector);
            nft.mintGlyphs(ALICE, ALICE, id, 1);
        }
        // The cap's largest possible id also fits the bitmap.
        KilimGlyphs wide = newGlyphs(address(this), TREASURY, type(uint32).max);
        uint256 top = type(uint32).max;
        wide.mintGlyphs(ALICE, ALICE, top, 1);
        vm.prank(ALICE);
        wide.burn(top);
        assertTrue(wide.burned(top));
        vm.expectRevert(KilimGlyphs.AlreadyMinted.selector);
        wide.mintGlyphs(ALICE, ALICE, top, 1);
    }

    // ------------------------------------------------------------ worst-case tokenURI gas

    /// @dev The worst glyph for the SVG is a checkerboard: 16 rows x 8 runs = 128 rects. Measures the gas
    ///      of svg() and tokenURI() so the numbers are known, not assumed.
    function testWorstGlyphGas() public {
        bytes memory grids = standInGrids();
        bytes32 checker = bytes32(0);
        for (uint256 r; r < 16; ++r) {
            uint256 row = (r % 2 == 0) ? 0xAAAA : 0x5555;
            checker |= bytes32(row << (240 - 16 * r));
        }
        assembly ("memory-safe") {
            mstore(add(grids, 32), checker)
        }
        KilimGlyphs own = newGlyphs(address(this), TREASURY, 100_000, grids, standInNames());
        uint256 id;
        for (id = 1; id <= 100_000; ++id) {
            if (own.glyphOf(id) == 1) break;
        }
        own.mintGlyphs(ALICE, ALICE, id, 1);
        uint256 g0 = gasleft();
        string memory s = own.svg(1);
        uint256 svgGas = g0 - gasleft();
        g0 = gasleft();
        string memory uri = own.tokenURI(id);
        uint256 uriGas = g0 - gasleft();
        emit log_named_uint("svg bytes", bytes(s).length);
        emit log_named_uint("svg gas (internal)", svgGas);
        emit log_named_uint("tokenURI bytes", bytes(uri).length);
        emit log_named_uint("tokenURI gas (internal)", uriGas);
        // A view call through a public node: the usual eth_call cap is 50M; the policy for the 1/1 is 8M.
        assertTrue(uriGas < 8_000_000);
    }

    event log_named_uint(string key, uint256 val);

    // ------------------------------------------------------------ reentrancy from the receiver callback

    /// @dev A recipient that burns, transfers and reads during the mint callback: none of it breaks the
    ///      batch, the counters, or the id bookkeeping.
    function testReceiverMayBurnOrMoveTheJustMintedTokenInsideTheMintCallback() public {
        BurningReceiver r = new BurningReceiver(nft);
        nft.mintGlyphs(address(r), ALICE, 17, 4);
        // Every id of the batch was minted (Transfer 0 -> r) and then burned by its owner inside the callback.
        for (uint256 id = 17; id < 21; ++id) {
            assertTrue(nft.burned(id));
            vm.expectRevert();
            nft.ownerOf(id);
        }
        assertEq(nft.glyphsMinted(), 4);
        assertEq(nft.glyphsBurned(), 4);
        assertEq(nft.balanceOf(address(r)), 0);
        // The ids stay taken.
        vm.expectRevert(KilimGlyphs.AlreadyMinted.selector);
        nft.mintGlyphs(ALICE, ALICE, 17, 1);

        MovingReceiver m = new MovingReceiver(nft, BOB);
        nft.mintGlyphs(address(m), ALICE, 21, 2);
        assertEq(nft.ownerOf(21), BOB);
        assertEq(nft.ownerOf(22), BOB);
        assertEq(nft.glyphsMinted(), 6);
    }

    /// @dev During the auction's claim, the recipient re-enters the auction: bid, claimGlyphs, claimPrize,
    ///      settle, withdrawRefund all sit behind the auction's guard, and mintGlyphs behind the glyphs'.
    function testClaimRecipientCannotReenterTheAuctionOrTheMinter() public {
        KilimAuction auction = new KilimAuction(config());
        KilimGlyphs g = auction.glyphs();
        _openBidding(auction);
        _fund(ALICE, 1 ether);
        _bid(auction, ALICE, 0.1 ether); // 100 glyph credits
        ReenteringClaimer rc = new ReenteringClaimer(auction, g);
        vm.deal(address(rc), 1 ether);
        vm.prank(ALICE);
        auction.claimGlyphs(3, address(rc));
        assertEq(g.balanceOf(address(rc)), 3);
        assertEq(rc.attempts(), 3);
        // Every re-entry failed on a guard, not for want of trying.
        assertEq(rc.failures(), 3 * 5);
        assertEq(auction.glyphsClaimed(), 3);
        assertEq(auction.glyphCredits(ALICE), 97);
    }

    /// @dev CONTRACTS.md: "no path lets the treasury, the token contracts or the minter receive tokens".
    ///      The treasury cannot bid, but any bidder may name it as the recipient of a claim: the auction's
    ///      recipient rule excludes the zero address, itself and the two token contracts only.
    function testAnyBidderMayClaimGlyphsToTheTreasury() public {
        KilimAuction auction = new KilimAuction(config());
        KilimGlyphs g = auction.glyphs();
        _openBidding(auction);
        _fund(ALICE, 1 ether);
        _bid(auction, ALICE, 0.1 ether);
        vm.prank(ALICE);
        auction.claimGlyphs(2, TREASURY);
        assertEq(g.balanceOf(TREASURY), 2);
        assertEq(g.ownerOf(1), TREASURY);
    }

    // ------------------------------------------------------------ royaltyInfo arithmetic

    /// @dev ERC-2981 says royaltyInfo must not revert for any salePrice; the multiplication overflows
    ///      above uint256.max / 500. Unreachable for real prices, recorded for completeness.
    function testRoyaltyInfoOverflowsOnlyAboveAnyRealPrice() public {
        (, uint256 amount) = nft.royaltyInfo(1, type(uint256).max / 500);
        assertTrue(amount > 0);
        vm.expectRevert();
        nft.royaltyInfo(1, type(uint256).max / 500 + 1);
    }

    // ------------------------------------------------------------ names table edge: first offset nonzero

    /// @dev A names table whose first offset is not 0 leaves unreferenced bytes at the start of the
    ///      names section. The constructor accepts it (offsets only need to be monotone and end at the
    ///      section end) and every read still stays inside the chunk.
    function testNamesTableWithLeadingGapIsAcceptedAndReadsStayInBounds() public {
        string[] memory names = new string[](1024);
        for (uint256 n = 1; n <= 1024; ++n) {
            names[n - 1] = "n";
        }
        bytes memory section = namesSection(names);
        // Shift every offset by 3 and insert 3 junk bytes after the table.
        bytes memory shifted = new bytes(section.length + 3);
        for (uint256 i; i <= 1024; ++i) {
            uint256 off = (uint256(uint8(section[2 * i])) << 8 | uint8(section[2 * i + 1])) + 3;
            shifted[2 * i] = bytes1(uint8(off >> 8));
            shifted[2 * i + 1] = bytes1(uint8(off));
        }
        shifted[2050] = "?";
        shifted[2051] = "?";
        shifted[2052] = "?";
        for (uint256 i = 2050; i < section.length; ++i) {
            shifted[i + 3] = section[i];
        }
        KilimGlyphs own = newGlyphs(address(this), TREASURY, 100, standInGrids(), shifted);
        assertEq(own.name(1), "n");
        assertEq(own.name(1024), "n");
    }

    // ------------------------------------------------------------ the overloaded name

    /// @dev Both `name()` and `name(uint16)` are callable by selector; the ERC-721 one keeps 0x06fdde03.
    function testNameSelectorsCoexist() public view {
        (bool ok, bytes memory out) = address(nft).staticcall(abi.encodeWithSelector(0x06fdde03));
        assertTrue(ok);
        assertEq(abi.decode(out, (string)), "Motif Bazaar");
        (ok, out) = address(nft).staticcall(abi.encodeWithSignature("name(uint16)", uint16(1)));
        assertTrue(ok);
        assertEq(abi.decode(out, (string)), standInName(1));
    }
}

/// @dev Burns each token inside the callback that delivers it.
contract BurningReceiver is IERC721Receiver {
    KilimGlyphs internal immutable nft;

    constructor(KilimGlyphs nft_) {
        nft = nft_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        nft.burn(id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Transfers each token away inside the callback that delivers it.
contract MovingReceiver is IERC721Receiver {
    KilimGlyphs internal immutable nft;
    address internal immutable to;

    constructor(KilimGlyphs nft_, address to_) {
        nft = nft_;
        to = to_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        nft.transferFrom(address(this), to, id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Tries every auction entry point and the minter from inside the claim's receiver callback.
contract ReenteringClaimer is IERC721Receiver {
    KilimAuction internal immutable auction;
    KilimGlyphs internal immutable glyphs;
    uint256 public attempts;
    uint256 public failures;

    constructor(KilimAuction auction_, KilimGlyphs glyphs_) {
        auction = auction_;
        glyphs = glyphs_;
    }

    function _try(address target, bytes memory data, uint256 value) private {
        (bool ok,) = target.call{value: value}(data);
        if (!ok) ++failures;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++attempts;
        _try(address(auction), abi.encodeCall(auction.bid, (0.2 ether, 0, 0)), 0.2 ether);
        _try(address(auction), abi.encodeCall(auction.claimGlyphs, (1, address(this))), 0);
        _try(address(auction), abi.encodeCall(auction.claimPrize, (address(this))), 0);
        _try(address(auction), abi.encodeCall(auction.settle, ()), 0);
        _try(address(glyphs), abi.encodeCall(glyphs.mintGlyphs, (address(this), address(this), 9000, 1)), 0);
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
