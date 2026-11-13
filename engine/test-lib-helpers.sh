#!/usr/bin/env bash
# Shared isolated fixture and assertions for the library suites.
set -euo pipefail
[[ -n "${ZF_AGENT_TEST_MODE:-}" ]] || { echo 'test-lib-helpers: the suite must source test-env.sh first' >&2; exit 2; }
# Cleanup is registered before setup so partial setup failures still remove the isolated home.
LIB_TEST_AGENT_HOME="$AGENT_HOME"
INBOX_HELPER_HOME="$AGENT_HOME"
LIB_TEST_TMP_DIRS=()
trap 'lib_test_status=$?; if [ -n "${LIB_TEST_STDERR_LOG:-}" ] && [ -f "$LIB_TEST_STDERR_LOG" ] && [ "$lib_test_status" -ne 0 ]; then cat "$LIB_TEST_STDERR_LOG" >&4; fi; rm -f -- "${LIB_TEST_STDERR_LOG:-}"; rm -rf -- "$LIB_TEST_AGENT_HOME" "$INBOX_HELPER_HOME" "${LIB_TEST_TMP_DIRS[@]}"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-test-setup.sh"
if [[ "${LIB_TEST_SETUP_DEFERRED:-0}" != 1 && "${LIB_TEST_SETUP_COMPLETE:-0}" != 1 ]]; then
  lib_test_setup "$SCRIPT_DIR"
  LIB_TEST_SETUP_COMPLETE=1
fi
policy_file_for_home() {
  AGENT_HOME="$1" MODEL_POLICY_SOURCE_CHECK_ONLY=1 MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    unset MODEL_POLICY_FILE MODEL_POLICY_DEFAULT
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    printf "%s\n" "$MODEL_POLICY_FILE"
  '
}

# Passing assertions only bump the counter; failures print "not ok - <case>".
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }

# One-line green output (#4480): ordinary stdout (functions under test echoing
# as they run) is discarded; stderr goes to a file that is dumped only when the
# run fails, so failure diagnostics survive. fd 3 is the original stdout
# (assertion failures, summary); fd 4 is the original stderr. Captures inside
# tests are unaffected.
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

