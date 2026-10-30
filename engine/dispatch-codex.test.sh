#!/usr/bin/env bash
# Public-CLI regression for the watched-session Codex dispatcher. It uses a
# fake codex but real setsid/ps for the success path, then proves a fake
# non-detaching setsid is rejected before it can be reported as a launch.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH_SRC="${DISPATCH_SRC:-$SCRIPT_DIR/dispatch-codex.sh}"
POLICY_DEFAULT="$SCRIPT_DIR/model-policy.default.json"
WORK_MODEL="$(jq -r '.roles.work.model' "$POLICY_DEFAULT")"
WORK_EFFORT="$(jq -r '.roles.work.effort' "$POLICY_DEFAULT")"
WORK_SERVICE_TIER="$(jq -r '.roles.work.service_tier // empty' "$POLICY_DEFAULT")"
PRODUCTION_MODEL="$(jq -r '.roles.production.model' "$POLICY_DEFAULT")"
PRODUCTION_EFFORT="$(jq -r '.roles.production.effort' "$POLICY_DEFAULT")"
PRODUCTION_SERVICE_TIER="$(jq -r '.roles.production.service_tier // empty' "$POLICY_DEFAULT")"
printf -v WORK_IDENTITY 'codex:%s:%s' "$WORK_MODEL" "$WORK_EFFORT"
printf -v PRODUCTION_IDENTITY 'codex:%s:%s' "$PRODUCTION_MODEL" "$PRODUCTION_EFFORT"

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
assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (did not expect [$unexpected])"
    FAILED=1
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}
assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (missing [$path])"
    FAILED=1
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  if ! grep -qF -- "$needle" "$file"; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (found [$needle])"
    FAILED=1
  fi
}

owner_session_source="$(sed -n '/^dispatch_owner_session() {/,/^}/p' "$DISPATCH_SRC")"
owner_release_line="$(grep -nF 'codex_budget_release "$OWNER_SESSION_BUDGET_ID"' <<< "$owner_session_source" | head -n 1 | cut -d: -f1)"
owner_receipt_line="$(grep -nF -- '--arg status exited' <<< "$owner_session_source" | head -n 1 | cut -d: -f1)"
if [[ "$owner_release_line" =~ ^[0-9]+$ && "$owner_receipt_line" =~ ^[0-9]+$ ]] \
  && (( owner_release_line < owner_receipt_line )); then
  echo 'ok - owner budget lease releases before terminal manifest'
else
  echo 'not ok - owner budget lease must release before terminal manifest'
  FAILED=1
fi

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
LOW_MEMORY_BIN="$TEST_ROOT/low-memory-bin"
BAD_SETSID_BIN="$TEST_ROOT/bad-setsid-bin"
PID_FAILURE_SETSID_BIN="$TEST_ROOT/pid-failure-setsid-bin"
FAKE_CODEX_ARGS_FILE="$TEST_ROOT/codex-args"
FAKE_CODEX_STDIN_FILE="$TEST_ROOT/codex-stdin"
FAKE_CODEX_PID_FILE="$TEST_ROOT/codex-pid"
FAKE_CODEX_REPO_ENV_FILE="$TEST_ROOT/codex-repo-env"
FAKE_SYSTEMD_ARGS_FILE="$TEST_ROOT/systemd-args"
PROMPT_FILE="$TEST_ROOT/brief.md"
LOG_DIR="$TEST_ROOT/logs"
WORKTREE="$TEST_ROOT/worktree"
LIVE_CHECKOUT="$TEST_ROOT/live-checkout"
AGENT_HOME="$TEST_ROOT/agent-home"
AGENT_DISPATCH_LOADAVG_FILE="$TEST_ROOT/loadavg"
ZF_WORKTREE_ROOT="$TEST_ROOT/worktrees"
export AGENT_DISPATCH_LOADAVG_FILE ZF_WORKTREE_ROOT

stop_fake_codex() {
  local pid=""
  if [ -s "$FAKE_CODEX_PID_FILE" ]; then
    pid="$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill "$pid" 2>/dev/null || true ;;
    esac
  fi
}
trap 'stop_fake_codex; rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$FAKE_BIN" "$LOW_MEMORY_BIN" "$BAD_SETSID_BIN" "$PID_FAILURE_SETSID_BIN" "$LOG_DIR" "$WORKTREE" "$ZF_WORKTREE_ROOT"
printf '%s\n' '0.10 0.12 0.13 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"
git -C "$WORKTREE" init -q -b manual-recovery
git -C "$WORKTREE" config user.name test
git -C "$WORKTREE" config user.email test@example.invalid
printf '%s\n' seed > "$WORKTREE/seed.txt"
git -C "$WORKTREE" add seed.txt
git -C "$WORKTREE" commit -qm seed
git clone -q "$WORKTREE" "$LIVE_CHECKOUT"
printf '%s\n' 'Implement one safe unit.' > "$PROMPT_FILE"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'features list' ]; then
  if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ] \
    && [ "$(awk -F= '$1 ~ /^[[:space:]]*model[[:space:]]*$/ {n++} END {print n+0}' "$CODEX_HOME/config.toml")" -gt 1 ]; then
    printf 'Error: failed to load bootstrap configuration\n' >&2
    printf '    0: %s/config.toml:2:1: duplicate key\n' "$CODEX_HOME" >&2
    exit 1
  fi
  printf 'feature flags parsed\n'
  exit 0
fi
printf '%s\n' "$$" > "$FAKE_CODEX_PID_FILE"
printf '<%s>\n' "$@" > "$FAKE_CODEX_ARGS_FILE"
printf '%s\n%s\n%s\n' "${ZF_REPO_DIR:-}" "${REPO_DIR:-}" "$(command -v gh)" > "$FAKE_CODEX_REPO_ENV_FILE"
if [ -n "${FAKE_CODEX_PROXY_ENV_FILE:-}" ]; then
  printf '%s\n%s\n' "${NODE_USE_ENV_PROXY:-}" "${NO_PROXY:-}" > "$FAKE_CODEX_PROXY_ENV_FILE"
fi
cat > "$FAKE_CODEX_STDIN_FILE"
[ -z "${FAKE_CODEX_STARTED_FILE:-}" ] || printf '%s\n' started > "$FAKE_CODEX_STARTED_FILE"
if [ -n "${FAKE_CODEX_EXIT_CODE:-}" ]; then
  printf '%s\n' 'tokens used' '1,234'
  if [ "${FAKE_CODEX_ERROR_JSON:-0}" = 1 ]; then
    jq -nc --arg message "${FAKE_CODEX_ERROR_MESSAGE:-}" '{type:"error",message:$message}' >&2
  else
    printf '%s\n' "${FAKE_CODEX_ERROR_MESSAGE:-Error: HTTP 401 token=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}" >&2
  fi
  exit "$FAKE_CODEX_EXIT_CODE"
fi
if [ -n "${FAKE_CODEX_RELEASE_FILE:-}" ]; then
  printf '%s\n' started > "$FAKE_CODEX_STARTED_FILE"
  while [ ! -e "$FAKE_CODEX_RELEASE_FILE" ]; do sleep 0.02; done
  if [ "${FAKE_CODEX_EMIT_TOKEN_SUMMARY:-0}" = 1 ]; then printf '%s\n' 'tokens used' '1,234'; fi
  exit "${FAKE_CODEX_WAIT_EXIT_CODE:-0}"
