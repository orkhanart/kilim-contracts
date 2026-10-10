# The ETH auction

How the Kilim auction works, as the code on disk does it. The auction takes native ETH and nothing else. Ethereum mainnet (chain 1), rehearsed with test ETH on Sepolia (11155111).

Sources: `src/auction/EnglishAuction.sol` (registration, bids, refunds, settlement, proceeds) and `src/KilimAuction.sol` (symbol credits, claims, the 1/1). Nothing here has been deployed.

## Numbers

| Name | Value | Meaning |
| --- | --- | --- |
| `SYMBOL_PRICE` | 0.001 ETH | The bid unit. Every bid is a whole multiple of it, and each unit earns one symbol credit. |
| `REGISTRATION_BALANCE` | 0.01 ETH | What a wallet must hold to register. |
| `reservePrice` | 0.01 ETH | The opening bid. The constructor accepts no other value: it must equal `REGISTRATION_BALANCE`. |
| `REGISTRATION_TARGET` | 100 | Registrations needed before anyone can bid. |
| Refund gas | 150,000 | Gas given to the automatic refund. |
| Prize gas | 500,000 | Gas given to sending the 1/1 at settlement. |

All amounts are wei. Duration, late-bid window, increment and the symbol caps are constructor settings; the launch values are in [checklists/1-pre-deploy.md](../checklists/1-pre-deploy.md).

## 1. Registration

From `startsAt`, a wallet registers in one of two ways:

- `register()`: the wallet sends the transaction itself.
- `registerFor(wallet, deadline, signature)`: anyone sends it, with the wallet's EIP-712 signature over `Register(address wallet,uint256 deadline)`. The domain is `Kilim Registration`, version `1`, bound to the chain and this auction. Signatures from plain accounts and from ERC-1271 contract wallets are accepted. `registrationDigest(wallet, deadline)` returns the digest to sign.

Both are free: registration takes no ETH and moves none. It checks that the wallet holds at least 0.01 ETH at that moment. The wallet keeps its ETH and may spend it afterwards.

Refused:

| Case | Error |
| --- | --- |
| Before `startsAt`, or once 100 wallets have registered | `RegistrationClosed` |
| The treasury | `TreasuryCannotBid` |
| A wallet that already registered | `AlreadyRegistered` |
| A balance below 0.01 ETH | `InsufficientRegistrationBalance` |
| `registerFor` after its `deadline` | `RegistrationSignatureExpired` |
| `registerFor` with a signature that is not the wallet's | `InvalidRegistrationSignature` |

Each registration emits `Registered(wallet, count)`. `registered(wallet)` and `registrationCount()` are public.

The 100th registration only unlocks bidding. It takes no deposit, earns no symbols and does not start the clock: `endsAt` stays 0. A signature authorises registration only. It can never place a bid or move ETH.

**What registration does not do.** It counts addresses, not people. One actor can pass the same 0.01 ETH through 100 addresses and fill every slot. Being registered gives no right, priority or reward, and a wallet does not need to be registered to bid. If fewer than 100 wallets ever register, bidding never opens: there is no fallback date and nobody can change that. The artist accepted all three on October 9, 2026 (see [AUDIT.md](../AUDIT.md)).

## 2. Bidding

`bid(amount, minimumReward, expectedFirstSymbolId)` is payable. `msg.value` must equal `amount` exactly, or the call reverts with `IncorrectPayment`. A bid is a new full bid, not a top-up.

A bid is accepted when all of this holds:

- 100 wallets have registered (`RegistrationIncomplete` otherwise);
- the sender is not the treasury (`TreasuryCannotBid`);
- the auction is not settled and, once the clock runs, the close has not passed (`AuctionNotOpen`);
- the amount is at least `minimumBid()` (`BidTooLow(minimum)`);
- the amount is a whole multiple of 0.001 ETH (`NonWholeUnitBid`).

`minimumBid()` is 0.01 ETH before the first bid. After that it is the highest bid plus `incrementBps`, rounded up to a whole 0.001 ETH. With the launch increment of 10% the ladder starts 0.01, 0.011, 0.013, 0.015, 0.017 ETH. If two opening bids race, the second must meet the new minimum or it reverts. A wallet may outbid itself; that bid is funded in full like any other.

There is no deadline between the 100th registration and the first bid, and a bid transaction carries no deadline of its own.

## 3. The clock

`startsAt` opens registration. It does not start a countdown.

The first accepted bid sets `endsAt` to that bid's time plus `duration` and emits `AuctionStarted`. A later bid that lands within `extensionWindow` of the close moves the close to that bid's time plus `extensionWindow`. A bid never shortens the close, and there is no limit on extensions: the auction ends only after a full window with no new bid.

With no bid the clock never starts, `settle()` reverts with `NoBids`, and the 1/1 is never minted.

## 4. Refunds

The bid that beats yours pays you back in the same transaction. The auction calls itself (`payOutbidRefund`) with 150,000 gas and sends your full bid to your address. On success it emits `RefundPaid`.

