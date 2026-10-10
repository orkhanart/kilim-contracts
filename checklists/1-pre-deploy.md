# 1. Pre-deploy checklist

Everything that must be true **before the mainnet deployment transactions are sent**. Next: [2-deploy.md](2-deploy.md), then [3-post-deploy.md](3-post-deploy.md).

The contracts have **no admin, pause, upgrade or metadata setter**, and a deployed auction **cannot be stopped**. Anything wrong at deployment is permanent. The auction takes native ETH only; how it works is in [docs/NATIVE-ETH.md](../docs/NATIVE-ETH.md), and what is stored on the chain and how it is checked is in [docs/STORAGE.md](../docs/STORAGE.md). `[x]` marks items done. K-01 to K-09, F-01 to F-27 and R-01 to R-20 refer to findings in [AUDIT.md](../AUDIT.md).

## Launch settings

| Setting | Where it is fixed | Decided | Limits |
| --- | --- | --- | --- |
| Chain | — | **Ethereum mainnet** | Chain ID 1. |
| Currency | The contract | **Native ETH.** Bids, refunds and proceeds are ETH. | `bid` is payable and `msg.value` must equal the bid. |
| Bid unit | Constant `MOTIF_PRICE` | **0.001 ETH**: every bid is a whole multiple, and each unit earns one motif | Not configurable. |
| Registration | Constants `REGISTRATION_TARGET`, `REGISTRATION_BALANCE` | **100 wallets**, each holding at least **0.01 ETH** when it registers; nothing is deposited | Not configurable. Bidding opens only at exactly 100. |
| Deployer | `deployer` in the config | `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` = **orkhanart.eth** (decided 10 October) | The script refuses any other on chain 1. The three contract addresses follow from this address and its nonce. |
| Treasury and royalty receiver | `treasury` in the auction; `royaltyReceiver` in both token contracts | The same wallet, orkhanart.eth (personal wallet, not a multisig) | Permanent. Cannot register or bid. The **only** caller of `withdrawProceeds`. The contracts store the address, not the ENS name. |
| Registration opens | `startsAt` | **Open**: the date. Registration opens then. Bidding opens at the 100th registration, and the 24 h countdown starts at the **first bid**. | Unix **seconds**, in the future at deployment. |
| Duration | `duration` | 24 hours (86,400 s) from the first bid | 1 s to 30 days. |
| Late-bid window | `extensionWindow` | 10 minutes (600 s) | ≤ duration. |
| Maximum extension | — | **No limit**: the auction ends only after 10 quiet minutes | There is no such field. |
| Opening bid | `reservePrice` | **0.01 ETH** = `10000000000000000` wei; it earns 10 motifs | The constructor accepts only this value (`REGISTRATION_BALANCE`). |
| Minimum raise | `incrementBps` | 10% = `1000` | Rounded up to a whole 0.001 ETH: 0.01, 0.011, 0.013, 0.015, 0.017 … |
| Maximum motif tokens ever | `motifCap`, a constructor argument of `KilimMotifs`; the auction reads it from there | 1,000,000 | 1 to 2^32 − 1. Token ids are 1..motifCap. |
| Maximum per bid | `maxMotifsPerBid` | No smaller cap (= `motifCap`) | 1..motifCap. A bid of N motifs takes ceil(N / 64) claim transactions. |
| The motifs | `MOTIF_COUNT` = 1,024; the grids and names in chunks | **1,024**, from the artist's page (`research/motifs/curate/living-language-v3/index.html`). No additions or edits after deploy. | Packed by `onchain/pack_motifs.py`; the packer and the script refuse any other count. **Open:** the artist's final file. |
| Content hashes | `gridsHash`, `namesHash` (motifs); `prefixHash`, `headHash`, `tailHash` (the 1/1) | **Open**: final once the artwork file and the still are; today's values are for the stand-in page | Recipe in [docs/STORAGE.md](../docs/STORAGE.md). Each constructor re-reads its chunks and refuses a mismatch. |
| Names | The code (`KilimMotifs`) and the config (`oneOfOne.name`) | **Motif Bazaar** / `MOTIF`; **The Unwoven Kilim** / `UNWOVEN` (the artist, 10 October). `KILIM` is reserved for Kilim Bazaar. | The script refuses any other 1/1 name on chain 1, and on every chain a name that differs from the packed page. |
| Images | — | **Fully on-chain**: a contract-drawn SVG per motif (built) | 20 × 20 units, white paper, the motif at (2, 2) in `#141414`. |
| 1/1 media | — | The page served from the chain (built): a PNG still as `image`, the loader with the gzipped artwork as `animation_url` | The grids come live from the motif contract when the token is read. |
| On-chain data | — | Grids 32,768 B (2 chunks) + names 13,739 B (1) + page prefix 393 B, head 196 B, tail 808,872 B (1 + 1 + 33 chunks), with the stand-in page | 38 chunks, about 202.0M gas, deployed by CREATE2 **before** the contracts. Changes with the final page. |
| Royalties | `ROYALTY_BPS` | 5% to the treasury (ERC-2981) on both contracts (built) | Fixed. Marketplaces may ignore royalty settings. |

