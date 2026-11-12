#!/usr/bin/env python3
"""Per-unit machine signals for the observer: overturned, repair, rereview, reverted.

Read-only. Each signal is True, False or None (unknown). Missing evidence makes only
that signal None; the others are still filled. Usage: unit_signals.py <unit-id> [--runtime DIR] [--repo DIR]"""
import argparse
import json
import os
import re
import sys

import ledger_history
import roi_rollup

BLOCKING_VERDICTS = frozenset(("review-request-changes", "review-block"))
REVIEW_VERDICTS = BLOCKING_VERDICTS | {"review-approve"}
REPAIR_STAGES = frozenset(("repair-delivered", "repair-no-push"))
SHA_RE = re.compile(r"[0-9a-f]{40}")


def _history_stages(unit):
    history = unit.get("history")
    if not isinstance(history, list):
        return None
    return [entry.get("stage") for entry in history if isinstance(entry, dict)]


def unit_signals(unit, reverted):
    """One unit dict and the reverted-SHA map (None when git could not be read) -> stage, prompt and signals."""
    stages = _history_stages(unit)
    signals = {"overturned": None, "repair": None, "rereview": None, "reverted": None}
    if stages is not None:
        # A supervisor approve while the last review verdict still blocks overrules that verdict.
        blocked = overturned = repaired = rereviewed = False
        for stage in stages:
            if stage in BLOCKING_VERDICTS:
                blocked = True
            elif stage == "review-approve":
                blocked = False
            elif stage == "supervisor-approve" and blocked:
                overturned = True
            if stage in REPAIR_STAGES:
                repaired = True
            elif stage in REVIEW_VERDICTS and repaired:
                rereviewed = True
        signals.update(overturned=overturned, repair=repaired, rereview=rereviewed)
    sha = unit.get("merge_sha") or unit.get("land_sha")
    if stages is not None and "merge-reverted" in stages:
        signals["reverted"] = True
    elif isinstance(sha, str) and SHA_RE.fullmatch(sha) and reverted is not None:
        signals["reverted"] = sha in reverted
    return {"unit": unit.get("id"), "stage": unit.get("stage"), "prompt": unit.get("prompt"), "signals": signals}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("unit_id")
    parser.add_argument("--runtime", default=os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR", ""))
    parser.add_argument("--repo", default="", help="git checkout for the reverted signal; unset leaves it null")
    args = parser.parse_args(argv)
    units = [unit for unit in ledger_history.load_units(args.runtime) if unit.get("id") == args.unit_id]
    if not units:
        print(json.dumps({"unit": args.unit_id, "error": "unit not found"}), file=sys.stderr)
        return 2
    reverted = roi_rollup._reverted_shas(args.repo) if args.repo else None
    print(json.dumps(unit_signals(units[0], reverted), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
