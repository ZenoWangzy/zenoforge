#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

node "$SCRIPT_DIR/jq-regex-safety.mjs"

fixture="$TMP_DIR/bad-jq-regex.sh"
broken_prefix='^(third entry .*|arbitration budget exhausted for '
printf 'jq -n '\''"" | test("%s")'\''\n' "$broken_prefix" > "$fixture"
output="$(node "$SCRIPT_DIR/jq-regex-safety.mjs" "$fixture" 2>&1)" && {
  echo 'jq-regex-safety.test.sh: bad literal regex unexpectedly passed' >&2
  exit 1
}
grep -Fq 'bad-jq-regex.sh:1: invalid jq test pattern' <<<"$output" || {
  printf '%s\n' "$output" >&2
  echo 'jq-regex-safety.test.sh: checker did not report the planted invalid pattern' >&2
  exit 1
}
echo 'jq-regex-safety.test.sh: PASS'
