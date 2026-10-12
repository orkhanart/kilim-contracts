// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "./TestBase.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";

/// @dev A bidder contract with switches: reject ETH, burn a set amount of gas on ETH or on an NFT,
///      reject NFTs, and try one call back into the auction from either callback.
contract ProbeWallet is IERC721Receiver {
    KilimAuction private immutable auction;
    bool public rejectNft;
    uint256 public burnOnEth;
    uint256 public burnOnNft;
    bytes public reenter;
    bool public reentered;

    constructor(KilimAuction a) {
        auction = a;
    }

    function set(bool rejectNft_, uint256 burnOnEth_, uint256 burnOnNft_, bytes calldata reenter_) external {
        rejectNft = rejectNft_;
        burnOnEth = burnOnEth_;
        burnOnNft = burnOnNft_;
        reenter = reenter_;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function run(bytes calldata data) external returns (bool ok) {
        (ok,) = address(auction).call(data);
    }

    function _burn(uint256 amount) private view {
        uint256 start = gasleft();
        if (amount == type(uint256).max) while (gasleft() > 0) {}
        while (start - gasleft() < amount) {}
    }

    function _callback() private {
        if (reenter.length != 0) (reentered,) = address(auction).call(reenter);
    }

    receive() external payable {
        _burn(burnOnEth);
        _callback();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectNft, "NFT rejected");
        _burn(burnOnNft);
        _callback();
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev An ERC-1271 wallet that accepts any signature.
contract AnySignatureWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice Tests the October 9 and 10 audits found missing (F-05, F-16, F-18, R-11 to R-18). Each one
///         fails when the check it names is removed or loosened.
contract AuditGapsTest is TestBase {
    KilimAuction internal auction;
    KilimMotifs internal nft;

    function setUp() public {
        auction = new KilimAuction(config());
        nft = auction.motifs();
        _openBidding(auction);
        _fund(ALICE, 100 ether);
        _fund(BOB, 100 ether);
    }

    function _wallet() private returns (ProbeWallet w) {
        w = new ProbeWallet(auction);
        _fund(address(w), 10 ether);
    }

    // ---- the gas caps bound what a hostile wallet can cost others (F-05, R-11) ----

    function testGasBurningLeaderCostsARivalNoMoreThanTheRefundCap() public {
        ProbeWallet leader = _wallet();
        leader.set(false, type(uint256).max, 0, "");
        leader.bid(RESERVE);
        uint256 amount = auction.minimumBid();
        vm.prank(ALICE);
        uint256 before = gasleft();
        auction.bid{value: amount}(amount, 0, 0);
        uint256 used = before - gasleft();
        assertEq(auction.refunds(address(leader)), RESERVE);
        // The refund's 150,000 cap plus the bid itself (about 128,000 today); a cap of 193,000 or more
        // fails this.
        assertTrue(used < 320_000);
    }

    function testGasBurningWinnerCostsSettleNoMoreThanThePrizeCap() public {
        ProbeWallet winner = _wallet();
        winner.set(false, 0, type(uint256).max, "");
        winner.bid(RESERVE);
        vm.warp(auction.endsAt());
        uint256 before = gasleft();
        auction.settle();
        uint256 used = before - gasleft();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        // The delivery's 1,000,000 cap plus settlement itself, less the 1/64 shares held back at the
        // delivery's two inner calls (they come back): 1,001,448 today. A cap of about 1,102,000 or more
        // fails this.
        assertTrue(used < 1_100_000);
    }

    // ---- the gas given to a receiver is really what the constants promise (R-12) ----

    function testAWinnerNeedingMostOfThePrizeCapIsDeliveredAtAnyGasLimit() public {
        ProbeWallet winner = _wallet();
        // Under the most a winner's callback can use. This winner is built inside the test, so the 1/1
        // and the winner are already warm when settle() runs and the budget here is about 873,000; a
        // settle() sent on mainnet finds both cold and leaves about 4,900 less (ColdPrizeBudgetTest
        // below measures that state). 870,000 is delivered in both.
        winner.set(false, 0, 870_000, "");
        winner.bid(RESERVE);
        vm.warp(auction.endsAt());
        uint256 delivered;
        for (uint256 gasLimit = 100_000; gasLimit <= 1_500_000; gasLimit += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{gas: gasLimit}(abi.encodeCall(auction.settle, ()));
            if (ok) {
                assertTrue(auction.prizeClaimed());
                assertEq(auction.oneOfOne().ownerOf(1), address(winner));
                ++delivered;
            } else {
                assertTrue(!auction.settled());
            }
            vm.revertToState(snap);
        }
        assertTrue(delivered != 0);
    }

    function testAReceiverNeedingMostOfTheRefundCapIsStillPaid() public {
        ProbeWallet leader = _wallet();
        leader.set(false, 120_000, 0, "");
        leader.bid(RESERVE);
        uint256 balance = address(leader).balance;
        uint256 amount = auction.minimumBid();
        vm.expectEmit();
        emit EnglishAuction.RefundPaid(address(leader), RESERVE);
        _bid(auction, ALICE, amount);
        assertEq(address(leader).balance, balance + RESERVE);
        assertEq(auction.refunds(address(leader)), 0);
        assertEq(auction.refundLiability(), 0);
    }

    // ---- the guard on the two payout entry points no other test re-enters (R-14) ----

    function testProceedsRecipientCannotReenter() public {
        ProbeWallet sink = _wallet();
        sink.bid(RESERVE);
        _bid(auction, ALICE, auction.minimumBid());
        vm.warp(auction.endsAt());
        auction.settle();
        bytes memory claim = abi.encodeCall(auction.claimMotifs, (1, CAROL));
        sink.set(false, 0, 0, claim);
        uint256 credits = auction.motifCredits(address(sink));
        vm.prank(TREASURY);
        auction.withdrawProceeds(address(sink));
        assertTrue(!sink.reentered());
        assertEq(auction.motifCredits(address(sink)), credits);
        // The same call is valid outside the payout: it failed on the guard, not on its own terms.
        assertTrue(sink.run(claim));
        assertEq(auction.motifCredits(address(sink)), credits - 1);
    }

    function testClaimedPrizeCallbackCannotReenter() public {
        ProbeWallet winner = _wallet();
        winner.set(true, 0, 0, "");
        winner.bid(RESERVE);
        vm.warp(auction.endsAt());
        auction.settle();
        assertTrue(!auction.prizeClaimed());
        bytes memory claim = abi.encodeCall(auction.claimMotifs, (1, CAROL));
        winner.set(false, 0, 0, claim);
        uint256 credits = auction.motifCredits(address(winner));
        assertTrue(winner.run(abi.encodeCall(auction.claimPrize, (address(winner)))));
        assertEq(auction.oneOfOne().ownerOf(1), address(winner));
        assertTrue(!winner.reentered());
        assertEq(auction.motifCredits(address(winner)), credits);
        winner.set(false, 0, 0, "");
        assertTrue(winner.run(claim));
    }

    // ---- the registration signature is the standard EIP-712 hash the site signs (F-18, R-15) ----

    function testRegistrationDigestIsTheStandardEip712Hash() public view {
        address wallet = address(0xC0FFEE);
        uint256 deadline = 1_900_000_000;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Kilim Registration"),
                keccak256("1"),
                block.chainid,
                address(auction)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Register(address wallet,uint256 deadline)"), wallet, deadline));
        assertEq(
            auction.registrationDigest(wallet, deadline),
            keccak256(abi.encodePacked(hex"1901", domain, structHash))
        );
    }

    // ---- only the auction makes its self-calls, whoever asks (R-16) ----

    function testFuzzOnlyTheAuctionMakesItsSelfCalls(address caller, uint8 pick) public {
        _bid(auction, ALICE, RESERVE);
        _bid(auction, BOB, auction.minimumBid());
        vm.warp(auction.endsAt());
        uint256 k = pick % 5;
        if (k == 1) caller = TREASURY;
        if (k == 2) caller = auction.highestBidder();
        if (k == 3) caller = address(nft);
        if (k == 4) caller = address(auction.oneOfOne());
        if (caller == address(auction)) return;
        uint256 held = address(auction).balance;
        uint256 own = caller.balance;

        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(caller);
        auction.payOutbidRefund(caller, held);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(caller);
        auction.payOutbidRefund(ALICE, 1);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        vm.prank(caller);
        auction.deliverPrize();

        assertEq(address(auction).balance, held);
        assertEq(caller.balance, own);
        assertEq(address(auction).balance, auction.liabilities());
        assertTrue(!auction.oneOfOne().minted());
        assertTrue(!auction.prizeClaimed());
    }

    // ---- events an indexer relies on, and the first bid refunding nobody (R-17) ----

    function testRegistrationStartAndSettlementEvents() public {
        KilimAuction fresh = new KilimAuction(config());
        vm.warp(fresh.startsAt());
        vm.deal(registrant(0), RESERVE);
        vm.expectEmit();
        emit EnglishAuction.Registered(registrant(0), 1);
        vm.prank(registrant(0));
        fresh.register();
        _registerWallets(fresh, 98);
        vm.deal(registrant(99), RESERVE);
        vm.expectEmit();
        emit EnglishAuction.Registered(registrant(99), 100);
        vm.prank(registrant(99));
        fresh.register();

        vm.expectEmit();
        emit EnglishAuction.AuctionStarted(ALICE, uint64(block.timestamp) + fresh.duration());
        _bid(fresh, ALICE, RESERVE);
        vm.warp(fresh.endsAt());
        vm.expectEmit();
        emit EnglishAuction.AuctionSettled(ALICE, RESERVE);
        fresh.settle();
    }

    /// @dev With nobody to refund, the first bid must not need the refund's gas floor.
    function testFirstBidNeedsNoRefundGas() public {
        vm.prank(ALICE);
        (bool ok,) =
            address(auction).call{value: RESERVE, gas: 250_000}(abi.encodeCall(auction.bid, (RESERVE, 0, 0)));
        assertTrue(ok);
        assertEq(auction.refundLiability(), 0);
    }

    // ---- constructor and deadline edges (R-18) ----

    function testTreasuryCannotBeTheAuctionAndTheBoundsAreInclusive() public {
        KilimAuction.Config memory c = config();
        c.startsAt = uint64(block.timestamp + 1 hours);
        c.treasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);

        c = config();
        c.startsAt = uint64(block.timestamp + 1 hours);
        c.duration = 30 days;
        c.extensionWindow = 30 days;
        KilimAuction ok = new KilimAuction(c);
        assertEq(ok.duration(), 30 days);
        assertEq(ok.extensionWindow(), 30 days);

        c.duration = 30 days + 1;
        c.extensionWindow = 10 minutes;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);

        c.duration = 1 days;
        c.extensionWindow = 1 days + 1;
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
    }

    function testSignatureIsGoodThroughItsDeadlineSecondAndNotAfter() public {
        KilimAuction fresh = new KilimAuction(config());
        vm.warp(fresh.startsAt());
        address wallet = address(new AnySignatureWallet());
        vm.deal(wallet, RESERVE);
        uint256 deadline = block.timestamp + 15 minutes;
        vm.warp(deadline + 1);
        vm.expectRevert(EnglishAuction.RegistrationSignatureExpired.selector);
        fresh.registerFor(wallet, deadline, "");
        vm.warp(deadline);
        fresh.registerFor(wallet, deadline, "");
        assertTrue(fresh.registered(wallet));
    }

    // ---- registration gates (F-16) ----

    function testRegistrationIsClosedBeforeStartAndToTheTreasury() public {
        KilimAuction fresh = new KilimAuction(config());
        vm.deal(ALICE, RESERVE);
        vm.expectRevert(EnglishAuction.RegistrationClosed.selector);
        vm.prank(ALICE);
        fresh.register();
        assertEq(fresh.registrationCount(), 0);

        vm.warp(fresh.startsAt());
        vm.deal(TREASURY, RESERVE);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(TREASURY);
        fresh.register();
        assertEq(fresh.registrationCount(), 0);
    }
}

