# 2. Deploy checklist

The deployment itself: from final checks to verified, read-back contracts. Run it twice, first on Sepolia as the rehearsal and then on mainnet. Before: [1-pre-deploy.md](1-pre-deploy.md). After: [3-post-deploy.md](3-post-deploy.md).

Don't start unless the pre-deploy go/no-go is signed off. A deployed auction **cannot be stopped or edited**.

Two phases, in this order ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)):

1. **The store** (`runStore()`): every chunk (motif grids, names, page prefix, head and tail) through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0. Sent by forge's `--sender`: any funded wallet **other than orkhanart.eth once its nonce is published** (45 chunks today would move that nonce, and the script refuses it). Any time before the contracts; idempotent, so it can be rerun and sends only what is missing.
2. **The contracts** (`runContracts()`): from orkhanart.eth at its published nonce n: `KilimMotifs` (Motif Bazaar) at n, `KilimOneOfOne` (The Unwoven Kilim) at n + 1, both with the auction's predicted address (n + 2) as `minter`, then `KilimAuction` at n + 2.

`run()` does both in one go for the local dry run only (`pnpm -s deploy:dry`). The Sepolia rehearsal uses the two phases as mainnet does, with the nonce published after the store, but with the gas flags of [the section below](#the-sepolia-rehearsal-runs-glamsterdam): Sepolia already runs Glamsterdam. On mainnet `run()` is refused.

```sh
cd contracts
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runStore()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --ledger --sender <a funded wallet that is not the deployer>
# publish the chunk addresses and the deployer's nonce, inspect, then:
KILIM_DEPLOY_CONFIG=deploy/<network>.json \
  node scripts/forge.mjs script script/DeployKilim.s.sol --sig 'runContracts()' \
  --rpc-url "$RPC" --broadcast --slow --timeout 600 --ledger --sender 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac
```

`--slow` sends each transaction only after the one before it is confirmed and succeeded. Without it forge signs and sends a whole phase at once, and if the first creation is lost the other two are still spent on creations that revert. `--timeout` is how long forge waits for a receipt (seconds). If the Ledger's address is not its first one, add `--mnemonic-indexes <n>` (or `--hd-paths`).

**Store phase only:** if forge stops on a timeout or a dropped transaction, nothing is lost. Rerun the same command with `--resume`, which continues from the saved broadcast file without simulating again and expects the nonces unchanged; a transaction that was dropped from the pool has to be removed from that file before it is sent again. Rerunning without `--resume` works too, since the phase sends only what is missing. The contracts phase is never resumed after a transaction was removed from the broadcast file: a lost creation is handled under [Send](#send).

forge sets each transaction's gas limit from its own simulation of it, in the EVM that `foundry.toml` names (Cancun), times `--gas-estimate-multiplier` (130% by default). It does not ask the node's `eth_estimateGas`. That is right for mainnet only while mainnet has not forked to Glamsterdam.

## The Sepolia rehearsal runs Glamsterdam

Sepolia has run Glamsterdam since 6 October 2026. Under EIP-8037 code deposit is 1,530 gas per byte of state gas instead of 200, and a full store chunk needs about 38.6M gas there (the measured minimum is 38,626,249). forge 1.7.1 has no Glamsterdam prices: its Cancun simulation times 130% signs a chunk with under 8M, so the commands above fail on the first chunk. The 16,777,216 cap of EIP-7825 limits execution gas only; state gas is paid from the gas limit above it, so such a transaction is valid.

On Sepolia, add two flags to both commands:

```sh
  --skip-simulation --gas-estimate-multiplier 120
```

With `--skip-simulation` forge takes each gas limit from the node's `eth_estimateGas` times the multiplier. The node's estimate is itself short: 38,532,308 for a full chunk, about 94,000 under the minimum, so the estimate alone would fail. A multiplier of 105 or more covers it; pass 120 explicitly rather than rely on forge's default. The script still runs its own checks before anything is sent.

- [ ] The script's 8M policy and every gas figure it prints are Cancun measurements. They do not describe a Glamsterdam chain: on Sepolia they pass and say nothing about what the chain charges.
- [ ] Record the Sepolia receipts as the post-fork figures: each chunk's gas used, and the three contracts (estimated on 11 October at about 18.6M for `KilimMotifs`, 24.9M for `KilimOneOfOne` and 18.1M for `KilimAuction`). The whole store is about 1.6G gas there. Fund the Sepolia wallets for that.
- [ ] Send the first chunk and read its receipt before leaving the rest to run.

## Pre-flight

`cast` is not part of the project's toolchain (only forge and anvil are). Where a line below uses it, the same JSON-RPC call works with curl, for example `curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac","latest"]}' "$RPC"` must answer `"result":"0x"`, and `eth_getBlockByNumber` with `["latest",false]` shows the header fields.

`script/DeployKilim.s.sol` checks the items marked **(script)** itself and **refuses to send** if any fail. Confirm every item by hand as well.

- [ ] Compare the script's config with the signed-off config line by line. A second person does the same. Start from `deploy/mainnet.example.json`. The contracts phase prints every setting it deploys with and flags any that differs from the launch value; on chain 1 there must be no flag.
- [ ] **By hand, on deploy day: mainnet has not forked to Glamsterdam.** The latest block header has no `blockAccessListHash` and no `slotNumber` (`cast block latest --json --rpc-url "$RPC"`), and the fork schedule (EIP-7773) sets no mainnet activation before both phases are done. Mainnet has no Glamsterdam date on 11 October 2026. If it has forked, stop: the commands, the 8M policy and the gas figures here are Cancun's ([docs/STORAGE.md](../docs/STORAGE.md#deployment-and-what-the-script-refuses)).
- [ ] **(script)** `block.chainid` equals the config's `chainId`. **By hand:** 1 for Ethereum mainnet, 11155111 for the Sepolia rehearsal; and the chain has code at the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (`cast code`; mainnet and Sepolia do. forge's own simulation supplies that code even where the chain lacks it, so the script cannot tell).
- [ ] **(script)** The manifests: `motifCount` 1,024, the canonical CREATE2 deployer, every chunk file's size and keccak, every chunk's CREATE2 address, the chunk layout (full chunks before a section's last, grids cut at 24,544), the five section hashes recomputed from the files, and no foreign code at any chunk address. **By hand:** the manifests are the ones packed from the final artwork and still (`pnpm -s check:stores --config <the config>`), and their hashes and addresses are the published ones.
- [ ] **(script)** The content is the content the config names: the `expected` block (five section hashes, the two tokenURI goldens, the sha256 of the artist's page, the artwork, the still and the loader; `pnpm -s expected --config deploy/mainnet.json` prints it) equals the manifests, value by value, in both phases. On chain 1 a config without the block, or with a zero in it, is refused, and so is an artwork whose manifest says it never reads `KILIM_GRIDS`. **By hand:** the block is the published one, and two people compared it.
- [ ] **(script)** The config texts equal the manifests': the collection `description` and `externalUrl`, and the 1/1's `name`, `description` and `externalUrl` (the goldens were computed with them, except the collection's link, which the packer records for this comparison). The token JSON holds no `#` or `%`.
- [ ] **(script)** The texts are the signed-off ones: `expected.texts` is the hash of the eight texts the contracts store (the five above and the `bazaar` block's `description`, `externalUrl` and `imageBase`; `script/KilimTexts.sol`), recomputed from the config in both phases and again by the Kilim Bazaar script, which also requires the token texts to be the chain's. Required on chain 1. Before 12 October the collection's link and the Bazaar's texts were in no published value: an edit after sign-off, with the store re-packed to match, passed every check (audit TK-2). **By hand:** the `texts` value and the eight texts printed by `pnpm -s expected --config deploy/mainnet.json` are the published ones.
- [ ] **(script)** Store phase: each missing chunk's dry run stays under 8M gas and lands at the predicted address. A chunk already there is verified and skipped. The script prints who sends and how many chunks, and refuses when the sender is the config's deployer, a nonce is published for it and a chunk is still missing.
- [ ] **(script)** Contracts phase: every chunk is already on the chain (`store not deployed: runStore first`).
- [ ] **(script)** The deployer's nonce at the latest block equals the published `deployerNonce`, and so does its pending nonce (`eth_getTransactionCount(deployer, "pending")`, asked of the node the script runs against): a transaction from the wallet still waiting in the pool is refused. On chain 1 the check cannot be skipped. **By hand:** no other transaction from this key since publishing, and none waiting in another node's pool (look the wallet up in a block explorer right before sending).
- [ ] **(script)** The deployer is a plain account, without code: no EIP-7702 delegation and no contract wallet (`deployer has code (EIP-7702 delegation or contract wallet)`), in the contracts phase and in `runAuction()`. **By hand:** right before sending, `cast code 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac --rpc-url "$RPC"` prints `0x`.
- [ ] **(script)** `reservePrice` is `10000000000000000` wei (0.01 ETH), on every chain. The auction constructor accepts no other value.
- [ ] **(script)** On chain 1: `deployer` and `treasury` are `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac` (orkhanart.eth); `incrementBps` 1000 (+10%); `duration` 86400 (24 hours from the first bid); `extensionWindow` 600 (10 minutes, no limit on extensions); `motifCap` and `maxMotifsPerBid` 1,000,000; `oneOfOne.name` "The Unwoven Kilim". **By hand:** fresh proof that the key still works ([1-pre-deploy.md](1-pre-deploy.md)). Switching the treasury to a Safe would mean changing `LAUNCH_TREASURY` in the script, its tests and the signed-off config, then re-tagging.
- [ ] **(script)** `startsAt` is in Unix **seconds** (not milliseconds), at least `minLeadSeconds` (the inspection window) ahead of the latest block when the script simulates, and at most a year out. On chain 1, `minLeadSeconds` must be nonzero; it is 600 (the artist, 12 October 2026: the registration phase is the inspection window). `runStore()` reads `startsAt` but never checks it, so the config keeps the placeholder 0 until the contracts. **By hand:** right before `runContracts()`, `startsAt` is set to now + 1,200 seconds ([0-launch-steps.md](0-launch-steps.md), step 10), and the three creations are sent at once: the auction's must be mined before `startsAt`, or its constructor reverts and both token contracts are void.
- [ ] **(script)** The dry run of the three contracts: the auction's address equals the prediction (nonce + 2), every immutable reads back as deployed, a motif's `tokenURI` and the 1/1's `tokenURI(1)` hash to the manifests' goldens, and each deployment and each read stays under 8M gas.
- [ ] **(script)** forge simulates the whole script before sending anything. **By hand:** the commands carry `--slow` and `--timeout`; each broadcast gas limit is forge's own Cancun simulation of that transaction times 130%, not the node's estimate (on Sepolia: the flags above); and the wallets hold enough ETH ([0-launch-steps.md](0-launch-steps.md), step 3). The final dress rehearsal's receipts on a fork of mainnet (12 October): the store 225.0M gas, from the store wallet; from orkhanart.eth the three contracts 11.5M and Kilim Bazaar 5.7M, 17.2M in all; and 0.1 ETH in the sealer's own wallet. A wallet must also hold its next transaction's gas limit times its max fee when it sends: 7.87M for a chunk, 7.61M for `KilimOneOfOne`, 7.37M for the Bazaar.
- [ ] **The build is the frozen one.** In a clean checkout of the git tag, in `contracts/` (after `pnpm install`):

  ```sh
  pnpm -s build && pnpm -s artifacts
  git diff --exit-code -- abi/ audit/build-manifest.json
  ```

  `pnpm -s artifacts` has no compare mode: it rewrites `abi/` and `audit/build-manifest.json` from the build and from the files git tracks (never an untracked one), and `git diff` is the comparison. Run it before `deploy/mainnet.json` is edited for the day, and it must exit 0 with no output. If `deploy/mainnet.json` already carries the day's values, these two must print nothing instead: the manifest may differ only in `deploy/mainnet.json`'s own hash, and that file only in `deployerNonce` and `startsAt`.

  ```sh
  git diff --exit-code -- abi/ && git diff -U0 -- audit/build-manifest.json | grep '^[-+] ' | grep -v '"deploy/mainnet.json": '
  git diff -U0 -- deploy/mainnet.json | grep '^[-+] ' | grep -v -E '"(deployerNonce|startsAt)": '
  ```

  Then `git checkout -- audit/build-manifest.json`, so the checkout carries the frozen file again.

## Send

- [ ] **Store phase.** Broadcast the chunk transactions (45 with the artwork and still of 11 October). Record each hash. Compare the addresses the script prints with the published ones. The chunks can go up over several days, from any wallet but the deployer.
- [ ] **Contracts phase.** Broadcast the three creation transactions from orkhanart.eth, in order, at nonces n, n + 1, n + 2. They send no ETH: the auction holds nothing until the first bid.
- [ ] Record each transaction hash, block number and gas used.
- [ ] Confirm the three addresses match the published predictions.
- [ ] **If a creation is still pending** when forge's `--timeout` runs out: wait, or use Speed up only.
  - **Never press Cancel.** Cancel is a replacement at the same nonce: it voids both token contracts, and you must republish and deploy again with a new `startsAt`. No ETH is lost.
  - **The auction's creation must be mined before `startsAt`** (about 20 minutes after the command started): a third creation mined after it reverts in the constructor (FA-04), which is the case below where both token contracts are void. Speed it up rather than let it wait.
  - **Before any rerun:** reject every open MetaMask request, and confirm that Activity shows nothing pending for orkhanart.eth.
  - **Why:** a request MetaMask still holds is still sent if it is confirmed after forge stops ([audit/sepolia-2026-10-11.txt](../audit/sepolia-2026-10-11.txt)).
- [ ] **If the third (the auction) was dropped** (never mined: the deployer is still at n + 2, latest and pending, on an explorer) and the first two are mined: nothing is void. The two token contracts name the address at nonce n + 2 as their minter, and the auction can still be deployed there. Find the cause, send nothing else from the wallet, set `startsAt` again to now + 1,200 (only the auction holds it; the token contracts do not), then run the same command with `--sig 'runAuction()'`: it requires the deployer at n + 2, reads both token contracts back against the config, repeats every check and the golden comparison, and sends only the auction. The published addresses and the motif layout stand.
- [ ] **If the third was mined and reverted, or replaced by another transaction at n + 2:** nonce n + 2 is spent and the deployer is at n + 3. The address both token contracts name as their minter can never get code, so neither can ever mint: both are void. `runAuction()` refuses (`deployer nonce is not the published one plus two`). Mark the two addresses void as in [If anything is wrong](#if-anything-is-wrong), then restart from a new nonce (steps 1 to 3 below).
- [ ] **If the first was dropped** (never mined: the deployer's latest and pending nonce are still n on an explorer, and nothing from the wallet is queued): nothing is spent, and with `--slow` the other two were not sent. Find the cause, then run `runContracts()` again, without `--resume`. The published addresses and the motif layout stand.
- [ ] **If the first was mined and reverted or replaced, or the second was lost in any way:** the deployer has moved past n and the script refuses both commands. A dropped second leaves the 1/1's and the auction's addresses free, but the script has no command that sends only those two. Mark any token contract already at a published address void, then:
  1. find the cause;
  2. publish the new nonce, predicted addresses and motif layout (`motifOf` depends on the Motif Bazaar address);
  3. deploy again with `deployerNonce` and `startsAt` set anew (step 10 of [0-launch-steps.md](0-launch-steps.md)).

## Verify source

- [ ] Verify `KilimMotifs` on Etherscan, with its constructor arguments in this order: `minter` (the **auction** address), `royaltyReceiver`, `motifCap`, `gridChunks` (`address[]`, the grid chunks in order), `gridsHash`, `namesChunk`, `namesHash`, `description`, `externalUrl`.
- [ ] Verify `KilimOneOfOne`: `minter` (the auction), `royaltyReceiver`, `motifs` (the Motif Bazaar address), `page` (one struct: `prefixChunks` `address[]`, `prefixHash`, `headChunks` `address[]`, `headHash`, `tailChunks` `address[]`, `tailHash`), `name`, `description`, `externalUrl`.
- [ ] Verify `KilimAuction`: one `Config` struct of 9 fields, in this order: `treasury`, `motifs`, `oneOfOne`, `startsAt`, `duration`, `extensionWindow`, `incrementBps`, `reservePrice`, `maxMotifsPerBid`.
- [ ] The chunks are code-only (`0x00` followed by the data) and need no verification; publish their addresses and the files they hold.
- [ ] Confirm the verifier supports solc 0.8.37 with optimizer 200, cancun, no via-IR, ipfs metadata. Keep Sourcify as a fallback.
- [ ] All three contracts show as verified, and their source matches the tagged commit.

## Read back

Check every value on-chain against the config **before `startsAt`**. The script only read back its own simulation before sending; this checks the chain itself. On chain 1 every value must also equal the launch value in the pre-flight list above.

- [ ] **Auction settings:** `treasury`, `reservePrice` (10000000000000000), `incrementBps`, `startsAt`, `duration`, `extensionWindow`, `motifs()`, `oneOfOne()`, `motifCap` (equal to the collection's), `maxMotifsPerBid`.
- [ ] **Auction constants:** `MOTIF_PRICE` = 1000000000000000 (0.001 ETH), `REGISTRATION_BALANCE` = 10000000000000000 (0.01 ETH), `REGISTRATION_TARGET` = 100.
- [ ] **Registration domain:** `eip712Domain()` returns name `Kilim Registration`, version `1`, this chain ID and this auction's address. A sponsor or site that signs for any other domain will fail.
- [ ] **Nothing has happened yet:**
  - `registrationCount == 0`;
  - `endsAt == 0`: it is set only by the first bid, to that bid's time plus `duration`;
  - `highestBid == 0`, `highestBidder == 0x0`;
  - `motifsAllocated == 0`, `motifsClaimed == 0`, `settled == false`, `prizeClaimed == false`;
  - `refundLiability == 0`, `proceedsDue == 0`, `liabilities() == 0`;
  - the auction's ETH balance is 0.
- [ ] **Closed doors:** `minimumBid()` returns 10000000000000000. Simulate (do not send) a `bid` of that amount with that value: it must revert with `RegistrationIncomplete`. Simulate `register()`: before `startsAt` it must revert with `RegistrationClosed`. Simulate a plain ETH transfer to the auction: it must revert.
- [ ] **Motif Bazaar** (`motifs()`): `name()` "Motif Bazaar", `symbol()` "MOTIF", `minter() == auction`, `royaltyReceiver()` (the treasury), `ROYALTY_BPS` 500, `motifCap`, `MOTIF_COUNT` 1024, `deploymentChainId` (the chain's id), `MAX_MINT_BATCH` 64, `gridsHash()`, `namesHash()`, `gridChunks()` and `namesChunk()` (the published addresses), `description()`, `externalUrl()`, `motifsMinted == 0`, `motifsBurned == 0`; `keccak256(grids())` equals `gridsHash`; `grid(1)` and `motifName(1)` equal the first 32 bytes of `grids.bin` and the first name; `contractURI()` decodes to the published texts; `tokenURI(1)` reverts (no token exists yet).
- [ ] **The Unwoven Kilim** (`oneOfOne()`): `name()` "The Unwoven Kilim", `symbol()` "UNWOVEN", `minter() == auction`, `motifs()` (the Motif Bazaar address), `royaltyReceiver()`, `ROYALTY_BPS` 500, `TOKEN_ID` 1, `prefixHash()`, `headHash()`, `tailHash()`, `prefixChunks()`, `headChunks()`, `tailChunks()` (the published values), `description()`, `externalUrl()`, `minted() == false`.
- [ ] **The 1/1's `tokenURI(1)` against its golden, before the mint** (audit TK-5). It reverts until the mint, but an `eth_call` can pretend token 1 has an owner: a state override of `_owners[1]`, which OpenZeppelin's ERC721 keeps at slot 2, so its key is `keccak256(abi.encode(1, 2))`. Nothing is sent. Put the 1/1's address in `ONE`:

  ```sh
  ONE=<The Unwoven Kilim's address>
  curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"'"$ONE"'","data":"0xc87b56dd0000000000000000000000000000000000000000000000000000000000000001","gas":"0x1c9c380"},"latest",{"'"$ONE"'":{"stateDiff":{"0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0":"0x000000000000000000000000000000000000000000000000000000000000dead"}}}]}' "$RPC" \
    | python3 -c 'import sys,json,hashlib; r=bytes.fromhex(json.load(sys.stdin)["result"][2:]); n=int.from_bytes(r[32:64],"big"); print(n, hashlib.sha256(r[64:64+n]).hexdigest())'
  ```

  It must print the length (1068627 with today's store) and `expected.oneOfOneGolden` without its `0x`. Run it on two RPCs. On 12 October the same command against Sepolia's 1/1 printed that chain's golden (`69bca6eb…`, 1,068,635 bytes), and with the slot set to zero instead the node answered `ERC721NonexistentToken(1)`, so public nodes apply the override. `test/DeployKilim.t.sol` (`testTheUnmintedOneOfOneReadsItsGoldenWithAStateOverride`) pins the slot. The first read after settlement is checked again in [3-post-deploy.md](3-post-deploy.md).
- [ ] Spot-check `motifOf(id)` for a few ids against the published layout.

## If anything is wrong

A deployment cannot be abandoned. It opens registration at its own `startsAt`, takes real bids once 100 wallets register, and mints tokens named "Motif Bazaar" and "The Unwoven Kilim".

- [ ] Publicly mark its addresses void on the site, social channels, explorers and marketplaces, and make the site refuse them.
- [ ] Commit publicly that the treasury will return any winning bid on it with `withdrawProceeds(to = winner)`. Outbid bidders are refunded by the contract as usual.
- [ ] If the treasury address itself was the mistake, warn plainly that a winning bid there cannot be returned.
- [ ] Then fix the config, publish the new nonce, predicted addresses and layout, set a new `startsAt` on the day, and run this checklist again. The chunks stay where they are and are reused.

## Kilim Bazaar's sealer

Kilim Bazaar is its own launch, after this one (`script/DeployKilimBazaar.s.sol`, from orkhanart.eth; [0-launch-steps.md](0-launch-steps.md), step 11). Its sealer (`kilim-sealer/`, see its README) must be running before the first kilim can be made. That moment is settlement if the Bazaar already exists, else the Bazaar's own creation block. Without the sealer, rule 7 does not hold (audit SL-1).

- [ ] **Before the Bazaar is deployed, its pages and image service are live:** `https://orkhan.art/kilim/bazaar/`, `https://orkhan.art/kilim/bazaar/<id>` and `https://orkhan.art/kilim/bazaar/image/<id>` are served by the live site, not 404 (all three were 404 on 12 October). The contract appends each kilim's id to `externalUrl` and `imageBase` for ever, and marketplaces take every kilim's picture from the image base. **The Bazaar deploy can wait until they are live: any time before the auction settles is as good as at once.** Before kilim 1 exists its two URLs cannot show it, but they must answer from the live pages.

### Kilim Bazaar: read back

Right after the creation, read the Bazaar on the chain itself (the script only read back its own deployment). With the sealer's node modules (`kilim-sealer/`, ethers 6.17.0; `npm ci` there first if they are missing), put a trusted RPC in `RPC` and the printed address in `BAZAAR`, and run it on two RPCs. Nothing is sent:

```sh
cd ../kilim-sealer && node --input-type=module -e '
import { ethers } from "ethers";
const p = new ethers.JsonRpcProvider(process.env.RPC), at = process.env.BAZAAR;
const b = new ethers.Contract(at, ["function auction() view returns (address)", "function motifs() view returns (address)",
  "function oneOfOne() view returns (address)", "function royaltyReceiver() view returns (address)", "function motifPrice() view returns (uint256)",
  "function motifChainId() view returns (uint256)", "function seedWindow() view returns (uint256)", "function ROYALTY_BPS() view returns (uint256)",
  "function totalSupply() view returns (uint256)", "function name() view returns (string)", "function symbol() view returns (string)",
  "function description() view returns (string)", "function externalUrl() view returns (string)", "function imageBase() view returns (string)",
  "function ladder() view returns (uint256[6], bool)", "function rankName(uint256) view returns (string)"], p);
for (const f of ["auction", "motifs", "oneOfOne", "royaltyReceiver", "motifPrice", "motifChainId", "seedWindow", "ROYALTY_BPS", "totalSupply",
  "name", "symbol", "description", "externalUrl", "imageBase"]) console.log(f.padEnd(16), String(await b[f]()));
const [costs, open] = await b.ladder();
console.log("ladder".padEnd(16), costs.join(", "), "open", open);
for (let r = 1; r <= 6; r++) console.log(("rankName(" + r + ")").padEnd(16), await b.rankName(r));
console.log("runtime keccak".padEnd(16), ethers.keccak256(await p.getCode(at)));
'
```

- [ ] `auction`, `motifs` and `oneOfOne` are the three published addresses (orkhanart.eth's creations at `deployerNonce` + 2, + 0 and + 1).
- [ ] `royaltyReceiver` orkhanart.eth `0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac`, `motifPrice` 1000000000000000, `motifChainId` 1, `seedWindow` 8191, `ROYALTY_BPS` 750, `totalSupply` 0, `name` "Kilim Bazaar", `symbol` "KILIM".
- [ ] `description`, `externalUrl` and `imageBase` are the `bazaar` block's texts in `deploy/mainnet.json`, as `pnpm -s expected --config deploy/mainnet.json` prints them under `texts`.
- [ ] Before settlement: `ladder` 10, 30, 100, 300, 1000, 0, open false; `rankName(1)` to `(6)` Apprentice, Spinner, Weaver, Artisan, Dyer, The Master.
- [ ] `runtime keccak` is the same on both RPCs; it is the sealer's `KILIM_RUNTIME_HASH` below.

- [ ] **Before:**
  - A new sealer wallet that nothing else uses. The sealer refuses the auction's treasury and the Bazaar's royalty receiver.
  - 0.1 ETH in it, and `KILIM_BUDGET_ETH` 0.1 (the README's budget table).
  - One container on the host, a persistent named volume for the journal, and rolling updates off.
  - A trusted RPC, not a public one.
  - If possible, a second operator on another host and RPC, with `KILIM_DELAY_BLOCKS=100`.
- [ ] **After the creation:**
  - `KILIM_BAZAAR` is the address the script printed.
  - `KILIM_START_BLOCK` is the creation's block, read from its receipt. Never a later block.
  - `KILIM_RUNTIME_HASH` is the keccak256 of `eth_getCode(<bazaar>, "latest")`, read on two nodes, and the two agree.
  - `KILIM_CHAIN_ID` is 1, or 11155111 for Sepolia.
- [ ] **Start:**
  - The first log line names the sealer wallet, the Bazaar, the chain and window 8191. The deploy script refuses any other window on mainnet and Sepolia.
  - `/health` answers 200.
  - If it refuses with "runtime hash mismatch", "separate sealer wallet" or "Journal is locked", nothing was sent. Fix the cause and start again.
- [ ] **First kilim:** its `KilimSealed` comes from the sealer's wallet in block B+2, where B is the block it was made in. Only then link the Bazaar from the site.
- [ ] **Watch, for as long as kilims can be made:**
  - `ALERT` lines are forwarded, and `/health` is monitored.
  - At the low-budget alert, compare the journal's `spent` with the wallet's history before topping up.
  - Never delete or edit the journal.
