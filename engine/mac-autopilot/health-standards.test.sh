#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_CONFIG_ROOT="$test_env_root/config/.zenoforge" PYTHONPATH="$script_dir"
mkdir -p "$ZF_CONFIG_ROOT/mac-autopilot"
python3 - <<'PY'
import contextlib, io, json, os
from datetime import datetime, timezone
import node_health as nh
import health_standards as hs
path = os.path.join(os.environ["ZF_CONFIG_ROOT"], "mac-autopilot", "health-standards.json")
def write(doc): json.dump(doc, open(path, "w"))
def standard(mid, value=2):
    criteria, minimums, bases, invalid = nh.resolve_health_standards()
    return criteria, minimums, bases, invalid, next(r for r in nh.score({mid: value}, criteria, {}, minimums, invalid) if r[1] == mid)
assert nh.CRITERIA["delivery.merged_not_live"][2:4] == (6, 12)
write({"flow.merge_rate_per_hour":{"healthy":1.5,"unhealthy":1,"basis":"measured fixture values over a seven day window"}})
criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[4:6] == (1.5, 1) and row[7] == "OK" and "seven day window" in bases[row[1]]
valid_basis = "measured fixture values over a seven day window"
bad_entries = ({"healthy":3,"unhealthy":1.5}, {"healthy":3,"unhealthy":1.5,"basis":"short"},
               {"healthy":1.5,"unhealthy":3,"basis":valid_basis}, {"healthy":"3","unhealthy":1.5,"basis":valid_basis},
               {"healthy":True,"unhealthy":1.5,"basis":valid_basis}, [])
for entry in bad_entries:
    write({"flow.merge_rate_per_hour":entry}); err = io.StringIO()
    with contextlib.redirect_stderr(err): criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
    assert row[4:6] == (3, 1.5) and row[7] == "STANDARD-INVALID" and "metric=flow.merge_rate_per_hour" in err.getvalue()
open(path, "w").write("[]")
assert standard("flow.merge_rate_per_hour")[4][7] == "STANDARD-INVALID"
open(path, "w").write("{"); err = io.StringIO()
with contextlib.redirect_stderr(err): criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[7] == "STANDARD-INVALID" and "all metrics STANDARD-INVALID" in err.getvalue()
runtime, agent_home = os.path.join(os.environ["ZF_CONFIG_ROOT"], "runtime"), os.environ["AGENT_HOME"]
now = datetime(2026, 10, 19, 12, tzinfo=timezone.utc)
nh.health_standards.write_health_alerts(runtime, agent_home, [row], now, nh.live_delivery.display_value, nh.health_doc_reference)
alert = open(os.path.join(runtime, "alerts", "node-health.md")).read()
watch = open(os.path.join(agent_home, "logs", "head-watch.alerts")).read()
assert "NODE-STANDARD-INVALID metric=flow.merge_rate_per_hour" in alert and "NODE-STANDARD-INVALID" in watch
nh.flow_inbox(runtime, [row], now, agent_home, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
assert "flow metric=flow.merge_rate_per_hour status=STANDARD-INVALID" in open(os.path.join(agent_home, "supervisor-inbox")).read()
write({}); missing = os.path.join(os.path.dirname(path), "missing-built-in-health-standards.json"); err = io.StringIO()
with contextlib.redirect_stderr(err):
    criteria, minimums, bases, invalid = hs.resolve(nh.CRITERIA, default_path=missing)
    row = next(r for r in nh.score({"flow.merge_rate_per_hour":2}, criteria, {}, minimums, invalid) if r[1] == "flow.merge_rate_per_hour")
assert row[7] == "STANDARD-INVALID" and "missing file=missing-built-in-health-standards.json" in err.getvalue()
write({"unknown.metric":{"healthy":1,"unhealthy":2,"basis":"measured fixture values over a seven day window"}})
err = io.StringIO()
with contextlib.redirect_stderr(err): criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[4:6] == (3, 1.5) and err.getvalue().count("metric=unknown.metric") == 1
write({})
criteria, minimums, bases, invalid, row = standard("rereview.wall_p50", 15)
row = next(r for r in nh.score({"rereview.wall_p50":15}, criteria, {"rereview.wall_p50":3}, minimums, invalid) if r[1] == "rereview.wall_p50")
assert row[7] == "LOW-N" and minimums[row[1]] == 10
row = next(r for r in nh.score({"rereview.wall_p50":27.5}, criteria, {"rereview.wall_p50":3}, minimums, invalid) if r[1] == "rereview.wall_p50")
assert row[7] == "UNHEALTHY"
html = open(os.path.join(os.environ["PYTHONPATH"], "dashboard.html")).read()
assert '"STANDARD-INVALID":"bad"' in html and '"LOW-N":"warn"' in html and 'sample_n:m.sample_n' in html and 'n=${o.sample_n}' in html
print("health-standards.test.sh: PASS")
PY
