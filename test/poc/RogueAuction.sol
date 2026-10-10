// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev PoC (site review, 10 October 2026). A contract that answers every read site/chain.js makes at
///      startup, on refresh and for a quote, names the real token contracts, and keeps every bid. The
///      site's startup check binds the auction to its tokens (auction.motifs() == cfg.motifs) but not
///      the tokens to the auction (motifs.minter() == cfg.auction), so a chain config that names this
///      contract as the auction passes every check and the page sends bids here.
contract RogueAuction {
    struct CreditRange {
        uint128 nextId;
        uint128 remaining;
    }

    uint256 public constant MOTIF_PRICE = 0.001 ether;
    uint64 public constant duration = 1 days;
    uint64 public constant extensionWindow = 10 minutes;
    uint16 public constant incrementBps = 1000;
    uint256 public constant reservePrice = 0.01 ether;
    uint256 public constant motifCap = 1_000_000;
    uint256 public constant maxMotifsPerBid = 1_000_000;
    uint256 public constant registrationCount = 100;
    address public immutable motifs;
    address public immutable oneOfOne;
    address public immutable treasury;
    uint64 public immutable startsAt;
    uint256 public highestBid;
    address public highestBidder;
    uint64 public endsAt;
    uint256 public motifsAllocated;
    uint256 public motifsClaimed;
    bool public settled;
    bool public prizeClaimed;
    uint256 public proceedsDue;
    mapping(address => uint256) public refunds;
    mapping(address => uint256) public motifCredits;
    mapping(address => bool) public registered;

    event BidPlaced(
        address indexed bidder, uint256 amount, uint256 motifReward, uint256 firstMotifId, uint64 endsAt
    );

    constructor(address motifs_, address oneOfOne_, address treasury_) {
        motifs = motifs_;
        oneOfOne = oneOfOne_;
        treasury = treasury_;
        startsAt = uint64(block.timestamp);
    }

    function minimumBid() public view returns (uint256) {
        return highestBid == 0 ? reservePrice : highestBid + highestBid / 10;
    }

    function rewardForBid(uint256 amount) public pure returns (uint256) {
        return amount / MOTIF_PRICE;
    }

    function unclaimedMotifRanges(address) external pure returns (CreditRange[] memory result) {
        result = new CreditRange[](0);
    }

    /// @dev Takes the ETH and never refunds anyone.
    function bid(uint256 amount, uint256, uint256) external payable {
        require(msg.value == amount, "value");
        highestBid = amount;
        highestBidder = msg.sender;
        endsAt = uint64(block.timestamp) + duration;
        uint256 reward = rewardForBid(amount);
        motifCredits[msg.sender] += reward;
        motifsAllocated += reward;
        emit BidPlaced(msg.sender, amount, reward, 1, endsAt);
    }
}
