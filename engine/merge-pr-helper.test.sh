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
PR_CHECKS='[]'
PR_BODY=$'## prior-art\nFollows required status checks: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches\n'
PR_FILES='["tools/merge-pr.sh"]'
gh() {
  case "$1 $2" in
    'pr view')
      printf 'view:%s\n' "$*" >> "$fixture/gh-calls"
      if [[ "$*" == *body,files* ]]; then
        [[ "$PR_BODY" != gh-error ]] || return 1
        jq -cn --arg body "$PR_BODY" --argjson files "$PR_FILES" \
          '{body:$body,files:($files | map({path:.}))}'
      else
        printf '{"headRefOid":"%s"}\n' "$PR_HEAD"
      fi
      ;;
    'pr checks')
      printf 'checks:%s\n' "$*" >> "$fixture/gh-calls"
      if [[ "$PR_CHECKS" == gh-error ]]; then
        printf 'gh pr checks: API error\n' >&2
        return 1
      fi
      printf '%s\n' "$PR_CHECKS"
      if jq -e 'any(.[]; .bucket == "fail" or .bucket == "pending")' <<<"$PR_CHECKS" >/dev/null 2>&1; then
        return 8
      fi
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
[[ "$(cat "$fixture/gh-calls")" == $'view:pr view 17 --json headRefOid\nchecks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files\nmerge:pr merge 17 --squash --delete-branch' ]] \
  || fail "green matching result did not squash merge: $(cat "$fixture/gh-calls")"

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"unit","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
if ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
  fail 'override for one failed check also allowed an unnamed failed check'
fi
check_output="$(cat "$fixture/check-output")"
[[ "$check_output" == *'failed checks: cla, unit'* && "$check_output" == *'checks without a matching ZF_MERGE_OVERRIDE: unit'* ]] \
  || fail "failed check names or unmatched override were not reported: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files' ]] \
  || fail "an unmatched failed check reached merge: $(cat "$fixture/gh-calls")"

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
check_output="$(ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 2>&1)" \
  || fail "named failed-check override did not allow the merge: $check_output"
[[ "$check_output" == *'explicit ZF_MERGE_OVERRIDE allows failed checks: cla'* ]] \
  || fail "merge did not print the failed check covered by its override: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files\nmerge:pr merge 17 --squash --delete-branch' ]] \
  || fail "pending check or named override did not reach squash merge: $(cat "$fixture/gh-calls")"

PR_CHECKS=gh-error
: > "$fixture/gh-calls"
if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
  fail 'a gh pr checks API error reached merge'
fi
check_output="$(cat "$fixture/check-output")"
[[ "$check_output" == *'could not read PR checks as JSON'* ]] \
  || fail "gh pr checks error was not reported: $check_output"
[[ "$(cat "$fixture/gh-calls")" == 'checks:pr checks 17 --json bucket,name' ]] \
  || fail "gh pr checks error reached merge: $(cat "$fixture/gh-calls")"

# Prior-art gate: body needs "## prior-art" with a URL or "no external prior art: <reason>".
PR_CHECKS='[]'
expect_prior_art_refusal() {
  local label="$1" expected="$2"
  : > "$fixture/gh-calls"
  if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
    fail "$label reached merge"
  fi
  [[ "$(cat "$fixture/check-output")" == *"$expected"* ]] || fail "$label wrong refusal: $(cat "$fixture/check-output")"
  [[ "$(cat "$fixture/gh-calls")" != *merge:* ]] || fail "$label reached the merge call"
}
expect_prior_art_merge() {
  local label="$1"
  : > "$fixture/gh-calls"
  merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1 || fail "$label refused: $(cat "$fixture/check-output")"
  [[ "$(cat "$fixture/gh-calls")" == *merge:* ]] || fail "$label did not merge"
}

PR_BODY=$'## summary\nfoo https://example.com/not-in-section\n'
expect_prior_art_refusal 'missing section' 'has no "## prior-art" section'
PR_BODY=$'## prior-art\nI thought hard about it.\n\n## notes\nhttps://example.com/elsewhere\n'
expect_prior_art_refusal 'section without a source' 'needs a source URL'
PR_BODY=$'## prior-art\nno external prior art:\n'
expect_prior_art_refusal 'empty no-prior-art reason' 'needs a source URL'
PR_BODY=gh-error
expect_prior_art_refusal 'unreadable body' 'could not read the PR body and file list as JSON'
PR_BODY=$'## Prior-Art\nSee https://example.com/practice\n## notes\n'
expect_prior_art_merge 'URL in section'
PR_BODY=$'## prior-art\nno external prior art: internal gate wiring only\n'
expect_prior_art_merge 'no-prior-art line'
PR_BODY='no section at all'
PR_FILES='["engine/a.test.sh","engine/tests/fixture.json"]'
expect_prior_art_merge 'test-only PR'
PR_FILES='["engine/a.test.sh","engine/a.sh"]'
expect_prior_art_refusal 'mixed test and source PR' 'has no "## prior-art" section'
PR_FILES='[]'
expect_prior_art_refusal 'empty file list' 'has no "## prior-art" section'
PR_FILES='["tools/merge-pr.sh"]'
ZF_MERGE_OVERRIDE=prior-art expect_prior_art_merge 'prior-art override'
[[ "$(cat "$fixture/check-output")" == *'skips the prior-art check for PR #17'* ]] || fail 'override was not logged'

echo 'PASS merge helper enforces the full-gate SHA, refuses failed or unreadable checks, allows pending checks, and applies exact named overrides, and requires a prior-art section unless test-only or overridden'
