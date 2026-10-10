# 2. Deploy checklist

The deployment itself: from final checks to verified, read-back contracts. Run it twice, first on Sepolia as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

Two phases, in this order ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)):

1. **The store** (`runStore()`): every chunk (motif grids, names, page prefix, head and tail) through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0. Sent by forge's `--sender`: any funded wallet **other than orkhanart.eth once its nonce is published** (46 chunks today would move that nonce, and the script refuses it). Any time before the contracts; idempotent, so it can be rerun and sends only what is missing.
2. **The contracts** (`runContracts()`): from orkhanart.eth at its published nonce n: `KilimMotifs` (Motif Bazaar) at n, `KilimOneOfOne` (The Unwoven Kilim) at n + 1, both with the auction's predicted address (n + 2) as `minter`, then `KilimAuction` at n + 2.

`run()` does both in one go for the local dry run only (`pnpm -s deploy:dry`). The Sepolia rehearsal uses the two phases exactly as mainnet does, with the nonce published after the store; on mainnet `run()` is refused.

```sh
cd contracts
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --ledger --sender <a funded wallet that is not the deployer>
# publish the chunk addresses and the deployer's nonce, inspect, then:
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --ledger --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac
```

`--slow` sends each transaction only after the one before it is confirmed and succeeded. Without it forge signs and sends a whole phase at once, and if the first creation is lost the other two are still spent on creations that revert. `--timeout` is how long forge waits for a receipt (seconds). If forge stops on a timeout or a dropped transaction, nothing is lost: rerun the same command with `--resume`, which continues from the saved broadcast file without simulating again and expects the nonces unchanged; a transaction that was dropped from the pool has to be removed from that file before it is sent again. If the Ledger's address is not its first one, add `--mnemonic-indexes <n>` (or `--hd-paths`).

## Pre-flight

