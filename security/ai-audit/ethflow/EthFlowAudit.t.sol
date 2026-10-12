// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "../../../test/TestBase.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";

/// @dev forge-std's Vm.Gas, as returned by lastCallGas().
struct CallGas {
    uint64 gasLimit;
    uint64 gasTotalUsed;
    uint64 gasMemoryUsed;
    int64 gasRefunded;
    uint64 gasRemaining;
}

interface VmEth {
    function lastCallGas() external view returns (CallGas memory);
    function cool(address) external;
    function record() external;
    function accesses(address) external returns (bytes32[] memory reads, bytes32[] memory writes);
    function load(address, bytes32) external view returns (bytes32);
    function resetNonce(address) external;
    function getNonce(address) external view returns (uint64);
}

/// @dev An outbid leader with a chosen receive(): 0 accept, 1 refuse, 2 burn every unit of gas,
///      3 accept with a 150,000-byte return buffer, 4 accept after burning down to 3,000 gas,
///      5 try to re-enter withdrawRefund and settle, then accept.
contract ModalLeader is IERC721Receiver {
    KilimAuction private immutable auction;
    uint8 public mode;
    uint256 public reentered;

    constructor(KilimAuction a) {
        auction = a;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function withdraw(address to) external {
        auction.withdrawRefund(to);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        uint8 m = mode;
        if (m == 1) revert("no");
        if (m == 2) {
            while (true) {}
        }
        if (m == 3) {
            assembly ("memory-safe") {
                return(0, 150000)
            }
        }
        if (m == 4) {
            while (gasleft() > 3_000) {}
            return;
        }
        if (m == 5) {
            (bool ok,) = address(auction).call(abi.encodeCall(auction.withdrawRefund, (address(this))));
            if (ok) ++reentered;
            (ok,) = address(auction).call(abi.encodeCall(auction.settle, ()));
            if (ok) ++reentered;
            (ok,) = address(auction).call(abi.encodeCall(auction.payOutbidRefund, (address(this), 1)));
            if (ok) ++reentered;
        }
    }
}

/// @dev A winner with an empty NFT hook, for the contract-winner delivery cost.
contract PlainContractWinner is IERC721Receiver {
    function bid(KilimAuction a, uint256 amount) external {
        a.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

abstract contract EthFlowBase is TestBase {
    VmEth internal constant vmx = VmEth(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 value);
    event log_named_int(string key, int256 value);

    /// @dev Fresh (zero to nonzero) and updated storage writes `data` makes in `target`, measured by
    ///      running the call once to learn the slots, rolling back, then reading their values before.
    function _countWrites(address caller, uint256 value, uint256 gasLimit, bytes memory data, address target)
        internal
        returns (uint256 fresh, uint256 updated)
    {
        uint256 snap = vm.snapshotState();
        vmx.record();
        vm.prank(caller);
        (bool ok,) = _auctionAddr().call{value: value, gas: gasLimit}(data);
        require(ok, "probe call failed");
        (, bytes32[] memory slots) = vmx.accesses(target);
        vm.revertToState(snap);
        bytes32[] memory pre = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            pre[i] = vmx.load(target, slots[i]);
        }
        snap = vm.snapshotState();
        vm.prank(caller);
        (ok,) = _auctionAddr().call{value: value, gas: gasLimit}(data);
        require(ok, "call failed");
        // Each slot once, however often it was written.
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (slots[j] == slots[i]) seen = true;
            }
            if (seen) continue;
            bytes32 post = vmx.load(target, slots[i]);
            if (pre[i] == bytes32(0) && post != bytes32(0)) ++fresh;
            else if (pre[i] != post) ++updated;
        }
        vm.revertToState(snap);
    }

    function _auctionAddr() internal view virtual returns (address);
}

