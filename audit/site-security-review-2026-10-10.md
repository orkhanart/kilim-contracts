# Website security review, 10 October 2026

Scope: everything that ships to a visitor of kilim.orkhan.art / orkhan.art/kilim, and the two
services behind it. Not the contracts (they have their own review). Read-only; nothing was changed.

- `site/` (the built pages, `chain.js`, `rpc.js`, `abi.js`, `auction.js`, `auction-info.js`,
  `notify.js`, `mode.js`, `landing-chain.js`, `afterglow*.js`, `flat-viewer.js`, `lib.js`,
  `motifs.js`, `build.py`, `chains/*.json`, `vendor/`)
- `landing-departure/` (the chosen landing page, Vite + React)
- `registration-relayer/` and `afterglow-server/`
- Dependencies and lockfiles of every package that ships or builds the site
- The live hosts: response headers of orkhan.art, DNS of kilim.orkhan.art

Method: four parallel reviewers, one per surface (wallet and transaction flow; DOM injection;
the two Node services; supply chain and build pipeline), every input traced to every sink. Every
finding below was then re-read in the source by hand. Confidence threshold: concrete exploit path
only. Excluded: denial of service, rate limiting, hardening without an injection to pair with.

## Verdict

**No new High finding. Nothing in the site can send a transaction anywhere but the embedded
auction address, nothing renders attacker-controlled HTML, no dependency is tampered, no secret is
in the tree.** The items that must be closed before the live build are the three already logged in
AUDIT.md as W-01, W-03 and W-05 (all still open in the code as of commit `2ceaf9cd`), plus the
hosting headers, which live in the orkhan.art repo, not here.

## Fixed the same day

Commit after this review, all with tests in `site/test/site-review.test.mjs` and
`site/test/afterglow-access.test.mjs`, run against a real local anvil:

- Finding 1 (W-01): `init()` reads `minter()` on both token contracts and refuses anything but the
  configured auction. A deployed `RogueAuction` stops the page before any write.
- Finding 2 (W-05): `bid()` re-reads `minimumBid()` and `rewardForBid()` through the wallet's own
  provider right before the prompt and refuses on disagreement. A second RPC URL in both configs
  (W-06).
- Finding 3 (W-03): `guardWrite()` refuses every write until the immutables are verified.
- Finding 4: the Afterglow page checks the challenge is this origin's entry message for the
  connected wallet, chain and challenge id before signing.

Still open: 5 (the build gate, to lift deliberately on launch day) and 6 (hosting headers, in the
orkhan.art repo).

## Findings

### 1. W-01, still open: startup never checks `minter()` on the two token contracts

- Severity: Medium (latent: no public build can send a bid today, see 5)
- Where: `site/chain.js:126-160` (`init()`); `grep minter site/chain.js` is empty although
  `minter` is in the ABI at `site/abi.js:399` and `:411`.
- Description: `init()` reads `auction.motifs()` and `auction.oneOfOne()` and compares them with
  the config, then checks the grids and names hashes on the real token contracts. A rogue auction
  that answers those two calls with the real token addresses passes every check, and every bid
  (`plan()` at `chain.js:693-704`, `to: cfg.auction`) goes to it.
- Exploit: a tampered `site/chains/1.json` or a tampered build (a compromised orkhan.art deploy, a
  wrong address pasted on deploy day). `site-config.mjs` does check `minter()` before writing the
  config (`contracts/scripts/site-config.mjs:69-83`), so the page is the only layer missing it.
- Fix: add `[cfg.motifs, FG.minter]` and `[cfg.oneOfOne, FO.minter]` to the `readMany` batch in
  `init()` and fail with a `Startup` error unless both equal `cfg.auction`.

### 2. W-05, still open: one read RPC decides the ETH value the bidder signs

- Severity: Medium (latent)
- Where: `site/auction.js:315-321` prefills the bid field from `minimumBid()`; `:59-61` the
  "Requote" button sets it from the `BidTooLow` revert args; `chain.js:573-581` simulates on the
  same RPC. `site/chains/1.json` names one URL (`ethereum-rpc.publicnode.com`), so the transport's
  failover never runs (W-06).
- Exploit: a compromised or intercepted read RPC answers `minimumBid() = 5 ETH`. The field reads
  5 ETH, the page calls it the minimum, the wallet shows 5 ETH to the real auction. The money lands
  in the genuine contract, so the attacker cannot take it, but the bidder overpays and, if not
  outbid, wins at that price. A lying `rewardForBid()` passes simulation and reverts on-chain
  (gas lost).
