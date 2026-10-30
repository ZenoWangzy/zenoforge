#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d); owner_pid=""; decoy_pid=""
cleanup() { for pid in "$owner_pid" "$decoy_pid"; do [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; done; rm -rf "$CRASH_TEST_ROOT" "$test_env_root"; }
trap cleanup EXIT
H="$tmp/agent"; NIGHT="$H/night"; LOG="$NIGHT/log"; REPO_DIR="$tmp/repo"
mkdir -p "$NIGHT" "$REPO_DIR/engine/night" "$tmp/bin" "$tmp/wt"
AGENT_HOME="$H"; export AGENT_HOME
ZF_REPO_DIR="$tmp/repo"; export ZF_REPO_DIR
export CRASH_TEST_ROOT="$tmp"
export ZF_LAND_QUEUE_DIR="$tmp/land-queue"
export DQ_QUEUE="$NIGHT/supervisor-dispatch-queue.tsv"
cat > "$tmp/bin/uptime" <<'EOF'
#!/bin/bash
date -d "${CRASH_BOOT_AGE:-3600} seconds ago" '+%Y-%m-%d %H:%M:%S'
EOF
cat > "$REPO_DIR/engine/night/dispatch.sh" <<'EOF'
#!/bin/bash
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$6" "$5" "${8:-0}" "${9:-}" >> "$CRASH_TEST_ROOT/dispatched"
EOF
chmod +x "$tmp/bin/uptime"
PATH="$tmp/bin:$PATH"
source "$root/engine/lib.sh"
source "$root/engine/night/hand-crash-recovery.sh"
ZF_ENGINE_DIR="$REPO_DIR/engine" # the stub dispatcher lives in the fixture repo
hand_agent_pid_live() { return 1; }
hand_agent_role_for_identity() { echo work; }
sleep() { :; }
say() { printf '%s\n' "$*" >> "$LOG"; }
supervisor_inbox_append() { printf '%s %s\n' "$1" "$2" >> "$CRASH_TEST_ROOT/inbox"; }
supervisor_inbox_append_once() {
  local key="$1" message="$2"
  grep -Fxq -- "$key" "$CRASH_TEST_ROOT/once" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$CRASH_TEST_ROOT/once"
  printf '%s\n' "$message" >> "$CRASH_TEST_ROOT/inbox"
}
fake_codex_error_log() { jq -cn --arg message "$FAKE_CODEX_ERROR_MESSAGE" '{type:"error",message:$message}' > "$1"; }
reset() { rm -rf "$NIGHT/crash-recovery" "$ZF_LAND_QUEUE_DIR"; rm -f "$NIGHT"/.hand-owner-* "$DQ_QUEUE.removed"; : > "$DQ_QUEUE"; : > "$NIGHT/agents.txt"; : > "$tmp/dispatched"; : > "$tmp/queued"; : > "$tmp/inbox"; : > "$tmp/once"; }
row() {
  local name="$1" attempt="${2:-0}" role="${3:-work}" started="${4:-0}" provider_retry="${5:-0}" episode="${6:-$(date +%s%N)}"
  printf '99999999\t%s\ttest-model\tmax\t%s/wt\tbrief\t%s/%s.report\t%s/log\t%s\t%s\t%s\t1\t3024\tnode-test\t%s\t%s\n' \
    "$name" "$tmp" "$tmp" "$name" "$tmp" "$attempt" "$started" "$role" "$provider_retry" "$episode" >> "$NIGHT/agents.txt"
}
if declare -F recover_dead_hand_agents >/dev/null; then
  echo 'FAIL retired hand queue recovery remains callable' >&2; exit 1
fi
for pair in \
  'Selected model is at capacity|provider-capacity' \
  'unexpected status 429 Too Many Requests: Rate limit reached|quota-429' \
  'websocket closed by server before response.completed|websocket-closed'; do
  FAKE_CODEX_ERROR_MESSAGE="${pair%%|*}"
  expected_kind="${pair#*|}"
  fake_codex_error_log "$tmp/provider-error.jsonl"
  actual_kind="$(codex_session_error_kind "$(codex_session_error_output "$tmp/provider-error.jsonl")" 1)"
  [[ "$actual_kind" == "$expected_kind" ]]
done
echo 'PASS FAKE_CODEX_ERROR_MESSAGE classifies capacity, 429 and websocket closure'

reset
FAKE_CODEX_ERROR_MESSAGE='unexpected status 429 Too Many Requests: Rate limit reached'; fake_codex_error_log "$tmp/log"
quota_kind="$(codex_session_error_kind "$(codex_session_error_output "$tmp/log")" 1)"
[[ "$quota_kind" == quota-429 ]]
quota_failure_notifications=0
note_provider_quota_exhausted() { quota_failure_notifications=$((quota_failure_notifications + 1)); }
for retry_stage in 0 1; do
  ZF_HAND_PROVIDER_RETRY="$retry_stage" codex_session_failure "$tmp/log" 1 hand:quota-test codex:test:max
  [[ "$quota_failure_notifications" == 0 ]]
done
unset ZF_HAND_PROVIDER_RETRY
codex_session_failure "$tmp/log" 1 codex-session codex:test:max
[[ "$quota_failure_notifications" == 1 ]]
ZF_HAND_PROVIDER_RETRY=2 codex_session_failure "$tmp/log" 1 hand:quota-test codex:test:max
[[ "$quota_failure_notifications" == 2 ]]
hand_provider_recover quota "$tmp/wt" "$tmp/quota-brief" work "$tmp/quota.report" 0 \
  'RESUME: 429 provider failure' 0 "$(date +%s%N)" "$quota_kind" "$(date +%s%N)"
[[ $(cut -f5 "$tmp/dispatched") == 1 ]]
echo 'PASS quota 429 enters bounded recovery without opening quota hold before final model failure'

reset
FAKE_CODEX_ERROR_MESSAGE='Selected model is at capacity'; fake_codex_error_log "$tmp/log"
fast_episode="$(date +%s%N)"
fast_kind="$(codex_session_error_kind "$(codex_session_error_output "$tmp/log")" 1)"
# Active Codex roles have no configured fallback identity.
hand_provider_recover fast "$tmp/wt" "$tmp/fast-brief" work "$tmp/fast.report" 0 \
  'RESUME: fast provider failure' 0 "$fast_episode" "$fast_kind" "$fast_episode"
[[ ! -s "$NIGHT/agents.txt" && $(cut -f1 "$tmp/dispatched") == fast ]]
[[ $(cut -f3 "$tmp/dispatched") == 0 && $(cut -f5 "$tmp/dispatched") == 1 && $(cut -f6 "$tmp/dispatched") == "$fast_episode" ]]
grep -Fq "stage=1 kind=provider-capacity model=$MODEL_POLICY_TEST_WORK_MODEL" "$tmp/inbox"
echo 'PASS fast pre-roster failure retries original model once with same worktree, brief and report'

FAKE_CODEX_ERROR_MESSAGE='websocket closed by server before response.completed'; fake_codex_error_log "$tmp/log"
fast_kind="$(codex_session_error_kind "$(codex_session_error_output "$tmp/log")" 1)"
if hand_provider_recover fast "$tmp/wt" "$tmp/fast-brief" work "$tmp/fast.report" 0 \
  'RESUME: first retry failed' 1 "$fast_episode" "$fast_kind" "$fast_episode"; then
  echo 'FAIL recovery must stop after the original-model retry when no fallback is configured' >&2; exit 1
fi
[[ $(wc -l < "$tmp/dispatched") == 1 && $(grep -c '^STATUS: FAILED$' "$tmp/fast.report") == 1 ]]
grep -Fq 'no valid fallback_model' "$tmp/fast.report"
if grep -Fq 'stage=2 kind=websocket-closed' "$tmp/inbox"; then
  echo 'FAIL no-fallback recovery must not enqueue a second identity' >&2; exit 1
fi
echo 'PASS no-fallback recovery stops after one original-model retry'
