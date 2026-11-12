#!/usr/bin/env python3
# Unattended /retro stage, slice 1: pick the newest finished luna workers, then keep only the candidates that cite a real event line.
# Usage: retro.py select <scratch-root> <n>            prints the chosen session keys, sorted
#        retro.py filter <scratch-root> <keys> <raw.json> <out.json>   writes kept candidates and drop counts
import glob
import json
import os
import sys
from collections import Counter

CATEGORIES = {"navigation", "automated-checks", "coding-standards", "global-agents-md",
              "tool-economy", "no-ops", "information-access"}
SEVERITIES = {"low", "medium", "high"}


def select(root, n):
    done = []
    for d in glob.glob(os.path.join(root, "luna", "*")):
        key = os.path.basename(d)
        rc = os.path.join(d, "rc")
        # rc is written when a worker ends; a retro run is not an input to the next retro.
        if key.startswith("retro-") or not os.path.isfile(rc):
            continue
        done.append((os.path.getmtime(rc), key))
    done.sort(reverse=True)
    return sorted(key for _, key in done[:n])


def event_lines(root, key):
    path = os.path.join(root, "luna", key, "events.jsonl")
    if not os.path.isfile(path):
        return 0
    with open(path, encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


def filter_candidates(root, keys, raw):
    dropped = Counter()
    kept = []
    counts = {}
    for c in raw.get("candidates", []):
        if not isinstance(c, dict):
            dropped["malformed"] += 1
            continue
        key = c.get("session_key")
        line = c.get("event_line")
        if c.get("category") not in CATEGORIES:
            dropped["bad_category"] += 1
        elif c.get("severity") not in SEVERITIES:
            dropped["bad_severity"] += 1
        elif key not in keys:
            dropped["unknown_session"] += 1
        elif not isinstance(line, int) or isinstance(line, bool):
            dropped["no_event_position"] += 1
        else:
            if key not in counts:
                counts[key] = event_lines(root, key)
            if not 1 <= line <= counts[key]:
                dropped["event_line_out_of_range"] += 1
            elif not isinstance(c.get("proposal"), str) or not c["proposal"].strip():
                dropped["missing_proposal"] += 1
            else:
                kept.append(c)
    return {"candidates": kept, "dropped": dict(dropped), "total": len(kept) + sum(dropped.values())}


def main(argv):
    if len(argv) >= 4 and argv[1] == "select":
        print("\n".join(select(argv[2], int(argv[3]))))
        return 0
    if len(argv) == 6 and argv[1] == "filter":
        root, keys_file, raw_file, out_file = argv[2:]
        with open(keys_file, encoding="utf-8") as f:
            keys = {k.strip() for k in f if k.strip()}
        with open(raw_file, encoding="utf-8") as f:
            raw = json.load(f)
        result = filter_candidates(root, keys, raw)
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write("\n")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
