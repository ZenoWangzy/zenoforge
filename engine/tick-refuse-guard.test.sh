#!/usr/bin/env bash
# tick-refuse-guard.test.sh -- one busy issue or a claim miss must not refuse
# the whole pipeline tick (2026-11-03 incident):
#   1. triage never touches an issue whose scheduler unit is in flight
#      (rereview / ready-to-merge): selection skips it and run-triage.sh
#      leaves its labels unchanged;
#   2. a batch claim drops members with live scheduler workers and claims the
#      rest; an empty remainder is a no-op;
#   3. a slice that exits 75 (EX_TEMPFAIL, defer) does not set failed and the
#      slice summary stays status=0; a slice that exits 1 still fails;
#   4. the bell scanner classifies the tick-refusal and slice-failure lines
#      so the incident intake files this class.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
export AGENT_HOME="$AGENT_HOME"
source "$SCRIPT_DIR/lib.sh"

FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])" >&2
    FAILED=1
  fi
}

FIXTURES="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURES"' EXIT
RUNTIME="$FIXTURES/autopi"
mkdir -p "$RUNTIME"
export MAC_AUTOPILOT_RUNTIME_DIR="$RUNTIME"
# Unit ledger: 5040 rereview and 5041 ready-to-merge are in flight (today's
# case); 5042 merged is terminal; 5043 has no unit at all.
cat > "$RUNTIME/units.json" <<'EOF'
{"units":[
  {"id":"issue-5040","issue":5040,"stage":"rereview"},
  {"id":"issue-5041","issue":5041,"stage":"ready-to-merge"},
  {"id":"issue-5042","issue":5042,"stage":"merged"}
]}
EOF
printf '{"workers":[]}\n' > "$RUNTIME/workers.json"

# --- 1a. the unit-ledger predicate ------------------------------------------
assert_eq 'rereview unit is in flight' 0 "$(scheduler_issue_unit_inflight 5040 >/dev/null 2>&1; echo $?)"
assert_eq 'ready-to-merge unit is in flight' 0 "$(scheduler_issue_unit_inflight 5041 >/dev/null 2>&1; echo $?)"
assert_eq 'merged unit is not in flight' 1 "$(scheduler_issue_unit_inflight 5042 >/dev/null 2>&1; echo $?)"
assert_eq 'issue without a unit is not in flight' 1 "$(scheduler_issue_unit_inflight 5043 >/dev/null 2>&1; echo $?)"
assert_eq 'missing ledger inside a live runtime is unknown (fail-closed)' 3 "$(scheduler_issue_unit_inflight 5040 "$RUNTIME/no-units.json" >/dev/null 2>&1; echo $?)"
printf '{"units":"not-an-array"}\n' > "$FIXTURES/bad-units.json"
assert_eq 'malformed ledger is unknown (fail-closed)' 3 "$(scheduler_issue_unit_inflight 5040 "$FIXTURES/bad-units.json" >/dev/null 2>&1; echo $?)"
assert_eq 'host without the scheduler runtime proceeds' 1 "$(scheduler_issue_unit_inflight 5040 "$FIXTURES/nohost/units.json" >/dev/null 2>&1; echo $?)"

# --- 1b. triage selection skips in-flight units ------------------------------
eval "$(sed -n '/^pipeline_live_worker_check() {/,/^}/p; /^pipeline_triage_skip_inflight() {/,/^}/p' "$PIPELINE_SRC")"
assert_eq 'triage selection skips a rereview unit' 0 "$(pipeline_triage_skip_inflight 5040 >/dev/null 2>&1; echo $?)"
assert_eq 'triage selection skips a ready-to-merge unit' 0 "$(pipeline_triage_skip_inflight 5041 >/dev/null 2>&1; echo $?)"
assert_eq 'triage selection proceeds past a merged unit' 1 "$(pipeline_triage_skip_inflight 5042 >/dev/null 2>&1; echo $?)"
saved_runtime="$MAC_AUTOPILOT_RUNTIME_DIR"
saved_repo_dir="${REPO_DIR:-}"
engine_only_rc="$(MAC_AUTOPILOT_RUNTIME_DIR= REPO_DIR="$FIXTURES/engine-only" pipeline_triage_skip_inflight 5040 >/dev/null 2>&1; echo $?)"
MAC_AUTOPILOT_RUNTIME_DIR="$saved_runtime"
REPO_DIR="$saved_repo_dir"
assert_eq 'engine-only host (no scheduler runtime) still triages' 1 "$engine_only_rc"

