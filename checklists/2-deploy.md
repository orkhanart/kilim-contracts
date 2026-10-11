# 2. Deploy checklist

The deployment itself: from final checks to verified, read-back contracts. Run it twice, first on Sepolia as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

Two phases, in this order ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)):

1. **The store** (`runStore()`): every chunk (motif grids, names, page prefix, head and tail) through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0. Sent by forge's `--sender`: any funded wallet **other than orkhanart.eth once its nonce is published** (45 chunks today would move that nonce, and the script refuses it). Any time before the contracts; idempotent, so it can be rerun and sends only what is missing.
2. **The contracts** (`runContracts()`): from orkhanart.eth at its published nonce n: `KilimMotifs` (Motif Bazaar) at n, `KilimOneOfOne` (The Unwoven Kilim) at n + 1, both with the auction's predicted address (n + 2) as `minter`, then `KilimAuction` at n + 2.

`run()` does both in one go for the local dry run only (`pnpm -s deploy:dry`). The Sepolia rehearsal uses the two phases as mainnet does, with the nonce published after the store, but with the gas flags of [the section below](#the-sepolia-rehearsal-runs-glamsterdam): Sepolia already runs Glamsterdam. On mainnet `run()` is refused.

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

`--slow` sends each transaction only after the one before it is confirmed and succeeded. Without it forge signs and sends a whole phase at once, and if the first creation is lost the other two are still spent on creations that revert. `--timeout` is how long forge waits for a receipt (seconds). If the Ledger's address is not its first one, add `--mnemonic-indexes <n>` (or `--hd-paths`).

**Store phase only:** if forge stops on a timeout or a dropped transaction, nothing is lost. Rerun the same command with `--resume`, which continues from the saved broadcast file without simulating again and expects the nonces unchanged; a transaction that was dropped from the pool has to be removed from that file before it is sent again. Rerunning without `--resume` works too, since the phase sends only what is missing. The contracts phase is never resumed after a transaction was removed from the broadcast file: a lost creation is handled under [Send](#send).

forge sets each transaction's gas limit from its own simulation of it, in the EVM that `foundry.toml` names (Cancun), times `--gas-estimate-multiplier` (130% by default). It does not ask the node's `eth_estimateGas`. That is right for mainnet only while mainnet has not forked to Glamsterdam.

## The Sepolia rehearsal runs Glamsterdam

Sepolia has run Glamsterdam since 6 October 2026. Under EIP-8037 code deposit is 1,530 gas per byte of state gas instead of 200, and a full store chunk needs about 38.6M gas there (the measured minimum is 38,626,249). forge 1.7.1 has no Glamsterdam prices: its Cancun simulation times 130% signs a chunk with under 8M, so the commands above fail on the first chunk. The 16,777,216 cap of EIP-7825 limits execution gas only; state gas is paid from the gas limit above it, so such a transaction is valid.

On Sepolia, add two flags to both commands:

```sh
  --skip-simulation --gas-estimate-multiplier 120
```

With `--skip-simulation` forge takes each gas limit from the node's `eth_estimateGas` times the multiplier. The node's estimate is itself short: 38,532,308 for a full chunk, about 94,000 under the minimum, so the estimate alone would fail. A multiplier of 105 or more covers it; pass 120 explicitly rather than rely on forge's default. The script still runs its own checks before anything is sent.

- [ ] The script's 8M policy and every gas figure it prints are Cancun measurements. They do not describe a Glamsterdam chain: on Sepolia they pass and say nothing about what the chain charges.
- [ ] Record the Sepolia receipts as the post-fork figures: each chunk's gas used, and the three contracts (estimated on 11 October at about 18.6M for `KilimMotifs`, 24.9M for `KilimOneOfOne` and 18.1M for `KilimAuction`). The whole store is about 1.6G gas there. Fund the Sepolia wallets for that.
- [ ] Send the first chunk and read its receipt before leaving the rest to run.

## Pre-flight

`cast` is not part of the project's toolchain (only forge and anvil are). Where a line below uses it, the same JSON-RPC call works with curl, for example `curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","latest"]}' "$RPC"` must answer `"result":"0x"`, and `eth_getBlockByNumber` with `["latest",false]` shows the header fields.

`script/DeployKilim.s.sol` checks the items marked **(script)** itself and **refuses to send** if any fail. Confirm every item by hand as well.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same. Start from `deploy/mainnet.example.json`. The contracts phase prints every setting it deploys with and flags any that differs from the launch value; on chain 1 there must be no flag.
- [ ] **By hand, on deploy day: mainnet has not forked to Glamsterdam.** The latest block header has no `blockAccessListHash` and no `slotNumber` (`cast block latest --json --rpc-url "$RPC"`), and the fork schedule (EIP-7773) sets no mainnet activation before both phases are done. Mainnet has no Glamsterdam date on 11 October 2026. If it has forked, stop: the commands, the 8M policy and the gas figures here are Cancun's ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)).
- [ ] **(script)** `block.chainid` equals the config's `chainId`. **By hand:** 1 for Ethereum mainnet, 11155111 for the Sepolia rehearsal; and the chain has code at the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (`cast code`; mainnet and Sepolia do. forge's own simulation supplies that code even where the chain lacks it, so the script cannot tell).
- [ ] **(script)** The manifests: `motifCount` 1,024, the canonical CREATE2 deployer, every chunk file's size and keccak, every chunk's CREATE2 address, the chunk layout (full chunks before a section's last, grids cut at 24,544), the five section hashes recomputed from the files, and no foreign code at any chunk address. **By hand:** the manifests are the ones packed from the final artwork and still (`pnpm -s check:stores --config <the config>`), and their hashes and addresses are the published ones.
- [ ] **(script)** The content is the content the config names: the `expected` block (five section hashes, the two tokenURI goldens, the sha256 of the artist's page, the artwork, the still and the loader; `pnpm -s expected` prints it) equals the manifests, value by value, in both phases. On chain 1 a config without the block, or with a zero in it, is refused, and so is an artwork whose manifest says it never reads `KILIM_GRIDS`. **By hand:** the block is the published one, and two people compared it.
- [ ] **(script)** The config texts equal the manifests': the collection `description` and `externalUrl`, and the 1/1's `name`, `description` and `externalUrl` (the goldens were computed with them, except the collection's link, which the packer records for this comparison). The token JSON holds no `#` or `%`.
- [ ] **(script)** Store phase: each missing chunk's dry run stays under 8M gas and lands at the predicted address. A chunk already there is verified and skipped. The script prints who sends and how many chunks, and refuses when the sender is the config's deployer, a nonce is published for it and a chunk is still missing.
- [ ] **(script)** Contracts phase: every chunk is already on the chain (`store not deployed: runStore first`).
- [ ] **(script)** The deployer's nonce at the latest block equals the published `deployerNonce`, and so does its pending nonce (`eth_getTransactionCount(deployer, "pending")`, asked of the node the script runs against): a transaction from the wallet still waiting in the pool is refused. On chain 1 the check cannot be skipped. **By hand:** no other transaction from this key since publishing, and none waiting in another node's pool (look the wallet up in a block explorer right before sending).
- [ ] **(script)** The deployer is a plain account, without code: no EIP-7702 delegation and no contract wallet (`deployer has code (EIP-7702 delegation or contract wallet)`), in the contracts phase and in `runAuction()`. **By hand:** right before sending, `cast code 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac --rpc-url "$RPC"` prints `0x`.
- [ ] **(script)** `reservePrice` is `10000000000000000` wei (0.01 ETH), on every chain. The auction constructor accepts no other value.
- [ ] **(script)** On chain 1: `deployer` and `treasury` are `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth); `incrementBps` 1000 (+10%); `duration` 86400 (24 hours from the first bid); `extensionWindow` 600 (10 minutes, no limit on extensions); `motifCap` and `maxMotifsPerBid` 1,000,000; `oneOfOne.name` "The Unwoven Kilim". **By hand:** fresh proof that the key still works ([1-pre-deploy.md](1-pre-deploy.md)). Switching the treasury to a Safe would mean changing `LAUNCH_TREASURY` in the script, its tests and the signed-off config, then re-tagging.
- [ ] **(script)** `startsAt` is in Unix **seconds** (not milliseconds), at least `minLeadSeconds` (the inspection window) ahead, and at most a year out. On chain 1, `minLeadSeconds` must be nonzero. **By hand:** it is the window that was announced; the script accepts any nonzero value.
- [ ] **(script)** The dry run of the three contracts: the auction's address equals the prediction (nonce + 2), every immutable reads back as deployed, a motif's `tokenURI` and the 1/1's `tokenURI(1)` hash to the manifests' goldens, and each deployment and each read stays under 8M gas.
- [ ] **(script)** forge simulates the whole script before sending anything. **By hand:** the commands carry `--slow` and `--timeout`; each broadcast gas limit is forge's own Cancun simulation of that transaction times 130%, not the node's estimate (on Sepolia: the flags above); and the keys hold enough ETH (on a mainnet before Glamsterdam, the store about 246.0M gas in all with the page of 11 October and the WebP still, the three contracts about 13.1M).
- [ ] The git tag is checked out, and `pnpm -s artifacts` matches the frozen `audit/build-manifest.json`.

## Send

- [ ] **Store phase.** Broadcast the chunk transactions (45 with the artwork and still of 11 October). Record each hash. Compare the addresses the script prints with the published ones. The chunks can go up over several days, from any wallet but the deployer.
- [ ] **Contracts phase.** Broadcast the three creation transactions from orkhanart.eth, in order, at nonces n, n + 1, n + 2. They send no ETH: the auction holds nothing until the first bid.
- [ ] Record each transaction hash, block number and gas used.
- [ ] Confirm the three addresses match the published predictions.
- [ ] **If the third (the auction) was dropped** (never mined: the deployer is still at n + 2, latest and pending, on an explorer) and the first two are mined: nothing is void. The two token contracts name the address at nonce n + 2 as their minter, and the auction can still be deployed there. Find the cause, send nothing else from the wallet, then run the same command with `--sig 'runAuction()'`: it requires the deployer at n + 2, reads both token contracts back against the config, repeats every check and the golden comparison, and sends only the auction. The published addresses and the motif layout stand.
- [ ] **If the third was mined and reverted, or replaced by another transaction at n + 2:** nonce n + 2 is spent and the deployer is at n + 3. The address both token contracts name as their minter can never get code, so neither can ever mint: both are void. `runAuction()` refuses (`deployer nonce is not the published one plus two`). Mark the two addresses void as in [If anything is wrong](#if-anything-is-wrong), then restart from a new nonce (steps 1 to 3 below).
- [ ] **If the first was dropped** (never mined: the deployer's latest and pending nonce are still n on an explorer, and nothing from the wallet is queued): nothing is spent, and with `--slow` the other two were not sent. Find the cause, then run `runContracts()` again, without `--resume`. The published addresses and the motif layout stand.
- [ ] **If the first was mined and reverted or replaced, or the second was lost in any way:** the deployer has moved past n and the script refuses both commands. A dropped second leaves the 1/1's and the auction's addresses free, but the script has no command that sends only those two. Mark any token contract already at a published address void, then:
  1. find the cause;
  2. publish the new nonce, predicted addresses and motif layout (`motifOf` depends on the Motif Bazaar address);
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