fi
printf '%s\n' 'raw-agent-output'
while :; do sleep 1; done
EOF
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>\n' "$@" > "$FAKE_SYSTEMD_ARGS_FILE"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "$#" -gt 0 ] || exit 2
shift
setsid --fork "$@" >/dev/null 2>&1 &
EOF
chmod +x "$FAKE_BIN/systemd-run"

cat > "$FAKE_BIN/nproc" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${FAKE_NPROC_FAIL:-0}" = 1 ] && exit 1
printf '%s\n' "${FAKE_NPROC_VALUE:-10}"
EOF
chmod +x "$FAKE_BIN/nproc"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$*" = '-ww -eo args=' ] && [ -n "${FAKE_PS_PROCESS_LIST_FILE:-}" ]; then
  cat "$FAKE_PS_PROCESS_LIST_FILE"
else
  exec /bin/ps "$@"
fi
EOF
chmod +x "$FAKE_BIN/ps"

cat > "$LOW_MEMORY_BIN/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' ' 4242     1 3145728 pipeline-hog'
EOF
chmod +x "$LOW_MEMORY_BIN/ps"

cat > "$BAD_SETSID_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" = "--fork" ]; do
  shift
done
exec "$@"
EOF
chmod +x "$BAD_SETSID_BIN/setsid"

cat > "$PID_FAILURE_SETSID_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ] && [ "$1" = "--fork" ]; do
  shift
done
# Make PID publication fail after the prompt opens. /dev/full stays size zero,
# so the parent cannot mistake the path for a published PID. Find the private
# PID path instead of coupling this regression to sh's option positions.
for arg in "$@"; do
  case "$arg" in
    *.pid)
      ln -s /dev/full "$arg"
      break
      ;;
  esac
done
exec "$@"
EOF
chmod +x "$PID_FAILURE_SETSID_BIN/setsid"

reset_fake_codex() {
  stop_fake_codex
  : > "$FAKE_CODEX_ARGS_FILE"
  : > "$FAKE_CODEX_STDIN_FILE"
  : > "$FAKE_CODEX_PID_FILE"
}

run_dispatch() {
  set +e
  RUN_OUTPUT="$(PATH="$FAKE_BIN:$PATH" \
    AGENT_HOME="$AGENT_HOME" \
    AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
    FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
    FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
    FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
    FAKE_CODEX_REPO_ENV_FILE="$FAKE_CODEX_REPO_ENV_FILE" \
    FAKE_SYSTEMD_ARGS_FILE="$FAKE_SYSTEMD_ARGS_FILE" \
    CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
    ZF_NODE_OWNER_EPISODE="${ZF_NODE_OWNER_EPISODE:-}" \
    ZF_REPO_DIR="$LIVE_CHECKOUT" REPO_DIR="$LIVE_CHECKOUT" \
    bash "$DISPATCH_SRC" "$@" --worktree "$WORKTREE" 2>&1)"
  RUN_STATUS=$?
  set -e
}

wait_for_text() {
  local path="$1" text="$2" attempts="${3:-50}"
  for _ in $(seq 1 "$attempts"); do
    if [ -f "$path" ] && grep -Fq "$text" "$path"; then
      return 0
    fi
    sleep 0.02
  done
  return 1
}

# Dispatch publishes its PID before config preflight invokes Codex. That probe
# has a ten-second command timeout; allow twenty seconds for it and process
# startup under load before treating an async launch as broken.
ASYNC_CODEX_START_ATTEMPTS=1000

wait_for_owner_exit() {
  local manifest="$1" attempts="${2:-1500}"
  for _ in $(seq 1 "$attempts"); do
    if jq -e '.status == "exited"' "$manifest" >/dev/null 2>&1; then return 0; fi
    sleep 0.02
  done
  return 1
}

wait_for_budget_release() {
  local id="$1" file="$2"
  for _ in $(seq 1 100); do
    if ! awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.02 # wall-clock-allow: bounded poll for the budget release row, exits on first match
  done
  return 1
}

wait_for_owner_terminal() {
  local manifest="$1"
  for _ in $(seq 1 150); do
    if jq -e '.status != "launching" and .status != "running"' "$manifest" >/dev/null 2>&1; then return 0; fi
    sleep 0.02
  done
  return 1
}

run_owner_exit_trap() {
  local manifest="$1" pid_file="$2" pending_log="$3" exit_status="$4"
  (
    source "$SCRIPT_DIR/lib.sh"
    source <(sed -n '/^dispatch_jq_reason() {/,/^}/p; /^dispatch_owner_session_exit() {/,/^}/p' "$DISPATCH_SRC")
    OWNER_SESSION_MANIFEST_FILE="$manifest"
    OWNER_SESSION_PID_FILE="$pid_file"
    OWNER_SESSION_PENDING_LOG="$pending_log"
    OWNER_SESSION_SIGNAL=""
    dispatch_owner_session_exit "$exit_status"
  )
}