- Fix: before the wallet prompt, re-read `minimumBid()` and `rewardForBid()` through the connected
  wallet's provider and refuse if they disagree with the quote; add a second independent RPC URL;
  require the bidder to type when the prefill jumps by more than a sane factor.

### 3. W-03, still open: five writes can be sent before startup has verified the contracts

- Severity: Low (loss is gas; `to` is always the embedded address)
- Where: `site/chain.js:503-511` (`guardWrite()`) checks `deployed`, `S.fatal`, `writesDisabled`,
  the void list, wallet and wallet chain, but not `S.imm`. `register`, `withdrawRefund`, `settle`,
  `claimPrize`, `withdrawProceeds` (`:1008-1021`) go through while `init()` is still retrying.
  `bid` is protected by `quote()`.
- Fix: `if (!S.imm) throw KilimError('Startup', 'Still checking the contracts.')` in `guardWrite()`.

### 4. Afterglow: the wallet signs whatever string the room API sends

- Severity: Low (new; `personal_sign` only, cannot be a transaction or a permit)
- Where: `site/afterglow-access.js:180-193`. The only client-side checks are non-empty and
  under 8,192 characters. The server builds a good message (`afterglow-server/server.mjs:280`:
  origin, wallet, chain, nonce, expiry, "not a transaction"), but the page does not verify it.
- Exploit: a compromised afterglow proxy on orkhan.art presents a Sign-In-With-Ethereum message
  for another dapp; the collector sees it only in the wallet dialog. Login impersonation on that
  dapp, no funds.
- Fix: require the message to start with a fixed site line and to contain the connected address,
  the chain id and the challenge id; cap it at a few hundred characters; show it on the page before
  the wallet prompt.

### 5. Launch path: no public build can go live (W-02, still open)

- Severity: operational, not a vulnerability. Recorded because the fix will be made under pressure.
- Where: `site/build.py:273-274` fails any non-dev build whose chain config has addresses, and
  `:341-347` composes the public auction page from read-only `auction-info.js`. The documented
  path (`pnpm site-config`, `python3 site/build.py`, `sync_orkhanart.py`) therefore cannot
  produce a bidding page.
- Risk: the gate is removed in a hurry and the checks around it (`load_chain`, `check_published`)
  go with it.
- Fix: lift the gate in its own reviewed commit, after 1 to 3 above are in, and run the site tests
  on the live build.

### 6. Hosting: orkhan.art sends no security headers

- Severity: Low on its own (there is no injection for it to amplify), but it is the one control
  that would contain a future one.
- Observed 10 October 2026, `curl -D - https://orkhan.art/kilim`: no `Content-Security-Policy`,
  no `Strict-Transport-Security`, no `X-Frame-Options`, no `X-Content-Type-Options`,
  no `Referrer-Policy`. HTTP does redirect to HTTPS. `kilim.orkhan.art` has no DNS record yet.
- Fix (in the orkhan.art repo): HSTS; a CSP for `/kilim*` that allows `'self'`, inline scripts
  (the pages inline everything, so use a hash or nonce, or `'unsafe-inline'` as a first step),
  `connect-src` to the configured RPC and the same-origin APIs, `style-src`/`font-src` for Google
  Fonts, `frame-ancestors 'none'`. When kilim.orkhan.art is created, point it at the same host in
  the same change (an unclaimed CNAME to a hosting provider is a subdomain takeover).

## Housekeeping (no security impact, remove before launch)

- `site/dist/orkhanart/` and `landing-departure/dist/` are stale pre-rename builds ("glyphs");
  both are gitignored and `sync_orkhanart.py` always rebuilds, so they ship only if copied by hand.
- `site/chains/31337.json` and `contracts/deploy/poc-slow-flag.json` still use the `glyphs` key;
  `build.py --dev` fails on it until `pnpm dev:chain` rewrites it.
- `explorer` and `registrationRelayer` in the chain config are not validated by `build.py`
  (only `rpcUrls` is). The page enforces `https:` on the relayer at runtime and `explorer` only
  reaches `wallet_addEthereumChain`, so no injection; add the checks to `load_chain` anyway.
- No `.npmrc` with `ignore-scripts=true` in the three npm packages. The only lifecycle script in
  any lockfile is `fsevents@2.3.3` (dev, optional). `contracts/pnpm-workspace.yaml` already
  disallows builds for the Foundry packages.

