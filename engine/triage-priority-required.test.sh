#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
source "$SCRIPT_DIR/lib.sh"

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok - $description"
  else
    echo "not ok - $description (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

FAILED=0
READY_MEASURE_JSON='[
  {"number":92001,"labels":[{"name":"ready-for-agent"}]},
  {"number":92002,"labels":[{"name":"ready-for-agent"},{"name":"priority:normal"}]}
]'
printf '%s\n' '{"risk_class":null,"level":null}' > "$STATE_DIR/92001.json"
printf '%s\n' '{"risk_class":"P1","level":"L1"}' > "$STATE_DIR/92002.json"
READY_PRIORITY_MISSING_IDS=""
READY_MEASURE_IDS=""
if declare -F triage_ready_issue_ids >/dev/null; then
  triage_ready_issue_ids $'92001\n92002' "$READY_MEASURE_JSON"
fi
assert_eq "ready issue without priority is on the missing-priority list" 92001 "$READY_PRIORITY_MISSING_IDS"
assert_eq "measured ready issue without priority remains a triage candidate" 92001 "$READY_MEASURE_IDS"
STALE_WITHOUT_PRIORITY=false
STALE_WITH_PRIORITY=false
if declare -F triage_ready_snapshot_is_stale >/dev/null; then
  triage_ready_snapshot_is_stale '{"labels":[{"name":"ready-for-agent"}]}' "$STATE_DIR/92001.json" && STALE_WITHOUT_PRIORITY=true || true
  triage_ready_snapshot_is_stale '{"labels":[{"name":"ready-for-agent"},{"name":"priority:normal"}]}' "$STATE_DIR/92002.json" && STALE_WITH_PRIORITY=true || true
fi
assert_eq "measured ready issue without priority is not rejected as stale" false "$STALE_WITHOUT_PRIORITY"
assert_eq "measured ready issue with priority is still rejected as stale" true "$STALE_WITH_PRIORITY"

MEASURE_SELECTION_BODY="$(sed -n '/^  for next_measure in \$READY_MEASURE_IDS; do$/,/^  done$/p' "$PIPELINE_SRC")"
TRIAGE_RETRY_NOW=0
TRIAGE_SELECT_RESERVE=0
TRIAGE_CAP=2
TRIAGE_BATCH_ACTIVE=0
TRIAGE_SELECT_CUT=0
TRIAGE_DEFERRED_COUNT=0
TRIAGE_BATCH_IDS=()
TRIAGE_RETRY_ALONE=0
TRIAGE_SKIPS=()
triage_slots=2
triage_skip() { :; }
triage_slice_seconds_left() { printf '9999\n'; }
state_file() { printf '%s/%s.json\n' "$STATE_DIR" "$1"; }
state_read() { printf '{}\n'; }
issue_model_failure_backoff_remaining() { printf '0\n'; }
triage_retry_deferred() { return 1; }
hand_agent_issue_is_live_owned() { return 1; }
is_on_hold() { return 1; }
stage_unit_active() { return 1; }
pipeline_triage_skip_inflight() { return 1; }
stage_dispatch_allowed() { return 0; }
ensure_issue_roadmap_parent_for_dispatch() { :; }
eval "$MEASURE_SELECTION_BODY"
assert_eq "ready issue without priority is selected while classifier admission is held" 92001 "${TRIAGE_BATCH_IDS[0]:-}"

dispatch_triage_batch() {
  printf 'held:%s\n' "$*"
  return 75
}
DISPATCH_OUTPUT=""
DISPATCH_STATUS=0
if [[ "${#TRIAGE_BATCH_IDS[@]}" -gt 0 ]]; then
  DISPATCH_OUTPUT="$(dispatch_triage_batch "${TRIAGE_BATCH_IDS[@]}")" || DISPATCH_STATUS=$?
fi
assert_eq "held classifier receives the missing-priority issue in this tick" held:92001 "$DISPATCH_OUTPUT"

if [[ "$FAILED" -eq 1 || "$DISPATCH_STATUS" -ne 75 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
