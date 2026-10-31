#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh"
REPO_DIR_INPUT="${ZF_REPO_DIR:-$SCRIPT_DIR/..}"
REPO_DIR="$(cd -- "$REPO_DIR_INPUT" 2>/dev/null && pwd -P)" || { echo "ERROR check-rulings: repo directory unavailable: $REPO_DIR_INPUT" >&2; exit 2; }
SCRIPT_DIR="$ZF_ENGINE_DIR"
unset ZF_CHECK_RULINGS_POLICY_SOURCE_SCAN_VERIFIED
AGENT_RULINGS_MODE="${AGENT_RULINGS_MODE:-static}"
[[ "$AGENT_RULINGS_MODE" == static || "$AGENT_RULINGS_MODE" == source ]] || {
  printf 'ERROR check-rulings: invalid AGENT_RULINGS_MODE: %s\n' "$AGENT_RULINGS_MODE" >&2
  exit 2
}
codex_path_root="${CODEX_HOME:-${HOME:?HOME is not set}/.codex}"
PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:$codex_path_root/packages/standalone/current/codex-path"
export PATH AGENT_HOME REPO_DIR ZF_REPO_DIR="$REPO_DIR"
cd -- "$REPO_DIR" || { echo "ERROR check-rulings: cannot enter repo: $REPO_DIR" >&2; exit 2; }

check_model_policy_source() {
  local MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCRIPT_DIR/lib.sh" >/dev/null || return 1
  model_policy_scan_sources || {
    echo 'ERROR check-rulings: a forbidden model name appears in pipeline sources' >&2
    return 1
  }
}

# #4655：统一调度策略与单元状态机（state/scheduling-policy.json）的自洽、
# 源码封闭与（有 live 台账时）台账封闭检查；live ledger 不存在（CI/隔离 fixture）则跳过台账部分。
check_scheduling_policy() {
  command -v node >/dev/null 2>&1 || { echo 'ERROR check-rulings: node is required to verify scheduling-policy' >&2; return 1; }
  node "$SCRIPT_DIR/scheduling-policy.mjs"
}

if [[ "$AGENT_RULINGS_MODE" == source && "${1:-}" == --sources-only ]]; then
  (($# == 1)) || { echo 'ERROR check-rulings: --sources-only cannot be combined with suite paths' >&2; exit 2; }
  check_model_policy_source || exit 2
  check_scheduling_policy || exit 2
  echo 'check-rulings: source checks passed'
  exit 0
fi

[[ -r "$SCRIPT_DIR/test-env.sh" ]] || { echo "ERROR check-rulings: shared test environment helper is missing" >&2; exit 2; }
if [[ "$AGENT_RULINGS_MODE" == source && $# -gt 0 ]]; then
  test_files=("$@")
  for test_file in "${test_files[@]}"; do
    [[ "$test_file" == "$SCRIPT_DIR/"*.test.sh && -f "$test_file" ]] || {
      printf 'ERROR check-rulings: invalid source suite path: %s\n' "$test_file" >&2
      exit 2
    }
  done
else
  (($# == 0)) || { echo 'ERROR check-rulings: arguments are only valid for source suite checks' >&2; exit 2; }
  mapfile -d '' -t test_files < <(find "$SCRIPT_DIR" -type f -name '*.test.sh' -print0)
fi
for test_file in "${test_files[@]}"; do
  if [[ ! -s "$test_file" ]]; then
    printf 'ERROR check-rulings: empty test suite: %s\n' "${test_file#"$SCRIPT_DIR"/}" >&2
    exit 2
  fi
done
"$BASH" "$SCRIPT_DIR/test-bootstrap-check.sh" "${test_files[@]}" || exit 2
# rg is not on the systemd or CI PATH: `rg ... || true` there matched nothing and its assertion passed vacuously
# (git-fetch-bounded, lib.test.sh), or the suite failed only at landing (hold.test.sh, 2026-09-30).
rg_suites="$(grep -lE '(^|[;&|({[:space:]]|\$\()rg[[:space:]]+-' "${test_files[@]}" | grep -v '/check-rulings\.test\.sh$' || true)"
if [ -n "$rg_suites" ]; then
  printf 'test suite calls rg: %s\n' $rg_suites >&2
  echo 'ERROR check-rulings: test suites must use grep; rg is not on the landing or CI PATH' >&2
  exit 2
fi

check_model_policy_source || exit 2
check_scheduling_policy || exit 2

# Every trunk push validates the durable problem register: a new record without
# root cause evidence or classic-problem research is refused here (issue #4657).
if [[ ! -f "$SCRIPT_DIR/lesson-guard-schema.mjs" ]]; then
  echo 'ERROR check-rulings: lesson-guard-schema.mjs is missing' >&2
  exit 2
fi
node "$SCRIPT_DIR/lesson-guard-schema.mjs" "$REPO_DIR" || exit 2
printf 'check-rulings: %s checks passed\n' "$AGENT_RULINGS_MODE"
