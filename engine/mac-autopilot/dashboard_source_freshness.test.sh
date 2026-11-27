#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" <<'PY'
import json, os, sys, tempfile
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import dashboard_source_freshness as freshness

now = datetime(2026, 11, 27, 18, 0, tzinfo=timezone.utc).timestamp()
old = "2026-11-24T17:14:00Z"
paused_since = "2026-11-24T17:14:00Z"

def write_json(path, value):
    with open(path, "w", encoding="utf-8") as target:
        json.dump(value, target)

with tempfile.TemporaryDirectory() as runtime:
    write_json(os.path.join(runtime, "units.json"), {"units": [{"id": "issue-2713", "stage": "ready-to-merge"}]})
    write_json(os.path.join(runtime, "units-archive.json"), {"units": []})
    write_json(os.path.join(runtime, "workers.json"), {"workers": [{"pid": 1234, "type": "implement"}]})
    write_json(os.path.join(runtime, "pr-run-snapshot.json"), {"schema": 1, "tick": old, "prs": [], "unfinished_runs": [], "main_runs": {}, "infra_runs": []})
    write_json(os.path.join(runtime, "node-health.json"), {"generated_at": old, "metrics": [{"id": "scheduler.tick_gap_p50", "value": 120}], "delivery": {"rows_from": old}})
    write_json(os.path.join(runtime, "station-health.json"), {"at": old, "paused": True, "stations": {"merge": {"status": "PAUSED"}}})
    write_json(os.path.join(runtime, "merge-wait-last-good.json"), {"at": old, "value": 12.0, "details": {"factory_n": 2}})
    write_json(os.path.join(runtime, "delivery-rows-last-good.json"), {"at": old, "issues": [], "prs": []})
    stamp = datetime.strptime(old, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    os.utime(os.path.join(runtime, "units.json"), (stamp, stamp))
    os.utime(os.path.join(runtime, "workers.json"), (stamp, stamp))
    result = freshness.read_sources(runtime, now=now, tick_seconds=120, paused_since=paused_since)

for key in ("units", "workers", "ci_live", "node_health", "stations", "merge_wait", "delivery_rows"):
    assert result[key]["stale"] is True, (key, result[key])
    assert result[key]["fetched_at"] == old, (key, result[key])
for key in ("units", "workers", "ci_live", "node_health", "stations"):
    assert result[key]["paused"] is True, (key, result[key])
    assert result[key]["paused_since"] == paused_since, (key, result[key])
assert result["ci_live"]["at"] == old, result["ci_live"]
assert result["stations"]["at"] == old, result["stations"]
assert result["merge_wait"]["at"] == old, result["merge_wait"]
assert result["delivery_rows"]["at"] == old, result["delivery_rows"]
metrics = freshness.annotate_standards({"metrics": [{"id": "merge.green_to_merge_max_min"}, {"id": "delivery.unlinked_units_30d", "data_at": old}, {"id": "scheduler.tick_gap_p50"}]}, result)["metrics"]
assert [(row["source_name"], row["source_at"], row["source_stale"]) for row in metrics] == [("合并等待", old, True), ("交付台账", old, True), ("健康评分", old, True)], metrics
assert all("path" not in source for source in result.values()), result
print("dashboard_source_freshness.test.sh: PASS")
PY
