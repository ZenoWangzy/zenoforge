#!/usr/bin/env bash
# Manual, watched-session Codex dispatcher. This never routes through
# issue-pipeline.sh or changes its run-implement.sh/run-advisor.sh dispatch.
# The supervisor owns recovery; this launcher records exact replay inputs
# before the process starts.
#
# Capacity basis (2026-09-21): 52 implement units in 24 hours peaked at
# median 1.6G, p90 3.6G, max 4.8G.  Maintainer floor: 2G MemAvailable.
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh"
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
INDEX_ROOT="${ZF_CODE_INTELLIGENCE_ROOT:-$REPO_DIR}"
MIN_AVAILABLE_KIB=$((2 * 1024 * 1024))
VERIFY_ATTEMPTS=50
VERIFY_DELAY_SECONDS=0.1
AGENT_HOME="${AGENT_HOME:-${HOME:-.}/.zenoforge}"
DISPATCH_DIR="${AGENT_DISPATCH_DIR:-$AGENT_HOME/hand-dispatch}"
LOG_ROOT="${AGENT_DISPATCH_LOG_DIR:-$AGENT_HOME/logs/hand-dispatch}"
MEMINFO_FILE="${AGENT_DISPATCH_MEMINFO_FILE:-/proc/meminfo}"
LOADAVG_FILE="${AGENT_DISPATCH_LOADAVG_FILE:-/proc/loadavg}"
WORKTREE_ROOT="${ZF_WORKTREE_ROOT:-$HOME/wt}"
WORKTREE_ROOT_PREFIX="${WORKTREE_ROOT%/}/"
MAX_AGENTS="${MAX_AGENTS:-10}"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/redact-secrets.sh"
if [[ "${1:-}" != --owner-session ]] || ! python3 "$(pipeline_execution_guard)" inherited; then
  pipeline_execution_admit || exit $?
fi
# shellcheck source=./dispatch-load-guard.sh
source "$SCRIPT_DIR/dispatch-load-guard.sh"
source "$SCRIPT_DIR/thread-budget.sh"
PATH="$SCRIPT_DIR/gh-shim:$PATH"
export PATH

# 2026-10-08 (issue 2695, run 3): the sessions this script launches run node
# test suites and preflights whose built-in fetch ignores https_proxy/
# HTTPS_PROXY unless NODE_USE_ENV_PROXY=1 is set (same wall run-release.sh
# documented at its Postsubmit preflight). Default it once here — before the
# owner unit's env copy below and before the direct setsid session — so every
# hand dispatch session routes node fetches through the egress proxy.
export NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"

# This standalone dispatcher does not source lib.sh; keep same helper available.
declare -F jq_arg_file >/dev/null 2>&1 || jq_arg_file() {
  local f
  f="$(mktemp)" || return 1
  printf '%s' "$1" > "$f"
  echo "$f"
}

dispatch_jq_reason() {
  local reason="$1" reason_file status
  shift
  reason_file="$(jq_arg_file "$reason")" || return 1
  if jq --rawfile reason "$reason_file" "$@"; then
    status=0
  else
    status=$?
  fi
  rm -f -- "$reason_file" || true
  return "$status"
}

KIND=""
ACCESS=""
PROMPT_FILE=""
WORKTREE=""
BRANCH=""
REQUESTED_BRANCH=""
BRIEF_FILE=""
MANIFEST_FILE=""
MANIFEST_TMP=""
PID_FILE=""
RENDERED_PROMPT=""
PENDING_LOG=""
LOG_FILE=""
AGENT_PID=""
LAUNCHER_PID=""
PID_START_TICKS=""
DISPATCH_BUDGET_ID=""
DISPATCH_BUDGET_HANDED_OFF=0
SANDBOX_ARGS=()

usage() {
  cat >&2 <<EOF
usage: $SCRIPT_NAME --kind work|hard|production --prompt-file PATH [--access investigation|delivery] [--worktree PATH] [--branch BRANCH]

Kind selects the only allowed Codex configuration:
  work        persistent work role
  hard        persistent work role
  production  persistent production role

Access selects the only allowed authority level:
  investigation  workspace-write, no network (default)
  delivery       danger-full-access plus workspace-write network access
EOF
}

die_usage() {
  echo "$SCRIPT_NAME: $*" >&2
  usage
  exit 2
}

die() {
  echo "$SCRIPT_NAME: $*" >&2
  exit 1
}

dispatch_codex_config_guard() {
  local stage="${1:-hand-dispatch}"
  codex_dispatch_preflight "$stage"
}

