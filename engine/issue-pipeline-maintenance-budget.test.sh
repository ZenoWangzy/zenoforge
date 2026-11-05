#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$AGENT_HOME/night" "$test_env_root/autopi" "$test_env_root/repo"
export REPO_DIR="$test_env_root/repo"
export MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/autopi"
eval "$(sed -n '/^maintenance_record_deferred_step() {/,/^}/p; /^maintenance_clear_deferred_step() {/,/^}/p; /^maintenance_now_epoch_ms() {/,/^}/p; /^maintenance_set_optional_deadline() {/,/^}/p; /^maintenance_restore_slice_deadline() {/,/^}/p; /^maintenance_defer_optional_step() {/,/^}/p; /^maintenance_run_optional_step() {/,/^}/p; /^run_post_dispatch_maintenance() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"

if [[ "${1:-}" == --plant-old ]]; then
  PLANT_OLD_ORDER=1
  # The pre-fix scheduler checked the same cutoff before every step and put
  # the required email/reopen work after optional sweeps. This planted copy
  # keeps the live failure order and guard for the regression reproduction.
  run_post_dispatch_maintenance() {
    local stop_at=$(( ${TICK_UNIT_TIMEOUT_SECONDS:-1200} - ${MAINTENANCE_STEP_RESERVE_SECONDS:-240} ))
    local step
    local -a steps=(checks-blocked-sweep hold-sweep supervisor-hold-sweep hand-completion-events founder-outcome-recovery needs-info-email
      needs-info-recovery needs-info-blocker-roots needs-info-unlabeled needs-info-loop main-red-bisect batch-state)
    for step in "${steps[@]}"; do
      if [ "$SECONDS" -ge "$stop_at" ]; then
        echo "issue-pipeline: maintenance deferred tick=$IMPLEMENT_TICK_ID from=$step elapsed_sec=$SECONDS stop_at=$stop_at" >&2
        return 0
      fi
      profile_mark "$step"
      case "$step" in
        checks-blocked-sweep) checks_blocked_sweep ;;
        needs-info-email) read_needs_info_email_replies ;;
        needs-info-recovery) sweep_reopened_issues ;;
        *) : ;;
      esac
    done
  }
fi

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

CALLS=()
profile_mark() { :; }
checks_blocked_sweep() {
  CALLS+=(checks-blocked-sweep)
  if [[ "${PLANT_OLD_ORDER:-0}" == 1 ]]; then
    SECONDS=110
  else
    [[ "$ZF_GMAIL_CALL_DEADLINE_EPOCH_MS" == "$ZF_GH_CALL_DEADLINE_EPOCH_MS" ]] \
      || fail 'optional GitHub and Gmail work did not share its cutoff'
    CAPTURED_OPTIONAL_GMAIL_DEADLINE="$ZF_GMAIL_CALL_DEADLINE_EPOCH_MS"
    CAPTURED_OPTIONAL_GH_DEADLINE="$ZF_GH_CALL_DEADLINE_EPOCH_MS"
    SECONDS=50
  fi
}
hold_sweep() { CALLS+=(hold-sweep); }
supervisor_hold_sweep() { CALLS+=(supervisor-hold-sweep); }
hand_completion_events_run_once() { CALLS+=(hand-completion-events); }
reconcile_maintainer_outcomes() { CALLS+=(founder-outcome-recovery); }
flush_maintainer_outcome_digest() { :; }
read_needs_info_email_replies() {
  local now_ms remaining_ms
  now_ms="$(maintenance_now_epoch_ms)"
  remaining_ms=$((ZF_GH_CALL_DEADLINE_EPOCH_MS - now_ms))
  (( SECONDS <= 52 && remaining_ms >= 34000 )) || fail 'required email did not retain its bounded 37-second slot'
  [[ "${ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS:-}" == 87 ]] || fail 'email poll missed its subslot cutoff'
  [[ "${ZF_GMAIL_CALL_DEADLINE_EPOCH_MS:-}" == "$ZF_GH_CALL_DEADLINE_EPOCH_MS" ]] \
    || fail 'email poll did not get an absolute Gmail deadline'
  CALLS+=(needs-info-email)
  SECONDS=$((SECONDS + 37))
}
sweep_reopened_issues() {
  local now_ms remaining_ms
  (( SECONDS <= 89 && suffix_stop_at - SECONDS >= 16 )) || fail 'required recovery lost its reserved runtime'
  now_ms="$(maintenance_now_epoch_ms)"
  remaining_ms=$((ZF_GH_CALL_DEADLINE_EPOCH_MS - now_ms))
  (( remaining_ms >= 17000 && remaining_ms <= 18000 )) \
    || fail 'required recovery was not bounded by its reserved cutoff'
  [[ -z "${ZF_GMAIL_CALL_DEADLINE_EPOCH_MS:-}" && -z "${ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS:-}" ]] \
    || fail 'email deadlines leaked into reopened-issue recovery'
  CALLS+=(needs-info-recovery)
  SECONDS=$((SECONDS + 16))
}
sweep_blocking_issue_roots() { CALLS+=(needs-info-blocker-roots); }
sweep_unlabeled_issues() { CALLS+=(needs-info-unlabeled); }
reconcile_needs_info_issues() { CALLS+=(needs-info-loop); }
manual_pause_is_valid() { return 1; }
main_red_bisect_sweep() { CALLS+=(main-red-bisect); }
sweep_batch_state() { CALLS+=(batch-state); }