If that payment fails, for example because the address is a contract that rejects ETH or burns the gas, the new bid still goes through. The amount is added to `refunds(yourAddress)`, `RefundDeferred` is emitted, and you collect it with `withdrawRefund(to)` whenever you like, to any address except the zero address, the auction and the collection. Nothing expires.

A bid that outbids someone must reach the refund with enough gas for the refund's full allowance (`REFUND_GAS + REFUND_GAS / 63 + 60_000`, about 212,000). With less it reverts with `InsufficientGas` and nothing changes. This is why the gas a bid needs does not depend on what the outbid wallet's code does. Send bids with a generous gas limit.

Gas is never refunded.

## 5. Symbol credits

Every accepted bid earns `min(amount / 0.001 ETH, maxSymbolsPerBid, symbols left in the pool)` credits. `rewardForBid(amount)` quotes it. A bid of 0.01 ETH earns 10.

The credits reserve the next symbol IDs in order, so the traits of those symbols are fixed at that moment. `BidPlaced` reports the first reserved ID, and `unclaimedSymbolRanges(bidder)` lists what a bidder has left.

An outbid bidder keeps every credit and gets the ETH back. This is intended. It also means one wallet can outbid itself up the ladder and take the whole pool for the cost of gas (see [AUDIT.md](../AUDIT.md), F-04 and K-01).

When the pool is empty, bids still count for the 1/1 and earn nothing.

Two guards protect a bidder from another bid landing first:

- `minimumReward`: revert with `RewardSlippage` if the bid would earn fewer credits.
- `expectedFirstSymbolId`: revert with `SymbolRangeMoved` unless the reward starts at this ID. Pass 0 to accept whatever IDs are next, and always pass 0 when the quoted reward is 0.

**Credits are not symbols until they are claimed.** There is no automatic delivery. The bidder calls `claimSymbols(quantity, to)`, 1 to 64 symbols per transaction, oldest bid first, and pays the gas. Credits never expire and can be claimed before or after settlement, to any address that accepts ERC-721 tokens. `symbolsAllocated()` and `symbolsClaimed()` give the totals; their difference is what is still unclaimed.

## 6. Settlement and the 1/1

At or after `endsAt`, anyone calls `settle()`. It records the winner and the proceeds, emits `AuctionSettled`, then sends the 1/1 (token ID 1) to the winner through a self-call (`deliverPrize`) with 500,000 gas.

- If the winner's wallet accepts it, `PrizeClaimed(winner, winner)` is emitted and nothing more is needed.
- If the wallet rejects it or needs more gas, settlement still stands, `PrizeDeliveryFailed(winner)` is emitted, and the winner calls `claimPrize(to)` to any address that accepts it.

`settle()` must have enough gas for the delivery's full allowance (`PRIZE_GAS + PRIZE_GAS / 63 + 50_000`, about 558,000). With less it reverts with `InsufficientGas`, nothing is settled, and anyone can call it again. A low-gas call therefore cannot skip the delivery.

## 7. Proceeds

After settlement the treasury calls `withdrawProceeds(to)` and receives the winning bid in ETH. Only the treasury can call it, and only once there is something to withdraw. The treasury address can neither register nor bid.

## 8. What the auction holds

`liabilities()` is the ETH the auction owes: deferred refunds plus the highest bid, or after settlement the proceeds not yet withdrawn. `address(auction).balance` must never be below it. That is the one number to monitor.

The auction has no `receive` and no fallback function. A plain ETH transfer reverts, and so does a call to an unknown function. ETH forced into the contract is not counted, earns nothing and cannot be recovered.

There is no owner, pause, upgrade or rescue function.

## For bidders that are contracts

A contract that bids must be able to do these things later, or it locks its own assets:

- receive ETH, or call `withdrawRefund(to)`;
- call `claimSymbols(quantity, to)`;
- accept an ERC-721 token, or call `claimPrize(to)`.

## Sponsored registration

`registerFor` lets a sponsor pay the gas for someone else's registration. The contract has no sponsor role and never repays the sponsor. The optional service that does this is in `registration-relayer/`; its spending limits and setup are in `registration-relayer/README.md`. It is not activated.

## Tests

- `test/NativeRegistration.t.sol`: registration, the threshold, duplicates, exact payment, rollback, competing opening bids, refunds, proceeds, claims, receivers that reject ETH, and who may call the self-calls.
- `test/SponsoredRegistration.t.sol`: signatures, deadlines, replay across chains and auctions, ERC-1271 wallets, the 100th sponsored registration.
- `test/GasFloors.t.sol`: the two gas floors.
- `test/KilimAuction.t.sol`, `test/LaunchConfig.t.sol`, `test/Lifecycle.t.sol`, `test/ReuseRegression.t.sol`: bid rules, the clock, refunds, claims, settlement and the launch settings.
- `test/AuctionInvariants.t.sol`: the balance always covers `liabilities()`, under stateful fuzzing with hostile receivers.

Run them with `pnpm test:contracts`. Passing local tests are not an audit: see [AUDIT.md](../AUDIT.md) for what is open, what the artist accepted and what still blocks a launch.
