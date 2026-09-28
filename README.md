# Kilim contracts

An implementation for Ethereum mainnet (Sepolia for the rehearsal) using an immutable ERC-20 auction paid in USDC. This is a **development release with an internal security review**, not a certification or a production deployment. Read [AUDIT.md](AUDIT.md) before using real funds.

OpenZeppelin primitives are reused directly. The auction uses a limited adaptation of thirdweb's English auction flow and its unchanged winning-bid predicate. [REUSE.md](REUSE.md) records the exact audit-reference commit, source hashes, licenses and modifications. The custom escrow and rewards require their own review; the upstream audit does not certify this adaptation.

## Included

- `src/auction/ERC20EnglishAuction.sol`: immutable stablecoin auction, thirdweb bid predicate, automatic refunds with a pull fallback, a clock that starts at the first bid, late-bid extensions with no limit, permissionless settlement and treasury proceeds.
- `src/KilimAuction.sol`: retained symbol credits and a separately claimed 1/1, added to the auction base.
- `src/Kilim.sol`: one ERC-721 collection containing the 1/1, symbols, and compositions. Compositions burn source symbols atomically, can expand under the same token ID, and can be permanently frozen by their owner.
- `src/render/KilimRenderer.sol` (with `KilimWriter.sol`): the immutable on-chain renderer. It draws every token's metadata, SVG images and the 1/1's interactive page from geometry stored in SSTORE2 data contracts. `onchain/pack_store.py` packs the store; [docs/RENDERER.md](docs/RENDERER.md) gives the hash recipe, the deploy order and the gas budget.
- `script/DeployKilim.s.sol`: deploys the data chunks and the renderer, then the auction, refusing on any mismatch. On Ethereum mainnet it also refuses any auction setting other than the decided launch values.
- Unit, adversarial, fuzz, golden, differential and stateful invariant tests; pinned dependencies; exported ABIs and a reproducible build manifest.

There are no upgrade keys, metadata setters, unrestricted mint endpoints, administrator asset seizures, or admin withdrawals. The auction creates its collection in its constructor and is its immutable mint authority. Deploying `Kilim` separately with an EOA minter changes that trust model and is not the intended setup.

## Run locally

Requires Node.js 22+ and pnpm 11.19.0. Foundry 1.7.1 is installed as a pinned native package. Its install script is unnecessary; the runner invokes the platform package directly and preserves exit codes.

```sh
cd contracts
pnpm install --frozen-lockfile
pnpm verify:upstream
pnpm build
pnpm test
pnpm test:ci
pnpm fmt
pnpm artifacts
```

The renderer adds (Python 3.9+ and Node 22+, no extra packages):

```sh
pnpm pack:check              # onchain/build matches the geometry and page it was packed from
pnpm test:pack               # packer invariants, scale band, determinism
pnpm test:page               # the 1/1 page at 700, 812 and 900 motifs, then test:render-site
pnpm test:render-geometries  # the renderer suite on a 700- and a 912-motif store
pnpm test:render-ffi         # differential fuzzing against onchain/render_ref.py
pnpm test:render-site        # the contract's images against the site's drawing code, in headless Chrome
pnpm gas:render              # writes audit/gas-render.txt
pnpm deploy:dry              # simulates the store phase of the deployment
```

Compilation pins Solidity **0.8.37**, OpenZeppelin **5.6.1**, Cancun EVM, optimizer 200 runs, and the legacy code-generation pipeline. Foundry downloads the pinned native compiler on first use. Build and test scripts verify the thirdweb source snapshot, license, denominator and retained function before running. `pnpm artifacts` rejects stale source/dependency inputs and non-production build settings before exporting. It records hashes for sources, tests, scripts and upstream evidence.

