# 1. Pre-deploy checklist

Everything that must be true **before the mainnet deployment transaction is sent**. Next: [2-deploy.md](2-deploy.md), then [3-post-deploy.md](3-post-deploy.md).

The contracts have **no admin, pause, upgrade or metadata setter**, and a deployed auction **cannot be stopped**. Anything wrong at deployment is permanent. The auction takes native ETH only; how it works is in [docs/NATIVE-ETH.md](../docs/NATIVE-ETH.md). `[x]` marks items done. K-01 to K-09 and F-01 to F-27 refer to findings in [AUDIT.md](../AUDIT.md).

## Launch settings

| Setting | Where it is fixed | Decided | Limits |
| --- | --- | --- | --- |
| Chain | — | **Ethereum mainnet** | Chain ID 1. |
| Currency | The contract | **Native ETH.** Bids, refunds and proceeds are ETH. | `bid` is payable and `msg.value` must equal the bid. |
| Bid unit | Constant `SYMBOL_PRICE` | **0.001 ETH**: every bid is a whole multiple, and each unit earns one symbol | Not configurable. |
| Registration | Constants `REGISTRATION_TARGET`, `REGISTRATION_BALANCE` | **100 wallets**, each holding at least **0.01 ETH** when it registers; nothing is deposited | Not configurable. Bidding opens only at exactly 100. |
| Treasury | `treasury` | `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` = **orkhanart.eth** (personal wallet, not a multisig) | Permanent. Cannot register or bid. The **only** caller of `withdrawProceeds`. |
| Collection page owner | `collectionOwner` | Same wallet: `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` = orkhanart.eth | Page-only role; can be handed over or renounced later. The contract stores the address, not the ENS name. |
| Registration opens | `startsAt` | **Open**: the date. Registration opens then. Bidding opens at the 100th registration, and the 24 h countdown starts at the **first bid**. | Unix **seconds**, in the future at deployment. |
| Duration | `duration` | 24 hours (86,400 s) from the first bid | 1 s to 30 days. |
| Late-bid window | `extensionWindow` | 10 minutes (600 s) | ≤ duration. |
| Maximum extension | — | **No limit**: the auction ends only after 10 quiet minutes | There is no such field. |
| Opening bid | `reservePrice` | **0.01 ETH** = `10000000000000000` wei; it earns 10 symbols | The constructor accepts only this value (`REGISTRATION_BALANCE`). |
| Minimum raise | `incrementBps` | 10% = `1000` | Rounded up to a whole 0.001 ETH: 0.01, 0.011, 0.013, 0.015, 0.017 … |
| Maximum symbols ever | `symbolCap` | 1,000,000 | At most 2^32 − 3. |
| Maximum per bid | `maxSymbolsPerBid` | No smaller cap (= `symbolCap`) | A bid of N symbols takes ceil(N / 64) claim transactions. |
| Motifs | `motifCount` | **Open**: decided 1,024; the packed store holds 812. No additions or edits after deploy. | Read from the final geometry file by `onchain/pack_store.py`; Kilim checks it against the renderer. |
| Largest composition | `maxCells` | 256 | 4–256. |
| Content hashes | `geometryHash`, `rendererHash` | **Open**: computed once the on-chain data is final | Nonzero; recipe in [docs/RENDERER.md](../docs/RENDERER.md). Kilim checks both against the renderer. |
| Images | — | **Fully on-chain** (built: `KilimRenderer`) | Contract-drawn SVG for symbols, artworks and the 1/1. |
| 1/1 media | — | Interactive page served from the chain (built) | `animation_url` assembled on-chain; no hosting. |
| On-chain data | — | STORE for today's 812 motifs: header 64 B + uncompressed geometry 105,377 B + index 12,992 B + 1/1 page 34,949 B = 153,382 B | 7 data contracts (33.5M gas) and the renderer (6.9M), deployed by CREATE2 **before** the auction. Changes with the final set. |
| Royalties | — | 5% to the treasury (ERC-2981) (built) | Marketplaces may ignore royalty settings. |

