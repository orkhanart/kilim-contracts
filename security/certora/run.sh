#!/bin/sh
# Run one Certora conf with the LOCAL prover built from source. Never uses Certora's cloud.
# Usage (from anywhere):  contracts/security/certora/run.sh confs/Solvency.conf [extra certoraRun args]
# Writes: results/<conf>.log (full prover output), results/<conf>.output.json (rule results),
#         results/<conf>.summary.txt (one line per rule/method), work/<conf>/ (full report, ~1 GB, gitignored).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$HOME/.local/certora/env.sh"
unset CERTORAKEY
jar="$CERTORA/emv.jar"
[ -f "$jar" ] || { echo "local prover jar missing: $jar (build it first, see README.md)" >&2; exit 2; }
conf=$1; shift
cd "$here"
heap="${CERTORA_HEAP:--Xmx32g}"
name="${RUN_NAME:-$(basename "$conf" .conf)}"
# KILIM_SRC: the contracts the harness imports as kilim/ (default: the frozen src/; mutants.py points it at a mutant copy).
src="${KILIM_SRC:-$here/../../src}"
mkdir -p results "work/$name"
# Each run gets its own working directory so parallel runs do not share .certora_internal or emv-* folders.
rm -rf "work/$name"; mkdir -p "work/$name"
cd "work/$name"
# Paths in the conf are relative to security/certora; run from a fresh copy of harness/ and specs/
# so that several confs can run at once without sharing .certora_internal or emv-* folders.
cp -R "$here/harness" "$here/specs" .
# --jar forces the local jar; certoraRun only goes to the cloud when no local jar is configured,
# and the cloud path would also need a CERTORAKEY, which is unset above.
set +e
nice -n 10 certoraRun.py "../../$conf" --jar "$jar" --java_args "$heap" \
    --packages "@openzeppelin/contracts=$here/../../node_modules/@openzeppelin/contracts" "kilim=$src" \
    --solc_allow_path "$here/../.." "$@" > "$here/results/$name.log" 2>&1
rc=$?
set -e
out=$(ls -d emv-*/Reports/output.json 2>/dev/null | tail -1 || true)
if [ -n "$out" ]; then
    cp "$out" "$here/results/$name.output.json"
    python3 "$here/summarize.py" "$out" > "$here/results/$name.summary.txt"
    tail -1 "$here/results/$name.summary.txt"
else
    echo "no output.json; see results/$name.log" >&2
fi
exit $rc
