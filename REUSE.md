# Open-source provenance and Kilim adaptation

> The auction is native ETH only, with a 100-wallet registration before bidding opens. See [NATIVE-ETH.md](docs/NATIVE-ETH.md) for the behavior and [audit/full-audit-2026-10-09.md](audit/full-audit-2026-10-09.md) for the latest internal review.

Upstream evidence checked September 18, 2026 UTC; the adaptation notes below were updated October 9, 2026 for the ETH-only contracts and October 10, 2026 for the split into Motif Bazaar, The Unwoven Kilim and the auction (motifs, not symbols; two token contracts the auction mints into). The build reuses OpenZeppelin directly and a limited, explicitly identified part of thirdweb's English auction implementation. **The complete Kilim contracts have not received an independent audit.**

## What is reused

| Component | Source | Boundary |
| --- | --- | --- |
| ERC-721 ownership, approvals, transfers and receiver checks | OpenZeppelin Contracts **5.6.1**, imported unchanged | Kilim's mint restrictions, owner-only burn, stored data and on-chain metadata (`src/KilimMotifs.sol`, `src/KilimOneOfOne.sol`) are custom. |
| Reentrancy protection, arithmetic, EIP-712 typed data and signature checking (EOA and ERC-1271) | Same pinned OpenZeppelin package | ETH escrow, registration and auction accounting are Kilim additions. |
| Ascending bid acceptance | thirdweb `EnglishAuctionsLogic._isNewWinningBid`, retained unchanged apart from whitespace, including its 10,000 denominator | Actual predicate equality and reference-file integrity are checked by `pnpm verify:upstream`. Calls are additionally bounded to uint128 amounts and whole bid units of 0.001 ETH. |
| Auction lifecycle | `src/auction/EnglishAuction.sol`, a limited adaptation of thirdweb's ascending-bid flow | Escrow, storage, registration, refund, extension and settlement code is extensively changed. This is not an unchanged thirdweb marketplace deployment. |
| Motif credits and the 1/1 | `src/KilimAuction.sol`, built on the auction base; it mints into `KilimMotifs` and `KilimOneOfOne` | Custom Kilim code; losing bidders retain their credits, with separate claims and immutable caps. |

The original marketplace cannot be used unchanged for the requested economics: it has marketplace storage, native-token wrapping, fees, royalties and upgrades, and no registration or retained rewards. The `_handleBid` function is not a virtual extension point in this reference. Extracting the relevant rule and adapting the flow makes the changed security boundary explicit; it does not transfer the original audit's assurance to the new escrow code.

## Exact upstream evidence