What these settings mean, accepted by the artist on October 9, 2026:

- **One wallet can take the whole motif pool for gas (F-04, K-01).** A wallet that outbids itself gets its ETH back when outbid and keeps every motif it reserved. Along the minimum steps, 93 bids reserve all 1,000,000 motifs and end at a top bid of about 93.9 ETH. If nobody outbids that wallet, it has bought the 1/1 at that price. After the pool is empty, bids earn no motifs.
- **One actor can fill the 100 registrations and choose when the clock starts (F-03).** Registration checks a balance, not a person.
- **Bidding never opens below 100 registrations (F-10).** There is no fallback date. The artist keeps promoting until the count is reached.

- [ ] Every open value is decided and written into one signed-off config file (`deploy/mainnet.example.json`, every TODO filled in). Still open: the final artwork file and still (and so the page hashes and the 1/1's golden), and the opening date, which waits for the artwork.
- [ ] **Blocker — prove the wallet's key works and is backed up.** `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` is a single-key wallet, and it now deploys as well as receiving proceeds and royalties: checked 2026-09-19, it has no contract code on Ethereum and had sent 1,532 transactions there, so the key has worked on the chosen chain.
  - Confirm you still hold this key, with one fresh transaction shortly before deploying, and before publishing the nonce: nothing may be sent from it between publishing and deploying.
  - Back up the recovery phrase offline, in two places. If this key is lost, the proceeds are unrecoverable, and the address can never be changed.
  - Decide where the key lives (a hardware wallet or an app): the three contract deployments are signed with it, through `forge script --ledger` or an equivalent that never exports the key. The deployer must be a plain account: a Safe or another contract wallet cannot be the deployer with this script.
  - Decide in advance where proceeds will go (`withdrawProceeds(to)`): an address that can receive ETH, and not an exchange deposit address that only credits plain transfers.
- [ ] Check live Ethereum gas shortly before the date and tell bidders what to expect. Gas per action, measured locally on 10 October 2026 (forge, the packed stand-in store) and to be re-measured on Sepolia:

  | Action | Gas |
  | --- | --- |
  | Register | about 80,000 (sponsored registration of a plain account, measured October 8) |
  | Place the first bid (nobody to refund) | under 250,000 |
  | Place a bid that outbids someone | **succeeds from 523,590**; below that it reverts with `InsufficientGas` (it must reach the refund with 452,380 left: the 150,000 allowance, 1/64 for EIP-150 and the 300,000 kept back for a deferred refund). The site sends a fixed 1,500,000; unused gas is not charged |
  | Claim 64 motifs | 1,790,852 across three bids (execution, before refunds); about 28,000 per motif |
  | Settle | **succeeds from 585,900** (557,936 must be left at the prize step); the site sends 1,200,000 |
  | Burn a motif (its owner) | not measured; one ERC-721 burn and a bitmap write |
  | Deploy the store (once, 38 chunks) | about 202.0M in all, the largest chunk 5,876,690 |
  | Deploy the three contracts (once) | 3,226,366 + 5,600,491 + 3,150,749 |
  | Read `tokenURI` (an `eth_call`, not a transaction) | a motif 287,311; the 1/1 3,838,101 |

  At busy gas a single motif costs more to claim than the 0.001 ETH it stands for. Claims never expire, so bidders can wait for cheap gas; the site must say so.

## Artwork, metadata and marketplaces

`tokenURI` is fixed forever. Decided: fully on-chain. Built: `KilimMotifs.tokenURI` draws each motif from the stored grids, and `KilimOneOfOne.tokenURI(1)` serves the stored page with the grids read live from the motif contract. See [docs/STORAGE.md](../docs/STORAGE.md).

- [x] Motif token: `image` a contract-drawn SVG; `name` "<Name> (motif <n>)"; `attributes` Motif (1..1024) and Name; the collection `description`.
- [x] The 1/1: the still as `image`, the page as `animation_url`, assembled on-chain in one buffer; `contractURI()` and fixed 5% ERC-2981 royalties on both contracts; no owner role (F-13 closed).
- [x] A hash recipe and a re-pack procedure: [docs/STORAGE.md](../docs/STORAGE.md). Every chunk's CREATE2 address is known before deploy; the deploy dry run checks both tokenURIs against the packers' goldens.
- [x] The chunks are deployed before the contracts (`runStore`), by any funded key, idempotently.
- [x] Sizes checked against `audit/build-manifest.json` (creation / runtime bytes; limits 49,152 / 24,576): `KilimMotifs` 13,343 / 10,808, `KilimOneOfOne` 12,062 / 9,921, `KilimAuction` 13,635 / 10,885. Check again at the freeze.
- [ ] **The final artwork file** (the artist; `onchain/ARTWORK-ONCHAIN.md` says what it must do: read `KILIM_GRIDS`, start with a doctype, be as small as the work allows) and **the still image** (which frame). Today's store holds the stand-in `onchain/test/fixtures/lean.html` and a placeholder PNG. Then re-pack (STORAGE.md), update the config texts, rerun `pnpm -s test:pack`, `test:page`, `test:contracts` and `deploy:dry`, and republish the hashes and chunk addresses.
- [ ] Artist review of the tokens before the freeze: the motif token's look (paper, ink, offset), the names as the page gives them (29 distinct names, not unique), the collection and 1/1 descriptions and external URLs (packed into the goldens, fixed at deployment), the still.
- [ ] Confirm with the target marketplace that it accepts these contracts and how the two collection pages are claimed. Get written confirmation that it renders a `data:text/html` `animation_url` of about 600 KB and a `tokenURI` of about 900 KB served as `data:application/json;utf8,` (not base64), and that the 1/1 loads in its frame (the loader needs `DecompressionStream`).

## Code freeze and verification

- [x] Owner decisions implemented:
  - native ETH only; 100 registrations before bidding; 0.01 ETH opening bid; 0.001 ETH per motif;
  - treasury cannot bid; refund-and-keep rewards;
  - motifs are claimed by the bidder, never sent;
  - motif ids fixed at bid time, with the id slippage guard; which motif a token shows is fixed by its id;
  - the clock starts at the first bid; extensions have no limit; with no bids the auction never ends;
  - 5% royalties, no owner role;
  - 10 October: no arranging; four contracts, the 1/1 in its own; owner-only burn for the weaver to come; deployment from the artist's wallet; the names.
- [x] Internal review rounds of September 18 and 26 (an earlier collection contract and its on-chain drawing code, both removed on 10 October).
- [x] Full internal audit of the ETH auction, October 9: F-01 and F-02 fixed with tests in `test/GasFloors.t.sol`; F-03, F-04 and F-10 accepted by the artist.
- [x] Every item of the October 9 list is decided ([AUDIT.md](../AUDIT.md)): F-01 and F-02 fixed, F-03, F-04 and F-10 accepted, the test gaps closed, the leftover code removed (October 10); F-13 and F-14 closed by the split of 10 October.
- [x] The missing tests are in `test/AuditGaps.t.sol` (October 10): the gas a hostile refund receiver or winner can cost (F-05), the registration signature domain rebuilt independently (F-18), and eleven more. Twenty-five mutants of those checks all fail the suite.
- [x] Internal review round and mutation testing on the ETH-only auction (October 10, `audit/eth-only-reaudit-2026-10-10.md`), then tested against the October 2026 attack research (`test/AttackPatterns.t.sol`).
- [x] The split of 10 October: `KilimMotifs`, `KilimOneOfOne`, the auction minting into both, the packers and the deploy script; the whole auction suite re-targeted and its measured numbers re-measured ([AUDIT.md](../AUDIT.md), "10 October 2026"). 188 forge tests at the rewrite commit, 78 site tests, Slither without medium or high, `pnpm -s deploy:dry` green.
- [ ] **Adversarial review round of the split** (pending; [AUDIT.md](../AUDIT.md), "Review round"). `KilimMotifs`, `KilimOneOfOne`, the packers and the loader have not been read by any reviewer. Repeat after any further contract change.
- [ ] Tag the frozen version once the artwork and settings are final.
- [ ] Rerun on the frozen commit: `pnpm -s verify:upstream`, `build`, `test:ci`, `fmt`, `audit:static`, `artifacts`, `test:pack`, `test:page`, `deploy:dry`. Confirm `audit/build-manifest.json` matches the tag.
- [x] Each heavy transaction fits the **per-transaction gas cap**, 16,777,216 (EIP-7825), with margin, and every deployment transaction the 8M policy: the largest chunk 5,876,690, the 1/1 contract 5,600,491, a 64-motif claim 1,790,852 (re-measure on Sepolia, into a contract wallet with a receiver hook). `tokenURI` is an `eth_call`: the 1/1 3,838,101, a motif 287,311, both under the line some nodes apply to reads (decided 10 October: every token stays readable under 16,777,216; the script refuses a 1/1 above 8M).
- [ ] **Independent human audit** of the frozen commit. Fix the findings, then repeat this section. This is a launch blocker (K-08).
- [ ] On freeze day, recheck the Solidity 0.8.37 bug list and OpenZeppelin 5.6.1 advisories.

## Deployment tooling and key

- [x] Deployment script: `script/DeployKilim.s.sol`. It reads the signed-off config (templates: `deploy/mainnet.example.json`, `deploy/sepolia.example.json`) and **refuses to send** on any mismatch (chain, manifests, chunk files, CREATE2 addresses, section hashes, config texts, gas, golden tokenURIs, reserve price, schedule, nonce, read-back). On chain 1 it also refuses any deployer but orkhanart.eth, any auction setting other than the decided values in the table above, any 1/1 name but "The Unwoven Kilim", a skipped nonce check and a zero inspection window. Still to check by hand: the [2-deploy.md](2-deploy.md) "Pre-flight" items it cannot see (signed-off config, key access, git tag, deployer ETH).
- [ ] The script's refusals are covered by `test/DeployKilim.t.sol`; confirm it passes at the frozen commit.
- [ ] The deployer is the artist's wallet (above). Fund it with ETH for gas: about 214M gas in all at the gas price of the day, plus margin (the store about 202M, the three contracts about 12M). The store can go up earlier and from any key (`runStore` is idempotent); the three contracts must come from orkhanart.eth at the published nonce.
- [ ] Choose the inspection window between deployment and `startsAt`, for example 24 hours. It goes in the config as `minLeadSeconds`; the script refuses 0 on chain 1 and accepts any other value, so check the number by hand (F-26).
- [ ] Publish before deploy day:
  - every chunk's address and the five hashes, from the manifests (the same on every chain);
  - the deployer address and its next nonce n;
  - the predicted addresses: Motif Bazaar at n, The Unwoven Kilim at n + 1, the auction at n + 2;
  - the full motif layout (`motifOf(id)` for every id; it follows from the Motif Bazaar address).

  After publishing, send **no other transaction** from that key.
- [ ] Be accurate about what publishing proves. It gives everyone the same information early. It does **not** prove the layout wasn't picked, because the deployer chose the key and nonce first (K-02). Either disclose that, or rule it out properly: deploy through a published CREATE2 factory with the initcode published in advance, using as salt a pre-announced future public random value.

## Sponsored registration (optional)

`registerFor` lets a sponsor wallet pay the gas for a supporter's registration. The service is in `registration-relayer/` and is **not activated**.

- [ ] Decide whether to run it. Without it, each supporter pays the gas for `register()`.
- [ ] If yes: a dedicated sponsor wallet (never the treasury or the deployer), a spending limit, persistent hosting and an HTTPS endpoint, as `registration-relayer/README.md` describes. Read F-08 (an attacker can burn the sponsor's budget) and F-09 (wallets with code cannot use this path and need a direct `register()` button) first.

## Testnet rehearsal

Use the exact launch config except the times, on Sepolia (11155111) with test ETH. Run [2-deploy.md](2-deploy.md) end to end, both phases, then:

- [ ] Walk the full flow **through the website**, with several wallets including a Safe:
  1. register wallets until the count is 100, directly and, if it will be used, through the sponsor; confirm a bid before the 100th reverts with `RegistrationIncomplete` and the 101st registration reverts with `RegistrationClosed`;
  2. place the opening bid of 0.01 ETH and see the clock start;
  3. get outbid and see the ETH come back in the same transaction (`RefundPaid`);
  4. force one deferred refund with a contract bidder that rejects ETH (`RefundDeferred`), then `withdrawRefund` it to another address;
  5. claim motifs across several bids, 64 at a time, to the bidder and to another recipient;
  6. transfer a motif; `burn` one as its owner, and confirm an approved operator cannot;
  7. after the end: `settle` and see the 1/1 arrive in the winner's wallet; `withdrawProceeds` from the treasury;
  8. repeat the end with a winner contract that rejects the 1/1 (`PrizeDeliveryFailed`), then `claimPrize(to)`.
- [ ] Send a bid and a `settle()` with too little gas: each must revert with `InsufficientGas` and change nothing.
- [ ] Place a bid after the motif pool runs out (use a small `motifCap` in the rehearsal config). It must succeed, with no motifs.
- [ ] Check the guards: a treasury bid and a treasury registration revert with `TreasuryCannotBid`; a stale `expectedFirstMotifId` reverts with `MotifRangeMoved`; a bid whose value differs from its amount reverts with `IncorrectPayment`; a plain ETH transfer to the auction reverts.
- [x] The site's JavaScript `motifOf` matches the contract on every chain id the site ships for (`site/test/motifs.test.mjs`, on a local chain). Repeat on Sepolia for sample ids.
- [ ] Measure real gas on the chain for the actions in the table above.
- [ ] Check how both collections display on at least one marketplace or indexer for the chain: a motif token's SVG and name, the 1/1's still and page.
- [ ] Media: fetch a motif and the 1/1 through the target marketplaces, MetaMask/Rainbow, Etherscan and one indexer; record response times. Open the 1/1 in a sandboxed iframe and on a phone; the loader must find `DecompressionStream`.
- [ ] Probe the `eth_call` gas cap of the RPC providers those marketplaces use (`node scripts/probe-rpc.mjs`); anything below about 4M would blank the 1/1.

## Website

The pages inline their scripts, so after editing rebuild with `python3 site/build.py`. Point the site at a deployment with `pnpm -s site-config --chain <id> --auction <address> --block <deployment block>` (it reads the two token contracts from the auction). Every item below must be checked against the contracts in the rehearsal above.

- [ ] **Registration.** Show `registrationCount()` out of 100 and whether the connected wallet is `registered`. Say plainly that registering deposits nothing, gives no priority and no motifs, and is not required to bid. Offer `register()` directly, also when a sponsor is configured (F-09).
- [ ] **Bid quote.** Always read from the chain; never recompute.
  - `minimumBid()` gives the next valid amount, in wei.
  - `rewardForBid(amount)` gives the motif count, which is capped and can be 0. Pass it as `minimumReward`.
  - If the page does not show which motif ids a bid reserves, pass `expectedFirstMotifId = 0`. If it does, pass `1 + motifsAllocated()` while `rewardForBid(amount) > 0`, and re-quote on `MotifRangeMoved`.
- [ ] **Bid transaction.** One payable call from the bidder's own account with `value` equal to the amount, and a fixed gas limit of 1,500,000 (R-08; an outbidding bid needs at least 523,590) rather than a bare estimate. Check the wallet's ETH balance against the full new bid plus gas: a re-bid is not netted against the bidder's own earlier bid.
- [ ] **Clock.** Read `startsAt`, `duration` and `endsAt` from the chain, and compare them with the latest block time.
  - Before 100 registrations: show the count, no countdown.
  - After 100 and before the first bid, `endsAt` is 0: show "Bidding open — the 24-hour clock starts with the first bid".
  - Start the countdown from `AuctionStarted`, and update `endsAt` from each `BidPlaced`. There is no latest possible close.
  - After `endsAt`, show "Ended, awaiting settlement" with a `settle()` button that sends a fixed 1,200,000 gas (at least 585,900 is needed).
- [ ] **Claims.** Motifs are claimed by the bidder: loop `claimMotifs(min(64, credits), to)` until `motifCredits` reaches 0. Show the number of transactions and the estimated gas before a large bid.
  - Take minted ids from the collection's `MotifsMinted` event, one per range. Ranges aren't contiguous, and `MotifsClaimed.firstTokenId` is only the first id.
  - Treat `BidPlaced.firstMotifId == 0` as "no ids reserved".
  - The artist's decision: no motifs are previewed before a claim (the site's copy test enforces it).
- [ ] **Refunds.** Show `refunds(wallet)` and a `withdrawRefund` button only when it is nonzero. Tell an outbid bidder whose refund was deferred (`RefundDeferred`).
- [ ] **Winner.** After `settle()`, the winner normally holds the 1/1 already. Show `claimPrize(to)` only when `prizeClaimed` is false after settlement. A Safe still needs a connection path (WalletConnect or a Safe Apps shim).
- [x] **Holdings.** The collection has no enumeration. List a wallet's tokens from `Transfer` logs since the deployment block, or from an indexer that supports the chain. Include secondary-market motifs.
- [x] **Motifs.** `motifOf` ported to JavaScript exactly (`site/motifs.js`): `keccak256(abi.encode(chainId, motifs, id)) % 1024 + 1`. The grids and names are the packed store's, and `chain.js` refuses a collection whose `gridsHash` or `namesHash` differ.
- [ ] **Errors.** Simulate each transaction before sending. Decode reverts using the auction and the two token ABIs together. Show a clear next step for `RegistrationIncomplete`, `RegistrationClosed`, `AlreadyRegistered`, `InsufficientRegistrationBalance`, `BidTooLow`, `NonWholeUnitBid`, `IncorrectPayment`, `InsufficientGas`, `RewardSlippage`, `MotifRangeMoved`, `AuctionNotOpen`, `TreasuryCannotBid`, `InvalidQuantity`, `InvalidRecipient`, and `ERC721InvalidReceiver` (suggest another recipient).
- [ ] **Security.**
  - Call `bid()` straight from the user's account, never through a router or multicall; credits, refunds and the prize belong to `msg.sender`.
  - The only transactions the site asks for go to the published auction and Motif Bazaar addresses (the 1/1 contract is only read).
  - Lock DNS and hosting accounts.
  - Never ask anyone to send ETH straight to a contract: a plain transfer to the auction reverts (K-06).
- [ ] **Copy that must match the contracts:**
  - which motif a token shows is deterministic and public before bidding, not random;
  - rewards are capped, can be 0, and are claimed separately by the bidder, up to 64 at a time, at the bidder's gas cost;
  - outbid ETH comes back in the transaction that outbids, with a withdrawal fallback; gas is not refunded;
  - registration gives no right and is not needed to bid;
  - the 1,024 are motifs; the collection is Motif Bazaar and the 1/1 is The Unwoven Kilim; nothing is arranged or woven until Kilim Bazaar opens;
  - the opening date, time zone and duration are the real schedule.

## Disclosures and terms

- [ ] Plain-language terms covering:
  - outbid bidders keep motifs, and one wallet can take the whole pool by outbidding itself (K-01, F-04);
  - registration counts addresses, one actor can fill it and start the clock, and bidding never opens below 100 (F-03, F-10, F-11);
  - which motif a token shows is public and deterministic, with no randomness or rarity guarantee, names are not unique, and the deployer could have influenced the layout (K-02);
  - the seller can't bid from the treasury, but other wallets are undetectable (K-07);
  - no admin, pause or recovery (K-06);
  - chain timing and outages (K-05);
  - the clock starts at the first bid and late bids extend it without limit; the auction ends only after 10 minutes with no new bid, and never ends if nobody bids;
  - a pending bid has no deadline and can land later at the amount signed (F-24);
  - burning a motif is permanent and only its owner can do it; Kilim Bazaar's rules are not part of this auction.
- [ ] Bid only from a wallet that can send transactions later: an EOA, a Safe or a smart wallet. A contract that can neither receive ETH nor call `withdrawRefund`, or cannot call `claimMotifs` or `claimPrize`, locks its own funds and NFTs (F-19).
- [ ] State what the 1/1 gives the winner: token id 1 of The Unwoven Kilim with its page served from the chain, how the winner opens it full-window (the `animation_url` saved as an `.html` file; browsers block top-level navigation to `data:` URLs), and what license comes with it.
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

- [x] **`tokenURI` and the 16,777,216-gas line.** Decided 10 October (the secure option): every token stays readable under the line. The 1/1 reads at 3,838,101 gas and a motif at 287,311 on the packed stand-in store, and the deploy script refuses a 1/1 above 8,000,000. Re-measure on the final page (`pnpm -s deploy:dry` prints it).
- [ ] **After 2026-11-01** (EIP-8037 leaves Last Call): re-run the Glamsterdam projections in `test/AttackPatterns.t.sol` with the final prices, then run the whole lifecycle on Sepolia, which already runs Glamsterdam: register, bid, outbid an EOA, a Safe and a refusing wallet, settle to a first-time holder, claim 64, burn one. Re-measure the page's bid and settle gas limits and the relayer's `gasLimit` and budget (a registration writes one new slot).
- [ ] **Deploy the chunks before Glamsterdam reaches mainnet.** Code deposit rises from 200 to 1,530 gas per byte: the store's 202M gas would become about 1.5G.
- [ ] **Keys.** Decided 10 October: orkhanart.eth deploys, receives the proceeds and the royalties; there is no page-owner role any more. Anything automated (the registration sponsor, alerts) gets its own small wallet. No key used for the launch may carry an EIP-7702 delegation.
- [ ] **Domain.** Registrar with no account recovery by support, registry lock on, DNSSEC validating, CAA records set; monitor NS, A and DS records and certificate-transparency logs; announce a fallback (direct contract instructions) beforehand. Every 2025 and 2026 front-end theft in the report began with a persuaded support agent.
- [ ] **Site hardening not built yet:** a scheduled check that each served page hashes to the tagged build; a check after sending that the mined transaction's `to`, `value` and `data` are what the page built; two independent RPC providers that must agree before the bid button is live; a raised priority fee and a high max fee for bids in the last ten minutes, sent to the public mempool.
- [ ] **Real smart wallets on a fork:** `registerFor` with a Safe (with and without its fallback handler) and a Coinbase Smart Wallet. OpenZeppelin 5.6.1 sends ERC-1271 calldata without zero padding (5.7.0 pads it).
- [ ] **Marketplaces on a testnet:** mint throwaway motifs and the 1/1 and check how OpenSea, Etherscan and the main wallets show the SVG image and the `data:text/html` animation.
- [ ] **Say it plainly on the site and in the terms:** registration is a counter of 100 wallets, not a list of who may bid; one wallet outbidding itself earns about eleven times the motifs of one bid; refunds and the 1/1 are sent automatically when the receiving wallet allows it and are otherwise withdrawn or claimed; the site never asks for a token approval, a permit or a wallet delegation.
- [ ] **The weeks before the launch:** no remote control in calls, no scripts or repositories from new contacts, review the apps connected to the X account, freeze wallet-extension updates, and verify the payout address on the device against a written copy.

## Go / no-go

- [ ] Every item above is checked. The frozen tag, audit report, config file, manifests and published predictions all refer to the same commit and values. Two people sign off.
