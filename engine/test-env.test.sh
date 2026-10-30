#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT

case "$TMPDIR" in
  /tmp/zenoforge-agent-suite-*/zenoforge-agent-test-*|"$test_host_home"/.cache/zenoforge-agent-test/zenoforge-agent-test-*) ;;
  *) exit 1 ;;
esac
[[ "$HOME" == "$TMPDIR/home" ]]
[[ "$AGENT_HOME" == "$TMPDIR/agent" ]]
[[ "$ZF_AGENT_TEST_MODE" == 1 ]]
[[ "$ZF_AGENT_TEST_ROOT" == "$test_env_root" ]]
[[ "$(jq -n 1)" == 1 ]]
if [[ "$(command -v codex || true)" != "$test_env_root/bin/codex" ]]; then
  echo 'test-env: codex guard is not first on PATH' >&2
  exit 1
fi
codex_guard_output="$test_env_root/codex-guard.log"
if codex exec --sandbox read-only 2>"$codex_guard_output"; then
  echo 'test-env: codex guard returned success' >&2
  exit 1
fi
if ! grep -Fqx 'real codex call in test: exec --sandbox read-only' "$codex_guard_output"; then
  echo 'test-env: codex guard did not fail with its diagnostic' >&2
  exit 1
fi

while IFS= read -r name; do
  case "$name" in
    AGENT_HOME|AGENT_EXECUTION_MIN_MEM_MB|AGENT_EXECUTION_MAX_LOAD|ZF_EXECUTION_MODULE_DIR|ZF_AGENT_TEST_MODE|ZF_AGENT_TEST_ROOT|ZF_REPO) ;;
    AGENT_*|ZF_*)
      printf 'test environment leaked %s\n' "$name" >&2
      exit 1
      ;;
  esac
done < <(compgen -e)

hostile_tmp="$MODEL_POLICY_TEST_REPO"
hostile_test_root="$(HOME="$test_host_home" TMPDIR="$hostile_tmp" bash -c '
  set -euo pipefail
  host_home="$HOME"
  source "$1"
  [[ "$test_env_root" == "$host_home"/.cache/zenoforge-agent-test/zenoforge-agent-test-* ]]
  trap "rm -rf -- \"$test_env_root\"" EXIT
  printf "%s" "$test_env_root"
' _ "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh")"
[[ "$hostile_test_root" == "$test_host_home"/.cache/zenoforge-agent-test/zenoforge-agent-test-* ]]
[[ "$hostile_test_root" != "$hostile_tmp"/zenoforge-agent-test-* ]]

# A repo fixture nested under the runner temp is not the runner's scratch root.
nested_hostile_tmp="$TMPDIR/nested-suite/repo"
mkdir -p "$nested_hostile_tmp"
nested_hostile_root="$(HOME="$test_host_home" TMPDIR="$nested_hostile_tmp" bash -c '
  set -euo pipefail
  host_home="$HOME"
  source "$1"
  [[ "$test_env_root" == "$host_home"/.cache/zenoforge-agent-test/zenoforge-agent-test-* ]]
  trap "rm -rf -- \"$test_env_root\"" EXIT
  printf "%s" "$test_env_root"
' _ "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh")"
[[ "$nested_hostile_root" == "$test_host_home"/.cache/zenoforge-agent-test/zenoforge-agent-test-* ]]
[[ "$nested_hostile_root" != "$nested_hostile_tmp"/zenoforge-agent-test-* ]]

# A queued landing runs preflight with these set (land-queue.sh); they must not reach tests.
if ! PLAN_PACKAGE=leaked-package REPO_DIR=/leaked/repo bash -c '
  source "$1"
  [[ ! -v PLAN_PACKAGE && ! -v REPO_DIR ]]
' _ "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"; then
  echo 'test environment leaked PLAN_PACKAGE or REPO_DIR' >&2
  exit 1
fi

# Shared admission state must resolve inside the tested checkout, never the host.
if ! HAND_PRIORITY_STATE=/live/hand-priority.json bash -c '
  source "$1"
  [[ ! -v HAND_PRIORITY_STATE ]]
' _ "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"; then
  echo 'test environment leaked HAND_PRIORITY_STATE' >&2
  exit 1
fi

echo 'test-env.test.sh: PASS'
