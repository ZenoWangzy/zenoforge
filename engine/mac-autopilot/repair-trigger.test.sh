#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/repair-trigger"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

fail() { printf 'repair-trigger.test.sh: %s\n' "$*" >&2; exit 1; }
field() { jq -r --arg id issue-9 ".units[] | select(.id==\$id) | $1" "$UNITS"; }
refill_stopped() { return 1; }
room_for() { return 0; }
size_admission_write_start() { return 0; }
dispatch() { return 0; }
tick_pr_head() { printf '%040d\n' 1; }

dispatch_case() { # case-name expected history-json
  local name="$1" expected="$2" history="$3" actual
  jq -n --argjson history "$history" '{units:[{id:"issue-9",issue:9,pr:9,lane:"pr",branch:"agent/issue-9",stage:"repair-pending",estimated_changed_lines:100,footprint:[],history:$history}]}' > "$UNITS"
  dispatch_if_room issue-9 repair repair repair-9.worker.log repair-9.md GPT-5 high prompt "" "$fixture/repo" "" "" "" false codex false configured codex \
    || fail "$name repair dispatch was rejected"
  actual="$(field '.history[-1].trigger // "missing"')"
  [[ "$actual" == "$expected" ]] || fail "$name write-start trigger: expected $expected, got $actual"
}

unit_end_case() {
  PYTHONPATH="$script_dir${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
from datetime import datetime, timezone

import roi_collect

row = {
    "unit": "issue-9", "phase": "repair", "usage": None, "footer_tokens": 100,
    "end": datetime(2026, 11, 20, 1, 0, tzinfo=timezone.utc),
    "start": datetime(2026, 11, 20, 0, 59, tzinfo=timezone.utc),
    "model": "gpt-6-luna", "backend": "codex", "log": "repair-2.worker.log",
}
units = {
    "issue-9": {
        "issue": 9,
        "history": [
            {"stage": "write-start", "work_type": "repair", "attempt": "repair-1.worker.log", "trigger": "merge-conflict"},
            {"stage": "write-start", "work_type": "repair", "attempt": "repair-2.worker.log", "trigger": "ci-test-red"},
        ],
    },
}
event = roi_collect._worker_event(row, units, "test-host")
assert event["event_type"] == "unit-end"
assert event["unit"].get("trigger") == "ci-test-red", event["unit"]
PY
}

run_case() {
  case "$1" in
    review-finding) dispatch_case "$1" review-finding '[{"stage":"review-request-changes"}]' ;;
    ci-test-red) dispatch_case "$1" ci-test-red '[{"stage":"ci-test-red"}]' ;;
    merge-conflict) dispatch_case "$1" merge-conflict '[{"stage":"merge-conflict"}]' ;;
    self-check-red) dispatch_case "$1" self-check-red '[{"stage":"self-check-red"}]' ;;
    supervisor-requeue) dispatch_case "$1" supervisor-requeue '[{"stage":"review-request-changes"},{"stage":"supervisor-requeue"}]' ;;
    no-push) dispatch_case "$1" no-push '[{"stage":"repair-no-push"}]' ;;
    worker-rc75) dispatch_case "$1" worker-rc75 '[{"stage":"worker-rc75"}]' ;;
    unknown) dispatch_case "$1" unknown '[{"stage":"unclassified-signal"}]' ;;
    unit-end) unit_end_case ;;
    *) fail "unknown case selector: $1" ;;
  esac
  printf 'repair-trigger.test.sh: %s ok\n' "$1"
}

if [[ -n "${REPAIR_TRIGGER_CASE:-}" ]]; then
  run_case "$REPAIR_TRIGGER_CASE"
else
  for case_name in review-finding ci-test-red merge-conflict self-check-red supervisor-requeue no-push worker-rc75 unknown unit-end; do
    run_case "$case_name"
  done
fi

echo 'repair-trigger.test.sh: ok'
