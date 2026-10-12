// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {HalmosBase, Rejecter, Reenterer} from "./HalmosBase.sol";

/// @notice Halmos stateful invariants over the real, freshly deployed KilimAuction (no assumed state):
///         every sequence of up to --invariant-depth symbolic calls (withdrawRefund, settle, withdrawProceeds,
///         claimPrize, payOutbidRefund, deliverPrize, register; through handlers: bid, which really pays,
///         and claimMotifs of 1, 2 or 15; and a time step of up to 2 days) from five senders (two EOAs, an ETH-rejecting contract, a re-entering
///         contract, the treasury), with symbolic arguments and msg.value.
abstract contract AuctionInvariantBase is HalmosBase {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    KilimMotifs internal motifs;
    KilimOneOfOne internal oneOfOne;
    KilimAuction internal auction;
    Rejecter internal rejecter;
    Reenterer internal reenterer;
    address[] internal _senders;

    function _deploy() internal {
        // A small pool (cap 40, 15 per bid) so the cap binds inside short sequences.
        (motifs, oneOfOne, auction) = deployTrio(40, 15, 1000, 1 days, 10 minutes);
        openBidding(auction);
        rejecter = new Rejecter();
        reenterer = new Reenterer();
        reenterer.setAuction(auction);
        _senders.push(A);
        _senders.push(B);
        _senders.push(address(rejecter));
        _senders.push(address(reenterer));
        _senders.push(TREASURY);
        for (uint256 i; i < _senders.length; ++i) {
            vm.deal(_senders[i], 1e24);
        }
    }

    /// @dev The time step: a handler on this contract, targeted below.
    function warp(uint256 dt) external {
        vm.assume(dt <= 2 days);
        vm.warp(block.timestamp + dt);
    }

    /// @dev A bid by the calling sender, paying exactly `amount` (any amount). Not targeted directly: Halmos
    ///      0.3.3 sets msg.value on a direct invariant call but never moves the ETH (its run_message does no
    ///      value transfer), so the auction would record bids it was never paid for. A first run that
    ///      targeted `bid` directly "broke" solvency at depth 1 for exactly that reason. Here the bid is an
    ///      inner CALL with value, which Halmos does transfer, from the pranked sender's balance.
    function bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstMotifId) external {
        vm.prank(msg.sender);
        auction.bid{value: amount}(amount, minimumReward, expectedFirstMotifId);
    }

    /// @dev claimMotifs by the calling sender, to itself, of 1, 2 or 15 motifs. Not targeted directly: the
    ///      auction allocates arrays of length `quantity` and Halmos cannot copy a symbolic number of bytes,
    ///      so the quantity is split into concrete paths here.
    function claim(uint256 q) external {
        uint256[3] memory options = [uint256(1), 2, 15];
        for (uint256 i; i < 3; ++i) {
            if (q == options[i]) {
                vm.prank(msg.sender);
                auction.claimMotifs(options[i], msg.sender);
                return;
            }
        }
        vm.assume(false);
    }

    // ------------------------------------------------------------ targets

    function targetSenders() public view returns (address[] memory) {
        return _senders;
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(auction);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory s) {
        s = new FuzzSelector[](2);
        // Non-payable: a direct call with msg.value != 0 reverts, so the missing value transfer cannot matter.
        bytes4[] memory a = new bytes4[](7);
        a[0] = auction.withdrawRefund.selector;
        a[1] = auction.settle.selector;
        a[2] = auction.withdrawProceeds.selector;
        a[3] = auction.claimPrize.selector;
        a[4] = auction.payOutbidRefund.selector;
        a[5] = auction.deliverPrize.selector;
        a[6] = auction.register.selector;
        s[0] = FuzzSelector(address(auction), a);
        bytes4[] memory w = new bytes4[](3);
        w[0] = this.warp.selector;
        w[1] = this.claim.selector;
        w[2] = this.bid.selector;
        s[1] = FuzzSelector(address(this), w);
    }

    function excludeSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeContracts() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    // ------------------------------------------------------------ the invariants

    function invariant_solvent() public view {
        assert(address(auction).balance >= auction.liabilities());
    }

    function invariant_shape() public view {
        uint256 hb = auction.highestBid();
        address bidder = auction.highestBidder();
        bool settled = auction.settled();
        uint256 pd = auction.proceedsDue();
        uint64 endsAt = auction.endsAt();
        // Branch-free (HalmosBase helpers): `&&`, `?:` and `if` would fork every explored state.
        bool started = bidder != address(0);
        bool shape = (hb == 0) == !started;
        shape = _and(shape, _imp(started, _and(_and(hb % UNIT == 0, hb >= RESERVE), hb <= type(uint128).max)));
        shape = _and(shape, _and(bidder != TREASURY, bidder != address(auction)));
        shape = _and(shape, (endsAt != 0) == started);
        shape = _and(shape, _imp(settled, _and(started, block.timestamp >= endsAt)));
        shape = _and(shape, _imp(settled, _or(pd == hb, pd == 0)));
        shape = _and(shape, _imp(!settled, pd == 0));
        assert(shape);
    }

    function invariant_refundsAddUp() public view {
        uint256 sum;
        for (uint256 i; i < _senders.length; ++i) {
            sum += auction.refunds(_senders[i]);
        }
        assert(sum == auction.refundLiability());
    }

    function invariant_supply() public view {
        uint256 allocated = auction.motifsAllocated();
        uint256 claimed = auction.motifsClaimed();
        assert(allocated <= auction.motifCap());
        assert(claimed <= allocated);
        assert(motifs.motifsMinted() == claimed);
        uint256 credits;
        for (uint256 i; i < _senders.length; ++i) {
            credits += auction.motifCredits(_senders[i]);
        }
        assert(credits + claimed == allocated);
        (uint256 first, uint256 count) = auction.highestBidMotifs();
        // Both are uint128 slots, so the unchecked sum cannot wrap.
        bool someIds = _and(first >= 1, _usub(_uadd(first, count), 1) <= allocated);
        assert(_and(_imp(count != 0, someIds), _imp(count == 0, first == 0)));
    }

    function invariant_prize() public view {
        bool claimed = auction.prizeClaimed();
        assert(claimed == oneOfOne.minted());
        if (claimed) assert(auction.settled());
    }
}

/// @dev From registration complete, no bid yet.
contract AuctionInvariantFreshHalmos is AuctionInvariantBase {
    function setUp() public {
        _deploy();
    }
}

/// @dev From a running auction whose leader is the ETH-rejecting contract (so the next outbid defers its
///      refund), 30 seconds before the close.
contract AuctionInvariantStartedHalmos is AuctionInvariantBase {
    function setUp() public {
        _deploy();
        vm.prank(address(rejecter));
        auction.bid{value: RESERVE}(RESERVE, 0, 0);
        vm.warp(auction.endsAt() - 30);
    }
}
