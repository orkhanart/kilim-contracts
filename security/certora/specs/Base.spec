/*
 * Shared declarations for the Kilim auction specs (KilimAuction + EnglishAuction, through
 * harness/KilimAuctionHarness.sol). Every other spec imports this file.
 *
 * Modelling choices (each one is listed again in audit/tools-2026-10-12/certora.md):
 *  - The two token contracts are not in the scene. KilimMotifs.mintMotifs is summarised by a CVL
 *    function that records what was minted in ghosts and may revert (a receiver that rejects the
 *    token); MAX_MINT_BATCH returns 64. KilimOneOfOne.mint is dispatched to harness/OneOfOneMock.sol,
 *    which counts mints and may reject any recipient.
 *  - The ETH transfer in _pay is an unresolved call. The prover's default for it is HAVOC_ECF: the
 *    call may fail, other contracts' state and balances are havocked, the auction's own storage is
 *    untouched and its balance can only go up during the call. That "no reentrant state change"
 *    assumption is justified separately by Reentrancy.spec (every entry point reverts while the
 *    guard is held, except the two self-call functions, which revert for any caller but the auction).
 *  - Immutables are symbolic in rules. configOk() restores what the constructors enforce.
 *  - A transaction is never sent by the auction itself or by address(0), and block timestamps fit
 *    in uint64 (requireRealCaller).
 */

using OneOfOneMock as prize;

methods {
    // ---- auction state, read without an environment
    function highestBid() external returns (uint256) envfree;
    function highestBidder() external returns (address) envfree;
    function endsAt() external returns (uint64) envfree;
    function settled() external returns (bool) envfree;
    function proceedsDue() external returns (uint256) envfree;
    function refundLiability() external returns (uint256) envfree;
    function refunds(address) external returns (uint256) envfree;
    function liabilities() external returns (uint256) envfree;
    function registrationCount() external returns (uint256) envfree;
    function registered(address) external returns (bool) envfree;
    function motifsAllocated() external returns (uint256) envfree;
    function motifsClaimed() external returns (uint256) envfree;
    function motifCredits(address) external returns (uint256) envfree;
    function prizeClaimed() external returns (bool) envfree;
    function minimumBid() external returns (uint256) envfree;
    function rewardForBid(uint256) external returns (uint256) envfree;
    function highestBidMotifs() external returns (uint256, uint256) envfree;

    // ---- immutables
    function treasury() external returns (address) envfree;
    function reservePrice() external returns (uint256) envfree;
    function startsAt() external returns (uint64) envfree;
    function duration() external returns (uint64) envfree;
    function extensionWindow() external returns (uint64) envfree;
    function incrementBps() external returns (uint16) envfree;
    function motifCap() external returns (uint256) envfree;
    function maxMotifsPerBid() external returns (uint256) envfree;
    function motifs() external returns (address) envfree;
    function oneOfOne() external returns (address) envfree;

    // ---- harness views
    function harnessGuardEntered() external returns (bool) envfree;
    function harnessIsNewWinningBid(uint256) external returns (bool) envfree;

    // ---- the token contracts, which are not in the scene
    function _.mintMotifs(address to, address bidder, uint256 firstId, uint256 quantity) external
        => cvlMintMotifs(to, bidder, firstId, quantity) expect void;
    function _.MAX_MINT_BATCH() external => cvlMaxMintBatch() expect uint256;
    // KilimOneOfOne.mint(to): dispatched to harness/OneOfOneMock.sol, which may reject any recipient.
    function _.mint(address) external => DISPATCHER(true);
}

// ------------------------------------------------------------------ token summaries

/// Total motifs minted through mintMotifs, and per bidder (the `bidder` argument).
persistent ghost mathint ghostMotifsMinted {
    init_state axiom ghostMotifsMinted == 0;
}
persistent ghost mapping(address => mathint) ghostMotifsMintedFor {
    init_state axiom forall address a. ghostMotifsMintedFor[a] == 0;
}
/// Set if mintMotifs is ever asked for an id outside 1..motifsAllocated.
persistent ghost bool ghostMintOutsideAllocation {
    init_state axiom !ghostMintOutsideAllocation;
}
/// Set if mintMotifs is ever called for a bidder other than the transaction's sender.
persistent ghost bool ghostMintForOther {
    init_state axiom !ghostMintForOther;
}
persistent ghost address ghostTxSender;
/// Number of mintMotifs calls (one per credit range a claim touches).
persistent ghost mathint ghostMintCalls {
    init_state axiom ghostMintCalls == 0;
}
/// Number of 1/1 mints, and the last 1/1 recipient.
persistent ghost mathint ghostPrizeMints {
    init_state axiom ghostPrizeMints == 0;
}
persistent ghost address ghostPrizeTo;

function cvlMintMotifs(address to, address bidder, uint256 firstId, uint256 quantity) {
    bool receiverAccepts;
    if (!receiverAccepts) {
        revert("motif receiver rejected the token");
    }
    ghostMintCalls = ghostMintCalls + 1;
    ghostMotifsMinted = ghostMotifsMinted + quantity;
    ghostMotifsMintedFor[bidder] = ghostMotifsMintedFor[bidder] + quantity;
    if (firstId == 0 || firstId + quantity - 1 > to_mathint(currentContract.motifsAllocated)) {
        ghostMintOutsideAllocation = true;
    }
    if (bidder != ghostTxSender) {
        ghostMintForOther = true;
    }
}

function cvlMaxMintBatch() returns uint256 {
    return 64;
}

