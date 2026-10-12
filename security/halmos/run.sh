#!/usr/bin/env bash
# Runs the Halmos symbolic tests in security/halmos with their own build folders.
# NEVER builds into contracts/out or contracts/cache (a live test reads ABIs from contracts/out).
# Usage: security/halmos/run.sh [extra halmos args...]   e.g.  --match-contract AuctionMathHalmos
set -euo pipefail
CONTRACTS="$(cd "$(dirname "$0")/../.." && pwd)"
FORGE_BIN="$CONTRACTS/node_modules/.pnpm/@foundry-rs+forge-darwin-arm64@1.7.1/node_modules/@foundry-rs/forge-darwin-arm64/bin"
HALMOS_VENV_BIN="$HOME/.local/share/uv/tools/halmos/bin" # yices-smt2 and z3 ship here with halmos
OUT="$CONTRACTS/.tools-out/halmos/out"
export PATH="$FORGE_BIN:$HALMOS_VENV_BIN:$PATH"
export FOUNDRY_OUT="$OUT"
export FOUNDRY_CACHE_PATH="$CONTRACTS/.tools-out/halmos/cache"
export FOUNDRY_TEST=security/halmos
export FOUNDRY_SCRIPT=security/halmos
cd "$CONTRACTS"
export PYTHONUNBUFFERED=1
exec nice -n 10 "$HOME/.local/bin/halmos" --root "$CONTRACTS" --forge-build-out "$OUT" "$@"
