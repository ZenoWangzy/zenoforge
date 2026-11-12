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
import node_health, station_health, station_standards as ss

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
print("station-standards ok: %d stations, %d metrics" % (len(ss.MATRIX), len(ss.CRITERIA)))
PY