What these settings mean, accepted by the artist on October 9, 2026:

- **One wallet can take the whole symbol pool for gas (F-04, K-01).** A wallet that outbids itself gets its ETH back when outbid and keeps every symbol it reserved. Along the minimum steps, 93 bids reserve all 1,000,000 symbols and end at a top bid of about 93.9 ETH. If nobody outbids that wallet, it has bought the 1/1 at that price. After the pool is empty, bids earn no symbols.
- **One actor can fill the 100 registrations and choose when the clock starts (F-03).** Registration checks a balance, not a person.
- **Bidding never opens below 100 registrations (F-10).** There is no fallback date. The artist keeps promoting until the count is reached.

- [ ] Every open value is decided and written into one signed-off config file. Still open: the final symbol set (and so `motifCount` and the content hashes), and the opening date, which waits for the symbol set.
- [ ] **Blocker — prove the treasury key works and is backed up.** `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` is a single-key wallet: checked 2026-09-19, it has no contract code on Ethereum and has sent 1,532 transactions there, so the key has worked on the chosen chain.
  - Confirm you still hold this key, with one fresh transaction shortly before deploying.
  - Back up the recovery phrase offline, in two places. If this key is lost, the proceeds are unrecoverable, and the address can never be changed.
  - Prefer a hardware wallet for this key. A Safe multisig is still the safer option if you change your mind before deploy.
  - Decide in advance where proceeds will go (`withdrawProceeds(to)`): an address that can receive ETH, and not an exchange deposit address that only credits plain transfers.
- [ ] Check live Ethereum gas shortly before the date and tell bidders what to expect. Gas per action, measured locally on September 26 and to be re-measured on Sepolia:

  | Action | Gas |
  | --- | --- |
  | Register | about 80,000 (sponsored registration of a plain account, measured October 8) |
  | Place a bid | not yet measured for the ETH auction. A bid that outbids someone reverts with `InsufficientGas` unless about 212,000 is left at the refund, on top of what the bid itself uses. Send a fixed 500,000 until the rehearsal gives a number; unused gas is not charged |
  | Claim 64 symbols | about 1.84M, up to 1.93M across three bids |
  | Per symbol claimed | about 29,000 |
  | Weave 256 cells (largest) | about 9.77M |
  | Settle | not yet measured. About 558,000 must be left at the prize step, on top of what settlement itself uses. Send a fixed 800,000 until the rehearsal gives a number |
  | Store art data and deploy (once) | about 45.9M in total, every transaction under 8M |

  At busy gas a single symbol costs more to claim than the 0.001 ETH it stands for. Claims never expire, so bidders can wait for cheap gas; the site must say so.

## Artwork, metadata and marketplaces

