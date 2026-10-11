# 0. Launch steps, in order

One page for the artist: what to click or run, and what you should see. The detailed checks are in [1-pre-deploy.md](1-pre-deploy.md), [2-deploy.md](2-deploy.md) and [3-post-deploy.md](3-post-deploy.md); where a step says "see", the detail is there. Every command runs in `contracts/`. Written 11 October 2026.

Two wallets are involved. **orkhanart.eth** (`0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`) deploys the three contracts and receives the proceeds. A **store wallet** is a second account of yours (a new MetaMask account will do) that pays for the 45 storage transactions. Each transaction orkhanart.eth sends moves its **nonce** up by one, and the contract addresses are tied to that number. So orkhanart.eth sends nothing in these steps except the switch-back in step 1 and the contracts in steps 5 and 10. Receiving ETH does not move the nonce.

To read a wallet's nonce or code, paste this, with `eth_getTransactionCount` or `eth_getCode` as the method (for Sepolia, use `https://ethereum-sepolia-rpc.publicnode.com` as the address at the end):

```sh
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","latest"]}' https://ethereum-rpc.publicnode.com
```

A nonce comes back in hex: `0x61e` is 1,566, `0x61f` is 1,567 and `0x620` is 1,568.

## 1. Switch orkhanart.eth back to a standard account (mainnet)

**Done 11 October 2026.** Checked on two nodes: `eth_getCode` answers `0x`, the nonce is 1,568 (`0x620`, latest and pending), and `deploy/mainnet.json` carries `"deployerNonce": 1568`. A rehearsal on a fork of mainnet in this state deployed the three contracts at Motif Bazaar `0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF`, The Unwoven Kilim `0xeD82CE5F5E943ef80F3D32a907281936186742eC` and the auction `0xb4817D07a14503dCEf49Bd25B17557e7CBb23423`. **Send nothing from orkhanart.eth on mainnet until step 10**, and never accept a smart-account upgrade.

Today the wallet is a MetaMask smart account on mainnet: `eth_getCode` answers `0xef0100…63c0c19a…` and the deploy script refuses it.
- In MetaMask, on Ethereum mainnet, open the account's details, find **Smart account** and choose **Switch back** to a standard account. Menu names differ between MetaMask versions. Confirm the one transaction.
- **You should see:** `eth_getCode` now answers `"result":"0x"`, and the nonce reads the same for `"latest"` and `"pending"`. MetaMask sends the switch-back from the wallet itself as an EIP-7702 transaction, which uses **two** nonces (one for the transaction, one for the authorization inside it), so expect `0x620` (1,568); a relayed switch-back would leave `0x61f` (1,567). It also shows the key works today; checklist 2 asks again on deploy day.
- Write the number you read into `deploy/mainnet.json` as `"deployerNonce"`, a whole number with no quotes. Never assume it: the three contract addresses follow from it.
- From now on, reject any MetaMask offer to "upgrade" or "switch to a smart account", on any network. Accepting would add the code back and spend a nonce.

## 2. Decide the launch date

The date and time when registration opens. Bidding opens at the 100th registration, and the 24 hours start with the first bid. Convert it to Unix seconds and write it into `deploy/mainnet.json` as `"startsAt"`, with no quotes:

```sh
python3 -c 'import calendar,time; print(calendar.timegm(time.strptime("2026-11-20 18:00", "%Y-%m-%d %H:%M")))'   # 20 November 2026, 18:00 UTC
```

It must be at least 24 hours after the contracts land (`minLeadSeconds` is 86400, the inspection window) and less than a year after.

## 3. Fund the wallets

Gas used is the same on any day; the price per unit (the **base fee**) changes. ETH needed ≈ gas × base fee. On 11 October the mainnet base fee was about 0.19 gwei.