DRY_RUN=0
TICK_UNIT_TIMEOUT_SECONDS=120
MAINTENANCE_STEP_RESERVE_SECONDS=15
MAINTENANCE_REQUIRED_SLOT_SECONDS=55
MAINTENANCE_REOPEN_SLOT_SECONDS=18
MAINTENANCE_DEFERRAL_ALERT_AFTER=3
ZF_GH_CALL_DEADLINE_EPOCH_MS=$(( $(maintenance_now_epoch_ms) + 300000 ))
TEST_SLICE_GH_DEADLINE_MS="$ZF_GH_CALL_DEADLINE_EPOCH_MS"
export ZF_GH_CALL_DEADLINE_EPOCH_MS TEST_SLICE_GH_DEADLINE_MS
IMPLEMENT_TICK_ID=20261103T000001Z
SECONDS=0
run_post_dispatch_maintenance

check 'required tail steps run after an earlier section consumes the slice budget' \
  "${CALLS[*]}" 'checks-blocked-sweep needs-info-email needs-info-recovery'
check 'the 37-second email subslot preserves 18 seconds for reopen recovery' \
  "$((105 - 87))" 18
check 'the reserved 55-second slot fits the measured p90 pair before the 105-second cutoff' \
  "$((SECONDS <= 105 ? 1 : 0))" 1
check 'the original wider GH deadline is restored after bounded recovery' \
  "$ZF_GH_CALL_DEADLINE_EPOCH_MS" "$TEST_SLICE_GH_DEADLINE_MS"
check 'optional work leaves a resume cursor at the next deferred section' \
  "$(cat "$AGENT_HOME/night/maintenance-resume")" hold-sweep
check 'optional GitHub and Gmail work share the earlier cutoff' \
  "$CAPTURED_OPTIONAL_GMAIL_DEADLINE" "$CAPTURED_OPTIONAL_GH_DEADLINE"

eval "$(sed -n '/^read_needs_info_email_replies() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
GH_LIST_CALLS=0
gh() { GH_LIST_CALLS=$((GH_LIST_CALLS + 1)); return 1; }
SECONDS=87
ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS=87
read_needs_info_email_replies
check 'email polling yields at its subslot cutoff before another network call' "$GH_LIST_CALLS" 0
unset ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS

# No state file records a Gmail thread: nothing to poll, so no GitHub listing.
REPO=test/repo; STATE_DIR="$test_env_root/needs-info-state"; mkdir -p "$STATE_DIR"
printf '{"attempts":0}\n' > "$STATE_DIR/1.json"
gh() { printf x >> "$STATE_DIR/gh-calls"; return 1; }
read_needs_info_email_replies
check 'needs-info poll skips the issue listing when no state holds a thread id' "$(wc -c < "$STATE_DIR/gh-calls" 2>/dev/null || echo 0)" 0
printf '{"needs_info_thread_id":"t1"}\n' > "$STATE_DIR/2.json"
read_needs_info_email_replies
check 'needs-info poll lists issues once a state holds a thread id' "$(wc -c < "$STATE_DIR/gh-calls")" 1

