#!/usr/bin/env bash
# tick-refuse-guard.test.sh -- one busy issue or a claim miss must not refuse
# the whole pipeline tick (2026-11-03 incident):
#   1. triage never touches an issue whose scheduler unit is in flight
#      (rereview / ready-to-merge): selection skips it and run-triage.sh
#      leaves its labels unchanged;
#   2. advisor batch selection/acquisition drops in-flight units and live
#      workers, then claims the rest; an empty remainder is a no-op;
#   3. one failed slice is logged and isolated while later slices still run;
#      a member renewal miss drops that member without stopping the batch;
#   4. the bell scanner keys incidents by slice+status, so #166 deduplication
#      does not collapse different slice failures.
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
# case); 5042 merged is terminal; 5043 has no unit at all. Pending stage
# suffixes are in flight too, even before a worker PID exists.
cat > "$RUNTIME/units.json" <<'EOF'
{"units":[
  {"id":"issue-5040","issue":5040,"stage":"rereview"},
  {"id":"issue-5041","issue":5041,"stage":"ready-to-merge"},
  {"id":"issue-5044","issue":5044,"stage":"rereview-pending"},
  {"id":"issue-5045","issue":5045,"stage":"implement-pending"},
  {"id":"issue-5042","issue":5042,"stage":"merged"}
]}
EOF
printf '{"workers":[]}\n' > "$RUNTIME/workers.json"

# --- 1a. the unit-ledger predicate ------------------------------------------
assert_eq 'rereview unit is in flight' 0 "$(scheduler_issue_unit_inflight 5040 >/dev/null 2>&1; echo $?)"
assert_eq 'ready-to-merge unit is in flight' 0 "$(scheduler_issue_unit_inflight 5041 >/dev/null 2>&1; echo $?)"
assert_eq 'rereview-pending unit is in flight before a worker starts' 0 "$(scheduler_issue_unit_inflight 5044 >/dev/null 2>&1; echo $?)"
assert_eq 'implement-pending unit is in flight before a worker starts' 0 "$(scheduler_issue_unit_inflight 5045 >/dev/null 2>&1; echo $?)"
assert_eq 'merged unit is not in flight' 1 "$(scheduler_issue_unit_inflight 5042 >/dev/null 2>&1; echo $?)"
assert_eq 'issue without a unit is not in flight' 1 "$(scheduler_issue_unit_inflight 5043 >/dev/null 2>&1; echo $?)"
assert_eq 'missing ledger inside a live runtime is unknown (fail-closed)' 3 "$(scheduler_issue_unit_inflight 5040 "$RUNTIME/no-units.json" >/dev/null 2>&1; echo $?)"
printf '{"units":"not-an-array"}\n' > "$FIXTURES/bad-units.json"
assert_eq 'malformed ledger is unknown (fail-closed)' 3 "$(scheduler_issue_unit_inflight 5040 "$FIXTURES/bad-units.json" >/dev/null 2>&1; echo $?)"
assert_eq 'host without the scheduler runtime proceeds' 1 "$(scheduler_issue_unit_inflight 5040 "$FIXTURES/nohost/units.json" >/dev/null 2>&1; echo $?)"

