// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TestBase} from "../TestBase.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {ProbeWallet} from "../AuditGaps.t.sol";

interface VmP {
    function setNonce(address, uint64) external;
    function store(address, bytes32, bytes32) external;
}

/// @dev A Safe 1.4.1-shaped winner: proxy -> singleton by delegatecall -> fallback handler by call, with
///      the sender appended, exactly as Safe's FallbackManager does. The handler burns `burn` gas first so
///      the shell's cost can be measured through the real delivery. (Safe's own handler burns nothing.)
///      The amount is block.timestamp - base, so a measurement set up in one transaction and run in
///      another touches nothing in the handler beforehand (vm.warp warms no account; vm.store would).
contract SafeShapedHandler {
    uint256 private immutable base;

    constructor(uint256 base_) {
        base = base_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        uint256 b = block.timestamp - base;
        while (start - gasleft() < b) {}
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract SafeShapedSingleton {
    // keccak256("fallback_manager.handler.address"), as in Safe.
    bytes32 private constant HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    address private singleton; // slot 0, the proxy's layout

    function setFallbackHandler(address handler) external {
        bytes32 slot = HANDLER_SLOT;
        assembly ("memory-safe") {
            sstore(slot, handler)
        }
    }

    function execCall(address to, uint256 value, bytes calldata data) external returns (bool ok) {
        (ok,) = to.call{value: value}(data);
    }

    receive() external payable {}

    fallback() external payable {
        bytes32 slot = HANDLER_SLOT;
        assembly {
            let handler := sload(slot)
            if iszero(handler) { return(0, 0) }
            calldatacopy(0, 0, calldatasize())
            mstore(calldatasize(), shl(96, caller()))
            let success := call(gas(), handler, 0, 0, add(calldatasize(), 20), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract SafeShapedProxy {
    address private singleton;

    constructor(address singleton_) {
        singleton = singleton_;
    }

    fallback() external payable {
        assembly {
            let s := and(sload(0), 0xffffffffffffffffffffffffffffffffffffffff)
            if eq(calldataload(0), 0xa619486e00000000000000000000000000000000000000000000000000000000) {
                mstore(0, s)
                return(0, 0x20)
            }
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), s, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @dev A winner whose hook burns a set amount of gas, fixed at construction (no storage read).
contract Burner is IERC721Receiver {
    uint256 private immutable burn;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev The same with the amount taken from the clock: block.timestamp - base, where base is the
///      auction's close. vm.warp sets it without touching the winner, so the winner stays cold.
contract ClockBurner is IERC721Receiver {
    uint256 private immutable base;

    constructor(uint256 base_) {
        base = base_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 start = gasleft();
        uint256 b = block.timestamp - base;
        while (start - gasleft() < b) {}
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A motif recipient that accepts the first `acceptCount` tokens and rejects the rest, or burns or
///      moves every token it is handed from inside the mint callback.
contract PickyReceiver is IERC721Receiver {
    uint8 public constant ACCEPT = 0;
    uint8 public constant BURN = 1;
    uint8 public constant MOVE = 2;
    KilimMotifs private immutable motifs;
    uint256 public acceptCount;
    uint8 public mode;
    uint256 public received;
    address public moveTo;

    constructor(KilimMotifs g) {
        motifs = g;
    }

    function set(uint256 acceptCount_, uint8 mode_, address moveTo_) external {
        acceptCount = acceptCount_;
        mode = mode_;
        moveTo = moveTo_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ++received;
        require(received <= acceptCount, "rejected");
        if (mode == BURN) motifs.burn(id);
        if (mode == MOVE) motifs.transferFrom(address(this), moveTo, id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A winner that hands the 1/1 straight on from inside its receiver hook.
contract PrizeMover is IERC721Receiver {
    KilimOneOfOne private immutable oneOfOne;
    address private immutable to;

    constructor(KilimOneOfOne o, address to_) {
        oneOfOne = o;
        to = to_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        oneOfOne.transferFrom(address(this), to, id);
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Measurements behind the prize-delivery budget review, 10 October 2026. Numbers are logged;
///         the assertions pin what the surrounding comments and tests claim. A probe, kept for the record.
contract PrizeGasBudgetPoC is TestBase {
    VmP private constant vmp = VmP(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant PRIZE_GAS = 500_000;
    uint256 private constant SETTLE_FLOOR = PRIZE_GAS + PRIZE_GAS / 63 + 50_000;
    // EIP-8037 + EIP-8038 as published (both Last Call, deadline 2026-11-01).
    uint256 private constant NEW_SLOT_TODAY = 22_100;
    uint256 private constant NEW_SLOT_AFTER = 97_920 + 2_100 + 10_000;
    uint256 private constant COLD_ACCOUNT_TODAY = 2_600;
    uint256 private constant COLD_ACCOUNT_AFTER = 3_000;
    uint256 private constant EXTCODESIZE_EXTRA = 100;
    uint256 private constant COLD_SLOT = 2_100;

    KilimAuction internal auction;
    KilimMotifs internal nft;
    KilimOneOfOne internal oneOfOne;
    // Set up in their own transaction so that in a test everything below is cold, as on mainnet. Each
    // winner's hook burns block.timestamp - close, so a test picks the amount with vm.warp alone.
    KilimAuction internal auctionBurner;
    ClockBurner internal burner;
    uint256 internal burnerClose;
    KilimAuction internal auctionSafe;
    SafeShapedHandler internal handler;
    address internal safe;
    uint256 internal safeClose;

    event log_named_uint(string key, uint256 value);
    event log_string(string value);

    function setUp() public {
        auction = new KilimAuction(config());
        nft = auction.motifs();
        oneOfOne = auction.oneOfOne();
        _openBidding(auction);
        _fund(ALICE, 100 ether);
        _fund(BOB, 100 ether);

        auctionBurner = new KilimAuction(config());
        _openBidding(auctionBurner);
        // The first bid, placed right below, closes the clock at now + duration.
        burnerClose = block.timestamp + auctionBurner.duration();
        burner = new ClockBurner(burnerClose);
        _fund(address(burner), 1 ether);
        vm.prank(address(burner));
        auctionBurner.bid{value: RESERVE}(RESERVE, 0, 0);
        assertEq(auctionBurner.endsAt(), burnerClose);

        auctionSafe = new KilimAuction(config());
        _openBidding(auctionSafe);
        safeClose = block.timestamp + auctionSafe.duration();
        SafeShapedSingleton singleton = new SafeShapedSingleton();
        handler = new SafeShapedHandler(safeClose);
        safe = address(new SafeShapedProxy(address(singleton)));
        SafeShapedSingleton(payable(safe)).setFallbackHandler(address(handler));
        _fund(safe, 1 ether);
        SafeShapedSingleton(payable(safe))
            .execCall(address(auctionSafe), RESERVE, abi.encodeCall(auctionSafe.bid, (RESERVE, 0, 0)));
        assertEq(auctionSafe.highestBidder(), safe);
        assertEq(auctionSafe.endsAt(), safeClose);
    }

    /// @dev Warm, as the AttackPatterns loop measures: a winner created in this transaction, so its
    ///      account is warm when the 1/1 looks at it. (The 1/1 itself is cold either way here.)
    function _deliveredWarm(uint256 burn) private returns (bool delivered) {
        uint256 snap = vm.snapshotState();
        Burner w = new Burner(burn);
        _fund(address(w), 1 ether);
        vm.prank(address(w));
        auction.bid{value: RESERVE}(RESERVE, 0, 0);
        vm.warp(auction.endsAt());
        auction.settle();
        delivered = auction.prizeClaimed();
        vm.revertToState(snap);
    }

    /// @dev Cold, as a settle() transaction on mainnet: the 1/1, the winner and every slot they read
    ///      were last touched in setUp; only the clock moves, which touches nothing.
    function _deliveredCold(uint256 burn) private returns (bool delivered) {
        return _deliveredColdOn(auctionBurner, burnerClose, burn);
    }

    function _deliveredThroughSafe(uint256 burn) private returns (bool delivered) {
        return _deliveredColdOn(auctionSafe, safeClose, burn);
    }

    function _deliveredColdOn(KilimAuction a, uint256 close, uint256 burn) private returns (bool delivered) {
        uint256 snap = vm.snapshotState();
        vm.warp(close + burn);
        a.settle();
        delivered = a.prizeClaimed();
        vm.revertToState(snap);
    }

    function _maxBurn(function(uint256) returns (bool) probe, uint256 lo, uint256 hi)
        private
        returns (uint256)
    {
        // lo is delivered, hi is not; narrow to one gas.
        assertTrue(probe(lo));
        assertTrue(!probe(hi));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (probe(mid)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    // ---- 1. the hook budget today, warm as the suite measures it and cold as mainnet will ----

    function testHookBudgetWarmAndColdAndTheSafeShell() public {
        // First, that the cold path really is cold: settle() on the burner's auction costs more than
        // the same settle() after a touch of its 1/1 and of the winner, by the two cold accesses.
        uint256 untouched;
        uint256 touched;
        {
            uint256 snap = vm.snapshotState();
            vm.warp(burnerClose + 1_000);
            uint256 g = gasleft();
            auctionBurner.settle();
            untouched = g - gasleft();
            vm.revertToState(snap);
            snap = vm.snapshotState();
            vm.warp(burnerClose + 1_000);
            assertTrue(address(auctionBurner.oneOfOne()).code.length != 0);
            assertTrue(address(burner).code.length != 0);
            g = gasleft();
            auctionBurner.settle();
            touched = g - gasleft();
            vm.revertToState(snap);
        }
        emit log_named_uint("settle() gas, 1/1 and winner cold", untouched);
        emit log_named_uint("settle() gas, 1/1 and winner touched first", touched);
        assertTrue(untouched > touched);
        assertTrue(untouched - touched >= 2 * (COLD_ACCOUNT_TODAY - 100) - 500);

        uint256 warm = _maxBurn(_deliveredWarm, 380_000, 400_000);
        emit log_named_uint("hook budget, winner warm (as the AttackPatterns loop measures)", warm);
        uint256 cold = _maxBurn(_deliveredCold, 370_000, 400_000);
        emit log_named_uint("hook budget, 1/1 and winner cold (as a real settle() transaction)", cold);
        emit log_named_uint("delivery overhead today, cold (PRIZE_GAS - budget)", PRIZE_GAS - cold);
        // AttackPatterns logs 391,406 at 1,000-gas granularity with both warm; AuditGaps pins 389,005
        // for its ProbeWallet in a state like `warm` here. Neither is the mainnet number.
        assertTrue(warm > cold);
        assertTrue(cold < 389_005);

        uint256 viaSafe = _maxBurn(_deliveredThroughSafe, 350_000, 400_000);
        emit log_named_uint("hook budget, through a cold Safe-shaped shell", viaSafe);
        // What the shell takes from the budget: its own work (two cold slots, two cold accounts, the
        // copying) plus the 1/64 held back at each of its two extra call depths (about 6,000 each;
        // returned if the handler finishes, so a real Safe's handler, which burns nothing, never
        // needs them).
        uint256 shell = cold - viaSafe;
        emit log_named_uint("Safe shell cost inside the budget, cold, incl. two 1/64 retentions", shell);
        // A real Safe's handler burns nothing. It is delivered today.
        assertTrue(_deliveredThroughSafe(0));

        // Projection at EIP-8037/8038 prices from the cold number: four new slots in the delivery
        // (prizeClaimed, minted, _owners[1], _balances[winner]) and the cold-access rises the
        // AttackPatterns model leaves out: the auction's call into the 1/1, and the 1/1's EXTCODESIZE
        // of the winner (+400 each, +100 for the second read).
        uint256 overheadAfter = (PRIZE_GAS - cold) + 4 * (NEW_SLOT_AFTER - NEW_SLOT_TODAY) + 2
            * (COLD_ACCOUNT_AFTER - COLD_ACCOUNT_TODAY) + EXTCODESIZE_EXTRA;
        emit log_named_uint("delivery overhead at EIP-8037/8038 prices, cold", overheadAfter);
        uint256 budgetAfter = PRIZE_GAS - overheadAfter;
        emit log_named_uint("hook budget at EIP-8037/8038 prices, cold", budgetAfter);
        // A Safe's need after the fork, as an upper bound: the shell as measured (retentions counted in
        // full, though they shrink with the budget) plus the rise on its two cold accounts.
        uint256 safeNeedAfter = shell + 2 * (COLD_ACCOUNT_AFTER - COLD_ACCOUNT_TODAY);
        emit log_named_uint("a Safe's need at EIP-8037/8038 prices, upper bound", safeNeedAfter);
        assertTrue(safeNeedAfter < budgetAfter);
        emit log_named_uint("margin left for a Safe after the fork", budgetAfter - safeNeedAfter);
        // One new storage slot in a winner's hook (a pool recording the token) after the fork:
        emit log_named_uint("one new slot in the hook after the fork", NEW_SLOT_AFTER);
        assertTrue(NEW_SLOT_AFTER > budgetAfter);
        // The Safe shell's two cold slots are already inside `shell`; COLD_SLOT records their price.
        assertTrue(shell > 2 * COLD_SLOT);
    }

    // ---- 2. the AuditGaps comments: 390,000 not delivered, settle ~17,000, bid ~128,000 ----

    function testSettleFloorIsExactAndTheDeliveryAlwaysGetsFullGas() public {
        // A winner that needs the whole budget: delivered only if the hook really gets PRIZE_GAS less
        // the overhead. If any gas limit settled with a short delivery, this winner would be left to
        // claimPrize while settled, which the loop below would catch. The sweep starts far below the floor,
        // so a floor check that moved or was deleted shows as a short delivery or a bare out-of-gas.
        uint256 warm = _maxBurn(_deliveredWarm, 380_000, 400_000);
        Burner w = new Burner(warm);
        _fund(address(w), 1 ether);
        vm.prank(address(w));
        auction.bid{value: RESERVE}(RESERVE, 0, 0);
        vm.warp(auction.endsAt());
        uint256 lowestOk = type(uint256).max;
        uint256 bareOutOfGas;
        for (uint256 gasLimit = 400_000; gasLimit <= SETTLE_FLOOR + 30_000; gasLimit += 100) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory data) =
                address(auction).call{gas: gasLimit}(abi.encodeCall(auction.settle, ()));
            if (ok) {
                assertTrue(auction.settled());
                assertTrue(auction.prizeClaimed());
                if (gasLimit < lowestOk) lowestOk = gasLimit;
            } else {
                assertTrue(!auction.settled());
                // Below the floor the revert is the auction's own InsufficientGas, not a bare OOG.
                if (data.length >= 4) {
                    assertEq(bytes32(data), bytes32(EnglishAuction.InsufficientGas.selector));
                } else {
                    ++bareOutOfGas;
                }
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("settle floor in the contract (PRIZE_GAS + PRIZE_GAS/63 + 50,000)", SETTLE_FLOOR);
        emit log_named_uint("smallest call gas limit that settles and delivers (100-gas steps)", lowestOk);
        emit log_named_uint(
            "limits that failed with no revert data (bare out-of-gas before the check)", bareOutOfGas
        );
        assertEq(bareOutOfGas, 0);
        assertTrue(lowestOk >= SETTLE_FLOOR && lowestOk < SETTLE_FLOOR + 30_000);
    }

    // ---- 4. a claim that fails in its second id range rolls everything back ----

    function testClaimRollsBackWhenTheSecondRangeIsRejected() public {
        _bid(auction, ALICE, 25 * UNIT); // ids 1-25
        _bid(auction, BOB, 27 * UNIT); // ids 26-52
        _bid(auction, ALICE, 29 * UNIT); // ids 53-81
        PickyReceiver r = new PickyReceiver(nft);
        r.set(25, r.ACCEPT(), address(0)); // takes all of range 1, rejects the first of range 2
        KilimAuction.CreditRange[] memory before = auction.unclaimedMotifRanges(ALICE);
        vm.expectRevert();
        vm.prank(ALICE);
        auction.claimMotifs(30, address(r));
        KilimAuction.CreditRange[] memory after_ = auction.unclaimedMotifRanges(ALICE);
        assertEq(auction.motifCredits(ALICE), 54);
        assertEq(auction.motifsClaimed(), 0);
        assertEq(nft.motifsMinted(), 0);
        assertEq(after_.length, before.length);
        for (uint256 i; i < before.length; ++i) {
            assertEq(after_[i].nextId, before[i].nextId);
            assertEq(after_[i].remaining, before[i].remaining);
        }
        assertEq(r.received(), 0);
        // The same claim to a willing recipient still works, from the same ids.
        vm.prank(ALICE);
        auction.claimMotifs(30, CAROL);
        assertEq(nft.ownerOf(1), CAROL);
        assertEq(nft.ownerOf(57), CAROL);
        assertEq(auction.motifsClaimed(), 30);
        assertEq(nft.motifsMinted(), 30);
    }

    // ---- 5. a recipient that burns or moves each motif from inside the mint callback ----

    function testRecipientBurningOrMovingInsideTheMintCallbackKeepsTheCounters() public {
        _bid(auction, ALICE, 25 * UNIT);
        PickyReceiver burnerR = new PickyReceiver(nft);
        burnerR.set(type(uint256).max, burnerR.BURN(), address(0));
        vm.prank(ALICE);
        auction.claimMotifs(4, address(burnerR));
        assertEq(nft.motifsMinted(), 4);
        assertEq(nft.motifsBurned(), 4);
        assertEq(auction.motifsClaimed(), 4);
        assertEq(auction.motifCredits(ALICE), 21);
        for (uint256 id = 1; id <= 4; ++id) {
            assertTrue(nft.burned(id));
            vm.expectRevert();
            nft.ownerOf(id);
        }
        assertEq(nft.balanceOf(address(burnerR)), 0);

        PickyReceiver mover = new PickyReceiver(nft);
        mover.set(type(uint256).max, mover.MOVE(), CAROL);
        vm.prank(ALICE);
        auction.claimMotifs(4, address(mover));
        for (uint256 id = 5; id <= 8; ++id) {
            assertEq(nft.ownerOf(id), CAROL);
        }
        assertEq(nft.motifsMinted(), 8);
        assertEq(auction.motifsClaimed(), 8);
        // Burned ids are never handed out again: the next claim continues at 9.
        vm.prank(ALICE);
        auction.claimMotifs(1, CAROL);
        assertEq(nft.ownerOf(9), CAROL);
    }

    // ---- 6. the winner's hook moving the 1/1 away at once leaves every flag consistent ----

    function testWinnerMovingThePrizeInsideTheHookIsConsistent() public {
        PrizeMover w = new PrizeMover(oneOfOne, CAROL);
        _fund(address(w), 1 ether);
        vm.prank(address(w));
        auction.bid{value: RESERVE}(RESERVE, 0, 0);
        vm.warp(auction.endsAt());
        auction.settle();
        assertTrue(auction.settled());
        assertTrue(auction.prizeClaimed());
        assertTrue(oneOfOne.minted());
        assertEq(oneOfOne.ownerOf(1), CAROL);
        vm.expectRevert(KilimAuction.PrizeAlreadyClaimed.selector);
        vm.prank(address(w));
        auction.claimPrize(address(w));
    }

    // ---- 7. the nonce slip at deployment ----

    function testNonceSlipLeavesTokensWithoutAMinterAndTheAuctionRefuses() public {
        // (a) A plain transaction from the deployer uses nonce n+2: the auction lands at n+3 and refuses;
        //     the tokens name an address that can never get code by CREATE from this deployer.
        KilimAuction.Config memory c = config();
        vmp.setNonce(address(this), uint64(vm.getNonce(address(this)) + 1));
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        address minter = KilimMotifs(c.motifs).minter();
        assertEq(minter.code.length, 0);
        vm.expectRevert(KilimMotifs.Unauthorized.selector);
        KilimMotifs(c.motifs).mintMotifs(ALICE, ALICE, 1, 1);
        vm.expectRevert(KilimOneOfOne.Unauthorized.selector);
        KilimOneOfOne(c.oneOfOne).mint(ALICE);
        emit log_string("(a) tokens built for a slipped nonce can never mint; both must be redeployed, the chunks survive");

        // (b) The deployer creates some other contract of its own at n+2 (here a Safe-shaped executor):
        //     that contract is the tokens' minter, and whoever controls it can mint without the auction.
        c = config();
        SafeShapedSingleton executor = new SafeShapedSingleton();
        assertEq(KilimMotifs(c.motifs).minter(), address(executor));
        vm.expectRevert(EnglishAuction.InvalidConfiguration.selector);
        new KilimAuction(c);
        assertTrue(
            executor.execCall(
                c.motifs, 0, abi.encodeCall(KilimMotifs(c.motifs).mintMotifs, (ALICE, ALICE, 1, 1))
            )
        );
        assertEq(KilimMotifs(c.motifs).ownerOf(1), ALICE);
        assertTrue(executor.execCall(c.oneOfOne, 0, abi.encodeCall(KilimOneOfOne(c.oneOfOne).mint, (BOB))));
        assertEq(KilimOneOfOne(c.oneOfOne).ownerOf(1), BOB);
        emit log_string("(b) a deployer contract at n+2 becomes the minter of both tokens; nothing on-chain can tell");
    }
}
