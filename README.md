# Kilim contracts

An immutable auction in native ETH for Ethereum mainnet, rehearsed on Sepolia, and the two ERC-721 contracts it mints into: **Motif Bazaar**, the motif collection, and **The Unwoven Kilim**, the 1/1. This is a **development release with an internal security review**, not a certification or a production deployment. Nothing is deployed. Read [AUDIT.md](AUDIT.md) before using real funds.

The design, decided with the artist on 10 October 2026, is [docs/CONTRACTS.md](docs/CONTRACTS.md). OpenZeppelin primitives are reused directly. The auction uses a limited adaptation of thirdweb's English auction flow and its unchanged winning-bid predicate; [REUSE.md](REUSE.md) records the exact audit-reference commit, source hashes, licenses and modifications. The custom escrow, registration and rewards require their own review; the upstream audit does not certify this adaptation.

## The contracts

| Contract | File | Name, ticker | Tokens |
| --- | --- | --- | --- |
| The auction base | `src/auction/EnglishAuction.sol` | — | none |
| Kilim Auction | `src/KilimAuction.sol` | — | none: it mints into the two below |
| Motif Bazaar | `src/KilimMotifs.sol` | `Motif Bazaar`, `MOTIF` | up to `motifCap` (1,000,000), ids `1..motifCap`, each showing one of the 1,024 motifs |
| The Unwoven Kilim | `src/KilimOneOfOne.sol` | `The Unwoven Kilim`, `UNWOVEN` | exactly one, id 1 |
| Kilim Bazaar, the weaver | not built | `KILIM` reserved | kilims; built when weaving opens |

- **`EnglishAuction`**: registration of 100 wallets before bidding opens, payable ETH bids, the thirdweb bid predicate, automatic refunds with a pull fallback, a clock that starts at the first bid, late-bid extensions with no limit, permissionless settlement and treasury proceeds.
- **`KilimAuction`**: motif credits for every bid, claims, and the 1/1 minted to the winner at settlement, added to the auction base. Its constructor takes the two token contracts' addresses and checks that each names this auction as its `minter`, that the 1/1 reads this motif collection, and that the treasury is neither of them.
- **`KilimMotifs`**, Motif Bazaar: the 1,024 motifs' 16 × 16 grids and names live in SSTORE2 chunks whose hashes the constructor checks. Which motif a token shows is `motifOf(id)`, fixed by the chain, the contract address and the id: public from deployment, not random. `tokenURI` is a contract-drawn SVG with the motif number and name as attributes. The owner of a motif, and nobody else, can `burn` it; a burned id can never be minted again. This is what the weaver will use.
- **`KilimOneOfOne`**, The Unwoven Kilim: one token whose page is stored in chunks and served from the chain. `tokenURI(1)` assembles the token JSON and the loader page in one buffer, taking the motif grids live from `KilimMotifs.grids()`, so the 1/1 provably draws the same motifs the motif tokens show. [docs/STORAGE.md](docs/STORAGE.md) gives the chunk layout, the hash chain, the assembly and its measured gas. The artwork file itself keeps its inner title, "KILIM / What the weave remembers"; the token is The Unwoven Kilim.
- **Kilim Bazaar**, the weaver, is not built. It will burn motifs through `KilimMotifs.burn` and mint kilims; its rules are a draft in `../launch/KILIM-BAZAAR-RULES.md`.

No contract has an admin, pause, upgrade, metadata setter or ownership role. Everything is fixed by constructor arguments, and each token contract's `minter` is an immutable address: the auction's, predicted from the deployer's nonce before the auction exists. There are no unrestricted mint endpoints, administrator asset seizures or admin withdrawals.

## Also in this directory

