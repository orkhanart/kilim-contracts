# Kilim internal security review

**Review dates:** September 18 and 26, 2026 and October 9, 2026 UTC; October 10, 2026 for the ETH-only re-audit and the attack research. The split of 10 October had its review round the same day; October 10 and 11, 2026 for the final audit before the freeze, the last section.
**Disposition:** Development implementation. **Not approved for a real-money launch.**
**Reviewers:** Claude instances only: the agent that implemented the contracts, then separate review sessions and multi-agent review rounds with adversarial verification and mutation testing. This is not an independent audit, formal verification, or a guarantee of zero vulnerabilities. An independent human audit of the frozen commit is required before funding (K-08).

The auction is native ETH only. Bids, refunds and proceeds are ETH; there is no other currency in the contracts. [docs/NATIVE-ETH.md](docs/NATIVE-ETH.md) describes the behaviour.

**How to read this file.** Each section describes the code as it stood on its date and keeps that code's names, so the sections up to "October 2026 attack research" say symbols, `Kilim.sol`, the renderer, weaving, materials and the page-owner role. Since 10 October 2026 the contracts are `KilimMotifs` (Motif Bazaar), `KilimOneOfOne` (The Unwoven Kilim) and `KilimAuction` over `EnglishAuction`; symbols are motifs; `Kilim.sol`, the renderer, weaving, materials and the owner role no longer exist. The last section, "10 October 2026: the split", says which of the older findings and measurements still apply, which moved and which closed; nothing above it has been rewritten.

## Scope and evidence

- `src/auction/EnglishAuction.sol`: the auction base, with registration, ETH escrow, refunds and the thirdweb bid predicate.
- `src/KilimAuction.sol`: symbol credits, bid-time ID reservation, claims, the 1/1.
- `src/Kilim.sol`: the ERC-721 collection, composition, royalties, the page-only owner role, renderer forwarding.
- `src/render/KilimRenderer.sol`, `src/render/KilimWriter.sol`, `src/render/IKilimRenderer.sol`: the on-chain renderer and its data store.
- `script/DeployKilim.s.sol` and `deploy/*.json`: deployment and its preflight refusals.
- `onchain/pack_store.py` and `onchain/render_ref.py`: the store packer and the byte-exact reference renderer.

Exact source and build hashes are in `audit/build-manifest.json`. The auction base retains thirdweb's `_isNewWinningBid` predicate from the source identified in the 0xMacro A-15 report; the build checks that the retained function and denominator have not changed. [REUSE.md](REUSE.md) records provenance, license and behavioural changes.

Three rounds, each on the code as it stood then:

- **September 18 and 26.** Manual review; six review lenses (auction, collection, renderer, deploy, site, mutation) with two adversarial verifiers per medium-or-higher finding; stateful fuzzing with hostile re-entrant receivers; differential testing of the renderer against the Python reference; pixel comparison of the renderer's images with the site's drawing code; Slither 0.11.5; npm advisory scanning; the Solidity compiler's published bug list. The collection and the renderer have not changed since. The auction has.
- **October 9.** The full audit of the native-ETH auction: eight lenses, 27 merged findings, each checked by a refuter and, above info, a Foundry reproduction. See the next section and [audit/full-audit-2026-10-09.md](audit/full-audit-2026-10-09.md).
- **After October 9.** The auction was reduced to ETH only: everything the audit had read that did not belong to the ETH path was deleted, and the queue that minted symbols on a bidder's behalf went with it. That removal was checked by the build, the tests, the formatter and Slither. **No review round has read the result.**

Not covered: deployed bytecode, live wallets beyond the test wallet, marketplace rendering on a real marketplace, legal terms, or a mainnet deployment. No transaction was broadcast and no private key was used.

## Launch configuration under review

Ethereum mainnet (chain 1), native ETH.

- **Registration.** From `startsAt`, the first 100 wallets register with `register()` or, through a sponsor, `registerFor(wallet, deadline, signature)`. A wallet must hold at least 0.01 ETH when it registers; nothing is deposited. Bidding opens only when the count is exactly 100.
- **Bids.** `bid` is payable and `msg.value` must equal the bid. The opening bid is 0.01 ETH. Each new bid is at least 10% higher, rounded up to a whole 0.001 ETH: 0.01, 0.011, 0.013, 0.015, 0.017 and so on.
- **Clock.** The 24-hour clock starts at the first bid. A bid in the last 10 minutes moves the close to 10 minutes after it, with no limit. With no bids the auction never ends.
- **Symbols.** Every accepted bid earns one symbol credit per 0.001 ETH, including bids later outbid, up to 1,000,000 symbols in total and with no smaller per-bid cap. The bidder mints them with `claimSymbols`, up to 64 per transaction. Nothing mints symbols for a bidder.
- **Refunds and the 1/1.** The outbid bidder is paid back inside the bid that beats theirs; `withdrawRefund` is the fallback. `settle()` sends the 1/1 to the winner; `claimPrize` is the fallback.
- **Roles.** Treasury and collection page owner: orkhanart.eth, `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`. The treasury withdraws the winning bid and cannot bid. Royalties 5% (ERC-2981). Art fully on-chain.

The deploy script refuses any other auction setting on chain 1.

## October 9, 2026 audit

Source: [audit/full-audit-2026-10-09.md](audit/full-audit-2026-10-09.md), with evidence, proof-of-concept sources and suggested fixes in `audit/full-audit-2026-10-09.json`. Finding numbers below are that report's.

### Fixed, with tests

| ID | Severity | Finding | Fix | Test |
| --- | --- | --- | --- | --- |
| F-01 | High | The current top bidder could make a rival's bid run out of gas by switching its refund receiver between cheap and gas-burning after the rival's wallet had estimated gas. | `_refundOutbid` reverts with `InsufficientGas` unless the bid still carries `REFUND_GAS + REFUND_GAS / 63 + 60_000` gas. The gas a bid needs no longer depends on the outbid wallet's code. | `test/GasFloors.t.sol`: `testLeaderCannotMakeARivalsBidRunOutOfGas`, `testABidWithTooLittleGasFailsTheSameWayWhateverTheLeaderDoes` |
| F-02 | Medium | A `settle()` call with little gas skipped sending the 1/1. A contract winner that cannot call `claimPrize` would have lost it. | `_afterSettle` reverts with `InsufficientGas` unless `PRIZE_GAS + PRIZE_GAS / 63 + 50_000` gas is left. The revert undoes the settlement and anyone can call `settle()` again. | `test/GasFloors.t.sol`: `testLowGasSettleCannotSkipThePrize` |

`REFUND_GAS` is 150,000 and `PRIZE_GAS` is 500,000.

### Accepted by the artist on October 9

These are properties of the design. They were confirmed, reproduced and left as they are. Each must be said plainly to bidders.

- **F-04 (Medium): one wallet can take the whole symbol pool for gas.** A wallet that outbids itself gets its ETH back when outbid and keeps every symbol it reserved. Climbing the minimum steps from 0.01 ETH, 93 bids reserve all 1,000,000 symbols and end with a top bid of about 93.9 ETH. A wallet that does this and is then outbid has paid only gas. If nobody outbids it, it has bought the 1/1 at that price. This is K-01 with the ETH numbers.
- **F-03 (Medium): one actor can fill the 100 registrations and choose when the clock starts.** Registration checks a balance, not a person. The same 0.01 ETH can be passed through 100 addresses in one transaction the moment `startsAt` passes, and the opening bid can follow in that transaction. Registration therefore protects nothing and reserves no place for real supporters.
- **F-10 (Low): bidding never opens below 100 registrations.** There is no fallback date. If the count stops at 99, the auction stays closed for good. The artist will keep promoting until the count is reached.

### Open

Not fixed. Each is either a decision to take before the code is frozen, a test to add, or something the site, the sponsor service or the runbook must handle.

| ID | Severity | Finding |
| --- | --- | --- |
| F-05 | Medium | No test pins the upper bound of `REFUND_GAS` or `PRIZE_GAS`. Tests now show that a gas-burning refund receiver is deferred and a gas-burning winner falls back to `claimPrize`, but none asserts a ceiling on the gas used, so both caps could still be raised and the tests would pass. |
| F-06 | Low | An outbid contract bidder can make each rival pay about 140,000 to 180,000 extra gas per bid, because `REFUND_GAS` is far more than a normal ETH receiver needs. |
| F-07 | Low | A self-outbid ladder placed in front of someone's pending jump bid farms symbols at no risk. Follows from F-04. |
| F-08 | Low | `registerFor`: the ERC-1271 check has no gas cap and signatures can be copied from the mempool, so an attacker can burn the sponsor's gas and budget. A matter for the sponsor service. |
| F-09 | Low | Wallets with code (EIP-7702-delegated accounts, some smart accounts) cannot use the sponsored path, and the site offers no direct `register()` button when a sponsor is configured. |
| F-11 | Low | The `registered` flag means nothing on-chain and can be captured by one actor. Never build a perk or an allowlist on it. |
| F-13 | Low | The page-owner key can change the royalty receiver or point the collection page at a hostile link. |
| F-14 | Low | The deploy script does not pin the motif set or measure `tokenURI` read gas. The packed store still has 812 motifs while the decision is 1,024. |
| F-18 | Low | No test rebuilds the EIP-712 domain and type string for `registerFor` independently. |
| F-19 | Info | Forced ETH is locked for good. So is a refund owed to a bidder contract that can neither receive ETH nor call `withdrawRefund`. |
| F-21 | Info | `payOutbidRefund` and `deliverPrize` rely only on `msg.sender == address(this)`. `deliverPrize` has no `settled` check of its own. |
| F-22 | Info | Registration signatures have no upper bound on `deadline` and cannot be revoked. They can only register the signing wallet. |
| F-23 | Info | Once the count is 100, any wallet except the treasury can bid, registered or not. Intended. |
| F-24 | Info | A bid has no deadline. A pending transaction can land much later at the amount the bidder signed. |
| F-26 | Info | On chain 1 the script accepts any nonzero inspection window, and config integers are narrowed without a range check. |
| F-27 | Info | Small surviving mutants: the deadline boundary, the `Registered` count, a 2,300-gas ETH payout, refund and collect order, the `withdrawProceeds` guard. |

