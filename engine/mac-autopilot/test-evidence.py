#!/usr/bin/env python3
"""Pass-only test evidence keyed by Git tree and the exact test target."""

import fcntl
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import sys


def has_pass(ledger: Path, tree: str, target: str) -> bool:
    try:
        with ledger.open(encoding="utf-8") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_SH)
            for line in stream:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if record.get("tree") == tree and record.get("target") == target and record.get("result") == "pass":
                    return True
    except FileNotFoundError:
        return False
    return False


def record_pass(ledger: Path, tree: str, target: str, source: str) -> None:
    ledger.parent.mkdir(parents=True, exist_ok=True)
    record = json.dumps(
        {
            "tree": tree,
            "target": target,
            "result": "pass",
            "source": source,
            "recorded_at": datetime.now(timezone.utc).isoformat(),
        },
        separators=(",", ":"),
    ) + "\n"
    fd = os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, record.encode("utf-8"))
    finally:
        os.close(fd)


def main() -> int:
    if sys.argv[1:2] == ["has"] and len(sys.argv) == 5:
        action, ledger, tree, target = sys.argv[1:5]
        source = ""
    elif sys.argv[1:2] == ["record"] and len(sys.argv) == 6:
        action, ledger, tree, target, source = sys.argv[1:6]
    else:
        print("usage: test-evidence.py has|record <ledger> <tree-id> <target> [source]", file=sys.stderr)
        return 64
    if not tree or not target:
        print("test evidence requires a tree id and target", file=sys.stderr)
        return 64
    if action == "has":
        return 0 if has_pass(Path(ledger), tree, target) else 1
    record_pass(Path(ledger), tree, target, source)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as error:
        print(f"test evidence ledger unavailable: {error}", file=sys.stderr)
        sys.exit(2)
