# 2. Deploy checklist

The deployment itself: from final checks to a verified, read-back contract. Run it twice, first on Sepolia as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

## Pre-flight

`script/DeployKilim.s.sol` checks the items marked **(script)** itself and **refuses to send** if any fail (the full list is in [docs/RENDERER.md](../docs/RENDERER.md#what-the-script-refuses)). Confirm every item by hand as well.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same. Start from `deploy/mainnet.example.json`. The auction phase prints every setting it deploys with and flags any that differs from the launch value; on chain 1 there must be no flag.
- [ ] **(script)** `block.chainid` equals the config's `chainId`. **By hand:** that `chainId` is 1 for Ethereum mainnet, or 11155111 for the Sepolia rehearsal. On mainnet the script also refuses the one-shot `run()`: use `runStore`, publish `rendererHash`, then `runAuction`.
- [ ] **(script)** The deployer's pending nonce equals the published `deployerNonce`. On chain 1 the check cannot be skipped. No other transaction from this key since publishing.
- [ ] **(script)** `reservePrice` is `10000000000000000` wei (0.01 ETH), on every chain. The auction constructor accepts no other value.
- [ ] **(script)** On chain 1, the other launch settings: `incrementBps` 1000 (+10%), `duration` 86400 (24 hours from the first bid), `extensionWindow` 600 (10 minutes, no limit on extensions), `symbolCap` and `maxSymbolsPerBid` 1,000,000, `maxCells` 256.
- [ ] **(script)** `startsAt` is in Unix **seconds** (not milliseconds), at least `minLeadSeconds` (the inspection window) ahead, and at most a year out. On chain 1, `minLeadSeconds` must be nonzero. **By hand:** it is the window that was announced; the script accepts any nonzero value.
- [ ] **(script)** The treasury and the collection owner are nonzero. On chain 1 both must be `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth). By hand: fresh proof that the key still works ([1-pre-deploy.md](1-pre-deploy.md)). Switching to a Safe would mean changing `LAUNCH_TREASURY` in the script, its tests and the signed-off config, then re-tagging.
- [ ] **(script)** `motifCount` equals the count in the published geometry file (`onchain/build/manifest.json`). **By hand:** it is the final set; the script does not pin the number.
- [ ] **(script)** `geometryHash` and `rendererHash`, recomputed from the published files, match the config. The script also checks the chunk files, the CREATE2 addresses and the renderer's golden answers, and refuses on any mismatch. The data chunks and the renderer are deployed first, in a separate phase, and are already on-chain here.
- [ ] **(script)** forge simulates the whole deployment before sending anything, and dry-runs each transaction to measure its gas: every one stays under the script's 8M policy, well under the 16,777,216 per-transaction cap. By hand: the broadcast gas limit comes from Ethereum's own estimate plus margin, and the deployer holds enough ETH.
- [ ] The git tag is checked out, and `pnpm artifacts` matches the frozen `audit/build-manifest.json`.

## Send

- [ ] Broadcast the one auction deployment transaction from the deployer key. It sends no ETH: the auction holds nothing until the first bid.
- [ ] Record the transaction hash, block number and gas used.
- [ ] Confirm the auction and collection addresses match the published predictions.
- [ ] **If the transaction reverted, was replaced or dropped:** the published nonce is spent, and the addresses and trait layout change with it. Before retrying:
  1. find the cause;
  2. publish the new nonce, predicted addresses and trait layout;
  3. restart the inspection window.

## Verify source

- [ ] Verify `KilimAuction` on Etherscan, with its constructor config: one struct of 14 fields, in this order: `treasury`, `collectionOwner`, `startsAt`, `duration`, `extensionWindow`, `incrementBps`, `reservePrice`, `symbolCap`, `maxSymbolsPerBid`, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`, `renderer`.
- [ ] Verify `Kilim`. It was created inside the auction, so encode its constructor arguments by hand, in this order: `minter` = the **auction** address, `owner`, `royaltyReceiver`, `symbolCap`, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`, `renderer`.
- [ ] Verify `KilimRenderer` (constructor: the chunk addresses in order, `geometryHash`, `indexHash`, `pageHash`). The data chunks and `TABLES` are code-only and need no verification; publish their addresses.
- [ ] Confirm the verifier supports solc 0.8.37 with optimizer 200, cancun, no via-IR, ipfs metadata. Keep Sourcify as a fallback.
- [ ] All three contracts show as verified, and their source matches the tagged commit.

## Read back

Check every value on-chain against the config **before `startsAt`**. The script only read back its own simulation before sending; this checks the chain itself. On chain 1 every value must also equal the launch value in the pre-flight list above.

- [ ] **Auction settings:** `treasury`, `reservePrice` (10000000000000000), `incrementBps`, `startsAt`, `duration`, `extensionWindow`, `symbolCap`, `maxSymbolsPerBid`.
- [ ] **Auction constants:** `SYMBOL_PRICE` = 1000000000000000 (0.001 ETH), `REGISTRATION_BALANCE` = 10000000000000000 (0.01 ETH), `REGISTRATION_TARGET` = 100.
- [ ] **Registration domain:** `eip712Domain()` returns name `Kilim Registration`, version `1`, this chain ID and this auction's address. A sponsor or site that signs for any other domain will fail.
- [ ] **Nothing has happened yet:**
  - `registrationCount == 0`;
  - `endsAt == 0`: it is set only by the first bid, to that bid's time plus `duration`;
  - `highestBid == 0`, `highestBidder == 0x0`;
  - `symbolsAllocated == 0`, `symbolsClaimed == 0`, `settled == false`, `prizeClaimed == false`;
  - `refundLiability == 0`, `proceedsDue == 0`, `liabilities() == 0`;
  - the auction's ETH balance is 0.
- [ ] **Closed doors:** `minimumBid()` returns 10000000000000000. Simulate (do not send) a `bid` of that amount with that value: it must revert with `RegistrationIncomplete`. Simulate `register()`: before `startsAt` it must revert with `RegistrationClosed`. Simulate a plain ETH transfer to the auction: it must revert.
- [ ] **Collection** (`collection()`): `minter == auction`, `symbolCap` equal to the auction's, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`, `renderer()` (the published renderer), `name()` "Kilim", `symbol()` "KILIM", `owner()` (the page-owner wallet), `royaltyReceiver()` (the treasury), `ROYALTY_BPS` = 500, `masterpieceMinted == false`, `symbolsMinted == 0`.
- [ ] **Renderer**: `motifCount()`, `geometryHash()`, `indexHash()`, `pageHash()` and `chunks()` match the published values; `masterpieceURI()` (with an explicit gas value, e.g. 50M) matches `onchain/build/golden.json`.
- [ ] Spot-check `symbolTraits(id)` for a few IDs against the published layout.

## If anything is wrong

A deployment cannot be abandoned. It opens registration at its own `startsAt`, takes real bids once 100 wallets register, and mints tokens named "Kilim".

- [ ] Publicly mark its addresses void on the site, social channels, explorers and marketplaces, and make the site refuse them.
- [ ] Commit publicly that the treasury will return any winning bid on it with `withdrawProceeds(to = winner)`. Outbid bidders are refunded by the contract as usual.
- [ ] If the treasury address itself was the mistake, warn plainly that a winning bid there cannot be returned.
- [ ] Then fix the config, publish the new nonce, predicted addresses and layout, restart the inspection window, and run this checklist again.