# --- 1c. run-triage.sh leaves an in-flight issue's labels unchanged ----------
GH_LOG="$FIXTURES/gh-calls"
STUB_BIN="$FIXTURES/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
echo 'gh stub: refusing test gh call' >&2
exit 1
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
: > "$GH_LOG"
rt_out="$(bash "$SCRIPT_DIR/run-triage.sh" 5040 2>&1)" && rt_rc=0 || rt_rc=$?
assert_eq 'run-triage on a rereview unit exits 0 without consuming it' 0 "$rt_rc"
case "$rt_out" in
  *'in-flight scheduler unit'*) echo "ok - run-triage names the in-flight unit" ;;
  *) echo "not ok - run-triage output lacks the in-flight guard message: $rt_out" >&2; FAILED=1 ;;
esac
if grep -q 'issue edit' "$GH_LOG"; then
  echo "not ok - run-triage edited an in-flight issue's labels" >&2
  FAILED=1
else
  echo "ok - run-triage made no label edit on an in-flight issue"
fi
: > "$GH_LOG"
rt_out="$(bash "$SCRIPT_DIR/run-triage.sh" 5041 2>&1)" && rt_rc=0 || rt_rc=$?
assert_eq 'run-triage on a ready-to-merge unit exits 0 without consuming it' 0 "$rt_rc"
if grep -q 'issue edit' "$GH_LOG"; then
  echo "not ok - run-triage edited a ready-to-merge issue's labels" >&2
  FAILED=1
else
  echo "ok - run-triage made no label edit on a ready-to-merge issue"
fi

# --- 2. batch claim drops busy members, claims the rest ----------------------
# Issue 200 has a live worker (this test process); 201 and 202 are free.
cat > "$RUNTIME/workers.json" <<EOF
{"workers":[{"pid":$$,"issue":200,"unit":"issue-200"}]}
EOF
cat > "$RUNTIME/units.json" <<'EOF'
{"units":[
  {"id":"issue-200","issue":200,"stage":"implement"},
  {"id":"issue-201","issue":201,"stage":"intake"},
  {"id":"issue-202","issue":202,"stage":"intake"}
]}
EOF
eval "$(sed -n '/^pipeline_batch_claim_acquire() {/,/^}/p' "$PIPELINE_SRC")"
claim_owner="$(coord_new_owner)"
issue_ids=(200 201 202)
claim_rc=0
pipeline_batch_claim_acquire "$claim_owner" advisor-batch zf-advisor-batch issue_ids 2> "$FIXTURES/claim-log" || claim_rc=$?
assert_eq 'batch claim succeeds with one busy member' 0 "$claim_rc"
assert_eq 'batch claim keeps the free members' '201 202' "${issue_ids[*]}"
if grep -q 'dropping #200' "$FIXTURES/claim-log"; then
  echo "ok - batch claim logs the dropped busy member"
else
  echo "not ok - batch claim did not log the dropped member: $(cat "$FIXTURES/claim-log")" >&2
  FAILED=1
fi
assert_eq 'free member 201 is claimed' 0 "$(coord_assert_owned "$(coord_issue_key 201)" "$claim_owner" >/dev/null 2>&1; echo $?)"
assert_eq 'free member 202 is claimed' 0 "$(coord_assert_owned "$(coord_issue_key 202)" "$claim_owner" >/dev/null 2>&1; echo $?)"
assert_eq 'busy member 200 is NOT claimed' 1 "$(coord_assert_owned "$(coord_issue_key 200)" "$claim_owner" >/dev/null 2>&1; echo $?)"
coord_release_many "$claim_owner" 201 202 >/dev/null 2>&1 || :

