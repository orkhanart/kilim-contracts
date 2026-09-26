# 1. Pre-deploy checklist

Everything that must be true **before the mainnet deployment transaction is sent**. Next: [2-deploy.md](2-deploy.md), then [3-post-deploy.md](3-post-deploy.md).

The contracts have **no admin, pause, upgrade or metadata setter**, and a deployed auction **cannot be stopped**. Anything wrong at deployment is permanent. `[x]` marks items done, checked against the repo on September 25, 2026. K-01 to K-07 refer to findings in [AUDIT.md](../AUDIT.md).

## Timing

- [x] **The auction page still says "Opens Sep 22 · 2:00 PM EST"** (`site/auction.js:100`, `site/chain.js:9`). That date has passed. Remove it, and don't announce a new one until this checklist is complete.
- [x] When a date is set, label the time zone correctly: 18:00 UTC is 2:00 PM **EDT**, not EST. The site's mock also still runs a 22-hour fixed-start auction; the decided rules are a 24-hour clock that starts at the first bid.

## Launch settings

| Setting | Constructor field | Decided | Limits |
| --- | --- | --- | --- |
| Chain | — | **Ethereum mainnet** (decided September 25, 2026) | Chain ID 1. Claiming costs about 95,000 gas per $1 symbol; see the cost table below. |
| Payment | `paymentToken` | **USDC** only in the contract (`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`). The **website** accepts ETH (swapped to USDC) or USDC directly. Refunds are in USDC. | Contract, ≤ 18 decimals, exact transfers, no fee or rebase. |
| Treasury | `treasury` | `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` = **orkhanart.eth** (personal wallet, not a multisig) | Permanent. Cannot bid. The **only** caller of `withdrawProceeds`. |
| Collection page owner | `collectionOwner` | Same wallet: `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` = orkhanart.eth | Page-only role; can be handed over or renounced later. The contract stores the address, not the ENS name. |
| Bids open | `startsAt` | **Open**: the date, expected Monday, September 28. The 24 h countdown starts at the **first bid** (built). If nobody ever bids, the auction waits forever. | Unix **seconds**, in the future at deployment. |
| Duration | `duration` | 24 hours (86,400 s) from the first bid | 1 s to 30 days. |
| Late-bid window | `extensionWindow` | 10 minutes (600 s) | ≤ duration. |
| Maximum extension | — | **No limit**: the auction ends only after 10 quiet minutes (built) | The field was removed from the contract. |
| Opening bid | `reservePrice` | $1 = `1 × 10^decimals` | Whole token units, computed from the token's on-chain `decimals()`. |
| Minimum raise | `incrementBps` | 10% = `1000` | Rounded up to whole dollars: 1, 2, 3 … 10, 11, 13, 15, 17 … |
| Maximum symbols ever | `symbolCap` | No real limit: safety maximum 1,000,000 | Supply is about 11× the final price if bids climb in minimum steps. |
| Maximum per bid | `maxSymbolsPerBid` | No cap (= `symbolCap`) | A bid of N symbols takes ceil(N / 64) claim transactions. |
| Motifs | `motifCount` | **Open**: whatever set is final at deploy (812 today). No additions or edits after deploy. | Read from the final geometry file; must equal it exactly. |
| Largest composition | `maxCells` | 256 | 4–256. |
| Content hashes | `geometryHash`, `rendererHash` | **Open**: computed once the on-chain data is final | Nonzero; computed by the published recipe below. |
| Images | — | **Fully on-chain** (**not built yet**) | Contract-drawn SVG for symbols, artworks and the 1/1. |
| 1/1 media | — | Interactive page served from the chain (**not built yet**) | `animation_url` assembled on-chain; no hosting. |
| On-chain data | — | Uncompressed geometry 105,377 B + 1/1 page 33,523 B | ~6 data contracts, ~28M gas once, deployed **before** the auction. |
| Royalties | — | 5% to the treasury (ERC-2981) (built) | Marketplaces may ignore royalty settings. |

