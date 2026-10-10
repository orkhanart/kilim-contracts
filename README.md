# Kilim contracts

An immutable auction in native ETH for Ethereum mainnet, rehearsed on Sepolia, with the ERC-721 collection it mints and the on-chain renderer. This is a **development release with an internal security review**, not a certification or a production deployment. Nothing is deployed. Read [AUDIT.md](AUDIT.md) before using real funds.

OpenZeppelin primitives are reused directly. The auction uses a limited adaptation of thirdweb's English auction flow and its unchanged winning-bid predicate. [REUSE.md](REUSE.md) records the exact audit-reference commit, source hashes, licenses and modifications. The custom escrow, registration and rewards require their own review; the upstream audit does not certify this adaptation.

## Included

- `src/auction/EnglishAuction.sol`: the auction base. Registration of 100 wallets before bidding opens, payable ETH bids, the thirdweb bid predicate, automatic refunds with a pull fallback, a clock that starts at the first bid, late-bid extensions with no limit, permissionless settlement and treasury proceeds.
- `src/KilimAuction.sol`: symbol credits for every bid, claims, and the 1/1 sent to the winner at settlement, added to the auction base.
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
pnpm test:contracts     # the forge suite
pnpm test               # the forge suite, then the site tests
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

The full Slither output is retained in `audit/slither.json`; timestamp warnings are reviewed in the audit rather than hidden. Coverage tooling is available as `pnpm coverage`.

## Exact behavior

[docs/NATIVE-ETH.md](docs/NATIVE-ETH.md) is the full description of the auction. In short:

**Registration.** From `startsAt`, the first 100 wallets register with `register()`, or a sponsor submits `registerFor(wallet, deadline, signature)` with the wallet's EIP-712 signature (plain accounts and ERC-1271 wallets). A wallet must hold at least 0.01 ETH when it registers. Nothing is deposited. Bidding opens when the count is exactly 100, and the 100th registration does nothing else: no bid, no symbols, no clock. Registration counts addresses, not people, and one actor can fill every slot. If 100 wallets never register, bidding never opens.

**Bids.** `bid(amount, minimumReward, expectedFirstSymbolId)` is payable and takes a **new full bid**, not a top-up: `msg.value` must equal `amount`, in wei. The opening bid is `reservePrice`, 0.01 ETH, the only value the constructor accepts. The next bid is the current high bid plus the configured percentage, rounded **up** to a whole 0.001 ETH (`SYMBOL_PRICE`), and every bid must be a whole multiple of that unit. Any wallet except the treasury can bid once bidding is open, registered or not (`TreasuryCannotBid`); other wallets a seller controls cannot be detected on-chain. Re-bidding from the same address is allowed and must also be fully funded. Increment, treasury, opening time, duration, late-bid window and reward limits are fixed at deployment.

**Refunds.** The outbid bidder gets their full prior bid back automatically, inside the bid that beats it, and keeps all allocated credits. If that payment fails (for example a contract that rejects ETH), the amount waits in `refunds` for `withdrawRefund(to)`, so no address can block later bids. A bid that outbids someone must carry enough gas for the refund's full allowance or it reverts with `InsufficientGas`.

**Symbol credits.** Every accepted bid allocates `min(amount / 0.001 ETH, per-bid reward cap, remaining collection rewards)` symbol credits. Outbid bidders keep them. This is intentional: it rewards continued bidding. It also means one wallet can collect credits by repeatedly outbidding itself; the caps bound total issuance, not who receives it. Once the reward supply is exhausted, the auction continues with zero new rewards. `minimumReward` lets the bidder reject an unexpected reduction caused by another bid. `expectedFirstSymbolId` lets the bidder reject a different ID range, and therefore different traits, if another bid lands first: while `rewardForBid(amount) > 0`, a frontend that shows the range passes `collection().FIRST_SYMBOL_ID() + symbolsAllocated()` read when quoting, and the bid reverts with `SymbolRangeMoved` unless it reserves IDs starting exactly there. Pass `0` to accept whatever IDs are next, and **always pass `0` once the quoted reward is 0**: after the pool runs out a bid reserves no IDs, so any nonzero value reverts.

**Symbols are claimed, never sent.** Each bid **reserves the next symbol token IDs** in allocation order; `BidPlaced` reports the first reserved ID. The bidder mints them with `claimSymbols(quantity, recipient)`, in batches of 1–64, and pays the gas. Claims mint exactly the reserved IDs, oldest bid first, and `unclaimedSymbolRanges(bidder)` lists what remains. A claim that spans several bids mints several ID ranges, each reported by the collection's `SymbolsMinted` event. Credits never expire and can be claimed before or after settlement. Frontend copy must say that a bid does not put symbols in a wallet by itself.