/// @notice ETH-1 / ETH-2: how much the fixed gas numbers leave over, measured cold as a mainnet
///         transaction meets the state, and what new-slot price would use it up.
contract EthFlowGasMarginsTest is EthFlowBase {
    KilimAuction internal auction;
    ModalLeader internal leader;
    address internal constant RIVAL = address(0xF1257B1D); // a first-time bidder
    uint256 internal amount;

    // The site's fixed limits (site/chain.js:22).
    uint256 internal constant BID_GAS = 1_500_000;
    uint256 internal constant SETTLE_GAS = 1_200_000;
    // Today's price of setting a fresh slot (EIP-2200 SSTORE_SET); a cold slot adds 2,100 on top.
    uint256 internal constant SET_PRICE_TODAY = 20_000;

    function _auctionAddr() internal view override returns (address) {
        return address(auction);
    }

    function setUp() public {
        auction = new KilimAuction(config());
        _openBidding(auction);
        leader = new ModalLeader(auction);
        vm.deal(address(leader), 1 ether);
        leader.bid(RESERVE);
        leader.setMode(2); // its receive() burns everything it is given
        vm.deal(RIVAL, 10 ether);
        amount = auction.minimumBid();
    }

    function _bidData() internal view returns (bytes memory) {
        return abi.encodeCall(auction.bid, (amount, 0, 0));
    }

    /// @dev One rival bid with `gasLimit` call gas, everything but the sender cold.
    function _try(uint256 gasLimit) internal returns (bool ok, bytes memory ret, CallGas memory g) {
        vmx.cool(address(auction));
        vmx.cool(address(leader));
        vm.prank(RIVAL);
        (ok, ret) = address(auction).call{value: amount, gas: gasLimit}(_bidData());
        g = vmx.lastCallGas();
    }

    function _minimumBidGas() internal returns (uint256 hi) {
        uint256 lo = 200_000;
        hi = 2_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,,) = _try(mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    /// @notice DEFERRED_REFUND_RESERVE: at the smallest call gas that passes the refund floor, with
    ///         a leader that burns the whole 150,000 and a first deferral (two fresh slots), how much
    ///         gas is left when the bid returns, and the fresh-slot price that would use it up.
    function testDeferredRefundReserveSlackAtTheFloor() public {
        assertEq(auction.refunds(address(leader)), 0);
        assertEq(auction.refundLiability(), 0);
        uint256 lMin = _minimumBidGas();

        // One gas less fails on the floor check itself, never as a bare out-of-gas in the deferral.
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret,) = _try(lMin - 1);
        assertTrue(!ok);
        assertEq(bytes32(ret), bytes32(EnglishAuction.InsufficientGas.selector));
        vm.revertToState(snap);

        snap = vm.snapshotState();
        CallGas memory g;
        (ok,, g) = _try(lMin);
        assertTrue(ok);
        assertEq(auction.refunds(address(leader)), RESERVE);
        vm.revertToState(snap);

        (uint256 fresh, uint256 updated) = _countWrites(RIVAL, amount, BID_GAS, _bidData(), address(auction));
        emit log_named_uint("smallest call gas for the bid (cold, burning leader)", lMin);
        emit log_named_uint("gas left when the bid returns at that limit (slack)", g.gasRemaining);
        emit log_named_uint("fresh slots written by the whole bid", fresh);
        emit log_named_uint("slots updated by the whole bid", updated);
        // Two of the fresh slots are written after the refund call: refunds[leader], refundLiability.
        uint256 surcharge = uint256(g.gasRemaining) / 2;
        emit log_named_uint("fresh-slot surcharge that uses the slack up (per slot)", surcharge);
        emit log_named_uint("=> SSTORE-set price at which the 300k reserve is exhausted", SET_PRICE_TODAY + surcharge);
        assertTrue(g.gasRemaining > 0);
    }

    /// @notice The site's BID_GAS of 1,500,000 against the worst outbidding bid: a first-time bidder,
    ///         a leader that burns the refund's 150,000, and the auction's first deferral.
    function testWorstCaseBidAgainstTheSiteLimit() public {
        uint256 lMin = _minimumBidGas();
        uint256 snap = vm.snapshotState();
        (bool ok,, CallGas memory g) = _try(BID_GAS);
        assertTrue(ok);
        vm.revertToState(snap);
        (uint256 fresh,) = _countWrites(RIVAL, amount, BID_GAS, _bidData(), address(auction));
        // Intrinsic gas: 21,000 plus calldata (4 + 3 x 32 bytes).
        bytes memory data = _bidData();
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        uint256 used = intrinsic + g.gasTotalUsed;
        uint256 needed = intrinsic + lMin;
        emit log_named_uint("worst-case outbidding bid, gas used as a transaction (cold)", used);
        emit log_named_uint("worst-case outbidding bid, gas limit it needs (floor)", needed);
        emit log_named_uint("fresh slots written", fresh);
        // Two ways 1.5M can stop being enough: the floor (three fresh slots are written before it) or
        // the whole bid's use (all five). The smaller surcharge is the one that binds.
        uint256 perSlotFloor = (BID_GAS - needed) / 3;
        uint256 perSlotUse = (BID_GAS - used) / fresh;
        emit log_named_uint("surcharge per fresh slot at which BID_GAS fails the floor", perSlotFloor);
        emit log_named_uint("surcharge per fresh slot at which BID_GAS runs out in use", perSlotUse);
        emit log_named_uint("=> SSTORE-set price at which 1.5M is no longer enough", SET_PRICE_TODAY
                + (perSlotFloor < perSlotUse ? perSlotFloor : perSlotUse));
        assertEq(fresh, 5);
    }

    /// @notice F-01 re-checked against more receiver shapes: the smallest call gas at which a rival's
    ///         bid lands is the same to the gas whatever the leader's receive() does (accept, refuse,
    ///         burn all, return bomb, starve its caller, try to re-enter).
    function testMinimumBidGasIsTheSameForEveryLeaderShape() public {
        uint256 first;
        for (uint8 m; m < 6; ++m) {
            uint256 snap = vm.snapshotState();
            leader.setMode(m);
            uint256 lMin = _minimumBidGas();
            vm.revertToState(snap);
            emit log_named_uint(string.concat("smallest call gas, leader mode ", vm.toString(uint256(m))), lMin);
            if (m == 0) first = lMin;
            else assertEq(lMin, first);
        }
    }
}

