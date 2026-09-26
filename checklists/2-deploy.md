# 2. Deploy checklist

The deployment itself: from final checks to a verified, read-back contract. Run it twice, first on testnet as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

## Pre-flight

The deployment script must check all of these itself and **refuse to send** if any fail. Also confirm them by hand.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same.
- [ ] Right network: `block.chainid` is 1 for Ethereum mainnet, or 11155111 for the Sepolia rehearsal.
- [ ] The deployer's pending nonce equals the published nonce. No other transaction from this key since publishing.
- [ ] The stablecoin address has code, and its `decimals()` matches. `reservePrice == 10 × 10^decimals`.
- [ ] `startsAt` is in Unix **seconds** (not milliseconds), at least the inspection window ahead, and not absurdly far out.
- [ ] The treasury matches the config. If it's a Safe: it has code on **this** chain, and its owners and threshold are as expected.
- [ ] `motifCount` equals the count in the published geometry file.
- [ ] `geometryHash` and `rendererHash`, recomputed from the published files, match the config.
- [ ] An `eth_call` simulation of the exact deployment transaction succeeds.
- [ ] The gas limit comes from Ethereum's own estimate plus margin, and every transaction stays under the 16,777,216 per-transaction cap. The deployer holds enough ETH.
- [ ] The git tag is checked out, and `pnpm artifacts` matches the frozen `audit/build-manifest.json`.

## Send

- [ ] Broadcast the one deployment transaction from the deployer key.
- [ ] Record the transaction hash, block number and gas used.
- [ ] Confirm the auction and collection addresses match the published predictions.
- [ ] **If the transaction reverted, was replaced or dropped:** the published nonce is spent, and the addresses and trait layout change with it. Before retrying:
  1. find the cause;
  2. publish the new nonce, predicted addresses and trait layout;
  3. restart the inspection window.

## Verify source

- [ ] Verify `KilimAuction` on Etherscan, with its constructor config.
- [ ] Verify `Kilim`. It was created inside the auction, so encode its constructor arguments by hand, in this order: `minter` = the **auction** address, `symbolCap`, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`.
- [ ] Confirm the verifier supports solc 0.8.37 with optimizer 200, cancun, no via-IR, ipfs metadata. Keep Sourcify as a fallback.
- [ ] Both contracts show as verified, and their source matches the tagged commit.

## Read back

Check every value on-chain against the config **before any bid**.

- [ ] **Auction:** `paymentToken`, `treasury`, `tokenUnit` (= 10^decimals), `reservePrice`, `incrementBps`, `startsAt`, `duration`, `extensionWindow`, `symbolCap`, `maxSymbolsPerBid`.
- [ ] **Clock not started:** `endsAt == 0`. It is set only by the first bid, to that bid's time plus `duration`.
- [ ] **Collection** (`collection()`): `minter == auction`, `symbolCap` equal to the auction's, `motifCount`, `maxCells`, `geometryHash`, `rendererHash`, `name()` "Kilim", `symbol()` "KILIM", `owner()` (the page-owner wallet), `royaltyReceiver()` (the treasury), `ROYALTY_BPS` = 500.
- [ ] **Starting state:**
  - `highestBid == 0`, `highestBidder == 0x0`;
  - `symbolsAllocated == 0`, `settled == false`, `prizeClaimed == false`;
  - `masterpieceMinted == false`, `symbolsMinted == 0`.
- [ ] Spot-check `symbolTraits(id)` for a few IDs against the published layout.

## If anything is wrong

A deployment cannot be abandoned. It opens at its own `startsAt`, takes real bids and mints tokens named "Kilim".

- [ ] Publicly mark its addresses void on the site, social channels, explorers and marketplaces, and make the site refuse them.
- [ ] Commit publicly that the treasury will return any winning bid on it with `withdrawProceeds(to = winner)`. Outbid bidders withdraw their own refunds.
- [ ] If the treasury address itself was the mistake, warn plainly that a winning bid there cannot be returned.
- [ ] Then fix the config, publish the new nonce, predicted addresses and layout, restart the inspection window, and run this checklist again.
