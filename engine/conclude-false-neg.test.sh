#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
FAILED=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; FAILED=1; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "ok - $desc"; else echo "not ok - $desc"; FAILED=1; fi
}

CODEX_PROVIDER_FAILURE_EVENTS_FILE="$AGENT_HOME/codex-provider-outage-events.log"
CODEX_PROVIDER_PROBE_REQUIRED_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-required"
CODEX_PROVIDER_PROBE_NOTICE_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-notice-sent"
: > "$AGENT_HOME/supervisor-inbox"
assert_eq "WebSocket closure followed by 401 is provider-side outage" \
  websocket-401 "$(premium_call_provider_outage_kind $'ERROR: websocket closed by server before response.completed\nERROR: unexpected status 401 Unauthorized' || true)"
assert_eq "standalone configuration 401 remains real failure" \
  "" "$(premium_call_provider_outage_kind 'ERROR: unexpected status 401 Unauthorized: Incorrect API key provided' || true)"
assert_eq "stream disconnect is provider-side outage" \
  stream-disconnected "$(premium_call_provider_outage_kind 'stream disconnected before completion' || true)"
assert_eq "provider 503 is provider-side outage" \
  provider-5xx "$(premium_call_provider_outage_kind 'unexpected status 503 Service Unavailable' || true)"
assert_eq "exhausted reconnects with no final output are provider-side outage" \
  reconnect-exhausted "$(premium_call_provider_outage_kind $'ERROR: Reconnecting... 5/5\ncodex-final-output-present=false' || true)"
assert_eq "exhausted reconnects after model output remain real failure" \
  "" "$(premium_call_provider_outage_kind $'ERROR: Reconnecting... 5/5\ncodex-final-output-present=true' || true)"

MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
jq '.escalation.steps = ([.escalation.steps[] | select(.name != "conclude")] + [{"name":"production","role":"production","on_failure":"conclude"},{"name":"conclude"}]) | (.escalation.steps[] | select(.name == "work_retry").on_failure) = "production" | .roles.advisor.disabled = false' \
  "$SCRIPT_DIR/model-policy.default.json" > "$MODEL_POLICY_FILE"

state_merge 509901 '{"attempts":2,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry"}}}'
route_to_advisor() { :; }
record_run_decision() { :; }
conclude_run() { :; }
model_policy_record_failure 509901 work_retry implement "local timeout" "exit 124" 124 ready-for-agent implement 1
TIMEOUT_STATE="$(state_read 509901)"
assert_eq "exit 124 preserves the current escalation step" work_retry "$(jq -r '.model_policy.step' <<< "$TIMEOUT_STATE")"
assert_eq "exit 124 refunds the charged attempt" 1 "$(jq -r '.attempts' <<< "$TIMEOUT_STATE")"
assert_eq "exit 124 records retry context" 124 "$(jq -r '.model_policy.retry_note.status' <<< "$TIMEOUT_STATE")"
assert_eq "exit 124 does not append an escalation failure" 0 "$(jq -r '(.model_policy.failures // []) | length' <<< "$TIMEOUT_STATE")"
assert_eq "exit 124 clears the active unit" true "$(jq -e '.model_policy.active == null' >/dev/null <<< "$TIMEOUT_STATE" && echo true || echo false)"

state_merge 509912 '{"attempts":2,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry"}}}'
CI_INFRA_STATUS=0
model_policy_record_failure 509912 work_retry implement "CI runner capacity gate failed" "Ensure CI runner has capacity before dependency install: insufficient disk" 1 ready-for-agent implement 1 || CI_INFRA_STATUS=$?
CI_INFRA_STATE="$(state_read 509912)"
assert_eq "explicit CI infrastructure retry records successfully" 0 "$CI_INFRA_STATUS"
assert_eq "explicit CI infrastructure retry keeps current policy rung" work_retry "$(jq -r '.model_policy.step' <<< "$CI_INFRA_STATE")"
assert_eq "explicit CI infrastructure retry refunds the charged attempt" 1 "$(jq -r '.attempts' <<< "$CI_INFRA_STATE")"
assert_eq "explicit CI infrastructure retry records its concrete reason" \
  "CI runner capacity gate failed" "$(jq -r '.model_policy.retry_note.reason' <<< "$CI_INFRA_STATE")"
assert_eq "explicit CI infrastructure retry persists refund evidence" true \
  "$(jq -r '.model_policy.retry_note.attempt_refunded' <<< "$CI_INFRA_STATE")"
assert_eq "explicit CI infrastructure retry avoids code-failure ladder" 0 "$(jq -r '(.model_policy.failures // []) | length' <<< "$CI_INFRA_STATE")"