### Closed by tests added after the audit

- **F-15.** `test/KilimAuction.t.sol`, `test/LaunchConfig.t.sol`, `test/Lifecycle.t.sol` and `test/AuctionInvariants.t.sol` now run against the ETH auction: extension and close, increment and unit, the treasury ban, prize delivery and its fallback, deferred-refund accounting, and stateful invariants with receivers that reject ETH, burn gas or refuse NFTs.
- **F-16.** `testRegistrationIsClosedBeforeStartsAt` and `testTreasuryCannotRegister` in `test/SponsoredRegistration.t.sol`. `register()` and `registerFor()` revert with `RegistrationClosed` one second before `startsAt` and succeed at `startsAt`. A treasury registration reverts with `TreasuryCannotBid` on both paths. Removing either check from the contract makes the matching test fail.
- **F-17.** `testConstructorRejectsInvalidConfiguration` refuses a reserve above, below and a whole-unit multiple away from 0.01 ETH.

These tests were written by Claude instances after the audit and have not been reviewed.

### Closed by removing code

- **F-12** concerned the queue that minted symbols for bidders. It is deleted.
- **F-20** concerned the same queue being written on every bid, and a README that said symbols arrive by themselves. The queue is deleted and the docs say bidders claim.
- **F-25** concerned checklists that described another launch. They are rewritten for ETH: see `checklists/`.
- The parts of F-16 and F-17 that named the removed mode no longer apply.

### Still a launch blocker

**An independent human audit.** The October 9 audit was done by Claude instances. It is not independent, and it read the code before the removal. See K-08.

## Open findings

### K-01 — High economic risk, accepted by owner: refundable bids earn permanent rewards

Location: `KilimAuction.bid()` and `rewardForBid()`.

A bidder keeps symbol credits after getting all of their losing ETH back. Cooperating wallets can alternate rising bids and recycle refunds, and a single wallet can outbid itself. The 1,000,000 cap is binding: along the minimum steps the pool is exhausted at the 93rd bid, about 93.9 ETH (F-04 above). After that, bids still count for the 1/1 and earn no symbols. When bids climb in minimum steps, the symbols issued are about 11 times the final price counted in 0.001 ETH.

**Status:** Accepted by the owner (September 18 and 25, and again on October 9, 2026, for the ETH numbers) as the intended incentive. Nonrefundable purchases, increment-only rewards and winner-only rewards were offered and declined. Disclose the mechanism plainly; do not advertise 0.001 ETH of net revenue per symbol.

### K-02 — Medium, reduced: symbol traits are public and deterministic

Location: `Kilim.symbolTraits()`, `KilimAuction.bid()`.

Traits depend only on the chain ID, collection address and token ID; they are public at deployment through `symbolTraits(id)` and recomputed on every read rather than stored. Each bid reserves the next IDs in allocation order and claims mint exactly those IDs, so wallet choice, claim time, order, recipient and receiver retries do not affect what a bidder receives, and rare supply is fixed.

Residual risks: rarity is a public race (bidders can time and size bids to cover rare IDs, zero-sum between bidders); a bid that lands first moves later bids to different IDs (`expectedFirstSymbolId` lets a bidder revert instead); and the deployer's choice of address fixes the whole layout. Publishing the deployer and nonce beforehand gives everyone the same information but does not prove the layout was not chosen.

**Status:** Deterministic, public traits remain by owner decision (no VRF). The site states this.

### K-03 — Launch blocker, reduced: the on-chain renderer needs an independent review and the final symbol set

Location: `src/render/*`, `Kilim.tokenURI`.

Built: geometry, index and the 1/1 page live on-chain in seven SSTORE2 data contracts. `KilimRenderer` verifies them in its constructor against `geometryHash`, `indexHash` and `pageHash`, and draws every image and metadata document. `Kilim` checks the renderer's code hash, motif count and geometry hash, and forwards its answers. `appearance` is an allow-list of three values. See `docs/RENDERER.md` (removed with the renderer on 10 October 2026; [docs/STORAGE.md](docs/STORAGE.md) describes what replaced it).

Open:

- **Assembly.** `KilimWriter` and parts of `KilimRenderer` write memory by pointer for gas reasons. Every writer documents its overrun and slack, and exact-length postconditions guard every document; two review rounds found no defect. This is exactly the code that most needs an independent human review.
- **Read cost.** Reading the 1/1 costs about 22.4M gas and the heaviest possible artwork about 30.4M. Some public RPC endpoints cap `eth_call` at 25M, so those artworks would show blank there; marketplaces use their own infrastructure. Symbols cost at most about 0.48M.
- **Content.** The symbol set is not final: the decision is 1,024 motifs and the packed store holds 812. The packer enforces format and scale limits and prints the remaining budget: about 90 more median-size symbols before the 1/1 reaches 24M, which is far fewer than the 212 still to add. Only symbols the artist has rights to may go on-chain; some research images are third-party reference material.
- **Look.** The artist has not yet approved the rendered palette, still image, names and descriptions, and no real marketplace has displayed the media yet.

### K-05 — Low: timing relies on block timestamps, and extensions have no absolute end

Registration opens at `startsAt`, bidding opens at the 100th registration, the close is set by the first bid, and each late bid moves it to 10 minutes after that bid, with no limit; the only bound is the uint64 timestamp. Timestamps are never used as entropy. A network outage near the close may prevent a bid being answered; there is no administrator restart or cancellation. With no bids, `settle()` reverts with `NoBids` and the 1/1 is never minted.

**Status:** Documented behaviour. The Slither timestamp findings are retained, not suppressed.

### K-06 — Low: ETH that arrives outside a bid has no recovery path

The auction has no `receive` or fallback function, so a plain transfer reverts. ETH forced in (for example by a self-destructing contract) creates no refund, credit or proceeds, and there is no rescue function, so it stays locked. This avoids any administrative path to the ETH that backs refunds and proceeds.

**Status:** Deliberate. The only way to pay is `bid()`.

### K-07 — Medium trust risk, partly mitigated: seller self-bidding

The treasury address cannot bid or register (`TreasuryCannotBid`). A seller can still bid from other wallets; that is undetectable on-chain.

**Status:** Disclosure matter.

### K-08 — Launch blocker: independent audit, rehearsal and deployment inputs

Still required before funding:

- an independent human audit of the frozen commit, covering the ETH auction after the removal and with the renderer's assembly as a priority;
- a Sepolia rehearsal through the website with real wallets, including the 100 registrations;
- the final symbol set and the resulting hashes, published before deployment;
- the published deployer nonce and an inspection window before `startsAt`.

### K-09 — Launch blocker, reduced: the automatic refund and prize delivery have had one internal round and no independent one

Location: `EnglishAuction._refundOutbid()` / `payOutbidRefund()`, `KilimAuction._afterSettle()` / `deliverPrize()`.

An outbid bid is paid back inside the bid that beats it, through a call the auction makes to itself with 150,000 gas. Any failure (a wallet that rejects ETH, a receiver that burns the gas) is caught: the amount is recorded in `refunds`, `RefundDeferred` is emitted and the bidder calls `withdrawRefund(to)`. An address that cannot receive ETH therefore never blocks bidding. Settlement sends the 1/1 to the winner through a self-call with 500,000 gas; if the winner's wallet rejects it, `settle()` still succeeds, `PrizeDeliveryFailed` is emitted and the winner calls `claimPrize(to)`.

Both self-calls are external functions callable only by the auction (`Unauthorized` otherwise), and every state-changing entry point is `nonReentrant`. Both now have a gas floor (F-01, F-02).

Residual risks: the caps are larger than needed (F-06) and their upper bounds are untested (F-05); a legitimate contract wallet with an expensive receiver is deferred and withdraws or claims by hand.

**Status:** Read by the October 9 audit. Not read by anyone since the removal, and never by an independent reviewer.

## Retired findings

- **K-04, issuer controls of the payment currency** (pause, blacklist, upgrade, transfer fees). Retired. The auction holds ETH only. No issuer can pause, freeze or change what the escrow holds, and there is no transfer that can take a fee.
- The parts of K-06 and K-09 about donated tokens and about minting symbols on a bidder's behalf. Retired with the code.

## Protections

Verified on the September 26 build and unchanged since, because `Kilim.sol` and `src/render` did not change:

- **Supply and IDs.** Each symbol ID is reserved once at bid time and minted once, and a burned ID can never be minted again. Symbol, artwork and 1/1 IDs are disjoint. Only the immutable auction can mint, and the 1/1 mints at most once.
- **Composition.** Approved operators cannot weave, expand or freeze someone else's tokens. Duplicate, missing, foreign or already-burned sources revert atomically, and expansion keeps every earlier source exactly once. Artwork cells are packed 8 per storage slot and unpack exactly.
- **Page owner role.** It can only edit collection text and links, change the royalty receiver, and hand over or renounce the role. It cannot mint, move or burn tokens, change art, or touch funds. Collection JSON is escaped.
- **Renderer.** It is byte-identical to the Python reference for every motif path, every symbol, 46 artwork layouts in all three looks, the 1/1 still and page, and every metadata document, plus 70 random differential cases. Its images match the site's drawing code within anti-aliasing for all 812 symbols and all 46 artworks. It works unchanged for stores of 700 and 912 motifs, and every store corruption case is refused.

