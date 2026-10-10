// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "./TestBase.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";
import {ProbeWallet} from "./AuditGaps.t.sol";

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

/// @dev A pool whose bookkeeping on receipt needs more than the 500,000 gas settlement gives the
///      delivery (thirty new slots, about 670k), and that has no way to call claimPrize.
contract HeavyPoolWinner is IERC721Receiver {
    uint256 public received;
    mapping(uint256 => uint256) public ledger;

    function bid(KilimAuction auction, uint256 amount) external payable {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++received;
        for (uint256 i; i < 30; ++i) {
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

    event log_named_uint(string key, uint256 value);

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
        emit log_named_uint("smallest call gas for a bid that outbids someone (500-gas steps)", limit);

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

    /// @dev The 1/1 has no reentrancy guard of its own and shares none with the motifs or the auction.
    ///      A holder who settles from inside a motif transfer callback must not be able to make the
    ///      prize delivery fail (audit finding R-06, re-targeted at the three contracts).
    /// @dev Review round, 10 October 2026: a winner whose receiver needs more gas than settlement gives
    ///      the delivery, and that cannot call claimPrize, is not left without the 1/1. Anyone can send
    ///      it again with more gas, and it can only go to the winner.
    function testAnyoneCanSendThePrizeAgainToAWinnerThatNeedsMoreGas() public {
        HeavyPoolWinner pool = new HeavyPoolWinner();
        vm.deal(address(this), 1 ether);
        pool.bid{value: RESERVE}(auction, RESERVE);
        vm.expectRevert(EnglishAuction.NotSettled.selector);
        auction.deliverPrizeToWinner();
        vm.warp(auction.endsAt());
        vm.expectEmit();
        emit KilimAuction.PrizeDeliveryFailed(address(pool));
        auction.settle();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        assertEq(pool.received(), 0);
        // Nobody but the winner can choose where it goes.
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(CAROL);
        auction.claimPrize(CAROL);

        vm.expectEmit();
        emit KilimAuction.PrizeClaimed(address(pool), address(pool));
        vm.prank(CAROL);
        auction.deliverPrizeToWinner();
        assertTrue(auction.prizeClaimed());
        assertEq(auction.oneOfOne().ownerOf(1), address(pool));
        assertEq(pool.received(), 1);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        auction.deliverPrizeToWinner();
        // The proceeds were never held up by any of it.
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(address(auction).balance, auction.liabilities());
    }

    /// @dev Sending it again to a winner that refuses the token changes nothing, cannot be used to enter
    ///      the auction from the winner's callback, and leaves the winner's own claim open.
    function testSendingThePrizeAgainToAWinnerThatRefusesChangesNothing() public {
        ProbeWallet winner = new ProbeWallet(auction);
        vm.deal(address(winner), 1 ether);
        winner.set(true, 0, 0, "");
        winner.bid(RESERVE);
        vm.warp(auction.endsAt());
        auction.settle();
        assertTrue(!auction.prizeClaimed());
        vm.expectRevert();
        auction.deliverPrizeToWinner();
        assertTrue(!auction.prizeClaimed());
        assertTrue(!auction.oneOfOne().minted());

        // Accepting now, and trying to claim motifs from inside the callback: the guard holds.
        winner.set(false, 0, 0, abi.encodeCall(auction.claimMotifs, (1, CAROL)));
        uint256 credits = auction.motifCredits(address(winner));
        vm.prank(BOB);
        auction.deliverPrizeToWinner();
        assertTrue(!winner.reentered());
        assertEq(auction.motifCredits(address(winner)), credits);
        assertEq(auction.oneOfOne().ownerOf(1), address(winner));
        // The winner's own claim is spent with it.
        assertTrue(!winner.run(abi.encodeCall(auction.claimPrize, (ALICE))));
    }

    /// @dev After the winner claimed the 1/1 to another address, nobody can send it "again".
    function testThePrizeIsNotSentAgainAfterTheWinnerClaimedIt() public {
        ProbeWallet winner = new ProbeWallet(auction);
        vm.deal(address(winner), 1 ether);
        winner.set(true, 0, 0, "");
        winner.bid(RESERVE);
        vm.warp(auction.endsAt());
        auction.settle();
        assertTrue(winner.run(abi.encodeCall(auction.claimPrize, (ALICE))));
        assertEq(auction.oneOfOne().ownerOf(1), ALICE);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        auction.deliverPrizeToWinner();
    }

    function testSettlingFromInsideAMotifCallbackStillSendsThePrize() public {
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
        assertEq(auction.motifs().ownerOf(1), address(mallory));
    }
}

/// @dev Holds four motifs, moves one to itself with a safe transfer, and settles the auction from the
///      motif contract's receiver callback.
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
        auction.claimMotifs(quantity, address(this));
    }

    function transferAndSettle() external {
        settling = true;
        auction.motifs().safeTransferFrom(address(this), address(this), held[0]);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (settling) auction.settle();
        else held.push(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