The [0xMacro thirdweb A-15 report](https://0xmacro.com/library/audits/thirdweb-15) identifies:

- Repository: `thirdweb-dev/contracts`.
- Commit: **`46e69070978c23b9533edb381e838a5dddf7ed9d`**.
- File: `contracts/prebuilts/marketplace/english-auctions/EnglishAuctionsLogic.sol`.
- SHA-256: **`5c3e0e3d331c38b1f9487230002f0f68b8972d10232ad435338229549995f52e`**.
- Report scope: listed contracts, with marketplace work focused on changes since a previous MarketplaceV3 review. Deployment scripts are outside that report's scope.

The complete byte-for-byte reference is preserved as `vendor/thirdweb/EnglishAuctionsLogic.sol.txt`, outside compilation. `manifest.json` records its source URL, audit and hashes. The original Apache-2.0 license and an attribution/change notice are included. The adapted base retains Apache-2.0; Kilim's own extension and collection files are MIT. This snapshot is an audit reference, not a claim that every line is a patched, recommended production release.

OpenZeppelin is pinned through the package lockfile. Its [5.6.1 source tree](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/5fd1781b1454fd1ef8e722282f86f9293cacf256) and [audit index](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/audits/README.md) were inspected. The index lists reports through 5.5.0; no claim is made that every 5.6.1 line has an independent audit.

## Changes that need their own review

| Upstream behavior | Kilim behavior | Reason / regression evidence |
| --- | --- | --- |
| Multiple auctions in marketplace storage | One constructor-configured auction; no roles or upgrades | Smaller scope; constructor and access-control tests. |
| Percentage-based winning-bid predicate | Same predicate, plus whole-unit bids (0.001 ETH) and uint128 upper bound | Quote acceptance and minimality across 1–10,000 bps; overflow boundary. |
| Refund old bidder during the new bid | Refund inside the new bid through a self-call capped at 150,000 gas, after a check that the bid carries enough gas for it; a failed refund becomes a credit the old bidder withdraws | A previous bidder that rejects ETH or burns gas cannot stop later bids or make them run out of gas (`test/GasFloors.t.sol`, `test/NativeRegistration.t.sol`). |
| Currency wrapper moves incoming funds | Payable bid; `msg.value` must equal the recorded amount; no wrapper | Wrong-value and rollback tests; the contract balance equals its liabilities. |
| Any address may bid at once | Bidding opens only when exactly 100 wallets have registered, directly or by an EIP-712 / ERC-1271 signature. Registration counts addresses, not people, and takes no deposit | `test/NativeRegistration.t.sol`, `test/SponsoredRegistration.t.sol`. One actor can fill the slots; the owner accepted this. |
| Fixed start and end, extended by adding a time buffer | `startsAt` only opens registration and bidding; the first bid starts a `duration` clock. A later bid extends the close to at least now plus the window, with no absolute end, so the auction ends only after a full window with no new bid. With no bids it never ends and cannot settle | First-bid clock, unlimited-extension, no-bids, last-second and stateful tests. |
| A currency chosen per auction, moved through a wrapper library | Native ETH only: one payable bid entry point, no receive function | Plain ETH transfers to the auction revert. Forced ETH remains unrecoverable. |
| Optional immediate buyout | No buyout or amount clamp | Large overbids must be fully collected and remain fully payable. |
| Marketplace fees, royalty routing and asset delivery | Treasury withdraws the winning bid; settlement sends the 1/1 to the winner through a self-call capped at 1,000,000 gas, and the winner claims it if that call fails | A failing NFT receiver cannot block settlement or proceeds, and a low-gas settlement cannot skip the 1/1 (`test/GasFloors.t.sol`). |
| No retained Kilim rewards | Bounded motif credits for every accepted bid, each reserving specific motif token ids | Refunds preserve credits by owner decision; exhausted rewards do not stop bidding. Self-outbid credit collection is accepted, not fixed. |
| Any address may bid | The configured treasury address cannot bid | Treasury bids revert; other seller-controlled wallets are not detectable. |

The upstream A-15 M-1 finding concerned native currency attached to a bid in another currency becoming trapped. Kilim has one currency, and a bid whose `msg.value` differs from its amount reverts, which excludes that path. thirdweb also published a [September 2023 buyout vulnerability](https://blog.thirdweb.com/2023-09-09-vulnerability-auctions-with-a-buyout-price/); this adaptation has no buyout branch. Historical fixes illustrate why an audit-reference commit is not itself a deployable security guarantee.

`test/ReuseRegression.t.sol` checks these adaptation boundaries in ETH: wrong-value bids, plain ETH transfers, a previous bidder that rejects ETH, rollback on a reverted bid, the uint128 bound, quote minimality and full collection of large overbids. `test/AuctionInvariants.t.sol` checks refund backing statefully, with wallets that reject ETH, burn gas or refuse NFTs: the contract balance always covers its liabilities and every wei bid is refunded, paid as proceeds or still owed. The adversarial tests for claims, treasury limits and NFT callbacks are in `test/KilimAuction.t.sol`. The build manifest hashes the production sources, tests, scripts and vendored evidence. Source verification on an explorer, open-source publication and security audits remain different checks; no deployment or explorer verification has been performed.

## Other candidates considered

- [Nouns Auction House V3](https://github.com/nounsDAO/nouns-monorepo/blob/3779f34e4442cc62f6602bf17460ad334e0208a7/packages/nouns-contracts/contracts/NounsAuctionHouseV3.sol): ETH/WETH and Nouns-specific issuance/history with upgradeable controls; adapting it to this design (one immutable auction, registration, retained motif rewards) adds unnecessary changes. No Nouns source was copied.
- [Zora legacy Auction House](https://github.com/ourzora/auction-house#deprecation-notice): maintainers explicitly deprecate it; not selected.

Fully refunded bids that retain permanent rewards can be farmed regardless of the auction library. The owner has accepted this as the intended bidding incentive; see [AUDIT.md](AUDIT.md) for the measured exposure and the remaining launch requirements.
