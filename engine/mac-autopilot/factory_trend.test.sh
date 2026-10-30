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
# daily ROI line: tokens per landed ticket 100 -> 200 -> 300 on 3 consecutive days fires the retro rule; a gap day (None) or a flat day does not
ev2 = lambda ts, tk, wall: {"event_type": "unit-end", "ts": ts, "wall_s": wall, "tickets": [], "unit": {"key": "k", "stage": "repair"}, "models": [{"tokens": tk}]}
land = lambda n, d, lead=None: {"ticket": n, "outcome": "landed", "landed_at": d + "T12:00:00Z", "lead_hours": lead}
evs = [ev2("2026-10-28T01:00:00Z", 100, 3600), ev2("2026-10-29T01:00:00Z", 200, 43200), ev2("2026-10-30T01:00:00Z", 300, 43200)]
rep2 = {"tickets": [land(1, "2026-10-28", 4), land(2, "2026-10-29", 6), land(3, "2026-10-29", 2), land(4, "2026-10-30")]}
now2 = datetime.datetime(2026, 10, 30, 12, tzinfo=datetime.timezone.utc)
t2 = F.trend(evs, rep2, [], "/nonexistent", days=3, now=now2, max_workers=2)
d2 = {x["id"]: x["values"] for x in t2["daily"]}
assert d2["spend"] == [100, 200, 300] and d2["accepted"] == [1, 2, 1] and d2["lead_p50"] == [4.0, 4.0, None], d2
assert d2["per_accepted"] == [100, 100, 300] and d2["idle"] == [97.9, 75.0, 50.0], d2
assert t2["retro"] == [] and F.retro_line(t2, "2026-10-30") is None
rep2["tickets"].pop(2)  # one landed ticket per day: 100, 200, 300
t3 = F.trend(evs, rep2, [], "/nonexistent", days=3, now=now2, max_workers=2)
assert t3["retro"] == ["2026-10-30"] and "100 → 200 → 300" in F.retro_line(t3, "2026-10-30"), t3["retro"]
assert F.rising_runs([1, 2, None, 3, 4]) == [] and F.rising_runs([1, 2, 2, 3]) == [] and F.rising_runs([5, 1, 2, 3]) == [3]
# lead-time p50 regression: the createdAt census must target the ZF_REPO deployment repo when the caller
# passes none (factory_trend.collect never does), else every landed ticket's lead_hours is null
import os, tempfile, pathlib, roi_rollup as R
fixture = pathlib.Path(tempfile.mkdtemp()); (fixture / "metrics").mkdir(parents=True)
(fixture / "metrics" / "efficiency-2026-10.jsonl").write_text(
    '{"event_type": "merged", "ts": "2026-10-30T10:00:00Z", "issue": 7, "sha": "aa"}\n')
os.environ["ZF_REPO"] = "example-maintainer/example-live"
censused = []
R._issue_created = lambda repo, cutoff: censused.append(repo) or {7: datetime.datetime(2026, 10, 30, 6, tzinfo=datetime.timezone.utc)}
rep = R.tickets_report(str(fixture), days=3, repo_root="/nonexistent", now=datetime.datetime(2026, 10, 31, tzinfo=datetime.timezone.utc))
assert censused == ["example-maintainer/example-live"] and rep["tickets"][0]["lead_hours"] == 4.0, (censused, rep["tickets"])
PY
echo "factory_trend.test.sh: PASS"