dispatch_redact_line() {
  redact_secret_text "$1" | cut -c1-400
}
dispatch_log_output() {
  local log_file="$1" line lower safe now event_error event_tokens awaiting_tokens=0
  while IFS= read -r line || [ -n "$line" ]; do
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    lower="${line,,}"
    if [[ "$lower" =~ ^[[:space:]]*tokens[[:space:]]+used[[:space:]]*$ ]]; then
      printf 'tokens used\n' >> "$log_file"
      awaiting_tokens=1
      continue
    fi
    if [ "$awaiting_tokens" = 1 ]; then
      if [[ "$line" =~ ^[[:space:]]*[0-9][0-9,]*[[:space:]]*$ ]]; then
        printf '%s\n' "$line" >> "$log_file"
        awaiting_tokens=0
        continue
      fi
      awaiting_tokens=0
    fi
    if [[ "$line" == \{* ]]; then
      event_error="$(jq -r 'if .type == "error" then .message elif .type == "turn.failed" then .error.message else empty end | select(type == "string")' 2>/dev/null <<< "$line" || true)"
      if [ -n "$event_error" ]; then
        safe="$(dispatch_redact_line "$event_error")"
        printf '%s codex-provider-error %s\n' "$now" "$safe" >> "$log_file"
      fi
      event_tokens="$(codex_tokens_used "$line" 2>/dev/null || true)"
      if [[ "$event_tokens" =~ ^[0-9]+$ ]]; then
        printf 'tokens used\n%s\n' "$event_tokens" >> "$log_file"
      fi
    fi
    printf '%s codex-output\n' "$now" >> "$log_file"
    if [[ "$lower" =~ (error|failed|failure|unauthorized|forbidden|http[[:space:]]+[45][0-9][0-9]|rate.?limit|quota|capacity|overload|timed?[[:space:]]*out|timeout|invalid|not[[:space:]]+found|missing|denied|could[[:space:]]+not|cannot|refused|unavailable|connection) ]]; then
      safe="$(dispatch_redact_line "$line")"
      [ -n "$safe" ] && printf '%s codex-error %s\n' "$now" "$safe" >> "$log_file"
    fi
  done
}
export -f dispatch_redact_line

dispatch_owner_session_exit() {
  local exit_status="$1" status log_file reason now tmp published_pid terminal_status signal tokens
  [ -n "${OWNER_SESSION_MANIFEST_FILE:-}" ] || return 0
  log_file="$(jq -r '.log_file // empty' "$OWNER_SESSION_MANIFEST_FILE" 2>/dev/null || true)"
  [ -n "$log_file" ] || log_file="${OWNER_SESSION_PENDING_LOG:-}"
  tokens="$(codex_tokens_used "$log_file" 2>/dev/null || true)"
  if [ "${OWNER_SESSION_BUDGET_RECORDED:-0}" != 1 ] \
    && [[ "${OWNER_SESSION_BUDGET_ROLE:-}" =~ ^(work|production)$ ]] \
    && [ -n "$tokens" ] && [[ "$tokens" =~ ^[0-9]+$ ]]; then
    record_premium_spend "$OWNER_SESSION_BUDGET_ROLE" \
      "codex:${OWNER_SESSION_BUDGET_MODEL}:${OWNER_SESSION_BUDGET_EFFORT}" \
      "${OWNER_SESSION_BUDGET_SOURCE:-node-auto-owner}" "" \
      "${OWNER_SESSION_BUDGET_STARTED_AT:-$(date +%s)}" "$tokens" || true
    OWNER_SESSION_BUDGET_RECORDED=1
  fi
  if [ "${OWNER_SESSION_FAILURE_RECORDED:-0}" != 1 ]; then
    codex_session_failure "$log_file" "$exit_status" owner-session "${OWNER_SESSION_BUDGET_MODEL:-unknown}" "${OWNER_SESSION_SIGNAL:-}" || true
  fi
  codex_budget_release "${OWNER_SESSION_BUDGET_ID:-}" || true
  status="$(jq -r '.status // empty' "$OWNER_SESSION_MANIFEST_FILE" 2>/dev/null || true)"
  case "$status" in launching|running) ;; *) return 0 ;; esac
  published_pid="$(jq -r '.pid // empty' "$OWNER_SESSION_MANIFEST_FILE" 2>/dev/null || true)"
  case "$published_pid" in ''|*[!0-9]*)
    terminal_status=dispatch-failed
    reason="owner session exited before PID publication (status $exit_status)"
    signal=""
    ;;
    *)
      if [ -n "${OWNER_SESSION_SIGNAL:-}" ]; then
        terminal_status=killed
        signal="$OWNER_SESSION_SIGNAL"
        reason="owner session killed by SIG$signal (status $exit_status)"
      else
        terminal_status=exited
        signal=""
        reason="owner session exited before final result was recorded (status $exit_status)"
      fi
      ;;
  esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$OWNER_SESSION_MANIFEST_FILE.tmp"
  if dispatch_jq_reason "$reason" --arg status "$terminal_status" --arg signal "$signal" \
    --arg now "$now" --argjson exit_code "$exit_status" \
    '.status = $status | .exit_reason = $reason | .finished_at = $now | .updated_at = $now
     | if $status == "killed" then .exit_signal = $signal
       elif $status == "exited" then .exit_code = $exit_code
       else . end' \
    "$OWNER_SESSION_MANIFEST_FILE" > "$tmp" 2>/dev/null; then
    mv -- "$tmp" "$OWNER_SESSION_MANIFEST_FILE" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  case "$terminal_status" in
    killed) printf '%s owner-session-killed signal=%s reason=%s\n' "$now" "$signal" "$reason" >> "$log_file" 2>/dev/null || true ;;
    exited) printf '%s owner-session-exited status=%s reason=%s\n' "$now" "$exit_status" "$reason" >> "$log_file" 2>/dev/null || true ;;
    *) printf '%s dispatch-failed reason=%s\n' "$now" "$reason" >> "$log_file" 2>/dev/null || true ;;
  esac
}

