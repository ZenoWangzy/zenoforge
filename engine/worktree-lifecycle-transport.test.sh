#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
outside="$test_env_root/nonrepo"
mkdir -p "$outside"
output="$(cd "$outside" && ZF_ENGINE_DIR="$root/engine" AGENT_HOME="$AGENT_HOME" bash -c 'source "$ZF_ENGINE_DIR/worktree-lifecycle.sh"; printf source-ok' 2>&1)" || {
  printf '%s\n' "$output" >&2
  exit 1
}
[[ "$output" == source-ok ]] || { printf '%s\n' "$output" >&2; exit 1; }
echo 'ok - engine module sourcing outside git does not probe a repository'