/// @notice ETH-1: the prize delivery's fixed 500,000 against fresh-slot prices.
contract EthFlowPrizeMarginTest is EthFlowBase {
    uint256 internal constant PRIZE_GAS = 500_000;
    uint256 internal constant SET_PRICE_TODAY = 20_000;
    KilimAuction internal auction;
    KilimOneOfOne internal one;
    address internal constant EOA_WINNER = address(0xE0A11CE);
    PlainContractWinner internal contractWinner;

    function _auctionAddr() internal view override returns (address) {
        return address(auction);
    }

    function setUp() public {
        auction = new KilimAuction(config());
        one = auction.oneOfOne();
        _openBidding(auction);
        contractWinner = new PlainContractWinner();
        vm.deal(EOA_WINNER, 1 ether);
        vm.deal(address(contractWinner), 1 ether);
    }

    /// @dev The delivery's own gas (deliverPrize as the auction calls it), cold as in a mainnet
    ///      settle: the 1/1 and the winner cold, the auction's highestBidder slot warm (settle read it).
    function _deliveryGas() internal returns (uint256 used, uint256 fresh) {
        uint256 snap = vm.snapshotState();
        vmx.cool(address(one));
        vmx.cool(auction.highestBidder());
        vmx.cool(address(auction));
        auction.highestBidder(); // settle() has read this slot already
        vm.prank(address(auction));
        auction.deliverPrize();
        used = vmx.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        // Fresh slots: prizeClaimed in the auction, and those of the 1/1's mint.
        snap = vm.snapshotState();
        vmx.record();
        vm.prank(address(auction));
        auction.deliverPrize();
        (, bytes32[] memory wa) = vmx.accesses(address(auction));
        (, bytes32[] memory wo) = vmx.accesses(address(one));
        vm.revertToState(snap);
        fresh = _freshOf(address(auction), wa) + _freshOf(address(one), wo);
    }

    function _freshOf(address target, bytes32[] memory slots) internal returns (uint256 n) {
        uint256 snap = vm.snapshotState();
        bytes32[] memory pre = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            pre[i] = vmx.load(target, slots[i]);
        }
        vm.prank(address(auction));
        auction.deliverPrize();
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (slots[j] == slots[i]) seen = true;
            }
            if (!seen && pre[i] == bytes32(0) && vmx.load(target, slots[i]) != bytes32(0)) ++n;
        }
        vm.revertToState(snap);
    }

    /// @dev The 1/1's own mint, as the auction calls it, cold.
    function _mintGas(address to) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        vmx.cool(address(one));
        vmx.cool(to);
        vm.prank(address(auction));
        one.mint(to);
        used = vmx.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
    }

    function testPrizeMintSplit() public {
        _bid(auction, EOA_WINNER, RESERVE);
        vm.warp(auction.endsAt());
        (uint256 total,) = _deliveryGas();
        uint256 mintEoa = _mintGas(EOA_WINNER);
        uint256 mintContract = _mintGas(address(contractWinner));
        emit log_named_uint("deliverPrize total, EOA winner", total);
        emit log_named_uint("1/1 mint alone, EOA winner", mintEoa);
        emit log_named_uint("1/1 mint alone, contract winner with an empty hook", mintContract);
    }

    function testPrizeDeliveryHeadroomForAnEoaAndAContractWinner() public {
        uint256 snap = vm.snapshotState();
        _bid(auction, EOA_WINNER, RESERVE);
        vm.warp(auction.endsAt());
        (uint256 eoaUsed, uint256 eoaFresh) = _deliveryGas();
        vm.revertToState(snap);

        contractWinner.bid(auction, RESERVE);
        vm.warp(auction.endsAt());
        (uint256 cUsed, uint256 cFresh) = _deliveryGas();

        emit log_named_uint("delivery gas to an EOA winner (cold)", eoaUsed);
        emit log_named_uint("fresh slots in the delivery (EOA)", eoaFresh);
        emit log_named_uint("delivery gas to a contract winner with an empty hook (cold)", cUsed);
        emit log_named_uint("fresh slots in the delivery (contract)", cFresh);
        uint256 eoaSurcharge = (PRIZE_GAS - eoaUsed) / eoaFresh;
        uint256 cSurcharge = (PRIZE_GAS - cUsed) / cFresh;
        emit log_named_uint("surcharge per fresh slot at which no EOA winner is delivered", eoaSurcharge);
        emit log_named_uint("=> SSTORE-set price (EOA)", SET_PRICE_TODAY + eoaSurcharge);
        emit log_named_uint("surcharge per fresh slot at which no contract winner is delivered", cSurcharge);
        emit log_named_uint("=> SSTORE-set price (contract, empty hook)", SET_PRICE_TODAY + cSurcharge);
        assertEq(eoaFresh, 4);
        assertEq(cFresh, 4);
    }

    /// @notice What a failed delivery leaves: settlement and proceeds stand, the winner alone can claim,
    ///         and nobody else can deliver or claim. A winner that cannot make the call keeps nothing.
    function testAFailedDeliveryLeavesOnlyTheWinnersOwnClaim() public {
        HookBurner w = new HookBurner(auction);
        vm.deal(address(w), 1 ether);
        w.bid(RESERVE);
        vm.warp(auction.endsAt());
        auction.settle{gas: 1_200_000}();
        assertTrue(auction.settled());
        assertTrue(!auction.prizeClaimed());
        assertEq(address(auction).balance, auction.liabilities());
        // Nobody else can claim it or deliver it again.
        vm.prank(ALICE);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        auction.claimPrize(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(EnglishAuction.Unauthorized.selector);
        auction.deliverPrize();
        // The treasury is paid regardless.
        uint256 before = TREASURY.balance;
        vm.prank(TREASURY);
        auction.withdrawProceeds(TREASURY);
        assertEq(TREASURY.balance - before, RESERVE);
        assertTrue(!auction.oneOfOne().minted());
    }
}

