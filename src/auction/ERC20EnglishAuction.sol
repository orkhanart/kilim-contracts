// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A single immutable ERC-20 auction with independently withdrawable refunds and proceeds.
/// @dev The clock starts at the FIRST accepted bid, not at a fixed time: `startsAt` only opens
///      bidding. Late bids extend the close without any absolute limit, so the auction ends only
///      after `extensionWindow` passes with no new bid. With no bids it never ends and never settles.
/// @dev Adapted from thirdweb's EnglishAuctionsLogic, commit 46e69070978c23b9533edb381e838a5dddf7ed9d.
///      Original author: thirdweb. Modified for Kilim; see REUSE.md and vendor/thirdweb/NOTICE.
///      Only _isNewWinningBid is retained unchanged (apart from formatting). The escrow, scheduling,
///      storage, settlement and integration changes are NOT covered by the upstream audit.
abstract contract ERC20EnglishAuction is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 private constant MAX_BPS = 10_000;
    /// @dev Gas forwarded to an automatic refund. A plain stablecoin transfer plus the balance checks
    ///      uses well under this; the cap stops a hostile token path from eating the bidder's gas.
    uint256 private constant REFUND_GAS = 150_000;

    struct AuctionConfig {
        address paymentToken;
        address treasury;
        uint64 startsAt;
        uint64 duration;
        uint64 extensionWindow;
        uint16 incrementBps;
        uint256 reservePrice;
    }

    IERC20 public immutable paymentToken;
    address public immutable treasury;
    uint256 public immutable tokenUnit;
    uint256 public immutable reservePrice;
    uint64 public immutable startsAt;
    uint64 public immutable duration;
    uint64 public immutable extensionWindow;
    uint16 public immutable incrementBps;
    uint64 public endsAt;
    uint256 public highestBid;
    address public highestBidder;
    bool public settled;
    uint256 public proceedsDue;
    uint256 public refundLiability;
    mapping(address => uint256) public refunds;

    error InvalidConfiguration();
    error InvalidRecipient();
    error AuctionNotOpen();
    error AuctionNotEnded();
    error NoBids();
    error AlreadySettled();
    error NotSettled();
    error BidTooLow(uint256 minimum);
    error NonWholeUnitBid();
    error Unauthorized();
    error NothingToWithdraw();
    error UnsupportedTokenBehavior();
    error TreasuryCannotBid();

    event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amount);
    /// @notice The outbid amount went straight back to the outbid bidder.
    event RefundPaid(address indexed bidder, uint256 amount);
    /// @notice The automatic refund failed (for example a blacklisted address); it waits in `refunds`.
    event RefundDeferred(address indexed bidder, uint256 amount);
    event AuctionStarted(address indexed firstBidder, uint64 endsAt);
    event AuctionSettled(address indexed winner, uint256 amount);
    event ProceedsWithdrawn(address indexed recipient, uint256 amount);

    constructor(AuctionConfig memory config) {
        if (
            config.paymentToken.code.length == 0 || config.treasury == address(0)
                || config.treasury == address(this) || config.startsAt <= block.timestamp
                || config.duration == 0 || config.duration > 30 days || config.extensionWindow == 0
                || config.extensionWindow > config.duration || config.incrementBps == 0
                || config.incrementBps > MAX_BPS
        ) revert InvalidConfiguration();
        uint8 decimals = IERC20Metadata(config.paymentToken).decimals();
        if (decimals > 18) revert InvalidConfiguration();
        uint256 unit = 10 ** uint256(decimals);
        if (
            config.reservePrice == 0 || config.reservePrice % unit != 0
                || config.reservePrice > type(uint128).max
        ) revert InvalidConfiguration();
        tokenUnit = unit;
        paymentToken = IERC20(config.paymentToken);
        treasury = config.treasury;
        startsAt = config.startsAt;
        duration = config.duration;
        extensionWindow = config.extensionWindow;
        incrementBps = config.incrementBps;
        reservePrice = config.reservePrice;
    }

    function minimumBid() public view returns (uint256) {
        if (highestBid == 0) return reservePrice;
        uint256 increment = Math.mulDiv(highestBid, incrementBps, MAX_BPS, Math.Rounding.Ceil);
        uint256 next = highestBid + increment;
        return Math.ceilDiv(next, tokenUnit) * tokenUnit;
    }

    /// @notice Only a refund the automatic payment could not make waits here to be withdrawn.
    function withdrawRefund(address to) external nonReentrant {
        _validateRecipient(to);
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;
        refundLiability -= amount;
        _pay(to, amount);
        emit RefundWithdrawn(msg.sender, to, amount);
    }

    /// @notice Settlement records the outcome without calling the winner or transferring assets.
    /// @dev Impossible until a first bid starts the clock; with no bids there is nothing to settle.
    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (highestBidder == address(0)) revert NoBids();
        if (block.timestamp < endsAt) revert AuctionNotEnded();
        settled = true;
        proceedsDue = highestBid;
        emit AuctionSettled(highestBidder, highestBid);
    }

    function withdrawProceeds(address to) external nonReentrant {
        if (msg.sender != treasury) revert Unauthorized();
        if (!settled) revert NotSettled();
        _validateRecipient(to);
        uint256 amount = proceedsDue;
        if (amount == 0) revert NothingToWithdraw();
        proceedsDue = 0;
        _pay(to, amount);
        emit ProceedsWithdrawn(to, amount);
    }

    /// @notice Minimum stablecoin balance needed to pay every current obligation.
    function liabilities() external view returns (uint256) {
        return refundLiability + (settled ? proceedsDue : highestBid);
    }

    /// @dev Adaptation of thirdweb _handleBid's ascending-bid branch. Called only inside Kilim's
    ///      nonReentrant bid entry point, which allocates rewards and MUST call _collectBid and then
    ///      _refundOutbid(previous bidder, previous bid) atomically. Returns the outbid bid, if any.
    ///      The seller's treasury cannot bid. Other wallets it controls are not detectable.
    ///      The first accepted bid starts the clock; later bids inside the window extend it, forever.
    function _handleBid(uint256 amount) internal returns (address outbid, uint256 outbidAmount) {
        if (msg.sender == treasury) revert TreasuryCannotBid();
        // No highest bidder means the clock has not started, so there is no close to be past.
        bool started = highestBidder != address(0);
        if (settled || block.timestamp < startsAt || (started && block.timestamp >= endsAt)) {
            revert AuctionNotOpen();
        }
        // Bound BEFORE the unchanged upstream predicate: its difference * MAX_BPS cannot overflow.
        if (amount > type(uint128).max || !_isNewWinningBid(reservePrice, highestBid, amount, incrementBps)) {
            revert BidTooLow(minimumBid());
        }
        if (amount % tokenUnit != 0) revert NonWholeUnitBid();

        outbid = highestBidder;
        outbidAmount = highestBid;
        highestBidder = msg.sender;
        highestBid = amount;
        if (!started) {
            // First bid: the full duration starts now. Both terms are bounded by uint64.
            endsAt = uint64(block.timestamp) + duration;
            emit AuctionStarted(msg.sender, endsAt);
        } else {
            // Bounded by the uint64 timestamp plus a uint64 window; no absolute end.
            uint64 extended = uint64(block.timestamp) + extensionWindow;
            if (extended > endsAt) endsAt = extended;
        }
    }

    /// @dev Collect the full recorded amount; no buyout clamp, currency wrapper or outgoing refund.
    function _collectBid(uint256 amount) internal {
        uint256 beforeBalance = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = paymentToken.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnsupportedTokenBehavior();
        }
    }

    /// @dev Push the outbid amount back; on any failure keep it as a pull refund instead, so an
    ///      address that cannot receive the token never blocks later bids. State is final before this.
    function _refundOutbid(address bidder, uint256 amount) internal {
        if (bidder == address(0)) return;
        try this.payOutbidRefund{gas: REFUND_GAS}(bidder, amount) {
            emit RefundPaid(bidder, amount);
        } catch {
            refunds[bidder] += amount;
            refundLiability += amount;
            emit RefundDeferred(bidder, amount);
        }
    }

    /// @notice Internal use only: the automatic refund, as a call this contract makes to itself so
    ///         a failure can be caught. Anyone else calling it reverts.
    function payOutbidRefund(address bidder, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        _pay(bidder, amount);
    }

    /// @dev Unchanged thirdweb bid predicate. Caller bounds amounts to uint128 and bps to 1..10000.
    function _isNewWinningBid(
        uint256 _minimumBidAmount,
        uint256 _currentWinningBidAmount,
        uint256 _incomingBidAmount,
        uint256 _bidBufferBps
    ) internal pure returns (bool isValidNewBid) {
        if (_currentWinningBidAmount == 0) {
            isValidNewBid = _incomingBidAmount >= _minimumBidAmount;
        } else {
            isValidNewBid =
            (_incomingBidAmount > _currentWinningBidAmount
                    && ((_incomingBidAmount - _currentWinningBidAmount) * MAX_BPS) / _currentWinningBidAmount
                        >= _bidBufferBps);
        }
    }

    function _pay(address to, uint256 amount) private {
        uint256 beforeBalance = paymentToken.balanceOf(address(this));
        uint256 recipientBefore = paymentToken.balanceOf(to);
        paymentToken.safeTransfer(to, amount);
        uint256 afterBalance = paymentToken.balanceOf(address(this));
        uint256 recipientAfter = paymentToken.balanceOf(to);
        if (
            afterBalance > beforeBalance || beforeBalance - afterBalance != amount
                || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
        ) revert UnsupportedTokenBehavior();
    }

    function _validateRecipient(address to) internal view virtual {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }
}
