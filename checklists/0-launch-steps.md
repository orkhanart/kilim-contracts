# 0. Launch steps, in order

One page for the artist: what to click or run, and what you should see. The detailed checks are in [1-pre-deploy.md](1-pre-deploy.md), [2-deploy.md](2-deploy.md) and [3-post-deploy.md](3-post-deploy.md); where a step says "see", the detail is there. Every command runs in `contracts/`. Written 11 October 2026.

Two wallets are involved. **orkhanart.eth** (`0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`) deploys the three contracts and Kilim Bazaar and receives the proceeds. The **store wallet** (`0xdA67F4A8EBF6c6eF1a403d6dE7141E700F436e00`, made on 12 October with `node scripts/new-store-wallet.mjs`; its encrypted key is `~/.kilim-store/store-keystore.json`) pays for the 45 storage transactions. Each transaction orkhanart.eth sends moves its **nonce** up by one, and the contract addresses are tied to that number. So from the **wallet-freeze day** (step 1) orkhanart.eth sends nothing on mainnet but the three contracts (step 10) and then Kilim Bazaar (step 11). Before that day it may send anything, the store wallet's ETH included: the nonce is read again on the freeze day. Receiving ETH never moves the nonce.

To read a wallet's nonce or code, paste this, with `eth_getTransactionCount` or `eth_getCode` as the method (for Sepolia, use `https://ethereum-sepolia-rpc.publicnode.com` as the address at the end):

```sh
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","latest"]}' https://ethereum-rpc.publicnode.com
```

A nonce comes back in hex: `0x61e` is 1,566, `0x61f` is 1,567 and `0x620` is 1,568.

## 1. Switch orkhanart.eth back to a standard account (mainnet)

**Done 11 October 2026.** Checked on two nodes: `eth_getCode` answers `0x`, the nonce is 1,568 (`0x620`, latest and pending), and `deploy/mainnet.json` carries `"deployerNonce": 1568`. A rehearsal on a fork of mainnet in this state deployed the three contracts at Motif Bazaar `0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF`, The Unwoven Kilim `0xeD82CE5F5E943ef80F3D32a907281936186742eC` and the auction `0xb4817D07a14503dCEf49Bd25B17557e7CBb23423`. **From the wallet-freeze day (below), send nothing from orkhanart.eth on mainnet until step 10**, and never accept a smart-account upgrade.

**The nonce has moved since (12 October).** orkhanart.eth sent a WETH unwrap at 15:28 UTC, so its mainnet nonce became 1,569, and at 23:51 UTC two nodes read 1,570 (`0x622`, latest and pending; `eth_getCode` still `0x`). The 1,568 addresses above are no longer the ones it will deploy at. `deploy/mainnet.json` still says 1568 on purpose: on the **wallet-freeze day** (the day from which orkhanart.eth sends nothing until step 10), read the nonce again on two nodes, write it into `"deployerNonce"`, and publish the addresses for that number (step 9). Every transaction from the wallet before that day is fine; any after it voids the published addresses.

