#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
runner="$script_dir/agent-sandbox-run"
repo="$test_env_root/agent-sandbox-dispatch/repo"
mkdir -p "$repo"

actual="$(AGENT_SANDBOX_TEST_VALUE=visible "$runner" codex read "$repo" "" -- \
  sh -c 'printf "%s\n%s" "$PWD" "$AGENT_SANDBOX_TEST_VALUE"')"
[[ "$actual" == "$repo"$'\n'visible ]] || {
  printf '%s\n' 'agent-sandbox-dispatch.test.sh: command did not inherit the repo directory and caller environment' >&2
  exit 1
}

status=0
"$runner" codex read "$repo" "" true >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]] || {
  printf 'agent-sandbox-dispatch.test.sh: missing separator exited %s instead of 64\n' "$status" >&2
  exit 1
}

printf '%s\n' 'agent-sandbox-dispatch.test.sh: pass'