# Provider fixtures: openai/codex rust-v0.162.1 protocol/src/error.rs
# (UsageLimitReachedError), exec/src/exec_events.rs and human error renderer.
run_quota_exit_case() {
  local lane="$1" case_name="$2" status="$3" text="$4" signal="${5:-}"
  QUOTA_CASE_HOME="$TEST_ROOT/quota-$lane-$case_name"
  mkdir -p "$QUOTA_CASE_HOME"
  while IFS= read -r line; do
    if [[ "$line" == ERROR:* ]]; then
      jq -cn --arg message "${line#ERROR: }" '{type:"error",message:$message}'
    else
      printf '%s\n' "$line"
    fi
  done <<< "$text" > "$QUOTA_CASE_HOME/session.log"
  (
    export AGENT_HOME="$QUOTA_CASE_HOME"
    source "$SCRIPT_DIR/lib.sh"
    source "$SCRIPT_DIR/redact-secrets.sh"
    CODEX_PROVIDER_FAILURE_THRESHOLD=1
    source <(sed -n '/^dispatch_redact_line() {/,/^}/p; /^dispatch_log_output() {/,/^}/p; /^dispatch_jq_reason() {/,/^}/p; /^dispatch_owner_session_exit() {/,/^}/p' "$DISPATCH_SRC")
    if [[ "$lane" == owner ]]; then
      mv "$QUOTA_CASE_HOME/session.log" "$QUOTA_CASE_HOME/raw.log"
      dispatch_log_output "$QUOTA_CASE_HOME/session.log" < "$QUOTA_CASE_HOME/raw.log"
      jq -n --arg log "$QUOTA_CASE_HOME/session.log" '{status:"running",pid:123,log_file:$log}' > "$QUOTA_CASE_HOME/manifest.json"
      OWNER_SESSION_MANIFEST_FILE="$QUOTA_CASE_HOME/manifest.json"
      OWNER_SESSION_SIGNAL="$signal"
      dispatch_owner_session_exit "$status"
    else
      log="$QUOTA_CASE_HOME/session.log"; role=work; model="$WORK_MODEL"; effort="$WORK_EFFORT"; name=test; budget_id=""; started="$(date +%s)"
      source <(sed -n '/^      tokens=/,/^      exit /{ /^      exit /!p; }' "$SCRIPT_DIR/night/dispatch.sh")
    fi
  )
}
quota_marker_present() { test -e "$QUOTA_CASE_HOME/codex-exhausted-until" && echo true || echo false; }
# Full sentence and reset layout come from the CLI source, timestamp is future fixture data.
QUOTA_REFUSAL="ERROR: You’ve hit your usage limit. Try again at Oct 19th, 2099 1:13 AM."
for lane in owner hand; do
  run_quota_exit_case "$lane" signal 143 '2026-10-11T23:07:06Z codex-error an overly broad quota regex'
  assert_eq "$lane SIGTERM with quota prose creates no hold" false "$(quota_marker_present)"
  run_quota_exit_case "$lane" prose 1 '2026-10-11T23:07:06Z codex-error Fix rate limit and quota classification; quoted HTTP 429 Too Many Requests'
  assert_eq "$lane agent rate-limit prose creates no hold" false "$(quota_marker_present)"
  run_quota_exit_case "$lane" usage 1 "$QUOTA_REFUSAL"
  assert_eq "$lane real provider reset sets exact deadline" "$(date -d 'Oct 19, 2099 1:13 AM' +%s)" "$(cat "$QUOTA_CASE_HOME/codex-exhausted-until" 2>/dev/null || true)"
  run_quota_exit_case "$lane" quoted 1 "$(jq -cn --arg text "$QUOTA_REFUSAL" '{type:"item.completed",item:{id:"prose",type:"agent_message",text:$text}}')"
  assert_eq "$lane agent can quote full provider refusal without hold" false "$(quota_marker_present)"
  run_quota_exit_case "$lane" json 1 "$(jq -cn --arg message "${QUOTA_REFUSAL#ERROR: }" '{type:"turn.failed",error:{message:$message}}')"
  assert_eq "$lane structured CLI refusal sets exact deadline" "$(date -d 'Oct 19, 2099 1:13 AM' +%s)" "$(cat "$QUOTA_CASE_HOME/codex-exhausted-until" 2>/dev/null || true)"
  run_quota_exit_case "$lane" tokens 0 '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":1234}}'
  token_count="$(AGENT_HOME="$QUOTA_CASE_HOME" bash -c 'source "$1/lib.sh"; codex_tokens_used "$2"' _ "$SCRIPT_DIR" "$QUOTA_CASE_HOME/session.log")"
  assert_eq "$lane JSON session keeps blended token accounting" 2034 "$token_count"
  run_quota_exit_case "$lane" stale 1 "$(printf '%s\n' "$QUOTA_REFUSAL"; printf 'ordinary agent output\n%.0s' {1..1000}; printf '\nERROR: unexpected internal failure\n')"
  assert_eq "$lane ignores old refusal outside provider tail" false "$(quota_marker_present)"
  for failure in 'ERROR: unexpected status 504 Gateway Timeout: quota proxy unavailable' 'ERROR: websocket closed by server before response.completed' 'ERROR: failed to connect to websocket: proxy connection failed: HTTP CONNECT failed with status 504'; do
    run_quota_exit_case "$lane" outage 1 "$failure"
    deadline="$(cat "$QUOTA_CASE_HOME/codex-exhausted-until" 2>/dev/null || echo 0)"
    remaining=$((deadline - $(date +%s)))
    assert_eq "$lane outage opens short circuit" true "$([[ "$remaining" -gt 0 && "$remaining" -le 90 ]] && echo true || echo false)"
    assert_eq "$lane outage has recovery probe latch" true "$(test -e "$QUOTA_CASE_HOME/codex-exhausted-until.probe-required" && echo true || echo false)"
    assert_eq "$lane outage creates no quota alert" false "$(test -e "$QUOTA_CASE_HOME/codex-exhausted-until.alerted" && echo true || echo false)"
    rm -rf -- "$QUOTA_CASE_HOME"
  done
done
run_quota_exit_case owner trap-signal 1 "$QUOTA_REFUSAL" TERM
assert_eq "owner TERM flag overrides non-signal exit status" false "$(quota_marker_present)"
# Three distinct standalone failures use the existing circuit threshold; replaying
# one failure does not count twice and never writes a fictitious issue state.
QUOTA_CASE_HOME="$TEST_ROOT/quota-circuit"
mkdir -p "$QUOTA_CASE_HOME"
(
  export AGENT_HOME="$QUOTA_CASE_HOME"
  source "$SCRIPT_DIR/lib.sh"
  for id in first first second; do
    printf '%s\n' '{"type":"error","message":"unexpected status 504 Gateway Timeout"}' > "$QUOTA_CASE_HOME/$id.log"
    codex_session_failure "$QUOTA_CASE_HOME/$id.log" 1 owner-session "$WORK_MODEL"
  done
  assert_eq "two distinct session failures keep circuit closed" false "$(quota_marker_present)"
  printf '%s\n' '{"type":"error","message":"websocket closed by server before response.completed"}' > "$QUOTA_CASE_HOME/third.log"
  codex_session_failure "$QUOTA_CASE_HOME/third.log" 1 owner-session "$WORK_MODEL"
  assert_eq "third distinct session opens recovery circuit" true "$(test -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" && echo true || echo false)"
  assert_eq "session circuit writes no fictitious issue state" 0 "$(find "$STATE_DIR" -name 'session:*.json' | wc -l)"
  exit "$FAILED"
) || FAILED=1
if [[ "${1:-}" == --quota-only ]]; then exit "$FAILED"; fi

# Red before implementation: this public seam must prove a detached work
# launch, the fixed work model, brief injection, and PID-addressable log.
mkdir -p "$TEST_ROOT/duplicate-codex-home"
cat > "$TEST_ROOT/duplicate-codex-home/config.toml" <<'TOML'
model = "$WORK_MODEL"
model = "$WORK_MODEL"
TOML
reset_fake_codex
ZF_NODE_OWNER_EPISODE=episode-invalid \
  CODEX_HOME="$TEST_ROOT/duplicate-codex-home" \
  run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "node auto-owner refuses duplicate-key config before dispatch" "1" "$RUN_STATUS"
assert_contains "node auto-owner prints named config fault" "$RUN_OUTPUT" "env:codex-config-invalid"
assert_contains "node auto-owner prints parser detail" "$RUN_OUTPUT" "duplicate key"
assert_eq "node auto-owner config failure never starts Codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
assert_eq "node auto-owner config failure creates no ticket launch manifest" "0" \
  "$(find "$AGENT_HOME/hand-dispatch" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_contains "node auto-owner records env fault in supervisor inbox" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" "env:codex-config-invalid"

reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "work launch succeeds" "0" "$RUN_STATUS"
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - work fake Codex args finish writing"
  FAILED=1
}
assert_contains "work fake Codex args include final stdin selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<->"
assert_contains "work launch reports its log" "$RUN_OUTPUT" "log="
assert_contains "work launch reports its recovery record" "$RUN_OUTPUT" "record="
assert_contains "work launch reports reparenting" "$RUN_OUTPUT" "reparented-parent="
WORK_PID="$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE" 2>/dev/null || true)"
assert_ne "work launch records a PID" "" "$WORK_PID"
RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
SESSION_PID="$(jq -r '.pid // empty' "$RECORD")"
WORK_LOG="$(sed -n 's/.* log=\([^ ]*\).*/\1/p' <<< "$RUN_OUTPUT")"
assert_file "work log is PID-addressable" "$WORK_LOG"
assert_contains "work log path carries its session PID" "$WORK_LOG" "$SESSION_PID"
assert_file "dispatch writes a durable record" "$RECORD"
if [ -f "$RECORD" ]; then
  assert_eq "manual manifest identifies its budget reservation" "hand-dispatch:$(jq -r '.id' "$RECORD")" \
    "$(jq -r '.codex_budget_reservation_id' "$RECORD")"
  BRIEF="$(jq -r '.brief_file' "$RECORD")"
  assert_file "dispatch copies the replay brief outside session scratch" "$BRIEF"
  assert_eq "record keeps original brief bytes" "$(cat "$PROMPT_FILE")" "$(cat "$BRIEF")"
  assert_eq "record keeps policy work model" "$WORK_MODEL" "$(jq -r '.model' "$RECORD")"
  assert_eq "record keeps policy work effort" "$WORK_EFFORT" "$(jq -r '.effort' "$RECORD")"
  assert_eq "record persists work policy role, step, and identity" $'work\twork\t'"$WORK_IDENTITY" \
    "$(jq -r '[.model_policy.role,.model_policy.step,.model_policy.identity] | @tsv' "$RECORD")"
  assert_eq "record defaults to investigation access" "investigation" "$(jq -r '.access' "$RECORD")"
  assert_eq "record keeps worktree" "$(cd "$WORKTREE" && pwd -P)" "$(jq -r '.worktree' "$RECORD")"
  assert_eq "record keeps branch" "manual-recovery" "$(jq -r '.branch' "$RECORD")"
  assert_eq "record captures process start identity" "true" "$(jq -r '(.pid_start_ticks | type) == "string" and length > 0' "$RECORD")"
  RECORD_LOG_FILE="$(jq -r '.log_file' "$RECORD")"
  assert_file "record keeps PID-addressable log" "$RECORD_LOG_FILE"
  assert_not_contains "PID log stores heartbeat, not raw agent output" raw-agent-output "$RECORD_LOG_FILE"