dispatch_owner_session_signal() {
  local signal="$1" exit_status="$2" report_file tmp reason
  OWNER_SESSION_SIGNAL="$signal"
  if [ -n "${OWNER_SESSION_MANIFEST_FILE:-}" ]; then
    "$SCRIPT_DIR/owner-stop-request.sh" \
      "$OWNER_SESSION_MANIFEST_FILE" "${OWNER_SESSION_PENDING_LOG:-}" "${OWNER_SESSION_UNIT:-}" \
      UNKNOWN direct-signal || true
  fi
  report_file="${ZF_NODE_OWNER_REPORT_FILE:-}"
  if [ -n "$report_file" ] && ! awk '
    NF { last=$0 }
    END { sub(/\r$/, "", last); exit !(last ~ /^STATUS: (DONE|FOLLOWUP\([0-9]+(, [0-9]+)*\)|NEEDS-DECISION|FAILED|LANDING-QUEUED|TIMEOUT .+)$/) }
  ' "$report_file" 2>/dev/null; then
    reason="$(jq -r '.stop_reason // "unit-runtime-or-external-stop"' "${OWNER_SESSION_MANIFEST_FILE:-}" 2>/dev/null || true)"
    tmp="$report_file.tmp.$$"
    { cat -- "$report_file" 2>/dev/null || true; printf '\nSTATUS: TIMEOUT SIG%s reason=%s\n' "$signal" "${reason:-unknown}"; } > "$tmp" \
      && mv -- "$tmp" "$report_file" || rm -f -- "$tmp"
  fi
  exit "$exit_status"
}

dispatch_owner_session() {
  local prompt_file="$1" pid_file="$2" manifest_file="$3" pending_log="$4" log_root="$5"
  local worktree="$6" kind="$7" model="$8" effort="$9" access="${10}" unit_name="${11}"
  local budget_id="${12:-}" budget_source="${13:-node-auto-owner}"
  local base_repo_dir="$REPO_DIR"
  local pid ticks final_log now exit_code last_error exit_reason tmp role identity provider service_tier tokens primary_identity fallback_identity
  local -a sandbox_args=() service_tier_args=()
  OWNER_SESSION_BUDGET_ID=""
  OWNER_SESSION_FAILURE_RECORDED=0
  OWNER_SESSION_BUDGET_SOURCE="$budget_source"
  OWNER_SESSION_BUDGET_ROLE=""
  OWNER_SESSION_BUDGET_MODEL=""
  OWNER_SESSION_BUDGET_EFFORT=""
  OWNER_SESSION_BUDGET_STARTED_AT=""
  OWNER_SESSION_BUDGET_RECORDED=0
  REPO_DIR="$worktree"
  ZF_REPO_DIR="$worktree"
  export REPO_DIR ZF_REPO_DIR
  cd -- "$worktree" || return 1
  OWNER_SESSION_MANIFEST_FILE="$manifest_file"
  OWNER_SESSION_PID_FILE="$pid_file"
  OWNER_SESSION_PENDING_LOG="$pending_log"
  OWNER_SESSION_UNIT="$unit_name"
  OWNER_SESSION_SIGNAL=""
  trap 'dispatch_owner_session_exit "$?"' EXIT
  trap 'dispatch_owner_session_signal TERM 143' TERM
  trap 'dispatch_owner_session_signal INT 130' INT
  trap 'dispatch_owner_session_signal HUP 129' HUP
  trap 'dispatch_owner_session_signal QUIT 131' QUIT

  case "$kind" in
    work|hard) role=work ;;
    production) role=production ;;
    *) echo "$SCRIPT_NAME: refusing owner session: unknown kind '$kind'" >&2; return 64 ;;
  esac
  primary_identity="$(model_policy identity "$role")" || return 1
  identity="codex:$model:$effort"
  fallback_identity="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' "$MODEL_POLICY_FILE")"
  service_tier="$(model_policy tier "$identity")" || return 1
  [ -z "$service_tier" ] || service_tier_args=(--config "service_tier=\"$service_tier\"")
  provider="${identity%%:*}"
  if [ "$provider" != codex ] || { [ "$identity" != "$primary_identity" ] && [ "$identity" != "$fallback_identity" ]; }; then
    echo "$SCRIPT_NAME: refusing owner session: supplied model/effort does not match policy role '$role' ($identity)" >&2
    return 64
  fi
  dispatch_codex_config_guard "$budget_source" || return 1
  OWNER_SESSION_BUDGET_ID="$budget_id"
  if [ -z "$OWNER_SESSION_BUDGET_ID" ]; then
    OWNER_SESSION_BUDGET_ID="node-owner:$(jq -r '.id // empty' "$manifest_file" 2>/dev/null || true)"
    [ "$OWNER_SESSION_BUDGET_ID" != node-owner: ] || OWNER_SESSION_BUDGET_ID="node-owner:$$"
  fi
  OWNER_SESSION_BUDGET_ROLE="$role"
  OWNER_SESSION_BUDGET_MODEL="$model"
  OWNER_SESSION_BUDGET_EFFORT="$effort"
  if ! codex_budget_adopt "$OWNER_SESSION_BUDGET_ID" "$$"; then
    codex_budget_reserve "$role" "$OWNER_SESSION_BUDGET_ID" "" 0 "" "$identity" || return $?
  fi
  if codex_model_capacity_held "$identity"; then
    echo "$SCRIPT_NAME: node-auto-owner deferred by Codex model capacity hold" >&2
    return 75
  fi
  if provider_quota_exhausted codex; then
    echo "$SCRIPT_NAME: node-auto-owner deferred by Codex provider quota hold" >&2
    return 75
  fi

  case "$access" in
    investigation) sandbox_args=(-s workspace-write -c sandbox_workspace_write.network_access=false) ;;
    delivery) sandbox_args=(-s danger-full-access -c sandbox_workspace_write.network_access=true) ;;
    *) return 2 ;;
  esac

  exec 3<"$prompt_file" || return 1
  pid="$$"
  ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  case "$ticks" in ''|*[!0-9]*) return 1 ;; esac
  final_log="$log_root/$pid.log"
  mv -- "$pending_log" "$final_log" || return 1
  tmp="$manifest_file.tmp"
  jq --arg log_file "$final_log" --arg ticks "$ticks" --arg unit_name "$unit_name" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid "$pid" \
    '.status = "running" | .log_file = $log_file | .pid_start_ticks = $ticks | .pid = $pid | .updated_at = $now | (if $unit_name == "" then . else .execution_mode = "systemd" | .unit_name = $unit_name end)' \
    "$manifest_file" > "$tmp" || return 1
  mv -- "$tmp" "$manifest_file" || return 1
  printf '%s\n' "$pid" > "$pid_file"

  agent_thread_budget
  OWNER_SESSION_BUDGET_STARTED_AT="$(date +%s)"
  set +e
  pipeline_execution_run codex exec --json --model "$model" --config "model_reasoning_effort=\"$effort\"" "${service_tier_args[@]}" \
    --config mcp_servers.gitnexus.enabled=false \
    --cd "$worktree" "${sandbox_args[@]}" - <&3 2>&1 | dispatch_log_output "$final_log"
  exit_code="${PIPESTATUS[0]}"
  set -e

  tokens="$(codex_tokens_used "$final_log" 2>/dev/null || true)"
  if [[ "$OWNER_SESSION_BUDGET_ROLE" =~ ^(work|production)$ ]] \
    && [ -n "$tokens" ] && [[ "$tokens" =~ ^[0-9]+$ ]]; then
    record_premium_spend "$OWNER_SESSION_BUDGET_ROLE" \
      "codex:${OWNER_SESSION_BUDGET_MODEL}:${OWNER_SESSION_BUDGET_EFFORT}" \
      "$OWNER_SESSION_BUDGET_SOURCE" "" "$OWNER_SESSION_BUDGET_STARTED_AT" "$tokens" || true
    OWNER_SESSION_BUDGET_RECORDED=1
  fi

  # Publish provider/model failure state before the terminal manifest is visible.
  codex_session_failure "$final_log" "$exit_code" owner-session "$model" "${OWNER_SESSION_SIGNAL:-}" || true
  OWNER_SESSION_FAILURE_RECORDED=1

  # The terminal manifest is the completion receipt; clear the budget lease first.
  codex_budget_release "$OWNER_SESSION_BUDGET_ID" || true

  last_error="$(sed -n 's/^[^ ]* codex-error //p' "$final_log" | tail -n 1 | cut -c1-400)"
  exit_reason="codex exited with status $exit_code${last_error:+: $last_error}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$manifest_file.tmp"
  jq --arg status exited --arg exit_reason "$exit_reason" --arg last_error_line "$last_error" \
    --arg finished_at "$now" --argjson exit_code "$exit_code" \
    '.status = $status | .exit_code = $exit_code | .exit_reason = $exit_reason | .last_error_line = $last_error_line | .finished_at = $finished_at | .updated_at = $finished_at' \
    "$manifest_file" > "$tmp" || return 1
  mv -- "$tmp" "$manifest_file" || return 1
  printf '%s codex-exit status=%s reason=%s\n' "$now" "$exit_code" "$exit_reason" >> "$final_log"
  if [ "$OWNER_SESSION_BUDGET_SOURCE" = node-auto-owner ]; then
    if ! cleanup_output="$(timeout 90 bash "$SCRIPT_DIR/worktree-lifecycle.sh" finish-dispatch "$base_repo_dir" "$worktree" "$$" 2>&1)"; then
      printf '%s worktree-cleanup-warning %s\n' "$now" "$cleanup_output" >> "$final_log"
    fi
  fi
  return "$exit_code"
}

