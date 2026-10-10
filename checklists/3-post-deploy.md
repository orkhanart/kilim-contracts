# 3. Post-deploy checklist

From a verified deployment through registration and the auction to the final withdrawals. Before: [1-pre-deploy.md](1-pre-deploy.md), [2-deploy.md](2-deploy.md).

Nothing on-chain can be changed from here. The levers left are the website, public communication, and where the treasury sends proceeds.

## Publish (before `startsAt`)

- [ ] Publish on the site and at least one other channel:
  - the auction, collection and renderer addresses;
  - the deployment transaction and block;
  - the verified-source links;
  - the content hashes with links to the published files;
  - the full trait layout;
  - the terms.
- [ ] Record the same in the repo, for example `deployments/<chain>.json`, and commit it with the release tag.
- [ ] Ask marketplaces to mark the official collection. Check that tokens and the collection page display correctly.

## Website goes live (before `startsAt`)

- [ ] Point the site at the deployed addresses and the ABIs in `abi/`. Rebuild with `site/build.py` and deploy.
- [ ] Pin and display the official addresses. Confirm the site only ever asks a wallet to send to the published auction and collection addresses.
- [ ] Smoke test in read-only mode against the live contracts:
  - the page shows 0 of 100 registered and offers no bid;
  - `endsAt` reads 0 and no countdown is shown;
  - the quote shows `minimumBid()` (0.01 ETH) and `rewardForBid()` (10 symbols);
  - registering is disabled until `startsAt`.
- [ ] Test the kill switch: disable the buttons, post a banner, then restore. It stops the site, not the auction.
- [ ] If sponsored registration is used: the sponsor service points at this auction and this chain, its wallet is funded within its limit, and one test registration goes through on Sepolia first.

## Monitoring on (before `startsAt`)

- [ ] Switch on alerts for:
  - **`address(auction).balance < liabilities()`**. The balance must always be at least `liabilities()`. An alert here is the most serious one: stop the site and investigate at once;
  - every **`RefundDeferred(bidder, amount)`**: the automatic refund to that bidder failed and the ETH waits in `refunds(bidder)`. Contact them; they call `withdrawRefund(to)`;
  - **`PrizeDeliveryFailed(winner)`**: settlement could not send the 1/1. The winner calls `claimPrize(to)`;
  - every `Registered(wallet, count)`, to follow the count toward 100;
  - `AuctionStarted(firstBidder, endsAt)` and every `BidPlaced`, with amount, reward and new `endsAt`;
  - `AuctionSettled`, `ProceedsWithdrawn`, `RefundWithdrawn`, `PrizeClaimed`;
  - the health of the RPC endpoints the site reads from.
- [ ] Confirm the people on call are reachable from `startsAt` until settlement. There is no fixed end, so plan for the auction running long.

## Inspection window

- [ ] Change nothing. Answer questions publicly. Point everyone to the published addresses, and warn about fake links or clones.

## Registration

Registration opens at `startsAt`. Bidding is closed until exactly 100 wallets have registered.

- [ ] At `startsAt`, confirm the first `register()` lands and the site shows the count.
- [ ] Keep telling supporters what registering is: free apart from gas, no deposit, the wallet only has to hold 0.01 ETH at that moment, and it gives no priority and no symbols.
- [ ] Watch how the slots fill. One actor can fill all 100 in a single transaction and place the opening bid in the same one. That is accepted (F-03); be ready for bidding to open the second `startsAt` passes.
- [ ] If the count stalls below 100: bidding stays closed and nothing on-chain can change that (F-10). Keep promoting. Any wallet except the treasury can register, and a wallet does not need to bid afterwards.
- [ ] At 100, confirm on-chain: `registrationCount == 100`, `endsAt == 0`, no bid yet. Announce that bidding is open and that the 24-hour clock starts with the first bid.

## Opening bid

- [ ] Confirm the first bid lands: `AuctionStarted`, `highestBid` at least 0.01 ETH, `endsAt` equal to that block's time plus 24 hours, and 10 symbol credits per 0.01 ETH for the bidder.
- [ ] Confirm the site shows the high bid, the reward count and the close from the chain.
- [ ] On the second bid, confirm the first bidder got their ETH back in the same transaction (`RefundPaid`) and still holds their credits (`symbolCredits`).

## During the auction

- [ ] Watch bids, extensions and alerts. No one can pause or restart the auction; follow the runbook if something goes wrong.
- [ ] After each bid, `address(auction).balance` should equal `liabilities()`. A higher balance means ETH was forced in, which is harmless and unrecoverable. A lower one must never happen.
- [ ] Remind bidders:
  - outbid ETH comes back automatically; only a refund that could not be sent waits for `withdrawRefund`;
  - symbols are **claimed**: the bidder calls `claimSymbols`, up to 64 per transaction, and pays the gas. Credits never expire, so claiming can wait for cheap gas;
  - any bid in the last 10 minutes extends the close, with no limit;
  - send bids with a generous gas limit; a bid with too little gas reverts with `InsufficientGas` and costs only gas.
- [ ] If the symbol pool runs out (`symbolsAllocated == symbolCap`), announce that bids still count for the 1/1 but earn no symbols.
- [ ] Do not present bid counts or symbol counts as numbers of collectors. One wallet can outbid itself and keep the symbols (F-04).

## Closing and settlement

- [ ] After `endsAt`, anyone calls `settle()`. The site's button or the team can do it. Send it with a generous gas limit (800,000 until measured): with too little it reverts with `InsufficientGas`, nothing is settled, and it can be sent again.
- [ ] Check what settlement did with the 1/1:
  - `PrizeClaimed(winner, winner)` and `collection.ownerOf(1) == winner`: delivered, nothing more to do;
  - `PrizeDeliveryFailed(winner)`: the winner's wallet rejected it. Help the winner call `claimPrize(to)` to an address that accepts it. Only the winner can.
- [ ] The treasury calls `withdrawProceeds(to)` to the pre-chosen address. Confirm the ETH arrives and `proceedsDue` reads 0.
- [ ] Give the winner access to the interactive generator as the terms promise. (With no bids the auction never ends, so there is nothing to settle.)
- [ ] Publish the result: winning bid, winner address, symbols allocated and claimed, and the settlement transaction.

## After the auction

- [ ] Claims stay open for good. Tell bidders how many symbols are still unclaimed (`symbolsAllocated − symbolsClaimed`) and how to claim. Nobody can claim for them.
- [ ] Contact every bidder with a deferred refund until `refundLiability` reads 0. Refunds do not expire.
- [ ] Keep the balance alert on until `liabilities()` is 0.
- [ ] Switch the site to its post-auction state, keeping the claim, refund, weave, expand and freeze pages working.
- [ ] If sponsored registration was used, stop the service and move what is left out of the sponsor wallet.
- [ ] Archive the evidence: final `audit/` outputs, the deployment record, the audit report, and the published content files.
