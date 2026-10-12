# Sepolia swarm run: operator notes

The run's own record is in this folder: log.txt, events.jsonl (every transaction and receipt with its decoded events), checks.jsonl (every check), gas.json, status.json and, at the end, verdict.txt. These notes add what the files cannot say.

## Before the run

- A full rehearsal on an anvil fork of Sepolia, with the clock driven forward, ended `VERDICT PASS`: 16 of 16 items, 0 failed checks of 154. It found and fixed three harness bugs:
  - the site's bid book was compared at a newer block than the events;
  - the affordability sum counted the leading bid twice;
  - the bidder's gas cushion was fixed instead of read the way the site reads it.

## Restarts of the real run (11 October 2026, UTC)

The run is resumable: a restart reads the chain and the status file, and never sends a step twice.

- **20:39:11:** first start, from main 1bf77858 plus the uncommitted harness.
- **20:40:09:** restarted after a stale balance read. It came from a load-balanced node a block behind, right after robot 69's funding receipt, and was logged as `FAIL relay 3 robot 69 balance: 0.0102`. The robot held 0.0102 ETH. Fix: reads after a receipt now retry. The row is reclassified in checks.jsonl as `kind: step`, with its reason.
- **20:44:08:** restarted after two `insufficient funds ... balance 0` refusals. eth_sendRawTransaction had reached a backend that had not yet seen relay ETH arriving. Fix: the same signed transaction is resent. Both rows are reclassified as `kind: step`, with their reason.

- **20:51:50:** restarted to wait up to 3 hours after the 100th check-in for the artist's opening bid from their own wallet through the page; a robot outbids it 10 minutes later.

## Site adapter version

The harness loads site/chain.js once, at process start. The process started at 20:44:08 UTC runs chain.js as it stood before c3294f0b (committed 20:46:13 UTC: the four site fixes from the audit).

The process started at 20:51:45 UTC ran chain.js at c3294f0b. It was restarted at 21:08:37 UTC, while waiting for the opening bid, to run chain.js and rpc.js at 18d89333 (the log scan out of refresh, the replaced-transaction watch), the version the pages serve. The bid book is compared once status().history is ready.

## The close, settlement and claims (12 October 2026, UTC)

- **09:08:58:** `b2-mid` skipped, as designed: the artist's own second bid (0.011 ETH) had moved the ladder up one
  step, so the robots kept their test ETH for the two late bids.
- **21:05:13:** `late-1`, B1 bid 0.019 ETH through the site, 3 m 35 s before the close; the close moved to
  21:15:12 (exactly 10 minutes after the bid's block).
- **21:13:49:** `late-2`, B2 bid 0.021 ETH through the site; B1's 0.019 came back in the same transaction; the
  close moved to 21:23:48.
- **21:25:01:** settled by B3 (not the treasury). The settle transaction carried `AuctionSettled`, `Transfer`,
  `PrizeClaimed`: **the 1/1 was delivered inside settlement** on a Glamsterdam chain, with this contract's
  `PRIZE_GAS` of 500,000. Gas used: 599,508. The real `tokenURI(1)` equals `expected.oneOfOneGolden`.
- **21:25:16 to 21:28:20:** five step errors, all one cause: the pool held 0.0010 ETH and the top-up for B2's
  claims needed 0.0019. B1's 0.019 refund had stayed in B1 (the sweep returns robot ETH only at the end).
  Each row in `checks.jsonl` carries this reason. At 21:29 Claude moved 0.015991662952895921 test ETH from
  B1 to the pool by hand (tx `0xd58377b5d830a3cff212417b4070b3a2483d65d7992e0418a9e37c2ba3693d85`, block
  11,901,586), the same move the sweep makes; the retried step then went through. The end-of-run sweep of B1
  then logged `nonce too low` (its cached nonce 4 had been used by that transfer) and carried on.
- **21:29:25:** B2 claimed its 34 motifs; claims by B1 (36 to B3, a claim to another address), the contract
  wallet and the holder actions all passed.
- **21:30:51:** `swarm finished: verdict PASS` at block 11,901,595: 16 of 16 items, 0 failed of 470 checks;
  1 non-robot address took part (the artist's opening bid); 8 step errors retried, each with its reason
  (3 on 11 October, 5 above).

Gas on Glamsterdam (Sepolia), for comparison with mainnet's Cancun figures: settle with the prize delivered
599,508; claim of 36 motifs to another address 4,422,673; the contract wallet's claim 2,033,654; motif
transfer 58,589, approve 130,661, burn 254,170; outbidding bids 229,075 to 648,155.
