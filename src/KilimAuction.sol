// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnglishAuction} from "./auction/EnglishAuction.sol";
import {KilimGlyphs} from "./KilimGlyphs.sol";
import {KilimOneOfOne} from "./KilimOneOfOne.sol";

/// @notice The Kilim auction: native ETH bids, glyph credits for every bid, the 1/1 to the winner.
/// @dev Kilim reward/prize extension of the Apache-2.0 auction adaptation. See REUSE.md for provenance.
///      Outbid bidders keep their credits by design, to reward continued bidding; a single wallet can
///      therefore collect credits for refunded bids. The glyph cap bounds issuance. Each bid reserves
///      the next glyph ids, fixing which glyphs they show. Upstream audits do not cover this code.
///      The two token contracts are deployed first, each naming this auction's predicted address as
///      its minter; the constructor checks that they did.
contract KilimAuction is EnglishAuction {
    struct Config {
        address treasury;
        address glyphs;
        address oneOfOne;
        uint64 startsAt;
        uint64 duration;
        uint64 extensionWindow;
        uint16 incrementBps;
        uint256 reservePrice;
        uint256 maxGlyphsPerBid;
    }

    /// @dev Glyph token ids nextId..nextId+remaining-1, reserved by one bid and not yet claimed.
    struct CreditRange {
        uint128 nextId;
        uint128 remaining;
    }

    KilimGlyphs public immutable glyphs;
    KilimOneOfOne public immutable oneOfOne;
    /// @notice Read from the glyph collection, so it cannot be configured twice.
    uint256 public immutable glyphCap;
    uint256 public immutable maxGlyphsPerBid;
    bool public prizeClaimed;
    uint256 public glyphsAllocated;
    uint256 public glyphsClaimed;
    mapping(address => uint256) public glyphCredits;
    mapping(address => CreditRange[]) private _creditRanges;
    mapping(address => uint256) private _nextCreditRange;

    /// @dev Gas allowed for sending the 1/1 to the winner at settlement, receiver callback included.
    uint256 private constant PRIZE_GAS = 500_000;

    error RewardSlippage();
    error InvalidQuantity();
    error PrizeAlreadyClaimed();
    error GlyphRangeMoved(uint256 firstGlyphId);

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 glyphReward, uint256 firstGlyphId, uint64 endsAt
    );
    event GlyphsClaimed(
        address indexed bidder, address indexed recipient, uint256 count, uint256 firstTokenId
    );
    event PrizeClaimed(address indexed winner, address indexed recipient);
    /// @notice Settlement could not send the 1/1 to the winner; they claim it with claimPrize.
    event PrizeDeliveryFailed(address indexed winner);

    constructor(Config memory config)
        EnglishAuction(AuctionConfig({
                treasury: config.treasury,
                startsAt: config.startsAt,
                duration: config.duration,
                extensionWindow: config.extensionWindow,
                incrementBps: config.incrementBps,
                reservePrice: config.reservePrice
            }))
    {
        if (config.glyphs.code.length == 0 || config.oneOfOne.code.length == 0) revert InvalidConfiguration();
        KilimGlyphs glyphs_ = KilimGlyphs(config.glyphs);
        KilimOneOfOne oneOfOne_ = KilimOneOfOne(config.oneOfOne);
        // Both token contracts must have been built for this auction, and the 1/1 must draw its glyphs
        // from this collection.
        if (
            glyphs_.minter() != address(this) || oneOfOne_.minter() != address(this)
                || address(oneOfOne_.glyphs()) != config.glyphs
        ) revert InvalidConfiguration();
        if (config.treasury == config.glyphs || config.treasury == config.oneOfOne) {
            revert InvalidConfiguration();
        }
        uint256 cap = glyphs_.glyphCap();
        // The per-bid limit is at least 1 and at most the cap; the collection keeps the cap nonzero.
        if (config.maxGlyphsPerBid == 0 || config.maxGlyphsPerBid > cap) revert InvalidConfiguration();
        glyphs = glyphs_;
        oneOfOne = oneOfOne_;
        glyphCap = cap;
        maxGlyphsPerBid = config.maxGlyphsPerBid;
    }

    /// @notice Bid the full amount in wei; msg.value must equal it.
    /// @param minimumReward Revert if capped credits fall below your expected reward.
    /// @param expectedFirstGlyphId Revert unless the reward starts at this glyph id, i.e. the quoted
    ///        glyphs; 0 accepts whatever ids are next. Pass 0 when the quoted reward is 0: a bid that
    ///        earns no glyphs reserves no ids, so any nonzero value reverts.
    /// @dev All accounting precedes the refund, the only call out; a wrong msg.value rolls back credits and the bid.
    ///      The reward reserves the next glyph ids in allocation order, so which glyphs they show is fixed
    ///      now and cannot change with claim time, claim order, or recipient.
    function bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstGlyphId)
        external
        payable
        nonReentrant
    {
        _bid(amount, minimumReward, expectedFirstGlyphId);
    }

    function _bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstGlyphId) private {
        (address outbid, uint256 outbidAmount) = _handleBid(amount);
        uint256 reward = rewardForBid(amount);
        if (reward < minimumReward) revert RewardSlippage();
        uint256 firstGlyphId = 0;
        // Glyph ids run 1..glyphCap, in allocation order.
        if (reward != 0) firstGlyphId = 1 + glyphsAllocated;
        if (expectedFirstGlyphId != 0 && firstGlyphId != expectedFirstGlyphId) {
            revert GlyphRangeMoved(firstGlyphId);
        }
        if (reward != 0) {
            // Both values are bounded by glyphCap, which the collection keeps under uint32 max.
            _creditRanges[msg.sender].push(CreditRange(uint128(firstGlyphId), uint128(reward)));
            glyphCredits[msg.sender] += reward;
            glyphsAllocated += reward;
        }
        _collectBid(amount);
        _refundOutbid(outbid, outbidAmount);
        emit BidPlaced(msg.sender, amount, reward, firstGlyphId, endsAt);
    }

    /// @notice Quote credits, not bid validity. Bidding continues after rewards are exhausted.
    function rewardForBid(uint256 amount) public view returns (uint256) {
        return Math.min(Math.min(amount / GLYPH_PRICE, maxGlyphsPerBid), glyphCap - glyphsAllocated);
    }

    /// @notice Mint your reserved glyph ids, oldest bid first.
    /// @dev A claim spanning several bids mints several id ranges; the collection's GlyphsMinted events
    ///      list each one. firstTokenId below is the first id minted by this claim.
    ///      Glyphs are never sent automatically: every bidder claims here.
    function claimGlyphs(uint256 quantity, address to) external nonReentrant {
        _validateRecipient(to);
        if (quantity == 0 || quantity > glyphs.MAX_MINT_BATCH() || quantity > glyphCredits[msg.sender]) {
            revert InvalidQuantity();
        }
        _claim(quantity, to);
    }

    /// @dev Mint `quantity` of the caller's reserved ids to `to`. The caller checked the quantity.
    function _claim(uint256 quantity, address to) private {
        address bidder = msg.sender;
        glyphCredits[bidder] -= quantity;
        glyphsClaimed += quantity;
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
            glyphs.mintGlyphs(to, bidder, firstIds[i], counts[i]);
        }
        emit GlyphsClaimed(bidder, to, quantity, firstIds[0]);
    }

    /// @notice A bidder's reserved, unclaimed glyph id ranges, in claim order.
    function unclaimedGlyphRanges(address bidder) external view returns (CreditRange[] memory result) {
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
        oneOfOne.mint(winner);
        emit PrizeClaimed(winner, winner);
    }

    /// @notice Only needed if settlement could not send it: the winner claims the 1/1. Settlement is
    ///         impossible without a bid, so there is no unsold branch: with no bids the auction never ends.
    function claimPrize(address to) external nonReentrant {
        if (!settled) revert NotSettled();
        address winner = highestBidder;
        if (msg.sender != winner) revert Unauthorized();
        if (prizeClaimed) revert PrizeAlreadyClaimed();
        _validateRecipient(to);
        prizeClaimed = true;
        oneOfOne.mint(to);
        emit PrizeClaimed(winner, to);
    }

    function _validateRecipient(address to) internal view override {
        super._validateRecipient(to);
        if (to == address(glyphs) || to == address(oneOfOne)) revert InvalidRecipient();
    }
}
