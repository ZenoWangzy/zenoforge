#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh"

fixture="$test_env_root/merge-pr"
repo="$fixture/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
git -C "$repo" config user.name 'Merge Helper Test'
git -C "$repo" config user.email merge-helper-test@example.invalid
printf 'fixture\n' > "$repo/source"
git -C "$repo" add source
git -C "$repo" commit -qm 'fixture head'
sha="$(git -C "$repo" rev-parse HEAD)"
result_file="$(merge_pr_result_file "$repo" "$sha")"
mkdir -p "$(dirname "$result_file")"

fail() { printf 'merge-pr-helper.test.sh: %s\n' "$*" >&2; exit 1; }
assert_refuses() {
  local expected="$1" output
  if merge_pr_gate 17 "$sha" "$repo" > "$fixture/gate-output" 2>&1; then
    fail "gate unexpectedly accepted $expected"
  fi
  output="$(cat "$fixture/gate-output")"
  [[ "$output" == *"refusing to merge PR #17: $expected"* ]] || fail "wrong refusal for $expected: $output"
}

: > "$fixture/gh-calls"
PR_HEAD="$sha"
gh() {
  case "$1 $2" in
    'pr view')
      printf 'view:%s\n' "$*" >> "$fixture/gh-calls"
      printf '{"headRefOid":"%s"}\n' "$PR_HEAD"
      ;;
    'pr merge')
      printf 'merge:%s\n' "$*" >> "$fixture/gh-calls"
      ;;
    *)
      fail "unexpected gh command: $*"
      ;;
  esac
}

assert_refuses "no full-suite result exists for SHA $sha" 'missing result'
[[ ! -s "$fixture/gh-calls" ]] || fail 'missing result queried or merged the PR'

jq -n --arg sha "$sha" '{
  sha:$sha,green:false,cli_exit_code:0,
  engine_shards:[range(0;8) | {shard:.,exit_code:(if .==3 then 1 else 0 end)}]
}' > "$result_file"
assert_refuses "full local suites are red for SHA $sha" 'red result'
[[ ! -s "$fixture/gh-calls" ]] || fail 'red result queried or merged the PR'

jq -n --arg sha "$sha" '{
  sha:$sha,green:true,cli_exit_code:0,
  engine_shards:[range(0;8) | {shard:.,exit_code:0}]
}' > "$result_file"
PR_HEAD=ffffffffffffffffffffffffffffffffffffffff
assert_refuses "PR head $PR_HEAD does not match tested SHA $sha" 'stale SHA'
[[ "$(cat "$fixture/gh-calls")" == 'view:pr view 17 --json headRefOid' ]] \
  || fail "stale result made unexpected gh calls: $(cat "$fixture/gh-calls")"

PR_HEAD="$sha"
: > "$fixture/gh-calls"
merge_pr_gate 17 "$sha" "$repo" >/dev/null
[[ "$(cat "$fixture/gh-calls")" == $'view:pr view 17 --json headRefOid\nmerge:pr merge 17 --squash' ]] \
  || fail "green matching result did not squash merge: $(cat "$fixture/gh-calls")"

set +e
refusal=$(env -u ZF_ALLOW_FULL_GATE bash "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh" 17 2>&1)
refusal_status=$?
set -e
[[ $refusal_status == 2 && $refusal == *'do not use the local full gate'* ]] \
  || fail "direct run did not refuse the full gate: $refusal_status $refusal"

echo 'PASS merge helper refuses missing, red, and stale results; matching green result squash merges'
