#!/usr/bin/env bash
# Shared isolated fixture and assertions for the library suites.
set -euo pipefail
[[ -n "${ZF_AGENT_TEST_MODE:-}" ]] || { echo 'test-lib-helpers: the suite must source test-env.sh first' >&2; exit 2; }
LIB_TEST_AGENT_HOME="$AGENT_HOME"
INBOX_HELPER_HOME="$(mktemp -d)"
LIB_TEST_TMP_DIRS=()
trap 'lib_test_status=$?; if [ -n "${LIB_TEST_STDERR_LOG:-}" ] && [ -f "$LIB_TEST_STDERR_LOG" ] && [ "$lib_test_status" -ne 0 ]; then cat "$LIB_TEST_STDERR_LOG" >&4; fi; rm -f -- "${LIB_TEST_STDERR_LOG:-}"; rm -rf -- "$LIB_TEST_AGENT_HOME" "$INBOX_HELPER_HOME" "${LIB_TEST_TMP_DIRS[@]}"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

# Default-value assertions must ignore operator runtime overrides.
while IFS= read -r model_variable; do
  if [[ "$model_variable" == AGENT_MODEL* ]]; then unset "$model_variable"; fi
done < <(compgen -e)

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
policy_file_for_home() {
  AGENT_HOME="$1" MODEL_POLICY_SOURCE_CHECK_ONLY=1 MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    unset MODEL_POLICY_FILE MODEL_POLICY_DEFAULT
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    printf "%s\n" "$MODEL_POLICY_FILE"
  '
}
POLICY_WORK_MODEL="$(jq -r '.roles.work.model' "$MODEL_POLICY_DEFAULT")"
POLICY_WORK_EFFORT="$(jq -r '.roles.work.effort' "$MODEL_POLICY_DEFAULT")"
POLICY_WORK_TIER="$(jq -r '.roles.work.service_tier // empty' "$MODEL_POLICY_DEFAULT")"
POLICY_PRODUCTION_MODEL="$(jq -r '.roles.production.model' "$MODEL_POLICY_DEFAULT")"
POLICY_PRODUCTION_EFFORT="$(jq -r '.roles.production.effort' "$MODEL_POLICY_DEFAULT")"
POLICY_ADVISOR_IDENTITY="$MODEL_POLICY_TEST_ADVISOR_IDENTITY"
printf -v POLICY_WORK_IDENTITY 'codex:%s:%s' "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT"
printf -v POLICY_PRODUCTION_IDENTITY 'codex:%s:%s' "$POLICY_PRODUCTION_MODEL" "$POLICY_PRODUCTION_EFFORT"
export POLICY_WORK_MODEL POLICY_WORK_EFFORT POLICY_WORK_IDENTITY POLICY_PRODUCTION_IDENTITY POLICY_ADVISOR_IDENTITY POLICY_WORK_TIER

FAILED=0
ASSERTIONS=0

# Passing assertions only bump the counter; failures print "not ok - <case>".
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }

# One-line green output (#4480): ordinary stdout (functions under test echoing
# as they run) is discarded; stderr goes to a file that is dumped only when the
# run fails, so failure diagnostics survive. fd 3 is the original stdout
# (assertion failures, summary); fd 4 is the original stderr. Captures inside
# tests are unaffected.
LIB_TEST_STDERR_LOG="$(mktemp)"
exec 3>&1 4>&2 >/dev/null 2>"$LIB_TEST_STDERR_LOG"

# Single-case switches exit through here so they print the same one-line summary.
lib_case_exit() {
  if [ "$FAILED" -eq 1 ]; then echo "FAILED" >&3; else echo "ALL PASS ($ASSERTIONS assertions)" >&3; fi
  exit "$FAILED"
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    ok "$desc"
  else
    echo "not ok - $desc" >&3
    FAILED=1
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@"; then
    ok "$desc"
  else
    echo "not ok - $desc" >&3
    FAILED=1
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])" >&3
    FAILED=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
  else
    echo "not ok - $desc (expected to find [$needle])" >&3
    FAILED=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$desc"
  else
    echo "not ok - $desc (did not expect [$needle])" >&3
    FAILED=1
  fi
}