- `script/DeployKilim.s.sol`: deploys the chunks by CREATE2 from any funded wallet, then the three contracts from the artist's wallet at consecutive nonces, and refuses before sending anything on any mismatch (hashes, chunk files, addresses, goldens, gas, read-back, a pending transaction from the deployer, a deployer with code, a store that would spend the published nonce). `runAuction()` completes a deployment whose third transaction was dropped from the pool, never mined; a third creation that was mined and reverted, or replaced, spent the nonce the two token contracts' minter needs, and the script refuses to complete it. On Ethereum mainnet it also refuses any auction setting other than the decided launch values, any deployer but the artist's wallet, any 1/1 name but "The Unwoven Kilim", content the config does not name by hash (`expected`, printed by `pnpm -s expected`), and an artwork that never reads `KILIM_GRIDS`. Configs: `deploy/local.json` (the dry run), `deploy/sepolia.example.json`, `deploy/mainnet.example.json`.
- The packers, in `../onchain/`: `pack_motifs.py` turns the artist's page into `grids.bin`, `names.bin`, the chunk files and a manifest with hashes, CREATE2 addresses and the motif `tokenURI` golden; `pack_page.py` turns the final artwork page and its still into the loader (`loader.html`), the three page sections, their chunks and a manifest with the 1/1's `tokenURI` golden. `keccak.py` is the pure-Python keccak they share. `pnpm -s stores` runs both with the texts of a deploy config. Their tests are `../onchain/test/test_pack.py` and `page.test.mjs`.
- `test/`: unit, adversarial, fuzz, golden and stateful invariant tests for all three contracts and the deploy script's refusals. `test/review/` holds the tests the review round of 10 October left behind: properties it tried to break and could not (the encoders, the grids source, re-entry through receivers, royalty arithmetic, recipients), and its gas measurements.
- `scripts/`: the runners and dev tools listed below. `abi/` holds the exported ABIs and `audit/` the reproducible build manifest, the Slither output and the review records.

## Run locally

Requires Node.js 22+ and pnpm 11.19.0. Foundry 1.7.1 is installed as a pinned native package; `scripts/forge.mjs` runs that binary directly and preserves exit codes, so no global `forge` is needed. Every command below runs in `contracts/`.

```sh
pnpm install --frozen-lockfile
pnpm -s verify:upstream   # the thirdweb snapshot, license, denominator and retained function
pnpm -s build             # forge build, with contract sizes
pnpm -s test:contracts    # the forge suite
pnpm -s test              # the forge suite, the site tests (../site/test, on a local anvil), the packers and the page
pnpm -s test:ci           # the same with the ci profile (more fuzz and invariant runs)
pnpm -s fmt               # forge fmt --check
pnpm -s artifacts         # export abi/*.json and audit/build-manifest.json
pnpm -s coverage          # lcov and a summary
```

The stores and the deployment (Python 3.9+, no extra packages; headless Chrome for `test:page`):

```sh
pnpm -s stores            # the artist's page, its release copy and its still -> ../onchain/build-motifs, build-page
                          # (texts from deploy/local.json; --config <file> for another config)
pnpm -s check:stores      # fail unless both stores are exactly what those inputs give
pnpm -s expected          # the `expected` block of hashes for a deploy config
pnpm -s test:pack         # the packers, on synthetic pages
pnpm -s test:page         # the 1/1's exact animation_url, opened in headless Chrome
pnpm -s deploy:dry        # check:stores, then both phases in forge's memory, with gas and golden checks
```

Any other forge command: `node scripts/forge.mjs <args>`.

