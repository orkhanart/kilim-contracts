#!/usr/bin/env bash
# The Medusa campaign and its Foundry twin, from contracts/: security/medusa/run.sh <build|fuzz|forge>.
# Every build goes to .tools-out/medusa/: contracts/out and contracts/cache are never written.
set -euo pipefail
CONTRACTS="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$CONTRACTS"
FORGE_DIR="$CONTRACTS/node_modules/.pnpm/@foundry-rs+forge-darwin-arm64@1.7.1/node_modules/@foundry-rs/forge-darwin-arm64/bin"
export PATH="$FORGE_DIR:$HOME/.local/bin:$PATH"
TOOLS="$CONTRACTS/.tools-out/medusa"
mkdir -p "$TOOLS"

case "${1:-}" in
  build)
    # Only the Medusa target and what it imports, with build info for crytic-compile. A clean build: an
    # incremental one leaves several build-info files and crytic-compile would hand Medusa a stale unit.
    case "$TOOLS" in */contracts/.tools-out/medusa) rm -rf "$TOOLS/out" "$TOOLS/cache" ;; *) exit 3 ;; esac
    FOUNDRY_OUT="$TOOLS/out" FOUNDRY_CACHE_PATH="$TOOLS/cache" FOUNDRY_TEST=security/medusa \
      forge build --build-info --out "$TOOLS/out" --cache-path "$TOOLS/cache" \
      security/medusa/recon/CryticTester.sol
    ;;
  fuzz)
    # run.sh fuzz [seconds] [workers]: build, then fuzz under nice, kept awake.
    "$0" build
    SECS="${2:-0}"
    WORKERS="${3:-8}"
    caffeinate -i nice -n 10 medusa fuzz --config security/medusa/medusa.json \
      --timeout "$SECS" --workers "$WORKERS"
    ;;
  forge)
    # run.sh forge [forge test args...]: the same suite under Foundry's invariant runner. forge test keeps
    # its failure records outside cache_path (cache/test-failures, cache/invariant, cache/fuzz by default),
    # so those are redirected too.
    shift
    FOUNDRY_OUT="$TOOLS/forge-out" FOUNDRY_CACHE_PATH="$TOOLS/forge-cache" FOUNDRY_TEST=security/medusa \
      FOUNDRY_TEST_FAILURES_FILE="$TOOLS/forge-cache/test-failures" \
      FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$TOOLS/forge-cache/invariant" \
      FOUNDRY_FUZZ_FAILURE_PERSIST_DIR="$TOOLS/forge-cache/fuzz" \
      nice -n 10 forge test --out "$TOOLS/forge-out" --cache-path "$TOOLS/forge-cache" \
      --match-path 'security/medusa/*' "$@"
    ;;
  *)
    echo "usage: security/medusa/run.sh build | fuzz [seconds] [workers] | forge [forge test args]" >&2
    exit 2
    ;;
esac
