// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnglishAuction} from "../../../src/auction/EnglishAuction.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";

/// @notice The Kilim auction: native ETH bids, motif credits for every bid, the 1/1 to the winner.
/// @dev Kilim reward/prize extension of the Apache-2.0 auction adaptation. See REUSE.md for provenance.
///      Outbid bidders keep their credits by design, to reward continued bidding; a single wallet can
///      therefore collect credits for refunded bids. The motif cap bounds issuance. Each bid reserves
///      the next motif ids, fixing which motifs they show. Upstream audits do not cover this code.
///      The two token contracts are deployed first, each naming this auction's predicted address as
///      its minter; the constructor checks that they did.
/// @dev REVIEW FIXTURE: HEAD (pre-change) KilimAuction with PRIZE_GAS 500,000, as deployed on Sepolia.
contract KilimAuctionSepolia500k is EnglishAuction {
    struct Config {
        address treasury;
        address motifs;
        address oneOfOne;
        uint64 startsAt;
        uint64 duration;
        uint64 extensionWindow;
        uint16 incrementBps;
        uint256 reservePrice;
        uint256 maxMotifsPerBid;
    }

    /// @dev Motif token ids nextId..nextId+remaining-1, reserved by one bid and not yet claimed.
    struct CreditRange {
        uint128 nextId;
        uint128 remaining;
    }

    KilimMotifs public immutable motifs;
    KilimOneOfOne public immutable oneOfOne;
    /// @notice Read from the motif collection, so it cannot be configured twice.
    uint256 public immutable motifCap;
    uint256 public immutable maxMotifsPerBid;
    bool public prizeClaimed;
    uint256 public motifsAllocated;
    uint256 public motifsClaimed;
    mapping(address => uint256) public motifCredits;
    mapping(address => CreditRange[]) private _creditRanges;
    mapping(address => uint256) private _nextCreditRange;
    /// @dev The motif ids the current highest bid reserved; see highestBidMotifs. One slot.
    uint128 private _highestBidFirstMotifId;
    uint128 private _highestBidMotifCount;

    /// @dev Gas allowed for sending the 1/1 to the winner at settlement, receiver callback included.
    uint256 private constant PRIZE_GAS = 500_000;

    error RewardSlippage();
    error InvalidQuantity();
    error PrizeAlreadyClaimed();
    error MotifRangeMoved(uint256 firstMotifId);

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 motifReward, uint256 firstMotifId, uint64 endsAt
    );
    event MotifsClaimed(
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
        if (config.motifs.code.length == 0 || config.oneOfOne.code.length == 0) revert InvalidConfiguration();
        KilimMotifs motifs_ = KilimMotifs(config.motifs);
        KilimOneOfOne oneOfOne_ = KilimOneOfOne(config.oneOfOne);
        // Both token contracts must have been built for this auction, and the 1/1 must draw its motifs
        // from this collection.
        if (
            motifs_.minter() != address(this) || oneOfOne_.minter() != address(this)
                || address(oneOfOne_.motifs()) != config.motifs
        ) revert InvalidConfiguration();
        if (config.treasury == config.motifs || config.treasury == config.oneOfOne) {
            revert InvalidConfiguration();
        }
        uint256 cap = motifs_.motifCap();
        // The per-bid limit is at least 1 and at most the cap; the collection keeps the cap nonzero.
        if (config.maxMotifsPerBid == 0 || config.maxMotifsPerBid > cap) revert InvalidConfiguration();
        motifs = motifs_;
        oneOfOne = oneOfOne_;
        motifCap = cap;
        maxMotifsPerBid = config.maxMotifsPerBid;
    }

    /// @notice Bid the full amount in wei; msg.value must equal it.
    /// @param minimumReward Revert if capped credits fall below your expected reward.
    /// @param expectedFirstMotifId Revert unless the reward starts at this motif id, i.e. the quoted
    ///        motifs; 0 accepts whatever ids are next. Pass 0 when the quoted reward is 0: a bid that
    ///        earns no motifs reserves no ids, so any nonzero value reverts.
    /// @dev All accounting precedes the refund, the only call out; a wrong msg.value rolls back credits and the bid.
    ///      The reward reserves the next motif ids in allocation order, so which motifs they show is fixed
    ///      now and cannot change with claim time, claim order, or recipient.
    function bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstMotifId)
        external
        payable
        nonReentrant
    {
        _bid(amount, minimumReward, expectedFirstMotifId);
    }

    function _bid(uint256 amount, uint256 minimumReward, uint256 expectedFirstMotifId) private {
        (address outbid, uint256 outbidAmount) = _handleBid(amount);
        uint256 reward = rewardForBid(amount);
        if (reward < minimumReward) revert RewardSlippage();
        uint256 firstMotifId = 0;
        // Motif ids run 1..motifCap, in allocation order.
        if (reward != 0) firstMotifId = 1 + motifsAllocated;
        if (expectedFirstMotifId != 0 && firstMotifId != expectedFirstMotifId) {
            revert MotifRangeMoved(firstMotifId);
        }
        // Both values are bounded by motifCap, which the collection keeps under uint32 max.
        if (reward != 0) {
            _creditRanges[msg.sender].push(CreditRange(uint128(firstMotifId), uint128(reward)));
            motifCredits[msg.sender] += reward;
            motifsAllocated += reward;
        }
        // Every accepted bid is the new highest: its ids are the ones highestBidMotifs reports.
        _highestBidFirstMotifId = uint128(firstMotifId);
        _highestBidMotifCount = uint128(reward);
        _collectBid(amount);
        _refundOutbid(outbid, outbidAmount);
        emit BidPlaced(msg.sender, amount, reward, firstMotifId, endsAt);
    }

    /// @notice The motif ids the current highest bid reserved, after settlement the winning bid's:
    ///         `count` ids from `firstMotifId`, the same ones its BidPlaced event names. Both are 0 when
    ///         it earned none (the pool was empty) or before the first bid. The ids stay the same after
    ///         they are claimed; who holds them is `motifs.ownerOf`. For Kilim Bazaar, which treats the
    ///         winner's own motifs apart, and for anyone who wants to read them without the logs.
    function highestBidMotifs() external view returns (uint256 firstMotifId, uint256 count) {
        return (_highestBidFirstMotifId, _highestBidMotifCount);
    }

    /// @notice Quote credits, not bid validity. Bidding continues after rewards are exhausted.
    function rewardForBid(uint256 amount) public view returns (uint256) {
        return Math.min(Math.min(amount / MOTIF_PRICE, maxMotifsPerBid), motifCap - motifsAllocated);
    }

    /// @notice Mint your reserved motif ids, oldest bid first.
    /// @dev A claim spanning several bids mints several id ranges; the collection's MotifsMinted events
    ///      list each one. firstTokenId below is the first id minted by this claim.
    ///      Motifs are never sent automatically: every bidder claims here.
    function claimMotifs(uint256 quantity, address to) external nonReentrant {
        _validateRecipient(to);
        if (quantity == 0 || quantity > motifs.MAX_MINT_BATCH() || quantity > motifCredits[msg.sender]) {
            revert InvalidQuantity();
        }
        _claim(quantity, to);
    }

    /// @dev Mint `quantity` of the caller's reserved ids to `to`. The caller checked the quantity.
    function _claim(uint256 quantity, address to) private {
        address bidder = msg.sender;
        motifCredits[bidder] -= quantity;
        motifsClaimed += quantity;
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
            motifs.mintMotifs(to, bidder, firstIds[i], counts[i]);
        }
        emit MotifsClaimed(bidder, to, quantity, firstIds[0]);
    }

    /// @notice A bidder's reserved, unclaimed motif id ranges, in claim order.
    function unclaimedMotifRanges(address bidder) external view returns (CreditRange[] memory result) {
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

    /// @notice Only needed if settlement could not send it: the winner claims the 1/1, to any address that
    ///         can hold it and with as much gas as they give. Nobody else can: the winner chooses where it
    ///         goes. Settlement is impossible without a bid, so there is no unsold branch: with no bids the
    ///         auction never ends.
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
        if (to == address(motifs) || to == address(oneOfOne)) revert InvalidRecipient();
    }
}