Dev tools, local chains only: `pnpm -s dev:chain` (anvil with a fresh deployment for the site; `--open` registers 100 throwaway wallets), `pnpm -s walkthrough` (the whole auction narrated through the site's own adapter), `node scripts/bench.mjs` (a page of buttons against a private chain), `node scripts/probe-rpc.mjs` (how much gas RPC endpoints allow an `eth_call`, without deploying), `pnpm -s site-config --chain <id> --auction <address> --tx <creation transaction>` (points the site at a real deployment after verifying it), `pnpm -s site:build`, `pnpm -s test:site`.

Compilation pins Solidity **0.8.37**, OpenZeppelin **5.6.1**, Cancun EVM, optimizer 200 runs, and the legacy code-generation pipeline. Foundry downloads the pinned native compiler on first use. Build and test scripts verify the thirdweb source snapshot, license, denominator and retained function before running. `pnpm artifacts` rejects stale source/dependency inputs and non-production build settings before exporting. It records hashes for sources, tests, scripts and upstream evidence, the files git tracks only, so a clean checkout of a tag regenerates the manifest byte for byte (checklists/2-deploy.md, pre-flight, compares it with `git diff`).

Static analysis requires Python 3.10+:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r audit/requirements.txt
pnpm -s audit:static
```

The full Slither output is retained in `audit/slither.json`; timestamp warnings are reviewed in the audit rather than hidden.

## Exact behavior

[docs/NATIVE-ETH.md](docs/NATIVE-ETH.md) is the full description of the auction. In short:

**Registration.** From `startsAt`, the first 100 wallets register with `register()`, or a sponsor submits `registerFor(wallet, deadline, signature)` with the wallet's EIP-712 signature (plain accounts and ERC-1271 wallets). A wallet must hold at least 0.01 ETH when it registers. Nothing is deposited. Bidding opens when the count is exactly 100, and the 100th registration does nothing else: no bid, no motifs, no clock. Registration counts addresses, not people, and one actor can fill every slot. If 100 wallets never register, bidding never opens.

**Bids.** `bid(amount, minimumReward, expectedFirstMotifId)` is payable and takes a **new full bid**, not a top-up: `msg.value` must equal `amount`, in wei. The opening bid is `reservePrice`, 0.01 ETH, the only value the constructor accepts. The next bid is the current high bid plus the configured percentage, rounded **up** to a whole 0.001 ETH (`MOTIF_PRICE`), and every bid must be a whole multiple of that unit. Any wallet except the treasury can bid once bidding is open, registered or not (`TreasuryCannotBid`); other wallets a seller controls cannot be detected on-chain. Re-bidding from the same address is allowed and must also be fully funded. Increment, treasury, opening time, duration, late-bid window and reward limits are fixed at deployment.

**Refunds.** The outbid bidder gets their full prior bid back automatically, inside the bid that beats it, and keeps all allocated credits. If that payment fails (for example a contract that rejects ETH), the amount waits in `refunds` for `withdrawRefund(to)`, so no address can block later bids. A bid that outbids someone must carry enough gas for the refund's full allowance or it reverts with `InsufficientGas`.

**Motif credits.** Every accepted bid allocates `min(amount / 0.001 ETH, maxMotifsPerBid, motifs left under motifCap)` motif credits. Outbid bidders keep them. This is intentional: it rewards continued bidding. It also means one wallet can collect credits by repeatedly outbidding itself; the caps bound total issuance, not who receives it. Once the pool is exhausted, the auction continues with zero new rewards. `minimumReward` lets the bidder reject an unexpected reduction caused by another bid. `expectedFirstMotifId` lets the bidder reject a different id range, and therefore different motifs, if another bid lands first: while `rewardForBid(amount) > 0`, a frontend that shows the range passes `1 + motifsAllocated()` read when quoting, and the bid reverts with `MotifRangeMoved` unless it reserves ids starting exactly there. Pass `0` to accept whatever ids are next, and **always pass `0` once the quoted reward is 0**: after the pool runs out a bid reserves no ids, so any nonzero value reverts.

**Motifs are claimed, never sent.** Each bid **reserves the next motif token ids** in allocation order, starting at 1; `BidPlaced` reports the first reserved id. The bidder mints them with `claimMotifs(quantity, recipient)`, in batches of 1–64, and pays the gas. Claims mint exactly the reserved ids, oldest bid first, and `unclaimedMotifRanges(bidder)` lists what remains. A claim that spans several bids mints several id ranges, each reported by the collection's `MotifsMinted` event. Credits never expire and can be claimed before or after settlement. Frontend copy must say that a bid does not put motifs in a wallet by itself.

**Clock and settlement.** The first bid starts the clock: the auction closes `duration` after it (`endsAt`, 0 until then). A bid within `extensionWindow` of the close moves the close to `extensionWindow` after that bid, with no limit, so the auction ends only after a full window with no new bid. Anyone can call `settle()` at or after the closing time. Settlement mints the 1/1 to the winner; if the winner's wallet rejects it, settlement still stands and the winner calls `claimPrize(to)`; only the winner can claim it, with its own gas and to any address, so only the winner chooses where it goes. `highestBidMotifs()` names the motif ids the winning bid reserved. A `settle()` call with too little gas for that delivery reverts with `InsufficientGas` and can be repeated. Only the treasury can withdraw the winning bid, with `withdrawProceeds(to)`. With no bids the clock never starts and the auction never ends: `settle()` reverts with `NoBids`, and the 1/1 is never minted. NFT receivers cannot block settlement or proceeds. Claims can target another recipient if a wallet rejects NFTs.

**What the auction holds.** Only ETH from bids. `liabilities()` is what it owes; its balance is never below that. It has no `receive` or fallback function: a plain ETH transfer reverts. Forced ETH has no recovery path and never increases treasury proceeds.

**The tokens.** Which motif a token shows is `motifOf(id) = keccak256(abi.encode(deploymentChainId, motifs, id)) % 1024 + 1` (the chain id recorded when the collection was deployed, so a later change of chain id cannot change a token's motif), public from deployment for every id, minted or not. Because a bid reserves specific ids, claim time, claim order, recipient and wallet address cannot change what a bidder receives. **This is deterministic, public assignment, not randomness or guaranteed rarity:** bidders can see which upcoming ids show which motif and time their bids. A motif token's `tokenURI` is `data:application/json;base64,` JSON named `<Name> (motif <n>)`, with the collection description, an SVG image (`viewBox 0 0 20 20`, white paper, the 16 × 16 motif at (2, 2) in `#141414`, one `<rect>` per horizontal run) and the attributes `Motif` (1..1024) and `Name`. Names are not unique: 29 distinct names across the 1,024 motifs. The 1/1's `tokenURI(1)` is `data:application/json;utf8,` JSON with a WebP still as `image` and the page as a `data:text/html;base64,` `animation_url`, 1,068,627 bytes with the artwork as it stood on 11 October (re-packed with the 30-motif rank named Spinner); reading it costs 4.52M gas (`eth_call`), see [docs/STORAGE.md](docs/STORAGE.md). Both contracts have `contractURI()` and fixed 5% ERC-2981 royalties to the treasury. Ids are never reused: a burned motif id can never be minted again.

## Integration and launch inputs

The website calls these contracts through the ABIs in `abi/`; see the root [README](../README.md). `site/motifs.js` is generated from the same packer as the chunks (`site/tools/pack_motifs.py`) and carries `gridsHash` and `namesHash`; the site refuses a collection whose hashes differ. The site decodes the auction's and the token contracts' errors from `abi/*.json`.

Before deployment, work through the checklists in order: [pre-deploy](checklists/1-pre-deploy.md), [deploy](checklists/2-deploy.md) and [post-deploy](checklists/3-post-deploy.md). The launch settings are decided and listed in pre-deploy: native ETH, 100 registrations, a 0.01 ETH opening bid, +10% raises rounded up to 0.001 ETH, 24 hours from the first bid, a 10-minute late-bid window with no limit on extensions, up to 1,000,000 motifs with no smaller per-bid cap, 5% royalties, and orkhanart.eth as deployer, treasury and royalty receiver. On chain 1 the deploy script refuses any other value (`deploy/mainnet.example.json`, [docs/STORAGE.md](docs/STORAGE.md#deployment-and-what-the-script-refuses)). Still open (11 October): the opening date and the published nonce (after orkhanart.eth is switched back from its EIP-7702 delegation), the independent audit and the marketplace's confirmation; [checklists/0-launch-steps.md](checklists/0-launch-steps.md) lists the steps in order. The artwork is final and reads `KILIM_GRIDS`, the still is the lossless WebP, the three duplicate motifs are replaced, and `deploy/mainnet.json` is filled except the date and the nonce. `test/LaunchConfig.t.sol` runs the decided settings. The shared unit-test fixture in `test/TestBase.sol` (a 10,000-motif cap, 1,000 per bid, 5% increment, 22 hours, 10-minute window, a stand-in page) is not the launch configuration; only its 0.01 ETH reserve is.

The target is **Ethereum mainnet**, chain ID **1**, with the **Sepolia** testnet (**11155111**) for the rehearsal. Bids and gas are both ETH. The contracts are compiled for the Cancun EVM, which both networks support. Ethereum caps each transaction at 16,777,216 gas (EIP-7825): every deployment transaction stays under 8M, and the heaviest user transactions are listed in [pre-deploy](checklists/1-pre-deploy.md) with their measured gas. None of this replaces the Sepolia rehearsal or real-network gas measurements.