if [ "${1:-}" = --owner-session ]; then
  shift
  dispatch_owner_session "$@"
  exit $?
fi

cleanup() {
  [ -z "$PID_FILE" ] || rm -f -- "$PID_FILE"
  [ -z "$RENDERED_PROMPT" ] || rm -f -- "$RENDERED_PROMPT"
  if [ "$DISPATCH_BUDGET_HANDED_OFF" != 1 ] && [ -n "$DISPATCH_BUDGET_ID" ]; then
    codex_budget_release "$DISPATCH_BUDGET_ID" || true
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$#" -ge 2 ] || die_usage "--kind needs work, hard, or production"
      [ -z "$KIND" ] || die_usage "--kind was supplied more than once"
      KIND="$2"
      shift 2
      ;;
    --prompt-file)
      [ "$#" -ge 2 ] || die_usage "--prompt-file needs a path"
      [ -z "$PROMPT_FILE" ] || die_usage "--prompt-file was supplied more than once"
      PROMPT_FILE="$2"
      shift 2
      ;;
    --worktree)
      [ "$#" -ge 2 ] || die_usage "--worktree needs a path"
      [ -z "$WORKTREE" ] || die_usage "--worktree was supplied more than once"
      WORKTREE="$2"
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || die_usage "--branch needs a branch"
      [ -z "$REQUESTED_BRANCH" ] || die_usage "--branch was supplied more than once"
      REQUESTED_BRANCH="$2"
      shift 2
      ;;
    --access)
      [ "$#" -ge 2 ] || die_usage "--access needs investigation or delivery"
      [ -z "$ACCESS" ] || die_usage "--access was supplied more than once"
      ACCESS="$2"
      shift 2
      ;;
    --model|--effort|--reasoning-effort)
      die_usage "model is selected by --kind; free-form $1 is not supported"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

[ -n "$KIND" ] || die_usage "--kind is required"
[ -n "$PROMPT_FILE" ] || die_usage "--prompt-file is required"
if [ ! -f "$PROMPT_FILE" ] || [ ! -r "$PROMPT_FILE" ]; then
  die_usage "prompt file is not readable: $PROMPT_FILE"
