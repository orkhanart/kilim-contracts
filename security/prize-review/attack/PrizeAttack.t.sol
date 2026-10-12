// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";
import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {BazaarBase} from "../../../test/bazaar/BazaarBase.sol";
import {KilimAuction500} from "./KilimAuction500.sol";

/// @dev A winning contract (a pool, a smart wallet) that claimed its own motifs before settlement and, when
///      the 1/1 arrives inside settle(), makes a kilim in Kilim Bazaar from them. Whoever sent settle()
///      pays for it.
contract FirstKilimWinner is IERC721Receiver {
    KilimAuction public immutable auction;
    KilimBazaar public immutable bazaar;
    uint256[] public list;
    bool public armed;
    bool public madeInside;
    uint256 public kilimId;
    uint256 public gasAtHook;
    uint256 public makeGas;

    constructor(KilimAuction a, KilimBazaar b) {
        auction = a;
        bazaar = b;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    /// @dev Before settlement: claim `qty` reserved motifs to itself and approve the Bazaar.
    function claimAndArm(uint256 qty) external {
        KilimAuction.CreditRange[] memory r = auction.unclaimedMotifRanges(address(this));
        uint256 first = r[0].nextId;
        auction.claimMotifs(qty, address(this));
        for (uint256 i; i < qty; ++i) {
            list.push(first + i);
        }
        auction.motifs().setApprovalForAll(address(bazaar), true);
        armed = true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (armed && msg.sender == address(auction.oneOfOne())) {
            uint256 g = gasleft();
            gasAtHook = g;
            kilimId = bazaar.make(list, address(this));
            madeInside = true;
            makeGas = g - gasleft();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A winner whose NFT hook burns every gas unit it is given (the delivery fails out of gas).
contract BurnAllWinner is IERC721Receiver {
    KilimAuction public immutable auction;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender == address(auction.oneOfOne())) {
            while (true) {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A winner whose hook burns everything but what it needs to accept: the delivery succeeds.
contract EdgeWinner is IERC721Receiver {
    KilimAuction public immutable auction;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender == address(auction.oneOfOne())) {
            while (gasleft() > 1_500) {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Records the gas its hook is given.
contract GasProbeWinner is IERC721Receiver {
    KilimAuction public immutable auction;
    uint256 public seen;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(auction.oneOfOne())) seen = gasleft();
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A winner whose hook reverts with `size` bytes of revert data (0 = accept), and that tries every
///      auction write first. Counts the re-entries that went through.
contract BombWinner is IERC721Receiver {
    KilimAuction public immutable auction;
    uint256 public size;
    uint256 public reentered;

    constructor(KilimAuction a) {
        auction = a;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function setSize(uint256 s) external {
        size = s;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(auction.oneOfOne())) return IERC721Receiver.onERC721Received.selector;
        bytes[8] memory calls = [
            abi.encodeCall(KilimAuction.claimPrize, (address(this))),
            abi.encodeCall(KilimAuction.claimMotifs, (1, address(this))),
            abi.encodeCall(KilimAuction.deliverPrize, ()),
            abi.encodeCall(EnglishAuction.settle, ()),
            abi.encodeCall(EnglishAuction.withdrawRefund, (address(this))),
            abi.encodeCall(EnglishAuction.withdrawProceeds, (address(this))),
            abi.encodeCall(KilimAuction.bid, (1 ether, 0, 0)),
            abi.encodeCall(EnglishAuction.payOutbidRefund, (address(this), 1))
        ];
        uint256 n;
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(auction).call(calls[i]);
            if (ok) ++n;
        }
        reentered = n;
        uint256 s = size;
        if (s != 0) {
            assembly ("memory-safe") {
                revert(0, s)
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice The attacker's lens on PRIZE_GAS = 1,000,000: what a hostile winner can now do inside settle().
///         Each comparison runs the same attack against a copy of the auction with the old 500,000.
contract PrizeAttackTest is BazaarBase {
    uint256 internal constant SETTLE_GAS = 1_400_000;
    /// settle()'s calldata is a 4-byte selector, all nonzero: 21,000 + 4 x 16.
    uint256 internal constant INTRINSIC = 21_064;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(4_000_000);
    }

    /// @dev The fixture of BazaarBase._standard(), with the auction at PRIZE_GAS 1,000,000 (the real
    ///      contract) or at 500,000 (the copy).
    function _deploy(bool old) internal {
        pageDir = FIXTURE_PAGE;
        pageHead = _pageFile("head.bin");
        KilimOneOfOne.Page memory page = pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin"));
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        address[] memory gridChunks = chunked(grids, 767 * 32);
        address namesChunk = sstore2(names);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        motifs = new KilimMotifs(
            next,
            TREASURY,
            BIG_CAP,
            gridChunks,
            keccak256(grids),
            namesChunk,
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
        oneOfOne = new KilimOneOfOne(next, TREASURY, motifs, page, ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL);
        motifChain = motifs.deploymentChainId();
        uint64 startsAt = uint64(block.timestamp + 1 hours);
        if (old) {
            KilimAuction500.Config memory c = KilimAuction500.Config({
                treasury: TREASURY,
                motifs: address(motifs),
                oneOfOne: address(oneOfOne),
                startsAt: startsAt,
                duration: 22 hours,
                extensionWindow: 10 minutes,
                incrementBps: 500,
                reservePrice: RESERVE,
                maxMotifsPerBid: BIG_CAP
            });
            auction = KilimAuction(address(new KilimAuction500(c)));
        } else {
            KilimAuction.Config memory c = KilimAuction.Config({
                treasury: TREASURY,
                motifs: address(motifs),
                oneOfOne: address(oneOfOne),
                startsAt: startsAt,
                duration: 22 hours,
                extensionWindow: 10 minutes,
                incrementBps: 500,
                reservePrice: RESERVE,
                maxMotifsPerBid: BIG_CAP
            });
            auction = new KilimAuction(c);
        }
        require(address(auction) == next, "auction address");
        _deployBazaar();
        _openBidding(auction);
    }

    function _coolAll(address winner) internal {
        vmb.cool(address(auction));
        vmb.cool(address(oneOfOne));
        vmb.cool(address(motifs));
        vmb.cool(address(bazaar));
        vmb.cool(winner);
        vmb.cool(TREASURY);
    }

    /// @dev settle() sent by the treasury with `gas`, everything cold as in its own transaction. Returns
    ///      whether it succeeded and the gas it used as a transaction (execution + intrinsic, no refund).
    function _settleAs(uint256 gas, address winner) internal returns (bool ok, uint256 txGas) {
        _coolAll(winner);
        vm.prank(TREASURY);
        uint256 g = gasleft();
        (ok,) = address(auction).call{gas: gas}(abi.encodeCall(EnglishAuction.settle, ()));
        txGas = g - gasleft() + INTRINSIC;
    }

    // ------------------------------------------------------------ 1. Kilim Bazaar from inside settle()

    /// @dev The winner's hook makes a kilim inside the settle() someone else sent: it takes Bazaar token #1
    ///      (number 1 of its rank) before any other holder can act, with the settler paying. With
    ///      PRIZE_GAS 500,000 the same hook cannot afford it.
    function _firstKilim(bool old, uint256 winningBid, uint256 qty)
        internal
        returns (bool made, uint256 txGas, FirstKilimWinner w)
    {
        _deploy(old);
        w = new FirstKilimWinner(auction, bazaar);
        vm.deal(address(w), winningBid);
        w.bid(winningBid);
        w.claimAndArm(qty);
        vm.warp(auction.endsAt());
        bool ok;
        (ok, txGas) = _settleAs(SETTLE_GAS, address(w));
        assertTrue(ok);
        assertTrue(auction.settled());
        made = bazaar.totalSupply() != 0;
    }

    function testWinnerMakesKilimNumberOneInsideSomeoneElsesSettle() public {
        // A winning bid of 1 ETH: the Master costs 1,000, so 10 motifs make an Apprentice.
        (bool made, uint256 txGas, FirstKilimWinner w) = _firstKilim(false, 1 ether, 10);
        assertTrue(made);
        assertTrue(w.madeInside());
        assertEq(w.kilimId(), 1);
        assertEq(bazaar.ownerOf(1), address(w));
        assertEq(bazaar.kilim(1).number, 1);
        assertEq(bazaar.kilim(1).rank, 1);
        // The winning bid's own motifs: the kilim carries the WINNING_BID flag too.
        assertTrue(bazaar.kilim(1).flags & bazaar.WINNING_BID() != 0);
        // The 1/1 was delivered as well, in the same call.
        assertTrue(auction.prizeClaimed());
        assertEq(oneOfOne.ownerOf(1), address(w));
        assertEq(motifs.motifsBurned(), 10);
        _log(string.concat("hook gas at entry: ", vm.toString(w.gasAtHook())));
        _log(string.concat("make(10) inside the hook: ", vm.toString(w.makeGas())));
        _log(string.concat("settle() as a transaction, paid by the treasury: ", vm.toString(txGas)));
        // The treasury paid for the winner's kilim: an EOA winner's settlement is about 130,000.
        assertTrue(txGas > 550_000);
        assertTrue(w.makeGas() > 387_122); // the old cold hook budget (AUDIT.md, PrizeGasBudget)

        // Every other holder comes after: the first kilim anyone else can make is token 2.
        uint256[] memory alices = _fresh(ALICE, 10);
        assertEq(_make(ALICE, alices), 2);
    }

    function testTheSameHookCannotMakeAKilimWithTheOld500k() public {
        (bool made, uint256 txGas, FirstKilimWinner w) = _firstKilim(true, 1 ether, 10);
        assertTrue(!made);
        assertTrue(!w.madeInside());
        // The make ran out of gas inside the hook, so the delivery failed and was rolled back whole.
        assertTrue(!auction.prizeClaimed());
        assertEq(motifs.motifsBurned(), 0);
        _log(string.concat("old 500k: settle() as a transaction: ", vm.toString(txGas)));
    }

    /// @dev With a winning bid at the reserve (0.01 ETH) the Master costs 10 motifs: the winner's hook makes
    ///      the first Master inside settle().
    function testWinnerAtTheReserveMakesTheFirstMasterInsideSettle() public {
        (bool made,, FirstKilimWinner w) = _firstKilim(false, RESERVE, 10);
        assertTrue(made);
        assertEq(bazaar.kilim(w.kilimId()).rank, bazaar.MASTER());
        assertEq(bazaar.kilim(w.kilimId()).number, 1);
        assertEq(bazaar.madeAt(bazaar.MASTER()), 1);
    }

    /// @dev How many motifs the hook can put into one kilim inside settle() (cold, consecutive ids).
    function testLargestKilimTheHookCanMakeInsideSettle() public {
        uint256 lo = 10;
        uint256 hi = 40;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vmb.snapshotState();
            (bool made,,) = _firstKilim(false, 1 ether, mid);
            vmb.revertToState(snap);
            if (made) lo = mid;
            else hi = mid;
        }
        _log(string.concat("largest kilim made inside settle(): ", vm.toString(lo), " motifs"));
        assertTrue(lo >= 10);
    }

    // ------------------------------------------------------------ 2. the settler's bill

    /// @dev What a winner that burns all its gas costs whoever settles, against an EOA winner, before and
    ///      after the raise.
    function testWhatAHostileWinnerCostsTheSettler() public {
        uint256[2][2] memory costs;
        for (uint256 old; old < 2; ++old) {
            for (uint256 hostile; hostile < 2; ++hostile) {
                uint256 snap = vmb.snapshotState();
                _deploy(old == 1);
                address winner;
                if (hostile == 1) {
                    BurnAllWinner b = new BurnAllWinner(auction);
                    vm.deal(address(b), RESERVE);
                    b.bid(RESERVE);
                    winner = address(b);
                } else {
                    vm.deal(ALICE, RESERVE);
                    _bid(auction, ALICE, RESERVE);
                    winner = ALICE;
                }
                vm.warp(auction.endsAt());
                (bool ok, uint256 txGas) = _settleAs(SETTLE_GAS, winner);
                assertTrue(ok);
                assertTrue(auction.settled());
                assertTrue(auction.prizeClaimed() == (hostile == 0));
                costs[old][hostile] = txGas;
                vmb.revertToState(snap);
            }
        }
        _log(
            string.concat(
                "1,000,000: EOA winner ", vm.toString(costs[0][0]), ", burn-all ", vm.toString(costs[0][1])
            )
        );
        _log(
            string.concat(
                "  500,000: EOA winner ", vm.toString(costs[1][0]), ", burn-all ", vm.toString(costs[1][1])
            )
        );
        // The bill a burn-all winner hands the settler grew by about 485,000 (the unused 1/64 shares of
        // the inner frames come back, so not the full 500,000).
        assertTrue(costs[0][1] - costs[1][1] > 480_000 && costs[0][1] - costs[1][1] < 500_000);
        // The EOA case is the same either way.
        assertTrue(costs[0][0] == costs[1][0]);
        // AUDIT.md says "up to about 1,030,000 gas": as a transaction, intrinsic gas included, it is that.
        assertTrue(costs[0][1] > 1_020_000 && costs[0][1] < 1_040_000);
    }

    /// @dev A hook that burns all but the last 1,500 gas and accepts: the delivery succeeds, and this is
    ///      about the most a winner can bill the settler.
    function testAnEdgeBurningHookThatAcceptsCostsTheSettlerTheSame() public {
        _deploy(false);
        EdgeWinner e = new EdgeWinner(auction);
        vm.deal(address(e), RESERVE);
        e.bid(RESERVE);
        vm.warp(auction.endsAt());
        (bool ok, uint256 txGas) = _settleAs(SETTLE_GAS, address(e));
        assertTrue(ok);
        assertTrue(auction.prizeClaimed());
        assertEq(oneOfOne.ownerOf(1), address(e));
        _log(string.concat("edge-burning hook that accepts: settle() as a transaction ", vm.toString(txGas)));
        assertTrue(txGas < 1_040_000);
    }

    /// @dev The documented minimum (1,102,637 on the call) was measured with settle()'s endsAt slot warm
    ///      (the measurement read endsAt() just before). Cold, as a real transaction meets it, settle()
    ///      needs 2,000 more: 1,104,637 on the call, about 1,125,701 as a transaction.
    function testTheDocumentedSettleMinimumIsShortWhenCold() public {
        _deploy(false);
        vm.deal(ALICE, RESERVE);
        _bid(auction, ALICE, RESERVE);
        vm.warp(auction.endsAt());
        uint256 snap = vmb.snapshotState();
        _coolAll(ALICE);
        (bool ok, bytes memory data) =
            address(auction).call{gas: 1_102_637}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(!ok);
        assertEq(bytes32(bytes4(data)), bytes32(EnglishAuction.InsufficientGas.selector));
        vmb.revertToState(snap);
        _coolAll(ALICE);
        (ok,) = address(auction).call{gas: 1_104_637 - 1}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(!ok);
        vmb.revertToState(snap);
        _coolAll(ALICE);
        (ok,) = address(auction).call{gas: 1_104_637}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok && auction.prizeClaimed());
        vmb.revertToState(snap);
        // With only the endsAt slot warmed (what the 12 October measurement did), 1,102,637 is enough.
        _coolAll(ALICE);
        auction.endsAt();
        (ok,) = address(auction).call{gas: 1_102_637}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok && auction.prizeClaimed());
    }

    /// @dev ETH-4 on today's EVM: gas above the 16,777,216 cap does not reach the hook; it sees the same
    ///      allowance at 1,400,000 and at 30,000,000. (EIP-8037's reservoir cannot be run in forge.)
    function testExtraGasDoesNotReachTheHookOnTodaysEvm() public {
        _deploy(false);
        GasProbeWinner p = new GasProbeWinner(auction);
        vm.deal(address(p), RESERVE);
        p.bid(RESERVE);
        vm.warp(auction.endsAt());
        uint256 snap = vmb.snapshotState();
        (bool ok,) = _settleAs(SETTLE_GAS, address(p));
        assertTrue(ok);
        uint256 atSiteLimit = p.seen();
        vmb.revertToState(snap);
        (ok,) = _settleAs(30_000_000, address(p));
        assertTrue(ok);
        assertEq(p.seen(), atSiteLimit);
        _log(string.concat("gas the hook is given (both limits): ", vm.toString(atSiteLimit)));
    }

    // ------------------------------------------------------------ 3. what settle() needs is the winner's choice?

    /// @dev The least gas on settle() that works, by binary search. The winner's hook must not move it.
    function _minSettleGas(address winner) internal returns (uint256) {
        uint256 lo = 1_000_000;
        uint256 hi = 1_200_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vmb.snapshotState();
            vmb.cool(address(auction));
            vmb.cool(address(oneOfOne));
            vmb.cool(winner);
            (bool ok,) = address(auction).call{gas: mid}(abi.encodeCall(EnglishAuction.settle, ()));
            ok = ok && auction.settled();
            vmb.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function testNoWinnerShapeRaisesTheGasSettleNeeds() public {
        uint256[4] memory need;
        // 0: an EOA; 1: re-enters every auction write and then reverts with 357,000 bytes; 2: the same
        // with 900,000 bytes (cannot be built: out of gas); 3: burns everything.
        for (uint256 k; k < 4; ++k) {
            uint256 snap = vmb.snapshotState();
            _deploy(false);
            address winner;
            if (k == 0) {
                vm.deal(ALICE, RESERVE);
                _bid(auction, ALICE, RESERVE);
                winner = ALICE;
            } else if (k < 3) {
                BombWinner b = new BombWinner(auction);
                vm.deal(address(b), RESERVE);
                b.bid(RESERVE);
                b.setSize(k == 1 ? 357_000 : 900_000);
                winner = address(b);
            } else {
                BurnAllWinner b = new BurnAllWinner(auction);
                vm.deal(address(b), RESERVE);
                b.bid(RESERVE);
                winner = address(b);
            }
            vm.warp(auction.endsAt());
            need[k] = _minSettleGas(winner);
            // At exactly that limit it settles, the proceeds are withdrawable, and nothing re-entered.
            vmb.cool(address(auction));
            vmb.cool(address(oneOfOne));
            vmb.cool(winner);
            uint256 g = gasleft();
            (bool ok,) = address(auction).call{gas: need[k]}(abi.encodeCall(EnglishAuction.settle, ()));
            uint256 used = g - gasleft();
            assertTrue(ok);
            assertTrue(auction.settled());
            assertTrue(auction.prizeClaimed() == (k == 0));
            if (k == 1 || k == 2) assertEq(BombWinner(payable(winner)).reentered(), 0);
            // Within the 1,000,000 cap plus settlement's own work: the revert data is never copied.
            assertTrue(used < 1_000_000 + 45_000);
            vm.prank(TREASURY);
            auction.withdrawProceeds(TREASURY);
            vmb.revertToState(snap);
            _log(string.concat("least settle() gas, shape ", vm.toString(k), ": ", vm.toString(need[k])));
        }
        assertEq(need[1], need[0]);
        assertEq(need[2], need[0]);
        assertEq(need[3], need[0]);
    }

    /// @dev The hook re-entering every auction write gets nothing even while delivery succeeds.
    function testReentryFromTheHookGetsNothing() public {
        _deploy(false);
        BombWinner b = new BombWinner(auction);
        vm.deal(address(b), RESERVE);
        b.bid(RESERVE);
        vm.warp(auction.endsAt());
        (bool ok,) = _settleAs(SETTLE_GAS, address(b));
        assertTrue(ok);
        assertTrue(auction.prizeClaimed());
        assertEq(oneOfOne.ownerOf(1), address(b));
        assertEq(b.reentered(), 0);
        assertEq(auction.proceedsDue(), RESERVE);
        assertEq(address(auction).balance, RESERVE);
    }
}
