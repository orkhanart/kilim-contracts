#!/usr/bin/env python3
"""Summarise Medusa's lcov for the four Kilim contracts: per-function hits, line coverage, and every
source line inside src/ that the campaign never executed. Run from contracts/:

    python3 security/medusa/coverage_summary.py [lcov.info] [--sources DIR]

--sources DIR prints line text from DIR/<file name> instead of the file on disk: use it when src/ changed
after the campaign was compiled (Medusa reports lines of the source it read at start-up).
"""
import sys
from pathlib import Path

ARGS = sys.argv[1:]
SOURCES = None
if "--sources" in ARGS:
    i = ARGS.index("--sources")
    SOURCES = Path(ARGS[i + 1])
    del ARGS[i:i + 2]
LCOV = Path(ARGS[0] if ARGS else "security/medusa/corpus/coverage/lcov.info")
TARGETS = ("src/auction/EnglishAuction.sol", "src/KilimAuction.sol", "src/KilimMotifs.sol",
           "src/KilimOneOfOne.sol", "src/KilimBazaar.sol")


def parse(path):
    files, cur = {}, None
    for raw in path.read_text().splitlines():
        tag, _, rest = raw.partition(":")
        if tag == "SF":
            cur = files.setdefault(rest, {"fn": {}, "fnda": {}, "da": {}})
        elif tag == "FN" and cur is not None:
            line, name = rest.split(",", 1)
            cur["fn"][name] = int(line)
        elif tag == "FNDA" and cur is not None:
            hits, name = rest.split(",", 1)
            cur["fnda"][name] = int(hits)
        elif tag == "DA" and cur is not None:
            line, hits = rest.split(",")[:2]
            cur["da"][int(line)] = int(hits)
    return files


def main():
    files = parse(LCOV)
    for target in TARGETS:
        match = [f for f in files if f.endswith(target)]
        if not match:
            print(f"\n## {target}: not in the report")
            continue
        rec = files[match[0]]
        src_path = SOURCES / Path(match[0]).name if SOURCES else Path(match[0])
        src = src_path.read_text().splitlines()
        da = rec["da"]
        hit = sum(1 for h in da.values() if h > 0)
        print(f"\n## {target}: {hit}/{len(da)} instrumented lines executed ({100 * hit / max(len(da), 1):.1f}%)")
        print("functions (reached = 1):")
        for name, line in sorted(rec["fn"].items(), key=lambda kv: kv[1]):
            print(f"  {rec['fnda'].get(name, 0):>10}  {name} (line {line})")
        missed = [n for n, h in sorted(da.items()) if h == 0]
        if missed:
            print("lines never executed:")
            for n in missed:
                print(f"  {n:>5}: {src[n - 1].strip()[:110]}")


if __name__ == "__main__":
    main()
