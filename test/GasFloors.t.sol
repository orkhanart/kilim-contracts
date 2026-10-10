// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "./TestBase.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";

/// @dev A leader whose refund receiver is cheap until armed, then burns every unit of gas it is given.
contract SwitchingLeader {
    bool public armed;

    function arm(bool on) external {
        armed = on;
    }

    function bid(KilimAuction auction, uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    receive() external payable {
        if (armed) while (gasleft() > 0) {}
    }
}

/// @dev A pool that wins and can hold the 1/1, but has no way to call claimPrize.
contract PoolWinner is IERC721Receiver {
    uint256 public received;

    function bid(KilimAuction auction, uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    mapping(uint256 => uint256) public ledger;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++received;
        // A pool's own bookkeeping, about 110k gas.
        for (uint256 i; i < 5; ++i) {
            ledger[i] = block.number + 1;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice The October 9 audit's two gas findings, as attacks that must fail.
///         F-01: the leader cannot make a rival's bid run out of gas by changing what its refund
///         receiver costs. F-02: a low-gas settle() cannot skip sending the 1/1.
contract GasFloorsTest is TestBase {
    KilimAuction auction;

    function setUp() public {
        KilimAuction.Config memory c = config();
        c.duration = 1 days;
        c.incrementBps = 1000;
        auction = new KilimAuction(c);
        _openBidding(auction);
        vm.deal(ALICE, 10 ether);
    }

    function _aliceBids(uint256 amount, uint256 gasLimit) private returns (bool ok, bytes memory data) {
        vm.prank(ALICE);
        (ok, data) =
            address(auction).call{value: amount, gas: gasLimit}(abi.encodeCall(auction.bid, (amount, 0, 0)));
    }

    /// @dev What a wallet's eth_estimateGas returns: the smallest limit with which the bid succeeds now.
    function _estimate(uint256 amount) private returns (uint256 lo) {
        uint256 hi = 2_000_000;
        lo = 21_000;
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = _aliceBids(amount, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
    }

    function testLeaderCannotMakeARivalsBidRunOutOfGas() public {
        SwitchingLeader mallory = new SwitchingLeader();
        vm.deal(address(mallory), 1 ether);
        mallory.bid(auction, 0.01 ether);

        // Alice's wallet estimates while the leader's receiver is cheap, with no safety margin at all.
        uint256 limit = _estimate(0.011 ether);

        // The leader arms the receiver before Alice's bid lands. The bid still lands; the refund waits.
        mallory.arm(true);
        (bool ok,) = _aliceBids(0.011 ether, limit);
        assertTrue(ok);
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.refunds(address(mallory)), 0.01 ether);
        assertEq(address(auction).balance, auction.liabilities());
    }

    function testABidWithTooLittleGasFailsTheSameWayWhateverTheLeaderDoes() public {
        SwitchingLeader mallory = new SwitchingLeader();
        vm.deal(address(mallory), 1 ether);
        mallory.bid(auction, 0.01 ether);
        for (uint256 i; i < 2; ++i) {
            mallory.arm(i == 1);
            (bool ok, bytes memory data) = _aliceBids(0.011 ether, 200_000);
            assertTrue(!ok);
            assertEq(bytes32(data), bytes32(EnglishAuction.InsufficientGas.selector));
            assertEq(auction.highestBidder(), address(mallory));
        }
    }

    function testLowGasSettleCannotSkipThePrize() public {
        PoolWinner pool = new PoolWinner();
        vm.deal(address(pool), 1 ether);
        pool.bid(auction, 0.01 ether);
        vm.warp(auction.endsAt());

        // Every gas limit a griefer could pick either reverts (nothing settled) or delivers the 1/1.
        for (uint256 gasLimit = 60_000; gasLimit <= 700_000; gasLimit += 4_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{gas: gasLimit}(abi.encodeCall(auction.settle, ()));
            if (ok) {
                assertTrue(auction.prizeClaimed());
                assertEq(auction.oneOfOne().ownerOf(1), address(pool));
            } else {
                assertTrue(!auction.settled());
            }
            vm.revertToState(snap);
        }
        auction.settle();
        assertEq(auction.oneOfOne().ownerOf(1), address(pool));
        assertEq(pool.received(), 1);
    }

    /// @dev The 1/1 has no reentrancy guard of its own and shares none with the glyphs or the auction.
    ///      A holder who settles from inside a glyph transfer callback must not be able to make the
    ///      prize delivery fail (audit finding R-06, re-targeted at the three contracts).
    function testSettlingFromInsideAGlyphCallbackStillSendsThePrize() public {
        PoolWinner pool = new PoolWinner();
        TransferSettler mallory = new TransferSettler(auction);
        vm.deal(address(mallory), 1 ether);
        mallory.bid(0.01 ether);
        vm.deal(address(pool), 1 ether);
        pool.bid(auction, 0.011 ether);
        mallory.claim(4);
        vm.warp(auction.endsAt());
        mallory.transferAndSettle();
        assertTrue(auction.settled());
        assertTrue(auction.prizeClaimed());
        assertEq(auction.oneOfOne().ownerOf(1), address(pool));
        assertEq(auction.glyphs().ownerOf(1), address(mallory));
    }
}

/// @dev Holds four glyphs, moves one to itself with a safe transfer, and settles the auction from the
///      glyph contract's receiver callback.
contract TransferSettler is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256[] private held;
    bool private settling;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function claim(uint256 quantity) external {
        auction.claimGlyphs(quantity, address(this));
    }

    function transferAndSettle() external {
        settling = true;
        auction.glyphs().safeTransferFrom(address(this), address(this), held[0]);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (settling) auction.settle();
        else held.push(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