Covered by tests that run against the ETH-only auction today:

- **Registration** (`test/NativeRegistration.t.sol`, `test/SponsoredRegistration.t.sol`). A wallet below 0.01 ETH and a duplicate are refused, and so are a registration before `startsAt` and one by the treasury. Bids before the 100th registration revert. The 100th registration takes no deposit, earns nothing and does not start the clock; the 101st reverts. A signature cannot be replayed on another chain or auction, changed to another wallet or deadline, or used after its deadline. Direct and sponsored registration share one replay guard.
- **Payment.** A bid whose `msg.value` differs from its amount reverts and changes nothing. Refunds and proceeds are paid in full. A receiver that rejects ETH neither blocks bids nor loses its refund. Nobody but the auction can call the refund self-call, and callbacks cannot re-enter.
- **Gas floors** (`test/GasFloors.t.sol`). See F-01 and F-02 above.

- **Bid rules, clock and settlement** (`test/KilimAuction.t.sol`, `test/LaunchConfig.t.sol`, `test/ReuseRegression.t.sol`). `minimumBid()` is the smallest accepted whole-unit bid; the launch ladder starts 0.01, 0.011, 0.013 ETH; a late bid never brings the close forward, including at the last second; with no bids nothing settles; the treasury cannot bid; a winner that rejects the 1/1 or burns gas cannot block settlement or proceeds.
- **Solvency** (`test/AuctionInvariants.t.sol`). Under stateful fuzzing with hostile receivers the balance always covers `liabilities()`, credits are never created twice or above the cap, and reserved IDs match credits.
- **Deployment** (`test/DeployKilim.t.sol`). The script's refusals, and the pinned chain-1 values.

These auction tests were ported from the September suite to the ETH-only contracts after the October 9 audit. They pass; no review round has read them.

## Verification results

- **Tests, October 9, after the removal:** the forge suite ran 19 suites in the default profile and in the `ci` profile, **236 tests passed, 0 failed** in each. That is a working-tree result, not a frozen commit. Rerun `pnpm test:ci` at the freeze and record it; counts quoted in older logs under `audit/` belong to earlier code.
- **Slither** on the ETH-only sources: **no high or medium findings**, 9 low and 39 informational.
  - Low: 5 timestamp comparisons, 2 events emitted after a call, 1 benign reentrancy (the deferred-refund bookkeeping after the guarded self-call) and 1 calls-loop in `claimSymbols` (one call per reserved range, bounded by the 64-symbol batch).
  - One suppression, on `_pay`: Slither reports that the ETH recipient is chosen by the caller. Every caller pays only what is owed: an outbid bidder's own bid, a refund to the address its owner names, or the proceeds to the address the treasury names.
- **Mutation testing:** no full run on the ETH-only auction. A hand check on October 9 changed 22 single lines of the auction, one at a time (the payment equality, both gas floors, the refund ledger, the extension rule, bid rounding, the treasury and registration gates, the self-call guards, settlement timing, the reserve rule). Every one fails at least one test; the two registration gates of F-16 survived until its tests were added. The September result (169 of 177 killed, the rest equivalent, in `audit/mutation.txt`) covers the collection and renderer as they are and an auction that has since changed. F-27 lists the mutants the October 9 audit found alive.
- **Gas**, measured September 26 (execution before refunds). The claim path, the collection and the renderer have not changed since; re-measure on Sepolia.

  | Action | Gas |
  | --- | --- |
  | 64-symbol claim | 1,837,603 |
  | 64-symbol claim across three bids | 1,929,492 |
  | 256-cell weave | 9,771,795 |
  | 4-to-256-cell expansion | 9,469,352 |

  A bid that outbids someone must still have about 212,000 gas left when it reaches the refund, or it reverts with `InsufficientGas`. A `settle()` call must have about 558,000 left at the prize step.

  Reads through `tokenURI`:

  | Token | Gas |
  | --- | --- |
  | Median symbol | about 0.18M |
  | Worst symbol | 0.48M |
  | Heaviest 16 × 16 artwork | 30.4M |
  | The 1/1 | 22.4M |

  A full deployment is about 45.9M gas, with every transaction under 8M. Details are in `audit/gas-render.txt`.
- **Sizes** (bytes; runtime limit 24,576, initcode limit 49,152), from `audit/build-manifest.json`:

  | Contract | Runtime | Initcode |
  | --- | --- | --- |
  | Kilim | 15,314 | 17,031 |
  | KilimRenderer | 17,007 | — |
  | KilimAuction | 10,967 | 30,349 |

- **Records:** `audit/full-audit-2026-10-09.md` and `.json`, `audit/slither-summary.json`, `audit/build-manifest.json`, `audit/mutation.txt`, `audit/gas-render.txt`, `audit/dependency-audit.json`. The other logs under `audit/` are dated records of earlier builds and are not regenerated.

These are local EVM tests and internal reviews. They do not prove the absence of bugs, and they are not a substitute for K-08.

## Primary references

