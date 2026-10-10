# Re-audit of the ETH-only contracts, 10 October 2026

Run after the token mode, USDC and automatic symbol delivery were removed. Three lenses (did the removal change behaviour; funds, re-entry and liveness; did the test port lose protection), each finding reproduced or refuted. Evidence: `eth-only-reaudit-2026-10-10.json`.

| ID | Severity | Finding | Check |
|---|---|---|---|
| R-01 | info | Only observable ETH-mode difference: every rewarded bid is about 22,000 to 44,000 gas cheaper | confirmed |
| R-02 | info | ABI entries that answered in ETH mode are gone; symbolsPending() was a working view | confirmed |
| R-03 | info | Unreachable clause left behind: the startsAt test in _handleBid | confirmed |
| R-04 | info | Generality left from the removed mode: one-value reservePrice, _claim's bidder argument, two comments | confirmed |
| R-05 | info | Deploy script reserve check tightened on non-mainnet chains (same outcome, earlier refusal) | confirmed |
| R-06 | medium | Anyone holding four symbols can make settle() skip sending the 1/1, by settling from inside a Kilim.weave callback | confirmed |
| R-07 | medium | The 60,000 gas kept back for a deferred refund is sized to today's gas prices; the Glamsterdam state-creation repricing (EIP-8037) would exceed it and reopen F-01 | partly |
| R-08 | low | The site sends bid and settle with no gas limit; with the floors a wallet's own estimate fails in the opening race and at the late-bid boundary | confirmed |
| R-09 | info | A wallet with code but no ERC-721 receiver hook cannot receive the 1/1 or symbols at its own address, and the site defaults the recipient to that address | partly |
| R-10 | info | The catch on both self-calls hides the reason for a failure, and neither failed step can be retried by a third party | confirmed |
| R-11 | low | F-05 still open: both gas caps can be raised, and the prize self-call uncapped, with every test passing | confirmed |
| R-12 | low | The gas allowances are not pinned from below: the prize floor, PRIZE_GAS and REFUND_GAS can all be cut and tests pass | partly |
| R-13 | low | withdrawProceeds: the recipient check has no test, so proceeds to address(0) would pass | confirmed |
| R-14 | low | nonReentrant on withdrawProceeds and claimPrize is untested | confirmed |
| R-15 | low | F-18 still open in forge: the EIP-712 name, version and type string are unpinned, and a digest that leaves out the wallet also passes | confirmed |
| R-16 | info | The two self-call entry points are tested against one fixed caller each | confirmed |
| R-17 | info | Registered, AuctionStarted and AuctionSettled are never asserted, and nothing says the first bid makes no refund | confirmed |
| R-18 | info | Constructor and deadline edges with no test: treasury == the auction, duration == 30 days, extension == duration, signature used at its deadline second | confirmed |
| R-19 | info | Eleven surviving mutants are equivalent: the checks they remove are redundant on disk | partly |
| R-20 | info | AUDIT.md's mutation paragraph and F-27 line no longer match what a full run shows | confirmed |