fi
case "$SESSION_PID" in
  ''|*[!0-9]*)
    echo "not ok - work process owns its session (no PID)"
    echo "not ok - work process is no longer child of test session (no PID)"
    FAILED=1
    ;;
  *)
    assert_eq "work process owns its session" "$SESSION_PID" "$(ps -o sid= -p "$SESSION_PID" | tr -d '[:space:]')"
    assert_ne "work process is no longer child of test session" "$$" "$(ps -o ppid= -p "$SESSION_PID" | tr -d '[:space:]')"
    ;;
esac
assert_contains "work uses policy model" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<$WORK_MODEL>"
assert_eq "hand dispatcher overrides inherited ZF_REPO_DIR with worktree" "$WORKTREE" \
  "$(sed -n '1p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_eq "hand dispatcher overrides inherited REPO_DIR with worktree" "$WORKTREE" \
  "$(sed -n '2p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_eq "hand dispatcher puts guarded gh first in agent PATH" "$SCRIPT_DIR/gh-shim/gh" \
  "$(sed -n '3p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_contains "work uses policy effort" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<model_reasoning_effort=\"$WORK_EFFORT\">"
assert_ne "work policy supplies a service tier" "" "$WORK_SERVICE_TIER"
assert_contains "work forwards policy service tier" "$(cat "$FAKE_CODEX_ARGS_FILE")" \
  "<service_tier=\"$WORK_SERVICE_TIER\">"
assert_contains "work targets recovery worktree" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<--cd>"
assert_contains "work passes recovery worktree" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<$WORKTREE>"
assert_contains "investigation selects workspace-write" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<-s>"
assert_contains "investigation passes workspace-write" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<workspace-write>"
assert_contains "investigation passes network config selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<-c>"
assert_contains "investigation disables network access" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<sandbox_workspace_write.network_access=false>"
assert_contains "dispatch disables GitNexus MCP" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<mcp_servers.gitnexus.enabled=false>"
assert_not_contains "investigation omits danger-full-access" "<danger-full-access>" "$FAKE_CODEX_ARGS_FILE"
assert_not_contains "investigation omits network access config" "<sandbox_workspace_write.network_access=true>" "$FAKE_CODEX_ARGS_FILE"
assert_contains "brief requires incremental landing" "$(cat "$FAKE_CODEX_STDIN_FILE")" "Finish and publish each independently complete unit before beginning the next."
assert_contains "prompt sends graph users to GitNexus CLI" "$(cat "$FAKE_CODEX_STDIN_FILE")" "use the GitNexus CLI with an explicit"
assert_contains "prompt names the one GitNexus repo for this run" "$(cat "$FAKE_CODEX_STDIN_FILE")" "pass \`--repo $LIVE_CHECKOUT\`"
assert_contains "brief retains operator content" "$(cat "$FAKE_CODEX_STDIN_FILE")" "Implement one safe unit."
wait_for_text "$WORK_LOG" "codex-output" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - work log captures agent heartbeat"
  FAILED=1
}
stop_fake_codex
wait_for_owner_exit "$RECORD" || { echo "not ok - manual session records Codex exit"; FAILED=1; }
wait_for_budget_release "$(jq -r '.codex_budget_reservation_id' "$RECORD")" \
  "$AGENT_HOME/codex-budget/reservations.tsv" || {
    echo "not ok - manual session releases budget reservation"
    FAILED=1
  }

# Manual launches reserve the work envelope before manifest creation.
AGENT_HOME="$TEST_ROOT/budget-denied-home"
export CODEX_DAILY_TOKEN_BUDGET=1000 CODEX_PRODUCTION_TOKEN_RESERVE=200 \
  CODEX_BUDGET_RESERVATION_TOKENS=500 CODEX_PRODUCTION_RESERVATION_TOKENS=100 \
  CODEX_HAND_DISPATCH_RESERVATION_TOKENS=801
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "manual dispatch refuses request beyond work budget" "75" "$RUN_STATUS"
assert_contains "manual dispatch names budget deferral" "$RUN_OUTPUT" "hand dispatch launch deferred by Codex budget/hold"
assert_eq "budget-denied manual dispatch never starts Codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
assert_eq "budget-denied manual dispatch creates no manifest" "0" \
  "$(find "$AGENT_HOME/hand-dispatch" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
unset CODEX_DAILY_TOKEN_BUDGET CODEX_PRODUCTION_TOKEN_RESERVE CODEX_BUDGET_RESERVATION_TOKENS \
  CODEX_PRODUCTION_RESERVATION_TOKENS CODEX_HAND_DISPATCH_RESERVATION_TOKENS

# Manual session records the Codex token summary and frees its lease on exit.
AGENT_HOME="$TEST_ROOT/hand-spend-home"
HAND_STARTED="$TEST_ROOT/hand-spend-started"
HAND_RELEASE="$TEST_ROOT/hand-spend-release"
export FAKE_CODEX_STARTED_FILE="$HAND_STARTED" FAKE_CODEX_RELEASE_FILE="$HAND_RELEASE" \
  FAKE_CODEX_EMIT_TOKEN_SUMMARY=1
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "manual spend session starts" "0" "$RUN_STATUS"
HAND_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
wait_for_text "$HAND_STARTED" started "$ASYNC_CODEX_START_ATTEMPTS" || { echo "not ok - manual spend session reaches Codex"; FAILED=1; }
touch "$HAND_RELEASE"
wait_for_owner_exit "$HAND_RECORD" || { echo "not ok - manual spend session records exit"; FAILED=1; }
HAND_BUDGET_ID="$(jq -r '.codex_budget_reservation_id' "$HAND_RECORD")"
assert_contains "manual session records Codex token use" \
  "$(cat "$AGENT_HOME/spend/$(date -u +%F).log" 2>/dev/null || true)" \
  $'\twork\tcodex:'"$WORK_MODEL:$WORK_EFFORT"$'\thand-dispatch\t\t1234'
wait_for_budget_release "$HAND_BUDGET_ID" "$AGENT_HOME/codex-budget/reservations.tsv" || {
  echo "not ok - manual spend session releases budget reservation"
  FAILED=1
}
unset FAKE_CODEX_STARTED_FILE FAKE_CODEX_RELEASE_FILE FAKE_CODEX_EMIT_TOKEN_SUMMARY
AGENT_HOME="$TEST_ROOT/agent-home"