state_merge 509906 '{"attempts":2,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true}}}'
OUTAGE_LOG=$'ERROR: websocket closed by server before response.completed\nERROR: unexpected status 401 Unauthorized'
pause_for_backoff 509906 "$OUTAGE_LOG" 1 0 codex "$MODEL_POLICY_TEST_WORK_IDENTITY" run-implement:implement
model_policy_record_failure 509906 work_retry implement "Codex transport failed" "$OUTAGE_LOG" 1 ready-for-agent implement 0
OUTAGE_STATE="$(state_read 509906)"
assert_eq "provider outage preserves current model rung" work_retry "$(jq -r '.model_policy.step' <<< "$OUTAGE_STATE")"
assert_eq "provider outage refunds charged attempt" 1 "$(jq -r '.attempts' <<< "$OUTAGE_STATE")"
assert_eq "provider outage records actual exit status for retry" 1 "$(jq -r '.model_policy.retry_note.status' <<< "$OUTAGE_STATE")"
assert_eq "provider outage does not append escalation failure" 0 "$(jq -r '(.model_policy.failures // []) | length' <<< "$OUTAGE_STATE")"

for issue in 509907 509908; do
  state_merge "$issue" '{"attempts":1,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true}}}'
  pause_for_backoff "$issue" "$OUTAGE_LOG" 1 0 codex "$MODEL_POLICY_TEST_WORK_IDENTITY" run-implement:implement
  model_policy_record_failure "$issue" work_retry implement "Codex transport failed" "$OUTAGE_LOG" 1 ready-for-agent implement 0
  if [ "$issue" = 509907 ]; then
    state_merge "$issue" '.attempts = 1 | .model_policy.active = {unit:"implement",step:"work_retry",model_started:true}'
    pause_for_backoff "$issue" "$OUTAGE_LOG" 1 0 codex "$MODEL_POLICY_TEST_WORK_IDENTITY" run-implement:implement
    model_policy_record_failure "$issue" work_retry implement "Codex transport failed" "$OUTAGE_LOG" 1 ready-for-agent implement 0
    assert_eq "repeat failures from one issue do not trip circuit" false "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"
  fi
done
assert_eq "three distinct issues trip provider circuit" true "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"
assert_eq "provider circuit uses quota dispatch marker" true "$([ -f "$CODEX_EXHAUSTED_MARKER_FILE" ] && echo true || echo false)"
assert_eq "provider circuit emits one supervisor notice" 1 "$(wc -l < "$AGENT_HOME/supervisor-inbox" | tr -d '[:space:]')"

PROBE_BIN="$AGENT_HOME/probe-bin"
mkdir -p "$PROBE_BIN"
cat > "$PROBE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -eu
out_file=""
printf '%s\n' "$*" >> "$CODEX_PROBE_ARGS_FILE"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message) out_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'probe\n' >> "$CODEX_PROBE_ORDER_FILE"
cat > "$CODEX_PROBE_PROMPT_FILE"
if [ "${FAKE_CODEX_PROBE_STATUS:-0}" -eq 0 ]; then
  printf 'OK\n' > "$out_file"
  exit 0
fi
printf '%s\n' "${FAKE_CODEX_PROBE_ERROR:-unexpected status 401 Unauthorized: Incorrect API key provided}" >&2
exit "$FAKE_CODEX_PROBE_STATUS"
EOF
chmod +x "$PROBE_BIN/codex"
REAL_TIMEOUT_BIN="$(command -v timeout)"
cat > "$PROBE_BIN/timeout" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAKE_TIMEOUT_LOG:-}" ]; then
  has_codex=0 duration=''
  for arg; do
    [[ "\$arg" == codex ]] && has_codex=1
    [[ "\$arg" =~ ^[0-9]+s$ ]] && duration="\$arg"
  done
  [ "\$has_codex" = 1 ] && [ -n "\$duration" ] && printf '%s\\n' "\$duration" > "\$FAKE_TIMEOUT_LOG"
fi
exec "$REAL_TIMEOUT_BIN" "\$@"
EOF
chmod +x "$PROBE_BIN/timeout"
PATH="$PROBE_BIN:$PATH"
export PATH
CODEX_PROBE_ORDER_FILE="$AGENT_HOME/probe-order.log"
CODEX_PROBE_PROMPT_FILE="$AGENT_HOME/probe-prompt.txt"
CODEX_PROBE_ARGS_FILE="$AGENT_HOME/probe-args.log"
export CODEX_PROBE_ORDER_FILE CODEX_PROBE_PROMPT_FILE CODEX_PROBE_ARGS_FILE

PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
eval "$(sed -n '/^recover_stale_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
eval "$(sed -n '/^dispatch_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
eval "$(sed -n '/^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p' "$PIPELINE_SRC")"
agent_implement_dispatch_resources_allow() { return 0; }
stage_unit_active() { return 1; }
# This test isolates stalled-unit recovery; OOM accounting lives in issue-pipeline.test.sh.
consume_unit_memory_oom() { return 1; }
codex_probe_ok() { return 0; }
dispatch() { printf 'dispatch\n' >> "$CODEX_PROBE_ORDER_FILE"; DISPATCHED="$1:$2"; }
state_merge 509909 '{"attempts":0,"model_policy":{"unit":"implement","step":"work_retry"}}'
# A legacy thirty-minute marker must not suppress a due half-open probe.
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
: > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
DISPATCHED=""
assert_eq "due recovery passes the outer quota gate before dispatch" false "$(codex_quota_exhausted && echo true || echo false)"
dispatch_policy_unit implement 509909 ready-for-agent 1
assert_eq "bare Codex probe completes before work dispatch resumes" $'probe\ndispatch' "$(cat "$CODEX_PROBE_ORDER_FILE")"
assert_eq "probe uses fixed empty-context prompt" "Reply with exactly: OK." "$(cat "$CODEX_PROBE_PROMPT_FILE")"
assert_contains "recovery probe uses low reasoning effort" "$(cat "$CODEX_PROBE_ARGS_FILE")" "model_reasoning_effort=low"
assert_eq "successful probe clears circuit latch" false "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"
assert_eq "work dispatch charges attempt only after probe" 1 "$(state_read 509909 | jq -r '.attempts')"

WINDOW_NOW="$(date +%s)"
printf '%s\t509911\tstream-disconnected\n' "$((WINDOW_NOW - CODEX_PROVIDER_FAILURE_WINDOW_SECONDS - 1))" > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
note_codex_provider_outage 509912 stream-disconnected test codex:test "$WINDOW_NOW"
note_codex_provider_outage 509913 stream-disconnected test codex:test "$WINDOW_NOW"
assert_eq "provider circuit expires failures outside its 15-minute window" false "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"

CODEX_IMPLEMENT_PROMPT="$AGENT_HOME/codex-implement-prompt.txt"
printf 'small fixture prompt\n' > "$CODEX_IMPLEMENT_PROMPT"
WORK_IDENTITY="$(model_policy identity work)"
WORK_SPEC="${WORK_IDENTITY#codex:}"
WORK_MODEL="${WORK_SPEC%:*}"
WORK_EFFORT="${WORK_SPEC##*:}"
# Holding both identities proves a provider outage cannot be bypassed by switching models.
codex_model_capacity_hold "$WORK_IDENTITY" "$(( $(date +%s) + 90 ))"
WORK_FALLBACK_IDENTITY="$(model_policy fallback-identity work 2>/dev/null || true)"
if [ -n "$WORK_FALLBACK_IDENTITY" ]; then
  codex_model_capacity_hold "$WORK_FALLBACK_IDENTITY" "$(( $(date +%s) + 90 ))"
fi
state_merge 509914 '{"attempts":0,"model_policy":{"unit":"implement","step":"work_retry"}}'
DISPATCHED=""
CAPACITY_DISPATCH_STATUS=0
dispatch_policy_unit implement 509914 ready-for-agent 1 || CAPACITY_DISPATCH_STATUS=$?
assert_eq "capacity-held policy rung returns model-specific defer" 74 "$CAPACITY_DISPATCH_STATUS"
assert_eq "capacity-held policy rung does not dispatch" "" "$DISPATCHED"
assert_eq "capacity-held policy rung leaves attempt count unchanged" 0 "$(state_read 509914 | jq -r '.attempts')"
rm -f "$(codex_model_capacity_marker_file "$WORK_IDENTITY")"
if [ -n "$WORK_FALLBACK_IDENTITY" ]; then
  rm -f "$(codex_model_capacity_marker_file "$WORK_FALLBACK_IDENTITY")"
fi
FAKE_CODEX_PROBE_STATUS=1
FAKE_CODEX_PROBE_ERROR='ERROR: Reconnecting... 5/5'
export FAKE_CODEX_PROBE_STATUS FAKE_CODEX_PROBE_ERROR
CODEX_IMPLEMENT_STATUS=0
run_codex_implement "$REPO_DIR" "$WORK_MODEL" "$WORK_EFFORT" "$CODEX_IMPLEMENT_PROMPT" "$AGENT_HOME/codex-implement-failed.log" 1 || CODEX_IMPLEMENT_STATUS=$?
assert_eq "fake implement fails with reconnect signature" 1 "$CODEX_IMPLEMENT_STATUS"
assert_eq "failed implement transcript records no final model output" true "$(grep -q 'codex-final-output-present=false' "$AGENT_HOME/codex-implement-failed.log" && echo true || echo false)"
assert_eq "reconnect exhaustion reaches provider classifier from implement log" reconnect-exhausted "$(premium_call_provider_outage_kind "$(cat "$AGENT_HOME/codex-implement-failed.log")" || true)"
FAKE_CODEX_PROBE_STATUS=0
unset FAKE_CODEX_PROBE_ERROR
export FAKE_CODEX_PROBE_STATUS
run_codex_implement "$REPO_DIR" "$WORK_MODEL" "$WORK_EFFORT" "$CODEX_IMPLEMENT_PROMPT" "$AGENT_HOME/codex-implement-success.log" 1
assert_eq "successful implement transcript records final model output" true "$(grep -q 'codex-final-output-present=true' "$AGENT_HOME/codex-implement-success.log" && echo true || echo false)"
unset FAKE_CODEX_PROBE_STATUS

