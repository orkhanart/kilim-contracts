# Open-source provenance and Kilim adaptation

Checked September 18, 2026 UTC. The build reuses OpenZeppelin directly and a limited, explicitly identified part of thirdweb's English auction implementation. **The complete Kilim contracts have not received an independent audit.**

## What is reused

| Component | Source | Boundary |
| --- | --- | --- |
| ERC-721 ownership, approvals, transfers and receiver checks | OpenZeppelin Contracts **5.6.1**, imported unchanged | Kilim's mint restrictions, composition, expansion and metadata are custom. |
| ERC-20 transfers, reentrancy protection, arithmetic and metadata utilities | Same pinned OpenZeppelin package | Exact-transfer checks and auction accounting are Kilim additions. |
| Ascending bid acceptance | thirdweb `EnglishAuctionsLogic._isNewWinningBid`, retained unchanged apart from whitespace, including its 10,000 denominator | Actual predicate equality and reference-file integrity are checked by `pnpm verify:upstream`. Calls are additionally bounded to uint128 amounts and whole token units. |
| Auction lifecycle | `src/auction/ERC20EnglishAuction.sol`, a limited adaptation of thirdweb's ascending-bid flow | Escrow, storage, refund, extension and settlement code is extensively changed. This is not an unchanged thirdweb marketplace deployment. |
| Symbol credits and 1/1 claims | `src/KilimAuction.sol`, built on the auction base | Custom Kilim code; losing bidders retain their credits, with separate claims and immutable caps. |

The original marketplace cannot be used unchanged for the requested economics: it has immediate outgoing refunds, marketplace storage, native-token wrapping, fees, royalties and upgrades. The `_handleBid` function is not a virtual extension point in this reference. Extracting the relevant rule and adapting the flow makes the changed security boundary explicit; it does not transfer the original audit's assurance to the new escrow code.

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
| Percentage-based winning-bid predicate | Same predicate, plus whole-unit bids and uint128 upper bound | Fuzzed quote acceptance and minimality across 0–18 decimals and 1–10,000 bps; overflow boundary tested. |
| Refund old bidder during the new bid | Record refund credit; old bidder withdraws separately | A blocked previous recipient cannot stop later bids. |
| Currency wrapper moves incoming funds | SafeERC20 collects the entire recorded amount; check exact balance change | Fee/false-return/failed-deposit tests and solvency invariants. |
| Extend by adding a time buffer | Extend to at least now plus the buffer, capped by an absolute end | Deadline, last-second, zero-extension and stateful tests. |
| Payable and native-currency support | Nonpayable ERC-20 entry points, no receive function | Attached ETH and direct ETH calls revert. Forced ETH remains unrecoverable. |
| Optional immediate buyout | No buyout or amount clamp | Large overbids must be fully collected and remain fully payable. |
| Marketplace fees, royalty routing and asset delivery | Treasury receives winning principal; winner separately claims one Kilim NFT | Failed NFT receiver cannot block settlement or proceeds. |
| No retained Kilim rewards | Bounded symbol credits for every accepted bid, each reserving specific symbol IDs | Refunds preserve credits by owner decision; exhausted rewards do not stop bidding. Self-outbid credit collection is accepted, not fixed. |
| Any address may bid | The configured treasury address cannot bid | Treasury bids revert; other seller-controlled wallets are not detectable. |

The upstream A-15 M-1 finding concerned attached native currency becoming trapped on ERC-20 bids. The nonpayable interface excludes that path. thirdweb also published a [September 2023 buyout vulnerability](https://blog.thirdweb.com/2023-09-09-vulnerability-auctions-with-a-buyout-price/); this adaptation has no buyout branch. Historical fixes illustrate why an audit-reference commit is not itself a deployable security guarantee.

`test/ReuseRegression.t.sol` checks these adaptation boundaries. Existing adversarial and stateful tests cover claims, refund backing, treasury limits and token/NFT callbacks. The build manifest hashes the production sources, tests, scripts and vendored evidence. Source verification on an explorer, open-source publication and security audits remain different checks; no deployment or explorer verification has been performed.

## Other candidates considered

- [Nouns Auction House V3](https://github.com/nounsDAO/nouns-monorepo/blob/3779f34e4442cc62f6602bf17460ad334e0208a7/packages/nouns-contracts/contracts/NounsAuctionHouseV3.sol): ETH/WETH and Nouns-specific issuance/history with upgradeable controls; adapting it to this stablecoin design adds unnecessary changes. No Nouns source was copied.
- [Zora legacy Auction House](https://github.com/ourzora/auction-house#deprecation-notice): maintainers explicitly deprecate it; not selected.

Fully refunded bids that retain permanent rewards can be farmed regardless of the auction library. The owner has accepted this as the intended bidding incentive; see [AUDIT.md](AUDIT.md) for the measured exposure and the remaining launch requirements.
