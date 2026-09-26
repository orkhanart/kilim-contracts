# Kilim internal security review

**Review date:** September 18, 2026 UTC.  
**Disposition:** Development implementation. **Not approved for a real-money launch.**  
**Reviewer:** The same coding agent that implemented the contracts. A later pass the same day re-reviewed the code in a separate session, then reviewed the owner-requested changes (treasury bid block, bid-time symbol IDs, ID slippage guard) with five parallel review agents, two adversarial verifiers per finding, and mutation testing. All reviewers are Claude instances. This is not an independent audit, formal verification, or a guarantee of zero vulnerabilities.

## Scope and evidence

Reviewed `src/Kilim.sol`, `src/KilimAuction.sol` and `src/auction/ERC20EnglishAuction.sol`, their use of OpenZeppelin 5.6.1, constructor parameters, token callbacks, auction accounting, burn/merge provenance, and test/build configuration. Exact source and build hashes are recorded in `audit/build-manifest.json`.

The auction base retains thirdweb's `_isNewWinningBid` predicate from the source identified in the 0xMacro A-15 report. The original file's hash matches the report; the build checks that the retained function and denominator have not changed. This is a limited extraction with extensively modified surrounding code, not an independently audited Kilim auction. [REUSE.md](REUSE.md) records the exact provenance, license and behavioral changes.

Methods: manual review, adversarial tests, randomized input tests, stateful model invariants, gas measurements, Slither 0.11.5, npm advisory scanning, and the Solidity compiler's published bug list. Compiler and library dependencies were checked against current primary sources. This did not review the whole OpenZeppelin codebase independently.

Not covered: deployed bytecode, a specific production stablecoin or bridge, target-chain fork tests, live wallets, marketplace integrations, the website's mock ledger, the rendering engine, external data persistence, legal terms, or an actual mainnet deployment. No transaction was broadcast and no private key was used.

## Open findings

### K-01 — High economic risk, accepted by owner: refundable bids can farm permanent rewards

Location: `KilimAuction.bid()` and `rewardForBid()`.

A bidder keeps credits after receiving all of their losing principal back. Two cooperating wallets can alternate increasing bids and recycle refunds. A single wallet may also outbid itself with full fresh funding and withdraw the previous bid. Reward caps bound total issuance, but an actor can consume the reward pool ahead of other collectors. Wallet limits would not establish Sybil resistance.

Executable example: Alice bids $25, Bob $27, Alice $29, Bob $31, with losing bids withdrawn. Alice's stablecoin balance returns to its original value while she retains 54 symbol credits. Total allocated credits are 112 while only $31 remains as the standing bid. See `testRefundCyclingAccumulatesRewardsForFreeLosingBids`.

Measured exposure: with the test fixture (10,000 total, 1,000 per bid, $25 reserve, 5% increment), one wallet with no accomplice reaches all 10,000 credits in 58 self-outbids. Peak capital is about $1,073, fully recoverable once anyone outbids it. Every later bidder then receives zero symbols.

**Status:** Accepted by the owner on September 18, 2026 as the intended incentive: outbid bidders keep their credits so that they keep bidding. Nonrefundable purchases, increment-only rewards and winner-only rewards were offered and declined. Immutable caps bound total issuance, not its distribution. The per-bid and total caps are the remaining launch levers. Disclose the mechanism plainly and do not advertise it as manipulation-resistant or as $1 of net revenue per symbol.

### K-02 — Medium, reduced: symbol traits are public and deterministic

Location: `Kilim.symbolTraits()`, `KilimAuction.bid()`.

**Previous design (fixed in this update).** Traits hashed the bidder's address with a token ID assigned at claim time, and artworks advanced the same ID counter. Collectors could pick which wallet claimed the next ID, claim singly, retry after a receiver revert, or generate addresses offline. With eight credited wallets choosing per ID, rare materials (codes 4–5) rose from the expected 9% to 57% of claims.

**Current design.** Traits depend only on the chain ID, collection address and token ID, so all of them are public at deployment through `symbolTraits(id)`. Each bid reserves the next IDs in allocation order; claims mint exactly those IDs. Artworks use a separate ID range. Wallet choice, claim time, claim order, recipient and receiver retries no longer affect what a bidder receives, and rare supply is fixed. In the test fixture: 4,369 / 2,446 / 1,378 / 914 / 492 / 401 symbols of materials 0–5.

Residual risks, all following from public deterministic traits:

- **Rarity is a public race.** Bidders can see which upcoming IDs are rare and time or size bids to cover them. Ranges must start at the pointer and grow with the 5% increment, and rarity density varies modestly (23–53 material-5 symbols per 1,000-ID window in the fixture), so the edge is bounded. It is zero-sum between bidders.
- **Ordering.** A bid that lands first moves later bids to different IDs. `expectedFirstSymbolId` lets a bidder revert instead of accepting a different range; it cannot stop the earlier bid from taking the quoted IDs.
- **Deployer choice of layout.** The collection address, and thus the whole layout, follows from the auction's deployment address, which the deployer controls. Across 400 CREATE2 salts, the material-5 count in IDs 2–1,001 ranged from 26 to 62 (mean 40). An insider bidding from a non-treasury wallet at opening could target a ground layout. Publish the deployer and nonce (or factory and salt) before deployment, and leave a public inspection window between deployment and `startsAt`; the contract only requires `startsAt` to be in the future.

**Status:** Claim-time and address grinding removed. Deterministic, public traits remain by owner decision (no VRF). The site must say rarity is visible in advance, not random. If unpredictable or fair rarity is later required, integrate a chain-supported verifiable random source with asynchronous fulfillment and re-audit that design. Hashing wallets, timestamps, block hashes, or sequencer-controlled values is not a substitute.

### K-03 — Launch blocker: rendering and content availability are incomplete

Metadata and composition/source data are on-chain. Geometry, rendering code, and appearance preimages are not. `geometryHash`, `rendererHash`, and `appearance` are commitments only; constructor validation checks nonzero hashes, not content availability or correctness. No `image` or `animation_url` is supplied.

The collection uses the supplied geometry's 812 motifs; the landing page was corrected from 813 to 812 on September 19, 2026. The six symbol material codes and the current flat preview's appearance choices also need an explicit rendering specification.

**Status:** Open. Finalize the content set, availability mechanism, immutable renderer, appearance encoding, metadata media, and frontend calls. Substituting ABI names into the current prototype is insufficient: mint timing, reward caps, pull refunds, motif count, and canvas limits differ.

**Update (renderer built, not yet reviewed):** geometry, index and the 1/1 page now live on-chain in SSTORE2 data contracts; `KilimRenderer` verifies them against `geometryHash`, `indexHash` and `pageHash` in its constructor and draws all metadata and media; `Kilim` checks the renderer's code hash, motif count and geometry hash and forwards its answers; `appearance` is an allow-list of three values. See [docs/RENDERER.md](docs/RENDERER.md). Still open: an independent review of `KilimWriter` and the renderer's assembly (buffer rules, base64, decoder, `_read`), the final symbol set and hashes, the artist's review of the rendered look, and marketplace confirmation of the media. The 1/1 costs ~22.4M gas to read; RPCs that cap `eth_call` below that would show it blank.

### K-04 — Launch blocker: stablecoin and deployment configuration are unselected

The intended network is Robinhood Chain with an immutable USD ERC-20 token. No specific token address, issuer implementation, treasury, or economic launch configuration has been approved or tested here.

Exact balance-change checks reject typical fee-on-transfer behavior; SafeERC20 handles false return values. Neither protects against a malicious token that lies about balances, issuer blacklisting, rebases, upgrades, bridge failure, or a lost peg. A globally frozen escrow can make refunds unavailable despite correct accounting.

Candidate token, read-only checks on September 18, 2026: Robinhood Chain uses Paxos **USDG** (Global Dollar) as its native stablecoin. Paxos lists `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` on mainnet (4663) and `0x7E955252E15c84f5768B83c41a71F9eba181802F` on testnet (46630). RPC calls on both networks returned name "Global Dollar", symbol USDG and **6 decimals**, matching the test fixture's units. Each address is a 170-byte EIP-1967 proxy with an implementation slot set: the issuer can upgrade the token. It exposes `paused()` (currently false), an `owner()`, and `isFrozen(address)`: the issuer can pause all transfers and freeze individual addresses, including this escrow. These are the external risks above, now confirmed for this token. The implementation code, transfer behavior, and any fee or hook logic were not audited here.

**Status:** Open. USDG is identified but not approved or tested with these contracts. Rehearse on testnet with testnet USDG, validate treasury access, fix deployment values, and obtain independent review of the final build before funding. Test fixtures are not launch configuration.

### K-05 — Low: auction timing relies on chain time and sequencer availability

Opening, closing, and late-bid extensions use `block.timestamp`. This is intentional. Extensions have an immutable absolute end, and timestamps are never used as entropy. Clock constraints, ordering, outages, and censorship remain external assumptions. An outage near the deadline may prevent bidding; no administrator restart or cancellation exists.