/// @dev A winner whose NFT hook burns `block.timestamp - close` gas: the amount is set by the clock, so
///      the winner can be built in setUp and never touched before settle() runs.
contract ClockHungryWinner is IERC721Receiver {
    KilimAuction private immutable auction;
    uint256 private immutable close;

    constructor(KilimAuction a, uint256 close_) {
        auction = a;
        close = close_;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        uint256 burn = block.timestamp - close;
        while (start - gasleft() < burn) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Review round, 10 October 2026: the prize delivery measured as a mainnet settle() meets it.
///         The auction, the 1/1 and the winner are built in setUp, so inside the test they are cold: no
///         account or storage slot has been read yet when settle() is called.
contract ColdPrizeBudgetTest is TestBase {
    uint256 private constant PRIZE_GAS = 1_000_000;
    KilimAuction private auction;
    ClockHungryWinner private winner;
    uint256 private close;

    event log_named_uint(string key, uint256 value);

    function setUp() public {
        auction = new KilimAuction(config());
        _openBidding(auction);
        close = block.timestamp + auction.duration();
        winner = new ClockHungryWinner(auction, close);
        _fund(address(winner), 1 ether);
        winner.bid(RESERVE);
        assertEq(auction.endsAt(), close);
    }

    function _delivered(uint256 burn) private returns (bool delivered) {
        uint256 snap = vm.snapshotState();
        vm.warp(close + burn);
        auction.settle();
        delivered = auction.prizeClaimed();
        vm.revertToState(snap);
    }

    /// @dev What a winner's hook may use today, cold, to one gas. The bounds are loose on purpose: a
    ///      compiler or library change may move the number by a few hundred gas, not by thousands.
    function testColdHookBudgetToday() public {
        uint256 lo = 855_000;
        uint256 hi = 885_000;
        assertTrue(_delivered(lo));
        assertTrue(!_delivered(hi));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_delivered(mid)) lo = mid;
            else hi = mid;
        }
        emit log_named_uint("cold hook budget today (gas a winner's hook may use)", lo);
        emit log_named_uint("delivery overhead, cold", PRIZE_GAS - lo);
        assertTrue(lo >= 869_500 && lo < 873_500);
    }

    /// @dev A winner burning 870,000 is delivered at every gas limit that settles, cold.
    function testAColdWinnerNeedingMostOfTheCapIsDeliveredAtAnyGasLimit() public {
        vm.warp(close + 870_000);
        uint256 delivered;
        for (uint256 gasLimit = 100_000; gasLimit <= 1_500_000; gasLimit += 5_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{gas: gasLimit}(abi.encodeCall(auction.settle, ()));
            if (ok) {
                assertTrue(auction.prizeClaimed());
                assertEq(auction.oneOfOne().ownerOf(1), address(winner));
                ++delivered;
            } else {
                assertTrue(!auction.settled());
            }
            vm.revertToState(snap);
        }
        assertTrue(delivered != 0);
    }
}
