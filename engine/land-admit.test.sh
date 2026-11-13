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

printf '0\tgood command\nnot-a-receipt-line\n' >"$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" 'malformed receipt line 2'
[[ "$(cat "$test_env_root/stderr")" == 'malformed receipt line 2' ]] || fail 'strict receipt changed the malformed-line refusal'

printf '1\tcommand\tone\n0\tcommand\ttwo\n' >"$receipt"
assert_green_rc 0 "$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" $'command\tone (exit 1)'
[[ "$(cat "$test_env_root/stderr")" == $'command\tone (exit 1)' ]] || fail 'strict receipt did not retain the full command'

printf '0\t\n' >"$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" 'malformed receipt line 1'

source_fixture="$test_env_root/source-fixture"
mkdir -p "$source_fixture/tools" "$source_fixture/engine"
cp "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh" "$MODEL_POLICY_TEST_REPO/tools/merge-pr-bootstrap.sh" "$source_fixture/tools/"
cp "$MODEL_POLICY_TEST_REPO/engine/land-admit.sh" "$source_fixture/engine/"
(cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh" && declare -F land_receipt_green >/dev/null) \
  || fail 'merge helper could not load admission from its own checkout'
if (cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh" && merge_pr_squash invalid 0123456789abcdef0123456789abcdef01234567) 2>/dev/null; then
  fail 'merge helper accepted an invalid PR'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "merge helper returned $rc instead of 1 for an invalid PR"
rm "$source_fixture/engine/land-admit.sh"
if (cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh") >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'merge helper accepted a missing admission file'
fi
[[ "$(cat "$test_env_root/stderr")" == 'merge-pr: cannot load engine/land-admit.sh' ]] || fail 'missing admission file did not produce one clear error'

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
GH_META_RC=0
GH_META_OUTPUT='{"head":{"ref":"feature/topic"}}'

gh() {
  local method="" call_number
  if [[ -f "$GH_LOG_DIR/count" ]]; then
    read -r call_number < "$GH_LOG_DIR/count"
  else
    call_number=0
  fi
  call_number=$((call_number + 1))
  printf '%s\n' "$call_number" > "$GH_LOG_DIR/count"
  GH_CALL_COUNT="$call_number"
  printf '%s\0' "$@" > "$GH_LOG_DIR/call-$GH_CALL_COUNT"
  case "${1-} ${2-} ${3-}" in
    'pr merge '*) printf 'gh merge output\n'; return "$GH_RC" ;;
    'pr view '*) [[ "${GH_VIEW_RC:-0}" == 0 ]] || return "$GH_VIEW_RC"; printf '{"headRefName":"feature/topic"}\n'; return 0 ;;
    'api '*)
      while (($#)); do
        if [[ "$1" == -X && $# -ge 2 ]]; then
          method="$2"
          break
        fi
        shift
      done
      case "$method" in
        PUT) [[ -z "${GH_API_OUTPUT:-}" ]] || printf '%s\n' "$GH_API_OUTPUT" >&2; return "$GH_API_RC" ;;
        DELETE) return "$GH_DELETE_RC" ;;
        '') [[ "$GH_META_RC" == 0 ]] || return "$GH_META_RC"; printf '%s\n' "$GH_META_OUTPUT"; return 0 ;;
      esac
      ;;
  esac
  return 90
}

reset_gh_calls() {
  GH_CALL_COUNT=0
  rm -f "$GH_LOG_DIR"/call-*
  rm -f "$GH_LOG_DIR/count"
}

gh_call_count() {
  if [[ -f "$GH_LOG_DIR/count" ]]; then
    cat "$GH_LOG_DIR/count"
  else
    printf '0\n'
  fi
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

read_gh_call() {
  local call_number="$1"
  mapfile -d '' -t GH_ARGS < "$GH_LOG_DIR/call-$call_number"
}

assert_gh_arg() {
  local expected="$1" arg
  for arg in "${GH_ARGS[@]}"; do
    [[ "$arg" == "$expected" ]] && return 0
  done
  fail "gh arguments lack '$expected'"
}

assert_gh_pair() {
  local expected_flag="$1" expected_value="$2" i
  for ((i = 0; i < ${#GH_ARGS[@]} - 1; i++)); do
    if [[ "${GH_ARGS[$i]}" == "$expected_flag" && "${GH_ARGS[$((i + 1))]}" == "$expected_value" ]]; then
      return 0
    fi
  done
  fail "gh arguments lack '$expected_flag' followed by '$expected_value'"
}

valid_sha='0123456789abcdef0123456789abcdef01234567'
assert_merge_rc 64 'refuse:merge:bad-pr' abc "$valid_sha"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an invalid PR number'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha:0:12}"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for a short head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha^^}"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an uppercase head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-option' 17 "$valid_sha" --unknown
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an unknown option'

reset_gh_calls
GH_RC=0
assert_merge_rc 0 '' 17 "$valid_sha"
[[ "$(gh_call_count)" == 1 ]] || fail "land_merge_pr made $(gh_call_count) gh calls for a normal merge"
[[ "$(cat "$test_env_root/stdout")" == 'gh merge output' ]] || fail 'land_merge_pr did not pass gh output through'
read_gh_call 1
[[ "${GH_ARGS[0]}" == pr && "${GH_ARGS[1]}" == merge && "${GH_ARGS[2]}" == 17 ]] \
  || fail 'land_merge_pr called gh with the wrong merge command'
assert_gh_arg --squash
assert_gh_pair --match-head-commit "$valid_sha"

reset_gh_calls
assert_merge_rc 0 '' 17 "$valid_sha" --delete-branch
read_gh_call 1
[[ "${GH_ARGS[*]}" == "pr merge 17 --squash --delete-branch --match-head-commit $valid_sha" ]] \
  || fail 'land_merge_pr changed the merge helper argument order'

reset_gh_calls
subject='ship the "quoted" change'
body='release note with "quotes"'
assert_merge_rc 0 '' 18 "$valid_sha" --repo owner/project --subject "$subject" --body "$body" --delete-branch
[[ "$(gh_call_count)" == 1 ]] || fail "land_merge_pr made $(gh_call_count) gh calls with merge options"
read_gh_call 1
assert_gh_pair --repo owner/project
assert_gh_pair --subject "$subject"
assert_gh_pair --body "$body"
assert_gh_arg --delete-branch

reset_gh_calls
unset LAND_MERGE_REST_FALLBACK
GH_RC=1
assert_merge_rc 1 '' 19 "$valid_sha"
[[ "$(gh_call_count)" == 1 ]] || fail "land_merge_pr made $(gh_call_count) gh calls without REST fallback"

reset_gh_calls
LAND_MERGE_REST_FALLBACK=1
GH_RC=1
GH_API_RC=0
GH_DELETE_RC=0
assert_merge_rc 0 '' 20 "$valid_sha" --repo owner/project
[[ "$(gh_call_count)" == 4 ]] || fail "land_merge_pr made $(gh_call_count) gh calls with REST fallback"
read_gh_call 3
assert_gh_arg 'repos/{owner}/{repo}/pulls/20/merge'
assert_gh_arg "sha=$valid_sha"
assert_gh_pair --repo owner/project
read_gh_call 4
assert_gh_arg 'repos/{owner}/{repo}/git/refs/heads/feature/topic'

reset_gh_calls
GH_VIEW_RC=1
GH_DELETE_RC=5
assert_merge_rc 0 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ "$(gh_call_count)" == 5 ]] || fail 'REST fallback did not recover the head ref or ignore deletion failure'
read_gh_call 3
assert_gh_arg 'repos/{owner}/{repo}/pulls/20'
assert_gh_pair --repo owner/project
read_gh_call 4
assert_gh_arg 'repos/{owner}/{repo}/pulls/20/merge'
read_gh_call 5
assert_gh_arg 'repos/{owner}/{repo}/git/refs/heads/feature/topic'

reset_gh_calls
GH_META_OUTPUT='invalid metadata'
assert_merge_rc 1 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ ! -s "$test_env_root/stderr" ]] || fail 'malformed REST metadata leaked a parser error'
[[ "$(gh_call_count)" == 3 ]] || fail 'malformed REST metadata reached the merge or deletion call'
GH_META_OUTPUT='{"head":{"ref":"feature/topic"}}'

reset_gh_calls
GH_META_RC=1
assert_merge_rc 1 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ ! -s "$test_env_root/stderr" ]] || fail 'failed REST metadata read changed the refusal output'
[[ "$(gh_call_count)" == 3 ]] || fail 'failed REST metadata read reached the merge or deletion call'
GH_META_RC=0

reset_gh_calls
GH_VIEW_RC=0
GH_API_RC=1
GH_API_OUTPUT='HTTP 409: Head branch was modified'
assert_merge_rc 1 "refuse:merge:head-moved:$valid_sha is no longer the head, not merged" 20 "$valid_sha" --delete-branch
[[ "$(cat "$test_env_root/stderr")" == "refuse:merge:head-moved:$valid_sha is no longer the head, not merged" ]] || fail 'shared head-moved refusal changed'
[[ "$(gh_call_count)" == 3 ]] || fail 'REST fallback deleted the branch after a failed merge'

reset_gh_calls
LAND_MERGE_PR_REFUSAL=1 assert_merge_rc 1 "refusing to merge PR #20: head moved after the gate: $valid_sha is no longer the head, not merged" 20 "$valid_sha" --delete-branch
[[ "$(cat "$test_env_root/stderr")" == "refusing to merge PR #20: head moved after the gate: $valid_sha is no longer the head, not merged" ]] || fail 'head-moved refusal changed'
[[ "$(gh_call_count)" == 3 ]] || fail 'REST fallback deleted the branch after a failed merge'
unset LAND_MERGE_REST_FALLBACK

echo 'land-admit.test.sh: all assertions passed'