## Verified safe

Wallet and transaction flow
- Every transaction has `to: cfg.auction` from the embedded config (`chain.js:701, 741,
  1018-1021`). Nothing from the URL, the RPC, logs, ENS or the explorer becomes a recipient or
  calldata. Claim and withdraw recipients come from the bidder's own typed input, EIP-55 checked.
- Gas is constant (1.5M bid, 1.2M settle, `chain.js:18`). Value is `parseEth` of the field only.
- `?chain=` must be digits and a key of the embedded `KILIM_CHAINS`; there is no remote config.
- `walletTx` stamps `chainId` on every transaction; `checkSigner` re-asks the wallet for its chain
  and account right before each prompt and aborts on change.
- The only typed-data signature is the EIP-712 `Register(address wallet,uint256 deadline)` with
  `verifyingContract: cfg.auction`; it can only call `register` for that wallet. No `eth_sign`.
- Operator levers (`notice`, `writesDisabled`, `void`) are enforced in `guardWrite`; `notice` is
  rendered as text.

DOM
- No `eval`, `new Function`, `document.write`, string timers, `postMessage` listeners or
  `window.name` use. The two `innerHTML` writes (`afterglow.js:122, 248`) are constant strings.
- All chain, RPC, wallet and config strings reach the page through `textContent`,
  `replaceChildren` or text nodes. Revert reasons map to names in the static ABI.
- The site never fetches or renders `tokenURI`; held tokens are drawn on canvas from the local,
  hash-verified grid data. No iframe, object, srcdoc or `data:text/html` in `site/`. The two
  landing iframes load the same-origin artwork with numeric and enum query parameters only.
- Explorer links are embedded base plus a `/^0x[0-9a-f]{64}$/` hash, `rel="noopener noreferrer"`.
  Wallet icons are limited to `data:image/(svg+xml|png|webp)` under 200 KB in an `<img>`.
- Sign-up posts only an email to the same-origin `/api/newsletter`; the response is regex-tested,
  never rendered.

Services
- Relayer: body must be exactly `{deadline, signature, wallet}`, each regex-checked; `to`, value,
  gas, chain and nonce are fixed server-side; the auction's bytecode hash is pinned at startup; the
  signature is checked by the contract itself inside the signed struct, so it cannot register
  another wallet; replay blocked on-chain and by the journal; the sponsor key comes from env only
  and is never logged; spend is capped by the journal budget (0.02 ETH default).
- Afterglow: challenge bound to origin, wallet, chain, token ids, random nonce and a 3-minute
  expiry, deleted before the first `await` on join; `/join` takes no address; ERC-1271 only for
  deployed code with the exact magic value; static serving is allow-listed and `realpath`-confined;
  gesture fields are range-checked and all identifiers are server-generated; cookies `HttpOnly;
  SameSite=Strict`; no `X-Forwarded-*` trust.

Supply chain and build
- Every lockfile entry resolves from `registry.npmjs.org` with `sha512` integrity, and the registry
  integrity matched the lockfile for every direct and transitive package checked. `npm audit` /
  `pnpm audit --prod`: 0 advisories in all four packages. Maintainers match upstream for Foundry,
  OpenZeppelin 5.6.1, solc 0.8.37, ethers 6.17.0, react 19.3.0, vite 8.3.4, js-sha3 0.8.0.
- `site/vendor/js-sha3-0.8.0/sha3.min.js` is byte-identical to `build/sha3.min.js` in the
  registry tarball (file SHA-256 `f0ca4875…de84`, tarball `e7553c17…5fa4`, tarball SHA-512 equals
  the registry `dist.integrity`); `build.py` pins the same hash and fails on mismatch.
- `build.py` reads only repo files, embeds no environment variables, JSON-serialises config with
  `</` escaped, verifies `motifs.js` against its keccak hashes, and refuses dev wallets, local RPCs
  and stale copy in public builds. The tracked built pages are byte-identical to a fresh build.
  No sourcemaps in `landing-departure/dist`.
- No tracked `.env`, keystore or keyed RPC URL; the only private key in the tree is the anvil test
  key in a test file. The deployer signs with a Ledger (`checklists/2-deploy.md`). No CI workflow,
  no `curl | sh`, no `foundryup`; Foundry binaries come from the lockfile package.
- Third-party runtime dependencies of a visitor: the configured public RPC and the Google Fonts
  stylesheet (CSS only, cannot run script). All first-party JavaScript is inlined.