**Clock and settlement.** The first bid starts the clock: the auction closes `duration` after it (`endsAt`, 0 until then). A bid within `extensionWindow` of the close moves the close to `extensionWindow` after that bid, with no limit, so the auction ends only after a full window with no new bid. Anyone can call `settle()` at or after the closing time. Settlement sends the 1/1 to the winner; if the winner's wallet rejects it, settlement still stands and the winner calls `claimPrize(to)`. A `settle()` call with too little gas for that delivery reverts with `InsufficientGas` and can be repeated. Only the treasury can withdraw the winning bid, with `withdrawProceeds(to)`. With no bids the clock never starts and the auction never ends: `settle()` reverts with `NoBids`, and the 1/1 is never minted. NFT receivers cannot block settlement or proceeds. Claims can target another recipient if a wallet rejects NFTs.

**What the auction holds.** Only ETH from bids. `liabilities()` is what it owes; its balance is never below that. It has no `receive` or fallback function: a plain ETH transfer reverts. Forced ETH has no recovery path and never increases treasury proceeds.

Symbols have zero-based motifs and six material codes with weights 44/24/14/9/5/4. Traits derive only from the chain ID, collection address and token ID, so every symbol's traits are public from deployment through `symbolTraits(id)`. Because a bid reserves specific IDs, claim time, claim order, recipient and wallet address cannot change what a bidder receives. **This is deterministic, public assignment, not randomness or guaranteed rarity:** bidders can see which upcoming IDs are rare and time their bids. The collection has no special gold allocation.

`weave(cells, columns, rows, appearance)` requires ownership of every source and a fully filled rectangle with at least two rows and columns. Approved marketplace operators cannot call it on someone else's tokens. `expand(artworkId, expectedRevision, cells, columns, rows, appearance)` additionally requires ownership of the artwork, a strictly larger composition, and every previous source exactly once. Old sources may be reordered; new sources must be owned by the caller. Burned symbols retain their traits and composition provenance in `symbolData()`.

This version has a hard limit of **256 cells**, with a lower immutable deployment limit allowed. It does not support a merge of every motif. `appearance` must be one of `bytes32("flat/ink")`, `bytes32("flat/indigo")` or `bytes32("flat/vermilion")` (left-aligned ASCII, as `ethers.encodeBytes32String` makes it); anything else reverts with `InvalidAppearance`. `freezeArtwork()` permanently disables expansion but leaves ordinary transfers available. Use `expectedRevision` to reject stale edits. Buyers must understand that unfrozen artwork can be changed by its owner before a sale; revision checks do not change external marketplace settlement rules.

The 1/1 uses token ID 1. Symbols use IDs 2 through `symbolCap + 1`, reserved at bid time. Compositions use a separate checked counter starting at `symbolCap + 2`. IDs are never reused; a burned symbol ID can never be minted again. `tokenURI` is drawn entirely on-chain by the immutable renderer fixed at construction (base64 JSON with SVG images, and for the 1/1 an HTML `animation_url`); ERC-4906 updates are emitted on expand and freeze. The constructor checks that the renderer's code hash is `rendererHash` and that it reports the same `motifCount` and `geometryHash`. Rendering a large artwork or the 1/1 is an expensive view (up to ~31M gas); see [docs/RENDERER.md](docs/RENDERER.md).

## Integration and launch inputs

The website calls these contracts through the ABIs in `abi/`; see the root [README](../README.md#the-auction-and-weaving-pages). The packed store on disk holds **812** motifs (`motifCount = 812`); the decision is 1,024, and the content hashes are computed by `onchain/pack_store.py` and become final with the symbol set. The site sends the renderer's appearance encoding (`bytes32` ASCII `flat/<ink|indigo|vermilion>`) and decodes the auction's and the collection's errors from `abi/*.json`.

Before deployment, work through the checklists in order: [pre-deploy](checklists/1-pre-deploy.md), [deploy](checklists/2-deploy.md) and [post-deploy](checklists/3-post-deploy.md). The launch settings are decided and listed in pre-deploy: native ETH, 100 registrations, a 0.01 ETH opening bid, +10% raises rounded up to 0.001 ETH, 24 hours from the first bid, a 10-minute late-bid window with no limit on extensions, up to 1,000,000 symbols with no smaller per-bid cap, 256 cells, 5% royalties, and orkhanart.eth as treasury and collection owner. On chain 1 the deploy script refuses any other value (`deploy/mainnet.example.json`, [docs/RENDERER.md](docs/RENDERER.md#what-the-script-refuses)). Still open: the final symbol set (and with it `motifCount` and the content hashes), the opening date, the inspection window, the deployer key and its published nonce, and the findings in [AUDIT.md](AUDIT.md). `test/LaunchConfig.t.sol` runs the decided settings. The shared unit-test fixture in `test/TestBase.sol` (10,000 rewards, 1,000 per bid, 5% increment, 22 hours, 10-minute window) is not the launch configuration; only its 0.01 ETH reserve is.

The target is **Ethereum mainnet**, chain ID **1**, with the **Sepolia** testnet (**11155111**) for the rehearsal. Bids and gas are both ETH. The contracts are compiled for the Cancun EVM, which both networks support; the renderer uses `MCOPY`. Ethereum caps each transaction at 16,777,216 gas (EIP-7825): every deployment transaction stays under 8M, and the heaviest user transactions are listed in [pre-deploy](checklists/1-pre-deploy.md) with their measured gas. None of this replaces the Sepolia rehearsal or real-network gas measurements.