The EIP-7702 delegation is gone: the final dress rehearsal (12 October, [audit/rehearsal-2026-10-12-final.txt](../audit/rehearsal-2026-10-12-final.txt)) read `eth_getCode` `0x` on three nodes and the nonce 1,570 (`0x622`), latest and pending. Nothing more to do here until the freeze day.
- On the wallet-freeze day, write the nonce you read on two nodes into `deploy/mainnet.json` as `"deployerNonce"`, a whole number with no quotes. Never assume it: the three contract addresses follow from it.
- If `eth_getCode` ever answers `0xef0100…` again (a smart-account upgrade accepted by mistake), the deploy script refuses (`deployer has code`). Switch back in MetaMask (the account's details, **Smart account**, **Switch back**; the switch-back spends two nonces), then read the nonce again.
- Reject any MetaMask offer to "upgrade" or "switch to a smart account", on any network. Accepting would add the code back and spend a nonce.

## 2. Decide the launch day

Registration opens about 20 minutes after the contracts are sent, so the launch moment is the deployment (step 10): choose the day and the hour you will send it, and announce that. Bidding opens at the 100th registration, and the 24 hours start with the first bid.

There is no 24-hour inspection window any more (the artist, 12 October 2026): `minLeadSeconds` is 600, ten minutes. Before 100 registrations nobody can bid, so no ETH is at risk, and the registration phase is the inspection window. The script still refuses 0 on mainnet, and the auction contract needs `startsAt` in the future.

`"startsAt"` in `deploy/mainnet.json` stays `0` until step 10. The store command (step 8) reads the number but never checks it; the contracts command refuses 0 (`startsAt outside the inspection window`), so it cannot be forgotten. Step 10 says what to write.

## 3. Fund the wallets

Gas used is the same on any day; the price per unit (the **base fee**) changes. ETH needed ≈ gas × base fee. On 12 October the mainnet base fee was about 0.18 gwei. The mainnet gas below is what the final dress rehearsal's receipts used on a fork of mainnet (12 October, [audit/rehearsal-2026-10-12-final.txt](../audit/rehearsal-2026-10-12-final.txt), section 15).

| Network | What | Gas | Cost at 0.2 gwei | Cost at 1 gwei | Fund |
| --- | --- | --- | --- | --- | --- |
| Sepolia | the store | about 1.6G (Glamsterdam prices) | free test ETH | | store wallet: 0.1–0.5 Sepolia ETH from a faucet |
| Sepolia | the contracts | about 62M | free test ETH | | orkhanart.eth: add 0.1 Sepolia ETH (it holds 0.0006) |
| Mainnet | the store (45 chunks) | 225.0M | about 0.045 ETH | about 0.23 ETH | store wallet: about 0.07 ETH, enough up to about 0.3 gwei; send more if the day's base fee is higher |
| Mainnet | the three contracts | 11.5M | about 0.0023 ETH | about 0.012 ETH | orkhanart.eth |
| Mainnet | Kilim Bazaar | 5.7M | about 0.0011 ETH | about 0.0057 ETH | orkhanart.eth |
| Mainnet | the sealer | its budget, not gas | 0.1 ETH | 0.1 ETH | the sealer's own wallet (step 12) |

- **The store wallet's ETH may come from orkhanart.eth, before the wallet-freeze day only.** That send moves orkhanart.eth's nonce, which is read again on the freeze day, so it is harmless before that day and voids the published addresses after it. An exchange or another wallet is fine at any time. After the store is up, send what is left back to orkhanart.eth (step 8).
- **orkhanart.eth holds 0.143 ETH** (0.142993 on 12 October). At today's base fee that covers the store wallet's 0.07, the three contracts and Kilim Bazaar, with about 0.07 ETH left, or about 0.095 once the store wallet's leftover comes back. **It does not also cover the sealer's 0.1 ETH:** fund the sealer from an exchange or another wallet, or top up orkhanart.eth first. At 1 gwei the contracts and the Bazaar alone take about 0.017 ETH, and the store about 0.23.
- A wallet must hold more than it spends while it sends: each transaction's gas limit times its max fee (forge sets the limit at 130% of its simulation; the largest are 7.87M for a chunk, 7.61M for KilimOneOfOne and 7.37M for the Bazaar). Unused gas is not charged.

## 4. Choose how you sign

forge never sees the key. Choose for each wallet, since the store wallet and orkhanart.eth may sign differently, and put it in place of `<SIGN>` in that wallet's commands:
- **`--ledger`** if the account is on a Ledger. Open the Ethereum app, turn on blind signing, and close Ledger Live. If the account is not the Ledger's first, add `--mnemonic-indexes <n>`. You confirm each transaction on the device.
- **`--browser`** for a MetaMask account. forge opens a page at `localhost:9545`. Connect the right account there and confirm each transaction in MetaMask. Do not edit the gas, and reject any smart-account offer. If MetaMask refuses a transaction, stop and ask. Tried on Sepolia on 11 October ([audit/sepolia-2026-10-11.txt](../audit/sepolia-2026-10-11.txt)):
  - Open exactly `http://127.0.0.1:9545` in Chrome, where MetaMask is installed; `localhost` or another port fails.
  - Pick MetaMask in the page's wallet list, and set MetaMask's network before Connect.
  - Connect within 5 minutes of starting the command.
  - If the next transaction does not appear, reload the page or open MetaMask from the toolbar.
  - Never press Cancel on a deploy transaction. Cancel is a replacement at the same nonce, and it voids the published addresses.
- **`--keystore ~/.kilim-store/store-keystore.json`** for the store wallet (`0xdA67F4A8EBF6c6eF1a403d6dE7141E700F436e00`): 45 confirmations by hand are too many, so forge reads the encrypted key and asks for its password once. `scripts/new-store-wallet.mjs` wrote the file with the lowercase `crypto` field forge needs. Fund the wallet with only what the store needs (step 3).

## 5. Rehearse on Sepolia

**Done on 11 October 2026** ([audit/sepolia-2026-10-11.txt](../audit/sepolia-2026-10-11.txt)): orkhanart.eth deployed at its Sepolia nonce 11 (not 2: 8 chunks and the store wallet's funding went from it first), so the addresses are Motif Bazaar `0x48b3D1E55920BE80B952cff3568a142623e85c1e`, The Unwoven Kilim `0xCeEA7EBD8eE3Cc0a39ED89B999b4dB5c0CAC30F9`, the auction `0xf8301C81906512090f663bA474B59Cc186BD2e66`; registration opened at 19:06 UTC. The read back passed (83 items) and so did the display test (step 6). Keep the steps below for mainnet's order; the nonce-2 addresses in them no longer apply.

`deploy/sepolia.json` is ready, with orkhanart.eth as deployer at its Sepolia nonce 2 (11 October) and a 10-minute inspection window. Sepolia already runs the next Ethereum upgrade (Glamsterdam), so its commands carry two extra flags that mainnet's do not.

```sh
export RPC=https://ethereum-sepolia-rpc.publicnode.com
KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --skip-simulation --gas-estimate-multiplier 120 <SIGN> --sender <STORE WALLET>
```

- **You should see:** `chunks to send 45`, then the transactions one by one. Open the first on sepolia.etherscan.io and check it succeeded before leaving the rest to run. At the end, 45 chunk addresses are printed. If it stops halfway, run the same command again: it sends only what is missing.
- Then check that orkhanart.eth's Sepolia nonce still reads `0x2`. Set `"startsAt"` in `deploy/sepolia.json` to one hour from now: `python3 -c 'import time; print(int(time.time()) + 3600)'`. The placeholder 0 is refused on purpose.

```sh
KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --skip-simulation --gas-estimate-multiplier 120 <SIGN> --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac
```

- **You should see:** the settings list, three transactions, then the addresses: Motif Bazaar `0xE763AECa9D90C6Cfd8653dDEc753fD184174DB12`, The Unwoven Kilim `0x7e480AE4cF7953B389DD9f8b017645cA36A08576`, the auction `0x6B30a9B0f59E4f51752045FDc69915361A1cd346` (these hold only at nonce 2). A `Refused(…)` line means nothing was sent: read the reason, fix it, run again.
- Record the gas each transaction used. Then run the Sepolia part of [2-deploy.md](2-deploy.md) (read back) and the Testnet rehearsal of [1-pre-deploy.md](1-pre-deploy.md).

## 6. Check the 1/1 on testnets.opensea.io

**OpenSea closed its testnet site on 23 July 2025**, so the look on OpenSea below cannot be done on Sepolia. The display test itself ran on 11 October ([audit/sepolia-2026-10-11.txt](../audit/sepolia-2026-10-11.txt)): both tokenURIs equal the goldens on two RPCs and Alchemy's Sepolia API reads both tokens intact, but no testnet marketplace shows the still and the page. That look now needs another route before mainnet (the marketplace's written confirmation in step 7, or a display on a chain OpenSea serves).

In the auction the 1/1 exists only after settlement (100 registrations and a day of bidding), so the display test mints it straight away instead: `script/DisplayTest.s.sol` deploys the two token contracts over the Sepolia store with the same texts and bytes as the launch, with a small helper as their minter, and mints the 1/1 and nine motifs to the sending wallet. It refuses mainnet. Any Sepolia wallet can send it (use the store wallet, so orkhanart.eth's nonce is untouched):

```sh
KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DisplayTest.s.sol --tc DisplayTest --sig 'display()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --skip-simulation --gas-estimate-multiplier 120 <SIGN> --sender <STORE WALLET>
```

It prints the two addresses and checks both tokenURIs against the packed goldens. Then follow the display test in [1-pre-deploy.md](1-pre-deploy.md) (Testnet rehearsal, "The 1/1 as it will be on mainnet") with those addresses.
- **You should see:** the still as the image and the page playing on testnets.opensea.io, and the same `tokenURI(1)` from two RPCs.

## 7. Before mainnet: go / no-go

The mainnet run waits for the go/no-go of [1-pre-deploy.md](1-pre-deploy.md): above all the independent audit and the marketplace's written confirmation. Two people compare `deploy/mainnet.json` with the signed-off values ([2-deploy.md](2-deploy.md), pre-flight). On the day, check that mainnet has not upgraded to Glamsterdam: the reply below must have neither `blockAccessListHash` nor `slotNumber`. If it has either, stop: the mainnet commands no longer fit.

```sh
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' https://ethereum-rpc.publicnode.com
```

## 8. Put the store on mainnet

```sh
export RPC=https://ethereum-rpc.publicnode.com
KILIM_DEPLOY_CONFIG=deploy/mainnet.json node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 \
  --keystore ~/.kilim-store/store-keystore.json --sender 0xdA67F4A8EBF6c6eF1a403d6dE7141E700F436e00
```

- **You should see:** `chunks to send 45`, then 45 transactions, then the 45 chunk addresses, the same as on Sepolia. Rerun it if it stops. If the sender is orkhanart.eth the script refuses it, and that refusal is correct.
- **Then send the store wallet's leftover back to orkhanart.eth**, at any time (MetaMask can open the key: Add account, Import account, JSON file, with the same password). It is an incoming transfer for orkhanart.eth, so it does not move its nonce.

## 9. Publish the addresses

- Set `"deployerNonce"` to the nonce read on the wallet-freeze day (step 1).
- Run the contracts command **without** `--broadcast` and without `<SIGN>`. It only simulates and prints the three addresses. It refuses the placeholder `startsAt` 0, so for this simulation set `"startsAt"` to `python3 -c 'import time; print(int(time.time()) + 1200)'` (step 10 sets it again): `KILIM_DEPLOY_CONFIG=deploy/mainnet.json node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' --rpc-url "$RPC" --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`.
- The addresses follow from the nonce n: Motif Bazaar at n, The Unwoven Kilim at n + 1, the auction at n + 2. At 1,568 they were `0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF`, `0xeD82CE5F5E943ef80F3D32a907281936186742eC` and `0xb4817D07a14503dCEf49Bd25B17557e7CBb23423`; at 1,570 (the nonce on 12 October at 23:51 UTC) they would be `0xb4817D07a14503dCEf49Bd25B17557e7CBb23423`, `0xf2bf089aa3b9E7D8664147e2Db42e84499717c7e` and `0x89c531b660DA287BB16f971023cCDddf302D80A2`. Publish what the simulation prints.
- Publish on the site and at least one other channel: these three, the nonce, the 45 chunk addresses and the `expected` block from `deploy/mainnet.json` (its `texts` value with the eight texts it covers, which `pnpm -s expected --config deploy/mainnet.json` prints). The list is in [1-pre-deploy.md](1-pre-deploy.md), "Publish before deploy day".
- After publishing, send nothing from orkhanart.eth.

## 10. The mainnet contracts

Right before it:
- Repeat the header check of step 7. If mainnet forked to Glamsterdam after the store went up, KilimMotifs runs out of gas storing its code, and the published addresses are void.
- Run from a clean checkout of the frozen tag, not a working tree other sessions share. The script compiles what `src/` holds.
- Bring the stores into that checkout. `onchain/build-motifs/` and `onchain/build-page/` are git-ignored, so a clean checkout has neither, and the script stops at the first manifest read. Copy both folders from the working tree whose `pnpm -s check:stores --config deploy/mainnet.json` passed, for example from the checkout's root: `cp -R <working tree>/onchain/build-motifs <working tree>/onchain/build-page onchain/`. Then, in `contracts/`, run `pnpm install`, `pnpm -s check:stores --config deploy/mainnet.json` and `pnpm -s expected --config deploy/mainnet.json`, which must print the published block. Do not re-pack the stores there unless `python3 -c 'import zlib; print(zlib.ZLIB_VERSION)'` prints `1.2.12`, the zlib recorded in `build-page/manifest.json` (`blob.zlibVersion`). Another zlib compresses the artwork differently, TAIL changes, and the script refuses (`expected tailHash`). Nothing is sent, but copy the stores instead.
- Set `"deployerNonce"` to the published nonce (step 9) if the checkout does not carry it, and check the wallet is still at it.
- Set `"startsAt"`, last, to `python3 -c 'import time; print(int(time.time()) + 1200)'`, twenty minutes from now. The script needs it at least 600 seconds (`minLeadSeconds`) after the latest block when it simulates. The other ten minutes cover the compile, your three confirmations and their inclusion. The auction's creation (the third) must be mined before `startsAt`: if it is mined later, its constructor reverts and both token contracts are void ([2-deploy.md](2-deploy.md), "Send"). Confirm each transaction as soon as it appears. Use the wallet's normal or fast fee, and Speed up anything pending. If more than five minutes pass before you send, set it again. Use a later time if the network is busy.

Then run the command from step 9 with `--broadcast --slow --timeout 600 <SIGN>` added.
- **You should see:** the settings with no flag, three transactions, and the three published addresses.
- If anything goes wrong mid-way, do not improvise. [2-deploy.md](2-deploy.md), "Send", covers each case.

## 11. After deployment

- Verify the source and read back every value: [2-deploy.md](2-deploy.md), "Verify source" and "Read back".
- Publish, point the site at the deployment, test the off switch and turn on monitoring: [3-post-deploy.md](3-post-deploy.md). The site command takes the auction's creation transaction from `broadcast/DeployKilim.s.sol/1/runContracts-latest.json`. With `startsAt` twenty minutes after the deployment, most of this happens while registration is open. Before 100 registrations nobody can bid. But one actor can register 100 wallets in one transaction the moment `startsAt` passes and bid in the same transaction (F-03), so the only window that is certain is the one before `startsAt`. Do the read back of [2-deploy.md](2-deploy.md) first, inside it.
- **Kilim Bazaar goes up only once its pages and its image service are live**: `https://orkhan.art/kilim/bazaar/`, `https://orkhan.art/kilim/bazaar/<id>` and `https://orkhan.art/kilim/bazaar/image/<id>`. The contract appends each kilim's id to those two bases for ever, and every marketplace takes each kilim's picture from the image base. On 12 October all three answered 404. **The Bazaar can wait until they are live: any time before the auction settles is as good as now** (making opens at settlement; if it goes up after settlement it is open from its own block, step 12). Before kilim 1 exists, `/kilim/bazaar/1` and `/kilim/bazaar/image/1` cannot show it yet, but they must be served by the live pages, not 404.
- Then: `KILIM_DEPLOY_CONFIG=deploy/mainnet.json node scripts/forge.mjs script script/DeployKilimBazaar.s.sol --rpc-url "$RPC" --broadcast --slow --timeout 600 <SIGN> --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`. No address is typed in: on mainnet the script takes the motif collection, the 1/1 and the auction from `deployer` and `deployerNonce` (n, n + 1, n + 2), the only contracts orkhanart.eth can have created there, and refuses any other (audit TK-1). So `deployerNonce` stays the number the contracts were deployed at; do not move it to the wallet's later nonce. A wrong one is refused by name: `mainnet: no contracts at deployerNonce …` or `mainnet: deployerNonce … is not the nonce the three contracts were deployed at …`. It refuses a text that differs from `expected.texts`. Open the two kilim-1 URLs it prints before you confirm, then read it back ([2-deploy.md](2-deploy.md), "Kilim Bazaar: read back").

## 12. Kilim Bazaar: the sealer runs before anyone can make a kilim

The sealer seals every kilim from its own wallet, in the first block it can (see [kilim-sealer/README.md](../../kilim-sealer/README.md)). Without it, an owner who dislikes a kilim's look can leave it unsealed for about 27 hours and draw again, as often as they like (audit SL-1). It runs from the moment kilims can be made, for as long as they can be made.

1. **Before the Bazaar goes up:**
   - Make a new wallet for the sealer only. A new MetaMask account will do. Never use orkhanart.eth, the treasury or the store wallet.
   - Send it 0.1 ETH, from an exchange or another wallet. orkhanart.eth may send it once its three contracts are out, but it will not hold enough for this as well unless it is topped up first (step 3).
   - Choose the host: one container with a persistent volume, as in the README's Hosting.
2. **The order.** Best: deploy the Bazaar while the auction is still running (making opens at settlement), start the sealer at once, then let the auction settle. If the Bazaar goes up after settlement, it is open from its own block. Then start the sealer within the hour, and before the site links to the Bazaar.
3. **Start it** with these values:
   - `KILIM_CHAIN_ID=1` (the default, but set it);
   - `KILIM_BAZAAR`: the address the script printed;
   - `KILIM_START_BLOCK`: its creation block;
   - `KILIM_RUNTIME_HASH`: read on two nodes, as in [2-deploy.md](2-deploy.md), "Kilim Bazaar's sealer";
   - `KILIM_SEALER_KEY`: in the host's secret store;
   - `KILIM_BUDGET_ETH=0.1`.
4. **You should see:** a first line `Sealer 0x… watching Kilim Bazaar 0x… on chain 1 … window 8191 …`, and `/health` answering 200. After the first kilim you should see `NEW kilim 1 …`, then `SEND …`, then `MINED … sealed [1]`, two blocks after the kilim was made.
5. **Watch it:**
   - Have the `ALERT` lines reach your phone or email, and point an uptime check at `/health`.
   - At "Sealer budget low", compare the journal with the wallet on Etherscan. Then raise `KILIM_BUDGET_ETH`, top up the wallet and restart.
   - The audit also advises a second sealer on another host, with `KILIM_DELAY_BLOCKS=100`.
6. **Never stop it** while kilims can be made. A restart is fine: it scans again from the start block. A day without it is not.
