#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_CONFIG_ROOT="$test_env_root/config/.zenoforge" PYTHONPATH="$script_dir"
mkdir -p "$ZF_CONFIG_ROOT/mac-autopilot"
python3 - <<'PY'
import contextlib, io, json, os
import node_health as nh
path = os.path.join(os.environ["ZF_CONFIG_ROOT"], "mac-autopilot", "health-standards.json")
def write(doc): json.dump(doc, open(path, "w"))
def standard(mid, value=2):
    criteria, minimums, bases, invalid = nh.resolve_health_standards()
    return criteria, minimums, bases, invalid, next(r for r in nh.score({mid: value}, criteria, {}, minimums, invalid) if r[1] == mid)
write({"flow.merge_rate_per_hour":{"healthy":1.5,"unhealthy":1,"basis":"measured fixture values over a seven day window"}})
criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[4:6] == (1.5, 1) and row[7] == "OK" and "seven day window" in bases[row[1]]
write({"flow.merge_rate_per_hour":{"healthy":99,"unhealthy":1}})
err = io.StringIO()
with contextlib.redirect_stderr(err): criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[4:6] == (3, 1.5) and row[7] == "STANDARD-INVALID" and err.getvalue().count("metric=flow.merge_rate_per_hour") == 1
write({"unknown.metric":{"healthy":1,"unhealthy":2,"basis":"measured fixture values over a seven day window"}})
err = io.StringIO()
with contextlib.redirect_stderr(err): criteria, minimums, bases, invalid, row = standard("flow.merge_rate_per_hour")
assert row[4:6] == (3, 1.5) and err.getvalue().count("metric=unknown.metric") == 1
write({})
criteria, minimums, bases, invalid, row = standard("rereview.wall_p50", 27.5)
row = next(r for r in nh.score({"rereview.wall_p50":27.5}, criteria, {"rereview.wall_p50":3}, minimums, invalid) if r[1] == "rereview.wall_p50")
assert row[7] == "LOW-N" and minimums[row[1]] == 10
html = open(os.path.join(os.environ["PYTHONPATH"], "dashboard.html")).read()
assert '"STANDARD-INVALID":"bad"' in html and '"LOW-N":"warn"' in html and 'sample_n:m.sample_n' in html and 'n=${o.sample_n}' in html
print("health-standards.test.sh: PASS")
PY
