#!/usr/bin/env bash
# factory_trend.py: archive keeps newest finished runs with the work order's outcome; trend days without data stay None,
# waste share counts tokens of tickets that never merged, first-pass rate comes from each unit's first review.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" <<'PY'
import sys, datetime; sys.path.insert(0, sys.argv[1]); import factory_trend as F
ev = lambda key, ts, tk, tickets, wall=60.0: {"event_type": "unit-end", "ts": ts, "wall_s": wall, "tickets": tickets,
    "unit": {"key": key, "stage": "repair", "backend": "codex"}, "models": [{"tokens": tk}]}
events = [ev("a", "2026-10-30T10:00:00Z", 100, [1]), ev("b", "2026-10-30T11:00:00Z", 300, [2]), ev("c", "2026-10-29T11:00:00Z", 50, [1])]
units = [{"id": "a", "title": "A", "stage": "merged", "history": [{"stage": "review-request-changes", "at": "2026-10-30T09:00:00Z"}, {"stage": "review-approve", "at": "2026-10-30T09:30:00Z"}]},
         {"id": "b", "title": "B", "stage": "parked", "history": [{"stage": "review-approve", "at": "2026-10-30T09:00:00Z"}]}]
arc = F.archive(events, units, {"c"}, traffic={"wt:a": {"rx": 9, "tx": 1}})
assert [r["issue"] for r in F.archive([ev("77", "2026-10-30T10:00:00Z", 1, [4631])], [], set())] == [4631]
assert [(r["rx"], r["tx"]) for r in arc] == [(None, None), (9, 1)], arc
assert [(r["task"], r["outcome"]) for r in arc] == [("B", "bad"), ("A", "ok")], arc
rep = {"tickets": [{"ticket": 1, "outcome": "landed", "landed_at": "2026-10-30T12:00:00Z", "wall_s": 7200, "tokens": 500},
                   {"ticket": 2, "outcome": "closed-unmerged"}]}
t = F.trend(events, rep, units, "/nonexistent", days=3, now=datetime.datetime(2026, 10, 30, tzinfo=datetime.timezone.utc))
s = {x["id"]: x["values"] for x in t["series"]}
assert s["merged"] == [0, 0, 1] and s["wall"] == [None, None, 2.0] and s["tokens"] == [None, None, 500], s
assert s["waste"] == [None, 0.0, 75.0] and s["first_pass"] == [None, None, 50.0], s
PY
echo "factory_trend.test.sh: PASS"