fi
ACCESS="${ACCESS:-investigation}"
WORKTREE="${WORKTREE:-$(pwd -P)}"
WORKTREE="$(cd "$WORKTREE" && pwd -P)" || die "worktree is not accessible: $WORKTREE"
git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "worktree is not a Git worktree: $WORKTREE"
WORKTREE="$(git -C "$WORKTREE" rev-parse --show-toplevel)"

case "$KIND" in
  work|hard) ROLE=work ;;
  production) ROLE=production ;;
  *)
    die_usage "unknown --kind $KIND; expected work, hard, or production"
    ;;
esac
IDENTITY="$(model_policy dispatch-identity "$ROLE")"
SERVICE_TIER="$(model_policy tier "$IDENTITY")"
SERVICE_TIER_ARGS=()
[ -z "$SERVICE_TIER" ] || SERVICE_TIER_ARGS=(--config "service_tier=\"$SERVICE_TIER\"")
IFS=: read -r PROVIDER MODEL EFFORT <<< "$IDENTITY"
[ "$PROVIDER" = codex ] || die "policy role $ROLE is not a Codex role"

# Kind fixes model cost/quality; access fixes external authority. Keep them
# separate so choosing a model never silently grants network-capable delivery.
case "$ACCESS" in
  investigation)
    SANDBOX_ARGS=(-s workspace-write -c sandbox_workspace_write.network_access=false)
    ;;
  delivery)
    SANDBOX_ARGS=(-s danger-full-access -c sandbox_workspace_write.network_access=true)
    ;;
  *)
    die_usage "unknown --access $ACCESS; expected investigation or delivery"
    ;;
esac

BRANCH="$(git -C "$WORKTREE" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
  [ -n "$REQUESTED_BRANCH" ] || die "worktree is detached; --branch is required for recovery: $WORKTREE"
  git -C "$WORKTREE" switch "$REQUESTED_BRANCH" >/dev/null ||
    die "could not attach detached worktree to requested branch: $REQUESTED_BRANCH"
  BRANCH="$(git -C "$WORKTREE" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$BRANCH" = "$REQUESTED_BRANCH" ] || die "worktree did not attach requested branch: $REQUESTED_BRANCH"
elif [ -n "$REQUESTED_BRANCH" ] && [ "$BRANCH" != "$REQUESTED_BRANCH" ]; then
  die "worktree branch $BRANCH does not match requested --branch $REQUESTED_BRANCH"
fi

ADMISSION_ROLE="$ROLE"
if [ -n "${ZF_NODE_OWNER_EPISODE:-}" ] && [ "${ZF_NODE_OWNER_NODE:-}" = merge ]; then
  ADMISSION_ROLE=merge-owner
fi
ADMISSION_TIER="$(hand_dispatch_tier "$ADMISSION_ROLE")" || die "cannot resolve dispatch admission tier"
if [ "$ADMISSION_TIER" = finishing ]; then
  MIN_AVAILABLE_KIB=$(( $(hand_dispatch_memory_floor "$ADMISSION_TIER") * 1024 ))
fi
MEM_AVAILABLE_KIB="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null || true)"
case "$MEM_AVAILABLE_KIB" in
  ''|*[!0-9]*) die "cannot read MemAvailable from $MEMINFO_FILE" ;;
esac
if [ "$MEM_AVAILABLE_KIB" -lt "$MIN_AVAILABLE_KIB" ]; then
  echo "$SCRIPT_NAME: refusing launch: MemAvailable $((MEM_AVAILABLE_KIB / 1024))MiB is below $((MIN_AVAILABLE_KIB / 1024))MiB (class=$ADMISSION_TIER); largest RSS holders:" >&2
  ps -eo pid=,ppid=,rss=,comm= --sort=-rss | sed -n '1,8p' >&2 || true
  exit 1
fi

if [ "$ADMISSION_TIER" = finishing ]; then
  FINISHING_CAP="${NODE_OWNER_MERGE_MAX_ACTIVE:-$(jq -er '.max_active.finishing' "$(hand_priority_state)")}"
  [[ "$FINISHING_CAP" =~ ^[1-9][0-9]*$ ]] || die "invalid finishing owner cap"
  RUNNING_AGENTS="$(hand_agent_process_count "$WORKTREE_ROOT_PREFIX" finishing)" || die "cannot inspect finishing owners"
  if [ "$RUNNING_AGENTS" -ge "$FINISHING_CAP" ]; then
    echo "$SCRIPT_NAME: refusing launch: $RUNNING_AGENTS finishing owners running, cap $FINISHING_CAP" >&2
    exit 1
  fi
