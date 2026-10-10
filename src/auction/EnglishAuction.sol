// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A single immutable auction in native ETH. Bidding opens once 100 wallets have registered.
/// @dev The clock starts at the FIRST accepted bid, not at a fixed time: `startsAt` only opens
///      bidding. Late bids extend the close without any absolute limit, so the auction ends only
///      after `extensionWindow` passes with no new bid. With no bids it never ends and never settles.
/// @dev Adapted from thirdweb's EnglishAuctionsLogic, commit 46e69070978c23b9533edb381e838a5dddf7ed9d.
///      Original author: thirdweb. Modified for Kilim; see REUSE.md and vendor/thirdweb/NOTICE.
///      Only _isNewWinningBid is retained unchanged (apart from formatting). The escrow, scheduling,
///      storage, settlement and integration changes are NOT covered by the upstream audit.
abstract contract EnglishAuction is ReentrancyGuard, EIP712 {
    uint64 private constant MAX_BPS = 10_000;
    /// @dev Gas forwarded to an automatic refund. A plain ETH transfer uses far less; the cap stops a
    ///      hostile receiver from eating the next bidder's gas.
    uint256 private constant REFUND_GAS = 150_000;
    /// @dev Gas kept back, after the refund's allowance, for recording a refund that could not be paid:
    ///      two fresh storage slots, two events and the guard. About 47,000 today; sized several times
    ///      over so a later repricing of new storage (EIP-8037 puts it near 200,000) cannot reopen the
    ///      out-of-gas path in a contract that can never be changed. Unused gas is not charged.
    uint256 private constant DEFERRED_REFUND_RESERVE = 300_000;

    struct AuctionConfig {
        address treasury;
        uint64 startsAt;
        uint64 duration;
        uint64 extensionWindow;
        uint16 incrementBps;
        uint256 reservePrice;
    }

    /// @notice The bid unit: every bid is a whole multiple of it, and each unit bid earns one motif.
    uint256 public constant MOTIF_PRICE = 0.001 ether;
    /// @notice The ETH a wallet must hold to register. The reserve price must equal it.
    uint256 public constant REGISTRATION_BALANCE = 0.01 ether;
    uint256 public constant REGISTRATION_TARGET = 100;
    uint256 public registrationCount;
    mapping(address => bool) public registered;
    address public immutable treasury;
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
    error TreasuryCannotBid();
    error RegistrationClosed();
    error AlreadyRegistered();
    error InsufficientRegistrationBalance();
    error RegistrationIncomplete();
    error IncorrectPayment();
    error EthTransferFailed();
    /// @notice Send the transaction with more gas: a refund or the prize delivery needs its full allowance.
    error InsufficientGas();
    error RegistrationSignatureExpired();
    error InvalidRegistrationSignature();
    bytes32 private constant REGISTER_TYPEHASH = keccak256("Register(address wallet,uint256 deadline)");

    event Registered(address indexed wallet, uint256 count);

    event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amount);
    /// @notice The outbid amount went straight back to the outbid bidder.
    event RefundPaid(address indexed bidder, uint256 amount);
    /// @notice The automatic refund failed (for example a contract that rejects ETH); it waits in `refunds`.
    event RefundDeferred(address indexed bidder, uint256 amount);
    event AuctionStarted(address indexed firstBidder, uint64 endsAt);
    event AuctionSettled(address indexed winner, uint256 amount);
    event ProceedsWithdrawn(address indexed recipient, uint256 amount);

    constructor(AuctionConfig memory config) EIP712("Kilim Registration", "1") {
        // The only accepted reserve is REGISTRATION_BALANCE: nonzero, a whole number of bid units and
        // far below the uint128 bound on bids. A zero duration needs no clause of its own: the window
        // must be nonzero and no longer than the duration.
        if (
            config.treasury == address(0) || config.treasury == address(this)
                || config.startsAt <= block.timestamp || config.duration > 30 days
                || config.extensionWindow == 0 || config.extensionWindow > config.duration
                || config.incrementBps == 0 || config.incrementBps > MAX_BPS
                || config.reservePrice != REGISTRATION_BALANCE
        ) revert InvalidConfiguration();
        treasury = config.treasury;
        startsAt = config.startsAt;
        duration = config.duration;
        extensionWindow = config.extensionWindow;
        incrementBps = config.incrementBps;
        reservePrice = config.reservePrice;
    }

    /// @notice Register interest without depositing ETH. The balance is checked after gas prepayment.
    /// @dev This counts addresses, not distinct people; funds can be moved after registration.
    function register() external nonReentrant {
        _register(msg.sender);
    }

    /// @notice Anyone may pay gas to submit a wallet's registration-only authorization.
    /// @dev Domain binds the chain and this auction. Registration is one-shot, so registered[wallet]
    ///      is the replay guard shared with direct registration. This never authorizes a payment/bid.
    function registerFor(address wallet, uint256 deadline, bytes calldata signature) external nonReentrant {
        if (block.timestamp > deadline) revert RegistrationSignatureExpired();
        if (
            wallet == address(0)
                || !SignatureChecker.isValidSignatureNowCalldata(
                    wallet, registrationDigest(wallet, deadline), signature
                )
        ) revert InvalidRegistrationSignature();
        _register(wallet);
    }

    function registrationDigest(address wallet, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REGISTER_TYPEHASH, wallet, deadline)));
    }

    function _register(address wallet) private {
        if (block.timestamp < startsAt || registrationCount >= REGISTRATION_TARGET) {
            revert RegistrationClosed();
        }
        if (wallet == treasury) revert TreasuryCannotBid();
        if (registered[wallet]) revert AlreadyRegistered();
        if (wallet.balance < REGISTRATION_BALANCE) revert InsufficientRegistrationBalance();
        registered[wallet] = true;
        emit Registered(wallet, ++registrationCount);
    }

    function minimumBid() public view returns (uint256) {
        if (highestBid == 0) return reservePrice;
        uint256 increment = Math.mulDiv(highestBid, incrementBps, MAX_BPS, Math.Rounding.Ceil);
        uint256 next = highestBid + increment;
        return Math.ceilDiv(next, MOTIF_PRICE) * MOTIF_PRICE;
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

    /// @notice Settlement records the outcome, then hands the extension a chance to deliver the prize.
    /// @dev Impossible until a first bid starts the clock; with no bids there is nothing to settle.
    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (highestBidder == address(0)) revert NoBids();
        if (block.timestamp < endsAt) revert AuctionNotEnded();
        settled = true;
        proceedsDue = highestBid;
        emit AuctionSettled(highestBidder, highestBid);
        _afterSettle();
    }

    /// @dev Runs at the end of settle(), after the outcome is recorded. It may revert only to refuse a
    ///      settlement sent with too little gas; that undoes the settlement and anyone can retry.
    function _afterSettle() internal virtual {}

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

    /// @notice Minimum ETH balance needed to pay every current obligation.
    function liabilities() external view returns (uint256) {
        return refundLiability + (settled ? proceedsDue : highestBid);
    }

    /// @dev Adaptation of thirdweb _handleBid's ascending-bid branch. Called only inside Kilim's
    ///      nonReentrant bid entry point, which allocates rewards and MUST then call _collectBid and
    ///      _refundOutbid(previous bidder, previous bid) in the same call. Returns the outbid bid, if any.
    ///      The seller's treasury cannot bid. Other wallets it controls are not detectable.
    ///      The first accepted bid starts the clock; later bids inside the window extend it, forever.
    function _handleBid(uint256 amount) internal returns (address outbid, uint256 outbidAmount) {
        if (msg.sender == treasury) revert TreasuryCannotBid();
        if (registrationCount != REGISTRATION_TARGET) revert RegistrationIncomplete();
        // No highest bidder means the clock has not started, so there is no close to be past.
        bool started = highestBidder != address(0);
        // Open from the hundredth registration (which cannot happen before startsAt) until the close.
        // Settlement needs the close to have passed, and the close cannot move afterwards.
        if (started && block.timestamp >= endsAt) revert AuctionNotOpen();
        // Bound BEFORE the unchanged upstream predicate: its difference * MAX_BPS cannot overflow.
        if (amount > type(uint128).max || !_isNewWinningBid(reservePrice, highestBid, amount, incrementBps)) {
            revert BidTooLow(minimumBid());
        }
        if (amount % MOTIF_PRICE != 0) revert NonWholeUnitBid();

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

    /// @dev The ETH sent must be exactly the recorded amount.
    function _collectBid(uint256 amount) internal view {
        if (msg.value != amount) revert IncorrectPayment();
    }

    /// @dev Push the outbid amount back; on any failure keep it as a pull refund instead, so an
    ///      address that cannot receive ETH never blocks later bids. State is final before this.
    function _refundOutbid(address bidder, uint256 amount) internal {
        if (bidder == address(0)) return;
        // The refund always gets its full allowance and still leaves enough for the deferred path
        // (EIP-150 keeps back 1/64), so the gas a bid needs never depends on the outbid wallet's code:
        // a leader cannot make a rival's correctly estimated bid run out of gas.
        if (gasleft() < REFUND_GAS + REFUND_GAS / 63 + DEFERRED_REFUND_RESERVE) revert InsufficientGas();
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

    /// @dev Every caller pays only what is owed: an outbid bidder's own bid back to them, a refund to
    ///      the address its owner names, or the proceeds to the address the treasury names. Amounts are
    ///      zeroed or final before the call and every entry point is nonReentrant.
    // slither-disable-next-line arbitrary-send-eth
    function _pay(address to, uint256 amount) private {
        (bool paid,) = payable(to).call{value: amount}("");
        if (!paid) revert EthTransferFailed();
    }

    function _validateRecipient(address to) internal view virtual {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }
}
