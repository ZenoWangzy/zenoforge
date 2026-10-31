#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != --prod-anomaly-only ]]; then
  printf 'usage: %s --prod-anomaly-only\n' "$0" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"
night_config="$(zf_config_file night.json || true)"
if [[ -z "$night_config" ]] || ! jq -e '.jobs.production_errors.enabled == true' "$night_config" >/dev/null 2>&1; then
  echo 'skip: production anomaly monitor is not configured'
  exit 0
fi

H="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
NIGHT="${ZF_NIGHT_DIR:-$H/night}"
REPO_DIR="$ZF_REPO_DIR"
WORKTREE_ROOT="${ZF_WORKTREE_ROOT:-$HOME/worktrees}"
export AGENT_HOME="$H"
export MODEL_POLICY_READ_ONLY=1

model_policy_source_check_only_was_set="${MODEL_POLICY_SOURCE_CHECK_ONLY+x}"
model_policy_source_check_only_before="${MODEL_POLICY_SOURCE_CHECK_ONLY-}"
MODEL_POLICY_SOURCE_CHECK_ONLY=1
source "$script_dir/../lib.sh"
if [[ "$model_policy_source_check_only_was_set" == x ]]; then
  MODEL_POLICY_SOURCE_CHECK_ONLY="$model_policy_source_check_only_before"
else
  unset MODEL_POLICY_SOURCE_CHECK_ONLY
fi
unset model_policy_source_check_only_was_set model_policy_source_check_only_before

agent_pipeline_write_guard production-health "$H" "$NIGHT" || exit 1
source "$script_dir/hand-agent-watchdog.sh"
source "$script_dir/hand-exit-handoff.sh"
source "$script_dir/node-health-rules.sh"
prod_errors_config_ready || {
  echo 'skip: production anomaly monitor settings are incomplete in night.json'
  exit 0
}

runtime_bin="$(codex_runtime_user_bin_dir)"
export PATH="$runtime_bin:${ZF_NPM_GLOBAL_BIN_DIR:-}:/usr/local/bin:/usr/bin:/bin"
mkdir -p -- "$NIGHT" || exit 1
prod_roadmap_cache_owned=0
if [[ -z "${ZF_OPEN_ISSUES_CACHE_FILE:-}" ]]; then
  ZF_OPEN_ISSUES_CACHE_FILE="$NIGHT/.open-issues-production-anomaly-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  ZF_ROADMAP_TREE_CACHE_FILE="$(roadmap_cache_path "$ZF_OPEN_ISSUES_CACHE_FILE")"
  export ZF_OPEN_ISSUES_CACHE_FILE ZF_ROADMAP_TREE_CACHE_FILE
  prod_roadmap_cache_owned=1
fi
exec 9>"$NIGHT/production-errors-monitor.lock"
flock -n 9 || exit 0
prod_state_file="$NIGHT/production-errors-seen-signatures.json"
prod_result="$(prod_errors_probe "$prod_state_file")"
flock -u 9
exec 9>&-
prod_verdict="$(jq -r '.verdict // "UNKNOWN"' <<< "$prod_result" 2>/dev/null || printf UNKNOWN)"
prod_detail="$(jq -r '.detail // "production log assessment failed"' <<< "$prod_result" 2>/dev/null || printf 'production log assessment failed')"
if health_prod_errors_route "$prod_result" "$prod_verdict" "$prod_detail" "$prod_state_file"; then
  prod_route_status=0
else
  prod_route_status=$?
fi
if [[ "$prod_roadmap_cache_owned" == 1 ]]; then
  rm -f -- "$ZF_ROADMAP_TREE_CACHE_FILE" "$ZF_ROADMAP_TREE_CACHE_FILE.placed" \
    "$ZF_ROADMAP_TREE_CACHE_FILE.linked" "$ZF_ROADMAP_TREE_CACHE_FILE.placed.lock"
fi
exit "$prod_route_status"
