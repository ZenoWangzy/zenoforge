#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

node "$SCRIPT_DIR/scheduler-gh-timeout-safety.mjs"

fixture="$TMP_DIR/bad-scheduler-lib.sh"
printf 'call_gh() { command %s pr list; }\n' gh > "$fixture"
output="$(node "$SCRIPT_DIR/scheduler-gh-timeout-safety.mjs" "$fixture" 2>&1)" && {
  echo 'scheduler-gh-timeout-safety.test.sh: unbounded command unexpectedly passed' >&2
  exit 1
}
grep -Fq 'bad-scheduler-lib.sh:1: command gh bypasses the timed wrapper' <<<"$output" || {
  printf '%s\n' "$output" >&2
  echo 'scheduler-gh-timeout-safety.test.sh: checker did not report the planted bypass' >&2
  exit 1
}
echo 'scheduler-gh-timeout-safety.test.sh: PASS'
