#!/usr/bin/env python3
"""Print one line per rule (and per method for parametric rules) from a prover output.json."""
import json
import sys


def walk(name, node, out):
    if isinstance(node, str):
        out.append((name, node))
        return
    for key, val in node.items():
        if key in ("SUCCESS", "FAIL", "TIMEOUT", "UNKNOWN", "SANITY_FAIL", "SANITY_FAILED"):
            for m in val:
                out.append((f"{name} :: {m}", key))
        else:
            walk(f"{name} / {key}" if name else key, val, out)


def main(path):
    rules = json.load(open(path))["rules"]
    out = []
    for rule, node in sorted(rules.items()):
        if rule == "envfreeFuncsStaticCheck":
            continue
        walk(rule, node, out)
    counts = {}
    for name, status in out:
        counts[status] = counts.get(status, 0) + 1
        print(f"{status:12} {name}")
    print("totals:", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    main(sys.argv[1])