else
  if [ -n "${AGENT_EXECUTION_CPU_TARGET_PERCENT:-}" ]; then
    python3 "$(pipeline_execution_guard)" resources >/dev/null || exit $?
  else
  LOAD_1M="$(awk 'NR == 1 { print $1; exit }' "$LOADAVG_FILE" 2>/dev/null || true)"
  PROCESSORS="$(nproc 2>/dev/null || true)"
  LOAD_LIMIT_MULTIPLIER="${AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER:-2}"
  if dispatch_load_exceeded "$LOAD_1M" "$PROCESSORS" "$LOAD_LIMIT_MULTIPLIER"; then
    echo "$SCRIPT_NAME: refusing launch: 1-min load $LOAD_1M exceeds ${LOAD_LIMIT_MULTIPLIER}x nproc ($PROCESSORS; limit $((PROCESSORS * LOAD_LIMIT_MULTIPLIER)))" >&2
    exit 1
  else
    LOAD_GUARD_STATUS=$?
    [ "$LOAD_GUARD_STATUS" -eq 1 ] || die "cannot read valid 1-min load, nproc, or load multiplier (load=${LOAD_1M:-missing}, nproc=${PROCESSORS:-missing}, multiplier=$LOAD_LIMIT_MULTIPLIER)"
  fi

  fi

  [[ "$MAX_AGENTS" =~ ^[1-9][0-9]*$ ]] || die "MAX_AGENTS must be a positive integer"
  if ! RUNNING_AGENTS="$(hand_agent_process_count "$WORKTREE_ROOT_PREFIX" ordinary-hand)"; then
    die "cannot inspect running Codex agents"
  fi
  if [ "$RUNNING_AGENTS" -ge "$MAX_AGENTS" ]; then
    echo "$SCRIPT_NAME: refusing launch: $RUNNING_AGENTS hand agents running, cap $MAX_AGENTS" >&2
    exit 1
  fi
fi

command -v setsid >/dev/null 2>&1 || die "setsid is not on PATH"
command -v codex >/dev/null 2>&1 || die "codex is not on PATH"
config_fault_stage=hand-dispatch
[ -n "${ZF_NODE_OWNER_EPISODE:-}" ] && config_fault_stage=node-auto-owner
dispatch_codex_config_guard "$config_fault_stage" || exit 1

umask 077
mkdir -p "$DISPATCH_DIR" "$LOG_ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="$STAMP-$$"
OWNER_UNIT=""
if [ -n "${ZF_NODE_OWNER_EPISODE:-}" ]; then
  OWNER_UNIT="${UNIT_PREFIX_TRANSIENT}-node-owner-${ZF_NODE_OWNER_EPISODE}-${RUN_ID}"
  NODE_OWNER_BUDGET_ID="node-owner:$RUN_ID"
  DISPATCH_BUDGET_ID="$NODE_OWNER_BUDGET_ID"
  if ! codex_budget_reserve "$ROLE" "$NODE_OWNER_BUDGET_ID" "" 1 "" "$IDENTITY"; then
    echo "$SCRIPT_NAME: node-auto-owner launch deferred by Codex budget/hold" >&2
    exit 75
  fi
else
  DISPATCH_BUDGET_ID="hand-dispatch:$RUN_ID"
  HAND_BUDGET_TOKENS="$CODEX_HAND_DISPATCH_RESERVATION_TOKENS"
  [ "$ROLE" != production ] || HAND_BUDGET_TOKENS="$CODEX_PRODUCTION_RESERVATION_TOKENS"
  if ! codex_budget_reserve "$ROLE" "$DISPATCH_BUDGET_ID" "$HAND_BUDGET_TOKENS" 1 "" "$IDENTITY"; then
    echo "$SCRIPT_NAME: hand dispatch launch deferred by Codex budget/hold" >&2
    exit 75
  fi
fi
BRIEF_FILE="$DISPATCH_DIR/$RUN_ID.md"
MANIFEST_FILE="$DISPATCH_DIR/$RUN_ID.json"
PENDING_LOG="$LOG_ROOT/.dispatch-$RUN_ID.log"
PID_FILE="$LOG_ROOT/.dispatch-$RUN_ID.pid"
RENDERED_PROMPT="$LOG_ROOT/.dispatch-$RUN_ID.prompt"
cp -- "$PROMPT_FILE" "$BRIEF_FILE"

{
  cat <<'EOF'
## Code graph access

This Codex session uses GitNexus CLI only for code-graph queries.
When code graph evidence helps, use the GitNexus CLI with an explicit `--repo`
pointing at the indexed main checkout, following `docs/agents/gitnexus.md`.
EOF
  # "The indexed main checkout" alone let owners pick the maintainer's interactive
  # checkout (2026-09-30, twice); name the one path this run may query.
  printf 'The indexed main checkout for this run is `%s`: pass `--repo %s` and name no other checkout.\n\n' \
    "$INDEX_ROOT" "$INDEX_ROOT"
  cat <<'EOF'
## Required incremental landing

Finish and publish each independently complete unit before beginning the next.
For every unit, run focused verification, commit it, push or update its PR, and
leave the relevant GitHub issue or PR record. Do not batch a long session into
one final unpublished delivery. If blocked, publish completed work and blocking
evidence before stopping.

## Operator brief

EOF
  cat "$BRIEF_FILE"
} > "$RENDERED_PROMPT"

printf 'hand-dispatch started_at=%s kind=%s model=%s effort=%s access=%s worktree=%s branch=%s\n' \
  "$STAMP" "$KIND" "$MODEL" "$EFFORT" "$ACCESS" "$WORKTREE" "$BRANCH" > "$PENDING_LOG"

# Persist replay intent before creating a child. A reboot in the launch gap
# must still leave brief/model/effort/access/worktree/branch together. The detached
# session leader later atomically adds its PID/start identity before exec.
MANIFEST_TMP="$MANIFEST_FILE.tmp"
if ! jq -n \
  --arg id "$RUN_ID" --arg started_at "$STAMP" --arg status launching \
  --arg kind "$KIND" --arg model "$MODEL" --arg effort "$EFFORT" \
  --arg policy_role "$ROLE" --arg policy_step "$ROLE" --arg policy_identity "$IDENTITY" \
  --arg budget_reservation_id "$DISPATCH_BUDGET_ID" --arg admission_tier "$ADMISSION_TIER" \
  --arg access "$ACCESS" \
  --arg worktree "$WORKTREE" --arg branch "$BRANCH" --arg brief_file "$BRIEF_FILE" \
  --arg unit_name "$OWNER_UNIT" \
  '{id: $id, started_at: $started_at, status: $status, kind: $kind, model: $model, effort: $effort, model_policy: {role: $policy_role, step: $policy_step, identity: $policy_identity}, admission_tier:$admission_tier, codex_budget_reservation_id: $budget_reservation_id, access: $access, worktree: $worktree, branch: $branch, brief_file: $brief_file} + (if $unit_name == "" then {} else {unit_name:$unit_name, execution_mode:"systemd"} end)' \
  > "$MANIFEST_TMP"; then
  die "could not write durable dispatch intent; brief=$BRIEF_FILE"