**Status:** Documented limitation. The remaining Slither timestamp findings are retained, not suppressed.

### K-06 — Low: accidental asset donations have no recovery path

Direct ERC-20 transfers and forced ETH do not create refunds, credits, or proceeds. There is no rescue function. Accidental donations remain locked, avoiding an administrative path to withdraw assets backing claims.

**Status:** Deliberate minimal custody interface. The frontend must use `bid()` and token approval, never raw transfers.

### K-07 — Medium trust risk, partly mitigated: seller self-bidding

Location: `ERC20EnglishAuction._handleBid()`.

Before this update, the treasury could bid, win, withdraw its own payment as proceeds and claim the 1/1. It would end with its money back, every credit, and the prize, and could raise prices against real bidders at no risk. The treasury address now reverts with `TreasuryCannotBid`.

**Status:** Mitigated for the treasury address only. A seller can still bid from other wallets; that is undetectable on-chain and remains a trust and disclosure matter.

## Protections and fixes verified

- **Solvency:** refund liabilities plus the standing bid (or unpaid proceeds after settlement) are fully backed under the supported token model. Donations do not change obligations. Treasury proceeds cannot exceed the winning bid.
- **Withdrawal ownership:** only the claimant can withdraw their refund; only the immutable treasury can withdraw proceeds. A failed transfer restores the entire entitlement. Claimants can select another recipient.
- **Liveness:** refunds, reward claims, prize claims, and proceeds are separate. A malicious NFT receiver cannot prevent another bid, settlement, or another participant's withdrawal. Exhausted rewards do not close bidding.
- **Callbacks:** custom mutating entry points are guarded against reentrancy. Counters and entitlements change before external calls. Artwork state is complete before receiver callbacks. Standard ERC-721 transfers from a receiver remain permitted. A claim spanning several bids calls the collection once per ID range. During those callbacks the auction already counts the whole claim while the collection has counted only the ranges minted so far. No contract logic reads these counters; integrators should compare `symbolsClaimed` and `symbolsMinted` only at transaction boundaries.
- **Supply and IDs:** allocation is capped; claims cannot exceed credits; mint batches are bounded, including claims spanning several bids; burns never reopen issuance. Each symbol ID is reserved once at bid time and minted once; burned IDs can never be minted again. Symbol, artwork and masterpiece IDs occupy disjoint ranges. Only the immutable auction can mint. The masterpiece mints at most once.
- **Seller bids:** the treasury address cannot bid (K-07). Prize, settlement and proceeds flows for the treasury are unchanged.
- **Ownership and provenance:** approved operators cannot invoke burn/expand/freeze on others' tokens. Duplicate, nonexistent, foreign, or already consumed sources revert atomically. Expansion retains every prior source exactly once. Stale revisions revert. Source traits survive transfers and burns unchanged.
- **Freeze:** frozen artworks cannot expand, even after transfer. Unfrozen artworks can change before an external marketplace purchase; integrations must handle that property.
- **Bounded work:** at most 64 NFTs per claim and 256 cells per composition. A development 1,024-cell merge needed about 64.6 million execution gas and was removed from the supported range. Packed provenance reduced the 256-cell merge to about 10.7 million execution gas in the local fixture.
- **Arithmetic:** checked arithmetic, upward whole-unit rounding, bounded decimals, immutable limits, checked uint128 IDs, and checked timestamp construction. The `extended` cast is bounded by the uint64 hard end; the provenance cast originates from the uint128 ID counter. Neither accepts an unbounded caller value.
- **Reuse boundaries:** uint128 bid bounds are enforced before the upstream predicate's multiplication. The minimum quote is fuzzed for acceptance and minimality across decimals and percentage increments. Attached/direct ETH calls revert, a blocked old bidder cannot stop new bids, and large overbids are fully funded. A rejected reward-slippage check restores the prior leader, refunds and deadline. There is no buyout clamp or shared marketplace balance.
- **Build tooling:** the npm scan found solc's development dependency `tmp@0.2.6` affected by [GHSA-7c78-jf6q-g5cm](https://github.com/advisories/GHSA-7c78-jf6q-g5cm). A lockfile override pins patched `0.2.7`; the repeat scan reports zero advisories. This was a tooling issue, not an on-chain exploit.
- **Build provenance:** source exports compare every compiled input, including OpenZeppelin dependencies, with the compiler metadata's Keccak-256 hashes. Temporary-copy checks verified that stale source files and unexpected optimizer settings are rejected. Separate checks verified that altered upstream source, predicate or denominator are rejected. The auction refactor preserved the complete public ABI, including constructor, events and errors; it changes storage layout and is only intended for a fresh deployment.
- **Static-analysis cleanup:** made a zero-initialized counter explicit and used the mint return value in the claim event. The mint call no longer returns a value; claim events now report the reserved IDs directly. Those original medium warnings were reviewed and removed; they were not demonstrated theft vulnerabilities.

