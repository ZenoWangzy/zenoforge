#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$script_dir${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import dashboard_ready_queue

units = [
    {"issue": 1, "stage": "blocked-external", "blocked_on": 900},
    {"issue": 2, "stage": "blocked-external"},
    {"issue": 3, "stage": "blocked-external", "blocked_on": 4},
    {"issue": 5, "stage": "blocked-external", "blocked_on": 901},
    {"issue": 6, "stage": "parked", "parked_reason": "recut-refused-unpushed"},
    {"issue": 7, "stage": "parked", "parked_reason": "ticket-stop-loss"},
    {"issue": 8, "stage": "parked", "parked_reason": "token-hard-park"},
    {"issue": 9, "stage": "parked", "blocked_on": 901},
    {"issue": 4, "stage": "implement"},
    {"issue": 10, "stage": "parked", "parked_reason": "repair-breaker"},
    {"issue": 11, "stage": "parked", "parked_reason": "supervisor-arbitration-cap"},
    {"issue": 12, "stage": "parked", "parked_reason": "supervisor-cap-founder"},
    {"issue": 13, "stage": "parked", "parked_reason": "unknown-park"},
]

def read_json(path):
    return {"state": "tracker"} if path.endswith("/900.json") else None

queue = dashboard_ready_queue.summarize(13, list(range(1, 14)), units, read_json, "/agent")
counts = {row["key"]: row["count"] for row in queue["classes"]}
assert (queue["total"], queue["dispatchable"], queue["active"], queue["held"]) == (13, 0, 1, 12), queue
assert counts == {
    "tracker": 1,
    "no-blocker-recorded": 1,
    "chain-on-ready-issue": 1,
    "blocker-state-unavailable": 1,
    "waiting-predecessor": 1,
    "recut-refused-unpushed": 1,
    "ticket-stop-loss": 1,
    "token-hard-park": 1,
    "repair-breaker": 1,
    "supervisor-arbitration-cap": 1,
    "supervisor-cap-founder": 1,
    "other-parked": 1,
}, counts
assert "不能保证会自行恢复" in dashboard_ready_queue.CLASS_INFO["other-parked"][1]
print("dashboard_ready_queue.test.sh: PASS")
PY
