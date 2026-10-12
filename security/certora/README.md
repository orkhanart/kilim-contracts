# Certora specs for the Kilim auction (local prover only)

Formal rules for `src/auction/EnglishAuction.sol` + `src/KilimAuction.sol` (and, as a stretch, the rank
rule and seal of `src/KilimBazaar.sol`), checked with the **open-source Certora Prover built from source
on this machine**. Nothing is uploaded to Certora's cloud: the confs carry no `server`, `run.sh` passes the
local jar with `--jar` and unsets `CERTORAKEY`, and the jar's event stream is switched off
(`-enableEventReporting false`). Results and the analysis are in
[`../../audit/tools-2026-10-12/certora.md`](../../audit/tools-2026-10-12/certora.md).

Nothing here writes to `contracts/out` or `contracts/cache`, and nothing in `src/`, `test/`, `script/`,
`deploy/`, `scripts/` or `foundry.toml` is changed: the prover compiles the sources itself with solc, into
`work/` below this folder.

## Layout

| Path | What |
| --- | --- |
| `harness/KilimAuctionHarness.sol` | `KilimAuction` unchanged, plus two views: the reentrancy guard state and the upstream bid predicate `_isNewWinningBid` applied to an amount. |
| `harness/OneOfOneMock.sol` | Stand-in for `KilimOneOfOne.mint`: counts mints, may reject any recipient. |
| `harness/KilimBazaarHarness.sol` | `KilimBazaar` unchanged (the specs read its private storage directly). |
| `specs/Base.spec` | Shared methods, summaries, ghosts, `configOk()` (what the constructors enforce) and `requireRealCaller(e)`. |
| `specs/Solvency.spec` | Invariants: solvency, ledger sums, lifecycle, prize, guard. |
| `specs/Auction.spec` | Bid, refund, settlement, proceeds and 1/1 rules. |
| `specs/MinimumBid.spec` | `minimumBid()` against the bid predicate (nonlinear arithmetic; run apart). |
| `specs/Motifs.spec` | Motif credit invariants and `claimMotifs` rules. |
| `specs/MotifRanges.spec` | The reserved id ranges behind the credits (hook mirrors of the private arrays). |
| `specs/SelfCalls.spec` | `payOutbidRefund` / `deliverPrize` access, reentrancy. |
| `specs/Parametric.spec` | "Only X changes Y" over every external function. |
| `specs/Reachability.spec` | `satisfy` witnesses: the interesting paths are reachable in the model. |
| `specs/Bazaar.spec` | Kilim Bazaar rank rule and `seal()`. |
| `confs/*.conf` | One conf per spec. |
| `run.sh` | Runs one conf with the local prover; writes `results/<name>.{log,output.json,summary.txt}`. |
| `run-all.sh` | Runs every conf in turn; writes `results/final-run.txt` and `results/sources.sha256`. |
| `summarize.py` | One line per rule (and per method) from a prover `output.json`. |
| `mutants.py` | Hand-made mutants of a copy of `src/` (under `work/`) to check that the specs catch real bugs. |
| `results/` | The logs and results of the runs recorded in the report. |
| `work/` | Per-run prover folders (about 1 GB each, gitignored). |

## Toolchain (installed under `~/.local/certora`, nothing system-wide)

All downloads came from the projects' official release pages and were checked against the published
SHA-256 digests.

