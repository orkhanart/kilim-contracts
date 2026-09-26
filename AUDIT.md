# Kilim internal security review

**Review dates:** September 18 and 26, 2026 UTC.  
**Disposition:** Development implementation. **Not approved for a real-money launch.**  
**Reviewers:** Claude instances only: the agent that implemented the contracts, then separate review sessions and multi-agent review rounds with adversarial verification and mutation testing. This is not an independent audit, formal verification, or a guarantee of zero vulnerabilities. An independent human audit of the frozen commit is required before funding (K-08).

## Scope and evidence

Reviewed, on the September 26 round, everything changed since the September 18 design (`git diff b731288..main`):

- `src/auction/ERC20EnglishAuction.sol`: the auction base, with the thirdweb bid predicate.
- `src/KilimAuction.sol`: symbol credits, bid-time ID reservation, claims, the 1/1.
- `src/Kilim.sol`: the ERC-721 collection, composition, royalties, the page-only owner role, renderer forwarding.
- `src/render/KilimRenderer.sol`, `src/render/KilimWriter.sol`, `src/render/IKilimRenderer.sol`: the on-chain renderer and its data store.
- `script/DeployKilim.s.sol` and `deploy/*.json`: deployment and its preflight refusals.
- `onchain/pack_store.py` and `onchain/render_ref.py`: the store packer and the byte-exact reference renderer.
- `site/` chain layer: bidding, pay-with-ETH, claims, weaving, as it calls the contracts.

Exact source and build hashes are in `audit/build-manifest.json`. The auction base retains thirdweb's `_isNewWinningBid` predicate from the source identified in the 0xMacro A-15 report; the build checks that the retained function and denominator have not changed. [REUSE.md](REUSE.md) records provenance, license and behavioural changes.

Methods: manual review; six independent review lenses (auction, collection, renderer, deploy, site, mutation) with two adversarial verifiers per medium-or-higher finding; stateful fuzzing including hostile re-entrant receivers; differential testing of the renderer against the Python reference; pixel comparison of the renderer's images with the site's drawing code in headless Chrome; mainnet-fork tests of the pay-with-ETH path; Slither 0.11.5; npm advisory scanning; the Solidity compiler's published bug list.

Not covered: deployed bytecode, live wallets beyond the test wallet, marketplace rendering on a real marketplace, legal terms, or a mainnet deployment. No transaction was broadcast and no private key was used.

## Launch configuration under review