fi
mv -- "$MANIFEST_TMP" "$MANIFEST_FILE"

if [ -n "$OWNER_UNIT" ]; then
  OWNER_RUNTIME_MAX_SECONDS="${ZF_NODE_OWNER_RUNTIME_MAX_SECONDS:-3600}"
  [[ "$OWNER_RUNTIME_MAX_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid node owner runtime budget"
  SYSTEMD_ARGS=(
    --user --unit "$OWNER_UNIT" --collect --no-block --quiet
    -p "WorkingDirectory=$WORKTREE"
    -p "RuntimeMaxSec=$OWNER_RUNTIME_MAX_SECONDS"
    -p "ExecStop=$SCRIPT_DIR/owner-stop-request.sh $MANIFEST_FILE $PENDING_LOG $OWNER_UNIT"
    -p "EnvironmentFile=-$AGENT_HOME/env"
    -E HOME -E PATH
  )
  for env_name in CODEX_HOME http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY NODE_USE_ENV_PROXY; do
    if [ -n "${!env_name:-}" ]; then SYSTEMD_ARGS+=(-E "$env_name"); fi
  done
  if [ -n "${ZF_NODE_OWNER_REPORT_FILE:-}" ]; then
    SYSTEMD_ARGS+=(-E "ZF_NODE_OWNER_REPORT_FILE=$ZF_NODE_OWNER_REPORT_FILE")
  fi
  SYSTEMD_ARGS+=(-- "$SCRIPT_DIR/dispatch-codex.sh" --owner-session \
    "$RENDERED_PROMPT" "$PID_FILE" "$MANIFEST_FILE" "$PENDING_LOG" "$LOG_ROOT" \
    "$WORKTREE" "$KIND" "$MODEL" "$EFFORT" "$ACCESS" "$OWNER_UNIT" \
    "$NODE_OWNER_BUDGET_ID" node-auto-owner)
  set +e
  SYSTEMD_OUTPUT="$(systemd-run "${SYSTEMD_ARGS[@]}" 2>&1)"
  SYSTEMD_STATUS=$?
  set -e
  if [ "$SYSTEMD_STATUS" -ne 0 ]; then
    REASON="$(dispatch_redact_line "$(tail -n 1 <<< "$SYSTEMD_OUTPUT")")"
    [ -n "$REASON" ] || REASON="systemd-run exited with status $SYSTEMD_STATUS"
    dispatch_jq_reason "$REASON" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.status = "dispatch-failed" | .exit_reason = $reason | .finished_at = $now | .updated_at = $now' \
      "$MANIFEST_FILE" > "$MANIFEST_TMP" && mv -- "$MANIFEST_TMP" "$MANIFEST_FILE"
    printf '%s dispatch-failed reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REASON" >> "$PENDING_LOG"
    printf '%s: dispatch-failed reason=%s unit=%s record=%s\n' \
      "$SCRIPT_NAME" "$REASON" "$OWNER_UNIT" "$MANIFEST_FILE" >&2
    codex_budget_release "${NODE_OWNER_BUDGET_ID:-}" || true
    exit 1
  fi

  for ((attempt = 0; attempt < VERIFY_ATTEMPTS; attempt++)); do
    [ -s "$PID_FILE" ] && break
    if [ "$(jq -r '.status // empty' "$MANIFEST_FILE" 2>/dev/null || true)" = dispatch-failed ]; then break; fi
    sleep "$VERIFY_DELAY_SECONDS"
  done
  LOG_FILE="$(jq -r '.log_file // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
  if [ "$(jq -r '.status // empty' "$MANIFEST_FILE" 2>/dev/null || true)" = dispatch-failed ]; then
    REASON="$(jq -r '.exit_reason // "systemd owner unit failed before session record"' "$MANIFEST_FILE")"
    codex_budget_release "${NODE_OWNER_BUDGET_ID:-}" || true
    printf '%s: dispatch-failed reason=%s unit=%s log=%s record=%s\n' \
      "$SCRIPT_NAME" "$REASON" "$OWNER_UNIT" "$PENDING_LOG" "$MANIFEST_FILE" >&2
    exit 1
  fi
  if [ ! -s "$PID_FILE" ]; then
    UNIT_REASON="$(systemctl --user show "$OWNER_UNIT" -p Result -p ExecMainStatus --value 2>/dev/null | tr '\n' ' ' || true)"
    REASON="owner unit exited before PID publication${UNIT_REASON:+ ($UNIT_REASON)}"
    codex_budget_release "${NODE_OWNER_BUDGET_ID:-}" || true
    dispatch_jq_reason "$REASON" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.status = "dispatch-failed" | .exit_reason = $reason | .finished_at = $now | .updated_at = $now' \
      "$MANIFEST_FILE" > "$MANIFEST_TMP" && mv -- "$MANIFEST_TMP" "$MANIFEST_FILE"
    printf '%s dispatch-failed reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REASON" >> "$PENDING_LOG"
    printf '%s: dispatch-failed reason=%s unit=%s log=%s record=%s\n' \
      "$SCRIPT_NAME" "$REASON" "$OWNER_UNIT" "$PENDING_LOG" "$MANIFEST_FILE" >&2
    exit 1
  fi
  read -r AGENT_PID < "$PID_FILE"
  case "$AGENT_PID" in ''|*[!0-9]*) die "owner unit published invalid PID: $AGENT_PID; record=$MANIFEST_FILE" ;; esac
  RECORDED_PID="$(jq -r '.pid // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
  RECORDED_TICKS="$(jq -r '.pid_start_ticks // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
  if [ "$RECORDED_PID" != "$AGENT_PID" ] || [ -z "$RECORDED_TICKS" ] || [ ! -f "$LOG_FILE" ]; then
    die "owner unit did not publish its durable PID record; unit=$OWNER_UNIT record=$MANIFEST_FILE"
  fi
  PENDING_LOG=""
  DISPATCH_BUDGET_HANDED_OFF=1
  printf '%s: started pid=%s unit=%s kind=%s model=%s effort=%s access=%s log=%s record=%s\n' \
    "$SCRIPT_NAME" "$AGENT_PID" "$OWNER_UNIT" "$KIND" "$MODEL" "$EFFORT" "$ACCESS" "$LOG_FILE" "$MANIFEST_FILE"
  exit 0
fi

ZF_REPO_DIR="$WORKTREE" REPO_DIR="$WORKTREE" setsid --fork \
  "$SCRIPT_DIR/dispatch-codex.sh" --owner-session \
  "$RENDERED_PROMPT" "$PID_FILE" "$MANIFEST_FILE" "$PENDING_LOG" "$LOG_ROOT" \
  "$WORKTREE" "$KIND" "$MODEL" "$EFFORT" "$ACCESS" "" \
  "$DISPATCH_BUDGET_ID" hand-dispatch </dev/null >> "$PENDING_LOG" 2>&1 &
LAUNCHER_PID=$!

for ((attempt = 0; attempt < VERIFY_ATTEMPTS; attempt++)); do
  [ -s "$PID_FILE" ] && break
  sleep "$VERIFY_DELAY_SECONDS"
done
[ -s "$PID_FILE" ] || die "detachment verification failed: agent never published a PID; log=$PENDING_LOG"
read -r AGENT_PID < "$PID_FILE"
case "$AGENT_PID" in
  ''|*[!0-9]*) die "detachment verification failed: invalid agent PID; log=$PENDING_LOG" ;;