| Tool | Version | Where | Source / check |
| --- | --- | --- | --- |
| Certora Prover | 8.19.2 (tag commit `63fdea80a35b`) | source `~/.local/certora/CertoraProver`, build `~/.local/certora/install` (`$CERTORA`) | `git clone --branch 8.19.2` of github.com/Certora/CertoraProver, submodule `scripts/graphcore` over https |
| JDK (runtime and Gradle) | Temurin 21.0.12.1+1, macOS aarch64 | `~/.local/certora/jdk/jdk-21.0.12.1+1` | api.adoptium.net / github.com/adoptium; sha256 `3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998` |
| JDK (Gradle compile toolchain) | Temurin 19.0.2+7, macOS aarch64 | `~/.local/certora/jdk/jdk-19.0.2+7` | the build pins `java.version=19` as a Gradle toolchain; sha256 `c419330cc8d6b9974d3bf1937f8f0e747c34c469afd5c546831d35aa19e03d49` |
| Gradle | 7.2 (the repo's wrapper) | `~/.local/certora/gradle-home` (`GRADLE_USER_HOME`) | services.gradle.org; sha256 `f581709a9c35e9cb92e16f585d2c4bc99b2b1a5f85d2badbd3dc6bff59e1e6dd` |
| Z3 | 4.15.4, arm64-osx | `~/.local/certora/solvers/z3-4.15.4-arm64-osx-13.7.6` | github.com/Z3Prover/z3 release; sha256 `8bb3439772cafd75240d61abf255e89122850bab93563d1283b048359ab4e88f` |
| cvc5 | 1.4.2, macOS arm64 static | `~/.local/certora/solvers/cvc5-macOS-arm64-static` | github.com/cvc5/cvc5 release; sha256 `24397f7d022e755876ca836193d4c5f9c1d4326f0f6c01f7d7fc1ddd6bc5096c` |
| Rust | 1.99.0 (rustup, minimal profile) | `~/.local/certora/cargo`, `~/.local/certora/rustup` | sh.rustup.rs, `--no-modify-path` |
| rustfilt | 0.2.1 | `~/.local/certora/cargo/bin` | `cargo install rustfilt` (crates.io) |
| Python | 3.12.13 venv with `scripts/certora_cli_requirements.txt` | `~/.local/certora/venv` | uv |
| solc | 0.8.37+commit.f401782d (universal Mach-O) | `~/.local/certora/bin/solc8.37` → Foundry's `~/Library/Application Support/svm/0.8.37/solc-0.8.37` | sha256 `a27396e7732aa52e80ff89ad7bd8a2e46fec2a6dcc4ef20cd16e5e0c502d6821` |

`~/.local/certora/bin` holds the `z3`, `cvc5`, `solc8.37` links. `~/.local/certora/env.sh` sets `JAVA_HOME`,
`CARGO_HOME`, `RUSTUP_HOME`, `GRADLE_USER_HOME`, `CERTORA` and `PATH` for one shell, and unsets
`CERTORAKEY`. No shell profile was edited. llvm-symbolizer, llvm-dwarfdump and Graphviz were skipped (Solana
and report rendering only).

### Rebuilding the prover

```sh
. ~/.local/certora/env.sh
# Gradle finds the two JDKs through ~/.local/certora/gradle-home/gradle.properties:
#   org.gradle.java.installations.paths=<jdk-19 Home>,<jdk-21 Home>
#   org.gradle.java.installations.auto-download=false
#   org.gradle.java.installations.auto-detect=false
cd ~/.local/certora/CertoraProver
nice -n 10 ./gradlew assemble          # about 3 minutes; also builds fried-egg (tac_optimizer) with cargo
ls "$CERTORA"/emv.jar "$CERTORA"/tac_optimizer "$CERTORA"/certoraRun.py
```

Smoke test (the README example, plus one that exercises the SMT solvers):

```sh
cp -R ~/.local/certora/CertoraProver/Public/TestEVM/CVLCompilation/OptionalFunction /some/scratch/dir
cd /some/scratch/dir/OptionalFunction && certoraRun.py Default.conf     # matches expectedDefault.json
# Public/TestEVM/Counter with --solc solc8.37: both rules verified, matches expectedcounter.json
```

## Running the specs

```sh
cd contracts/security/certora
./run-all.sh                          # all nine confs, about 20 minutes on this machine
./run.sh confs/Solvency.conf          # or one: Auction, Solvency, SelfCalls, Motifs, MotifRanges,
                                      # Parametric, Reachability, MinimumBid, Bazaar
cat results/Solvency.summary.txt
python3 mutants.py                    # optional: every mutant should be KILLED
```

`run.sh` runs `certoraRun.py` under `nice -n 10` with a 32 GB Java heap (`CERTORA_HEAP=-Xmx16g ./run.sh ...`
to change it), from a fresh `work/<name>/` copy of `harness/` and `specs/`, so several confs can run at once.
Extra arguments go to certoraRun, for example `--rule solvency`. Each conf compiles with solc 0.8.37,
optimizer 200 runs, EVM `cancun`, no via-IR (the `foundry.toml` settings), and maps
`@openzeppelin/contracts` to `contracts/node_modules/@openzeppelin/contracts` (5.6.1) and `kilim/` to
`contracts/src`.

Run times on this machine (18 cores, shared with other jobs): one to four minutes per conf. MinimumBid
needs its `Math.mulDiv` summary: without it the same property times out after about ten minutes.