# 2026-10-08 (hand-node-env-proxy, issue 2695 run 3): the session must
# default the Node env-proxy opt-in even when the caller unset it, and keep
# the caller's uppercase NO_PROXY, so node fetch inside the session uses the
# egress proxy while loopback test servers stay direct.
reset_fake_codex
FAKE_CODEX_PROXY_ENV_FILE="$TEST_ROOT/codex-proxy-env"
set +e
RUN_OUTPUT="$(PATH="$FAKE_BIN:$PATH" \
  AGENT_HOME="$TEST_ROOT/proxy-env-home" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  FAKE_CODEX_REPO_ENV_FILE="$FAKE_CODEX_REPO_ENV_FILE" \
  FAKE_CODEX_PROXY_ENV_FILE="$FAKE_CODEX_PROXY_ENV_FILE" \
  NODE_USE_ENV_PROXY= no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
  ZF_NODE_OWNER_EPISODE= \
  ZF_REPO_DIR="$LIVE_CHECKOUT" REPO_DIR="$LIVE_CHECKOUT" \
  bash "$DISPATCH_SRC" --kind work --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "direct session dispatch succeeds with the opt-in unset" "0" "$RUN_STATUS"
wait_for_text "$FAKE_CODEX_PROXY_ENV_FILE" "127.0.0.1,localhost" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - direct session writes proxy environment"
  FAILED=1
}
assert_eq "direct session defaults NODE_USE_ENV_PROXY to 1" "1" "$(sed -n '1p' "$FAKE_CODEX_PROXY_ENV_FILE")"
assert_eq "direct session carries uppercase NO_PROXY" "127.0.0.1,localhost" "$(sed -n '2p' "$FAKE_CODEX_PROXY_ENV_FILE")"
stop_fake_codex

# Owner sessions use their own transient unit so the supervisor's one-shot
# cgroup cleanup cannot kill Codex. Persist useful sanitized failure details.
reset_fake_codex
FAKE_OWNER_HOME="$TEST_ROOT/owner-agent-home"
set +e
RUN_OUTPUT="$(PATH="$FAKE_BIN:$PATH" \
  AGENT_HOME="$FAKE_OWNER_HOME" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  FAKE_CODEX_REPO_ENV_FILE="$FAKE_CODEX_REPO_ENV_FILE" \
  FAKE_SYSTEMD_ARGS_FILE="$FAKE_SYSTEMD_ARGS_FILE" \
  NODE_USE_ENV_PROXY= no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
  FAKE_CODEX_EXIT_CODE=1 ZF_NODE_OWNER_EPISODE=episode-test ZF_NODE_OWNER_RUNTIME_MAX_SECONDS=47 \
  ZF_REPO_DIR="$LIVE_CHECKOUT" REPO_DIR="$LIVE_CHECKOUT" \
  bash "$DISPATCH_SRC" --kind work --access delivery --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "owner dispatcher returns after durable unit start" "0" "$RUN_STATUS"
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - owner fake Codex args finish writing"
  FAILED=1
}
assert_contains "owner fake Codex args include final stdin selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<->"
assert_contains "owner launch reports its transient unit" "$RUN_OUTPUT" "unit=zf-node-owner-episode-test-"
OWNER_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_file "owner launch writes dispatch record" "$OWNER_RECORD"
if [ -f "$OWNER_RECORD" ]; then
  wait_for_owner_exit "$OWNER_RECORD" || {
    echo "not ok - owner manifest records Codex exit"
    FAILED=1
  }
  assert_eq "owner manifest records isolated execution mode" "systemd" "$(jq -r '.execution_mode' "$OWNER_RECORD")"
  assert_eq "owner manifest records transient unit" "true" \
    "$(jq -r '.unit_name | startswith("zf-node-owner-episode-test-")' "$OWNER_RECORD")"
  assert_eq "owner manifest records Codex exit status" "1" "$(jq -r '.exit_code' "$OWNER_RECORD")"
  assert_contains "owner manifest retains HTTP failure reason" "$(jq -r '.exit_reason' "$OWNER_RECORD")" "HTTP 401"
  assert_contains "owner manifest redacts token" "$(jq -r '.exit_reason' "$OWNER_RECORD")" "token=[REDACTED]"
  OWNER_LOG="$(jq -r '.log_file' "$OWNER_RECORD")"
  assert_file "owner keeps PID log" "$OWNER_LOG"
  assert_contains "owner log retains sanitized failure" "$(cat "$OWNER_LOG")" "codex-error"
  assert_eq "owner log preserves Codex token summary" 1234 \
    "$(awk '/^[[:space:]]*tokens used[[:space:]]*$/ { if (getline) { gsub(/[[:space:],]/, ""); print } }' "$OWNER_LOG")"
  assert_contains "owner records Codex usage in spend ledger" \
    "$(cat "$FAKE_OWNER_HOME/spend/$(date -u +%Y-%m-%d).log" 2>/dev/null || true)" \
    $'\twork\tcodex:gpt-6-luna:max\tnode-auto-owner\t\t1234'
  assert_not_contains "owner log excludes raw credential" "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" "$OWNER_LOG"
