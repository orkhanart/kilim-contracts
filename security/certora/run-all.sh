#!/bin/sh
# Run every conf, one after another, with the local prover. Prints one totals line per conf and
# records the hashes of the sources that were verified in results/sources.sha256.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
mkdir -p results
(cd ../.. && shasum -a 256 src/auction/EnglishAuction.sol src/KilimAuction.sol src/KilimBazaar.sol) > results/sources.sha256
for c in Auction Solvency SelfCalls Motifs MotifRanges Parametric Reachability MinimumBid Bazaar; do
    printf '%-13s ' "$c"
    ./run.sh "confs/$c.conf" || true
done