Decided: no real supply limit and no per-bid cap, so the pool cannot be farmed out; one wallet can only inflate supply by holding the top bid, and pays for the 1/1 if nobody outbids it (K-01). For reference, with a binding cap and $1 opening / +10% steps, farming a whole pool would cost:

| `symbolCap` | Per-bid cap | Self-outbids | Last bid it must hold | Peak capital (all refundable if outbid) |
| --- | --- | --- | --- | --- |
| 5,000 | ≥ 1,000 | 47 | $491 | $937 |
| 10,000 | ≥ 1,000 | 54 | $963 | $1,838 |
| 10,000 | 250 | 70 | $4,441 | $8,478 |
| 25,000 | 1,000 | 69 | $4,037 | $7,707 |
| 10,000 | 100 | 122 | out of reach | — |

If bidding never reaches the "last bid" figure, the rest of the pool is never minted. Without a binding per-bid cap, supply ends up about 11× the final price when bids climb in minimum steps.

- [ ] Every open value is decided and written into one signed-off config file. Still open: the final symbol set (and so `motifCount` and the content hashes), and the opening date, which now waits for the symbol set.
- [ ] **Blocker — prove the treasury key works and is backed up.** `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` is a single-key wallet: checked 2026-09-19, it has no contract code on Ethereum and has sent 1,532 transactions there, so the key has worked on the chosen chain. On September 25 it was not blacklisted by USDC.
  - Confirm you still hold this key, with one fresh transaction shortly before deploying.
  - Back up the recovery phrase offline, in two places. If this key is lost, the proceeds and the 1/1 are unrecoverable, and the address can never be changed.
  - Prefer a hardware wallet for this key. A Safe multisig is still the safer option if you change your mind before deploy.
  - Decide in advance where proceeds will go (`withdrawProceeds(to)`): an address that accepts the stablecoin on this chain, not an exchange deposit address.
  - Confirm the stablecoin issuer has not frozen it.
- [x] **USDC** confirmed as the payment token (September 25). Checked on-chain: "USD Coin", USDC, **6 decimals**, not paused. Accept its issuer controls (K-04, to be rewritten for USDC): Circle can upgrade the contract, pause all transfers, and blacklist addresses, including this escrow.
- [x] Ethereum gas checked: on September 25 the base fee was about 0.1 gwei (at most 0.23 over the previous 1,025 blocks) and ETH was $2,693. Costs at three gas prices:

  | Action | 0.1 gwei (today) | 1 gwei | 10 gwei (busy) |
  | --- | --- | --- | --- |
  | Approve USDC (once) | $0.01 | $0.12 | $1.24 |
  | Place a bid | $0.05 | $0.54 | $5.39 |
  | Claim 64 symbols | $1.64 | $16.43 | $164 |
  | Per symbol claimed | $0.03 | $0.26 | $2.56 |
  | Weave 256 cells (largest) | $2.88 | $28.81 | $288 |
  | Store art data and deploy (once) | $9 | $92 | $916 |

  At busy gas a $1 symbol costs more to claim than it is worth. Claims never expire, so bidders can wait for cheap gas; the site should say so.

## Artwork, metadata and marketplaces: code changes

