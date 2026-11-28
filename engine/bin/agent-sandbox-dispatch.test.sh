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

grep -Fq 'agent-sandbox-run' "$script_dir/luna"
grep -Fq 'agent-sandbox-run' "$script_dir/zc"
grep -Fq 'ZF_AGENT_ACCESS=write' "$script_dir/worker"
grep -Fq 'agent-sandbox-run' "$script_dir/../mac-autopilot/scheduler.d/worker-scope.sh"
grep -Fq 'WORKER_AGENT_PROVIDER="$provider"' "$script_dir/../mac-autopilot/scheduler.d/dispatch.sh"
grep -Fq 'bin/agent-sandbox-run' "$script_dir/worker-remote.py"
grep -Fq 'codex read "$cwd"' "$script_dir/../lib.d/model-calls.sh"
grep -Fq 'codex write "$cwd"' "$script_dir/../lib.d/model-calls.sh"
grep -Fq 'zcode read "$cwd"' "$script_dir/../lib.d/model-calls.sh"
grep -Fq 'claude read "$cwd"' "$script_dir/../lib.d/triage-claude.sh"
grep -Fq 'agent-sandbox-run' "$script_dir/../eval/stage-call.sh"
grep -Fq 'agent-sandbox-run' "$script_dir/../night/dispatch.sh"
grep -Fq 'agent-sandbox-run' "$script_dir/../dispatch-codex.sh"
grep -Fq 'WORKER_AGENT_PROVIDER=codex' "$script_dir/../mac-autopilot/scheduler.d/supervisor-arbiter.sh"
grep -Fq 'WORKER_AGENT_CAPTURE_OUTPUT' "$script_dir/../mac-autopilot/scheduler.d/worker-scope.sh"
grep -Fq 'agent-sandbox-run' "$script_dir/../lib.d/codex-budget.sh"

printf '%s\n' 'agent-sandbox-dispatch.test.sh: pass'
