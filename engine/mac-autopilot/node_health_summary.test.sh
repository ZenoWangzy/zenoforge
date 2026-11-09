#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$script_dir" python3 - <<'PY'
from contextlib import redirect_stdout
from io import StringIO
import node_health_summary

metrics = {"ci.waste_runner_pct": 40}
spend = {
    "by_reason": {"cancelled": 3, "superseded_unapproved": 37, "nonproduct_postsubmit": 0},
    "cancel_audit_min_by_reason": {
        "deferred": 1, "slot_wait": 2, "repair_dispatched": 3,
        "superseded_main_head": 4, "review_blocked": 5, "parked": 6, "other": 19,
    },
}
rows = [("ci+merge", "waste", "could not change a verdict", 40, 0, 10, False, "UNHEALTHY")]
output = StringIO()
with redirect_stdout(output):
    node_health_summary.print_summary(metrics, spend, rows, ["mypc"], [42])
text = output.getvalue()
assert "ci waste by reason (min): cancelled=3  nonproduct_postsubmit=0  superseded_unapproved=37" in text
assert "ci waste by cancel reason (min): deferred=1  slot_wait=2  repair_dispatched=3  superseded_main_head=4  review_blocked=5  parked=6  other=19" in text
assert "unhealthy nodes: ci+merge" in text and "host missing: mypc" in text and "closed units under open issues: #42" in text
PY
echo 'node_health_summary.test.sh: PASS'
