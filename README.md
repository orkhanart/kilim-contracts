# Kilim contracts

An implementation for Robinhood Chain using an immutable ERC-20 USD stablecoin. This is a **development release with an internal security review**, not a certification or a production deployment. Read [AUDIT.md](AUDIT.md) before using real funds.

OpenZeppelin primitives are reused directly. The auction uses a limited adaptation of thirdweb's English auction flow and its unchanged winning-bid predicate. [REUSE.md](REUSE.md) records the exact audit-reference commit, source hashes, licenses and modifications. The custom escrow and rewards require their own review; the upstream audit does not certify this adaptation.

## Included

- `src/auction/ERC20EnglishAuction.sol`: immutable stablecoin auction, thirdweb bid predicate, pull refunds, bounded late-bid extensions, permissionless settlement and treasury proceeds.
- `src/KilimAuction.sol`: retained symbol credits and a separately claimed 1/1, added to the auction base.
- `src/Kilim.sol`: one ERC-721 collection containing the 1/1, symbols, and compositions. Compositions burn source symbols atomically, can expand under the same token ID, and can be permanently frozen by their owner.
- Unit, adversarial, fuzz, and stateful invariant tests; pinned dependencies; exported ABIs and a reproducible build manifest.

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

The next bid is the current high bid plus the configured percentage, rounded **up** to a whole token unit. Reserve price, increment, stablecoin, treasury, opening time, duration, extension limit, and reward limits are fixed at deployment. Re-bidding from the same address is allowed and must also be fully funded.

Every accepted bid allocates `min(whole token units, per-bid reward cap, remaining collection rewards)` symbol credits. The outbid bidder withdraws their full prior bid and keeps all allocated credits. This is intentional: it rewards continued bidding. It also means one wallet can collect credits by repeatedly outbidding itself and withdrawing; the caps bound total issuance, not who receives it. Once the reward supply is exhausted, the auction continues with zero new rewards. `minimumReward` lets the bidder reject an unexpected reduction caused by another bid. `expectedFirstSymbolId` lets the bidder reject a different ID range, and therefore different traits, if another bid lands first: while `rewardForBid(amount) > 0`, the frontend passes `collection().FIRST_SYMBOL_ID() + symbolsAllocated()` read when quoting, and the bid reverts with `SymbolRangeMoved` unless it reserves IDs starting exactly there. Pass `0` to accept whatever IDs are next, and **always pass `0` once the quoted reward is 0**: after the pool runs out a bid reserves no IDs, so any nonzero value reverts. The treasury address cannot bid (`TreasuryCannotBid`); other wallets a seller controls cannot be detected on-chain.

**NFTs are claimed separately**, in batches of 1–64, via `claimSymbols(quantity, recipient)`. Each bid **reserves the next symbol token IDs** in allocation order; `BidPlaced` reports the first reserved ID. Claims mint exactly those IDs, oldest bid first, and `unclaimedSymbolRanges(bidder)` lists what remains. A claim that spans several bids mints several ID ranges, each reported by the collection's `SymbolsMinted` event. Credits never expire and can be claimed before or after settlement. This deliberately replaces the prototype's unbounded synchronous NFT mint. Frontend copy must reflect it.

Refunds use `withdrawRefund(recipient)`. Anyone can call `settle()` at or after the closing time. Only the treasury can withdraw winning proceeds; only the winner can claim the 1/1. With no bids, the treasury can claim the unsold 1/1. NFT receivers cannot block settlement or proceeds. Claims can target an alternative recipient if a wallet rejects NFTs or a token blocks a recipient.

Symbols have zero-based motifs and six material codes with weights 44/24/14/9/5/4. Traits derive only from the chain ID, collection address and token ID, so every symbol's traits are public from deployment through `symbolTraits(id)`. Because a bid reserves specific IDs, claim time, claim order, recipient and wallet address cannot change what a bidder receives. **This is deterministic, public assignment, not randomness or guaranteed rarity:** bidders can see which upcoming IDs are rare and time their bids. The collection has no special gold allocation.

`weave(cells, columns, rows, appearance)` requires ownership of every source and a fully filled rectangle with at least two rows and columns. Approved marketplace operators cannot call it on someone else's tokens. `expand(artworkId, expectedRevision, cells, columns, rows, appearance)` additionally requires ownership of the artwork, a strictly larger composition, and every previous source exactly once. Old sources may be reordered; new sources must be owned by the caller. Burned symbols retain their traits and composition provenance in `symbolData()`.

This version has a hard limit of **256 cells**, with a lower immutable deployment limit allowed. It does not support an 812-cell merge. `appearance` is a 32-byte commitment; publishing its preimage and canonical interpretation is an outstanding renderer integration requirement. `freezeArtwork()` permanently disables expansion but leaves ordinary transfers available. Use `expectedRevision` to reject stale edits. Buyers must understand that unfrozen artwork can be changed by its owner before a sale; revision checks do not change external marketplace settlement rules.

The 1/1 uses token ID 1. Symbols use IDs 2 through `symbolCap + 1`, reserved at bid time. Compositions use a separate checked counter starting at `symbolCap + 2`. IDs are never reused; a burned symbol ID can never be minted again. Metadata is JSON encoded on-chain and emits ERC-4906 updates, but **image/animation rendering and artwork bytes are not yet stored or served by these contracts**. `geometryHash` and `rendererHash` are immutable content commitments, not proof of data availability or valid artwork. No metadata claims a completed renderer.

## Integration and launch inputs

The website remains a local preview. `site/chain.js` is not connected to this implementation. The collection uses the geometry's **812** motifs (`motifCount = 812`); the content hashes still need to be finalized.

Before deployment, work through the checklists in order: [pre-deploy](checklists/1-pre-deploy.md), [deploy](checklists/2-deploy.md) and [post-deploy](checklists/3-post-deploy.md). In particular, resolve the specific stablecoin contract, treasury, exact schedule, reserve/increment, total reward supply, per-bid reward cap, canvas limit, renderer/appearance encoding, and the economic/trait findings in [AUDIT.md](AUDIT.md). Test values (10,000 rewards, 1,000 per bid, $25 reserve, 5% increment, 22 hours, 10-minute extensions with a one-hour hard extension limit) are fixtures, not approved launch terms.

Robinhood's official network documentation lists mainnet chain ID **4663**, testnet **46630**, and ETH for gas. Both RPC chain IDs and a read-only `MCOPY` execution probe were checked during this review. This establishes basic Cancun opcode compatibility; it does not replace target-network deployment, fork, gas, or real stablecoin testing. Sources: [network configuration](https://docs.robinhood.com/chain/connecting/), [deployment guide](https://docs.robinhood.com/chain/deploy-smart-contracts/).

The chain's native stablecoin is Paxos **USDG**, 6 decimals: mainnet `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, testnet `0x7E955252E15c84f5768B83c41a71F9eba181802F` ([Paxos mainnet](https://docs.paxos.com/guides/stablecoin/usdg/mainnet), [testnet](https://docs.paxos.com/guides/stablecoin/usdg/testnet)). It is an upgradeable, pausable token with per-address freezing; see AUDIT.md K-04 before choosing it.

The contracts reject direct ETH transfers. Unexpected ERC-20 donations and forced ETH have no recovery path; they never increase treasury proceeds. Only deploy with a vetted, exact-transfer, non-rebasing stablecoin. Issuer freezes, upgrades, bridge failures, and a broken peg remain external risks.
