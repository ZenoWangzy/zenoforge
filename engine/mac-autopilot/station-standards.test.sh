#!/usr/bin/env bash
# Every station in station_health.STATIONS has a time, tokens and throughput standard (a measured metric in
# CRITERIA) or a documented exception; a station added without one fails. collect() emits the values it names.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
python3 -I - "$here" "$d" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from datetime import datetime, timezone
import os, node_health, station_health, station_standards as ss

DIMS = ("time", "tokens", "throughput")

def missing(stations):
    """Stations, and their dimensions, with neither a metric in CRITERIA nor a documented exception."""
    gaps = []
    for s in stations:
        row = ss.MATRIX.get(s)
        if row is None:
            gaps.append((s, "no MATRIX row"))
            continue
        for dim in DIMS:
            metric = row.get(dim)
            if metric is None:
                if not (ss.EXCEPTIONS.get((s, dim)) or "").strip():
                    gaps.append((s, dim))
            elif metric not in node_health.CRITERIA:
                gaps.append((s, dim + " " + metric))
    return gaps

assert set(ss.MATRIX) == set(station_health.STATIONS), (sorted(ss.MATRIX), station_health.STATIONS)
assert missing(station_health.STATIONS) == [], missing(station_health.STATIONS)
# Pipeline steps outside the stations: every cell is a metric in CRITERIA or a documented exception.
for step, row in ss.PIPELINE.items():
    for dim in DIMS:
        metric = row.get(dim)
        if metric is None:
            assert (ss.EXCEPTIONS.get((step, dim)) or "").strip(), (step, dim)
        else:
            assert metric in node_health.CRITERIA, (step, dim, metric)
# A new station without a standard must fail, not pass silently.
assert missing(station_health.STATIONS + ("newstation",)) == [("newstation", "no MATRIX row")]
# Every new metric is sourced (a measured window and sample count), not a bare bound.
for mid in ss.CRITERIA:
    assert ss.SOURCE.get(mid), f"{mid} has no SOURCE"
# collect() emits every metric the new standards name, as a number or None (no data).
now = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)
values = ss.collect(now, [], [], sys.argv[2], sys.argv[2])
assert set(ss.CRITERIA) <= set(values), sorted(set(ss.CRITERIA) - set(values))
for mid, v in values.items():
    assert v is None or isinstance(v, (int, float)), (mid, v)
assert all(values[f"{s}.out_per_day"] == 0 for s in station_health.STATIONS), values
# The long station value stays on its 24 h window while the same ledger samples expose a
# recovering one-hour value and its difference from the previous hour.
now = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)
def at(minutes):
    from datetime import timedelta
    return (now - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
units = [
    {"history": [{"stage": "ci-ready", "at": at(7 * 60)}, {"stage": "merged", "at": at(6 * 60)}]},
    {"history": [{"stage": "ci-ready", "at": at(5 * 60)}, {"stage": "merged", "at": at(4 * 60)}]},
    {"history": [{"stage": "ci-ready", "at": at(175)}, {"stage": "merged", "at": at(115)}]},
    {"history": [{"stage": "ci-ready", "at": at(40)}, {"stage": "merged", "at": at(30)}]},
]
long_values = ss.collect(now, units, [], sys.argv[2], sys.argv[2])
windows = ss.collect_windows(now, units, [], sys.argv[2], sys.argv[2])
assert long_values["merge.wait_p50_min"] == 60, long_values
assert windows["merge.wait_p50_min"]["value_1h"] == 10, windows
assert windows["merge.wait_p50_min"]["trend_1h"] == {"delta": -50, "direction": "down"}, windows
assert windows["merge.wait_p50_min"]["short_window"] == "1h", windows
fallback = ss.collect_windows(now, units[:3], [], sys.argv[2], sys.argv[2])
assert fallback["merge.wait_p50_min"]["value_1h"] == 60, fallback
assert fallback["merge.wait_p50_min"]["short_window"] == "6h", fallback
empty = ss.collect_windows(now, [], [], sys.argv[2], sys.argv[2])
assert all(row["value_1h"] is None and row["short_window"] is None for row in empty.values()), empty
# A forced breach (merge p50 of 70 min, bound 41) writes one STATION-OVER line naming its item ids; a value within bounds writes no merge line.
def alerts(name):
    try:
        return open(os.path.join(sys.argv[2], name, "alerts", "node-health.md")).read()
    except OSError:
        return ""
breach = [{"id": "issue-101", "history": [{"stage": "ci-ready", "at": at(200)}, {"stage": "merged", "at": at(120)}]},
          {"id": "issue-102", "history": [{"stage": "ci-ready", "at": at(100)}, {"stage": "merged", "at": at(30)}]}]
ss.collect(now, breach, [], os.path.join(sys.argv[2], "breach"), sys.argv[2], alert=True)
line = [l for l in alerts("breach").splitlines() if "metric=merge.wait_p50_min " in l]
assert len(line) == 1 and "STATION-OVER station=merge" in line[0] and "value=70 bound=41" in line[0] \
    and "items=issue-101,issue-102" in line[0], alerts("breach")
ss.collect(now, [{"id": "issue-103", "history": [{"stage": "ci-ready", "at": at(40)}, {"stage": "merged", "at": at(30)}]}],
           [], os.path.join(sys.argv[2], "within"), sys.argv[2], alert=True)
assert "metric=merge.wait_p50_min " not in alerts("within"), alerts("within")
# Only the --alert run writes: a report or a replay (alert=False) leaves the alerts file alone.
ss.collect(now, breach, [], os.path.join(sys.argv[2], "quiet"), sys.argv[2])
assert alerts("quiet") == "", alerts("quiet")
# A breach with no id or issue names '-', never the literal 'None'.
ss.collect(now, [{"history": [{"stage": "ci-ready", "at": at(200)}, {"stage": "merged", "at": at(120)}]}],
           [], os.path.join(sys.argv[2], "noid"), sys.argv[2], alert=True)
noid = [l for l in alerts("noid").splitlines() if "metric=merge.wait_p50_min " in l]
assert len(noid) == 1 and "items=-" in noid[0] and "None" not in noid[0], alerts("noid")
# Higher-is-better breach (starved, 20 <= bound 25) reads side=under; a second call in the same hour adds no line.
ss.over_bound(os.path.join(sys.argv[2], "under"), now, {"intake.out_per_day": 20}, {})
ss.over_bound(os.path.join(sys.argv[2], "under"), now, {"intake.out_per_day": 20}, {})
under = [l for l in alerts("under").splitlines() if "metric=intake.out_per_day " in l]
assert len(under) == 1 and "side=under" in under[0] and "value=20 bound=25" in under[0], alerts("under")
# A starved ledger throughput (2 implement write-ends, 24 h, bound 12) names the unit ids that left the station.
work = [{"id": "issue-201", "history": [{"stage": "write-start", "work_type": "implement", "at": at(90)}, {"stage": "write-end", "at": at(80)}]},
        {"id": "issue-202", "history": [{"stage": "write-start", "work_type": "implement", "at": at(70)}, {"stage": "write-end", "at": at(60)}]}]
ss.collect(now, work, [], os.path.join(sys.argv[2], "starved"), sys.argv[2], alert=True)
starved = [l for l in alerts("starved").splitlines() if "metric=implement.out_per_day " in l]
assert len(starved) == 1 and "side=under" in starved[0] and "value=2 bound=12" in starved[0] \
    and "items=issue-201,issue-202" in starved[0], alerts("starved")
assert "side=over" in line[0], line[0]
print("station-standards ok: %d stations, %d metrics" % (len(ss.MATRIX), len(ss.CRITERIA)))
PY