fi
assert_eq "owner dispatcher overrides inherited ZF_REPO_DIR with worktree" "$WORKTREE" \
  "$(sed -n '1p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_eq "owner dispatcher overrides inherited REPO_DIR with worktree" "$WORKTREE" \
  "$(sed -n '2p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_eq "owner dispatcher puts guarded gh first in agent PATH" "$SCRIPT_DIR/gh-shim/gh" \
  "$(sed -n '3p' "$FAKE_CODEX_REPO_ENV_FILE")"
assert_contains "transient unit uses collect" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" "<--collect>"
assert_contains "transient unit starts without blocking" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" "<--no-block>"
assert_contains "owner episode passes remaining runtime ceiling to systemd" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" "<RuntimeMaxSec=47>"
assert_contains "owner unit records stop intent before systemd sends TERM" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" \
  "<ExecStop=$SCRIPT_DIR/owner-stop-request.sh $OWNER_RECORD"
assert_contains "owner unit copies the defaulted Node env-proxy opt-in" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" "<NODE_USE_ENV_PROXY>"
assert_contains "owner unit copies uppercase NO_PROXY" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" "<NO_PROXY>"
assert_contains "owner delivery uses danger-full-access" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<danger-full-access>"

reset_fake_codex
CAPACITY_OWNER_HOME="$TEST_ROOT/capacity-owner-home"
set +e
RUN_OUTPUT="$(PATH="$FAKE_BIN:$PATH" \
  AGENT_HOME="$CAPACITY_OWNER_HOME" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  FAKE_CODEX_REPO_ENV_FILE="$FAKE_CODEX_REPO_ENV_FILE" \
  FAKE_SYSTEMD_ARGS_FILE="$FAKE_SYSTEMD_ARGS_FILE" \
  FAKE_CODEX_EXIT_CODE=1 FAKE_CODEX_ERROR_JSON=1 FAKE_CODEX_ERROR_MESSAGE='Selected model is at capacity' \
  ZF_NODE_OWNER_EPISODE=episode-capacity ZF_NODE_OWNER_RUNTIME_MAX_SECONDS=47 \
  ZF_REPO_DIR="$LIVE_CHECKOUT" REPO_DIR="$LIVE_CHECKOUT" \
  bash "$DISPATCH_SRC" --kind work --access delivery --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
if [ "$RUN_STATUS" != 0 ]; then printf '%s\n' "$RUN_OUTPUT"; fi
assert_eq "capacity owner dispatcher returns after durable unit start" "0" "$RUN_STATUS"
CAPACITY_OWNER_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_file "capacity owner launch writes dispatch record" "$CAPACITY_OWNER_RECORD"
if [ -f "$CAPACITY_OWNER_RECORD" ]; then
  wait_for_owner_exit "$CAPACITY_OWNER_RECORD" || {
    echo "not ok - capacity owner manifest records Codex exit"
    FAILED=1
  }
  assert_contains "owner log classifier records bare capacity line" \
    "$(jq -r '.last_error_line' "$CAPACITY_OWNER_RECORD")" "Selected model is at capacity"
fi
CAPACITY_TEST_MODEL="$MODEL_POLICY_TEST_WORK_MODEL"
CAPACITY_MODEL_MARKER="$CAPACITY_OWNER_HOME/codex-exhausted-until.model-$CAPACITY_TEST_MODEL.capacity"
CAPACITY_OWNER_LOG="$(jq -r '.log_file // empty' "$CAPACITY_OWNER_RECORD")"
assert_contains "capacity owner retains structured provider failure event" "$(cat "$CAPACITY_OWNER_LOG" 2>/dev/null || true)" "codex-provider-error"
assert_file "capacity owner opens only its model marker" \
  "$CAPACITY_MODEL_MARKER"
assert_eq "capacity owner leaves provider-wide marker closed" false \
  "$(test -e "$CAPACITY_OWNER_HOME/codex-exhausted-until" && echo true || echo false)"

# The parent exits and removes its PID file while the owner is still running.
# A later ordinary owner completion must use the durable manifest PID and be
# recorded as exited, not dispatch-failed.
reset_fake_codex
PARENT_FIRST_STARTED="$TEST_ROOT/parent-first-started"
PARENT_FIRST_RELEASE="$TEST_ROOT/parent-first-release"
export FAKE_CODEX_STARTED_FILE="$PARENT_FIRST_STARTED"
export FAKE_CODEX_RELEASE_FILE="$PARENT_FIRST_RELEASE"
export ZF_NODE_OWNER_EPISODE=parent-first
export ZF_NODE_OWNER_REPORT_FILE="$TEST_ROOT/parent-first-report.md"
run_dispatch --kind work --access delivery --prompt-file "$PROMPT_FILE"
assert_eq "owner parent returns before its Codex session" "0" "$RUN_STATUS"
PARENT_FIRST_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_file "parent-first owner record exists" "$PARENT_FIRST_RECORD"
assert_contains "transient unit receives the owner report path" "$(cat "$FAKE_SYSTEMD_ARGS_FILE")" \
  "<ZF_NODE_OWNER_REPORT_FILE=$TEST_ROOT/parent-first-report.md>"
wait_for_text "$PARENT_FIRST_STARTED" started "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - parent-first owner reaches Codex"
  FAILED=1
}
assert_eq "parent cleanup removes its ephemeral PID file" "0" \
  "$(find "$LOG_DIR" -maxdepth 1 -name '.dispatch-*.pid' -type f -print | wc -l | tr -d '[:space:]')"
touch "$PARENT_FIRST_RELEASE"
wait_for_owner_exit "$PARENT_FIRST_RECORD" || {
  echo "not ok - parent-first owner eventually records exited"
  FAILED=1
}
assert_eq "parent-first owner normal completion is exited" "exited" \
  "$(jq -r '.status' "$PARENT_FIRST_RECORD")"
assert_eq "parent-first owner normal exit code is recorded" "0" \
  "$(jq -r '.exit_code' "$PARENT_FIRST_RECORD")"

# Exercise the EXIT trap itself for both parent/owner orderings. The manifest
# PID stays durable whether parent cleanup removed the shared PID file or the
# owner exits before that cleanup runs.
PARENT_TRAP_MANIFEST="$TEST_ROOT/parent-trap.json"
PARENT_TRAP_PID_FILE="$TEST_ROOT/parent-trap.pid"
PARENT_TRAP_LOG="$TEST_ROOT/parent-trap.log"
jq -n --arg log "$PARENT_TRAP_LOG" '{status:"running",pid:123,log_file:$log}' > "$PARENT_TRAP_MANIFEST"
printf '%s\n' 123 > "$PARENT_TRAP_PID_FILE"
rm -f -- "$PARENT_TRAP_PID_FILE"
run_owner_exit_trap "$PARENT_TRAP_MANIFEST" "$PARENT_TRAP_PID_FILE" "$PARENT_TRAP_LOG" 0
assert_eq "parent cleanup cannot turn owner exit into dispatch-failed" "exited" \
  "$(jq -r '.status' "$PARENT_TRAP_MANIFEST")"
assert_eq "parent-first exit trap stores exit code" "0" \
  "$(jq -r '.exit_code' "$PARENT_TRAP_MANIFEST")"

OWNER_FIRST_MANIFEST="$TEST_ROOT/owner-first.json"
OWNER_FIRST_PID_FILE="$TEST_ROOT/owner-first.pid"
OWNER_FIRST_LOG="$TEST_ROOT/owner-first.log"
jq -n --arg log "$OWNER_FIRST_LOG" '{status:"running",pid:124,log_file:$log}' > "$OWNER_FIRST_MANIFEST"
printf '%s\n' 124 > "$OWNER_FIRST_PID_FILE"
sleep 3
run_owner_exit_trap "$OWNER_FIRST_MANIFEST" "$OWNER_FIRST_PID_FILE" "$OWNER_FIRST_LOG" 0
assert_eq "three-second owner-first exit cannot leave running manifest" "exited" \
  "$(jq -r '.status' "$OWNER_FIRST_MANIFEST")"
assert_eq "three-second owner-first exit stores code zero" "0" \
  "$(jq -r '.exit_code' "$OWNER_FIRST_MANIFEST")"
unset FAKE_CODEX_STARTED_FILE FAKE_CODEX_RELEASE_FILE ZF_NODE_OWNER_EPISODE ZF_NODE_OWNER_REPORT_FILE

# systemd sends TERM to the unit cgroup. The owner must retain the signal and
# leave a typed TIMEOUT report for unfinished work.
reset_fake_codex
SIGTERM_STARTED="$TEST_ROOT/sigterm-started"
SIGTERM_REPORT="$TEST_ROOT/sigterm-report.md"
export FAKE_CODEX_STARTED_FILE="$SIGTERM_STARTED"
export ZF_NODE_OWNER_EPISODE=sigterm
export ZF_NODE_OWNER_REPORT_FILE="$SIGTERM_REPORT"
run_dispatch --kind work --access delivery --prompt-file "$PROMPT_FILE"
SIGTERM_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_file "SIGTERM owner record exists" "$SIGTERM_RECORD"
SIGTERM_OWNER_PID="$(jq -r '.pid' "$SIGTERM_RECORD")"
wait_for_text "$SIGTERM_STARTED" started "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - SIGTERM owner reaches Codex"
  FAILED=1
}
/bin/kill -TERM -- "-$SIGTERM_OWNER_PID" 2>/dev/null || true
wait_for_owner_terminal "$SIGTERM_RECORD" || {
  echo "not ok - SIGTERM owner leaves running state"
  FAILED=1
}
assert_eq "SIGTERM owner is recorded killed" "killed" "$(jq -r '.status' "$SIGTERM_RECORD")"
assert_eq "SIGTERM owner records signal" "TERM" "$(jq -r '.exit_signal // empty' "$SIGTERM_RECORD")"
assert_contains "SIGTERM owner writes TIMEOUT" "$(cat "$SIGTERM_REPORT" 2>/dev/null || true)" "STATUS: TIMEOUT SIGTERM"
unset FAKE_CODEX_STARTED_FILE ZF_NODE_OWNER_EPISODE ZF_NODE_OWNER_REPORT_FILE
stop_fake_codex