: > "$CODEX_PROBE_ORDER_FILE"
state_merge 509910 '{"attempts":0,"model_policy":{"unit":"implement","step":"work_retry"}}'
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
: > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
FAKE_CODEX_PROBE_STATUS=1
export FAKE_CODEX_PROBE_STATUS
DISPATCHED=""
PROBE_DISPATCH_STATUS=0
dispatch_policy_unit implement 509910 ready-for-agent 1 || PROBE_DISPATCH_STATUS=$?
assert_eq "bad-config 401 probe keeps work held" 77 "$PROBE_DISPATCH_STATUS"
assert_eq "bad-config 401 probe does not dispatch or charge work" "" "$DISPATCHED"
assert_eq "bad-config 401 probe is visible without printing key" true "$(grep -q 'authentication/configuration' "$AGENT_HOME/supervisor-inbox" && echo true || echo false)"
assert_eq "bad-config 401 probe transcript stays redacted" false "$(grep -q 'Incorrect API key' "$AGENT_HOME/supervisor-inbox" && echo true || echo false)"
# Failed probes use an independent short deadline; calls before it cannot probe again.
probe_count="$(wc -l < "$CODEX_PROBE_ORDER_FILE")"
assert_eq "failed probe schedules recovery in 90 seconds" true "$(test "$(cat "$CODEX_PROVIDER_PROBE_REQUIRED_FILE")" -le "$(( $(date +%s) + 90 ))" && echo true || echo false)"
codex_provider_recovery_probe_if_due "$WORK_IDENTITY" || true
assert_eq "recovery attempts stay bounded until next due time" "$probe_count" "$(wc -l < "$CODEX_PROBE_ORDER_FILE")"
# Timeout uses the configured Codex call budget; exit 124 cannot re-arm provider hold.
: > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
rm -f "$CODEX_EXHAUSTED_MARKER_FILE"
FAKE_CODEX_PROBE_STATUS=124
export FAKE_CODEX_PROBE_STATUS
CODEX_JSON_TIMEOUT_SECONDS=123
export CODEX_JSON_TIMEOUT_SECONDS
FAKE_TIMEOUT_LOG="$AGENT_HOME/probe-timeout.txt"
export FAKE_TIMEOUT_LOG
probe_timeout_status=0
codex_provider_recovery_probe_if_due "$WORK_IDENTITY" >/dev/null 2>&1 || probe_timeout_status=$?
assert_eq "probe exit 124 clears recovery latch without failing provider gate" 0 "$probe_timeout_status"
assert_eq "probe timeout comes from configured Codex call budget" 123s "$(cat "$AGENT_HOME/probe-timeout.txt")"
assert_eq "probe exit 124 does not re-arm provider-wide marker" false "$([ -e "$CODEX_EXHAUSTED_MARKER_FILE" ] && echo true || echo false)"
assert_eq "probe exit 124 clears provider-wide recovery latch" false "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"
assert_eq "probe exit 124 does not block another model reservation" 0 "$(codex_budget_reserve work probe-timeout-check 1 1 "" "$WORK_IDENTITY" >/dev/null 2>&1 && echo 0 || echo $?)"
codex_budget_release probe-timeout-check
unset CODEX_JSON_TIMEOUT_SECONDS FAKE_TIMEOUT_LOG
FAKE_CODEX_PROBE_STATUS=0
export FAKE_CODEX_PROBE_STATUS
probe_count="$(wc -l < "$CODEX_PROBE_ORDER_FILE")"
# Genuine quota refusal keeps its original deadline even with a due outage probe.
: > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$CODEX_EXHAUSTED_MARKER_FILE.alerted"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
assert_eq "real quota hold blocks recovery probe" true "$(codex_quota_exhausted && echo true || echo false)"
assert_eq "real quota hold makes no model call" "$probe_count" "$(wc -l < "$CODEX_PROBE_ORDER_FILE")"
rm -f "$CODEX_EXHAUSTED_MARKER_FILE.alerted"
unset FAKE_CODEX_PROBE_STATUS
rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CODEX_PROVIDER_PROBE_NOTICE_FILE"