/// The 1/1 mints, counted from the stand-in's own storage writes (hooks do not fire on havoc, and a
/// mint that reverts writes nothing).
hook Sstore prize.mints uint256 newValue (uint256 oldValue) {
    ghostPrizeMints = ghostPrizeMints + newValue - oldValue;
}
hook Sstore prize.lastTo address newValue {
    ghostPrizeTo = newValue;
}

// ------------------------------------------------------------------ ETH sent by the auction

/// ETH the auction sent in successful CALLs, in total and per recipient. Persistent: the unresolved
/// transfer must not havoc them, and the auction never reverts after a successful payment.
persistent ghost mathint ghostEthSent {
    init_state axiom ghostEthSent == 0;
}
persistent ghost mapping(address => mathint) ghostEthSentTo {
    init_state axiom forall address a. ghostEthSentTo[a] == 0;
}
hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (executingContract == currentContract && value > 0 && rc != 0) {
        ghostEthSent = ghostEthSent + value;
        ghostEthSentTo[addr] = ghostEthSentTo[addr] + value;
    }
}

// ------------------------------------------------------------------ ledger sums

/// Mirrors of the two per-address ledgers, kept equal to storage by the hooks below, so that their
/// totals can be taken with `usum` (which also knows that a total is at least any one entry).
/// Persistent: the unresolved ETH transfer must not havoc them.
persistent ghost mapping(address => uint256) mirrorRefunds {
    init_state axiom forall address a. mirrorRefunds[a] == 0;
    init_state axiom (usum address a. mirrorRefunds[a]) == 0;
}
hook Sstore refunds[KEY address a] uint256 newValue {
    mirrorRefunds[a] = newValue;
}
hook Sload uint256 value refunds[KEY address a] {
    require mirrorRefunds[a] == value, "mirror equals storage";
}

persistent ghost mapping(address => uint256) mirrorCredits {
    init_state axiom forall address a. mirrorCredits[a] == 0;
    init_state axiom (usum address a. mirrorCredits[a]) == 0;
}
hook Sstore motifCredits[KEY address a] uint256 newValue {
    mirrorCredits[a] = newValue;
}
hook Sload uint256 value motifCredits[KEY address a] {
    require mirrorCredits[a] == value, "mirror equals storage";
}

definition sumRefunds() returns mathint = usum address a. mirrorRefunds[a];
definition sumCredits() returns mathint = usum address a. mirrorCredits[a];

/// number of registered wallets
persistent ghost mathint countRegistered {
    init_state axiom countRegistered == 0;
}
hook Sstore registered[KEY address a] bool newValue (bool oldValue) {
    countRegistered = countRegistered + (newValue ? 1 : 0) - (oldValue ? 1 : 0);
}

// ------------------------------------------------------------------ assumptions

/// What the constructors enforce about the immutables (EnglishAuction, KilimAuction and, for the
/// cap, KilimMotifs). Sound to assume in any state: immutables never change after deployment.
function configOk() {
    require reservePrice() == 10^16, "constructor: reservePrice == REGISTRATION_BALANCE";
    require incrementBps() >= 1 && incrementBps() <= 10000, "constructor: 1 <= incrementBps <= MAX_BPS";
    require duration() <= 30 * 86400, "constructor: duration <= 30 days";
    require extensionWindow() >= 1 && extensionWindow() <= duration(), "constructor: 0 < window <= duration";
    require treasury() != 0 && treasury() != currentContract, "constructor: treasury valid";
    require motifCap() >= 1 && motifCap() <= max_uint32, "KilimMotifs constructor: 0 < cap <= uint32 max";
    require maxMotifsPerBid() >= 1 && maxMotifsPerBid() <= motifCap(), "constructor: 0 < maxMotifsPerBid <= cap";
    require motifs() != currentContract && oneOfOne() != currentContract, "token contracts are separate deployments";
    require motifs() != 0 && oneOfOne() != 0, "constructor: token contracts have code";
    require treasury() != motifs() && treasury() != oneOfOne(), "constructor: treasury is not a token contract";
}

/// A real transaction: not sent by the auction to itself from outside its own code paths (its two
/// self-calls are inlined where bid() and settle() make them), not from address(0), and with a
/// timestamp that fits the uint64 the contract stores.
function requireRealCaller(env e) {
    require e.msg.sender != currentContract, "the auction only calls itself from inside bid/settle";
    require e.msg.sender != 0, "no transaction comes from address(0)";
    require e.block.timestamp <= max_uint64, "timestamps fit in uint64";
    ghostTxSender = e.msg.sender;
}

definition isBid(method f) returns bool = f.selector == sig:bid(uint256,uint256,uint256).selector;
definition isSettle(method f) returns bool = f.selector == sig:settle().selector;
definition isWithdrawRefund(method f) returns bool = f.selector == sig:withdrawRefund(address).selector;
definition isWithdrawProceeds(method f) returns bool = f.selector == sig:withdrawProceeds(address).selector;
definition isClaimMotifs(method f) returns bool = f.selector == sig:claimMotifs(uint256,address).selector;
definition isClaimPrize(method f) returns bool = f.selector == sig:claimPrize(address).selector;
definition isRegister(method f) returns bool =
    f.selector == sig:register().selector || f.selector == sig:registerFor(address,uint256,bytes).selector;
definition isSelfCall(method f) returns bool =
    f.selector == sig:payOutbidRefund(address,uint256).selector || f.selector == sig:deliverPrize().selector;
/// An external entry point of the auction that a real transaction can use: not the stand-in's mint
/// (the real KilimOneOfOne.mint only accepts the auction), not the two self-calls.
definition auctionEntry(method f) returns bool = f.contract == currentContract && !isSelfCall(f);
