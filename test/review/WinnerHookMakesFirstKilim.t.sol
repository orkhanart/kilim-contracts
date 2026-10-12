// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimBazaar} from "../../src/KilimBazaar.sol";
import {EnglishAuction} from "../../src/auction/EnglishAuction.sol";
import {BazaarBase} from "../bazaar/BazaarBase.sol";

/// @dev A winning contract (a pool, a smart wallet, an EIP-7702 wallet) that claimed its own motifs before
///      the close (claimMotifs has no settled check) and approved the Bazaar. When the 1/1 arrives inside
///      settle(), its hook makes a kilim from them: the auction already reads settled() == true there.
contract FirstKilimWinner is IERC721Receiver {
    KilimAuction public immutable auction;
    KilimBazaar public immutable bazaar;
    uint256[] public list;
    uint256 public kilimId;

    constructor(KilimAuction a, KilimBazaar b) {
        auction = a;
        bazaar = b;
    }

    function bid(uint256 amount) external {
        auction.bid{value: amount}(amount, 0, 0);
    }

    function claimAndApprove(uint256 qty) external {
        uint256 first = auction.unclaimedMotifRanges(address(this))[0].nextId;
        auction.claimMotifs(qty, address(this));
        for (uint256 i; i < qty; ++i) {
            list.push(first + i);
        }
        auction.motifs().setApprovalForAll(address(bazaar), true);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(auction.oneOfOne())) kilimId = bazaar.make(list, address(this));
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice A consequence of PRIZE_GAS = 1,000,000 (12 October 2026), recorded for the artist's decision
///         (AUDIT.md, "PRIZE_GAS raised to 1,000,000"): the winner's hook can now afford KilimBazaar.make()
///         inside whoever's settle() delivers the 1/1, so the winner can take Bazaar token #1, number 1 of
///         its rank, before any other holder can act, on the settler's gas. With 500,000 the same make(10)
///         (about 526,000 gas) ran out of gas and the delivery rolled back whole. No ETH or token is at
///         risk. If the Bazaar is later made to refuse writes during settle(), these tests flip.
contract WinnerHookMakesFirstKilimTest is BazaarBase {
    /// The gas the site sends with settle() (site/chain.js SETTLE_GAS).
    uint256 internal constant SETTLE_GAS = 1_400_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(4_000_000);
        _standard();
        _openBidding(auction);
    }

    /// @dev The winner bids `amount`, claims `qty` motifs before the close, and the treasury sends settle()
    ///      with the site's gas, every account cold as in its own transaction.
    function _settleWithArmedWinner(uint256 amount, uint256 qty) internal returns (FirstKilimWinner w) {
        w = new FirstKilimWinner(auction, bazaar);
        vm.deal(address(w), amount);
        w.bid(amount);
        w.claimAndApprove(qty);
        vm.warp(auction.endsAt());
        vmb.cool(address(auction));
        vmb.cool(address(oneOfOne));
        vmb.cool(address(motifs));
        vmb.cool(address(bazaar));
        vmb.cool(address(w));
        vm.prank(TREASURY);
        (bool ok,) = address(auction).call{gas: SETTLE_GAS}(abi.encodeCall(EnglishAuction.settle, ()));
        assertTrue(ok);
        assertTrue(auction.settled());
    }

    function testTheWinnersHookMakesKilimNumberOneInsideSettle() public {
        // A winning bid of 1 ETH: the Master costs 1,000 motifs, so ten make an Apprentice.
        FirstKilimWinner w = _settleWithArmedWinner(1 ether, 10);
        assertTrue(auction.prizeClaimed());
        assertEq(oneOfOne.ownerOf(1), address(w));
        assertEq(w.kilimId(), 1);
        assertEq(bazaar.ownerOf(1), address(w));
        assertEq(bazaar.kilim(1).number, 1);
        assertEq(bazaar.kilim(1).rank, 1);
        assertTrue(bazaar.kilim(1).flags & bazaar.WINNING_BID() != 0);
        assertEq(motifs.motifsBurned(), 10);
        // Every other holder comes after it.
        assertEq(_make(ALICE, _fresh(ALICE, 10)), 2);
    }

    function testAtTheReserveTheWinnersHookMakesTheFirstMaster() public {
        // A winning bid of 0.01 ETH: the Master costs ten motifs.
        FirstKilimWinner w = _settleWithArmedWinner(RESERVE, 10);
        assertEq(bazaar.kilim(w.kilimId()).rank, bazaar.MASTER());
        assertEq(bazaar.madeAt(bazaar.MASTER()), 1);
    }

    /// @dev The hook's 1,000,000 fits about 23 motifs (measured 12 October 2026), never a Spinner (30): the
    ///      make runs out of gas, the delivery rolls back whole, settlement stands and the winner claims.
    function testTheHookCannotMakeASpinnerInsideSettle() public {
        FirstKilimWinner w = _settleWithArmedWinner(1 ether, 30);
        assertTrue(!auction.prizeClaimed());
        assertEq(bazaar.totalSupply(), 0);
        assertEq(motifs.motifsBurned(), 0);
        assertEq(motifs.balanceOf(address(w)), 30);
    }
}