# The local model circuit already owns egress failure; many affected issues are one incident.
: > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
for issue in 509920 509921 509922; do
  note_codex_provider_outage "$issue" network-egress test "$WORK_IDENTITY"
done
assert_eq "shared egress blip never counts as distinct provider issue failures" false "$([ -s "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" ] && echo true || echo false)"
assert_eq "shared egress blip never opens provider hold" false "$([ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && echo true || echo false)"
assert_eq "egress issue retry is bounded by recovery interval" true "$(state_read 509922 | jq -e --argjson now "$(date +%s)" '.model_failure_backoff.until_epoch <= ($now + 90)' >/dev/null && echo true || echo false)"

# Simulate an eight-second blip without sleeping. All quota/dispatch callers use real gates.
PROBE_TEST_NOW="$(date +%s)"
PROBE_TEST_START="$PROBE_TEST_NOW"
date() { if [ "$*" = +%s ]; then printf '%s\n' "$PROBE_TEST_NOW"; else command date "$@"; fi; }
for issue in 509930 509931 509932; do
  note_codex_provider_outage "$issue" stream-disconnected test "$WORK_IDENTITY" "$PROBE_TEST_NOW"
done
# Preserve a legacy 30-minute hold to prove the probe deadline owns recovery.
printf '%s\n' "$((PROBE_TEST_START + 1800))" > "$CODEX_EXHAUSTED_MARKER_FILE"
: > "$CODEX_PROBE_ORDER_FILE"
PROBE_TEST_NOW=$((PROBE_TEST_START + 89))
assert_eq "simulated blip remains held before half-open deadline" true "$(codex_quota_exhausted && echo true || echo false)"
assert_eq "no premature recovery model calls" 0 "$(wc -l < "$CODEX_PROBE_ORDER_FILE")"
PROBE_TEST_NOW=$((PROBE_TEST_START + 90))
state_merge 509930 '.model_failure_backoff.until_epoch += 1800'
state_merge 509931 '.model_failure_backoff.timestamp = "2999-01-01T00:00:00Z"'
state_merge 509932 '.model_failure_backoff.reason = "CI runner failure"'
codex_config_probe() { return 0; }
codex_dispatch_preflight issue-pipeline
assert_eq "scheduler entry probes before candidate backoff filtering" probe "$(cat "$CODEX_PROBE_ORDER_FILE")"
assert_eq "successful recovery clears legacy issue outage backoff" 0 "$(issue_model_failure_backoff_remaining 509930)"
assert_eq "successful recovery preserves newer issue failure" "2999-01-01T00:00:00Z" "$(state_read 509931 | jq -r '.model_failure_backoff.timestamp')"
assert_eq "successful recovery preserves unrelated failure" "CI runner failure" "$(state_read 509932 | jq -r '.model_failure_backoff.reason')"
state_merge 509933 '{"attempts":0,"model_policy":{"unit":"implement","step":"work_retry"}}'
dispatch_policy_unit implement 509933 ready-for-agent 1
assert_eq "simulated blip resumes dispatch at 90 seconds versus legacy 1800" $'probe\ndispatch' "$(cat "$CODEX_PROBE_ORDER_FILE")"
assert_eq "recovered dispatch is charged once" 1 "$(state_read 509933 | jq -r '.attempts')"
# Hand/node dispatch meets the budget gate before any issue-policy gate.
: > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
printf '%s\n' "$((PROBE_TEST_NOW + 1800))" > "$CODEX_EXHAUSTED_MARKER_FILE"
: > "$CODEX_PROBE_ORDER_FILE"
assert_eq "hand budget admission probes due provider recovery" 0 "$(codex_budget_reserve work egress-recovery-check 1 2>/dev/null && echo 0 || echo $?)"
assert_eq "budget recovery performs one bare probe" probe "$(cat "$CODEX_PROBE_ORDER_FILE")"
codex_budget_release egress-recovery-check
unset -f date

state_merge 509902 '{"model_policy":{"unit":"implement","step":"production"}}'
DISPATCHED=""
dispatch_policy_unit implement 509902 ready-for-agent 0
assert_eq "configured production rung dispatches its configured role" implement:509902 "$DISPATCHED"
assert_eq "configured production rung remains current while running" production "$(state_read 509902 | jq -r '.model_policy.active.step')"