Ethereum mainnet (chain 1). Payment in USDC (`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, 6 decimals); the site can swap ETH to USDC into the bidder's own wallet first. Opening bid $1, each new bid at least 10% higher, rounded up to whole dollars. The 24-hour clock starts at the first bid; a bid in the last 10 minutes resets the close to 10 minutes after it, with no limit; with no bids the auction never ends. Every accepted bid earns $1 = 1 symbol, including bids later outbid; supply cap 1,000,000 and no per-bid cap. Treasury and collection page owner: orkhanart.eth, `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`. Royalties 5% (ERC-2981). Art fully on-chain. The deploy script refuses any other values on chain 1.

## Open findings

### K-01 — High economic risk, accepted by owner: refundable bids earn permanent rewards

Location: `KilimAuction.bid()` and `rewardForBid()`.

A bidder keeps symbol credits after withdrawing all of their losing principal. Cooperating wallets can alternate increasing bids and recycle refunds, and a single wallet can outbid itself. With the launch settings there is no binding cap, so this cannot exhaust a pool; it inflates supply instead. One wallet adds symbols only by holding the top bid, which it pays for if nobody outbids it. When bids climb in minimum steps, total supply ends up about 11 times the final price.

**Status:** Accepted by the owner (September 18 and 25, 2026) as the intended incentive. Nonrefundable purchases, increment-only rewards and winner-only rewards were offered and declined. Disclose the mechanism plainly; do not advertise $1 of net revenue per symbol.

### K-02 — Medium, reduced: symbol traits are public and deterministic

Location: `Kilim.symbolTraits()`, `KilimAuction.bid()`.

Traits depend only on the chain ID, collection address and token ID; they are public at deployment through `symbolTraits(id)` and recomputed on every read rather than stored. Each bid reserves the next IDs in allocation order and claims mint exactly those IDs, so wallet choice, claim time, order, recipient and receiver retries do not affect what a bidder receives, and rare supply is fixed.

Residual risks: rarity is a public race (bidders can time and size bids to cover rare IDs, zero-sum between bidders); a bid that lands first moves later bids to different IDs (`expectedFirstSymbolId` lets a bidder revert instead); and the deployer's choice of address fixes the whole layout. Publishing the deployer and nonce beforehand gives everyone the same information but does not prove the layout was not chosen.

**Status:** Deterministic, public traits remain by owner decision (no VRF). The site states this.

### K-03 — Launch blocker, reduced: the on-chain renderer needs an independent review and the final symbol set

Location: `src/render/*`, `Kilim.tokenURI`.

Built: geometry, index and the 1/1 page live on-chain in seven SSTORE2 data contracts. `KilimRenderer` verifies them in its constructor against `geometryHash`, `indexHash` and `pageHash`, and draws every image and metadata document. `Kilim` checks the renderer's code hash, motif count and geometry hash, and forwards its answers. `appearance` is an allow-list of three values. See [docs/RENDERER.md](docs/RENDERER.md).

Open:

- **Assembly.** `KilimWriter` and parts of `KilimRenderer` write memory by pointer for gas reasons. Every writer documents its overrun and slack, and exact-length postconditions guard every document; two review rounds found no defect. This is exactly the code that most needs an independent human review.
- **Read cost.** Reading the 1/1 costs about 22.4M gas and the heaviest possible artwork about 30.4M. Some public RPC endpoints cap `eth_call` at 25M, so those artworks would show blank there; marketplaces use their own infrastructure. Symbols cost at most about 0.48M.
- **Content.** The symbol set is not final. The packer enforces format and scale limits and prints the remaining budget: about 90 more median-size symbols before the 1/1 reaches 24M. Only symbols the artist has rights to may go on-chain; some research images are third-party reference material.
- **Look.** The artist has not yet approved the rendered palette, still image, names and descriptions, and no real marketplace has displayed the media yet.

### K-04 — Medium, external: USDC issuer controls

Location: every token transfer in `ERC20EnglishAuction`.

Exact balance-change checks reject fee-on-transfer behaviour, and SafeERC20 handles false return values. Neither protects against issuer action. Checked on-chain on September 25, 2026: USDC is an upgradeable proxy, `paused()` is false, and `isBlacklisted` exists. Circle can pause all transfers, blacklist this escrow, or upgrade the token; an upgrade adding fees or hooks would make every payout revert with `UnsupportedTokenBehavior`. Accounting would stay correct, but refunds and proceeds would be unavailable until the issuer acted. Bidders who pay with ETH depend on Uniswap and the site's read node for the swap price; the site refuses a quote outside a configured ETH/USD band.

**Status:** Accepted external risk, to be disclosed. Monitoring alerts are in the post-deploy checklist.

### K-05 — Low: timing relies on block timestamps, and extensions have no absolute end

Bidding opens at `startsAt`, the close is set by the first bid, and each late bid moves it to 10 minutes after that bid, with no limit; the only bound is the uint64 timestamp. Timestamps are never used as entropy. A network outage near the close may prevent a bid being answered; there is no administrator restart or cancellation. With no bids, `settle()` reverts with `NoBids` and the 1/1 is never minted.

**Status:** Documented behaviour. The three Slither timestamp findings are retained, not suppressed.

### K-06 — Low: accidental asset donations have no recovery path

Direct ERC-20 transfers and forced ETH create no refunds, credits or proceeds, and there is no rescue function, so they stay locked. This avoids any administrative path to assets backing claims.

**Status:** Deliberate. The site only uses `bid()` with an exact approval.

### K-07 — Medium trust risk, partly mitigated: seller self-bidding

The treasury address cannot bid (`TreasuryCannotBid`). A seller can still bid from other wallets; that is undetectable on-chain.

**Status:** Disclosure matter.

### K-08 — Launch blocker: independent audit, rehearsal and deployment inputs

Still required before funding:

- an independent human audit of the frozen commit, with the renderer's assembly as the priority;
- a Sepolia rehearsal through the website with real wallets;
- the final symbol set and the resulting hashes, published before deployment;
- the published deployer nonce and an inspection window before `startsAt`.

## Protections verified

- **Solvency and liveness.** Stateful fuzzing on the launch rules, at supply caps of 150, 5,000 and 1,000,000, included a hostile receiver that re-enters every entry point. Balance always equals liabilities plus donations, refunds match an independent ledger, and credits are conserved. Every refund, credit, proceeds withdrawal and prize claim can always complete. A blocked or reverting receiver fails only its own call.
- **Bid rules.** `minimumBid()` is exactly the smallest acceptable whole-unit bid across 0–18 decimals and every increment, and the launch ladder is $1, 2, 3 … 10, 11, 13, 15, 17. The clock starts at the first bid. A late bid never shortens the close, including at the exact one-second boundary. Settlement and bidding cannot overlap. The treasury cannot bid.
- **Supply and IDs.** Each symbol ID is reserved once at bid time and minted once, and a burned ID can never be minted again. Symbol, artwork and 1/1 IDs are disjoint. Only the immutable auction can mint, and the 1/1 mints at most once.
- **Composition.** Approved operators cannot weave, expand or freeze someone else's tokens. Duplicate, missing, foreign or already-burned sources revert atomically, and expansion keeps every earlier source exactly once. Artwork cells are packed 8 per storage slot and unpack exactly.
- **Page owner role.** It can only edit collection text and links, change the royalty receiver, and hand over or renounce the role. It cannot mint, move or burn tokens, change art, or touch funds. Collection JSON is escaped.
- **Renderer.** It is byte-identical to the Python reference for every motif path, every symbol, 46 artwork layouts in all three looks, the 1/1 still and page, and every metadata document, plus 70 random differential cases. Its images match the site's drawing code within anti-aliasing for all 812 symbols and all 46 artworks. It works unchanged for stores of 700 and 912 motifs, and every store corruption case is refused.
- **Deployment.** On chain 1 the script refuses any setting other than the launch values. It also refuses a skipped nonce check, a zero inspection window, and the one-shot `run()`. On every chain it refuses mismatched hashes, counts, code or chain.
- **Site.** Bids go from the bidder's own account, never through a router. Approvals go only to the auction, for the exact amount. The ETH swap is exact-output into the bidder's wallet, bounded by slippage and a price band. Every sequential step re-checks the network and account. Log results are filtered by owner.

## Verification results

- **Tests: 202 pass in the CI profile.** That includes 13 fuzz tests at 4,096 runs each and 6 invariants at 256 runs × 128 calls, with zero handler reverts. Beyond that:
  - site: 44 tests pass, plus 1 mainnet-fork test that passes when run against mainnet;
  - page and image comparison: 21 tests pass;
  - packer: 8 tests;
  - alternative geometries: 55 tests on each;
  - FFI differential: 70 cases.
- **Mutation testing:** 169 of 177 mutants killed. The other 8 are equivalent, so every non-equivalent mutant is caught. The first run killed 135; tests were then added for every non-equivalent survivor. Per-mutant results are in `audit/mutation.txt`.
- **Slither:** 30 contracts, 101 detectors. **No high or medium findings.**
  - 4 low: 3 reviewed timestamp comparisons, and 1 calls-loop in `claimSymbols` (one call per reserved range, bounded by the 64-symbol batch).
  - 37 informational: mostly the documented assembly and naming.
- **Gas** (execution before refunds):

  | Action | Gas |
  | --- | --- |
  | 64-symbol claim | 1,837,603 |
  | 64-symbol claim across three bids | 1,929,492 |
  | 256-cell weave | 9,771,795 |
  | 4-to-256-cell expansion | 9,469,352 |

  Reads through `tokenURI`:

  | Token | Gas |
  | --- | --- |
  | Median symbol | about 0.18M |
  | Worst symbol | 0.48M |
  | Heaviest 16 × 16 artwork | 30.4M |
  | The 1/1 | 22.4M |

  A full deployment is about 45.9M gas, with every transaction under 8M. Details are in `audit/gas-render.txt`.
- **Sizes** (runtime bytes; limit 24,576):

  | Contract | Runtime | Initcode |
  | --- | --- | --- |
  | Kilim | 15,314 | — |
  | KilimRenderer | 17,007 | — |
  | KilimAuction | 8,424 | 27,666 |

- **Records:** results are retained in `audit/tests.txt`, `audit/lifecycle.txt`, `audit/slither-summary.json`, `audit/mutation.txt`, `audit/gas-render.txt`, `audit/build.txt`, `audit/dependency-audit.json` and `audit/build-manifest.json`.

These are local EVM tests and internal reviews. They do not prove the absence of bugs, and they are not a substitute for K-08.

## Primary references

- [Solidity 0.8.37 release](https://www.soliditylang.org/blog/2026/09/10/solidity-0.8.37-release-announcement/). The bug list snapshot in `audit/compiler-bugs.json` had no entry applicable to 0.8.37 at review time.
- [OpenZeppelin ERC-721](https://docs.openzeppelin.com/contracts/5.x/api/token/erc721) and [SafeERC20](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20).
- [thirdweb A-15 audit and exact reference hashes](https://0xmacro.com/library/audits/thirdweb-15), its [preceding A-6 review](https://0xmacro.com/library/audits/thirdweb-6), and the [historical buyout incident report](https://blog.thirdweb.com/2023-09-09-vulnerability-auctions-with-a-buyout-price/). None of them audits this adaptation.
- [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825), the per-transaction gas cap of 16,777,216.