/// @dev A winner whose NFT hook needs more than the delivery's allowance (as any hook would once a
///      fresh slot costs more than the headroom measured above), and which has no claimPrize call.
contract HookBurner is IERC721Receiver {
    KilimAuction private immutable auction;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        while (gasleft() > 0) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Properties of the push refund against every kind of leader and every gas limit.
contract EthFlowRefundPropertiesTest is EthFlowBase {
    KilimAuction internal auction;
    address internal constant RIVAL = address(0xF1257B1D);

    function _auctionAddr() internal view override returns (address) {
        return address(auction);
    }

    function setUp() public {
        auction = new KilimAuction(config());
        _openBidding(auction);
        vm.deal(RIVAL, 100 ether);
    }

    /// @notice For any leader behaviour and any gas limit, the bid either changes nothing or lands
    ///         with the leader's old bid paid exactly once: pushed or owed, never both, never neither.
    function testFuzzEveryLeaderIsPaidExactlyOnceOrNothingChanges(uint8 modeSeed, uint256 gasSeed) public {
        uint8 mode = modeSeed % 6;
        uint256 gasLimit = 30_000 + gasSeed % 1_600_000;
        ModalLeader leader = new ModalLeader(auction);
        vm.deal(address(leader), 1 ether);
        leader.bid(RESERVE);
        leader.setMode(mode);
        uint256 amount = auction.minimumBid();
        uint256 leaderBefore = address(leader).balance;
        uint256 auctionBefore = address(auction).balance;

        vm.prank(RIVAL);
        (bool ok,) =
            address(auction).call{value: amount, gas: gasLimit}(abi.encodeCall(auction.bid, (amount, 0, 0)));

        if (!ok) {
            assertEq(auction.highestBidder(), address(leader));
            assertEq(address(auction).balance, auctionBefore);
            assertEq(address(leader).balance, leaderBefore);
            assertEq(auction.refunds(address(leader)), 0);
        } else {
            assertEq(auction.highestBidder(), RIVAL);
            uint256 paid = address(leader).balance - leaderBefore;
            uint256 owed = auction.refunds(address(leader));
            assertTrue((paid == RESERVE && owed == 0) || (paid == 0 && owed == RESERVE));
            if (mode == 0 || mode == 4 || mode == 5) assertEq(paid, RESERVE);
            if (mode == 1 || mode == 2) assertEq(owed, RESERVE);
            assertEq(leader.reentered(), 0);
            if (owed != 0) {
                leader.withdraw(ALICE);
                assertEq(auction.refunds(address(leader)), 0);
            }
        }
        assertEq(address(auction).balance, auction.liabilities());
    }

    /// @notice ETH-4: a leader whose account was emptied after it bid (a contract that bid from its
    ///         constructor and self-destructed in the same transaction, EIP-6780). The rival's bid pays
    ///         for re-creating that account inside the refund call: 25,000 today, which fits the
    ///         150,000; at Glamsterdam's 183,600 for a new account it cannot, and the refund is deferred.
    function testRefundToAnEmptiedAccountRecreatesIt() public {
        address ghost = address(0x6057);
        vm.deal(ghost, 1 ether);
        vm.prank(ghost);
        auction.bid{value: RESERVE}(RESERVE, 0, 0);
        uint256 amount = auction.minimumBid();

        // Same bid against the ghost while it still exists.
        uint256 snap = vm.snapshotState();
        vmx.cool(address(auction));
        vmx.cool(ghost);
        vm.prank(RIVAL);
        (bool ok,) =
            address(auction).call{value: amount, gas: 1_500_000}(abi.encodeCall(auction.bid, (amount, 0, 0)));
        assertTrue(ok);
        uint256 usedLive = vmx.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);

        // Emptied: no code, no balance, nonce 0, as EIP-6780 leaves a same-transaction self-destruct.
        vm.deal(ghost, 0);
        vmx.resetNonce(ghost);
        vm.etch(ghost, "");
        vmx.cool(address(auction));
        vmx.cool(ghost);
        vm.prank(RIVAL);
        (ok,) =
            address(auction).call{value: amount, gas: 1_500_000}(abi.encodeCall(auction.bid, (amount, 0, 0)));
        assertTrue(ok);
        uint256 usedEmpty = vmx.lastCallGas().gasTotalUsed;
        emit log_named_uint("rival bid gas, leader account live", usedLive);
        emit log_named_uint("rival bid gas, leader account emptied", usedEmpty);
        emit log_named_uint("extra paid by the rival to re-create it", usedEmpty - usedLive);
        assertEq(ghost.balance, RESERVE);
        assertEq(auction.refunds(ghost), 0);
        assertEq(address(auction).balance, auction.liabilities());
    }
}

