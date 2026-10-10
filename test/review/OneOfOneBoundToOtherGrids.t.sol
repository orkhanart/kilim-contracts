// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

/// @notice Review PoC (oneofone finding, skeptic): the 1/1's constructor binds to a motif address, not
///         to grid content. A real KilimMotifs built over different grids is accepted and the 1/1 then
///         draws those grids. What closes this on the deploy path is identity, not content: the auction
///         refuses a 1/1 bound to any collection but its own, and accepts one bound to its own whatever
///         the grids are; the only content check is the deploy script's golden sha256 of tokenURI(1).
contract OneOfOneBoundToOtherGridsPoC is TestBase {
    function _hex(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "0123456789abcdef";
        out = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            out[2 * i] = table[uint8(data[i]) >> 4];
            out[2 * i + 1] = table[uint8(data[i]) & 0xf];
        }
    }

    /// @dev The whole answer, built the plain way, for the stand-in page over `grids`.
    function _reference(bytes memory grids) internal pure returns (bytes memory) {
        bytes memory head = bytes(PAGE_HEAD);
        uint256 pad = (3 - (head.length + 65_536 + 1) % 3) % 3;
        bytes memory piece = bytes.concat(head, _hex(grids), "'");
        for (uint256 i; i < pad; ++i) {
            piece = bytes.concat(piece, " ");
        }
        return bytes.concat(
            "data:application/json;utf8,",
            bytes(PAGE_PREFIX),
            bytes(Base64.encode(piece)),
            bytes(Base64.encode(bytes(PAGE_REST))),
            '"}'
        );
    }

    /// @dev 1,024 grids that are not the stand-in ones.
    function _otherGrids() internal pure returns (bytes memory out) {
        out = new bytes(MOTIF_COUNT * 32);
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            bytes32 g = keccak256(abi.encode("some other grid", n));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(sub(n, 1), 32)), g)
            }
        }
    }

    /// @dev A KilimMotifs over different grids is accepted as the 1/1's source, and tokenURI(1) then
    ///      carries those grids: the constructor binds an address, never the grid content.
    function testAKilimMotifsOverOtherGridsIsAcceptedAndDrawn() public {
        bytes memory other = _otherGrids();
        assertTrue(keccak256(other) != keccak256(standInGrids()));
        KilimMotifs overOther = newMotifs(address(this), TREASURY, MOTIF_CAP, other, standInNames());
        KilimOneOfOne own = newOneOfOne(address(this), TREASURY, overOther);
        own.mint(ALICE);
        assertEq(address(own.motifs()), address(overOther));
        bytes32 got = keccak256(bytes(own.tokenURI(1)));
        assertEq(got, keccak256(_reference(other)));
        assertTrue(got != keccak256(_reference(standInGrids())));
    }

    /// @dev The auction refuses a 1/1 bound to a collection other than its own (KilimAuction line 82).
    function testTheAuctionRefusesAOneOfOneBoundElsewhere() public {
        // Deploy every chunk first so the three creations below are consecutive nonces.
        bytes memory other = _otherGrids();
        bytes memory names = standInNames();
        address[] memory otherChunks = chunked(other, 767 * 32);
        address otherNames = sstore2(names);
        newMotifs(address(1), TREASURY, MOTIF_CAP); // forces the stand-in store to exist
        standInPage();

        address auction = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        KilimMotifs own = newMotifs(auction, TREASURY, MOTIF_CAP);
        KilimMotifs stranger = new KilimMotifs(
            auction,
            TREASURY,
            MOTIF_CAP,
            otherChunks,
            keccak256(other),
            otherNames,
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
        KilimOneOfOne boundToStranger = newOneOfOne(auction, TREASURY, stranger);

        KilimAuction.Config memory c = KilimAuction.Config({
            treasury: TREASURY,
            motifs: address(own),
            oneOfOne: address(boundToStranger),
            startsAt: uint64(block.timestamp + 1 hours),
            duration: 22 hours,
            extensionWindow: 10 minutes,
            incrementBps: 500,
            reservePrice: RESERVE,
            maxMotifsPerBid: 1000
        });
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    /// @dev And it accepts a 1/1 bound to its own collection whatever that collection's grids are: the
    ///      contracts check identity. Content is the deploy script's golden hash, nothing on chain.
    function testTheAuctionAcceptsItsOwnCollectionOverAnyGrids() public {
        bytes memory other = _otherGrids();
        bytes memory names = standInNames();
        address[] memory otherChunks = chunked(other, 767 * 32);
        address otherNames = sstore2(names);
        standInPage();

        address auction = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        KilimMotifs overOther = new KilimMotifs(
            auction,
            TREASURY,
            MOTIF_CAP,
            otherChunks,
            keccak256(other),
            otherNames,
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
        KilimOneOfOne own = newOneOfOne(auction, TREASURY, overOther);
        KilimAuction.Config memory c = KilimAuction.Config({
            treasury: TREASURY,
            motifs: address(overOther),
            oneOfOne: address(own),
            startsAt: uint64(block.timestamp + 1 hours),
            duration: 22 hours,
            extensionWindow: 10 minutes,
            incrementBps: 500,
            reservePrice: RESERVE,
            maxMotifsPerBid: 1000
        });
        KilimAuction a = new KilimAuction(c);
        assertEq(address(a), auction);
        assertEq(address(a.oneOfOne()), address(own));
        assertEq(address(own.motifs()), address(overOther));
    }

    /// @dev The suggested belt-and-braces check would work as described: KilimMotifs exposes gridsHash
    ///      as an external view, so a 1/1 constructor could compare it to an argument. Shown here from
    ///      outside, since the finding asks for no change.
    function testGridsHashIsReadableForABeltAndBracesCheck() public {
        bytes memory other = _otherGrids();
        KilimMotifs overOther = newMotifs(address(this), TREASURY, MOTIF_CAP, other, standInNames());
        KilimMotifs overStandIn = newMotifs(address(this), TREASURY, MOTIF_CAP);
        assertEq(overOther.gridsHash(), keccak256(other));
        assertEq(overStandIn.gridsHash(), keccak256(standInGrids()));
        assertTrue(overOther.gridsHash() != overStandIn.gridsHash());
    }
}