esac

VERIFIED=0
OBSERVED_PPID=""
OBSERVED_SID=""
for ((attempt = 0; attempt < VERIFY_ATTEMPTS; attempt++)); do
  PROCESS_INFO="$(ps -o pid= -o ppid= -o sid= -p "$AGENT_PID" 2>/dev/null || true)"
  OBSERVED_PID=""
  OBSERVED_PPID=""
  OBSERVED_SID=""
  read -r OBSERVED_PID OBSERVED_PPID OBSERVED_SID _ <<< "$PROCESS_INFO" || true
  if [ "$OBSERVED_PID" = "$AGENT_PID" ] &&
     [ "$OBSERVED_SID" = "$AGENT_PID" ] &&
     [ -n "$OBSERVED_PPID" ] &&
     [ "$OBSERVED_PPID" != "$$" ] &&
     [ "$OBSERVED_PPID" != "$LAUNCHER_PID" ]; then
    VERIFIED=1
    break
  fi
  sleep "$VERIFY_DELAY_SECONDS"
done

if [ "$VERIFIED" -ne 1 ]; then
  kill "$AGENT_PID" 2>/dev/null || true
  die "detachment verification failed: pid=$AGENT_PID sid=${OBSERVED_SID:-missing} parent=${OBSERVED_PPID:-missing}; agent terminated; log=$PENDING_LOG"
fi

PID_START_TICKS="$(awk '{print $22}' "/proc/$AGENT_PID/stat" 2>/dev/null || true)"
case "$PID_START_TICKS" in
  ''|*[!0-9]*)
    kill "$AGENT_PID" 2>/dev/null || true
    die "detachment verification failed: cannot record process start identity; log=$PENDING_LOG"
    ;;
esac

LOG_FILE="$(jq -r '.log_file // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
RECORDED_PID="$(jq -r '.pid // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
RECORDED_TICKS="$(jq -r '.pid_start_ticks // empty' "$MANIFEST_FILE" 2>/dev/null || true)"
if [ "$(jq -r '.status // empty' "$MANIFEST_FILE" 2>/dev/null || true)" != running ] \
  || [ "$RECORDED_PID" != "$AGENT_PID" ] \
  || [ "$RECORDED_TICKS" != "$PID_START_TICKS" ] \
  || [ ! -f "$LOG_FILE" ]; then
  kill "$AGENT_PID" 2>/dev/null || true
  die "detachment verification failed: session did not publish its durable PID record; agent terminated; brief=$BRIEF_FILE"
fi
PENDING_LOG=""
DISPATCH_BUDGET_HANDED_OFF=1

printf '%s: started pid=%s sid=%s reparented-parent=%s kind=%s model=%s effort=%s access=%s log=%s record=%s\n' \
  "$SCRIPT_NAME" "$AGENT_PID" "$OBSERVED_SID" "$OBSERVED_PPID" \
  "$KIND" "$MODEL" "$EFFORT" "$ACCESS" "$LOG_FILE" "$MANIFEST_FILE"
