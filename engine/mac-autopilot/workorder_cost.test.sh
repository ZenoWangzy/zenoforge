#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$script_dir" python3 - <<'PY'
from datetime import datetime, timezone
from types import SimpleNamespace

import workorder_cost

rows = [
    {"unit": "issue-1", "usage": SimpleNamespace(raw=14_100_000),
     "footer_tokens": None, "minutes": 19.5},
    {"unit": "11", "usage": SimpleNamespace(raw=13_900_000),
     "footer_tokens": None, "minutes": 21.2},
    {"unit": "issue-2", "usage": SimpleNamespace(raw=3_000_000),
     "footer_tokens": 28_000_000, "minutes": 100},
]
spend = workorder_cost.unit_spend(rows)
assert spend["issue-1"] == [14_100_000, 19.5]
assert spend["11"] == [13_900_000, 21.2]
assert spend["issue-2"] == [28_000_000, 100]

units = [
    {"id": "issue-1", "issue": 1, "pr": 11, "stage": "repair-pending",
     "history": [{"stage": "created", "at": "2026-10-29T00:00:00Z"}]},
    {"id": "issue-2", "pr": 2, "stage": "merged",
     "history": [
         {"stage": "created", "at": "2026-10-29T00:00:00Z"},
         {"stage": "merged", "at": "2026-10-29T01:00:00Z"},
     ]},
]
orders = workorder_cost.work_orders(
    units, spend, datetime(2026, 10, 29, 1, tzinfo=timezone.utc)
)
open_order, done_order = orders
assert open_order["tokens"] == 28_000_000
assert open_order["worker_minutes"] == 41
assert open_order["over"] == ["tokens"]
assert done_order["tokens"] == 28_000_000
assert done_order["over"] == []
assert workorder_cost.UNIT_STANDARDS["tokens"][2] == 28_000_000
PY

echo 'workorder_cost.test.sh: PASS'
