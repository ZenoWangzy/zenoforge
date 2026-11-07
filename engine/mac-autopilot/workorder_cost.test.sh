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

# Held stages (blocked-external, parked) wait on a predecessor or an external
# decision: their age is not a defect, so the age bug bound must not count them.
held_units = [
    {"id": "issue-3", "issue": 3, "pr": 13, "stage": "parked",
     "history": [{"stage": "created", "at": "2026-10-15T00:00:00Z"}]},
    {"id": "issue-4", "issue": 4, "pr": 14, "stage": "blocked-external",
     "history": [{"stage": "created", "at": "2026-10-15T00:00:00Z"}]},
]
held_orders = workorder_cost.work_orders(
    held_units, {}, datetime(2026, 10, 29, 1, tzinfo=timezone.utc))
assert [o["over"] for o in held_orders] == [[], []], held_orders
# The same age on a progressable unit still trips the age bound.
active_unit = {"id": "issue-5", "issue": 5, "pr": 15, "stage": "review-pending",
               "history": [{"stage": "created", "at": "2026-10-15T00:00:00Z"}]}
active_order = workorder_cost.work_orders(
    [active_unit], {}, datetime(2026, 10, 29, 1, tzinfo=timezone.utc))[0]
assert active_order["over"] == ["age_hours"], active_order

# A held unit (supervisor-review included) keeps its lifetime spend but is judged only on spend
# inside the window; a progressable unit still trips on lifetime rounds with no recent spend.
from datetime import timedelta
now = datetime(2026, 10, 29, 1, tzinfo=timezone.utc)
rc = [{"stage": "created", "at": "2026-10-28T20:00:00Z"}] + [
    {"stage": "review-request-changes", "at": "2026-10-28T21:00:00Z"}] * 8
big = {"issue-6": [30_000_000, 100], "issue-7": [30_000_000, 100]}
sv = {"id": "issue-6", "issue": 6, "stage": "supervisor-review", "history": rc}
loop = {"id": "issue-7", "issue": 7, "stage": "repair", "history": rc}
assert [o["over"] for o in workorder_cost.work_orders([sv, loop], big, now, set())] == [[], ["tokens", "rounds"]]
assert workorder_cost.work_orders([sv], big, now, {"issue-6"})[0]["over"] == ["tokens", "rounds"]
since = now - timedelta(hours=5)
row = lambda start, minutes: {"unit": "issue-6", "start": start, "minutes": minutes}
assert workorder_cost.recent_units([row(since - timedelta(hours=2), 30)], since) == set()
assert workorder_cost.recent_units([row(since - timedelta(minutes=10), 30)], since) == {"issue-6"}
PY

echo 'workorder_cost.test.sh: PASS'
