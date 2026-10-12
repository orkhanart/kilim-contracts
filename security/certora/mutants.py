#!/usr/bin/env python3
"""Hand-made mutants: does each spec catch the bug it is meant to catch?

Each mutant copies contracts/src to work/mutants/<id>/src (gitignored), applies ONE source edit there,
and runs the named spec against the copy (run.sh with KILIM_SRC). The frozen src/ is never touched.
A mutant is "killed" when at least one of the expected rules is violated.

Usage: python3 mutants.py [mutant-id ...]      (default: all)
Writes results/mutants.txt.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "src"))
EA = "auction/EnglishAuction.sol"
KA = "KilimAuction.sol"

# id: (file, original text, mutated text, conf, rules to run, what it models)
MUTANTS = {
    "settle-twice": (
        EA, "        if (settled) revert AlreadySettled();\n", "",
        "Solvency", ["solvency", "prizeMintedAtMostOnce"],
        "settle() can run again after the proceeds were paid",
    ),
    "proceeds-not-zeroed": (
        EA, "        proceedsDue = 0;\n        _pay(to, amount);", "        _pay(to, amount);",
        "Solvency", ["solvency"],
        "withdrawProceeds pays without clearing proceedsDue",
    ),
    "refund-not-cleared": (
        EA, "        refunds[msg.sender] = 0;\n", "",
        "Solvency", ["refundLiabilityIsSumOfRefunds", "solvency"],
        "withdrawRefund pays without clearing the caller's refund",
    ),
    "deferred-not-counted": (
        EA, "            refundLiability += amount;\n", "",
        "Solvency", ["refundLiabilityIsSumOfRefunds", "refundAtMostLiability"],
        "a deferred refund is not added to refundLiability",
    ),
    "deferred-not-recorded": (
        EA, "            refunds[bidder] += amount;\n", "",
        "Solvency", ["refundLiabilityIsSumOfRefunds"],
        "a failed push refund is counted in the total but not credited to the bidder",
    ),
    "refund-dropped": (
        EA, "            refunds[bidder] += amount;\n            refundLiability += amount;\n", "",
        "Auction", ["bidRefundsOutbidBidder"],
        "a failed push refund is silently dropped (the bidder loses it, the books still balance)",
    ),
    "refund-twice": (
        EA, "            emit RefundPaid(bidder, amount);",
        "            refunds[bidder] += amount;\n            refundLiability += amount;\n            emit RefundPaid(bidder, amount);",
        "Solvency", ["solvency"],
        "a paid refund is also recorded as deferred (paid twice)",
    ),
    "no-close-check": (
        EA, "        if (started && block.timestamp >= endsAt) revert AuctionNotOpen();\n", "",
        "Auction", ["bidTiming"],
        "bids accepted after the close",
    ),
    "refund-wrong-bidder": (
        KA, "        _refundOutbid(outbid, outbidAmount);", "        _refundOutbid(msg.sender, outbidAmount);",
        "Auction", ["bidRefundsOutbidBidder"],
        "the outbid amount is refunded to the new bidder",
    ),
    "self-call-open": (
        EA, "        if (msg.sender != address(this)) revert Unauthorized();\n        _pay(bidder, amount);",
        "        _pay(bidder, amount);",
        "SelfCalls", ["payOutbidRefundOnlyBySelf"],
        "anyone can call payOutbidRefund",
    ),
    "treasury-check-dropped": (
        EA, "        if (msg.sender != treasury) revert Unauthorized();\n", "",
        "Auction", ["withdrawProceedsRevertsForOthers", "withdrawProceedsOnlyTreasuryOnce"],
        "anyone can withdraw the proceeds",
    ),
    "reward-uncapped": (
        KA, "Math.min(Math.min(amount / MOTIF_PRICE, maxMotifsPerBid), motifCap - motifsAllocated)",
        "Math.min(amount / MOTIF_PRICE, maxMotifsPerBid)",
        "Motifs", ["motifAllocationWithinCap"],
        "rewards ignore the motif cap",
    ),
    "claim-keeps-credits": (
        KA, "        motifCredits[bidder] -= quantity;\n", "",
        "Motifs", ["creditsMatchAllocation", "claimMotifsNeverExceedsCredits"],
        "claimMotifs mints without spending credits",
    ),
    "prize-claim-twice": (
        KA, "        if (prizeClaimed) revert PrizeAlreadyClaimed();\n", "",
        "Solvency", ["prizeMintedAtMostOnce"],
        "the winner can claim the 1/1 again",
    ),
    "withdraw-unguarded": (
        EA, "    function withdrawRefund(address to) external nonReentrant {",
        "    function withdrawRefund(address to) external {",
        "SelfCalls", ["reentryReverts"],
        "withdrawRefund loses its reentrancy guard",
    ),
}


def violated(output_json):
    data = json.load(open(output_json))["rules"]
    hits = []

    def walk(name, node):
        if isinstance(node, str):
            if node in ("FAIL",):
                hits.append(name)
            return
        for key, val in node.items():
            if key == "FAIL":
                hits.extend(f"{name} :: {m}" for m in val)
            elif isinstance(val, (dict, str)):
                walk(f"{name} / {key}", val)

    for rule, node in data.items():
        walk(rule, node)
    return hits


def main(ids):
    lines = []
    for mid in ids:
        path, old, new, conf, rules, what = MUTANTS[mid]
        root = os.path.join(HERE, "work", "mutants", mid)
        shutil.rmtree(root, ignore_errors=True)
        shutil.copytree(SRC, os.path.join(root, "src"))
        target = os.path.join(root, "src", path)
        text = open(target).read()
        assert text.count(old) == 1, f"{mid}: pattern not unique in {path}"
        open(target, "w").write(text.replace(old, new))
        env = dict(os.environ, KILIM_SRC=os.path.join(root, "src"), RUN_NAME=f"mutant-{mid}")
        args = [os.path.join(HERE, "run.sh"), f"confs/{conf}.conf", "--rule", *rules,
                "--msg", f"mutant {mid}"]
        subprocess.run(args, env=env, cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = os.path.join(HERE, "results", f"mutant-{mid}.output.json")
        if not os.path.exists(out):
            line = f"ERROR   {mid:24} no result (see results/mutant-{mid}.log)"
        else:
            hits = violated(out)
            status = "KILLED " if hits else "SURVIVED"
            line = f"{status} {mid:24} {what}; violated: {', '.join(hits) if hits else 'none'}"
        print(line, flush=True)
        lines.append(line)
    with open(os.path.join(HERE, "results", "mutants.txt"), "a") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:] or list(MUTANTS))