# --- 1b. triage selection skips in-flight units ------------------------------
eval "$(sed -n '/^pipeline_live_worker_check() {/,/^}/p; /^pipeline_scheduler_unit_inflight() {/,/^}/p; /^pipeline_triage_skip_inflight() {/,/^}/p; /^pipeline_advisor_issue_skip_inflight() {/,/^}/p' "$PIPELINE_SRC")"
assert_eq 'triage selection skips a rereview unit' 0 "$(pipeline_triage_skip_inflight 5040 >/dev/null 2>&1; echo $?)"
assert_eq 'triage selection skips a ready-to-merge unit' 0 "$(pipeline_triage_skip_inflight 5041 >/dev/null 2>&1; echo $?)"
assert_eq 'advisor selection skips a rereview-pending unit' 0 "$(pipeline_advisor_issue_skip_inflight 5044 >/dev/null 2>&1; echo $?)"
assert_eq 'advisor selection proceeds for an issue without a scheduler unit' 1 "$(pipeline_advisor_issue_skip_inflight 5043 >/dev/null 2>&1; echo $?)"
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
# Issue 200 has a live worker (this test process); 201 and 202 are free;
# 204 and 205 have pending scheduler units but no workers yet.
cat > "$RUNTIME/workers.json" <<EOF
{"workers":[{"pid":$$,"issue":200,"unit":"issue-200"}]}
EOF
cat > "$RUNTIME/units.json" <<'EOF'
{"units":[
  {"id":"issue-200","issue":200,"stage":"implement"},
  {"id":"issue-204","issue":204,"stage":"rereview-pending"},
  {"id":"issue-205","issue":205,"stage":"implement-pending"}
]}
EOF
eval "$(sed -n '/^pipeline_scheduler_unit_inflight() {/,/^}/p; /^pipeline_advisor_issue_skip_inflight() {/,/^}/p; /^pipeline_batch_claim_acquire() {/,/^}/p' "$PIPELINE_SRC")"
claim_owner="$(coord_new_owner)"
issue_ids=(200 201 202 204 205)
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
assert_eq 'in-flight rereview member 204 is NOT claimed' 1 "$(coord_assert_owned "$(coord_issue_key 204)" "$claim_owner" >/dev/null 2>&1; echo $?)"
assert_eq 'in-flight implement member 205 is NOT claimed' 1 "$(coord_assert_owned "$(coord_issue_key 205)" "$claim_owner" >/dev/null 2>&1; echo $?)"
if grep -q 'dropping #204 (in-flight scheduler unit)' "$FIXTURES/claim-log"; then
  echo 'ok - batch claim logs the dropped in-flight member'
else
  echo "not ok - batch claim did not log in-flight member 204: $(cat "$FIXTURES/claim-log")" >&2
  FAILED=1
fi
coord_release_many "$claim_owner" 201 202 >/dev/null 2>&1 || :

issue_ids=(200)
claim_rc=0
pipeline_batch_claim_acquire "$(coord_new_owner)" advisor-batch zf-advisor-batch issue_ids 2> "$FIXTURES/claim-empty-log" || claim_rc=$?
assert_eq 'all-busy batch is a no-op success, not an error' 0 "$claim_rc"
assert_eq 'all-busy batch leaves an empty member list' 0 "${#issue_ids[@]}"

other_owner="$(coord_new_owner)"
coord_acquire "$(coord_issue_key 206)" "$other_owner" systemd-worker 206 zf-recut recut || { echo "not ok - could not hold member 206" >&2; exit 1; }
issue_ids=(201 206 202)
claim_owner="$(coord_new_owner)"
claim_rc=0
pipeline_batch_claim_acquire "$claim_owner" advisor-batch zf-advisor-batch issue_ids 2> "$FIXTURES/claim-held-log" || claim_rc=$?
assert_eq 'batch claim survives one member held by another owner' 0 "$claim_rc"
assert_eq 'held member leaves the batch and the rest stay' '201 202' "${issue_ids[*]}"
assert_eq 'member after the held one is claimed' 0 "$(coord_assert_owned "$(coord_issue_key 202)" "$claim_owner" >/dev/null 2>&1; echo $?)"
assert_eq 'held member keeps its own owner' 0 "$(coord_assert_owned "$(coord_issue_key 206)" "$other_owner" >/dev/null 2>&1; echo $?)"
coord_release_many "$claim_owner" 201 202 >/dev/null 2>&1 || :
coord_release_many "$other_owner" 206 >/dev/null 2>&1 || :