Static analysis requires Python 3.10+:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r audit/requirements.txt
pnpm audit:static
```

The full Slither output is retained in `audit/slither.json`; timestamp warnings are reviewed in the audit rather than hidden. Coverage tooling is available as `pnpm coverage`; see the audit for its measurement limitations.

## Exact behavior

`bid(amount, minimumReward, expectedFirstSymbolId)` takes a **new full bid**, not a top-up. Amounts are stablecoin base units, in whole token units. With a six-decimal USD token, a $25 bid is `25_000_000`. The token's USD peg is an external assumption; no price oracle is used.

The next bid is the current high bid plus the configured percentage, rounded **up** to a whole token unit. Reserve price, increment, stablecoin, treasury, opening time, duration, late-bid window, and reward limits are fixed at deployment. Re-bidding from the same address is allowed and must also be fully funded.

Every accepted bid allocates `min(whole token units, per-bid reward cap, remaining collection rewards)` symbol credits. The outbid bidder gets their full prior bid back automatically, inside the bid that beats it, and keeps all allocated credits. If that transfer fails (for example the address is blacklisted by the token issuer), the amount waits in `refunds` for `withdrawRefund(to)`, so no address can block later bids. This is intentional: it rewards continued bidding. It also means one wallet can collect credits by repeatedly outbidding itself; the caps bound total issuance, not who receives it. Once the reward supply is exhausted, the auction continues with zero new rewards. `minimumReward` lets the bidder reject an unexpected reduction caused by another bid. `expectedFirstSymbolId` lets the bidder reject a different ID range, and therefore different traits, if another bid lands first: while `rewardForBid(amount) > 0`, the frontend passes `collection().FIRST_SYMBOL_ID() + symbolsAllocated()` read when quoting, and the bid reverts with `SymbolRangeMoved` unless it reserves IDs starting exactly there. Pass `0` to accept whatever IDs are next, and **always pass `0` once the quoted reward is 0**: after the pool runs out a bid reserves no IDs, so any nonzero value reverts. The treasury address cannot bid (`TreasuryCannotBid`); other wallets a seller controls cannot be detected on-chain.

**Symbols are delivered, not claimed.** `deliverSymbols(max)` mints pending symbols to the wallets that bid for them, oldest bid first, up to 64 per call; anyone may call it and pays its gas, and the artist runs it from the auction page. A wallet that rejects the tokens or burns its gas allowance (150k per symbol) is skipped with `DeliveryFailed`; with too little gas for the next wallet the call stops instead of skipping it, so send it with a fixed gas limit (the site uses 11M), never an estimate. `claimSymbols(quantity, recipient)` remains as the fallback, in batches of 1–64. Each bid **reserves the next symbol token IDs** in allocation order; `BidPlaced` reports the first reserved ID. Claims mint exactly those IDs, oldest bid first, and `unclaimedSymbolRanges(bidder)` lists what remains. A claim that spans several bids mints several ID ranges, each reported by the collection's `SymbolsMinted` event. Credits never expire and can be delivered or claimed before or after settlement. This deliberately replaces the prototype's unbounded synchronous NFT mint. Frontend copy must reflect it.

Bidding opens at `startsAt`, and the first bid starts the clock: the auction closes `duration` after it (`endsAt`, 0 until then). A bid within `extensionWindow` of the close moves the close to `extensionWindow` after that bid, with no limit, so the auction ends only after a full window with no new bid. Refunds use `withdrawRefund(recipient)`. Anyone can call `settle()` at or after the closing time. Only the treasury can withdraw winning proceeds; only the winner can claim the 1/1. With no bids the clock never starts and the auction never ends: `settle()` reverts with `NoBids`, and the 1/1 is never minted. NFT receivers cannot block settlement or proceeds. Claims can target an alternative recipient if a wallet rejects NFTs or a token blocks a recipient.

Symbols have zero-based motifs and six material codes with weights 44/24/14/9/5/4. Traits derive only from the chain ID, collection address and token ID, so every symbol's traits are public from deployment through `symbolTraits(id)`. Because a bid reserves specific IDs, claim time, claim order, recipient and wallet address cannot change what a bidder receives. **This is deterministic, public assignment, not randomness or guaranteed rarity:** bidders can see which upcoming IDs are rare and time their bids. The collection has no special gold allocation.

`weave(cells, columns, rows, appearance)` requires ownership of every source and a fully filled rectangle with at least two rows and columns. Approved marketplace operators cannot call it on someone else's tokens. `expand(artworkId, expectedRevision, cells, columns, rows, appearance)` additionally requires ownership of the artwork, a strictly larger composition, and every previous source exactly once. Old sources may be reordered; new sources must be owned by the caller. Burned symbols retain their traits and composition provenance in `symbolData()`.

This version has a hard limit of **256 cells**, with a lower immutable deployment limit allowed. It does not support an 812-cell merge. `appearance` must be one of `bytes32("flat/ink")`, `bytes32("flat/indigo")` or `bytes32("flat/vermilion")` (left-aligned ASCII, as `ethers.encodeBytes32String` makes it); anything else reverts with `InvalidAppearance`. `freezeArtwork()` permanently disables expansion but leaves ordinary transfers available. Use `expectedRevision` to reject stale edits. Buyers must understand that unfrozen artwork can be changed by its owner before a sale; revision checks do not change external marketplace settlement rules.

The 1/1 uses token ID 1. Symbols use IDs 2 through `symbolCap + 1`, reserved at bid time. Compositions use a separate checked counter starting at `symbolCap + 2`. IDs are never reused; a burned symbol ID can never be minted again. `tokenURI` is drawn entirely on-chain by the immutable renderer fixed at construction (base64 JSON with SVG images, and for the 1/1 an HTML `animation_url`); ERC-4906 updates are emitted on expand and freeze. The constructor checks that the renderer's code hash is `rendererHash` and that it reports the same `motifCount` and `geometryHash`. Rendering a large artwork or the 1/1 is an expensive view (up to ~31M gas); see [docs/RENDERER.md](docs/RENDERER.md).

## Integration and launch inputs

The website is integrated with these contracts: see the root [README](../README.md#the-auction-and-weaving-pages) for the local dev chain, the per-chain config and the site tests (`pnpm test` runs them after the forge suite). The collection uses the geometry's **812** motifs (`motifCount = 812`); the content hashes are computed by `onchain/pack_store.py` and become final with the symbol set. The local dev chain (`scripts/dev/deploy.mjs`) deploys the packed store and the real renderer, so its `tokenURI` answers are the production ones. The site sends the renderer's appearance encoding (`bytes32` ASCII `flat/<ink|indigo|vermilion>`, as `ethers.encodeBytes32String` makes it) and decodes the collection's errors, including `InvalidAppearance`, from `abi/*.json`.

Before deployment, work through the checklists in order: [pre-deploy](checklists/1-pre-deploy.md), [deploy](checklists/2-deploy.md) and [post-deploy](checklists/3-post-deploy.md). The launch settings are decided and listed in pre-deploy: USDC, a $1 opening bid, +10% raises, 24 hours from the first bid, a 10-minute late-bid window with no limit on extensions, up to 1,000,000 symbols with no per-bid cap, 256 cells, 5% royalties, and orkhanart.eth as treasury and collection owner. On chain 1 the deploy script refuses any other value (`deploy/mainnet.example.json`, [docs/RENDERER.md](docs/RENDERER.md#what-the-script-refuses)). Still open: the final symbol set (and with it `motifCount` and the content hashes), the opening date, the inspection window, the deployer key and its published nonce, and the findings in [AUDIT.md](AUDIT.md). `test/LaunchConfig.t.sol` runs the decided settings; the shared unit-test fixture in `test/TestBase.sol` (10,000 rewards, 1,000 per bid, $25 reserve, 5% increment, 22 hours, 10-minute window) is not the launch configuration.

The target is **Ethereum mainnet**, chain ID **1**, with the **Sepolia** testnet (**11155111**) for the rehearsal; gas is paid in ETH. The contracts are compiled for the Cancun EVM, which both networks support; the renderer uses `MCOPY`. Ethereum caps each transaction at 16,777,216 gas (EIP-7825): every deployment transaction stays under 8M, and the heaviest user transactions are listed in [pre-deploy](checklists/1-pre-deploy.md) with their measured gas. `pnpm test:fork` (with `KILIM_FORK_URL` set) runs the site's pay-with-ETH flow against a mainnet fork with the real USDC and Uniswap contracts. None of this replaces the Sepolia rehearsal or real-network gas measurements.

The payment token is Circle's **USDC**, 6 decimals: mainnet `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, and Circle's test USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` on Sepolia (from [faucet.circle.com](https://faucet.circle.com/)). Both were checked on-chain on September 25, 2026 ([pre-deploy](checklists/1-pre-deploy.md)). USDC is an upgradeable proxy: Circle can upgrade the contract, pause all transfers and blacklist addresses, including this escrow; see AUDIT.md K-04. The website also accepts ETH, swapped to USDC in the bidder's own wallet before the bid; the contracts only ever see USDC, and refunds are paid in USDC.

The contracts reject direct ETH transfers. Unexpected ERC-20 donations and forced ETH have no recovery path; they never increase treasury proceeds. Only deploy with a vetted, exact-transfer, non-rebasing stablecoin. Issuer pauses, blacklisting, upgrades and a broken peg remain external risks.