## Verification results

**94 tests passed** in the CI profile, including the full-lifecycle integration test, which was also run and recorded separately. The CI run included eight fuzz tests at **4,096 runs each** and six invariants at **256 runs × 128 calls each**, with zero handler reverts. The lifecycle test covers bidding, refund, reward claims, composition, expansion, freeze, transfer, settlement, proceeds and final NFT claims together. Slither analyzed 27 contracts with 101 detectors: **zero high/medium findings and four low findings**. Three are the reviewed timestamp comparisons. The fourth is calls-loop in `claimSymbols`: one call per reserved ID range to the immutable collection, bounded by the 64-symbol batch. A reverting receiver fails only its own claim. Two uninitialized-local warnings introduced by this update were fixed with explicit zero initialization. The npm dependency scan returned zero advisories. These scanner results do not clear the open manual/economic findings above.

Measured local execution gas before refunds: **10,719,409** for a 256-cell weave, **10,408,062** for a 4-to-256-cell expansion, **6,077,841** for a 64-symbol mint, and **6,168,420** for a 64-symbol auction claim spanning three bids. A review test measured about 6.75 million for the worst case of 64 one-symbol ranges into a contract receiver. Smart-contract receiver costs are additional.

**Mutation testing:** 34 targeted mutants of the changed code, covering ID ranges, trait derivation, claim cursor, events, reentrancy guards, the ID slippage guard and the treasury block, were each applied alone and run against the full suite. All 34 were killed. An earlier round against 88 tests left 11 survivors; those test gaps were closed before this run. Results are in `audit/mutation.txt`.

Final test and analysis results are retained in `audit/tests.txt`, `audit/lifecycle.txt`, `audit/slither-summary.json`, `audit/dependency-audit.json`, and `audit/build-manifest.json`. Provenance/export rejection checks are recorded in `audit/upstream-checks.txt` and `audit/artifact-checks.txt`. The CI profile runs each input-fuzz test 4,096 times, and each of six invariants for 256 runs of 128 calls. Handler calls can be no-ops when an action is unavailable; call totals are not counts of distinct attacks or successful economic operations.

Stateful assertions check exact refund backing, an independent cash-flow ledger, credit conservation, issuance limits, reserved ID ranges (matching credits, inside the allocated block, disjoint across bidders, unminted), deadlines, one-prize settlement, immutable seeds, unique source membership, dimensions, and balance/supply conservation. Handler reverts fail the run. These are local EVM tests, not proof of real issuer-token or sequencer behavior.

Gas tests measure execution before refunds, with setup in a separate fixture. They are regression checks, not network fee quotes or proof that arbitrary receivers fit a gas limit. A receiver can consume gas or revert; only its own claim/merge fails. Verify large operations against the actual chain's limits.

Coverage produced source-level measurements, but Foundry emitted source-map anchor warnings. Percentages are therefore not an audit pass criterion or evidence of exhaustive path coverage. Passing tests and detector thresholds do not prove absence of bugs.

## Primary references

- [Solidity 0.8.37 release and security fixes](https://www.soliditylang.org/blog/2026/09/10/solidity-0.8.37-release-announcement/). The published bug list snapshot in `audit/compiler-bugs.json` contained no entry applicable to 0.8.37 at review time; this does not address undiscovered bugs.
- [OpenZeppelin ERC-721](https://docs.openzeppelin.com/contracts/5.x/api/token/erc721) and [SafeERC20](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20).
- [thirdweb A-15 audit and exact reference hashes](https://0xmacro.com/library/audits/thirdweb-15), its [preceding A-6 review](https://0xmacro.com/library/audits/thirdweb-6), and the [historical buyout incident report](https://blog.thirdweb.com/2023-09-09-vulnerability-auctions-with-a-buyout-price/). None audits this adaptation.
- [Robinhood Chain network configuration](https://docs.robinhood.com/chain/connecting/) and [deployment guide](https://docs.robinhood.com/chain/deploy-smart-contracts/). Read-only RPC calls returned chain IDs 4663 and 46630, and a zero-length `MCOPY` probe succeeded on both. No funded transaction, deployment, or specific stablecoin call was made.

The final economics, renderer integration, production token, deployment rehearsal, and independent audit remain required before launch.
