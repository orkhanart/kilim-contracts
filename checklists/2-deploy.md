# 2. Deploy checklist

The deployment itself: from final checks to verified, read-back contracts. Run it twice, first on Sepolia as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

Two phases, in this order ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)):

1. **The store** (`runStore()`): every chunk (motif grids, names, page prefix, head and tail) through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0. Any funded key, any time before the contracts; idempotent, so it can be rerun and sends only what is missing.
2. **The contracts** (`runContracts()`): from orkhanart.eth at its published nonce n: `KilimMotifs` (Motif Bazaar) at n, `KilimOneOfOne` (The Unwoven Kilim) at n + 1, both with the auction's predicted address (n + 2) as `minter`, then `KilimAuction` at n + 2.

`run()` does both in one go for the local dry run and the rehearsal; on mainnet it is refused.

```sh
cd contracts
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
  --rpc-url "$RPC" --broadcast --ledger --sender <any funded key>
# publish the chunk addresses, inspect, then:
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' \
  --rpc-url "$RPC" --broadcast --ledger --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac
```

## Pre-flight

`script/DeployKilim.s.sol` checks the items marked **(script)** itself and **refuses to send** if any fail. Confirm every item by hand as well.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same. Start from `deploy/mainnet.example.json`. The contracts phase prints every setting it deploys with and flags any that differs from the launch value; on chain 1 there must be no flag.
- [ ] **(script)** `block.chainid` equals the config's `chainId`. **By hand:** 1 for Ethereum mainnet, 11155111 for the Sepolia rehearsal.
- [ ] **(script)** The manifests: `motifCount` 1,024, the canonical CREATE2 deployer, every chunk file's size and keccak, every chunk's CREATE2 address, the chunk layout (full chunks before a section's last, grids cut at 24,544), the five section hashes recomputed from the files, and no foreign code at any chunk address. **By hand:** the manifests are the ones packed from the final artwork and still (`pnpm -s pack:motifs -- --check …`, `pnpm -s pack:page -- … --check`), and their hashes and addresses are the published ones.
- [ ] **(script)** The config texts equal the manifests': the collection `description`, and the 1/1's `name`, `description` and `externalUrl` (the goldens were computed with them).
- [ ] **(script)** Store phase: each missing chunk's dry run stays under 8M gas and lands at the predicted address. A chunk already there is verified and skipped.
- [ ] **(script)** Contracts phase: every chunk is already on the chain (`store not deployed: runStore first`).
- [ ] **(script)** The deployer's pending nonce equals the published `deployerNonce`. On chain 1 the check cannot be skipped. No other transaction from this key since publishing.
- [ ] **(script)** `reservePrice` is `10000000000000000` wei (0.01 ETH), on every chain. The auction constructor accepts no other value.
- [ ] **(script)** On chain 1: `deployer` and `treasury` are `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth); `incrementBps` 1000 (+10%); `duration` 86400 (24 hours from the first bid); `extensionWindow` 600 (10 minutes, no limit on extensions); `motifCap` and `maxMotifsPerBid` 1,000,000; `oneOfOne.name` "The Unwoven Kilim". **By hand:** fresh proof that the key still works ([1-pre-deploy.md](1-pre-deploy.md)). Switching the treasury to a Safe would mean changing `LAUNCH_TREASURY` in the script, its tests and the signed-off config, then re-tagging.
- [ ] **(script)** `startsAt` is in Unix **seconds** (not milliseconds), at least `minLeadSeconds` (the inspection window) ahead, and at most a year out. On chain 1, `minLeadSeconds` must be nonzero. **By hand:** it is the window that was announced; the script accepts any nonzero value.
- [ ] **(script)** The dry run of the three contracts: the auction's address equals the prediction (nonce + 2), every immutable reads back as deployed, a motif's `tokenURI` and the 1/1's `tokenURI(1)` hash to the manifests' goldens, and each deployment and each read stays under 8M gas.
- [ ] **(script)** forge simulates the whole script before sending anything. **By hand:** the broadcast gas limit comes from Ethereum's own estimate plus margin, and the key holds enough ETH (the store about 202M gas in all, the three contracts about 12M).
- [ ] The git tag is checked out, and `pnpm -s artifacts` matches the frozen `audit/build-manifest.json`.

## Send

- [ ] **Store phase.** Broadcast the chunk transactions (38 with today's store). Record each hash. Compare the addresses the script prints with the published ones. The chunks can go up over several days, from any key.
- [ ] **Contracts phase.** Broadcast the three creation transactions from orkhanart.eth, in order, at nonces n, n + 1, n + 2. They send no ETH: the auction holds nothing until the first bid.
- [ ] Record each transaction hash, block number and gas used.
- [ ] Confirm the three addresses match the published predictions.
- [ ] **If any of the three reverted, was replaced or dropped:** the published nonce is spent, and with it the addresses and the motif layout (`motifOf` depends on the Motif Bazaar address). If only the third failed, the two token contracts exist with a `minter` nobody controls; they are harmless and void. Before retrying:
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
- [ ] **Motif Bazaar** (`motifs()`): `name()` "Motif Bazaar", `symbol()` "MOTIF", `minter() == auction`, `royaltyReceiver()` (the treasury), `ROYALTY_BPS` 500, `motifCap`, `MOTIF_COUNT` 1024, `MAX_MINT_BATCH` 64, `gridsHash()`, `namesHash()`, `gridChunks()` and `namesChunk()` (the published addresses), `description()`, `externalUrl()`, `motifsMinted == 0`, `motifsBurned == 0`; `keccak256(grids())` equals `gridsHash`; `grid(1)` and `name(1)` equal the first 32 bytes of `grids.bin` and the first name; `contractURI()` decodes to the published texts; `tokenURI(1)` reverts (no token exists yet).
- [ ] **The Unwoven Kilim** (`oneOfOne()`): `name()` "The Unwoven Kilim", `symbol()` "UNWOVEN", `minter() == auction`, `motifs()` (the Motif Bazaar address), `royaltyReceiver()`, `ROYALTY_BPS` 500, `TOKEN_ID` 1, `prefixHash()`, `headHash()`, `tailHash()`, `prefixChunks()`, `headChunks()`, `tailChunks()` (the published values), `description()`, `externalUrl()`, `minted() == false`. `tokenURI(1)` cannot be read before the mint; the dry run compared it with the golden, and the first read after settlement is checked in [3-post-deploy.md](3-post-deploy.md).
- [ ] Spot-check `motifOf(id)` for a few ids against the published layout.

## If anything is wrong

A deployment cannot be abandoned. It opens registration at its own `startsAt`, takes real bids once 100 wallets register, and mints tokens named "Motif Bazaar" and "The Unwoven Kilim".

- [ ] Publicly mark its addresses void on the site, social channels, explorers and marketplaces, and make the site refuse them.
- [ ] Commit publicly that the treasury will return any winning bid on it with `withdrawProceeds(to = winner)`. Outbid bidders are refunded by the contract as usual.
- [ ] If the treasury address itself was the mistake, warn plainly that a winning bid there cannot be returned.
- [ ] Then fix the config, publish the new nonce, predicted addresses and layout, restart the inspection window, and run this checklist again. The chunks stay where they are and are reused.