`tokenURI` is fixed forever. Decided: fully on-chain (contract-drawn SVG, and the 1/1's interactive page served from the chain). Built: `KilimRenderer` draws every token from on-chain data, and `Kilim.tokenURI` forwards its answer. See [docs/RENDERER.md](../docs/RENDERER.md).

- [x] Build the on-chain renderer: `image` as contract-drawn SVG for symbols, artworks and the 1/1, and an `animation_url` for the 1/1 assembled from on-chain data.
- [x] Add a standard `attributes` array: readable material names, the motif number in the site's numbering, the kind, and for artworks `frozen` and `revision`. Also add a `description`.
- [ ] Artist review of the rendered look before freezing: symbol palette and cotton-rag emboss, the 1/1 still (the page's opening frame), token names and descriptions, the Azerbaijani material trait, and the 1/1 relief view's older material set. All are named constants in `KilimRenderer.sol` and `onchain/render_ref.py`.
- [x] Marketplace hooks built: a page-only `owner()`, `contractURI()` for the collection page, and fixed 5% ERC-2981 royalties.
- [ ] Confirm with the target marketplace that it accepts this contract and how its collection page is claimed. Get written confirmation that it renders a `data:text/html` `animation_url` and ~330 KB base64 `tokenURI`s.
- [ ] **Finish the symbol set** (build now, deploy only when the set is final; no symbol additions or drawing changes after deploy). The decision is 1,024 motifs; the packed store holds 812. Then run `pnpm pack` (it sets `motifCount`, the hashes and the 1/1's opening frame from the geometry, and prints the gas budget left), republish the trait layout, and update the site's motif count. With today's drawings about 90 more symbols of median size fit before the 1/1 reaches its 24M read target, so 1,024 needs lighter drawings or a higher target: decide which (K-03, F-14).
- [x] Publish a **hash recipe**: [docs/RENDERER.md](../docs/RENDERER.md). `geometryHash` is keccak256 of the stored uncompressed geometry, not of `symbols.bin`; `rendererHash` is the renderer's EXTCODEHASH, predictable because it is deployed by CREATE2.
- [x] Store the geometry and the 1/1 page on-chain in data contracts deployed before the auction (`script/DeployKilim.s.sol`, store phase).
- [x] Publish the `appearance` encoding: `bytes32` `flat/ink`, `flat/indigo`, `flat/vermilion`; anything else reverts.
- [x] Sizes checked against `audit/build-manifest.json`: `Kilim` runtime 15,314 bytes and `KilimAuction` runtime 10,967 (limit 24,576); `KilimAuction` initcode 30,349 (limit 49,152). The renderer runtime is 17,007 bytes. Check again at the freeze.

## Code freeze and verification

- [x] Owner decisions implemented:
  - native ETH only; 100 registrations before bidding; 0.01 ETH opening bid; 0.001 ETH per symbol;
  - treasury cannot bid; refund-and-keep rewards;
  - symbols are claimed by the bidder, never sent;
  - symbol IDs and traits fixed at bid time, with the ID slippage guard;
  - the clock starts at the first bid; extensions have no limit; with no bids the auction never ends;
  - 5% royalties and the page-only owner role.
- [x] Internal review rounds of September 18 and 26 (collection and renderer unchanged since).
- [x] Full internal audit of the ETH auction, October 9: F-01 and F-02 fixed with tests in `test/GasFloors.t.sol`; F-03, F-04 and F-10 accepted by the artist.
- [ ] Decide each open item in the October 9 list ([AUDIT.md](../AUDIT.md), "Open"): fix it, test it, or write down why not. F-05 (no test pins the two gas caps) and F-06 (the refund cap is larger than needed) can only be changed before deployment.
- [x] Every auction test runs against the ETH-only contracts: bid rules, extension and close, settlement, deferred-refund accounting, the constructor rule, the deploy script's refusals, registration before `startsAt` and by the treasury, and stateful invariants with hostile receivers (F-15, F-16, F-17). On October 9 the forge suite passed 236 tests in the working tree.
- [ ] Add the tests still missing: a ceiling on the gas a hostile refund receiver or winner can cost (F-05) and an independent rebuild of the registration signature domain (F-18).
- [ ] Internal review round and mutation testing on the ETH-only auction. Nothing has read the code since the removal.
- [ ] Tag the frozen version once the symbol set and settings are final.
- [ ] Rerun on the frozen commit: `pnpm verify:upstream`, `build`, `test:ci`, `fmt`, `audit:static`, `artifacts`. Confirm `audit/build-manifest.json` matches the tag.
- [x] Locally confirmed on September 26 (weave 9.77M, expand 9.47M, worst claim about 6.75M; re-measure on Sepolia) that each heavy transaction fits the **per-transaction gas cap**, not just the block limit. On Ethereum that cap is 16,777,216 (EIP-7825). With margin for receiver callbacks, check:
  - the 256-cell weave (~10.7M);
  - the 4→256 expand (~10.4M);
  - a claim of 64 one-symbol ranges into a contract wallet (~6.75M);
  - each data chunk (≤5.4M), the renderer (~6.9M) and the auction with its collection (re-measure: the auction is smaller than when ~5.5M was recorded).

  `tokenURI` is an `eth_call`, not a transaction: the heaviest artwork needs ~30.4M and the 1/1 ~22.4M. Some RPC backends cap `eth_call` at 25M, so the 1/1 is kept under 24M; see docs/RENDERER.md.
- [ ] **Independent human audit** of the frozen commit. Fix the findings, then repeat this section. This is a launch blocker (K-08).
- [ ] On freeze day, recheck the Solidity 0.8.37 bug list and OpenZeppelin 5.6.1 advisories.

## Deployment tooling and key

- [x] Deployment script: `script/DeployKilim.s.sol`. It reads the signed-off config (templates: `deploy/mainnet.example.json`, `deploy/sepolia.example.json`) and **refuses to send** on any mismatch (chain, hashes, chunk files, CREATE2 addresses, gas, golden answers, renderer hash, reserve price, schedule, nonce, read-back). On chain 1 it also refuses any auction setting other than the decided values in the table above, a skipped nonce check and a zero inspection window. Still to check by hand: the [2-deploy.md](2-deploy.md) "Pre-flight" items it cannot see (signed-off config, treasury key access, git tag, deployer ETH).
- [ ] The script's refusals are covered by `test/DeployKilim.t.sol`; confirm it passes at the frozen commit.
- [ ] Use a dedicated deployer key, ideally a hardware wallet, and fund it with ETH for gas.
- [ ] Choose the inspection window between deployment and `startsAt`, for example 24 hours. It goes in the config as `minLeadSeconds`; the script refuses 0 on chain 1 and accepts any other value, so check the number by hand (F-26).
- [ ] Publish before deploy day:
  - the deployer address and its next nonce;
  - the predicted auction and collection addresses;
  - the full trait layout (`symbolTraits(id)` for every ID).

  After publishing, send **no other transaction** from that key.
- [ ] Be accurate about what publishing proves. It gives everyone the same information early. It does **not** prove the layout wasn't picked, because the deployer chose the key and nonce first (K-02). Either disclose that, or rule it out properly: deploy through a published CREATE2 factory with the initcode published in advance, using as salt a pre-announced future public random value.

## Sponsored registration (optional)

`registerFor` lets a sponsor wallet pay the gas for a supporter's registration. The service is in `registration-relayer/` and is **not activated**.

- [ ] Decide whether to run it. Without it, each supporter pays the gas for `register()`.
- [ ] If yes: a dedicated sponsor wallet (never the treasury or the deployer), a spending limit, persistent hosting and an HTTPS endpoint, as `registration-relayer/README.md` describes. Read F-08 (an attacker can burn the sponsor's budget) and F-09 (wallets with code cannot use this path and need a direct `register()` button) first.

## Testnet rehearsal

Use the exact launch config except the times, on Sepolia (11155111) with test ETH. Run [2-deploy.md](2-deploy.md) end to end, then:

- [ ] Walk the full flow **through the website**, with several wallets including a Safe:
  1. register wallets until the count is 100, directly and, if it will be used, through the sponsor; confirm a bid before the 100th reverts with `RegistrationIncomplete` and the 101st registration reverts with `RegistrationClosed`;
  2. place the opening bid of 0.01 ETH and see the clock start;
  3. get outbid and see the ETH come back in the same transaction (`RefundPaid`);
  4. force one deferred refund with a contract bidder that rejects ETH (`RefundDeferred`), then `withdrawRefund` it to another address;
  5. claim symbols across several bids, 64 at a time;
  6. `weave`, `expand`, `freezeArtwork`, transfer;
  7. after the end: `settle` and see the 1/1 arrive in the winner's wallet; `withdrawProceeds` from the treasury;
  8. repeat the end with a winner contract that rejects the 1/1 (`PrizeDeliveryFailed`), then `claimPrize(to)`.
- [ ] Send a bid and a `settle()` with too little gas: each must revert with `InsufficientGas` and change nothing.
- [ ] Place a bid after the symbol pool runs out. It must succeed, with no symbols.
- [ ] Check the guards: a treasury bid and a treasury registration revert with `TreasuryCannotBid`; a stale `expectedFirstSymbolId` reverts with `SymbolRangeMoved`; a bid whose value differs from its amount reverts with `IncorrectPayment`; a plain ETH transfer to the auction reverts.
- [ ] The site's JavaScript trait calculation matches on-chain `symbolTraits` for sample IDs.
- [ ] Measure real gas on the chain for the actions in the table above.
- [ ] Check how tokens display on at least one marketplace or indexer for the chain.
- [ ] Media: fetch a worst-case 16x16 artwork, the largest cotton-rag symbol and the 1/1 through the target marketplaces, MetaMask/Rainbow, Etherscan and one indexer; record response times. Open the 1/1 in a sandboxed iframe, under a parent CSP with `script-src 'self'` (the static still must show), and on a phone.
- [ ] Probe the `eth_call` gas cap of the RPC providers those marketplaces use (a gas-burner call with and without a gas field); anything below 25M would blank the 1/1.

## Website

The pages inline their scripts, so after editing rebuild with `python3 site/build.py`. Point the site at a deployment with `pnpm site-config --chain <id> --auction <address> --block <deployment block>`. Every item below must be checked against the ETH-only contracts in the rehearsal above.

- [ ] **Registration.** Show `registrationCount()` out of 100 and whether the connected wallet is `registered`. Say plainly that registering deposits nothing, gives no priority and no symbols, and is not required to bid. Offer `register()` directly, also when a sponsor is configured (F-09).
- [ ] **Bid quote.** Always read from the chain; never recompute.
  - `minimumBid()` gives the next valid amount, in wei.
  - `rewardForBid(amount)` gives the symbol count, which is capped and can be 0. Pass it as `minimumReward`.
  - If the page does not show which symbol IDs a bid reserves, pass `expectedFirstSymbolId = 0`. If it does, pass `collection().FIRST_SYMBOL_ID() + symbolsAllocated()` while `rewardForBid(amount) > 0`, and re-quote on `SymbolRangeMoved`.
- [ ] **Bid transaction.** One payable call from the bidder's own account with `value` equal to the amount, and a fixed generous gas limit (500,000 until the rehearsal gives a number) rather than a bare estimate. Check the wallet's ETH balance against the full new bid plus gas: a re-bid is not netted against the bidder's own earlier bid.
- [ ] **Clock.** Read `startsAt`, `duration` and `endsAt` from the chain, and compare them with the latest block time.
  - Before 100 registrations: show the count, no countdown.
  - After 100 and before the first bid, `endsAt` is 0: show "Bidding open — the 24-hour clock starts with the first bid".
  - Start the countdown from `AuctionStarted`, and update `endsAt` from each `BidPlaced`. There is no latest possible close.
  - After `endsAt`, show "Ended, awaiting settlement" with a `settle()` button that sends a fixed 800,000 gas until the rehearsal gives a number.
- [ ] **Claims.** Symbols are claimed by the bidder: loop `claimSymbols(min(64, credits), to)` until `symbolCredits` reaches 0. Show the number of transactions and the estimated gas before a large bid.
  - Take minted IDs from the collection's `SymbolsMinted` event, one per range. Ranges aren't contiguous, and `SymbolsClaimed.firstTokenId` is only the first ID.
  - Treat `BidPlaced.firstSymbolId == 0` as "no IDs reserved".
  - Refresh metadata on `MetadataUpdate`.
- [ ] **Refunds.** Show `refunds(wallet)` and a `withdrawRefund` button only when it is nonzero. Tell an outbid bidder whose refund was deferred (`RefundDeferred`).
- [ ] **Winner.** After `settle()`, the winner normally holds the 1/1 already. Show `claimPrize(to)` only when `prizeClaimed` is false after settlement. A Safe still needs a connection path (WalletConnect or a Safe Apps shim).
- [x] **Holdings.** `Kilim` has no enumeration. List a wallet's tokens from `Transfer` logs since the deployment block, or from an indexer that supports the chain. Include secondary-market symbols.
- [x] **Traits.** `symbolTraits` ported to JavaScript exactly (`site/traits.js`):
  - `seed = keccak256(abi.encode(chainId, collection, id))`;
  - the material roll is `keccak256(abi.encode(seed, "material")) % 100`, with "material" ABI-encoded as a dynamic string;
  - `motif = seed % motifCount`.
- [x] **Merge page.** Only grids with at most `maxCells()` cells; the `expand` flow passes the current `revision`, includes every existing cell exactly once and is strictly larger; the `freezeArtwork` flow exists.
- [ ] **Errors.** Simulate each transaction before sending. Decode reverts using the auction and collection ABIs together. Show a clear next step for `RegistrationIncomplete`, `RegistrationClosed`, `AlreadyRegistered`, `InsufficientRegistrationBalance`, `BidTooLow`, `NonWholeUnitBid`, `IncorrectPayment`, `InsufficientGas`, `RewardSlippage`, `SymbolRangeMoved`, `AuctionNotOpen`, `TreasuryCannotBid`, `InvalidQuantity`, and `ERC721InvalidReceiver` (suggest another recipient).
- [ ] **Security.**
  - Call `bid()` straight from the user's account, never through a router or multicall; credits, refunds and the prize belong to `msg.sender`.
  - The only transactions the site asks for go to the published auction and collection addresses.
  - Lock DNS and hosting accounts.
  - Never ask anyone to send ETH straight to a contract: a plain transfer to the auction reverts (K-06).
- [ ] **Copy that must match the contracts:**
  - traits are deterministic and public before bidding, not random;
  - rewards are capped, can be 0, and are claimed separately by the bidder, up to 64 at a time, at the bidder's gas cost;
  - outbid ETH comes back in the transaction that outbids, with a withdrawal fallback; gas is not refunded;
  - registration gives no right and is not needed to bid;
  - gold is only the 1/1, not a symbol material;
  - the opening date, time zone and duration are the real schedule.

## Disclosures and terms

- [ ] Plain-language terms covering:
  - outbid bidders keep symbols, and one wallet can take the whole pool by outbidding itself (K-01, F-04);
  - registration counts addresses, one actor can fill it and start the clock, and bidding never opens below 100 (F-03, F-10, F-11);
  - traits are public and deterministic, with no randomness or rarity guarantee, and the deployer could have influenced the layout (K-02);
  - the seller can't bid from the treasury, but other wallets are undetectable (K-07);
  - owners can change unfrozen artworks before a sale;
  - no admin, pause or recovery (K-06);
  - chain timing and outages (K-05);
  - the clock starts at the first bid and late bids extend it without limit; the auction ends only after 10 minutes with no new bid, and never ends if nobody bids;
  - a pending bid has no deadline and can land later at the amount signed (F-24).
- [ ] Bid only from a wallet that can send transactions later: an EOA, a Safe or a smart wallet. A contract that can neither receive ETH nor call `withdrawRefund`, or cannot call `claimSymbols` or `claimPrize`, locks its own funds and NFTs (F-19).
- [ ] State what the 1/1 gives the winner: token ID 1 with its metadata, where the interactive generator lives, how the winner accesses it, and what license comes with it.
- [ ] Legal review of the terms and of running this auction in your jurisdiction.

## Operations readiness

- [ ] Write an incident runbook. It needs:
  - a tested way to switch off the site's bid button and post a banner within minutes (the auction itself cannot be stopped);
  - notices written in advance for a chain outage near the close, a bug found mid-auction, registrations stalling below 100, and a phishing clone;
  - named people on call for the whole auction;
  - a public commitment on what the treasury does with proceeds if the result is compromised.
- [ ] Prepare automated alerts, to switch on after deployment ([3-post-deploy.md](3-post-deploy.md)):
  - `address(auction).balance < liabilities()`: must never happen;
  - every `RefundDeferred`: a bidder has ETH waiting in `refunds`;
  - `PrizeDeliveryFailed`: the winner must call `claimPrize`;
  - every `Registered`, `AuctionStarted` and `BidPlaced`.

## From the October 2026 attack research

Source: `reports/Auction contract attack patterns 2026.md` (67 items). The contract items are tested in `test/AttackPatterns.t.sol`; these are the decisions and steps that remain.

- [ ] **Decide `tokenURI` and the 16,777,216-gas line.** The 1/1 reads at 22.4M gas and the largest artworks at 17.3M to 30.4M. After Glamsterdam some nodes (Reth, Nethermind as of 2026-10-10) refuse reads above 16,777,216. Either bring every token under it (a lighter 1/1 render and a smaller `maxCells`, about 100) or accept in writing that the heaviest tokens depend on RPC policy. This cannot be changed after deployment.
- [ ] **After 2026-11-01** (EIP-8037 leaves Last Call): re-run the Glamsterdam projections in `test/AttackPatterns.t.sol` with the final prices, then run the whole lifecycle on Sepolia, which already runs Glamsterdam: register, bid, outbid an EOA, a Safe and a refusing wallet, settle to a first-time holder, claim 64, weave. Re-measure the page's bid and settle gas limits and the relayer's `gasLimit` and budget (a registration writes one new slot).
- [ ] **Deploy the data store before Glamsterdam reaches mainnet.** Code deposit rises from 200 to 1,530 gas per byte.
- [ ] **Separate the keys.** The deploy script pins the treasury and the collection-page owner to one address. Decide whether the page role moves to a low-value key or is renounced after launch. No key used for the launch may carry an EIP-7702 delegation.
- [ ] **Domain.** Registrar with no account recovery by support, registry lock on, DNSSEC validating, CAA records set; monitor NS, A and DS records and certificate-transparency logs; announce a fallback (direct contract instructions) beforehand. Every 2025 and 2026 front-end theft in the report began with a persuaded support agent.
- [ ] **Site hardening not built yet:** a scheduled check that each served page hashes to the tagged build; a check after sending that the mined transaction's `to`, `value` and `data` are what the page built; two independent RPC providers that must agree before the bid button is live; a raised priority fee and a high max fee for bids in the last ten minutes, sent to the public mempool.
- [ ] **Real smart wallets on a fork:** `registerFor` with a Safe (with and without its fallback handler) and a Coinbase Smart Wallet. OpenZeppelin 5.6.1 sends ERC-1271 calldata without zero padding (5.7.0 pads it).
- [ ] **Marketplaces on a testnet:** mint throwaway tokens and check how OpenSea, Etherscan and the main wallets show the SVG image and the `data:text/html` animation.
- [ ] **Say it plainly on the site and in the terms:** registration is a counter of 100 wallets, not a list of who may bid; one wallet outbidding itself earns about eleven times the symbols of one bid; refunds and the 1/1 are sent automatically when the receiving wallet allows it and are otherwise withdrawn or claimed; the site never asks for a token approval, a permit or a wallet delegation.
- [ ] **The weeks before the launch:** no remote control in calls, no scripts or repositories from new contacts, review the apps connected to the X account, freeze wallet-extension updates, and verify the payout address on the device against a written copy.

## Go / no-go

- [ ] Every item above is checked. The frozen tag, audit report, config file and published predictions all refer to the same commit and values. Two people sign off.