state_merge 509905 '{"attempts":1,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true}}}'
DISPATCHED=""
STALLED_DISPATCH_STATUS=0
dispatch_policy_unit implement 509905 ready-for-agent 0 || STALLED_DISPATCH_STATUS=$?
STALLED_STATE="$(state_read 509905)"
assert_eq "stalled implement unit is deferred for later retry" 78 "$STALLED_DISPATCH_STATUS"
assert_eq "stalled implement unit does not advance the policy step" work_retry "$(jq -r '.model_policy.step' <<< "$STALLED_STATE")"
assert_eq "stalled implement unit refunds dispatch attempt" 0 "$(jq -r '.attempts' <<< "$STALLED_STATE")"
assert_eq "stalled implement unit records retry note" 124 "$(jq -r '.model_policy.retry_note.status' <<< "$STALLED_STATE")"
assert_eq "stalled implement unit is not redispatched in the same pass" "" "$DISPATCHED"

state_merge 509913 '{"attempts":1,"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true}}}'
agent_implement_dispatch_resources_allow() { return 1; }
RESOURCE_BLOCKED_STALE_STATUS=0
dispatch_policy_unit implement 509913 ready-for-agent 0 || RESOURCE_BLOCKED_STALE_STATUS=$?
RESOURCE_BLOCKED_STALE_STATE="$(state_read 509913)"
assert_eq "stale unit recovery runs before current resource admission" 78 "$RESOURCE_BLOCKED_STALE_STATUS"
assert_eq "stale unit recovery refunds attempt despite current resource pressure" 0 "$(jq -r '.attempts' <<< "$RESOURCE_BLOCKED_STALE_STATE")"
agent_implement_dispatch_resources_allow() { return 0; }

state_merge 509914 '{"attempts":2,"unit_results":{"implement":{"result":"success","exit_status":0}},"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true,"dispatched_at":"2026-09-27T10:00:00Z"},"failure":{"stage":"review_verdict","reason":"review rejected the change","recorded_at":"2026-09-27T10:01:00Z"}}}'
RECORDED_CODE_FAILURE_STATUS=0
dispatch_policy_unit implement 509914 ready-for-agent 0 || RECORDED_CODE_FAILURE_STATUS=$?
RECORDED_CODE_FAILURE_STATE="$(state_read 509914)"
assert_eq "stale marker with a post-dispatch code failure is cleared without refund" 78 "$RECORDED_CODE_FAILURE_STATUS"
assert_eq "recorded code failure keeps its charged attempt" 2 "$(jq -r '.attempts' <<< "$RECORDED_CODE_FAILURE_STATE")"
assert_eq "recorded code failure is not rewritten as transient infrastructure" true \
  "$(jq -e '.model_policy.retry_note == null' >/dev/null <<< "$RECORDED_CODE_FAILURE_STATE" && echo true || echo false)"

state_merge 509915 '{"attempts":2,"unit_results":{"implement":{"result":"exit-code","exit_status":"1"}},"model_policy":{"unit":"implement","step":"work_retry","active":{"unit":"implement","step":"work_retry","model_started":true,"dispatched_at":"2026-09-27T10:00:00Z"}}}'
CRASHED_AFTER_MODEL_STATUS=0
dispatch_policy_unit implement 509915 ready-for-agent 0 || CRASHED_AFTER_MODEL_STATUS=$?
CRASHED_AFTER_MODEL_STATE="$(state_read 509915)"
assert_eq "wrapper exit after the model ran is deferred for retry" 78 "$CRASHED_AFTER_MODEL_STATUS"
assert_eq "wrapper exit after the model ran keeps its charged attempt" 2 "$(jq -r '.attempts' <<< "$CRASHED_AFTER_MODEL_STATE")"

MODEL_POLICY_FILE="$SCRIPT_DIR/model-policy.default.json"
export MODEL_POLICY_FILE
state_merge 509903 '{"model_policy":{"unit":"implement","step":"production","failure":{"reason":"prior work failed"}}}'
LEGACY_DISPATCH_STATUS=0
dispatch_policy_unit implement 509903 ready-for-agent 0 || LEGACY_DISPATCH_STATUS=$?
LEGACY_STATE="$(state_read 509903)"
assert_eq "legacy unconfigured production step exits through conclude handoff" 78 "$LEGACY_DISPATCH_STATUS"
assert_contains "unconfigured legacy production skip records its reason" "$(jq -r '.model_policy.skipped_steps[-1].reason // empty' <<< "$LEGACY_STATE")" "not present in the active model policy"
assert_eq "unconfigured legacy production step reaches terminal policy step" conclude "$(jq -r '.model_policy.step' <<< "$LEGACY_STATE")"