- [Solidity 0.8.37 release](https://www.soliditylang.org/blog/2026/09/10/solidity-0.8.37-release-announcement/). The bug list snapshot in `audit/compiler-bugs.json` had no entry applicable to 0.8.37 at review time.
- [OpenZeppelin ERC-721](https://docs.openzeppelin.com/contracts/5.x/api/token/erc721) and [EIP-712 and signature checking](https://docs.openzeppelin.com/contracts/5.x/api/utils/cryptography).
- [thirdweb A-15 audit and exact reference hashes](https://0xmacro.com/library/audits/thirdweb-15), its [preceding A-6 review](https://0xmacro.com/library/audits/thirdweb-6), and the [historical buyout incident report](https://blog.thirdweb.com/2023-09-09-vulnerability-auctions-with-a-buyout-price/). None of them audits this adaptation.
- [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825), the per-transaction gas cap of 16,777,216.

## October 10, 2026 re-audit (ETH-only)

After the token mode was removed, three reviewers re-read the contracts: one compared every ETH path line by line with the version audited on October 9 and found no behaviour change beyond lower gas; one re-derived funds, re-entry and liveness; one mutation-tested the ported suite. Twenty findings, listed in `audit/eth-only-reaudit-2026-10-10.md`. Fixed the same day:

- **R-06 (medium), fixed.** A holder could settle from inside a `weave` callback; the collection's own guard then rejected the prize mint and settlement stood without the 1/1. `Kilim.mintMasterpiece` no longer shares the collection's guard (it is auction-only and one-shot). Test: `testSettlingFromInsideAWeaveCallbackStillSendsThePrize`, which fails with the guard restored.
- **R-07 (medium, future fork), reduced.** The gas kept back for recording a deferred refund was 60,000 against about 47,000 used; a repricing of new storage (EIP-8037) would exceed it and reopen F-01. The reserve is now 300,000. Re-measure on any new fork's rules before deploying.
- **R-08 (low), fixed in the site.** The page sets the gas limit itself for a bid (800,000) and for settle (900,000), and explains `InsufficientGas` in plain words.
- **R-13 (low), fixed.** `testProceedsCannotGoToAnInvalidRecipient`.

Test gaps closed on October 10 in `test/AuditGaps.t.sol` (13 tests): upper and lower bounds on both gas constants and the settle floor (F-05, R-11, R-12), re-entry through `withdrawProceeds` and `claimPrize` (R-14), the EIP-712 domain and type string rebuilt independently (F-18, R-15), the self-call entry points against every caller (R-16), the `Registered`, `AuctionStarted` and `AuctionSettled` events and a first bid that refunds nobody (R-17), constructor and deadline edges (R-18), and registration before the start or by the treasury (F-16). Twenty-five single-line mutants of those checks were applied one at a time; the suite fails on every one. Leftover code removed the same day, with no change in behaviour (all suites and the 25 mutants re-run): the unreachable `startsAt` clause and the implied `settled` clause in `_handleBid` (R-03), the `duration == 0`, `symbolCap == 0` and `symbolCap > uint64 max` clauses that other checks already cover, the unused `bidder` argument of `_claim`, and four stale comments (R-04). Kept on purpose as a second line of defence, although other checks imply them today: the zero-address test in `registerFor` (it relies on the zero address having no code), `_validateRecipient` in `claimPrize` (the collection checks the same, later), and `nonReentrant` on `register` and `registerFor`. `reservePrice` stays a constructor value that accepts only 0.01 ETH, because the site and the deploy script read it. None of this code has had an independent human review; that remains a launch blocker.

## October 2026 attack research

A web research pass on exploits and audit findings from 2024 to October 2026 against contracts of this shape, with a 67-item checklist: `../reports/Auction contract attack patterns 2026.md` (notes in `../research_notes/`). No live mainnet NFT English auction was found exploited in that period. The contract was then tested against the checklist's contract items.

**Result: no new vulnerability.** `test/AttackPatterns.t.sol` (15 tests) adds the patterns that had no test:

- a deferred refund can be withdrawn only by its owner, once (the Bid Beasts 2025 drain);
- a return-data bomb from the outbid wallet or from the winner's NFT hook cannot make a bid or a settlement fail, even at a gas limit estimated with no margin. `settle` does not copy a hostile winner's revert data: a variant that does is caught by the test;
- an ordinary wallet's refund is never pushed to the pull path by a rival's choice of gas limit;
- nothing in the auction can be entered from the refund callback;
- a wallet that gains code after bidding (EIP-7702) cannot block bids or settlement, and still withdraws and claims;
- fifty bids in the closing window each move the close to exactly ten minutes after the bid; at the closing second only settlement is possible;
- malleable (high-s), compact and padded signatures are refused; a wallet with code cannot use the sponsored signature and registers directly (the site now routes such wallets to `register()`); hostile ERC-1271 wallets never register on a bad answer and cost the sponsor at most its gas limit;
- recorded, accepted behaviour: one transaction can fill all 100 registrations (7.8M gas) and anyone can then bid; a self-outbid ladder to a 1.06 ETH top bid earns 11,351 symbols against 1,060 for one honest bid.

`site/test/contract-static.test.mjs` pins that no contract logic depends on `tx.origin` or on a bidder's code, that nothing uses `delegatecall`, `selfdestruct`, `transfer`/`send` or forwards calldata, and the compiler and library versions.

**The fixed gas numbers at Glamsterdam prices** (scheduled, on Sepolia since 2026-10-06, no mainnet date; EIP-8037 values not final until its Last Call ends on 2026-11-01). Measured by counting the storage slots each path writes and re-pricing them (new slot 22,100 to 110,020 gas):

| Path | Today | At Glamsterdam prices | Fixed number |
|---|---|---|---|
| Recording a refund that could not be paid (two new slots) | about 50,000 | about 226,000 | 300,000 kept back |
| Prize delivery before the winner's hook (three new slots, one update) | 86,719 | 357,579 | 500,000 allowance |
| Gas left for a winner's `onERC721Received` | 413,281 | 142,421 | |

Both still work after the repricing; the delivery keeps enough for a Safe-style hook, not for one that writes two new slots. A further rise of about 40% in the price of a new slot would exhaust either. The failure mode is the fallback (pull refund, `claimPrize`), not loss, and a bidder can always send more gas than the minimum. The site now sends bids with 1,500,000 gas and settlement with 1,200,000.

**Open decisions from the research** (also in `checklists/1-pre-deploy.md`):

1. **`tokenURI` above 16,777,216 gas.** The 1/1 needs 22.4M gas and a 256-cell artwork 17.3M (typical) to 30.4M (heaviest). Reads work today. Under Glamsterdam rules Reth and Nethermind stop `eth_call` at 16,777,216 while geth and Erigon lifted the cap in the second week of October 2026; nothing binds the outcome. A token above the cap would show no metadata through those nodes, permanently, because the renderer is immutable. Keeping every token under the cap means a lighter 1/1 render and a smaller largest canvas (about 100 cells with today's symbols, which would also keep the largest weave inside one ordinary transaction after the repricing).
2. **Re-measure after EIP-8037 is final**, on Sepolia, before the auction is deployed; deploy the data store before Glamsterdam reaches mainnet (code deposit rises 7.65 times).
3. **One key holds the treasury and the collection page.** A compromise would take the proceeds and rewrite the collection's description and link together.
4. **Not built yet on the site:** a scheduled check that the served pages hash to the tagged build, a post-send check that the mined transaction is the one the page built, agreement between two RPC providers, and a raised priority fee for bids in the closing window.

## 10 October 2026: the split into Motif Bazaar, The Unwoven Kilim and the auction

Decided with the artist on 10 October and designed in [docs/CONTRACTS.md](docs/CONTRACTS.md): there is no arranging of motifs in a grid any more, so the single collection `Kilim.sol` with its SVG renderer was replaced by two small token contracts the auction mints into. The vocabulary changed with it: the 1,024 drawings and a bidder's tokens are motifs (first "glyphs", renamed to motifs the same day); "symbol" is gone. The sections above are written in the old names and are left as they were.

### What changed

- **`src/KilimMotifs.sol`, Motif Bazaar (`MOTIF`)**: up to `motifCap` tokens, ids `1..motifCap`, each showing motif `motifOf(id) = keccak256(abi.encode(chainid, address(this), id)) % 1024 + 1`. The 1,024 grids (32,768 bytes) and names live in SSTORE2 chunks whose keccak the constructor checks against `gridsHash` and `namesHash`. `mintMotifs` is minter-only and `nonReentrant`, batches of 1..64, each id once even after a burn (a bitmap); `burn` is owner-only, approvals do not count. `tokenURI` is a contract-drawn SVG with `Motif` and `Name` attributes; `contractURI`, 5% ERC-2981 to the royalty receiver. No owner role.
- **`src/KilimOneOfOne.sol`, The Unwoven Kilim (`UNWOVEN`)**: one token, id 1, minted once by the minter. The page is stored as three sections (PREFIX, HEAD, TAIL) in chunks hashed at construction; `tokenURI(1)` is assembled in one buffer in assembly with the grids read live from `KilimMotifs.grids()` ([docs/STORAGE.md](docs/STORAGE.md)). `mint` is deliberately not `nonReentrant` (R-06).
- **`src/KilimAuction.sol`**: `Config` loses `collectionOwner`, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`, `renderer` and `symbolCap` and gains `motifs` and `oneOfOne`. The constructor no longer creates a collection; it checks that both token contracts name this auction as `minter`, that the 1/1 reads this motif contract, that the treasury is neither, and reads `motifCap` from the collection. Names: `motifCap`, `maxMotifsPerBid`, `motifsAllocated`, `motifsClaimed`, `motifCredits`, `claimMotifs`, `unclaimedMotifRanges`, `MotifsClaimed`, `MotifRangeMoved`, `expectedFirstMotifId`, `firstMotifId`, `motifReward`. Motif ids start at 1 (no `FIRST_SYMBOL_ID`). `MAX_MINT_BATCH` is read from the motif contract. `deliverPrize` and `claimPrize` call `oneOfOne.mint`. `_validateRecipient` also refuses the two token contracts.
- **`src/auction/EnglishAuction.sol`**: only the constant's name (`SYMBOL_PRICE` → `MOTIF_PRICE`). The registration, bid, refund, extension and settlement code audited on 9 and 10 October is the same apart from that identifier.
- **`script/DeployKilim.s.sol`**: the chunks by CREATE2, then the three contracts from the artist's wallet at nonces n, n + 1 and n + 2 with the auction's predicted address as minter; the dry run compares both tokenURIs with the packers' goldens and measures their gas; chain 1 pins the deployer (orkhanart.eth) and the 1/1's name.
- **Packers**: `onchain/pack_motifs.py` and `onchain/pack_page.py` replace `pack_store.py`; `onchain/loader.html` gunzips the artwork in the browser and hands it the grids.
- **Names**, applied after the rewrite commit in the working tree: Motif Bazaar / `MOTIF`, The Unwoven Kilim / `UNWOVEN`; the deploy script refuses any other 1/1 name on chain 1.

### What was removed

`src/Kilim.sol`; `src/render/` (renderer, writer, interface) and every test under `test/render/`; `test/CompositionInvariants.t.sol`, `test/GasLimits.t.sol`, the renderer mocks and the `inspectArtwork` path of `test/mocks/Receiver.sol`; `scripts/render-geometries.mjs`, `gas-render.mjs` and `calibrate-gas.mjs`; the `test:render-*`, `gas:*` and `pack*` package scripts; `docs/RENDERER.md`; and in `onchain/` the old pipeline (`pack_store.py`, `render_ref.py`, `synth_geometry.py`, `pack.py`, `fit_gas_model.py`, `symbols.bin`, `symbols.b64`, `build/`, the old page sources and tests). With them: materials, appearances, cells, weaving, expanding and freezing, the page-owner role, `motifCount` and the renderer hash. `audit/gas-render.txt` and `audit/mutation.txt` are records of that earlier code.

### Findings that moved or closed with the removal

- **K-02**: which motif a token shows is now `KilimMotifs.motifOf(id)`. The residual risks (a public race for the ids that show a wanted motif, a bid landing first moves later ranges, the deployer's address fixes the layout) stand as written, with `expectedFirstMotifId` as the guard.
- **K-03** (the renderer's assembly, read cost, content and look): the renderer is gone. What replaces it for review is the assembly of `KilimOneOfOne.tokenURI` and the chunk readers of `KilimMotifs` (below). The read cost is no longer near any cap. The content is the 1,024 motifs of the artist's page, packed, with `motifCount` pinned at 1,024 by the packer and the script. The look of the motif token and the final artwork page are still to be approved by the artist.
- **F-13** (the page-owner key): closed. There is no owner role; the collection texts and the royalty receiver are fixed at construction.
- **F-14** (no motif pin, no read-gas ceiling): closed. The script refuses a store with other than 1,024 motifs, compares both tokenURIs with the goldens, and refuses a read above 8,000,000 gas.
- **R-06** (settling from inside a collection callback): re-targeted. `KilimOneOfOne.mint` has no guard, and the motif contract's guard covers only `mintMotifs`; `test/GasFloors.t.sol: testSettlingFromInsideAMotifCallbackStillSendsThePrize` settles from a motif transfer callback and the prize is delivered.
- **"`tokenURI` above 16,777,216 gas"** (open decision 1 of the attack research): closed by the design and the artist's 10 October rule (take the secure option). The 1/1 reads at 3,838,101 gas on the packed stand-in store, and the deploy script refuses anything above 8,000,000; there is no larger token.
- **"One key holds the treasury and the collection page"** (open decision 3): the page role is gone. The artist decided on 10 October that the same wallet, orkhanart.eth, deploys, receives the proceeds and the royalties; the script pins it on chain 1.

### What still holds, re-measured

The whole auction suite was re-targeted at the new contracts and names, and the measured numbers in its comments were re-measured rather than carried over:

- `test/AuditGaps.t.sol`, the gas a hostile wallet can cost others (F-05, R-11): a gas-burning leader costs a rival's bid "the refund's 150,000 cap plus the bid itself (about 128,000 today); a cap of 193,000 or more fails this" (asserted under 320,000); a gas-burning winner costs `settle()` "the delivery's 500,000 cap plus settlement itself (about 17,000 today); a cap of 583,000 or more fails this" (asserted under 600,000).
- `test/AuditGaps.t.sol`, what the constants really give a receiver (R-12): a winner's hook may use "389,005 of the 500,000 by a one-gas binary search on 10 October 2026 (the cold call into the 1/1, its minted flag, the safe mint and the auction's prizeClaimed take the rest)"; the test burns 388,000 and is delivered at every gas limit that settles, and "390,000 is not delivered". A refund receiver burning 120,000 is still paid inside the bid.
- `test/GasFloors.t.sol` (F-01, F-02): a leader cannot make a rival's bid, estimated with no margin, run out of gas by arming its receiver; a bid with 200,000 gas fails with `InsufficientGas` whatever the leader does; every settle gas limit from 60,000 to 700,000 either reverts with nothing settled or delivers the 1/1 to a pool whose hook writes five slots.
- `test/AttackPatterns.t.sol`, the Glamsterdam projections re-run on the new contracts: the deferred-refund path after the call projects to 225,840 gas (300,000 kept back); the prize delivery writes four new slots and updates none, a winner's hook may use 391,406 gas today and 39,726 at the projected prices (the 500,000 allowance still delivers to an ordinary wallet); filling all 100 registrations in one transaction costs 7,772,061; the self-outbid ladder to a 1.06 ETH top bid earns 11,351 motifs against 1,060 for one honest bid.
- Gas floors from the constants: an outbidding bid must reach the refund with `REFUND_GAS + REFUND_GAS / 63 + 300,000 = 452,380` gas, and a settle the prize step with `PRIZE_GAS + PRIZE_GAS / 63 + 50,000 = 557,936`. Measured as whole transactions on 10 October: an outbidding bid succeeds from **523,590** gas, `settle()` from **585,900**. The site sends 1,500,000 and 1,200,000.
- `test/KilimAuction.t.sol`: a 64-motif claim across three bids is **1,790,852** gas of execution (about 28,000 per motif); a claim mints exactly the reserved ids to the recipient; a settle that cannot deliver the 1/1 leaves settlement intact and `claimPrize` works; claims, refunds, proceeds and the prize all refuse the zero address, the auction and the two token contracts as recipients, and the collection refuses its minter, so no path puts a token or ETH into the auction or a token contract.
- Reads: `KilimOneOfOne.tokenURI(1)` **3,838,101** gas for 896,938 bytes on the packed stand-in store; `KilimMotifs.tokenURI` 287,311. Deployment: `KilimMotifs` 3,226,366, `KilimOneOfOne` 5,600,491, `KilimAuction` 3,150,749; a full chunk at most 5,876,690; the 38 chunks about 202.0M in all. Every transaction is under the 8M policy.
- Sizes from `audit/build-manifest.json` (creation / runtime bytes): `KilimMotifs` 13,343 / 10,808; `KilimOneOfOne` 12,062 / 9,921; `KilimAuction` 13,635 / 10,885.
- **Tests:** 188 forge tests at the rewrite commit, 0 failed; 189 with the name test added in the working tree (a run on 10 October counted 191 because another session had a two-test gas probe in `test/` at that moment); 78 site tests. Slither (`pnpm -s audit:static`): no high or medium; 10 low (5 timestamp comparisons, 2 events after a call, 1 benign reentrancy, 1 calls-loop in `claimMotifs`, 1 missing zero-check on `namesChunk`, which the constructor covers by reading the chunk's code), 25 informational (12 assembly, 6 too-many-digits in the encoders' masks, 5 naming, 1 dead code, 1 low-level call). `forge fmt --check` passes; `FOUNDRY_PROFILE=ci` passes; `pnpm -s deploy:dry` is green.

### What has not had an independent review

`KilimMotifs` and `KilimOneOfOne` are new code: the chunk readers, the names offset table, the SVG run encoder, the JSON escaping, the burn bitmap, and above all the one-buffer assembly of `tokenURI(1)` (in-place hex and base64 encoders with pointer arithmetic). The packers and the loader are new. The auction's changes are renames, the two external mints and, since the review round, `deliverPrizeToWinner`. All of it has now had one adversarial round by Claude instances (below). The independent human audit of K-08 is still required and covers these files first.

### Review round

**Run on 10 October 2026, written up the same night by a later session.** Six lenses read the split: the motif contract, the 1/1 contract, the auction's integration with both, the deploy script, the packers and the loader, and the site's use of the contracts. Each finding was to be checked by three verifiers (refute it, rate it, propose the fix and its test). The session that ran the round ended as it finished: 30 findings came back with their verdicts, and 42, mostly on the 1/1 contract and the packers, with none because the verifiers were cut off. Those 42 were checked by hand against the code by the session that wrote this, which also made the fixes. The round's raw results are kept outside the repository (`../kilim-archive/review-round-20261010/`); its proofs of concept are in the git history at commit `f92a2a73` under `contracts/test/poc/`. Reviewers and fixer were Claude instances: this is not the independent audit.

**Result: one high, eight medium, the rest low or informational; no way found to take funds or tokens, or to break the auction.** The high and most of the mediums were in the deploy script: things it would have sent to mainnet without complaint. The tests the round left behind are in `test/review/` and in the suites named below.

#### Fixed, with tests

| ID | Severity | Finding | Fix | Test |
| --- | --- | --- | --- | --- |
| V-01 | High | **The mainnet deploy pinned no content.** The script checked a store only against its own manifest, so whatever sat in `onchain/build-motifs` and `build-page` on deploy day would have gone on-chain for good, then the stand-in page and a placeholder picture. | The config names the content by hash in an `expected` block: five section hashes, both tokenURI goldens, and the sha256 of the artist's page, the artwork, the still and the loader. Chain 1 refuses a config without it, a zero in it and any mismatch, in both phases. `pnpm -s expected` prints it. | `DeployKilim.t.sol`: `testMainnetRefusesContentItsConfigDoesNotName`, `testAConfigThatNamesItsContentIsHeldToIt`, `testTemplatesCarryTheLaunchValuesAndFailClosed` |
| V-02 | Medium | The record of which file a store was packed from was never read. | Part of `expected` (V-01). | the same |
| V-03 | Medium | **The 1/1's page does not read `KILIM_GRIDS`.** The contract hands the page the motif grids on every read, and the documents said the 1/1 "provably draws the motifs the motif tokens show". The artwork ignores them and draws from its own copy. Nothing checked. | The packer records `artwork.readsGrids`; the deploy script refuses a page that does not read them on chain 1. **Still open on the artwork's side: the page has to be changed by the art session before mainnet.** | `test_pack.py`: `test_manifest_says_whether_the_artwork_reads_the_grids`; `DeployKilim.t.sol`: `testMainnetRefusesAnArtworkThatIgnoresTheGrids` |
| V-04 | Medium | The store phase was sent from the config's deployer, not from forge's `--sender`: on mainnet it would have spent 38 nonces of the artist's wallet and voided the published nonce and addresses. | `deployStore` sends from `--sender` and refuses when that is the deployer, a nonce is published and a chunk is missing. | `testTheStoreNeverSpendsAPublishedDeployerNonce`, `testTheDeployerMaySendTheStoreBeforeItsNonceIsPublished` |
| V-05 | Medium | The nonce check read the latest block; a transaction from the wallet still waiting in the pool was invisible and would have taken the published nonce. | The script also reads the pending nonce from the node and refuses when it differs. | `testContractsPhaseRefusals`, `testMainnetRefusesAPendingTransactionAndCompletesALostThird` (the node call is replaced in the test harness; to be exercised against a live node in the rehearsal) |
| V-06 | Medium | The deploy commands sent a phase as one burst; a lost first transaction would still have spent the next two. | The checklist commands carry `--slow` and `--timeout`, with what to do on a timeout or a dropped transaction. | Checklist only |
| V-07 | Medium | If only the third creation was lost, the checklist called the two token contracts void and told the deployer to start over, leaving two live contracts named Motif Bazaar and The Unwoven Kilim on mainnet. They are not void: the auction can still be deployed at the address they name. | `runAuction()` completes exactly that case after every check; the checklist says so. | `testCompletesADeploymentWhoseThirdCreationWasLost`, `testCompletingRefusesTokensThatAreNotTheOnesThisConfigDeploys` |
| V-08 | Medium | The collection's external link was pinned by nothing: no launch value, no manifest, no golden. | The motif packer records it and the script refuses a config that differs. | `testContractsPhaseRefusals`; `test_pack.py`: `test_manifest_records_the_link_and_any_identical_motifs` |
| V-09 | Medium | `pnpm test` never ran the packer or page tests, and nothing compared a packed store with its inputs, so a stale store passed the dry run. | `pnpm test` and `test:ci` run both; `pnpm deploy:dry` first runs `check:stores`; the fixture stores are checked by `test:pack`. | `test_pack.py`: `FixtureStoreTest` |
| V-10 | Low | `KilimMotifs`' constructor did not check the number of grid chunks that `grid()` relies on. Unreachable on a real chain (one chunk of 32,769 bytes is over the code size limit), but the contract should not lean on that. | The constructor refuses any count but two. | `KilimMotifs.t.sol`: `testOnlyTheTwoChunkLayoutIsAccepted` |
| V-11 | Low | `name(uint16)` overloaded ERC-721's `name()`: ethers v5 loses `contract.name()`, ethers v6 finds `name(n)` ambiguous. | Renamed `motifName(uint16)`. | `testTheMotifNameGetterDoesNotOverloadName`; site ABI test |
| V-12 | Info | `motifOf` hashed the live chain id, so a chain that changed its id after the auction (a minority fork) would have shown other motifs, against "fixed at deployment". | The chain id is recorded at deployment (`deploymentChainId`) and used from then on. | `testMotifsDoNotMoveWhenTheChainIdChanges` |
| V-13 | Low | The 1/1 could be transferred into the motif collection's contract, which can never send it on. | `KilimOneOfOne` refuses that recipient. A motif sent to the 1/1's contract is still lost, like a token sent to any contract that cannot move it: the motif contract is deployed first and does not know the 1/1's address. | `KilimOneOfOne.t.sol`: `testNoTransferReachesTheContractTheMinterOrTheMotifCollection` |
| V-14 | Low | The hook budget in the documents and in `AuditGaps` was measured with warm accounts; a mainnet `settle()` finds the 1/1 and the winner cold and leaves about 4,900 gas less. | Measured cold: `ColdPrizeBudgetTest` builds everything in `setUp`. Numbers below. | `AuditGaps.t.sol`: `testColdHookBudgetToday`, `testAColdWinnerNeedingMostOfTheCapIsDeliveredAtAnyGasLimit` |
| V-15 | Low to medium | **A winning contract whose receiver needs more than the 500,000 gas, and that cannot call `claimPrize`, never got the 1/1** (F-19 widened). Today that takes a receiver writing about seventeen new storage slots; after the Glamsterdam repricing, on the projected prices, one new slot is enough, which covers ordinary pools and vaults. | `deliverPrizeToWinner()`: after a settlement that could not deliver, anyone may send the 1/1 again with their own gas. It goes to the winner's address only, once, behind the auction's guard, and reverts with nothing changed if the wallet refuses it. `PRIZE_GAS` stays 500,000 until the final prices are known (after 1 November). | `GasFloors.t.sol`: `testAnyoneCanSendThePrizeAgainToAWinnerThatNeedsMoreGas`, `testSendingThePrizeAgainToAWinnerThatRefusesChangesNothing`, `testThePrizeIsNotSentAgainAfterTheWinnerClaimedIt`; the invariant handler calls it |
| V-16 | Low | The deploy script never looked inside PREFIX: a store edited after packing could carry `#` or `%`, which cut or change the token's data: URL. | The script refuses both bytes anywhere in PREFIX. | `testRefusesAPrefixThatADataUrlWouldCut` (a hand-edited fixture store) |
| V-17 | Low | The packer accepted an artwork that is not valid UTF-8 (the loader decodes it with losses) and an `animation_url` longer than Chromium opens. | Both refused. | `test_pack.py`: `test_refusals` |
| V-18 | Low | The gzip stream depends on the zlib build, so `--check` failed on another machine for the same page. | `--check` accepts a store that differs only in the deflate stream when it decompresses to the same artwork and everything else is identical; the published hashes are those of the store as packed. | `test_check_accepts_the_same_page_deflated_by_another_zlib` |
| V-19 | Low | `site-config` could verify a deployment block only on a node that still answers for that block (about 25 minutes on public nodes). | `--tx <creation transaction>`: the receipt gives the block on any node. | `site/test/chain.test.mjs`: "site-config verifies a deployment" |
| V-20 | Low | `.gitattributes` protected paths that no longer exist. | It now covers the chunk files, the loader, the fixtures and the artwork's release copy. | — |
| V-21 | Info | Three pairs of motifs are byte-identical with the same name: 147/590, 246/483, 482/613. | The packer reports and records them. **The artist decides** whether they stay; after deployment they cannot change. | `test_manifest_records_the_link_and_any_identical_motifs` |

Documents corrected with them: the treasury may receive tokens like any address (CONTRACTS.md said no path lets it); the gas floors are call gas limits, and a transaction needs about 21,000 more; the rehearsal uses the two phases, not `run()`; the R-06 comment on the 1/1's `mint`; the stale numbers of the stand-in page.

#### Open, for the web session (`site/`)

Confirmed by three verifiers each; none is in a contract. They are listed here so the list is in one place; the files belong to the web session.

| ID | Severity | Finding |
| --- | --- | --- |
| W-01 | Medium | **Fixed 10 October** (site review, [audit/site-security-review-2026-10-10.md](audit/site-security-review-2026-10-10.md)). Startup never asked the two token contracts who their minter is, so a config naming a rogue auction that answers `motifs()` and `oneOfOne()` with the real addresses passed, and bids would go to it. `site/chain.js` `init()` now reads `minter()` on both and refuses anything but the configured auction. `site/test/site-review.test.mjs` deploys `test/review/RogueAuction.sol` and shows the page stop. |
| W-02 | Medium | No public build can produce a bidding page: `site/build.py` still refuses a live chain ("Native ETH migration is pending"), and the live branch composes the read-only page. Would be fixed under pressure on deploy day. |
| W-03 | Low | **Fixed 10 October.** `guardWrite()` let `settle`, `withdrawRefund`, `claimPrize` and `register` be sent while startup had not verified the contracts yet (loss: gas). It now refuses every write until the immutables are read (`Startup`, "Still checking the contracts"); tested with a dead read node. |
| W-04 | Low | A `deployBlock` that is too late silently hides bids and holdings; the page never checks its book against the totals it reads. |
| W-05 | Low | **Fixed 10 October.** The amount the page pre-fills, quotes and simulates came from one read RPC; the wallet's own view was never consulted before signing. `bid()` now re-reads `minimumBid()` and `rewardForBid()` through the wallet's provider right before the prompt and refuses on any disagreement (`Mismatch`; a higher minimum is a `BidTooLow` with a requote). Tested with a read node that inflates the minimum and one that overstates the reward. |
| W-06 | Low | **Fixed 10 October.** The mainnet and Sepolia configs name a second URL (`eth.drpc.org`, `sepolia.drpc.org`, both probed in `audit/rpc-gas-caps-*.txt`), so the transport's failover engages. |
| W-07 | Low | `site/tools/pack_motifs.py` reads and writes `motifs.js` in the locale's encoding. |
| W-08 | Info | The root README still describes the removed site. |
| W-09 | — | New since the round: the site has no button for `deliverPrizeToWinner()` (V-15) and its ABI table does not list it. Not needed for a wallet that can claim. |
| W-10 | Low | **New in the site review of 10 October, fixed the same day.** The Afterglow page signed whatever string the room API handed it (`personal_sign`); a compromised proxy could obtain a login signature for another site. `site/afterglow-access.js` now checks the message is this origin's entry message for the connected wallet, chain and challenge id before the wallet is asked. |

#### Accepted, with the reason

- **The token JSON is served as `data:application/json;utf8,` raw, not base64.** It parses under the URL standard, and base64 would add a third to an answer of 1.1 MB. Unproven on a real marketplace at this size: a rehearsal item ([checklists/1-pre-deploy.md](checklists/1-pre-deploy.md)).
- **The 1/1 is bound to the motif contract's address, not to the grid bytes.** Only the deploy script's golden, and now `expected`, tie it to the content.
- **`?` is allowed in the 1/1's texts.** It does not end a data: URL for the readers tested.
- **The CREATE2 deployer is assumed to exist.** It does on mainnet and Sepolia; forge's simulation supplies it where the chain lacks it, so the script cannot tell. A by-hand line in the deploy checklist.
- **The packers read the artist's working file.** `pnpm -s stores` now requires the release copy (`mint/artwork.html`) to be that file byte for byte, and its hash is in `expected`.

#### Tried and held

No defect, each pinned by a test now in `test/review/`: the hex and base64 lanes of `tokenURI(1)` for every lane, byte and sextet (`OneOfOneEncoders`); the one-buffer assembly's bounds, free pointer, exact length and the live `grids()` read, including a grids source that answers the wrong size (`OneOfOneGridsSource`); the 1/1 against other grids (`OneOfOneBoundToOtherGrids`); the burn bitmap, a names table with a leading gap, re-entry through receivers during mint and claim, and the worst-case SVG (1.7M gas for a 128-run checkerboard, 94 runs in the real set) (`MotifsAttackSurface`); `royaltyInfo` overflowing only above any real price, as OpenZeppelin's does (`RoyaltyInfoOverflow`); the settle floor exact with no bare out-of-gas, a claim rolled back whole when its second id range is refused, a winner moving the 1/1 inside its hook, and a nonce slip at deployment refused by the auction's constructor (`PrizeGasBudget`); the still's size against the 8M read ceiling (`OneOfOneStillSizeSweep`); recipients (`TreasuryAsRecipient`). The loader's names no longer leak into the artwork's scope and the gzip header is the same from every Python (both fixed before the round ended). The page starts under every iframe sandbox mode and shows one line without `DecompressionStream`.

#### Numbers after the round

Measured on 10 October, night, on the store packed from that day's artwork (`mint/artwork.html`, `mint/still.png`):

- **Prize delivery, cold** (as a `settle()` sent on mainnet): a winner's receiver may use **387,122** of the 500,000 gas; the delivery itself takes 112,878. Through a Safe-shaped wallet (proxy, singleton, fallback handler) the handler may use 365,588. On the projected Glamsterdam prices (new slot 110,020, cold account 3,000; not final until 1 November): the delivery takes 465,458 and leaves **34,542**, against at most 22,334 for a Safe. One new slot in a receiver does not fit then; `deliverPrizeToWinner()` is the way out. The warm figures quoted above this section (391,406 and 39,726) are what the suite's in-test construction measures.
- **Gas floors**, as gas limits on the call: `settle()` from 585,836 (about 607,000 as a transaction), an outbidding bid from about 524,000 (about 545,000 as a transaction). The site sends 1,200,000 and 1,500,000.
- **Reads:** `KilimOneOfOne.tokenURI(1)` **4,625,534** gas for 1,092,954 bytes; `KilimMotifs.tokenURI` 287,312. Both under the 8M ceiling the script enforces.
- **Deployment:** 46 chunks, about 252.2M gas in all (the page 196.6M, the still 44.7M, the motifs 10.8M), the largest 5,992,449; `KilimMotifs` 3,210,743, `KilimOneOfOne` 6,750,528, `KilimAuction` 3,396,594. Every transaction under the 8M policy.
- **Sizes** (creation / runtime bytes): `KilimMotifs` 13,517 / 10,891; `KilimOneOfOne` 12,131 / 9,981; `KilimAuction` 13,973 / 11,216.
- **Tests:** 256 forge tests in 25 suites, 0 failed; 79 site tests; 21 packer tests; the page test 2 of 2 (the packed artwork starts from its data URL in headless Chrome, WebGL2). Slither: no high or medium, 10 low and 25 informational, the same findings as before the round. `forge fmt --check` passes; `pnpm -s deploy:dry` is green.

#### What the round did not do

No mutation run on the new contracts. The script's new paths were run once against a live local node (anvil, 10 October, the real store): the store was refused from the deployer's wallet and went out from another in 46 transactions with `--slow`; with a transaction from the deployer waiting in the pool the contracts phase was refused (`a transaction from the deployer is pending`, latest nonce 0, pending 1); with the pool empty the three contracts were deployed and read back. Measured there: `KilimMotifs` 3,210,743, `KilimOneOfOne` 6,276,216, `KilimAuction` 2,929,640 (the in-memory dry run reports the last two higher, 6,750,528 and 3,396,594, and is the figure the 8M policy is checked against). `runAuction()` and `--resume` have not been run live, and nothing has been deployed on Sepolia. `scripts/probe-rpc.mjs` was run for the first time (`audit/rpc-gas-caps-mainnet.txt`, `audit/rpc-gas-caps-sepolia.txt`): every public endpoint that answered lets an `eth_call` use 50M gas or more by default, on mainnet and on Sepolia under Glamsterdam rules, against 4.63M for the 1/1. No marketplace has shown either token. The verifiers of 42 findings never ran, so those rest on one reviewer and one hand check. The independent human audit (K-08) is still the launch blocker, and now covers `deliverPrizeToWinner` and the deploy script's new paths as well.

## 11 October 2026: final audit before the freeze

**Run on 10 and 11 October 2026**, on the working tree of commit `35a9297e` with the stores re-packed from the finished artwork (`mint/artwork.html`, SHA-256 `987085e6…`, and `mint/still.png`, 283,014 bytes). Reviewers: Claude instances (Fable 5.1, then Opus 5.5 after a usage limit). **This is not the independent audit (K-08), which is still a launch blocker.**

Method, following Trail of Bits' secure workflow: Slither 0.11.5 and `slither-check-erc`; ten finder lenses (the ETH flow, the motif credits and prize, `KilimMotifs`, `KilimOneOfOne`'s assembly, the deploy script, the packers and loader, spec against code, economics, dependencies, test adequacy); three adversarial verifiers per finding (refute by code; by the record and the tests; by impact, testing empirical claims); a Foundry proof of concept for each confirmed medium; a completeness critic and five more lenses on what it named (the site's launch path, the registration relayer, metadata consumers, EIP-7702 participants, Glamsterdam). Sixteen findings whose verifiers were cut off by the usage limit were verified again in a second run, which also measured the Glamsterdam rules on Sepolia and decoded the real 1/1 `tokenURI` in browsers and libraries. Every finding with its verifiers' full reasoning is in [audit/final-audit-2026-10-11.json](audit/final-audit-2026-10-11.json), readable in [audit/final-audit-2026-10-11.md](audit/final-audit-2026-10-11.md); the two proofs of concept are in [audit/poc-2026-10-11/](audit/poc-2026-10-11/).

**Result: in the four contracts, no way was found to take ETH or tokens, to break or stall the auction, or to mint outside the rules.** Slither reports no high or medium (the same 10 low and 25 informational as before), and both token contracts conform to ERC-721 and ERC-165. 66 findings came back, 65 distinct; 44 were confirmed, 1 refuted, 20 informational ones passed through unverified. Grouped: one high and three medium in the site (the web session's files), two medium in the deploy process, and the rest low or informational. None of them is in the Solidity's handling of funds.

### Launch blockers, as of 11 October

1. **The 1/1 page does not read `KILIM_GRIDS`** (V-03, open on the artwork's side), **and the gate that should refuse such a page cannot tell a page that uses the grids from one that names them** (FA-01).
2. **The still is too large for the 8M policy** (FA-03). With the 3:4 still of 10 October (1536 × 2048, 283,014 bytes) the dry run measures the `KilimOneOfOne` creation at **8,087,087** gas and refuses it; `pnpm test` is 255 of 256 for that reason (`testRunDeploysBothPhasesFromTheLocalConfig`). The same picture saved again losslessly (Pillow `optimize=True`, identical pixels, 271,482 bytes) measured **7,970,112** in a trial store, since deleted: under the line by 30,000. The dry run over-counts the creation (FA-05: anvil charged 7% less on 10 October), so the real margin is larger. The artist said on 10 October that the still is not to be a WebP; the packer accepts only PNG.
3. The independent human audit of the frozen commit (K-08), and the marketplace's written confirmation that it shows a raw `data:application/json;utf8,` `tokenURI` of 1.3 MB ([checklists/1-pre-deploy.md](checklists/1-pre-deploy.md)).

### Contracts, deploy script, packers, tests and documents

| ID | Severity | Finding | What to do |
| --- | --- | --- | --- |
| FA-01 | Medium | The mainnet refusal of a page that ignores the grids reads `artwork.readsGrids` from the page manifest, which the packer sets by a byte search for `KILIM_GRIDS` (`onchain/pack_page.py:179`); a comment or a dead fallback passes, the flag is in no hash, and `test:page` checks only that the global is defined, which the loader guarantees. Proof: `audit/poc-2026-10-11/GridsGateIsLexicalPoC.t.sol` fails. | Prove use, not mention: open the packed page with the real grids and with altered grids and require the drawing to differ (and the artwork to publish the hash of the grids it drew); refuse an artwork that declares `KILIM_GRIDS` itself; carry the result in `expected`. |
| FA-02 | Medium | **Glamsterdam.** The deploy script and forge simulate under Cancun prices (`foundry.toml` `evm_version = "cancun"`; forge 1.7.1 has no Glamsterdam schedule) and forge signs each broadcast at its simulation × 130%. On a Glamsterdam chain a full chunk needs about 38.6M gas, not 7.0M, so the documented Sepolia rehearsal fails on its first chunk today, and `checklists/2-deploy.md` says the limit comes from Ethereum's estimate when it does not. Mainnet is unaffected until Glamsterdam is scheduled there (it is not). Proof: `audit/poc-2026-10-11/GlamsterdamBroadcastGasPoC.t.sol` fails; measurements below. | Deploy to mainnet before Glamsterdam activates there. Rehearse on Sepolia with `--skip-simulation` and a gas limit from `eth_estimateGas` plus margin (the raw estimate is about 94,000 short for a full chunk), or rehearse on an anvil fork of mainnet. Correct 2-deploy.md, STORAGE.md and checklist 1. |
| FA-03 | Launch blocker | The still: see blocker 2. Also, the art toolchain's record (`source/still.mjs:11`, `mint/still.json`) says the WebP goes on-chain while the packer refuses anything but PNG. | The artist chooses the PNG (re-saved losslessly, compressed harder, or rendered smaller); then bring `still.mjs`, `still.json` and ARTWORK-ONCHAIN.md into line. |
| FA-04 | Low | `runAuction()` is documented as completing a third creation that was "dropped, replaced or reverted". Only a dropped one leaves the deployer at n + 2; a reverted or replaced one spends n + 2 and voids both token contracts, which the script correctly refuses to complete. Conversely a dropped first or second creation does not spend the published nonce, while the checklist says it does. | Reword `deployAuction`'s natspec, 2-deploy.md and the README; add a test that advances the deployer to n + 3. |
| FA-05 | Low | `_measured` is not the transaction's gas: it includes the script frame's memory (the whole store is loaded) and counts the creation's 32,000 twice, and it reads warm chunk accounts that a mainnet creation finds cold. It over-counts overall: the policy can refuse a creation that fits. | Measure each creation from a fresh helper contract, count the intrinsic once, add the cold-access difference. |
| FA-06 | Low | `deliverPrizeToWinner()` is open to anyone. After a failed delivery, a third party can send the 1/1 into a winning contract before the winner calls `claimPrize(to)` with another address; if that contract cannot move tokens, the 1/1 stays there. Not tested, not disclosed. | The artist decides: disclose the race, or let only the winner call it (or anyone only after a delay). |
| FA-07 | Low | A wallet of the seller's can ladder all 1,000,000 motifs and, if it wins, pay the winning bid to the treasury, so for the seller the ladder costs only gas (K-07 with K-01). The disclosures price the ladderer's downside as "it has bought the 1/1 at that price". | Say it in K-07, NATIVE-ETH.md and the terms: bidders rely on the artist's word that no other wallet of theirs bids. |
| FA-08 | Low | `launch/KILIM-BAZAAR-RULES.md:79` reads the winner's motif ids as `motifsAllocated − highestBid / 0.001 ETH + 1 … motifsAllocated`, which is wrong whenever the winning bid's reward was capped, and the auction has no getter for a bid's range (`_creditRanges` is private; only the `BidPlaced` log carries it). The auction cannot gain a getter after deployment. | Before the freeze, either add a getter for the winning bid's first id and reward, or rewrite the rules to read the `BidPlaced` log; and say what the Master costs when the winning bid earned fewer motifs than its price. |
| FA-09 | Low | `pack_page.py --check` takes its "another zlib" path on any problem, so a missing or stale `animation.html` or stray chunk files pass with a false message. | Enter that path only when the recorded zlib differs; check `animation.html` and stray files. |
| FA-10 | Low | `pack_motifs.py` sorts the records by `number`; the page indexes them by position. Harmless today (they are in order); a reordered page would pack silently. | Refuse records that are not in order. |
| FA-11 | Low | The store numbers in STORAGE.md, the README, the checklists, ARTWORK-ONCHAIN.md and the script header describe the 141 KB still (46 chunks, 252.2M gas, a 1,092,954-byte answer); the store is now 54 chunks. Checklist 1 ticks the 8M item on the old numbers and gives two different funding totals. | Regenerate every figure from `pnpm -s deploy:dry` once FA-03 is decided; untick until the dry run is green. |
| FA-12 | Low | `scripts/site-config.mjs` never compares the deployed `gridsHash`/`namesHash` with `site/motifs.js`, the one mismatch that makes the site refuse to start; it would first show in visitors' browsers. | Read both hashes and refuse a mismatch; refuse a `startsAt` in the past. |
| FA-13 | Low | The auction constructor's two minter checks are never tested apart: removing either one alone passes the suite. `KilimMotifs`' short names-table check is untested. | Two constructor tests, each with one wrong minter; one short names chunk. |
| FA-14 | Low | Three review-record tests assert less than their rows say (the F-02 sweep never requires a success; V-01's last check accepts any `Refused`; a bare `expectRevert` in V-15). | Count successes, pin the reasons. |
| FA-15 | Info | Test hygiene: the invariant handler steers around the fallback paths and asserts nothing about who holds the 1/1 after settle; the "exact settle floor" test asserts neither exactness nor the absence of bare out-of-gas; registration fixtures pay no gas; two bare `expectRevert()`. | As listed in the detailed report. |
| FA-16 | Info | AUDIT.md says an EIP-7702-delegated bidder "still withdraws and claims"; claiming motifs to its own address needs a receiver hook it may not have. | Say so in NATIVE-ETH.md; test the claim to self. |
| FA-17 | Info | The rule that the deployer must be a plain account without an EIP-7702 delegation is enforced by nothing. | `deployer.code.length == 0` in the script, and a `cast code` line in 2-deploy.md. |
| FA-18 | Info | The only mutation record (`audit/mutation.txt`) is of 26 September, over files since deleted. | Run a campaign on the current contracts before the freeze, or say none exists. |
| FA-19 | Low | `scripts/probe-rpc.mjs` reports "renders" when it has measured only that the gas suffices. | Reword; the marketplace check stays in the checklist. |
| FA-20 | Info | The raw `data:` URL was tested, not argued (below): it decodes byte for byte everywhere it matters. Only ethers' `FetchRequest` refuses it, because of the `;utf8` parameter. | No change needed. Optional, before the freeze: `data:application/json,` without the parameter, which ethers accepts. |

#### Glamsterdam, measured

Sepolia has run Glamsterdam since 6 October 2026, 13:53 UTC; mainnet has no date, and EIP-8037 is in Last Call until 1 November. Read-only `eth_estimateGas` on 11 October, two independent public nodes agreeing, for the deploy script's exact calldata of the real full chunk `prefix_00.bin`: **Sepolia 38,532,308, mainnet 5,467,182** (× 7.05). On Sepolia the transaction needs at least 38,626,249 (the raw estimate reverts). The cause is EIP-8037: code costs 1,530 gas per byte as state gas instead of 200, plus 183,600 for a new account. The 16,777,216 cap now limits execution gas only, so each chunk still fits in one transaction, with a gas limit above 2^24. For the whole store of 54 chunks: about 275M gas today against about 1.95G under Glamsterdam; at the mainnet base fee of 11 October (0.062 gwei) about 0.017 ETH against 0.12 ETH. The three contracts would need about 18.6M, 24.9M and 18.1M each, so the script's 8M policy cannot hold on such a chain. The registration relayer's fixed 120,000 gas limit does not fit `registerFor` there either (W-20).

#### The 1/1's raw `data:` URL, tested

The `tokenURI(1)` string assembled from the packed store (1,297,402 bytes, equal to the golden) holds 6,644 `+` and 7,191 `/`, and no `%`, `#`, `?`, `&`, control or non-ASCII byte. Node's `fetch`, Python's `urllib.request.urlopen`, headless Chrome's `fetch` and an `<img>`, the WHATWG data: URL processor as written, and viem's avatar parser all return the body byte for byte: the JSON parses, `image` is `still.png` (SHA-256 `8ec1ea03…`) and `animation_url` is the golden page. Only a form decoder (`unquote_plus` and the like) turns `+` into spaces, and no data: URL reader uses one. ethers v5 and v6 refuse the URL for its `;utf8` parameter. How OpenSea's and Alchemy's own ingestion treats a 1.3 MB raw answer is still unknown; Alchemy documents a 30,000-byte limit on token-URI responses without saying whether it covers data: URIs. That stays a rehearsal item.

### For the web session (`site/`, `registration-relayer/`, hosting)

| ID | Severity | Finding |
| --- | --- | --- |
| W-11 | High | Both mainnet RPCs in `site/chains/1.json` refuse the bid-book log scan from `deployBlock` once the deployment is about 1.5 days old (publicnode treats older `eth_getLogs` as archive requests, HTTP 403; drpc refuses spans over about 101 blocks), and `rpc.js` never fails over on a JSON-RPC error. The page then shows totals with an empty bid book, empty holdings and a permanent "Retrying", and the stale state disables the Register button. Probed live on 10 and 11 October. |
| W-02 | Medium | Re-confirmed and widened: no public build can bid; the orkhanart target composes a read-only page, the only bidding UI is dev-only, and three documents describe the opposite sequence. |
| W-12 | Medium | The chosen landing (`landing-departure/`) has no path to orkhan.art: nothing syncs it, its build uses root-absolute paths that 404 under `/kilim`, and the proposed `X-Frame-Options: DENY` and `frame-ancestors 'none'` block its own artwork iframe. |
| W-13 | Medium | The kill switch is a rebuild and republish across two repositories and a host pipeline this repo does not describe; open tabs never see it; the checklists call it tested and minutes-fast. |
| W-14 | Low | The bid page checks the balance against the bid only, while the fixed 1,500,000 gas limit makes wallets require bid + 1.5M × max fee up front. |
| W-15 | Low | A sponsor on another host is validated by nobody, is absent from the proposed `connect-src`, and the signature is asked for before the fetch the CSP would block. |
| W-16 | Low | `sync_orkhanart.py` never removes files the build stopped writing and ships 96 unreferenced frames (2.7 MB). |
| W-17 | Low | "Claim the 1/1" claims only to the connected wallet, the address that just failed to receive it. |
| W-18 | Low | "Withdraw refund" withdraws only to the connected wallet; a refund deferred because that wallet refuses ETH fails again from the page. |
| W-19 | Low | A Safe cannot connect (EIP-6963 and `window.ethereum` only; no WalletConnect, no Safe App manifest); checklist 1 says Safes can bid. |
| W-20 | Low | Relayer: the fixed 120,000 gas limit does not fit `registerFor` under Glamsterdam (Sepolia today); every wallet is told its signature is invalid. |
| W-21 | Low | Relayer: a journaled transaction that can never mine bricks it for good, and the README forbids the only repair. |
| W-22 | Low | Relayer: the 1 gwei fee gate adds the node's suggested tip, and ethers substitutes exactly 1 gwei when the node lacks `eth_maxPriorityFeePerGas`, so every request is refused. |
| W-23 | Low | Relayer: a sponsor transaction mined after the 15-minute deadline fails, and the wallet is then locked out of sponsorship. |
| W-24 | Low | Relayer: one sponsored registration per block at best, and every refused registrant must sign again. |
| W-25 | Low | F-08 widened: exhausting the sponsor's budget needs neither a mempool copy nor an ERC-1271 wallet; 166 attempts end sponsorship for everyone. |
| W-26 | Low | F-09 incomplete: after any sponsor error a plain wallet gets no self-paid `register()`, and counterfactual smart accounts are routed to a signature they cannot pass. |

The relayer is not activated in either production config, so W-20 to W-26 matter only if it is switched on.

### Measured on 10 and 11 October

- **Store** (packed from the finished artwork, `pnpm -s stores`, then `check:stores` green): 54 chunks: grids 2, names 1, prefix 16 (377,529 B, the still), head 1, tail 34 (832,196 B). The motifs are byte-identical to the previous pack (`gridsHash 0x467ddda4…`, `namesHash 0xf92beabc…`). `tokenURI(1)` answers 1,297,402 bytes.
- **Deployment, dry run:** `KilimMotifs` 3,210,743; `KilimOneOfOne` 8,087,087 (refused); with the re-saved still 7,970,112, `KilimAuction` 3,542,583, the 1/1's `tokenURI(1)` read 5,524,575 gas, a motif's 287,312.
- **Tests:** forge 255 of 256 (the deploy dry run refuses the 1/1's gas, FA-03); site 87 of 87; packers pass; the page test 2 of 2 (the packed artwork starts from its data URL in headless Chrome). `forge fmt --check` clean.

### What this audit did not do

No mutation campaign on the current contracts (FA-18). No transaction on Sepolia or mainnet; the Glamsterdam figures come from `eth_estimateGas` and `eth_call`. No marketplace has shown either token. The 20 informational items listed at the end of the detailed report were not verified. Nothing was fixed in this round: the store was re-packed and the findings recorded. The two proofs of concept were moved out of `test/` so the suite stays as it was. Everything here was done by Claude instances.
