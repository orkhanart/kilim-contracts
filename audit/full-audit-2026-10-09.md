# Full audit, 9 October 2026 (working tree, native-ETH design)

Eight lenses, 27 merged findings, each checked by a refuter and (above info) a Foundry reproduction. Full evidence, PoC sources and fixes: `full-audit-2026-10-09.json`.

| ID | Severity | Finding | Refuter | Reproduction |
|---|---|---|---|---|
| F-01 | high | Current top bidder can make rivals' ETH bids run out of gas by switching its refund receiver between cheap and gas-burning (no gas floor before the refund self-call) | confirmed | confirmed |
| F-02 | medium | settle() has no gas floor before the prize self-call: a low-gas call skips delivery of the 1/1 to a contract winner, and the 1/1 is lost if that contract cannot call claimPrize | confirmed | confirmed |
| F-03 | medium | One transaction can fill all 100 registration slots with recycled 0.01 ETH and place the opening bid, so one actor chooses when the 24-hour clock starts and locks real supporters out | partly | confirmed |
| F-04 | medium | Self-outbidding with automatically refunded ETH lets one actor take the whole 1,000,000-symbol pool in one transaction at a top bid of about 91-94 ETH (K-01 in ETH mode; the inherited cap is now binding) | partly | confirmed |
| F-05 | medium | No test pins the upper bound of REFUND_GAS or PRIZE_GAS: both can be made effectively unlimited and all tests pass | confirmed | confirmed |
| F-06 | low | An outbid contract bidder can make every rival pay about 140k-180k extra gas per bid, because REFUND_GAS (150k) is far larger than any legitimate ETH receiver needs | confirmed | confirmed |
| F-07 | low | Risk-free symbol farming by inserting a self-outbid ladder in front of a pending jump bid | confirmed | confirmed |
| F-08 | low | Sponsored registration (registerFor): uncapped ERC-1271 staticcall and copyable signatures let an attacker burn the sponsor's gas and budget | confirmed | confirmed |
| F-09 | low | Wallets with code (EIP-7702-delegated EOAs, some smart accounts) cannot use the sponsored registration path, and the site offers no direct register() fallback when a relayer is configured | confirmed | confirmed |
| F-10 | low | If fewer than 100 wallets register, bidding never opens and nothing can change that | confirmed | confirmed |
| F-11 | low | The `registered` flag carries no on-chain meaning and can be entirely captured by sybils, so it must not be used for any perk or allowlist | partly | confirmed |
| F-12 | low | Legacy ERC-20 mode only: a receiver that burns its per-symbol allowance but accepts makes deliverSymbols cost about 9.6M gas per 64 symbols and cannot be skipped | confirmed | confirmed |
| F-13 | low | The page-owner key can break royalty-paying sales or point the collection page at a hostile link | partly | confirmed |
| F-14 | low | Deploy script does not pin the motif set or measure tokenURI read gas, and the site still expects 812 motifs while the decision is 1,024 | partly | confirmed |
| F-15 | low | The ETH launch path has no tests of its own for extension, close, increment, unit, treasury ban, prize delivery or deferred-refund accounting | partly | confirmed |
| F-16 | low | No test that registration is refused before startsAt, in ERC-20 mode, or for the treasury | confirmed | confirmed |
| F-17 | low | Constructor rule reservePrice == REGISTRATION_BALANCE in ETH mode is untested | confirmed | confirmed |
| F-18 | low | EIP-712 domain and type string for registerFor are not pinned by any test | partly | partly |
| F-19 | info | Forced ETH, and refunds owed to bidder contracts that cannot receive ETH and cannot call withdrawRefund, are locked permanently | confirmed | not run |
| F-20 | info | ETH mode still writes the unusable delivery queue on every bid, README still says symbols are delivered, and large rewards need many claim transactions | confirmed | not run |
| F-21 | info | Self-only entry points rely solely on msg.sender == address(this); deliverPrize has no settled check of its own | confirmed | not run |
| F-22 | info | Registration signatures have no upper bound on deadline and cannot be revoked | confirmed | not run |
| F-23 | info | Unregistered wallets can bid once the count reaches 100 (intended and documented) | confirmed | not run |
| F-24 | info | A bid has no deadline, so a pending transaction can land much later at the price the bidder signed | confirmed | not run |
| F-25 | info | Checklists and comments the operator will follow on deploy day still describe the USDC launch | confirmed | not run |
| F-26 | info | Chain-1 guard accepts any nonzero inspection window, and config integers are narrowed without a range check | confirmed | not run |
| F-27 | info | Minor surviving mutants: deadline boundary, Registered event count, 2,300-gas ETH payout, refund/collect order, withdrawProceeds reentrancy guard | confirmed | not run |