state_merge 509904 '{"attempts":0,"model_policy":{"unit":"triage","step":"work"}}'
model_policy_record_failure 509904 work triage "triage timeout" "exit 124" 124 needs-triage triage 0
NO_CHARGE_STATE="$(state_read 509904)"
assert_eq "timeout without a charged attempt stays at zero" 0 "$(jq -r '.attempts' <<< "$NO_CHARGE_STATE")"
model_policy_complete_unit 509904 triage
COMPLETED_TIMEOUT_STATE="$(state_read 509904)"
assert_eq "successful retry archives and clears transient note" true "$(jq -e '.model_policy.retry_note == null and .model_policy.history[-1].retry_note.status == 124' >/dev/null <<< "$COMPLETED_TIMEOUT_STATE" && echo true || echo false)"

assert_true "quarantined advisor skip is recorded" grep -qF 'skipped quarantine' "$PIPELINE_SRC"

ROUTE_FIXTURE_DIR="$(mktemp -d)"
ROUTE_FIXTURE_REPO="$ROUTE_FIXTURE_DIR/repo"
git init -q --initial-branch=main "$ROUTE_FIXTURE_REPO"
git -C "$ROUTE_FIXTURE_REPO" config user.name test
git -C "$ROUTE_FIXTURE_REPO" config user.email test@example.invalid
mkdir -p "$ROUTE_FIXTURE_REPO/engine" "$ROUTE_FIXTURE_REPO/packages/example-service"
printf 'base\n' > "$ROUTE_FIXTURE_REPO/README.md"
git -C "$ROUTE_FIXTURE_REPO" add .
git -C "$ROUTE_FIXTURE_REPO" commit -qm 'test: seed route fixture'
printf 'pipeline\n' > "$ROUTE_FIXTURE_REPO/engine/change.sh"
git -C "$ROUTE_FIXTURE_REPO" add .
git -C "$ROUTE_FIXTURE_REPO" commit -qm '[skip ci] fix: landed pipeline work (issue 509905)'
PIPELINE_SHA="$(git -C "$ROUTE_FIXTURE_REPO" rev-parse HEAD)"
printf 'product\n' > "$ROUTE_FIXTURE_REPO/packages/example-service/change.ts"
git -C "$ROUTE_FIXTURE_REPO" add .
git -C "$ROUTE_FIXTURE_REPO" commit -qm 'fix(#509907): landed product work'
PRODUCT_SHA="$(git -C "$ROUTE_FIXTURE_REPO" rev-parse HEAD)"
# A pipeline fix that cites a product issue (issue 1254 and c205d6ad4) is not that issue's delivery.
printf 'cited\n' > "$ROUTE_FIXTURE_REPO/engine/cited.sh"
git -C "$ROUTE_FIXTURE_REPO" add .
git -C "$ROUTE_FIXTURE_REPO" commit -qm 'fix(agent): pipeline fix found on a product issue (#509908) [skip ci]'
# A pipeline fix whose body cites a pipeline issue as context is not that issue's delivery.
printf 'body\n' > "$ROUTE_FIXTURE_REPO/engine/body.sh"
git -C "$ROUTE_FIXTURE_REPO" add .
git -C "$ROUTE_FIXTURE_REPO" commit -qm '[skip ci] fix(agent): unrelated pipeline fix' -m 'Found while hand-2680 was blocked on issue 509911.'
git -C "$ROUTE_FIXTURE_REPO" update-ref refs/remotes/origin/main HEAD
pipeline_system_route_status() { [ "$1" != 509908 ]; }
ROUTED_PIPELINE_SHA=""
ROUTED_PRODUCT_PR=""
route_pipeline_system_verification() { ROUTED_PIPELINE_SHA="$2"; }
conclude_merged_run() { ROUTED_PRODUCT_PR="$2"; }
gh() {
  if [ "$1" = pr ] && [ "$2" = list ] && [[ "$*" == *"509907 in:title"* ]]; then
    printf '[{"number":9907,"title":"fix(#509907): landed product work","headRefName":"fix/509907-test","baseRefName":"main","mergeCommit":{"oid":"%s"}}]\n' "$PRODUCT_SHA"
  elif [ "$1" = pr ] && [ "$2" = list ] && [[ "$*" == *"509909 in:title"* ]]; then
    printf '[{"number":9909,"title":"fix(api): landed product work (issue 509909, issue 1)","headRefName":"hand/509909","baseRefName":"main","mergeCommit":{"oid":"%s"}},{"number":9910,"title":"fix(api): unrelated (issue 5099090)","headRefName":"hand/x","baseRefName":"main","mergeCommit":{"oid":"%s"}}]\n' "$PRODUCT_SHA" "$PRODUCT_SHA"
  elif [ "$1" = pr ] && [ "$2" = view ] && { [ "$3" = 9907 ] || [ "$3" = 9909 ]; }; then
    printf '{"files":[{"path":"packages/example-service/change.ts"}]}\n'
  else
    printf '[]\n'
  fi
}
PIPELINE_ROUTE_STATUS=0
route_existing_main_work 509905 "$ROUTE_FIXTURE_REPO" || PIPELINE_ROUTE_STATUS=$?
PRODUCT_ROUTE_STATUS=0
route_existing_main_work 509907 "$ROUTE_FIXTURE_REPO" || PRODUCT_ROUTE_STATUS=$?
ROUTED_PRODUCT_PR=""
ISSUE_TITLE_ROUTE_STATUS=0
route_existing_main_work 509909 "$ROUTE_FIXTURE_REPO" || ISSUE_TITLE_ROUTE_STATUS=$?
ROUTED_PIPELINE_SHA=""
CITED_ROUTE_STATUS=0
route_existing_main_work 509908 "$ROUTE_FIXTURE_REPO" || CITED_ROUTE_STATUS=$?
assert_eq "product issue is not routed to pipeline verification" "" "$ROUTED_PIPELINE_SHA"
ROUTED_PIPELINE_SHA=""
BODY_CITED_STATUS=0
route_existing_main_work 509911 "$ROUTE_FIXTURE_REPO" || BODY_CITED_STATUS=$?
assert_eq "a commit body citing a pipeline issue is not its delivery" 1 "$BODY_CITED_STATUS"
assert_eq "a body-cited pipeline issue is not routed to verification" "" "$ROUTED_PIPELINE_SHA"
NO_WORK_STATUS=0
route_existing_main_work 509906 "$ROUTE_FIXTURE_REPO" || NO_WORK_STATUS=$?
assert_eq "no linked main work returns implement-failure classification" 1 "$NO_WORK_STATUS"
rm -rf "$ROUTE_FIXTURE_DIR"