| Network | What | Gas | Cost at 0.19 gwei | Cost at 1 gwei | Fund |
| --- | --- | --- | --- | --- | --- |
| Sepolia | the store | about 1.6G (Glamsterdam prices) | free test ETH | | store wallet: 0.1–0.5 Sepolia ETH from a faucet |
| Sepolia | the contracts | about 62M | free test ETH | | orkhanart.eth: add 0.1 Sepolia ETH (it holds 0.0006) |
| Mainnet | the store | about 246M (the dress rehearsal's receipts: 225M) | about 0.047 ETH | about 0.25 ETH | store wallet: twice the day's figure |
| Mainnet | the contracts | about 13.1M | about 0.0025 ETH | about 0.013 ETH | orkhanart.eth holds 0.30 ETH, enough below about 10 gwei |

Send the store wallet's ETH **from an exchange or another wallet, never from orkhanart.eth**: that would move the nonce. Each transaction needs a margin above what it uses (forge sets its limit at 130%), but unused gas is not charged.

## 4. Choose how you sign

forge never sees the key. Choose for each wallet, since the store wallet and orkhanart.eth may sign differently, and put it in place of `<SIGN>` in that wallet's commands:
- **`--ledger`** if the account is on a Ledger. Open the Ethereum app, turn on blind signing, and close Ledger Live. If the account is not the Ledger's first, add `--mnemonic-indexes <n>`. You confirm each transaction on the device.
- **`--browser`** for a MetaMask account. forge opens a page at `localhost:9545`. Connect the right account there and confirm each transaction in MetaMask. Do not edit the gas, and reject any smart-account offer. This path has not been tried with this script yet. If MetaMask refuses a transaction, stop and ask.

## 5. Rehearse on Sepolia

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

In the auction the 1/1 exists only after settlement (100 registrations and a day of bidding), so the display test mints it straight away instead: `script/DisplayTest.s.sol` deploys the two token contracts over the Sepolia store with the same texts and bytes as the launch, with a small helper as their minter, and mints the 1/1 and nine motifs to the sending wallet. It refuses mainnet. Any Sepolia wallet can send it (use the store wallet, so orkhanart.eth's nonce is untouched):

```sh
KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DisplayTest.s.sol --sig 'display()' \
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
  --rpc-url "$RPC" --broadcast --slow --timeout 600 <SIGN> --sender <STORE WALLET>
```

- **You should see:** `chunks to send 45`, then 45 transactions, then the 45 chunk addresses, the same as on Sepolia. Rerun it if it stops. If the sender is orkhanart.eth the script refuses it, and that refusal is correct.

## 9. Publish the addresses

- Run the contracts command **without** `--broadcast` and without `<SIGN>`. It only simulates and prints the three addresses: `KILIM_DEPLOY_CONFIG=deploy/mainnet.json node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' --rpc-url "$RPC" --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`.
- At nonce 1,568 (the likely one) they are Motif Bazaar `0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF`, The Unwoven Kilim `0xeD82CE5F5E943ef80F3D32a907281936186742eC` and the auction `0xb4817D07a14503dCEf49Bd25B17557e7CBb23423`; at 1,567 they would be `0xA9D5d1dac003538D13cd28Ca3bDfF75914928AFA`, `0x33E45DED985DEfc51b15e4af3e69927D31f4e6EF` and `0xeD82CE5F5E943ef80F3D32a907281936186742eC`. Publish what the simulation prints.
- Publish on the site and at least one other channel: these three, the nonce, the 45 chunk addresses and the `expected` block from `deploy/mainnet.json`. The list is in [1-pre-deploy.md](1-pre-deploy.md), "Publish before deploy day".
- After publishing, send nothing from orkhanart.eth.

## 10. The mainnet contracts

Run the command from step 9 with `--broadcast --slow --timeout 600 <SIGN>` added. If `startsAt` is now less than 24 hours away, move it later first and announce the new date.
- **You should see:** the settings with no flag, three transactions, and the three published addresses.
- If anything goes wrong mid-way, do not improvise. [2-deploy.md](2-deploy.md), "Send", covers each case.

## 11. After deployment

- Verify the source and read back every value: [2-deploy.md](2-deploy.md), "Verify source" and "Read back".
- Publish, point the site at the deployment, test the off switch and turn on monitoring, all before `startsAt`: [3-post-deploy.md](3-post-deploy.md). The site command takes the auction's creation transaction from `broadcast/DeployKilim.s.sol/1/runContracts-latest.json`.
