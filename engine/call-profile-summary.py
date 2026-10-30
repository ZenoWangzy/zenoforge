#!/usr/bin/env python3
"""Aggregate redacted scheduler command-profile TSV rows."""

import csv
import re
import sys
from collections import defaultdict
from pathlib import Path


FIELDS = [
    "boundary", "tick", "stage", "section", "ticket_category", "command",
    "effect", "callsite", "result",
]
SAFE = re.compile(r"^[A-Za-z0-9_.:-]+$")
COMMANDS = {"gh", "git", "jq", "node", "systemd-run"}
EFFECTS = {
    "api-read", "api-unknown", "external-read", "dispatch-write",
    "record-write", "other-write", "local",
}


def summarize(path: Path) -> int:
    totals = defaultdict(lambda: [0, 0, 0])
    with path.open(newline="", encoding="utf-8") as stream:
        for line_no, row in enumerate(csv.reader(stream, delimiter="\t"), 1):
            if len(row) != 11 or row[0] != "1":
                print(f"invalid profile row {line_no}", file=sys.stderr)
                return 2
            boundary, tick, stage, section, category, command, effect, site, elapsed, result = row[1:]
            if (
                not all(SAFE.fullmatch(value) for value in row[1:9])
                or category not in {"tick", "product", "pipeline-system", "unclassified"}
                or command not in COMMANDS
                or effect not in EFFECTS
                or not elapsed.isdigit()
                or not (result.isdigit() or result == "dry-run")
            ):
                print(f"invalid profile metadata row {line_no}", file=sys.stderr)
                return 2
            key = (boundary, tick, stage, section, category, command, effect, site, result)
            item = totals[key]
            item[0] += 1
            item[1] += int(elapsed)
            item[2] = max(item[2], int(elapsed))

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(FIELDS + ["calls", "total_ms", "max_ms"])
    for key in sorted(totals):
        writer.writerow(list(key) + totals[key])
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} PROFILE.tsv", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(summarize(Path(sys.argv[1])))