# A transient Codex capacity response must stay on the current identity and
# refund the dispatch attempt for implement, repair, and triage callers.
CAPACITY_LOG='Selected model is at capacity'
assert_eq "Codex model-capacity log is a provider outage" \
  provider-capacity "$(premium_call_provider_outage_kind "$CAPACITY_LOG" || true)"
assert_eq "Codex overload log is a provider outage" \
  provider-capacity "$(premium_call_provider_outage_kind 'overloaded_error: server overloaded' || true)"
assert_eq "Codex model-capacity failure is transient" transient "$(model_call_failure_kind "$CAPACITY_LOG" 1)"
assert_eq "Codex provider capacity is not a quota refusal" false \
  "$(premium_call_is_quota_refused 'overloaded_error: server overloaded' 1 && echo true || echo false)"
CAPACITY_429='{"is_error":true,"api_error_status":429,"result":"Selected model is at capacity"}'
assert_eq "structured capacity 429 stays transient" transient "$(model_call_failure_kind "$CAPACITY_429" 1)"
assert_eq "structured capacity 429 skips quota fallback" false \
  "$(premium_call_is_quota_refused "$CAPACITY_429" 1 && echo true || echo false)"

: > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
capacity_issue=509920
for stage in implement repair triage; do
  case "$stage" in
    triage) unit=triage; caller=run-triage:triage ;;
    *) unit=implement; caller="run-implement:$stage" ;;
  esac
  n="$capacity_issue"
  capacity_issue=$((capacity_issue + 1))
  state_merge "$n" ".attempts = 2 | .model_policy = {unit:\"$unit\",step:\"work_retry\",active:{unit:\"$unit\",step:\"work_retry\",model_started:true}}"
  pause_for_backoff "$n" "$CAPACITY_LOG" 1 0 codex codex:gpt-6-luna:low "$caller"
  model_policy_record_failure "$n" work_retry "$stage" "Codex capacity" "$CAPACITY_LOG" 1 ready-for-agent "$unit" 0 || true
  capacity_state="$(state_read "$n")"
  assert_eq "$stage capacity outage keeps model rung" work_retry "$(jq -r '.model_policy.step' <<< "$capacity_state")"
  assert_eq "$stage capacity outage refunds attempt" 1 "$(jq -r '.attempts' <<< "$capacity_state")"
  assert_eq "$stage capacity outage records refund" true "$(jq -r '.model_policy.retry_note.attempt_refunded' <<< "$capacity_state")"
  assert_eq "$stage capacity outage avoids failure ladder" 0 "$(jq -r '(.model_policy.failures // []) | length' <<< "$capacity_state")"
  assert_eq "$stage capacity outage uses bounded backoff" true \
    "$(jq -e --argjson now "$(date +%s)" --argjson max "$(( $(date +%s) + CODEX_PROVIDER_BACKOFF_SECONDS ))" \
      '.model_failure_backoff.provider == "codex" and .model_failure_backoff.until_epoch > $now and .model_failure_backoff.until_epoch <= $max' \
      >/dev/null <<< "$capacity_state" && echo true || echo false)"
done

exit "$FAILED"