issue_ids=(200)
claim_rc=0
pipeline_batch_claim_acquire "$(coord_new_owner)" advisor-batch zf-advisor-batch issue_ids 2> "$FIXTURES/claim-empty-log" || claim_rc=$?
assert_eq 'all-busy batch is a no-op success, not an error' 0 "$claim_rc"
assert_eq 'all-busy batch leaves an empty member list' 0 "${#issue_ids[@]}"

# --- 3. the slice contract: 75 defers, 1 fails -------------------------------
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
mkdir -p "$AGENT_HOME"
gh() { printf 'triage\n'; }
check_gmail_credential() { :; }
manual_pause_is_valid() { return 1; }
roadmap_switch_value() { printf 'false\n'; }
LOCK_FILE="$FIXTURES/slice.lock"

cat > "$FIXTURES/scheduler-defer" <<'CHILD'
#!/usr/bin/env bash
flock -n 9 || exit 9
[ "$2" = advisor ] && exit 75
exit 0
CHILD
slice_rc=0
run_pipeline_slices "$FIXTURES/scheduler-defer" 2> "$FIXTURES/defer-log" || slice_rc=$?
assert_eq 'a slice exiting 75 does not fail the tick' 0 "$slice_rc"
grep -q 'slice deferred stage=advisor status=75' "$FIXTURES/defer-log" \
  && echo "ok - defer is logged like an overrun" \
  || { echo "not ok - defer line missing: $(cat "$FIXTURES/defer-log")" >&2; FAILED=1; }
grep -q 'slice-summary.*status=0' "$FIXTURES/defer-log" \
  && echo "ok - slice summary stays status=0 after a defer" \
  || { echo "not ok - slice summary not status=0: $(cat "$FIXTURES/defer-log")" >&2; FAILED=1; }

cat > "$FIXTURES/scheduler-fail" <<'CHILD'
#!/usr/bin/env bash
flock -n 9 || exit 9
[ "$2" = recut ] && exit 1
exit 0
CHILD
slice_rc=0
run_pipeline_slices "$FIXTURES/scheduler-fail" 2> "$FIXTURES/fail-log" || slice_rc=$?
assert_eq 'a slice exiting 1 still fails the tick' 1 "$slice_rc"
grep -q 'slice-summary.*status=1' "$FIXTURES/fail-log" \
  && echo "ok - slice summary reports status=1 for a real failure" \
  || { echo "not ok - slice summary not status=1: $(cat "$FIXTURES/fail-log")" >&2; FAILED=1; }
grep -q 'issue-pipeline: slice-failed tick=.* stage=recut status=1' "$RUNTIME/scheduler.log" \
  && echo "ok - failing slice leaves a durable bell-visible note" \
  || { echo "not ok - no slice-failed note in scheduler.log" >&2; FAILED=1; }

# --- 4. the bell scanner classifies the incident lines -----------------------
eval "$(sed -n '/^scheduler_signature_class() {/,/^}/p' "$SCRIPT_DIR/mac-autopilot/bell.sh")"
assert_eq 'tick refusal line gets an incident class' 'sched-run-tick-refused' \
  "$(scheduler_signature_class '[2026-11-03T05:23:11Z] run-tick: refusing to run this tick — cause=scheduler-failed observed=issue-pipeline.sh exited with status 1')"
assert_eq 'slice-failure line gets an incident class' 'sched-slice-failed' \
  "$(scheduler_signature_class '[2026-11-03T05:24:00Z] issue-pipeline: slice-failed tick=20261103T052311Z stage=advisor status=1')"
assert_eq 'a deferring slice line raises no incident' '' \
  "$(scheduler_signature_class '[2026-11-03T05:25:00Z] issue-pipeline: slice deferred stage=advisor status=75 (claim/admission said not-now); continuing other stages')"

[ "$FAILED" = 0 ] || exit 1
echo 'all tick-refuse guards passed'