`script/DeployKilim.s.sol` checks the items marked **(script)** itself and **refuses to send** if any fail. Confirm every item by hand as well.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same. Start from `deploy/mainnet.example.json`. The contracts phase prints every setting it deploys with and flags any that differs from the launch value; on chain 1 there must be no flag.
- [ ] **(script)** `block.chainid` equals the config's `chainId`. **By hand:** 1 for Ethereum mainnet, 11155111 for the Sepolia rehearsal; and the chain has code at the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (`cast code`; mainnet and Sepolia do. forge's own simulation supplies that code even where the chain lacks it, so the script cannot tell).
- [ ] **(script)** The manifests: `motifCount` 1,024, the canonical CREATE2 deployer, every chunk file's size and keccak, every chunk's CREATE2 address, the chunk layout (full chunks before a section's last, grids cut at 24,544), the five section hashes recomputed from the files, and no foreign code at any chunk address. **By hand:** the manifests are the ones packed from the final artwork and still (`pnpm -s check:stores --config <the config>`), and their hashes and addresses are the published ones.
- [ ] **(script)** The content is the content the config names: the `expected` block (five section hashes, the two tokenURI goldens, the sha256 of the artist's page, the artwork, the still and the loader; `pnpm -s expected` prints it) equals the manifests, value by value, in both phases. On chain 1 a config without the block, or with a zero in it, is refused, and so is an artwork whose manifest says it never reads `KILIM_GRIDS`. **By hand:** the block is the published one, and two people compared it.
- [ ] **(script)** The config texts equal the manifests': the collection `description` and `externalUrl`, and the 1/1's `name`, `description` and `externalUrl` (the goldens were computed with them, except the collection's link, which the packer records for this comparison). The token JSON holds no `#` or `%`.
- [ ] **(script)** Store phase: each missing chunk's dry run stays under 8M gas and lands at the predicted address. A chunk already there is verified and skipped. The script prints who sends and how many chunks, and refuses when the sender is the config's deployer, a nonce is published for it and a chunk is still missing.
- [ ] **(script)** Contracts phase: every chunk is already on the chain (`store not deployed: runStore first`).
- [ ] **(script)** The deployer's nonce at the latest block equals the published `deployerNonce`, and so does its pending nonce (`eth_getTransactionCount(deployer, "pending")`, asked of the node the script runs against): a transaction from the wallet still waiting in the pool is refused. On chain 1 the check cannot be skipped. **By hand:** no other transaction from this key since publishing, and none waiting in another node's pool (look the wallet up in a block explorer right before sending).
- [ ] **(script)** `reservePrice` is `10000000000000000` wei (0.01 ETH), on every chain. The auction constructor accepts no other value.
- [ ] **(script)** On chain 1: `deployer` and `treasury` are `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth); `incrementBps` 1000 (+10%); `duration` 86400 (24 hours from the first bid); `extensionWindow` 600 (10 minutes, no limit on extensions); `motifCap` and `maxMotifsPerBid` 1,000,000; `oneOfOne.name` "The Unwoven Kilim". **By hand:** fresh proof that the key still works ([1-pre-deploy.md](1-pre-deploy.md)). Switching the treasury to a Safe would mean changing `LAUNCH_TREASURY` in the script, its tests and the signed-off config, then re-tagging.
- [ ] **(script)** `startsAt` is in Unix **seconds** (not milliseconds), at least `minLeadSeconds` (the inspection window) ahead, and at most a year out. On chain 1, `minLeadSeconds` must be nonzero. **By hand:** it is the window that was announced; the script accepts any nonzero value.
- [ ] **(script)** The dry run of the three contracts: the auction's address equals the prediction (nonce + 2), every immutable reads back as deployed, a motif's `tokenURI` and the 1/1's `tokenURI(1)` hash to the manifests' goldens, and each deployment and each read stays under 8M gas.
- [ ] **(script)** forge simulates the whole script before sending anything. **By hand:** the commands carry `--slow` and `--timeout`; the broadcast gas limit comes from Ethereum's own estimate plus margin, and the keys hold enough ETH (the store about 252M gas in all with the page of 10 October, the three contracts about 13.4M).
- [ ] The git tag is checked out, and `pnpm -s artifacts` matches the frozen `audit/build-manifest.json`.

## Send

- [ ] **Store phase.** Broadcast the chunk transactions (46 with the page of 10 October). Record each hash. Compare the addresses the script prints with the published ones. The chunks can go up over several days, from any wallet but the deployer.
- [ ] **Contracts phase.** Broadcast the three creation transactions from orkhanart.eth, in order, at nonces n, n + 1, n + 2. They send no ETH: the auction holds nothing until the first bid.
- [ ] Record each transaction hash, block number and gas used.
- [ ] Confirm the three addresses match the published predictions.
- [ ] **If only the third (the auction) was lost** (dropped, replaced or reverted) and the first two are mined: nothing is void. The two token contracts name the address at nonce n + 2 as their minter, and the auction can still be deployed there. Find the cause, send nothing else from the wallet, then run the same command with `--sig 'runAuction()'`: it requires the deployer at n + 2, reads both token contracts back against the config, repeats every check and the golden comparison, and sends only the auction. The published addresses and the motif layout stand.
- [ ] **If the first or the second was lost:** the published nonce is spent, and with it the addresses and the motif layout (`motifOf` depends on the Motif Bazaar address). With `--slow` the later ones were not sent. Before retrying:
  1. find the cause;
  2. publish the new nonce, predicted addresses and motif layout;
  3. restart the inspection window.

## Verify source

- [ ] Verify `KilimMotifs` on Etherscan, with its constructor arguments in this order: `minter` (the **auction** address), `royaltyReceiver`, `motifCap`, `gridChunks` (`address[]`, the grid chunks in order), `gridsHash`, `namesChunk`, `namesHash`, `description`, `externalUrl`.
- [ ] Verify `KilimOneOfOne`: `minter` (the auction), `royaltyReceiver`, `motifs` (the Motif Bazaar address), `page` (one struct: `prefixChunks` `address[]`, `prefixHash`, `headChunks` `address[]`, `headHash`, `tailChunks` `address[]`, `tailHash`), `name`, `description`, `externalUrl`.
- [ ] Verify `KilimAuction`: one `Config` struct of 9 fields, in this order: `treasury`, `motifs`, `oneOfOne`, `startsAt`, `duration`, `extensionWindow`, `incrementBps`, `reservePrice`, `maxMotifsPerBid`.
- [ ] The chunks are code-only (`0x00` followed by the data) and need no verification; publish their addresses and the files they hold.
- [ ] Confirm the verifier supports solc 0.8.37 with optimizer 200, cancun, no via-IR, ipfs metadata. Keep Sourcify as a fallback.
- [ ] All three contracts show as verified, and their source matches the tagged commit.

## Read back

Check every value on-chain against the config **before `startsAt`**. The script only read back its own simulation before sending; this checks the chain itself. On chain 1 every value must also equal the launch value in the pre-flight list above.

- [ ] **Auction settings:** `treasury`, `reservePrice` (10000000000000000), `incrementBps`, `startsAt`, `duration`, `extensionWindow`, `motifs()`, `oneOfOne()`, `motifCap` (equal to the collection's), `maxMotifsPerBid`.
- [ ] **Auction constants:** `MOTIF_PRICE` = 1000000000000000 (0.001 ETH), `REGISTRATION_BALANCE` = 10000000000000000 (0.01 ETH), `REGISTRATION_TARGET` = 100.
- [ ] **Registration domain:** `eip712Domain()` returns name `Kilim Registration`, version `1`, this chain ID and this auction's address. A sponsor or site that signs for any other domain will fail.
- [ ] **Nothing has happened yet:**
  - `registrationCount == 0`;
  - `endsAt == 0`: it is set only by the first bid, to that bid's time plus `duration`;
  - `highestBid == 0`, `highestBidder == 0x0`;
  - `motifsAllocated == 0`, `motifsClaimed == 0`, `settled == false`, `prizeClaimed == false`;
  - `refundLiability == 0`, `proceedsDue == 0`, `liabilities() == 0`;
  - the auction's ETH balance is 0.
- [ ] **Closed doors:** `minimumBid()` returns 10000000000000000. Simulate (do not send) a `bid` of that amount with that value: it must revert with `RegistrationIncomplete`. Simulate `register()`: before `startsAt` it must revert with `RegistrationClosed`. Simulate a plain ETH transfer to the auction: it must revert.
- [ ] **Motif Bazaar** (`motifs()`): `name()` "Motif Bazaar", `symbol()` "MOTIF", `minter() == auction`, `royaltyReceiver()` (the treasury), `ROYALTY_BPS` 500, `motifCap`, `MOTIF_COUNT` 1024, `deploymentChainId` (the chain's id), `MAX_MINT_BATCH` 64, `gridsHash()`, `namesHash()`, `gridChunks()` and `namesChunk()` (the published addresses), `description()`, `externalUrl()`, `motifsMinted == 0`, `motifsBurned == 0`; `keccak256(grids())` equals `gridsHash`; `grid(1)` and `motifName(1)` equal the first 32 bytes of `grids.bin` and the first name; `contractURI()` decodes to the published texts; `tokenURI(1)` reverts (no token exists yet).
- [ ] **The Unwoven Kilim** (`oneOfOne()`): `name()` "The Unwoven Kilim", `symbol()` "UNWOVEN", `minter() == auction`, `motifs()` (the Motif Bazaar address), `royaltyReceiver()`, `ROYALTY_BPS` 500, `TOKEN_ID` 1, `prefixHash()`, `headHash()`, `tailHash()`, `prefixChunks()`, `headChunks()`, `tailChunks()` (the published values), `description()`, `externalUrl()`, `minted() == false`. `tokenURI(1)` cannot be read before the mint; the dry run compared it with the golden, and the first read after settlement is checked in [3-post-deploy.md](3-post-deploy.md).
- [ ] Spot-check `motifOf(id)` for a few ids against the published layout.

## If anything is wrong

A deployment cannot be abandoned. It opens registration at its own `startsAt`, takes real bids once 100 wallets register, and mints tokens named "Motif Bazaar" and "The Unwoven Kilim".

- [ ] Publicly mark its addresses void on the site, social channels, explorers and marketplaces, and make the site refuse them.
- [ ] Commit publicly that the treasury will return any winning bid on it with `withdrawProceeds(to = winner)`. Outbid bidders are refunded by the contract as usual.
- [ ] If the treasury address itself was the mistake, warn plainly that a winning bid there cannot be returned.
- [ ] Then fix the config, publish the new nonce, predicted addresses and layout, restart the inspection window, and run this checklist again. The chunks stay where they are and are reused.
