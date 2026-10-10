# Native ETH launch — 8 October 2026

Ethereum mainnet (1), to be rehearsed with test ETH on Sepolia (11155111). Opening bid 0.01 ETH; 0.001 ETH earns one symbol. The opening earns 10 symbols. All balances and transfer values use wei, and native mode is selected by `paymentToken = address(0)`; `tokenUnit = 10^15` is the reward/bid increment unit, not ETH's decimal count. Deployment templates specify 18 decimals. The mainnet deployment script rejects a token address or another opening reserve.

## Registration and bidding

After `startsAt`, `register()` admits the first 100 distinct non-treasury wallets. It is nonpayable and requires a wallet balance of at least 0.01 ETH at execution (after gas prepayment). Each wallet retains its ETH. `registered` and `registrationCount` are on-chain. No off-chain signatures, database, keeper or automatic activation server are needed.

The 100th registration only unlocks bidding. It takes no deposit, awards no symbols and leaves `endsAt` at zero. Registration then closes. Any non-treasury wallet, registered or not, can submit `bid` with at least 0.01 ETH to start the 24-hour clock and receive the corresponding symbol credits. An opening bid of 0.01 ETH earns 10 symbols. If two opening bids race, the later transaction must satisfy the updated minimum bid or revert. There is no deadline between unlocking and the opening bid.

Later bids use payable `bid(amount, minimumReward, expectedFirstSymbolId)` with `msg.value == amount`. The existing 10% raise is rounded up to 0.001 ETH; bids must be multiples of 0.001 ETH. Anyone other than the treasury can bid once unlocked. The existing ten-minute late-bid extension continues without a hard deadline. Reserve, caps, collection roles and rendering remain constructor-configured.

The website captures the registration action when clicked. It never changes a free registration into the paid opening transaction while waiting for wallet connection. Native mode sends a single ETH transaction with no ERC-20 approval or swap. Gas is additional to the payment.

## Custody and claims

Outbid ETH is automatically returned through the existing gas-capped self-call. A recipient that reverts or exhausts the allowance leaves a pull refund. `withdrawRefund(recipient)` and treasury proceeds use native ETH; failed withdrawals roll back the entitlement. The new paid entry points and registration share the existing reentrancy guard. Forced ETH does not increase liabilities or rewards.

Symbols remain reserved at bid time, retaining the existing IDs and trait behavior, but native mode refuses `deliverSymbols`: bidders use `claimSymbols` themselves. Settlement's existing best-effort masterpiece delivery remains separate from symbol claims. The ERC-20 path remains for historical regression coverage, with attached ETH expressly rejected; it cannot be selected by the mainnet deployment script.

## Limits and pending launch work

A balance check is not identity verification: wallets can pass the same funds around, and balances need not remain funded. This is 100 registrations, not 100 proven people or 100 guaranteed bids. Refunded reward farming remains inherent in the requested economics.

The final 1,024-motif pack and the larger-composition requirement in `launch/DECISIONS.md` remain separate unfinished work. These changes retain the existing 256-cell contract limit; they do not imply that larger compositions or the new artwork pack are ready. Mainnet deployment inputs, target-network rehearsal, and independent review of the final source remain pending. Nothing was broadcast.

## Verification

`test/NativeRegistration.t.sol` covers registration, threshold enforcement, duplicate wallets, exact ETH payments, atomic rollback, competing starts, ETH refunds/proceeds, retained manual claims and rejecting ETH recipients. `site/test/native-registration.test.mjs` exercises the actual adapter against local Anvil through 100 unpaid registrations, a separate opening bid and another direct ETH bid. Existing ERC-20 tests are regression coverage, not evidence of native-ETH coverage.

### Static-analysis review

The scan reports `arbitrary-send-eth` (High) at `_pay`: it sees the intentionally selectable ETH recipient. Manual review traced every call: `withdrawRefund` reads and clears only `refunds[msg.sender]`; `withdrawProceeds` requires the immutable treasury and clears proceeds; `payOutbidRefund` requires the contract itself and is reached with the recorded previous bidder/amount. Both external withdrawal paths and the paid bid are guarded. The native authorization/reentrancy test exercises unauthorized self-payout, unauthorized proceeds, nonexistent refunds and callback reentry. This finding is retained in the scanner output rather than presented as a clean high/medium scan. An independent reviewer should verify this reasoning. Existing renderer informational/low findings remain outside this payment change.

### Historical local results (before unlock-only revision)

The final full Solidity suite passed **225 tests**, including 10 native registration/payment tests, with the result retained in `audit/native-contract-tests.txt`. Forty adapter/ABI/copy/wallet-safety tests passed (`audit/native-site-tests.txt`). A Chrome test clicked through the registration UI and paid 100th-wallet start on local Anvil (`audit/native-browser-tests.txt`). No mainnet or Sepolia transaction was sent. These are local tests, not an independent audit.

### Unlock-only revision results

After separating registration from the opening bid, all **225 contract tests** passed (`audit/unlock-contract-tests.txt`), along with **21 adapter/copy tests** (`audit/unlock-site-tests.txt`) and the actual Chrome registration/unlock/separate-bid test (`audit/unlock-browser-tests.txt`). Coverage checks no deposit/reward/timer on the 100th registration, registration closure, registered and unregistered openers, delayed opening, pre-threshold rejection, competing opening bids, and rollback on failed payments/slippage. ABIs and generated website pages were refreshed. The earlier static-analysis report predates this revision; no fresh independent audit or deployment is implied.

## Sponsored registration revision

`registerFor(wallet, deadline, signature)` lets any sponsor submit a wallet's registration-only
EIP-712 signature. It uses pinned OpenZeppelin EIP712 and SignatureChecker (EOA and deployed ERC-1271
wallets), with domain binding to chain/auction and the shared `registered` flag as a one-shot replay
guard. Deadlines, treasury exclusion, balance, opening time and the 100-wallet cap are enforced
on-chain. No sponsor role, auction escrow reimbursement, arbitrary forwarding, payment authorization
or bid authorization is introduced. The 100th signature still only unlocks bidding.

Direct registration remains nonpayable. The optional site endpoint switches registration to a
signature-only flow, verifies confirmation on-chain and never falls back to asking the participant
to pay gas after a sponsor failure. Both public config endpoints are empty pending activation.
The sponsor service and its durable conservative spending controls are documented in
`registration-relayer/README.md`. The sponsor is a separate wallet; no funds were transferred.

Sponsored revision verification: **232 Solidity tests** passed (`audit/sponsor-contract-tests.txt`),
**29 ABI/adapter/copy tests** passed (`audit/sponsor-site-tests.txt`), and **3 sponsor integration
and Chrome tests** passed (`audit/sponsor-relayer-tests.txt`). The latter includes the 100th
signature-only registration, unchanged participant balance, no bid/timer/reward, persistent budget
across restart, invalid signatures, fee/budget refusal, and no paid fallback after sponsor failure.
The first sponsored EOA registration measured approximately **79,764 gas** locally; this is not
a current network fee quote. Runtime and creation sizes passed (`audit/sponsor-build-sizes.txt`).

The fresh Slither scan (`audit/sponsor-slither.txt`) reports **1 High, 12 Low, 39 Informational**;
the command intentionally exits nonzero because the High ETH payout finding remains. The High is
the previously reviewed selectable refund/proceeds recipient in `_pay`; no new High/Medium finding
was reported. The extra Low flags the intentional signature-expiry timestamp comparison. Findings
are retained, not suppressed. This work is not independent audit approval for mainnet funds.