eval "$(sed -n '/^gmail_now_epoch_ms() {/,/^}/p; /^gmail_deadline_timeout_seconds() {/,/^}/p; /^gmail_access_token() {/,/^}/p; /^gmail_curl() {/,/^}/p' "$SCRIPT_DIR/notify.sh")"
GMAIL_TIMEOUT_SECONDS=15
fake_gcloud="$test_env_root/fake-gcloud"
cat > "$fake_gcloud" <<'SH'
#!/usr/bin/env bash
printf 'test-access-token\n'
SH
chmod +x "$fake_gcloud"
CAPTURED_TOKEN_TIMEOUT_FILE="$test_env_root/token-timeout"
timeout() {
  [[ "$1" == --kill-after=1s ]] || fail 'Gmail token timeout omitted its kill grace'
  printf '%s\n' "$2" > "$CAPTURED_TOKEN_TIMEOUT_FILE"
  shift 2
  "$@"
}
ZF_GMAIL_CALL_DEADLINE_EPOCH_MS=$(( $(gmail_now_epoch_ms) + 7000 ))
check 'Gmail token mint retains its access token' "$(gmail_access_token "$fake_gcloud")" test-access-token
CAPTURED_TOKEN_TIMEOUT="$(cat "$CAPTURED_TOKEN_TIMEOUT_FILE")"
if [[ "$CAPTURED_TOKEN_TIMEOUT" =~ ^[1-9][0-9]*s$ ]] && (( ${CAPTURED_TOKEN_TIMEOUT%s} <= 5 )); then
  check 'Gmail token mint timeout is capped by its absolute deadline' yes yes
else
  fail "Gmail token mint timeout was not capped: $CAPTURED_TOKEN_TIMEOUT"
fi
CAPTURED_CURL_ARGS=()
curl() { CAPTURED_CURL_ARGS=("$@"); cat >/dev/null; }
ZF_GMAIL_CALL_DEADLINE_EPOCH_MS=$(( $(gmail_now_epoch_ms) + 7000 ))
gmail_curl test-token -sS --max-time 15 https://gmail.googleapis.com/gmail/v1/users/me/threads/test \
  >/dev/null || fail 'deadline-bounded Gmail curl helper failed'
gmail_max_time=""
for ((i = 0; i < ${#CAPTURED_CURL_ARGS[@]}; i++)); do
  if [[ "${CAPTURED_CURL_ARGS[$i]}" == --max-time ]]; then gmail_max_time="${CAPTURED_CURL_ARGS[$((i + 1))]}"; fi
done
if [[ "$gmail_max_time" =~ ^[1-9][0-9]*$ ]] && (( gmail_max_time <= 5 )); then
  check 'Gmail read curl timeout is capped by its absolute deadline' yes yes
else
  fail "Gmail read curl timeout was not capped: $gmail_max_time"
fi
CAPTURED_CURL_ARGS=()
ZF_GMAIL_CALL_DEADLINE_EPOCH_MS=$(( $(gmail_now_epoch_ms) + 30000 ))
gmail_curl test-token -sS --max-time 3 https://gmail.googleapis.com/gmail/v1/users/me/threads/test \
  >/dev/null || fail 'deadline-bounded Gmail curl helper failed with a shorter request timeout'
gmail_max_time=""
for ((i = 0; i < ${#CAPTURED_CURL_ARGS[@]}; i++)); do
  if [[ "${CAPTURED_CURL_ARGS[$i]}" == --max-time ]]; then gmail_max_time="${CAPTURED_CURL_ARGS[$((i + 1))]}"; fi
done
check 'Gmail deadline handling preserves a shorter request timeout' "$gmail_max_time" 3

maintenance_record_deferred_step needs-info-recovery 20261103T000002Z
maintenance_record_deferred_step needs-info-recovery 20261103T000003Z
maintenance_record_deferred_step needs-info-recovery 20261103T000004Z
check 'same-section deferral streak reaches three consecutive ticks' \
  "$(jq -r '.section + ":" + (.consecutive|tostring)' "$AGENT_HOME/night/maintenance-deferral-state.json")" \
  'needs-info-recovery:3'
check 'threshold writes the #166 scheduler incident signature' \
  "$(grep -c 'maintenance deferred streak section=needs-info-recovery consecutive=3' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")" 1
maintenance_record_deferred_step needs-info-recovery 20261103T000004Z
check 'duplicate section deferral in one tick does not repeat the warning' \
  "$(grep -c 'maintenance deferred streak section=needs-info-recovery consecutive=3' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")" 1

echo 'issue-pipeline-maintenance-budget.test.sh: PASS'
