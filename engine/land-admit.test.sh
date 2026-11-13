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

GH_LOG_DIR="$test_env_root/gh-calls"
mkdir -p "$GH_LOG_DIR"
GH_CALL_COUNT=0
GH_RC=0
GH_API_RC=0
GH_DELETE_RC=0

gh() {
  GH_CALL_COUNT=$((GH_CALL_COUNT + 1))
  printf '%s\0' "$@" > "$GH_LOG_DIR/call-$GH_CALL_COUNT"
  case "${1-} ${2-} ${3-}" in
    'pr merge '*) printf 'gh merge output\n'; return "$GH_RC" ;;
    'pr view '*) printf '{"headRefName":"feature/topic"}\n'; return 0 ;;
    'api -X PUT '*) return "$GH_API_RC" ;;
    'api -X DELETE '*) return "$GH_DELETE_RC" ;;
  esac
  return 90
}

reset_gh_calls() {
  GH_CALL_COUNT=0
  rm -f "$GH_LOG_DIR"/call-*
}

assert_merge_rc() {
  local expected_rc="$1" expected_stderr="$2" actual_rc
  shift 2
  if land_merge_pr "$@" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" == "$expected_rc" ]] || fail "expected land_merge_pr rc $expected_rc, got $actual_rc"
  if [[ -n "$expected_stderr" ]]; then
    [[ "$(cat "$test_env_root/stderr")" == *"$expected_stderr"* ]] \
      || fail "land_merge_pr stderr lacks '$expected_stderr': $(cat "$test_env_root/stderr")"
  fi
}

valid_sha='0123456789abcdef0123456789abcdef01234567'
assert_merge_rc 64 'refuse:merge:bad-pr' abc "$valid_sha"
[[ "$GH_CALL_COUNT" == 0 ]] || fail 'land_merge_pr called gh for an invalid PR number'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha:0:12}"
[[ "$GH_CALL_COUNT" == 0 ]] || fail 'land_merge_pr called gh for a short head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha^^}"
[[ "$GH_CALL_COUNT" == 0 ]] || fail 'land_merge_pr called gh for an uppercase head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-option' 17 "$valid_sha" --unknown
[[ "$GH_CALL_COUNT" == 0 ]] || fail 'land_merge_pr called gh for an unknown option'

echo 'land-admit.test.sh: all assertions passed'