# Launch-time load guard uses the shared 2x nproc rule and refuses unknown
# readings before any Codex process starts.
printf '%s\n' '30.01 30.00 29.00 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "high 1-minute load is refused" "1" "$RUN_STATUS"
assert_contains "high load reports shared 2x nproc limit" "$RUN_OUTPUT" "1-min load 30.01 exceeds 2x nproc (10; limit 20)"
assert_eq "high load never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

printf '%s\n' 'unavailable 30.00 29.00 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "invalid load reading is refused" "1" "$RUN_STATUS"
assert_contains "invalid load names fail-closed readings" "$RUN_OUTPUT" "cannot read valid 1-min load, nproc, or load multiplier"
assert_eq "invalid load never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

printf '%s\n' '0.10 0.12 0.13 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"
export FAKE_NPROC_FAIL=1
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "unreadable nproc is refused" "1" "$RUN_STATUS"
assert_contains "unreadable nproc names fail-closed readings" "$RUN_OUTPUT" "cannot read valid 1-min load, nproc, or load multiplier"
assert_eq "unreadable nproc never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
unset FAKE_NPROC_FAIL

# Count Codex argv by executable and `--cd` pair, not fixed option position.
# Sibling roots, non-Codex commands, and shell command text do not count.
CAP_PROCESS_LIST="$TEST_ROOT/cap-processes"
: > "$CAP_PROCESS_LIST"
for i in $(seq 1 20); do
  if [ $((i % 2)) -eq 0 ]; then
    printf '/usr/local/bin/codex exec --cd %s/owner-%s --model %s\n' "$ZF_WORKTREE_ROOT" "$i" "$WORK_MODEL" >> "$CAP_PROCESS_LIST"
  else
    printf 'codex exec --model %s --cd %s/owner-%s -\n' "$WORK_MODEL" "$ZF_WORKTREE_ROOT" "$i" >> "$CAP_PROCESS_LIST"
  fi
done
printf 'codex exec --cd %s-sibling/owner-11 --model %s\n' "$ZF_WORKTREE_ROOT" "$WORK_MODEL" >> "$CAP_PROCESS_LIST"
printf 'bash -c codex exec --cd %s/owner-12\n' "$ZF_WORKTREE_ROOT" >> "$CAP_PROCESS_LIST"
export FAKE_PS_PROCESS_LIST_FILE="$CAP_PROCESS_LIST"
unset MAX_AGENTS
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "default total agent cap is enforced" "1" "$RUN_STATUS"
assert_contains "cap counts Codex sessions despite option order" "$RUN_OUTPUT" "20 hand agents running, cap 10"
assert_eq "total cap never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
unset FAKE_PS_PROCESS_LIST_FILE

# Finishing admission uses its own slots, despite both ordinary cap and load.
export FAKE_PS_PROCESS_LIST_FILE="$CAP_PROCESS_LIST"
printf '%s\n' '65.8 60 50 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"
export ZF_NODE_OWNER_EPISODE=finishing-regression ZF_NODE_OWNER_NODE=merge
export ZF_NODE_OWNER_REPORT_FILE="$TEST_ROOT/finishing.report"
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "merge owner launches with ordinary cap full and high load" "0" "$RUN_STATUS"
FINISHING_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT" | tail -n 1)"
if [ -f "$FINISHING_RECORD" ]; then
  assert_eq "merge admission tier recorded" finishing "$(jq -r .admission_tier "$FINISHING_RECORD")"
fi
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - finishing owner reaches Codex"
  FAILED=1
}
stop_fake_codex
# Real memory floor and own cap still reject before any process starts.
FINISHING_MEMINFO="$TEST_ROOT/finishing-meminfo"
printf 'MemAvailable: 2046976 kB\n' > "$FINISHING_MEMINFO"
export AGENT_DISPATCH_MEMINFO_FILE="$FINISHING_MEMINFO"
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "finishing below memory floor refused" "1" "$RUN_STATUS"
assert_contains "finishing refusal names memory" "$RUN_OUTPUT" "below 2000MiB"
unset AGENT_DISPATCH_MEMINFO_FILE
export NODE_OWNER_MERGE_MAX_ACTIVE=invalid
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "invalid finishing cap refuses launch" "1" "$RUN_STATUS"
unset NODE_OWNER_MERGE_MAX_ACTIVE
unset ZF_NODE_OWNER_EPISODE ZF_NODE_OWNER_NODE ZF_NODE_OWNER_REPORT_FILE
reset_fake_codex
run_dispatch --kind work --prompt-file "$PROMPT_FILE"
assert_eq "ordinary hand still refused at same load and count" "1" "$RUN_STATUS"
assert_eq "ordinary refusal starts no codex" "" "$(cat "$FAKE_CODEX_PID_FILE")"
unset FAKE_PS_PROCESS_LIST_FILE
printf '%s\n' '0.10 0.12 0.13 1/1 100' > "$AGENT_DISPATCH_LOADAVG_FILE"

# Intent must exist before a detached child can publish a PID. A launcher that
# dies before setsid starts leaves the original brief and fixed parameters.
FAIL_BIN="$TEST_ROOT/fail-bin"
FAILED_AGENT_HOME="$TEST_ROOT/failed-agent-home"
mkdir -p "$FAIL_BIN"
cat > "$FAIL_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAIL_BIN/setsid"
set +e
PATH="$FAIL_BIN:$FAKE_BIN:$PATH" AGENT_HOME="$FAILED_AGENT_HOME" \
  FAKE_CODEX_ARGS_FILE="$TEST_ROOT/unreachable-args" \
  FAKE_CODEX_PID_FILE="$TEST_ROOT/unreachable.pid" \
  FAKE_CODEX_STDIN_FILE="$TEST_ROOT/unreachable-stdin" \
  bash "$DISPATCH_SRC" --kind work --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" >/dev/null 2>&1
FAIL_STATUS=$?
set -e
FAIL_RECORD="$(find "$FAILED_AGENT_HOME/hand-dispatch" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null || true)"
assert_eq "failed launcher returns nonzero" "1" "$FAIL_STATUS"
assert_file "dispatch persists replay intent before child launch" "$FAIL_RECORD"
if [ -f "$FAIL_RECORD" ]; then
  assert_eq "pre-launch record remains identity-free" "launching" "$(jq -r '.status' "$FAIL_RECORD")"
  assert_eq "pre-launch record keeps replay brief" "$(cat "$PROMPT_FILE")" "$(cat "$(jq -r '.brief_file' "$FAIL_RECORD")")"
else
  echo "not ok - pre-launch record remains identity-free (record missing)"
  echo "not ok - pre-launch record keeps replay brief (record missing)"
  FAILED=1
fi

reset_fake_codex
run_dispatch --kind hard --prompt-file "$PROMPT_FILE"
assert_eq "hard launch succeeds" "0" "$RUN_STATUS"
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - hard fake Codex args finish writing"
  FAILED=1
}
assert_contains "hard fake Codex args include final stdin selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<->"
assert_contains "hard uses the policy work model" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<$WORK_MODEL>"
assert_contains "hard uses policy effort" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<model_reasoning_effort=\"$WORK_EFFORT\">"
HARD_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_eq "hard defaults to investigation access" "investigation" "$(jq -r '.access' "$HARD_RECORD")"
assert_contains "hard investigation keeps workspace-write sandbox" \
  "$(cat "$FAKE_CODEX_ARGS_FILE")" "<workspace-write>"
