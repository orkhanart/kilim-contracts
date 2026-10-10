// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20EnglishAuction} from "./auction/ERC20EnglishAuction.sol";
import {Kilim} from "./Kilim.sol";
import {IKilimRenderer} from "./render/IKilimRenderer.sol";

/// @notice Native ETH launch (zero payment token), with legacy ERC-20 regression support.
/// @dev Kilim reward/prize extension of the Apache-2.0 auction adaptation. See REUSE.md for provenance.
///      Outbid bidders keep their credits by design, to reward continued bidding; a single wallet can
///      therefore collect credits for refunded bids. Immutable caps bound issuance. Each bid reserves
///      the next symbol IDs, fixing their traits. Upstream audits do not cover this code.
contract KilimAuction is ERC20EnglishAuction {
    struct Config {
        address paymentToken;
        address treasury;
        address collectionOwner;
        uint64 startsAt;
        uint64 duration;
        uint64 extensionWindow;
        uint16 incrementBps;
        uint256 reservePrice;
        uint256 symbolCap;
        uint256 maxSymbolsPerBid;
        uint16 motifCount;
        uint16 maxCells;
        bytes32 geometryHash;
        bytes32 rendererHash;
        /// @dev The deployed KilimRenderer; Kilim's constructor checks it against the three values above.
        address renderer;
    }

    /// @dev Symbol token IDs nextId..nextId+remaining-1, reserved by one bid and not yet claimed.
    struct CreditRange {
        uint128 nextId;
        uint128 remaining;
    }

    Kilim public immutable collection;
    uint256 public immutable symbolCap;
    uint256 public immutable maxSymbolsPerBid;
    bool public prizeClaimed;
    uint256 public symbolsAllocated;
    uint256 public symbolsClaimed;
    mapping(address => uint256) public symbolCredits;
    mapping(address => CreditRange[]) private _creditRanges;
    mapping(address => uint256) private _nextCreditRange;
    /// @dev Bidders in bid order, one entry per rewarded bid, for automatic delivery.
    address[] private _deliveryQueue;
    /// @notice The next queue entry deliverSymbols looks at.
    uint256 public deliveryCursor;

    /// @notice Most symbols one deliverSymbols call mints, keeping it well under the per-transaction gas cap.
    uint256 public constant DELIVERY_BATCH = 64;
    /// @dev Most queue entries one call walks, so a run of already-delivered entries stays cheap.
    uint256 private constant DELIVERY_SCAN = 256;
    /// @dev Gas allowed per symbol for one bidder's mint, receiver callbacks included. A wallet that
    ///      needs more, or rejects the tokens, is skipped and claims by hand instead.
    uint256 private constant DELIVERY_GAS_PER_SYMBOL = 150_000;
    /// @dev Gas allowed for sending the 1/1 to the winner at settlement, receiver callback included.
    uint256 private constant PRIZE_GAS = 500_000;

    error RewardSlippage();
    error InvalidQuantity();
    error PrizeAlreadyClaimed();
    error SymbolRangeMoved(uint256 firstSymbolId);

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 symbolReward, uint256 firstSymbolId, uint64 endsAt
    );
    event SymbolsClaimed(
        address indexed bidder, address indexed recipient, uint256 count, uint256 firstTokenId
    );
    event PrizeClaimed(address indexed winner, address indexed recipient);
    /// @notice A delivery to this bidder failed; their symbols stay claimable with claimSymbols.
    event DeliveryFailed(address indexed bidder, uint256 count);
    /// @notice Settlement could not send the 1/1 to the winner; they claim it with claimPrize.
    event PrizeDeliveryFailed(address indexed winner);

    constructor(Config memory config)
        ERC20EnglishAuction(AuctionConfig({
                paymentToken: config.paymentToken,
                treasury: config.treasury,
                startsAt: config.startsAt,
                duration: config.duration,
                extensionWindow: config.extensionWindow,
                incrementBps: config.incrementBps,
                reservePrice: config.reservePrice
            }))
    {
        if (
            config.symbolCap == 0 || config.symbolCap > type(uint64).max || config.maxSymbolsPerBid == 0
                || config.maxSymbolsPerBid > config.symbolCap
        ) revert InvalidConfiguration();
        symbolCap = config.symbolCap;
        maxSymbolsPerBid = config.maxSymbolsPerBid;
        // The collection-page role starts with collectionOwner; royalties start at the treasury.
        collection = new Kilim(
            address(this),
            config.collectionOwner,
            config.treasury,
            config.symbolCap,
            config.motifCount,
            config.maxCells,
            config.geometryHash,
            config.rendererHash,
            IKilimRenderer(config.renderer)
        );
        if (config.treasury == address(collection)) revert InvalidConfiguration();
    }

    /// @notice Bid the full amount in wei with matching msg.value in native mode.
    /// @dev Legacy ERC-20 mode instead requires approval and zero msg.value.
    /// @param minimumReward Revert if capped credits fall below your expected reward.
    /// @param expectedFirstSymbolId Revert unless the reward starts at this symbol ID, i.e. the
    ///        quoted traits; 0 accepts whatever IDs are next. Pass 0 when the quoted reward is 0:
    ///        a bid that earns no symbols reserves no IDs, so any nonzero value reverts.
    /// @dev All accounting precedes token calls; a rejected deposit rolls back credits and the bid.
    ///      The reward reserves the next symbol IDs in allocation order, so their traits are fixed
    ///      now and cannot change with claim time, claim order, or recipient.
    function bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstSymbolId)
        external
        payable
        nonReentrant
    {
        _bid(amount, minimumReward, expectedFirstSymbolId);
    }

    function _bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstSymbolId) private {
        (address outbid, uint256 outbidAmount) = _handleBid(amount);
        uint256 reward = rewardForBid(amount);
        if (reward < minimumReward) revert RewardSlippage();
        uint256 firstSymbolId = 0;
        if (reward != 0) firstSymbolId = collection.FIRST_SYMBOL_ID() + symbolsAllocated;
        if (expectedFirstSymbolId != 0 && firstSymbolId != expectedFirstSymbolId) {
            revert SymbolRangeMoved(firstSymbolId);
        }
        if (reward != 0) {
            // Both values are bounded by symbolCap <= uint64 max.
            _creditRanges[msg.sender].push(CreditRange(uint128(firstSymbolId), uint128(reward)));
            symbolCredits[msg.sender] += reward;
            symbolsAllocated += reward;
            _deliveryQueue.push(msg.sender);
        }
        _collectBid(amount);
        _refundOutbid(outbid, outbidAmount);
        emit BidPlaced(msg.sender, amount, reward, firstSymbolId, endsAt);
    }

    /// @notice Quote credits, not bid validity. Bidding continues after rewards are exhausted.
    function rewardForBid(uint256 amount) public view returns (uint256) {
        return Math.min(Math.min(amount / tokenUnit, maxSymbolsPerBid), symbolCap - symbolsAllocated);
    }

    /// @notice Mint your reserved symbol IDs, oldest bid first.
    /// @dev A claim spanning several bids mints several ID ranges; the collection's SymbolsMinted
    ///      events list each one. firstTokenId below is the first ID minted by this claim.
    ///         Native-ETH bidders claim their symbols here; legacy ERC-20 mode also supports delivery.
    function claimSymbols(uint256 quantity, address to) external nonReentrant {
        _validateRecipient(to);
        if (quantity == 0 || quantity > collection.MAX_MINT_BATCH() || quantity > symbolCredits[msg.sender]) {
            revert InvalidQuantity();
        }
        _claim(msg.sender, quantity, to);
    }

    /// @notice Send reserved symbols to the wallets that bid for them, oldest bid first, up to
    ///         `maxSymbols` (at most DELIVERY_BATCH). Anyone may call it and pays its gas; the
    ///         artist runs it until nothing is pending. A wallet that cannot take the tokens is
    ///         skipped (DeliveryFailed) and keeps its symbols to claim by hand.
    /// @return delivered How many symbols this call minted.
    /// @dev The cursor is stored after the self-calls because whether an entry is done depends on
    ///      their outcome. No re-entry can observe it: every state-changing entry point is
    ///      nonReentrant and deliverTo only accepts calls from this contract.
    // slither-disable-next-line reentrancy-no-eth
    function deliverSymbols(uint256 maxSymbols) external nonReentrant returns (uint256 delivered) {
        // Native-ETH launch uses collector claims, not automatic symbol delivery.
        if (address(paymentToken) == address(0)) revert Unauthorized();
        if (maxSymbols == 0 || maxSymbols > DELIVERY_BATCH) revert InvalidQuantity();
        uint256 cursor = deliveryCursor;
        uint256 end = _deliveryQueue.length;
        for (uint256 scanned; cursor < end && scanned < DELIVERY_SCAN && delivered < maxSymbols; ++scanned) {
            address bidder = _deliveryQueue[cursor];
            uint256 take = Math.min(symbolCredits[bidder], maxSymbols - delivered);
            if (take != 0) {
                // Too little gas left to give this delivery its full allowance: stop rather than
                // let it fail for lack of gas and skip a wallet that can receive (EIP-150 keeps 1/64).
                uint256 allowance = take * DELIVERY_GAS_PER_SYMBOL;
                if (gasleft() < allowance + allowance / 63 + 50_000) break;
                // A call to itself, so a failing receiver rolls back only its own delivery.
                try this.deliverTo{gas: allowance}(bidder, take) {
                    delivered += take;
                } catch {
                    emit DeliveryFailed(bidder, take);
                    ++cursor;
                    continue;
                }
            }
            // Move on once this bidder has nothing left; stop here if the batch ran out first.
            if (symbolCredits[bidder] != 0) break;
            ++cursor;
        }
        deliveryCursor = cursor;
    }

    /// @notice Internal use only: one bidder's delivery, as a call this contract makes to itself.
    function deliverTo(address bidder, uint256 quantity) external {
        if (msg.sender != address(this)) revert Unauthorized();
        _claim(bidder, quantity, bidder);
    }

    /// @notice Reserved symbols not yet delivered or claimed.
    function symbolsPending() external view returns (uint256) {
        return symbolsAllocated - symbolsClaimed;
    }

    /// @dev Mint `quantity` of `bidder`'s reserved IDs to `to`. The caller checked the quantity.
    function _claim(address bidder, uint256 quantity, address to) private {
        symbolCredits[bidder] -= quantity;
        symbolsClaimed += quantity;
        // Unclaimed ranges from the cursor onward are nonempty and sum to the caller's credits.
        CreditRange[] storage ranges = _creditRanges[bidder];
        uint256 cursor = _nextCreditRange[bidder];
        uint256[] memory firstIds = new uint256[](quantity);
        uint256[] memory counts = new uint256[](quantity);
        uint256 chunks = 0;
        for (uint256 left = quantity; left != 0; ++chunks) {
            CreditRange storage range = ranges[cursor];
            uint256 take = Math.min(left, range.remaining);
            firstIds[chunks] = range.nextId;
            counts[chunks] = take;
            // take <= remaining, which fits uint128.
            range.nextId += uint128(take);
            range.remaining -= uint128(take);
            if (range.remaining == 0) ++cursor;
            left -= take;
        }
        _nextCreditRange[bidder] = cursor;
        // Credit accounting is final before any receiver callback.
        for (uint256 i; i < chunks; ++i) {
            collection.mintSymbols(to, bidder, firstIds[i], counts[i]);
        }
        emit SymbolsClaimed(bidder, to, quantity, firstIds[0]);
    }

    /// @notice A bidder's reserved, unclaimed symbol ID ranges, in claim order.
    function unclaimedSymbolRanges(address bidder) external view returns (CreditRange[] memory result) {
        CreditRange[] storage ranges = _creditRanges[bidder];
        uint256 cursor = _nextCreditRange[bidder];
        result = new CreditRange[](ranges.length - cursor);
        for (uint256 i; i < result.length; ++i) {
            result[i] = ranges[cursor + i];
        }
    }

    /// @dev Settlement sends the 1/1 straight to the winner. A wallet that rejects it, or needs more
    ///      than PRIZE_GAS, leaves settlement intact and the winner claims it with claimPrize.
    function _afterSettle() internal override {
        // Give the delivery its full allowance or do not settle yet (EIP-150 keeps back 1/64): a
        // low-gas settle() cannot skip sending the 1/1. Reverting undoes the settlement; anyone retries.
        if (gasleft() < PRIZE_GAS + PRIZE_GAS / 63 + 50_000) revert InsufficientGas();
        try this.deliverPrize{gas: PRIZE_GAS}() {}
        catch {
            emit PrizeDeliveryFailed(highestBidder);
        }
    }

    /// @notice Internal use only: the 1/1 to the winner at settlement, as a call to itself.
    function deliverPrize() external {
        if (msg.sender != address(this)) revert Unauthorized();
        address winner = highestBidder;
        prizeClaimed = true;
        collection.mintMasterpiece(winner);
        emit PrizeClaimed(winner, winner);
    }

    /// @notice Only needed if settlement could not send it: the winner claims the masterpiece. Settlement is impossible without a bid, so
    ///         there is no unsold branch: with no bids the auction simply never ends.
    function claimPrize(address to) external nonReentrant {
        if (!settled) revert NotSettled();
        address winner = highestBidder;
        if (msg.sender != winner) revert Unauthorized();
        if (prizeClaimed) revert PrizeAlreadyClaimed();
        _validateRecipient(to);
        prizeClaimed = true;
        collection.mintMasterpiece(to);
        emit PrizeClaimed(winner, to);
    }

    function _validateRecipient(address to) internal view override {
        super._validateRecipient(to);
        if (to == address(collection)) revert InvalidRecipient();
    }
}
