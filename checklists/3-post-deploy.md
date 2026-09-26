# 3. Post-deploy checklist

From a verified deployment through the auction to the final withdrawals. Before: [1-pre-deploy.md](1-pre-deploy.md), [2-deploy.md](2-deploy.md).

Nothing on-chain can be changed from here. The levers left are the website, public communication, and where the treasury sends proceeds.

## Publish (before `startsAt`)

- [ ] Publish on the site and at least one other channel:
  - the auction, collection and stablecoin addresses;
  - the deployment transaction and block;
  - the verified-source links;
  - the content hashes with links to the published files;
  - the full trait layout;
  - the terms.
- [ ] Record the same in the repo, for example `deployments/<chain>.json`, and commit it with the release tag.
- [ ] Ask marketplaces to mark the official collection. Check that tokens and the collection page display correctly.

## Website goes live (before `startsAt`)

- [ ] Point the site at the deployed addresses and the ABIs in `abi/`. Rebuild with `site/build.py` and deploy.
- [ ] Pin and display the official addresses. Confirm the site only ever requests approval for the published auction address.
- [ ] Smoke test in read-only mode against the live contracts:
  - before the first bid the page shows bidding open with no countdown, and `endsAt` reads 0;
  - the bid quote shows `minimumBid()` and `rewardForBid()`;
  - the trait preview matches `symbolTraits`;
  - bidding is disabled until `startsAt`.
- [ ] Test the kill switch: disable the bid button, post a banner, then restore.
- [ ] Check that `ethUsdRange` in `site/chains/1.json` still brackets the ETH price with room on both sides (README, "The ETH/USD sanity band"). Outside it the site turns pay-with-ETH off; move it, rebuild, republish.

## Monitoring on (before `startsAt`)

- [ ] Switch on alerts for:
  - `paymentToken.balanceOf(auction) < liabilities()`;
  - USDC's `paused()` and `isBlacklisted(auction)`;
  - `Upgraded` on the stablecoin proxy;
  - the chain's sequencer status;
  - every `BidPlaced`, with amount, reward and new `endsAt`.
- [ ] Confirm the on-call team and the Safe signers are reachable for the whole auction.

## Inspection window

- [ ] Change nothing. Answer questions publicly. Point everyone to the published addresses, and warn about fake links or clones.

## Opening

- [ ] At `startsAt`, confirm the first bid lands, and that the site shows the new high bid, reward, reserved IDs and deadline correctly.
- [ ] Check that claims work: a bidder can claim symbols straight away, before the auction ends.

## During the auction

- [ ] Watch bids, extensions and alerts. No one can pause or restart the auction; follow the runbook if something goes wrong.
- [ ] Remind bidders:
  - outbid funds must be **withdrawn** with `withdrawRefund`;
  - symbols are **claimed** separately and never expire;
  - any bid in the last 10 minutes extends the close, with no limit.
- [ ] If the symbol pool runs out, announce that bids still count for the 1/1 but earn no symbols. Confirm the site now sends `expectedFirstSymbolId = 0`.

## Closing and settlement

- [ ] After `endsAt`, anyone calls `settle()`. The site's button or the team can do it.
- [ ] The treasury calls `withdrawProceeds(to)` to the pre-chosen address. Confirm the funds arrive.
- [ ] The winner calls `claimPrize(to)`. Give the winner access to the interactive generator as the terms promise. (With no bids the auction never ends, so there is nothing to settle.)
- [ ] Publish the result: winning bid, winner address, symbols minted, and the settlement transaction.

## After the auction

- [ ] Keep reminding outbid bidders to withdraw refunds and claim symbols. Neither expires.
- [ ] Keep the stablecoin alerts on until `liabilities()` is 0 and every refund is withdrawn.
- [ ] Switch the site to its post-auction state, keeping the claim, refund, weave, expand and freeze pages working.
- [ ] Archive the evidence: final `audit/` outputs, the deployment record, the audit report, and the published content files.
