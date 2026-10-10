// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {TestBase} from "./TestBase.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";

contract RejectEth {
    receive() external payable {
        revert("no ETH");
    }
}

contract ReenterEth {
    KilimAuction public auction;
    bool public reentered;

    function configure(KilimAuction a) external {
        auction = a;
    }

    receive() external payable {
        (reentered,) = address(auction).call(abi.encodeCall(auction.withdrawRefund, (address(this))));
    }
}

contract NativeRegistrationTest is TestBase {
    KilimAuction auction;

    function setUp() public {
        KilimAuction.Config memory c = config();
        c.duration = 1 days;
        c.incrementBps = 1000;
        auction = new KilimAuction(c);
        vm.warp(c.startsAt);
        vm.deal(ALICE, 1 ether);
        vm.deal(BOB, 1 ether);
    }

    function register99() internal {
        _registerWallets(auction, 99);
        for (uint256 i; i < 99; ++i) {
            assertEq(registrant(i).balance, 0.01 ether);
        }
    }

    function unlock() internal {
        vm.prank(CAROL);
        vm.deal(CAROL, 0.01 ether);
        auction.register();
    }

    function start(address user) internal {
        vm.prank(user);
        auction.bid{value: 0.01 ether}(0.01 ether, 10, 0);
    }

    function testRegistrationAndOpeningBid() public {
        register99();
        assertEq(auction.registrationCount(), 99);
        assertEq(address(auction).balance, 0);
        assertEq(auction.endsAt(), 0);
        unlock();
        assertEq(auction.endsAt(), 0);
        assertEq(address(auction).balance, 0);
        start(ALICE);
        assertEq(auction.registrationCount(), 100);
        assertTrue(!auction.registered(ALICE));
        assertEq(auction.highestBidder(), ALICE);
        assertEq(auction.motifCredits(ALICE), 10);
        assertEq(auction.endsAt(), block.timestamp + 1 days);
        assertEq(auction.minimumBid(), 0.011 ether);
        assertEq(address(auction).balance, auction.liabilities());
    }

    function testPoorAndDuplicateRegistration() public {
        vm.deal(ALICE, 0.01 ether - 1);
        vm.expectRevert(EnglishAuction.InsufficientRegistrationBalance.selector);
        vm.prank(ALICE);
        auction.register();
        vm.deal(ALICE, 0.01 ether);
        vm.prank(ALICE);
        auction.register();
        vm.expectRevert(EnglishAuction.AlreadyRegistered.selector);
        vm.prank(ALICE);
        auction.register();
        assertEq(auction.registrationCount(), 1);
    }

    function testCannotBypassThreshold() public {
        vm.expectRevert(EnglishAuction.RegistrationIncomplete.selector);
        start(ALICE);
        register99();
        vm.expectRevert(EnglishAuction.RegistrationIncomplete.selector);
        start(ALICE);
        unlock();
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(ALICE);
        auction.bid(0.01 ether, 10, 0);
        assertEq(auction.endsAt(), 0);
    }

    function testHundredthOnlyUnlocksAndFurtherRegistrationReverts() public {
        register99();
        unlock();
        assertEq(auction.registrationCount(), 100);
        assertEq(auction.highestBidder(), address(0));
        assertEq(auction.motifCredits(CAROL), 0);
        assertEq(CAROL.balance, 0.01 ether);
        vm.expectRevert(EnglishAuction.RegistrationClosed.selector);
        vm.prank(ALICE);
        auction.register();
        vm.warp(block.timestamp + 7 days);
        start(ALICE);
        assertEq(auction.endsAt(), block.timestamp + 1 days);
    }

    function testRegisteredWalletCanStartAndCompetingOpeningBidReverts() public {
        register99();
        vm.expectRevert(EnglishAuction.AlreadyRegistered.selector);
        vm.prank(registrant(0));
        auction.register();
        unlock();
        start(registrant(0));
        vm.expectRevert();
        start(BOB);
        assertEq(BOB.balance, 1 ether);
        assertEq(auction.motifCredits(BOB), 0);
    }

    function testSlippageAndWrongValueDoNotStartUnlockedAuction() public {
        register99();
        unlock();
        vm.expectRevert(KilimAuction.RewardSlippage.selector);
        vm.prank(ALICE);
        auction.bid{value: 0.01 ether}(0.01 ether, 11, 0);
        assertEq(auction.registrationCount(), 100);
        assertEq(auction.endsAt(), 0);
        assertEq(address(auction).balance, 0);
        vm.expectRevert(EnglishAuction.IncorrectPayment.selector);
        vm.prank(ALICE);
        auction.bid{value: 0.02 ether}(0.01 ether, 10, 0);
    }

    function testEthRefundProceedsAndManualClaims() public {
        register99();
        unlock();
        start(ALICE);
        vm.prank(BOB);
        auction.bid{value: 0.011 ether}(0.011 ether, 11, 0);
        assertEq(ALICE.balance, 1 ether);
        assertEq(auction.motifCredits(ALICE), 10);
        assertEq(address(auction).balance, 0.011 ether);
        vm.prank(ALICE);
        auction.claimMotifs(10, ALICE);
        assertEq(auction.motifs().balanceOf(ALICE), 10);
        // Motifs are never sent automatically: the old delivery entry point does not exist.
        (bool delivered,) = address(auction).call(abi.encodeWithSignature("deliverMotifs(uint256)", 10));
        assertTrue(!delivered);
        vm.warp(auction.endsAt());
        auction.settle();
        uint256 before = TREASURY.balance;
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance, before + 0.011 ether);
        assertEq(auction.liabilities(), 0);
    }

    function testRejectingReceiverDoesNotBlockBidsOrLoseRefund() public {
        register99();
        unlock();
        RejectEth wallet = new RejectEth();
        vm.deal(address(wallet), 0.01 ether);
        start(address(wallet));
        vm.prank(BOB);
        auction.bid{value: 0.011 ether}(0.011 ether, 0, 0);
        assertEq(auction.refunds(address(wallet)), 0.01 ether);
        assertEq(address(auction).balance, auction.liabilities());
        vm.expectRevert(EnglishAuction.EthTransferFailed.selector);
        vm.prank(address(wallet));
        auction.withdrawRefund(address(wallet));
        assertEq(auction.refunds(address(wallet)), 0.01 ether);
        vm.prank(address(wallet));
        auction.withdrawRefund(CAROL);
        assertEq(CAROL.balance, 0.02 ether);
        assertEq(auction.refundLiability(), 0);
    }

    function testNativePayoutAuthorizationAndReentrancy() public {
        register99();
        unlock();
        ReenterEth wallet = new ReenterEth();
        wallet.configure(auction);
        vm.deal(address(wallet), 0.01 ether);
        start(address(wallet));
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(BOB);
        auction.payOutbidRefund(BOB, 0.01 ether);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(BOB);
        auction.withdrawProceeds(BOB);
        vm.expectRevert(EnglishAuction.NothingToWithdraw.selector);
        vm.prank(BOB);
        auction.withdrawRefund(BOB);
        vm.prank(ALICE);
        auction.bid{value: 0.011 ether}(0.011 ether, 0, 0);
        assertTrue(!wallet.reentered());
        assertEq(address(wallet).balance, 0.01 ether);
        assertEq(address(auction).balance, auction.liabilities());
    }

    function testFuzzNativeBidFullyFunded(uint64 seed) public {
        register99();
        unlock();
        start(ALICE);
        uint256 amount = (11 + uint256(seed) % 10000) * 0.001 ether;
        vm.deal(BOB, amount);
        vm.prank(BOB);
        auction.bid{value: amount}(amount, 0, 0);
        assertEq(address(auction).balance, amount);
        assertEq(auction.liabilities(), amount);
        assertEq(ALICE.balance, 1 ether);
    }
}
