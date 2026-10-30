#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ "$ZF_AGENT_TEST_MODE" == 1 ]]
[[ "$ZF_AGENT_TEST_ROOT" == "$test_env_root" ]]

guard_sentinel="$(mktemp -d /tmp/zenoforge-agent-write-guard-XXXXXX)"
trap 'rm -rf -- "$guard_sentinel" "$test_env_root"' EXIT

source "$SCRIPT_DIR/lib.sh"
record_env_fault env:test-write-guard triage 910201 'isolated test write'
[[ -s "$AGENT_HOME/env-faults/env:test-write-guard.log" ]]

if guard_output="$(AGENT_HOME="$AGENT_HOME" bash -c '
  source "$1/lib.sh"
  AGENT_HOME="$2/agent"
  ENV_FAULT_DIR="$AGENT_HOME/env-faults"
  record_env_fault env:test-write-guard triage 910202 "must refuse sentinel"
' _ "$SCRIPT_DIR" "$guard_sentinel" 2>&1)"; then
  printf 'write guard accepted a test write to fallback home\n' >&2
  exit 1
fi
[[ "$guard_output" == *'test write guard: refusing write outside isolated root'* ]]
[[ ! -e "$guard_sentinel/agent" ]]

if inbox_output="$(AGENT_HOME="$AGENT_HOME" bash -c '
  source "$1/lib.sh"
  AGENT_HOME="$2/agent"
  supervisor_inbox_append test-write-guard "must refuse sentinel"
' _ "$SCRIPT_DIR" "$guard_sentinel" 2>&1)"; then
  printf 'supervisor inbox writer accepted test write to fallback home\n' >&2
  exit 1
fi
[[ "$inbox_output" == *'supervisor_inbox_append: test write guard: refusing write outside isolated root'* ]]
[[ ! -e "$guard_sentinel/agent" ]]

if once_output="$(AGENT_HOME="$AGENT_HOME" bash -c '
  source "$1/lib.sh"
  AGENT_HOME="$2/agent"
  supervisor_inbox_append_once test-key "must refuse sentinel"
' _ "$SCRIPT_DIR" "$guard_sentinel" 2>&1)"; then
  printf 'one-time supervisor inbox writer accepted test write to fallback home\n' >&2
  exit 1
fi
[[ "$once_output" == *'supervisor_inbox_append_once: test write guard: refusing write outside isolated root'* ]]
[[ ! -e "$guard_sentinel/agent" ]]

if notify_output="$(AGENT_HOME="$AGENT_HOME" bash -c '
  source "$1/lib.sh"
  source "$1/notify.sh"
  AGENT_HOME="$2/agent"
  NOTIFY_LOG_FILE="$2/notify.log"
  notify_log_send 910203 "test write guard" failed sentinel
' _ "$SCRIPT_DIR" "$guard_sentinel" 2>&1)"; then
  printf 'notify writer accepted test write to fallback home\n' >&2
  exit 1
fi
[[ "$notify_output" == *'notify: test write guard: refusing write outside isolated root'* ]]
[[ ! -e "$guard_sentinel/agent" && ! -e "$guard_sentinel/notify.log" ]]

# The fallback home models the live one, which always has a runtime checkout.
mkdir -p "$guard_sentinel/.zenoforge/checkout"
if unmarked_output="$(HOME="$guard_sentinel" bash -c '
  source "$1/lib.sh"
  unset ZF_AGENT_TEST_MODE ZF_AGENT_TEST_ROOT
  AGENT_HOME="$HOME/.zenoforge"
  ENV_FAULT_DIR="$AGENT_HOME/env-faults"
  record_env_fault env:test-write-guard triage 910204 "must refuse unmarked fallback"
' _ "$SCRIPT_DIR" 2>&1)"; then
  printf 'unmarked worktree writer accepted fallback home\n' >&2
  exit 1
fi
[[ "$unmarked_output" == *'record_env_fault: test write guard: refusing write outside runtime checkout'* ]]
[[ ! -e "$guard_sentinel/.zenoforge/env-faults" ]]

# An engine installed by the zenoforge CLI sits in $AGENT_HOME/engine/<version>, outside the checkout it serves.
mkdir -p "$guard_sentinel/.zenoforge/engine/0.1.0"
copy_agent_library "$guard_sentinel/.zenoforge/engine/0.1.0"
if ! cli_output="$(HOME="$guard_sentinel" env -u ZF_AGENT_TEST_MODE -u ZF_AGENT_TEST_ROOT bash -c '
  AGENT_HOME="$HOME/.zenoforge"
  source "$1/lib.sh" && echo loaded
' _ "$guard_sentinel/.zenoforge/engine/0.1.0" 2>&1)"; then
  printf 'write guard refused an engine installed under the agent home: %s\n' "$cli_output" >&2
  exit 1
fi
[[ "$cli_output" == *loaded* ]]

if init_output="$(HOME="$HOME" ZF_HOME="$guard_sentinel/agent" bash -c '
  unset AGENT_HOME
  source "$1/lib.sh"
' _ "$SCRIPT_DIR" 2>&1)"; then
  printf 'lib.sh accepted a test fallback to unisolated ZF_HOME\n' >&2
  exit 1
fi
[[ "$init_output" == *'lib.sh initialization: test write guard: refusing write outside isolated root'* ]]
[[ ! -e "$guard_sentinel/agent" ]]

# A home without a runtime checkout (CI, mktemp preflights) is not live state: lib.sh loads from a worktree.
scratch_home="$(mktemp -d "$guard_sentinel/scratch-XXXXXX")"
if ! scratch_output="$(env -u ZF_AGENT_TEST_MODE -u ZF_AGENT_TEST_ROOT -u ZF_HOME \
  AGENT_HOME="$scratch_home" bash -c 'source "$1/lib.sh" && echo loaded' _ "$SCRIPT_DIR" 2>&1)"; then
  printf 'lib.sh refused an agent home without a runtime checkout: %s\n' "$scratch_output" >&2
  exit 1
fi
[[ "$scratch_output" == *loaded* ]]

echo 'test-write-guard.test.sh: PASS'
