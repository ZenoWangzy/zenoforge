#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
retired_paths=(
  engine/bin/agent-sandbox.py
  engine/bin/agent_sandbox_network.py
  engine/bin/agent_sandbox_state.py
  engine/bin/agent_sandbox_workspace.py
)

for path in "${retired_paths[@]}"; do
  if [[ -e "$repo/$path" ]]; then
    printf 'retired sandbox file returned: %s\n' "$path" >&2
    exit 1
  fi
done

if matches="$(git -C "$repo" grep -nE 'agent-sandbox\.py|ZF_PUSH_SOCKET' -- engine ':(exclude,glob)engine/**/*.test.*')"; then
  printf '%s\n' "$matches" >&2
  exit 1
else
  grep_status=$?
  [[ "$grep_status" -eq 1 ]] || exit "$grep_status"
fi

printf '%s\n' 'agent-sandbox.test.sh: pass'
