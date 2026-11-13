#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/land-admit.sh"

fail() { printf 'land-admit.test.sh: %s\n' "$*" >&2; exit 1; }

assert_green_rc() {
  local expected_rc="$1" receipt="$2" expected_stderr="${3-}" actual_rc
  if land_receipt_green "$receipt" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" == "$expected_rc" ]] || fail "expected receipt rc $expected_rc, got $actual_rc for $receipt"
  [[ ! -s "$test_env_root/stdout" ]] || fail "receipt check wrote to stdout: $(cat "$test_env_root/stdout")"
  if [[ -n "$expected_stderr" ]]; then
    [[ "$(cat "$test_env_root/stderr")" == *"$expected_stderr"* ]] || fail "stderr lacks '$expected_stderr': $(cat "$test_env_root/stderr")"
  fi
}

receipt="$test_env_root/receipt"
assert_green_rc 1 "$test_env_root/missing" 'refuse:receipt:missing'

: >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:empty'

printf 'bad\tcommand\n-1\tcommand\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:no-valid-lines'

printf '0\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 0 "$receipt"

printf '1\tbash engine/example.test.sh\n0\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 0 "$receipt"

printf '0\tbash engine/example.test.sh\n1\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:failed:bash engine/example.test.sh'

printf '0\tfirst command\n2\tsecond command\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:failed:second command'

repo="$test_env_root/repo"
mkdir -p "$repo"
git init -q "$repo"
path="$(land_receipt_file "$repo" head-sha)" || fail 'land_receipt_file refused a Git repository'
[[ "$path" == */zf-test-receipts/head-sha ]] || fail "receipt path has wrong suffix: $path"

ordinary_dir="$test_env_root/ordinary"
mkdir -p "$ordinary_dir"
if land_receipt_file "$ordinary_dir" head-sha >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'land_receipt_file accepted an ordinary directory'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "land_receipt_file returned $rc for an ordinary directory"
[[ ! -s "$test_env_root/stdout" ]] || fail "land_receipt_file wrote unexpected output: $(cat "$test_env_root/stdout")"

echo 'land-admit.test.sh: all assertions passed'