# --- 3a. one member renewal miss cannot stop the batch -----------------------
eval "$(sed -n '/^pipeline_batch_claim_drop() {/,/^}/p; /^pipeline_batch_claim_keep() {/,/^}/p' "$PIPELINE_SRC")"
RENEW_LOG="$FIXTURES/renew-log"
coord_issue_key() { printf 'issue:%s\n' "$1"; }
coord_renew() {
  printf 'renew %s\n' "$1" >> "$RENEW_LOG"
  [[ "$1" != issue:301 ]]
}
coord_release_many() { printf 'release %s\n' "$*" >> "$RENEW_LOG"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$RENEW_LOG"; }
: > "$RENEW_LOG"
renew_rc=0
pipeline_batch_claim_keep owner zf-advisor-batch 301 302 303 2> "$FIXTURES/renew-error" || renew_rc=$?
assert_eq 'one batch-member renewal failure remains non-fatal' 0 "$renew_rc"
assert_eq 'renewal continues through every remaining batch member' 3 "$(grep -c '^renew ' "$RENEW_LOG")"
grep -q '^release owner 301$' "$RENEW_LOG" \
  && echo 'ok - renewal failure drops only the failed member claim' \
  || { echo "not ok - failed member claim was not dropped: $(cat "$RENEW_LOG")" >&2; FAILED=1; }
if grep -q '^systemctl stop ' "$RENEW_LOG"; then
  echo 'not ok - one member renewal failure stopped the batch' >&2
  FAILED=1
else
  echo 'ok - one member renewal failure does not stop the batch unit'
fi

# --- 3b. a stage failure is isolated, later slices run, tick stays successful
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
mkdir -p "$AGENT_HOME"
gh() { printf 'triage\n'; }
check_gmail_credential() { :; }
manual_pause_is_valid() { return 1; }
roadmap_switch_value() { printf 'false\n'; }
LOCK_FILE="$FIXTURES/slice.lock"
for checkout_tag in checkout-restore-failed wrong-branch fetch-starved fetch-timeout fetch-failed diverged; do
  assert_eq "run-tick keeps checkout-integrity refusal $checkout_tag" 0 \
    "$(tick_checkout_integrity_refusal_tag "$checkout_tag" >/dev/null 2>&1; echo $?)"
done
assert_eq 'a scheduler slice failure is outside the checkout-integrity refusal set' 1 \
  "$(tick_checkout_integrity_refusal_tag scheduler-failed >/dev/null 2>&1; echo $?)"

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
printf '%s\n' "$2" >> "$STAGE_LOG"
[ "$2" = recut ] && exit 1
exit 0
CHILD
export STAGE_LOG="$FIXTURES/stages-ran"
:> "$STAGE_LOG"
slice_rc=0
run_pipeline_slices "$FIXTURES/scheduler-fail" 2> "$FIXTURES/fail-log" || slice_rc=$?
assert_eq 'a slice exiting 1 does not refuse the tick' 0 "$slice_rc"
for continued_stage in fastlane triage advisor maintenance; do
  grep -qx "$continued_stage" "$STAGE_LOG" \
    && echo "ok - later/other slice $continued_stage still runs" \
    || { echo "not ok - slice $continued_stage did not run: $(cat "$STAGE_LOG")" >&2; FAILED=1; }
done
grep -q 'slice-summary.*status=0' "$FIXTURES/fail-log" \
  && echo "ok - slice summary stays status=0 after an isolated failure" \
  || { echo "not ok - slice summary not status=0: $(cat "$FIXTURES/fail-log")" >&2; FAILED=1; }
grep -q 'issue-pipeline: slice-failed tick=.* stage=recut status=1' "$RUNTIME/scheduler.log" \
  && echo "ok - failing slice leaves a durable bell-visible note" \
  || { echo "not ok - no slice-failed note in scheduler.log" >&2; FAILED=1; }

# --- 4. the bell scanner classifies the incident lines -----------------------
eval "$(sed -n '/^scheduler_signature_class() {/,/^}/p' "$SCRIPT_DIR/mac-autopilot/bell.sh")"
assert_eq 'tick refusal line gets an incident class' 'sched-run-tick-refused' \
  "$(scheduler_signature_class '[2026-11-03T05:23:11Z] run-tick: refusing to run this tick — cause=scheduler-failed observed=issue-pipeline.sh exited with status 1')"
assert_eq 'slice-failure line gets an incident class' 'sched-slice-failed-advisor-1' \
  "$(scheduler_signature_class '[2026-11-03T05:24:00Z] issue-pipeline: slice-failed tick=20261103T052311Z stage=advisor status=1')"
assert_eq 'slice incident identity includes the failed stage and status' 'sched-slice-failed-advisor-1' \
  "$(scheduler_signature_class '[2026-11-03T05:24:00Z] issue-pipeline: slice-failed tick=20261103T052311Z stage=advisor status=1')"
assert_eq 'different statuses on the same stage have different incident identities' 'sched-slice-failed-advisor-2' \
  "$(scheduler_signature_class '[2026-11-03T05:24:00Z] issue-pipeline: slice-failed tick=20261103T052311Z stage=advisor status=2')"
assert_eq 'a deferring slice line raises no incident' '' \
  "$(scheduler_signature_class '[2026-11-03T05:25:00Z] issue-pipeline: slice deferred stage=advisor status=75 (claim/admission said not-now); continuing other stages')"

[ "$FAILED" = 0 ] || exit 1
echo 'all tick-refuse guards passed'
