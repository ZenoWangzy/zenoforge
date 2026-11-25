#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP" "$test_env_root"' EXIT
FAILED=0
assert_eq() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (expected [$2], got [$3])"; FAILED=1; fi; }
LOCK_FILE="$TMP/decision.lock"
mkdir -p "$AGENT_HOME"
export LOCK_FILE

(
  exec 9>"$LOCK_FILE"
  flock -n 9
  touch "$TMP/advisor-ready"
  sleep 0.4
) &
advisor_pid=$!
for _ in {1..100}; do [ -e "$TMP/advisor-ready" ] && break; sleep 0.01; done
advisor_started="$(date +%s%N)"
advisor_status=0
advisor_output="$(AGENT_HOME="$AGENT_HOME" LOCK_FILE="$LOCK_FILE" PIPELINE_STAGE=triage EVENT_TRIAGE=1 bash -c 'source "$1"; pipeline_acquire_lock; echo acquired' _ "$SCRIPT_DIR/issue-pipeline-slices.sh" 2>&1)" || advisor_status=$?
advisor_elapsed_ms=$(( ($(date +%s%N) - advisor_started) / 1000000 ))
assert_eq "event pass acquires its lock while the decision lock is held" acquired "$advisor_output"
assert_eq "event pass does not wait on the advisor lock" 0 "$advisor_status"
assert_eq "event pass returns while advisor still holds the decision lock" 1 "$(kill -0 "$advisor_pid" 2>/dev/null && echo 1 || echo 0)"
assert_eq "event pass starts promptly" 1 "$(( advisor_elapsed_ms < 1000 ? 1 : 0 ))"
wait "$advisor_pid"

hold_triage_lock() (
  export AGENT_HOME LOCK_FILE ZF_PIPELINE_SLICE_TICK=fixture PIPELINE_STAGE=triage EVENT_TRIAGE=0
  exec 9>"$LOCK_FILE"
  flock -n 9
  source "$SCRIPT_DIR/issue-pipeline-slices.sh"
  pipeline_acquire_lock
  touch "$TMP/tick-ready"
  sleep 0.4
)
hold_triage_lock &
tick_pid=$!
for _ in {1..100}; do [ -e "$TMP/tick-ready" ] && break; sleep 0.01; done
event_busy_status=0
AGENT_HOME="$AGENT_HOME" LOCK_FILE="$LOCK_FILE" PIPELINE_STAGE=triage EVENT_TRIAGE=1 \
  bash -c 'source "$1"; pipeline_acquire_lock' _ "$SCRIPT_DIR/issue-pipeline-slices.sh" \
  >/dev/null 2>&1 || event_busy_status=$?
assert_eq "event pass exits when the tick owns the triage lock" 75 "$event_busy_status"
wait "$tick_pid"

hold_event_lock() (
  export AGENT_HOME LOCK_FILE PIPELINE_STAGE=triage EVENT_TRIAGE=1
  source "$SCRIPT_DIR/issue-pipeline-slices.sh"
  pipeline_acquire_lock
  touch "$TMP/event-ready"
  sleep 0.4
)
hold_event_lock &
event_pid=$!
for _ in {1..100}; do [ -e "$TMP/event-ready" ] && break; sleep 0.01; done
tick_busy_status=0
AGENT_HOME="$AGENT_HOME" LOCK_FILE="$LOCK_FILE" PIPELINE_STAGE=triage EVENT_TRIAGE=0 \
  bash -c 'source "$1"; pipeline_acquire_lock' _ "$SCRIPT_DIR/issue-pipeline-slices.sh" >/dev/null 2>&1 \
  || tick_busy_status=$?
assert_eq "tick triage stage exits when the event pass owns the triage lock" 75 "$tick_busy_status"
wait "$event_pid"

OWNER=fixture-owner
ISSUE=181047
coord_acquire "$(coord_issue_key "$ISSUE")" "$OWNER" systemd-worker "$ISSUE" zf-triage-batch triage-batch || exit 1
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMD_RUN_LOG"
SH
chmod +x "$TMP/bin/systemd-run"
SYSTEMD_RUN_LOG="$TMP/systemd-run.log"
export SYSTEMD_RUN_LOG
PATH="$TMP/bin:$PATH"
export PATH
unset ZF_AGENT_TEST_MODE
SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 \
  "$SCRIPT_DIR/record-unit-result.sh" triage-batch "$OWNER" "$ISSUE"
claim_after="$(jq -r '.owner // empty' "$AGENT_HOME/coord/claims/issue-$ISSUE.json")"
assert_eq "batch stop hook releases its issue claim" '' "$claim_after"
assert_eq "batch stop hook starts one delayed triage event" 1 "$(grep -cF -- '--on-active=1s' "$SYSTEMD_RUN_LOG" || true)"
assert_eq "batch stop hook launches the triage event stage" 1 "$(grep -cF -- '--stage triage-event' "$SYSTEMD_RUN_LOG" || true)"
assert_eq "batch stop hook retries only a lock-busy event" 1 "$(grep -cF -- '-p RestartForceExitStatus=75' "$SYSTEMD_RUN_LOG" || true)"
assert_eq "batch stop hook skips triage when the agent home PAUSE file exists" 1 "$(grep -Fq -- "-p ExecCondition=/usr/bin/test ! -e \"$AGENT_HOME/PAUSE\"" "$SYSTEMD_RUN_LOG" && echo 1 || echo 0)"
assert_eq "batch stop hook retries the event after one second" 1 "$(grep -cF -- '-p RestartSec=1s' "$SYSTEMD_RUN_LOG" || true)"
assert_eq "batch stop hook allows retries until the triage lock is free" 1 "$(grep -cF -- '-p StartLimitIntervalSec=0' "$SYSTEMD_RUN_LOG" || true)"

[ "$FAILED" -eq 0 ] && echo "ALL PASSED" || { echo FAILURES; exit 1; }