assert_contains "hard investigation disables network access" \
  "$(cat "$FAKE_CODEX_ARGS_FILE")" "<sandbox_workspace_write.network_access=false>"
stop_fake_codex

reset_fake_codex
run_dispatch --kind production --access delivery --prompt-file "$PROMPT_FILE"
assert_eq "production launch succeeds" "0" "$RUN_STATUS"
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - production fake Codex args finish writing"
  FAILED=1
}
assert_contains "production fake Codex args include final stdin selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<->"
assert_contains "production uses the policy model" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<$PRODUCTION_MODEL>"
assert_contains "production uses policy effort" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<model_reasoning_effort=\"$PRODUCTION_EFFORT\">"
assert_eq "production policy has no service tier" "" "$PRODUCTION_SERVICE_TIER"
assert_not_contains "production dispatch omits service tier" "service_tier=" "$FAKE_CODEX_ARGS_FILE"
assert_contains "delivery passes sandbox selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<-s>"
assert_contains "delivery passes danger-full-access" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<danger-full-access>"
assert_contains "delivery passes network config selector" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<-c>"
assert_contains "delivery enables network access" "$(cat "$FAKE_CODEX_ARGS_FILE")" "<sandbox_workspace_write.network_access=true>"
DELIVERY_RECORD="$(sed -n 's/.* record=//p' <<< "$RUN_OUTPUT")"
assert_eq "delivery record round-trips access" "delivery" "$(jq -r '.access' "$DELIVERY_RECORD")"
stop_fake_codex

reset_fake_codex
MISMATCH_MANIFEST="$TEST_ROOT/mismatch-owner.json"
MISMATCH_PENDING_LOG="$TEST_ROOT/mismatch-owner.log"
MISMATCH_PID_FILE="$TEST_ROOT/mismatch-owner.pid"
printf '%s\n' '{"status":"launching"}' > "$MISMATCH_MANIFEST"
: > "$MISMATCH_PENDING_LOG"
: > "$MISMATCH_PID_FILE"
set +e
MISMATCH_OUTPUT="$(PATH="$FAKE_BIN:$PATH" AGENT_HOME="$AGENT_HOME" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  bash "$DISPATCH_SRC" --owner-session "$PROMPT_FILE" "$MISMATCH_PID_FILE" \
  "$MISMATCH_MANIFEST" "$MISMATCH_PENDING_LOG" "$LOG_DIR" "$WORKTREE" \
  production other-model max delivery zf-owner-test 2>&1)"
MISMATCH_STATUS=$?
set -e
assert_eq "owner session rejects model that differs from resolved role" "64" "$MISMATCH_STATUS"
assert_contains "owner session reports resolved role on mismatch" "$MISMATCH_OUTPUT" "does not match policy role 'production'"
assert_eq "owner session mismatch never starts Codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

reset_fake_codex
run_dispatch --kind luna --prompt-file "$PROMPT_FILE"
assert_eq "unknown kind is refused" "2" "$RUN_STATUS"
assert_contains "unknown kind names valid choices" "$RUN_OUTPUT" "expected work, hard, or production"
assert_eq "unknown kind never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

reset_fake_codex
run_dispatch --kind work --model luna --prompt-file "$PROMPT_FILE"
assert_eq "free-form model override is refused" "2" "$RUN_STATUS"
assert_contains "free-form model error explains routing" "$RUN_OUTPUT" "model is selected by --kind"
assert_eq "free-form model never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

reset_fake_codex
run_dispatch --kind work --access unrestricted --prompt-file "$PROMPT_FILE"
assert_eq "unknown access is refused" "2" "$RUN_STATUS"
assert_contains "unknown access names valid choices" "$RUN_OUTPUT" "expected investigation or delivery"
assert_eq "unknown access never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

git -C "$WORKTREE" switch --detach -q
reset_fake_codex
run_dispatch --kind work --access unrestricted --branch manual-recovery --prompt-file "$PROMPT_FILE"
assert_eq "invalid access never attaches detached worktree" "2" "$RUN_STATUS"
assert_eq "invalid access leaves worktree detached" "true" \
  "$(if git -C "$WORKTREE" symbolic-ref --quiet HEAD >/dev/null 2>&1; then echo false; else echo true; fi)"

reset_fake_codex
run_dispatch --kind work --branch manual-recovery --prompt-file "$PROMPT_FILE"
assert_eq "detached launch attaches requested branch" "0" "$RUN_STATUS"
assert_eq "detached launch restores recorded branch" "manual-recovery" \
  "$(git -C "$WORKTREE" symbolic-ref --short HEAD)"
wait_for_text "$FAKE_CODEX_ARGS_FILE" "<->" "$ASYNC_CODEX_START_ATTEMPTS" || {
  echo "not ok - detached launch reaches Codex"
  FAILED=1
}
stop_fake_codex
git -C "$WORKTREE" switch manual-recovery -q || true

LOW_MEMINFO="$TEST_ROOT/low-meminfo"
printf '%s\n' 'MemAvailable:       1048576 kB' > "$LOW_MEMINFO"
reset_fake_codex
set +e
RUN_OUTPUT="$(PATH="$LOW_MEMORY_BIN:$FAKE_BIN:$PATH" \
  AGENT_HOME="$AGENT_HOME" \
  AGENT_DISPATCH_MEMINFO_FILE="$LOW_MEMINFO" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  bash "$DISPATCH_SRC" --kind work --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "low memory is refused" "1" "$RUN_STATUS"
assert_contains "low memory reports the floor" "$RUN_OUTPUT" "below 2048MiB"
assert_contains "low memory names top RSS holder" "$RUN_OUTPUT" "pipeline-hog"
assert_eq "low memory never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"

reset_fake_codex
set +e
RUN_OUTPUT="$(PATH="$BAD_SETSID_BIN:$FAKE_BIN:$PATH" \
  AGENT_HOME="$AGENT_HOME" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  bash "$DISPATCH_SRC" --kind work --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "non-detaching setsid is refused" "1" "$RUN_STATUS"
assert_contains "non-detaching setsid names verification failure" "$RUN_OUTPUT" "detachment verification failed"
BAD_PID="$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE" 2>/dev/null || true)"
if [ -n "$BAD_PID" ] && kill -0 "$BAD_PID" 2>/dev/null; then
  echo "not ok - non-detaching child is terminated"
  FAILED=1
else
  echo "ok - non-detaching child is terminated"
fi
stop_fake_codex

reset_fake_codex
set +e
RUN_OUTPUT="$(PATH="$PID_FAILURE_SETSID_BIN:$FAKE_BIN:$PATH" \
  AGENT_HOME="$AGENT_HOME" \
  AGENT_DISPATCH_LOG_DIR="$LOG_DIR" \
  FAKE_CODEX_ARGS_FILE="$FAKE_CODEX_ARGS_FILE" \
  FAKE_CODEX_STDIN_FILE="$FAKE_CODEX_STDIN_FILE" \
  FAKE_CODEX_PID_FILE="$FAKE_CODEX_PID_FILE" \
  bash "$DISPATCH_SRC" --kind work --prompt-file "$PROMPT_FILE" --worktree "$WORKTREE" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "PID-publication failure is refused" "1" "$RUN_STATUS"
assert_contains "PID-publication failure names verification" "$RUN_OUTPUT" "agent never published a PID"
assert_eq "PID-publication failure never starts codex" "" "$(tr -d '[:space:]' < "$FAKE_CODEX_PID_FILE")"
stop_fake_codex

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ALL PASS"
