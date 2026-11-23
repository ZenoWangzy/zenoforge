#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_CONTENT="$(cat "$SCRIPT_DIR/prompts/triage.md")"
PROMPT_ONE_LINE="$(printf '%s' "$PROMPT_CONTENT" | tr '\n' ' ' | tr -s ' ')"

assert_contains() {
  local label="$1" needle="$2"
  if [[ "$PROMPT_ONE_LINE" == *"$needle"* ]]; then
    echo "ok - $label"
  else
    echo "not ok - $label"
    exit 1
  fi
}

assert_not_contains() {
  local label="$1" needle="$2"
  if [[ "$PROMPT_CONTENT" != *"$needle"* ]]; then
    echo "ok - $label"
  else
    echo "not ok - $label"
    exit 1
  fi
}

assert_not_contains "prompt omits the legacy readiness state" 'ready-for-human'
assert_not_contains "prompt omits the legacy ownership state" 'needs-owner'
assert_contains "founder-authored issues choose defaults and continue" 'write them into `notes_md` as decisions with their reasoning, and return `ready-for-agent`'
assert_contains "unresolved L2 continues with impact evidence unavailable" 'record unresolved L2 as `ready-for-agent` and say plainly in `brief_md` that the impact evidence is unavailable'
assert_contains "scope calls are recorded for the implementer" 'record the scope call for the implementer in `brief_md`, and return `ready-for-agent`'
assert_contains "advisor_reason is honored on ready-for-agent" 'with `none` (or a missing field) a `ready-for-agent` verdict proceeds through the wrapper'
assert_contains "unknown impact cannot admit or reject L2" 'Do not admit or reject based on it'
jq -e '.properties.state.enum == ["needs-info", "ready-for-agent", "duplicate", "finish-first", "awaiting-release", "wontfix"]' \
  "$SCRIPT_DIR/prompts/triage.schema.json" >/dev/null