`tokenURI` is fixed forever. Today it still has **no image, no animation, no description and no marketplace traits**, so tokens would show blank. **Blocker.** Decided: fully on-chain (contract-drawn SVG, and the 1/1's interactive page served from the chain).

- [ ] Build the on-chain renderer: `image` as contract-drawn SVG for symbols, artworks and the 1/1, and an `animation_url` for the 1/1 assembled from on-chain data.
- [ ] Add a standard `attributes` array: readable material names, the motif number in the site's numbering, the kind, and for artworks `frozen` and `revision`. Also add a `description`. Marketplaces ignore the current custom top-level keys.
- [x] Marketplace hooks built: a page-only `owner()`, `contractURI()` for the collection page, and fixed 5% ERC-2981 royalties.
- [ ] Confirm with the target marketplace that it accepts this contract and how its collection page is claimed (see the SuperRare questions for Jon).
- [ ] **Finish collecting symbols** (decided September 25: build now, deploy only when the set is final; no symbol additions or drawing changes after deploy). Then regenerate the geometry file, set `motifCount` from it, recompute the content hashes, republish the trait layout, and update the site's motif count (812 today).
- [ ] Publish a **hash recipe**: the algorithm (for example keccak256 of raw bytes) and the exact file. For example `onchain/symbols.bin` (not `.b64`), and the renderer as one bundled file.
- [ ] Store the geometry and the 1/1 page on-chain in data contracts deployed before the auction: uncompressed geometry is 105,377 bytes (5 contracts) and the 1/1 page source 33,523 bytes. Compute both hashes from those exact bytes. This changes the deployment order and the nonce plan.
- [ ] Publish the `appearance` encoding (ink on paper, indigo textile, vermilion print) and how the six material codes render.
- [ ] After the renderer is built, check sizes. The `Kilim` runtime must stay ≤ 24,576 bytes (now 15,066). The `KilimAuction` initcode must stay ≤ 49,152 bytes (now 26,984). An oversized `Kilim` reverts the whole deployment.

## Code freeze and verification

- [x] Owner decisions implemented and tested (99 tests pass, Slither 0 high/medium):
  - treasury cannot bid; refund-and-keep rewards;
  - symbol IDs and traits fixed at bid time, with the ID slippage guard;
  - the clock starts at the first bid; extensions have no limit; with no bids the auction never ends;
  - 5% royalties and the page-only owner role.
- [x] Internal review of the September 18 version: 5 review agents, 2 adversarial verifiers per finding, 34/34 mutants killed.
- [ ] Review round for everything changed since: the new timing, royalties, owner role, and the renderer once built. Rerun the mutation tests (`audit/mutation.txt`).
- [ ] Update README, AUDIT and REUSE for these changes, then regenerate the ABIs and build manifest.
- [ ] Make the first git commit (the repo has **none**), then tag the frozen version.
- [ ] Add a test using the **exact launch config**. The current fixture uses test values: $25, +5%, 10,000 symbols.
- [ ] Rerun on the frozen commit: `pnpm verify:upstream`, `build`, `test:ci`, `fmt`, `audit:static`, `artifacts`. Confirm `audit/build-manifest.json` matches the tag.
- [ ] Confirm each heavy transaction fits the **per-transaction gas cap**, not just the block limit. On Ethereum that cap is 16,777,216 (EIP-7825). With margin for receiver callbacks, check:
  - the 256-cell weave (~10.7M);
  - the 4→256 expand (~10.4M);
  - a claim of 64 one-symbol ranges into a contract wallet (~6.75M).
- [ ] **Independent human audit** of the frozen commit. Fix the findings, then repeat this section.
- [ ] On freeze day, recheck the Solidity 0.8.37 bug list and OpenZeppelin 5.6.1 advisories.

## Deployment tooling and key

- [ ] Write a deployment script (none exists). It reads the signed-off config and **refuses to send** unless every check in [2-deploy.md](2-deploy.md) "Pre-flight" passes.
- [ ] Use a dedicated deployer key, ideally a hardware wallet, and fund it for gas.
- [ ] Choose the inspection window between deployment and `startsAt`, for example 24 hours.
- [ ] Publish before deploy day:
  - the deployer address and its next nonce;
  - the predicted auction and collection addresses;
  - the full trait layout (`symbolTraits(id)` for every ID).

  After publishing, send **no other transaction** from that key.
- [ ] Be accurate about what publishing proves. It gives everyone the same information early. It does **not** prove the layout wasn't picked, because the deployer chose the key and nonce first (K-02). Either disclose that, or rule it out properly: deploy through a published CREATE2 factory with the initcode published in advance, using as salt a pre-announced future public random value.

## Testnet rehearsal

Use the exact launch config except the times. On Ethereum's Sepolia testnet (11155111), use Circle's test USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals, checked September 25) from [faucet.circle.com](https://faucet.circle.com/). Run [2-deploy.md](2-deploy.md) end to end, then:

- [ ] Walk the full flow **through the website**, with several wallets including a Safe:
  1. approve, then bid;
  2. get outbid, then `withdrawRefund`;
  3. claim across several bids;
  4. `weave`, `expand`, `freezeArtwork`, transfer;
  5. after the end: `settle`, `withdrawProceeds` from the treasury, and `claimPrize` by the winner.
- [ ] Place a bid after the symbol pool runs out. It must succeed, with no symbols.
- [ ] Check the two guards: a treasury bid reverts with `TreasuryCannotBid`, and a stale `expectedFirstSymbolId` reverts with `SymbolRangeMoved`.
- [ ] The site's JavaScript trait calculation matches on-chain `symbolTraits` for sample IDs.
- [ ] Measure real gas on the chain for the heavy transactions listed above.
- [ ] Check how tokens display on at least one marketplace or indexer for the chain.

## Website

`site/chain.js` now talks to the contracts: reads from the configured RPC, writes through the wallet, with every transaction simulated first. The items below are implemented and covered by `pnpm test` (the site tests run against a real local anvil) and `pnpm walkthrough`; they still need the testnet rehearsal above. After editing, rebuild with `python3 site/build.py`: the pages inline the scripts, so editing `chain.js` alone changes nothing that gets served. Point the site at a deployment with `pnpm site-config --chain <id> --auction <address> --block <deployment block>`.

- [x] **Bid quote.** Always read from the chain; never recompute.
  - `minimumBid()` gives the next valid amount.
  - `rewardForBid(amount)` gives the symbol count, which is capped and can be 0. Pass it as `minimumReward`.
  - While `rewardForBid(amount) > 0`, pass `expectedFirstSymbolId = collection().FIRST_SYMBOL_ID() + symbolsAllocated()`. **Otherwise pass 0**, or every bid reverts once the pool runs out.
  - On `SymbolRangeMoved`, re-quote and show the new traits. Near the close, consider an "accept any IDs" option, so a reverted bid doesn't cost the bidder the auction.
- [x] **Pay with ETH.** Swap ETH to the exact USDC amount into the bidder's own wallet (exact-output swap), then approve and bid from that same wallet. Where the wallet supports batched calls (EIP-5792), send swap, approve and bid as one confirmation; the bid still comes from the bidder's own account. Show the swap price and fee before confirming, and say refunds come back in USDC.
- [x] **Approval.** Check `allowance` and balance against the full new bid. Re-bids aren't netted against refunds, so offer `withdrawRefund` first. Consider one up-front approval so the late-bid window isn't spent on two transactions.
- [x] **Clock.** Read `startsAt`, `duration` and `endsAt` from the chain, and compare them with the latest block time.
  - Before the first bid, `endsAt` is 0: show "Bidding open — the 24-hour clock starts with the first bid".
  - Start the countdown from `AuctionStarted`, and update `endsAt` from each `BidPlaced`. There is no latest possible close.
  - After `endsAt`, show "Ended, awaiting settlement" with a `settle()` button.
  - Remove the mock's hard-coded open time and 22-hour fixed run.
- [x] **Claims.** Loop `claimSymbols(min(64, credits), to)` until credits reach 0, showing progress from `unclaimedSymbolRanges`.
  - Take minted IDs from the collection's `SymbolsMinted` event, one per range. Ranges aren't contiguous, and `SymbolsClaimed.firstTokenId` is only the first ID.
  - Treat `BidPlaced.firstSymbolId == 0` as "no IDs reserved".
  - Refresh metadata on `MetadataUpdate`.
- [ ] **Winner.** Connect `claimPrize(to)` so the winner, including a Safe, can claim the 1/1. (Connected for injected and EIP-6963 wallets. A Safe still has no path: it needs WalletConnect or a Safe Apps shim.)
- [x] **Holdings.** `Kilim` has no enumeration. List a wallet's tokens from `Transfer` logs since the deployment block, or from an indexer that supports the chain. Include secondary-market symbols.
- [x] **Traits.** Port `symbolTraits` to JavaScript exactly:
  - `seed = keccak256(abi.encode(chainId, collection, id))`;
  - the material roll is `keccak256(abi.encode(seed, "material")) % 100`, with "material" ABI-encoded as a dynamic string;
  - `motif = seed % motifCount`.

  Replace the mock's wallet-based `tokenOf`, and use one motif numbering everywhere.
- [x] **Merge page.** Offer only grids with at most `maxCells()` cells; `merge.js` offers 20×20, 24×24 and 29×28, which revert. Also:
  - build the `expand` flow: pass the current `revision`, include every existing cell exactly once, and make it strictly larger;
  - build the `freezeArtwork` flow;
  - or remove the "add more symbols later" promise.
- [x] **Errors.** Simulate each transaction before sending. Decode reverts using the auction, collection and stablecoin ABIs together. Show a clear next step for `BidTooLow`, `RewardSlippage`, `SymbolRangeMoved`, `NonWholeUnitBid`, `AuctionNotOpen`, `TreasuryCannotBid`, `InvalidQuantity`, and `ERC721InvalidReceiver` (suggest another recipient).
- [ ] **Security.** (The two site items are done: `bid()` is sent from the bidder's own account, including after a pay-with-ETH swap, and the only approval requested is to the configured auction.)
  - Call `bid()` straight from the user's account, never through a router or multicall; credits, refunds and the prize belong to `msg.sender`.
  - Only ever request approval for the published auction address.
  - Lock DNS and hosting accounts.
  - Never ask anyone to send tokens straight to a contract (K-06).
- [x] **Copy that contradicts the contracts:**
  - "Receive randomly assigned symbols" and the FAQ's "randomly assigned" → traits are deterministic and public before bidding.
  - "Every dollar you bid sends you a symbol" and "Mints 250 symbols … in the same transaction" → rewards are capped, can be 0, and are claimed separately, up to 64 at a time.
  - "If outbid · Refunded" → refunds must be withdrawn.
  - Gold listed as a symbol material → gold is only the 1/1.
  - Opening date, time zone and duration → the real schedule.
- [x] Delete or rewrite the unused drafts `site/head.html` and `site/stages.html`. They claim wallet-seeded traits, mint-on-bid, 29 × 28 grids and a 1/1 "stored whole on-chain".

## Disclosures and terms

- [ ] Plain-language terms covering:
  - outbid bidders keep symbols, and one wallet can farm the pool (K-01);
  - traits are public and deterministic, with no randomness or rarity guarantee, and the deployer could have influenced the layout (K-02);
  - the seller can't bid from the treasury, but other wallets are undetectable (K-07);
  - owners can change unfrozen artworks before a sale;
  - stablecoin issuer risks (K-04);
  - no admin, pause or recovery (K-06);
  - chain timing and outages (K-05);
  - the clock starts at the first bid and late bids extend it without limit; the auction ends only after 10 minutes with no new bid, and never ends if nobody bids.
- [ ] Bid only from a wallet that can send transactions later: an EOA, a Safe or a smart wallet. A contract that can't call `withdrawRefund`, `claimSymbols` or `claimPrize` locks its own funds and NFTs.
- [ ] State what the 1/1 gives the winner: token ID 1 with its metadata, where the interactive generator lives, how the winner accesses it, and what license comes with it.
- [ ] Legal review of the terms and of running a stablecoin auction in your jurisdiction.

## Operations readiness

- [ ] Write an incident runbook. It needs:
  - a tested way to switch off the site's bid button and post a banner within minutes;
  - notices written in advance for an issuer pause or freeze, a chain outage near the close, a bug found mid-auction, and a phishing clone;
  - named people on call, with the Safe signers reachable throughout;
  - a public commitment on what the treasury does with proceeds if the result is compromised.
- [ ] Prepare automated alerts, to switch on after deployment ([3-post-deploy.md](3-post-deploy.md)):
  - `paymentToken.balanceOf(auction) < liabilities()`;
  - USDC's `paused()` and `isBlacklisted(auction)`;
  - an `Upgraded` event on the stablecoin proxy. An upgrade that adds fees or hooks would make every payout revert with `UnsupportedTokenBehavior`.

## Go / no-go

- [ ] Every item above is checked. The frozen tag, audit report, config file and published predictions all refer to the same commit and values. Two people sign off.