/// @notice Cancun baselines for the Sepolia (Glamsterdam) receipts quoted in the brief: register 142k,
///         a full outbid bid 428k to 648k. The difference, per fresh slot, is the surcharge Sepolia
///         actually charges today, which the margins above are compared with.
contract EthFlowSepoliaBaselineTest is EthFlowBase {
    KilimAuction internal auction;
    ModalLeader internal leader;
    address internal constant RIVAL = address(0xF1257B1D);
    address internal constant LATE = address(0x1A7E);

    function _auctionAddr() internal view override returns (address) {
        return address(auction);
    }

    function setUp() public {
        auction = new KilimAuction(config());
        vm.warp(auction.startsAt());
        _registerWallets(auction, 99);
        vm.deal(LATE, 1 ether);
        vm.deal(RIVAL, 10 ether);
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function testCancunBaselines() public {
        // A later registration (the 100th), cold.
        vmx.cool(address(auction));
        vm.prank(LATE);
        (bool ok,) = address(auction).call{gas: 1_000_000}(abi.encodeCall(auction.register, ()));
        assertTrue(ok);
        uint256 reg = _intrinsic(abi.encodeCall(auction.register, ())) + vmx.lastCallGas().gasTotalUsed;
        emit log_named_uint("register(), 100th, as a transaction (cold)", reg);

        // The opening bid (the site sends the node's estimate x 4/3), first-time bidder, cold.
        {
            bytes memory open = abi.encodeCall(auction.bid, (RESERVE, 0, 0));
            uint256 s0 = vm.snapshotState();
            vmx.cool(address(auction));
            vm.prank(RIVAL);
            (ok,) = address(auction).call{value: RESERVE, gas: 1_500_000}(open);
            assertTrue(ok);
            uint256 openUsed = _intrinsic(open) + vmx.lastCallGas().gasTotalUsed;
            vm.revertToState(s0);
            (uint256 openFresh,) = _countWrites(RIVAL, RESERVE, 1_500_000, open, address(auction));
            emit log_named_uint("opening bid, as a transaction (cold)", openUsed);
            emit log_named_uint("  fresh slots", openFresh);
            emit log_named_uint("  x 4/3, the site's gas limit for it", openUsed * 4 / 3);
        }
        leader = new ModalLeader(auction);
        vm.deal(address(leader), 1 ether);
        leader.bid(RESERVE);
        uint256 amount = auction.minimumBid();
        bytes memory data = abi.encodeCall(auction.bid, (amount, 0, 0));
        for (uint8 m; m < 2; ++m) {
            uint256 snap = vm.snapshotState();
            leader.setMode(m); // 0: accepts (refund paid), 1: refuses (first deferral)
            vmx.cool(address(auction));
            vmx.cool(address(leader));
            vm.prank(RIVAL);
            (ok,) = address(auction).call{value: amount, gas: 1_500_000}(data);
            assertTrue(ok);
            uint256 used = _intrinsic(data) + vmx.lastCallGas().gasTotalUsed;
            vm.revertToState(snap);
            snap = vm.snapshotState();
            leader.setMode(m);
            (uint256 fresh,) = _countWrites(RIVAL, amount, 1_500_000, data, address(auction));
            vm.revertToState(snap);
            emit log_named_uint(m == 0 ? "first-time outbid, refund paid: gas (cold)" : "first-time outbid, refund deferred: gas (cold)", used);
            emit log_named_uint("  fresh slots", fresh);
        }
    }
}
