#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh"
merge_pr_static_scans() { return 0; }
merge_pr_review_family() { return 0; }
merge_pr_root() { printf '%s\n' "$repo"; } # the fixture repo stands in for the enclosing checkout: the host's size state and receipts must not reach these fixtures

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
PR_CI_ROLLUP='[]'
PR_BODY=$'## prior-art\nFollows required status checks: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches\n'
PR_FILES='["tools/quick-land.sh"]'
PR_FILE_STATUSES='[]'
PR_META='{"title":"fixture","body":""}'
PR_LIST='[]'
PR_FILES_BY_PR='{}'
PR_HEAD_REF=parent-branch
PR_CHILDREN='[]'
PR_CI_VIEW_ERROR=0
PR_CI_VIEW_OUTPUT=''
PR_FILES_API_ERROR=0
gh() {
  case "$1 $2" in
    'pr view')
      if [[ "$*" == *headRefName* ]]; then
        printf '{"headRefName":"%s"}\n' "$PR_HEAD_REF"
        return
      fi
      printf 'view:%s\n' "$*" >> "$fixture/gh-calls"
      if [[ "$*" == *headRefOid,statusCheckRollup* ]]; then
        [[ "$PR_CI_VIEW_ERROR" == 0 ]] || return 1
        if [[ -n "$PR_CI_VIEW_OUTPUT" ]]; then printf '%s\n' "$PR_CI_VIEW_OUTPUT"; return; fi
        printf '{"headRefOid":"%s","statusCheckRollup":%s,"files":%s}\n' "${PR_CI_HEAD:-$PR_HEAD}" "$PR_CI_ROLLUP" "$(jq -cn --argjson files "$PR_FILES" '$files[:100] | map({path:.})')"
      elif [[ "$*" == *body,files* ]]; then
        [[ "$PR_BODY" != gh-error ]] || return 1
        jq -cn --arg body "$PR_BODY" --argjson files "$PR_FILES" --arg at "${PR_HEAD_DATE:-}" \
          '{body:$body,files:($files | map({path:.})),commits:(if $at == "" then [] else [{committedDate:$at}] end)}'
      else
        printf '{"headRefOid":"%s"}\n' "$PR_HEAD"
      fi
      ;;
    'pr checks')
      printf 'checks:%s\n' "$*" >> "$fixture/gh-calls"
      local unregistered; unregistered="$(cat "$fixture/no-checks-left" 2>/dev/null || printf 0)"
      if (( unregistered > 0 )); then
        printf '%s\n' "$((unregistered - 1))" > "$fixture/no-checks-left"
        printf "no checks reported on the 'parent-branch' branch\n" >&2
        return 1
      fi
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
    'pr edit')
      printf 'edit:%s\n' "$*" >> "$fixture/gh-calls"
      [[ "${PR_EDIT_ERROR:-}" != 1 ]] || return 1
      ;;
    'pr list')
      printf '%s\n' "$PR_CHILDREN"
      ;;
    'repo view')
      printf '{"defaultBranchRef":{"name":"main"}}\n'
      ;;
    'run list')
      printf '[{"databaseId":7,"status":"queued"},{"databaseId":8,"status":"completed"}]\n'
      ;;
    'run cancel')
      printf '%s\n' "$3" >> "$fixture/cancelled"
      ;;
    'api '*)
      if [[ "$*" == *' -q .[].filename' ]]; then
        printf 'api:%s\n' "$*" >> "$fixture/gh-calls"
        [[ "$PR_FILES_API_ERROR" == 0 ]] || return 1
        jq -r '.[]' <<<"$PR_FILES"
        return
      fi
      local path="${!#}" num
      case "$path" in
        'repos/{owner}/{repo}/pulls/17')
          [[ "${PR_META_ERROR:-}" != 1 ]] || return 1
          printf '%s\n' "$PR_META"
          ;;
        'repos/{owner}/{repo}/pulls?'*)
          [[ "${PR_LIST_ERROR:-}" != 1 ]] || return 1
          printf '%s\n' "$PR_LIST"
          ;;
        'repos/{owner}/{repo}/pulls/'*'/files')
          num="${path#*pulls/}"
          num="${num%%/*}"
          if [[ "$num" == 17 ]]; then
            printf '%s\n' "$PR_FILE_STATUSES"
          else
            jq -c --arg n "$num" '.[$n] // []' <<<"$PR_FILES_BY_PR"
          fi
          ;;
        *)
          printf '%s\n' "$PR_FILE_STATUSES"
          ;;
      esac
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
[[ "$(cat "$fixture/gh-calls")" == $'view:pr view 17 --json headRefOid\nchecks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nmerge:pr merge 17 --squash --delete-branch\nview:pr view 17 --json headRefOid' ]] \
  || fail "green matching result did not squash merge: $(cat "$fixture/gh-calls")"

# Stacked child: deleting the parent's head branch closes open PRs based on it, so the child is retargeted before the merge.
PR_CHILDREN='[{"number":21}]'
: > "$fixture/gh-calls"
merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1 || fail "stacked parent did not merge: $(cat "$fixture/check-output")"
[[ "$(cat "$fixture/gh-calls")" == *$'edit:pr edit 21 --base main\nmerge:pr merge 17 --squash --delete-branch'* ]] \
  || fail "child PR was not retargeted before the squash merge: $(cat "$fixture/gh-calls")"
[[ "$(cat "$fixture/check-output")" == *'retargeted child PR #21 from parent-branch to main'* ]] \
  || fail "retarget was not logged: $(cat "$fixture/check-output")"

PR_EDIT_ERROR=1
: > "$fixture/gh-calls"
if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then fail 'a failed child retarget still merged the parent'; fi
[[ "$(cat "$fixture/check-output")" == *'refusing to merge PR #17: could not retarget child PR #21 to main'* ]] \
  || fail "failed retarget did not refuse with a reason: $(cat "$fixture/check-output")"
! grep -q '^merge:' "$fixture/gh-calls" || fail 'a failed child retarget reached merge'
PR_EDIT_ERROR=
PR_CHILDREN='[]'

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"unit","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
if ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
  fail 'override for one failed check also allowed an unnamed failed check'
fi
check_output="$(cat "$fixture/check-output")"
[[ "$check_output" == *'failed checks: cla, unit'* && "$check_output" == *'checks without a matching ZF_MERGE_OVERRIDE: unit'* ]] \
  || fail "failed check names or unmatched override were not reported: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits' ]] \
  || fail "an unmatched failed check reached merge: $(cat "$fixture/gh-calls")"

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
check_output="$(ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 2>&1)" \
  || fail "named failed-check override did not allow the merge: $check_output"
[[ "$check_output" == *'explicit ZF_MERGE_OVERRIDE allows failed checks: cla'* ]] \
  || fail "merge did not print the failed check covered by its override: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nmerge:pr merge 17 --squash --delete-branch\nview:pr view 17 --json headRefOid' ]] \
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

# Checks that register late: "no checks reported" twice, then JSON, must proceed to merge.
sleep() { printf 'sleep:%s\n' "$1" >> "$fixture/sleep-calls"; }
PR_CHECKS='[]'
printf '2\n' > "$fixture/no-checks-left"
: > "$fixture/sleep-calls"
: > "$fixture/gh-calls"
merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1 || fail "late checks refused: $(cat "$fixture/check-output")"
[[ "$(cat "$fixture/gh-calls")" == *merge:* ]] || fail 'late checks did not reach merge'
[[ "$(grep -c '^checks:' "$fixture/gh-calls")" == 3 ]] || fail "late checks were not retried twice: $(cat "$fixture/gh-calls")"
[[ "$(cat "$fixture/sleep-calls")" == $'sleep:10\nsleep:10' ]] || fail "retry gap was not 10 s: $(cat "$fixture/sleep-calls")"

# Checks that never register: the bound (here 30 s) ends the retries and the merge is refused.
printf '999\n' > "$fixture/no-checks-left"
: > "$fixture/sleep-calls"
: > "$fixture/gh-calls"
if ZF_CHECKS_WAIT_SECS=30 merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
  fail 'checks that never registered reached merge'
fi
[[ "$(cat "$fixture/check-output")" == *'could not read PR checks as JSON'* ]] || fail "unregistered checks gave the wrong refusal: $(cat "$fixture/check-output")"
[[ "$(grep -c '^checks:' "$fixture/gh-calls")" == 4 && "$(grep -c '^sleep' "$fixture/sleep-calls")" == 3 ]] \
  || fail "bound was not 30 s of retries: checks=$(cat "$fixture/gh-calls") sleeps=$(cat "$fixture/sleep-calls")"
unset -f sleep
rm -f "$fixture/no-checks-left"

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

PR_HEAD_DATE=2020-01-01T00:00:00Z expect_prior_art_refusal 'stale PR head' 'over 24 hours old'

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
PR_FILES='["tools/quick-land.sh"]'
[[ "$(sort -u "$fixture/cancelled")" == 7 ]] || fail "merged PR's unfinished run was not the one cancelled"
# A red ratchet refuses only the PR that grew the file (#214 reddened main this way).
(
  merge_pr_root() { printf '%s\n' "$repo"; }
  PR_HEAD="$sha"
  PR_BODY=$'## prior-art\nno external prior art: internal gate wiring only\n'
  mkdir -p "$repo/tools"
  printf "echo 'FAIL tools/quick-land.sh grew to 900 lines, its baseline in tools/size-baseline.txt is 800'; exit 1\n" > "$repo/tools/size-ratchet.sh"
  expect_prior_art_refusal 'PR over its size baseline' 'FAIL tools/quick-land.sh grew'
  PR_FILES='["other.sh"]' expect_prior_art_merge 'main over baseline, PR not'
  PR_FILES='["tools/size-baseline.txt"]' expect_prior_art_merge 'PR edits the baseline file only'
  PR_FILES='["quick-land.sh"]' expect_prior_art_merge 'PR file is a substring of the failing path'
)
rm -f "$repo/tools/size-ratchet.sh" # the fake ratchet must not reach later merges
ZF_MERGE_OVERRIDE=prior-art expect_prior_art_merge 'prior-art override'
[[ "$(cat "$fixture/check-output")" == *'skips the prior-art check for PR #17'* ]] || fail 'override was not logged'

# Test receipts: a merge must not follow a failed test run at the PR head.
receipt_dir="$repo/.git/zf-test-receipts"
rsha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
expect_receipt_refusal() {
  local label="$1" expected="$2"
  : > "$fixture/gh-calls"
  if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
    fail "$label reached merge"
  fi
  [[ "$(cat "$fixture/check-output")" == *"$expected"* ]] || fail "$label wrong refusal: $(cat "$fixture/check-output")"
  [[ "$(cat "$fixture/gh-calls")" != *merge:* ]] || fail "$label reached the merge call"
}
expect_receipt_merge() {
  local label="$1"
  : > "$fixture/gh-calls"
  merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1 || fail "$label refused: $(cat "$fixture/check-output")"
  [[ "$(cat "$fixture/gh-calls")" == *merge:* ]] || fail "$label did not merge"
}
PR_CHECKS='[]'
PR_BODY=$'## prior-art\nno external prior art: test fixture\n'
PR_FILES='["tools/quick-land.sh"]'
PR_HEAD="$rsha" # no full-suite result exists for this head, so receipt or CI checks must prove it
PR_CI_HEAD="$rsha"
rm -rf "$receipt_dir"
expect_receipt_refusal 'no test receipt' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
ci_rollup() {
  jq -cn '
    ([{name:"cla",workflowName:"CLA"},{name:"cli",workflowName:"cli-tests"}]
      + [range(0;8) | {name:("suites (" + tostring + ")"),workflowName:"engine-tests"}])
    | map(. + {__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"})'
}
ci_set() {
  PR_CI_ROLLUP="$(jq -c --arg name "$1" --arg status "$2" --arg conclusion "$3" '
    map(if .name == $name then .status=$status
      | (if $conclusion == "" then del(.conclusion) else .conclusion=$conclusion end)
      else . end)' <<<"$PR_CI_ROLLUP")"
}
ci_set_workflow() {
  PR_CI_ROLLUP="$(jq -c --arg name "$1" --arg workflow "$2" '
    map(if .name == $name then .workflowName=$workflow else . end)' <<<"$PR_CI_ROLLUP")"
}
PR_CI_ROLLUP="$(ci_rollup)"
expect_receipt_merge 'all-green CI checks at the head'
[[ "$(cat "$fixture/check-output")" == *"receipt: ci-green 10 checks at ${rsha:0:12}"* ]] \
  || fail "green CI receipt path was not logged: $(cat "$fixture/check-output")"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set_workflow cli engine-tests
expect_receipt_refusal 'cli check from engine-tests workflow' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set_workflow 'suites (0)' cli-tests
expect_receipt_refusal 'suite check from cli-tests workflow' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set cla COMPLETED FAILURE
expect_receipt_refusal 'failed non-required check' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set 'suites (3)' COMPLETED SKIPPED
expect_receipt_refusal 'skipped required suite' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set cli COMPLETED SKIPPED
expect_receipt_refusal 'skipped required cli' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set 'suites (3)' COMPLETED FAILURE
rm -f "$receipt_dir/$rsha"
expect_receipt_refusal 'failed CI suite' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
ci_set 'suites (3)' IN_PROGRESS ''
expect_receipt_refusal 'pending CI suite' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_HEAD=ffffffffffffffffffffffffffffffffffffffff
PR_CI_ROLLUP="$(ci_rollup)"
expect_receipt_refusal 'rollup for another head' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_HEAD="$rsha"
PR_CI_ROLLUP="$(ci_rollup | jq -c 'map(if .name == "cli" then {__typename:"StatusContext",context:"cli",state:"SUCCESS"} else . end)')"
expect_receipt_refusal 'StatusContext cannot satisfy cli' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup | jq -c 'map(if .name == "cli" then del(.workflowName) else . end)')"
expect_receipt_refusal 'required CheckRun without workflow' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup | jq -c 'map(select(.name != "cli"))')"
expect_receipt_refusal 'missing cli' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup | jq -c '[.[] | select(.name == "cla" or .name == "cli" or .name == "suites (0)" or .name == "suites (1)" or .name == "suites (2)")]')"
expect_receipt_refusal 'only three of eight suites' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
for conclusion in CANCELLED TIMED_OUT ACTION_REQUIRED; do
  PR_CI_ROLLUP="$(ci_rollup)"
  ci_set 'suites (3)' COMPLETED "$conclusion"
  expect_receipt_refusal "suite $conclusion" "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
done
PR_CI_ROLLUP="$(ci_rollup | jq -c 'map(if .name == "cla" then .conclusion="SKIPPED" else . end) + [{__typename:"CheckRun",name:"optional",workflowName:"other.yml",status:"COMPLETED",conclusion:"NEUTRAL"}]')"
expect_receipt_merge 'non-required skipped and neutral checks'
PR_CI_ROLLUP="$(ci_rollup)"
PR_CI_VIEW_ERROR=1
expect_receipt_refusal 'gh pr view fails' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_VIEW_ERROR=0
PR_CI_VIEW_OUTPUT='not JSON'
expect_receipt_refusal 'non-JSON gh output' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_VIEW_OUTPUT=''
PR_CI_ROLLUP=null
expect_receipt_refusal 'null rollup' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_CI_ROLLUP="$(ci_rollup)"
PR_FILES='[".github/workflows/engine-tests.yml"]'
expect_receipt_refusal 'workflow-editing PR' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
for path in tools/run-engine-tests.sh .zenoforge/ci.json; do
  PR_FILES="$(jq -cn --arg path "$path" '[$path]')"
  expect_receipt_refusal "CI suite-selection file $path" "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
done
PR_FILES="$(jq -cn '[range(0;119) | "safe/file-\(.).txt"] + [".github/workflows/x.yml"] + [range(120;150) | "safe/file-\(.).txt"]')"
expect_receipt_refusal 'workflow file past the first 100 entries' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
[[ "$(cat "$fixture/gh-calls")" == *'api --paginate repos/{owner}/{repo}/pulls/17/files -q .[].filename'* ]] \
  || fail 'workflow-editing PR did not use the paginated CI file guard'
PR_FILES='["tools/quick-land.sh"]'
PR_FILES_API_ERROR=1
expect_receipt_refusal 'paginated PR file read fails' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
PR_FILES_API_ERROR=0
PR_FILES='["tools/quick-land.sh"]'
red_result="$(merge_pr_result_file "$repo" "$rsha")"
mkdir -p "$(dirname "$red_result")"
jq -n --arg sha "$rsha" '{sha:$sha,green:false,cli_exit_code:1,engine_shards:[]}' >"$red_result"
PR_CI_ROLLUP="$(ci_rollup)"
expect_receipt_refusal 'local red result with green CI' "full local suites are red for SHA $rsha"
[[ "$(cat "$fixture/gh-calls")" != *statusCheckRollup* ]] || fail 'CI was consulted despite a local red result'
rm -f "$red_result"
jq -n --arg sha "$rsha" '{sha:$sha,green:true,cli_exit_code:0,engine_shards:[range(0;7) as $shard | {shard:$shard,exit_code:0}]}' >"$red_result"
expect_receipt_refusal 'short local green result with green CI' "the full-suite result for SHA $rsha is incomplete or invalid"
[[ "$(cat "$fixture/gh-calls")" != *statusCheckRollup* ]] || fail 'CI was consulted despite an incomplete local result'
printf '{\n' >"$red_result"
expect_receipt_refusal 'malformed local result with green CI' "the full-suite result for SHA $rsha is incomplete or invalid"
[[ "$(cat "$fixture/gh-calls")" != *statusCheckRollup* ]] || fail 'CI was consulted despite a malformed local result'
jq -n --arg sha "$rsha" '{sha:$sha,green:true,cli_exit_code:0,engine_shards:[range(0;8) as $shard | {shard:$shard,exit_code:0}]}' >"$red_result"
expect_unreadable_result_refusal() {
  : > "$fixture/gh-calls"
  if (
    jq() {
      local arg
      for arg in "$@"; do
        [[ "$arg" == "$red_result" ]] && return 2
      done
      command jq "$@"
    }
    merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1
  ); then
    fail 'unreadable local result reached merge'
  fi
  [[ "$(cat "$fixture/check-output")" == *"the full-suite result for SHA $rsha is incomplete or invalid"* ]] \
    || fail "unreadable local result wrong refusal: $(cat "$fixture/check-output")"
  [[ "$(cat "$fixture/gh-calls")" != *statusCheckRollup* ]] || fail 'CI was consulted despite an unreadable local result'
}
expect_unreadable_result_refusal
rm -f "$red_result"
mkdir -p "$receipt_dir"
: >"$receipt_dir/$rsha"
PR_CI_ROLLUP="$(ci_rollup)"
expect_receipt_merge 'empty local receipt uses green CI'
[[ "$(cat "$fixture/check-output")" == *"receipt: ci-green 10 checks at ${rsha:0:12}"* ]] || fail "empty local receipt did not use the green CI receipt: $(cat "$fixture/check-output")"
rm -f "$receipt_dir/$rsha"
mkdir -p "$receipt_dir"
printf '0\tbash engine/quick-land.test.sh\n1\tbash engine/merge-pr-helper.test.sh\n' >"$receipt_dir/$rsha"
expect_receipt_refusal 'failed last run' 'bash engine/merge-pr-helper.test.sh (exit 1)'
printf '0\tbash engine/quick-land.test.sh\n1\tbash engine/merge-pr-helper.test.sh\n0\tbash engine/merge-pr-helper.test.sh\n' >"$receipt_dir/$rsha"
expect_receipt_merge 'later pass of the same command'
[[ "$(cat "$fixture/check-output")" == *'receipt: local'* ]] || fail "local receipt path was not logged: $(cat "$fixture/check-output")"
printf '1\tbash engine/x.test.sh\nnot-a-receipt-line\n' >"$receipt_dir/$rsha"
expect_receipt_refusal 'malformed receipt line' 'malformed receipt line 2'
rm -f "$receipt_dir/$rsha"
PR_FILES='["docs/notes.md","README.md"]'
expect_receipt_merge 'Markdown-only PR with no receipt'
PR_FILES='["tools/quick-land.sh"]'
PR_HEAD="$sha" # the green full-suite result above proves this head and counts as a receipt
PR_CI_HEAD="$sha"

# tools/test-receipt.sh writes <rc><TAB><command> under the current HEAD and exits with the command's code.
if (cd "$repo" && bash "$MODEL_POLICY_TEST_REPO/tools/test-receipt.sh" true); then :; else fail 'test-receipt.sh exited non-zero for a passing command'; fi
if (cd "$repo" && bash "$MODEL_POLICY_TEST_REPO/tools/test-receipt.sh" false); then fail 'test-receipt.sh exited 0 for a failing command'; fi
[[ "$(cat "$receipt_dir/$sha")" == $'0\ttrue\n1\tfalse' ]] || fail "test-receipt.sh wrote: $(cat "$receipt_dir/$sha" 2>/dev/null)"

# Any engine shell change runs the static scans; a red scan refuses, other changes skip them.
merge_pr_static_scans() { echo called >> "$fixture/scan-calls"; echo 'not ok - banned shape'; return 1; }
: > "$fixture/scan-calls"
PR_CHECKS='[]' PR_FILES='["tools/quick-land.sh"]' PR_BODY=$'## prior-art\nno external prior art: test fixture'
merge_pr_static_scans_ok 17 || fail 'a PR with no engine shell was refused by the static scans'
[[ ! -s "$fixture/scan-calls" ]] || fail 'a PR with no engine shell ran the static scans'
PR_FILES='["engine/lib.d/model-units.sh"]'
if merge_pr_static_scans_ok 17 >"$fixture/check-output" 2>&1; then fail 'a red static scan did not refuse the merge'; fi
[[ "$(cat "$fixture/check-output")" == *'static scan failed: not ok - banned shape'* ]] || fail "scan refusal lost its reason: $(cat "$fixture/check-output")"
# #659 reached main through a Python file: a text scan covers more than shell.
PR_FILES='["engine/mac-autopilot/worker_cost.py"]'
if merge_pr_static_scans_ok 17 >"$fixture/check-output" 2>&1; then fail 'a Python engine change skipped the static scans'; fi
PR_FILES='["engine/lib.d/model-units.sh"]'
PR_BODY=gh-error
if merge_pr_static_scans_ok 17 >"$fixture/check-output" 2>&1; then fail 'an unreadable PR skipped the static scans'; fi
PR_BODY=$'## prior-art\nno external prior art: test fixture'
merge_pr_static_scans() { return 0; }

# A dispatch-queue change runs review-family.test.sh; a red run refuses, other files skip it.
merge_pr_review_family() { echo called >> "$fixture/review-family-calls"; echo 'not ok - dispatch line'; return 1; }
: > "$fixture/review-family-calls"
PR_CHECKS='[]' PR_FILES='["tools/quick-land.sh"]' PR_BODY=$'## prior-art\nno external prior art: test fixture'
merge_pr_review_family_ok 17 || fail 'a non-dispatch PR was refused by review-family'
[[ ! -s "$fixture/review-family-calls" ]] || fail 'a non-dispatch PR ran review-family'
PR_FILES='["engine/mac-autopilot/scheduler.d/dispatch-queue.sh"]'
if merge_pr_review_family_ok 17 >"$fixture/check-output" 2>&1; then fail 'a red review-family did not refuse a dispatch-queue PR'; fi
[[ "$(cat "$fixture/check-output")" == *'review-family.test.sh failed: not ok - dispatch line'* ]] || fail "review-family refusal lost its reason: $(cat "$fixture/check-output")"
merge_pr_review_family() { return 0; }

# Missing checkouts refuse both the size gate and the scheduler prelude.
(
  mkdir -p "$fixture/no-git"
  cd "$fixture/no-git"
  merge_pr_root() { git rev-parse --show-toplevel 2>/dev/null; }
  failures=0
  if merge_pr_size_ok 17 >"$fixture/no-git-size" 2>&1; then
    printf 'merge-pr-helper.test.sh: size gate passed without a checkout\n' >&2
    failures=$((failures + 1))
  elif [[ "$(cat "$fixture/no-git-size")" != *'refusing to merge PR #17: no git checkout: cannot run size-ratchet'* ]]; then
    printf 'merge-pr-helper.test.sh: size gate lost its no-checkout refusal: %s\n' "$(cat "$fixture/no-git-size")" >&2
    failures=$((failures + 1))
  fi
  PR_FILES='["engine/mac-autopilot/scheduler.d/models.sh"]'
  PR_CI_ROLLUP='[]'
  if merge_pr_scheduler_prelude_ok 17 >"$fixture/no-git-tree" 2>&1; then
    printf 'merge-pr-helper.test.sh: tree gate passed without a checkout\n' >&2
    failures=$((failures + 1))
  elif [[ "$(cat "$fixture/no-git-tree")" != *'refusing to merge PR #17: scheduler.test.sh prelude failed rc=1: no git checkout: cannot run merge_pr_prelude_in on the PR head'* ]]; then
    printf 'merge-pr-helper.test.sh: tree gate lost its no-checkout refusal: %s\n' "$(cat "$fixture/no-git-tree")" >&2
    failures=$((failures + 1))
  fi
  (( failures == 0 ))
) || fail 'a gate passed or lost its refusal without a git checkout'

# A scheduler change runs the scheduler.test.sh prelude; all-green checks at the head skip it.
PRELUDE_RC=1
PRELUDE_OUT='not ok - stale grep'
merge_pr_scheduler_prelude() { echo called >> "$fixture/prelude-calls"; printf '%s\n' "$PRELUDE_OUT"; return "$PRELUDE_RC"; }
: > "$fixture/prelude-calls"
PR_CHECKS='[]' PR_FILES='["tools/quick-land.sh"]' PR_BODY=$'## prior-art\nno external prior art: test fixture'
merge_pr_scheduler_prelude_ok 17 || fail 'a non-scheduler PR was refused by the prelude check'
[[ ! -s "$fixture/prelude-calls" ]] || fail 'a non-scheduler PR ran the prelude'
PR_BODY=gh-error
if merge_pr_scheduler_prelude_ok 17 >"$fixture/check-output" 2>&1; then fail 'an unreadable PR skipped the prelude check'; fi
[[ "$(cat "$fixture/check-output")" == *'could not read PR files'* ]] || fail "unreadable PR refusal lost its reason: $(cat "$fixture/check-output")"
PR_BODY=$'## prior-art\nno external prior art: test fixture'
PR_FILES='["engine/mac-autopilot/scheduler.d/models.sh"]'
PRELUDE_RC=0
PRELUDE_OUT='prelude passed'
PR_CI_ROLLUP="$(ci_rollup)"
: > "$fixture/gh-calls"
if ! merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then fail "green checks at the head did not proceed to merge: $(cat "$fixture/check-output")"; fi
[[ ! -s "$fixture/prelude-calls" ]] || fail 'all-green head checks still ran the prelude'
[[ "$(cat "$fixture/check-output")" == *"prelude: ci-green 10 checks at ${sha:0:12}"* ]] || fail "green prelude skip was not logged: $(cat "$fixture/check-output")"
grep -q '^merge:' "$fixture/gh-calls" || fail 'all-green head checks did not merge'

# Any failed PR check keeps the local prelude in the merge path.
PR_CI_ROLLUP="$(ci_rollup)"
ci_set 'suites (3)' COMPLETED FAILURE
: > "$fixture/prelude-calls"
merge_pr_scheduler_prelude_ok 17 || fail 'a failed PR check stopped the local prelude'
[[ -s "$fixture/prelude-calls" ]] || fail 'a failed PR check skipped the local prelude'

# A skipped check is green for receipts but does not satisfy the prelude's SUCCESS contract.
PR_CI_ROLLUP="$(ci_rollup)"
ci_set 'suites (3)' COMPLETED SKIPPED
: > "$fixture/prelude-calls"
merge_pr_scheduler_prelude_ok 17 || fail 'a skipped PR check stopped the local prelude'
[[ -s "$fixture/prelude-calls" ]] || fail 'a skipped PR check incorrectly skipped the prelude'
for path in .github/workflows/engine-tests.yml tools/run-engine-tests.sh .zenoforge/ci.json; do
  PR_FILES="$(jq -cn --arg path "$path" '["engine/mac-autopilot/scheduler.d/models.sh",$path]')"
  PR_CI_ROLLUP="$(ci_rollup)"
  : > "$fixture/prelude-calls"
  merge_pr_scheduler_prelude_ok 17 || fail "CI suite-selection file $path stopped the local prelude"
  [[ -s "$fixture/prelude-calls" ]] || fail "CI suite-selection file $path incorrectly skipped the prelude"
done

# A real prelude timeout reports its exit code and the 300-second bound.
(
  source "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh"
  merge_pr_root() { printf '%s\n' "$repo"; }
  timeout() { return 124; }
  PR_CI_ROLLUP='[]'
  PR_FILES='["engine/mac-autopilot/scheduler.d/models.sh"]'
  git -C "$repo" remote add origin "$repo"
  git -C "$repo" update-ref refs/pull/17/head "$sha"
  if merge_pr_scheduler_prelude_ok 17 >"$fixture/check-output" 2>&1; then fail 'a timed-out prelude did not refuse the merge'; fi
  [[ "$(cat "$fixture/check-output")" == *'scheduler.test.sh prelude failed rc=124 (timeout 300s):'* ]] || fail "prelude refusal lost its rc or timeout: $(cat "$fixture/check-output")"
  git -C "$repo" remote remove origin
)

# A gate file waits for its suites; other files keep merging on pending checks.
PR_CHECKS='[{"name":"cla","bucket":"pass"},{"name":"suites (0)","bucket":"pending"}]' PR_FILES='["tools/merge-pr.sh"]'
: > "$fixture/gh-calls"
if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then fail 'a gate file merged with pending suites'; fi
[[ "$(cat "$fixture/check-output")" == *'gate file tools/merge-pr.sh waits for PR CI: suites (0)'* ]] || fail "gate refusal lost its reason: $(cat "$fixture/check-output")"
PR_CHECKS='[{"name":"cla","bucket":"pass"}]'
if merge_pr_gate_ci_ok 17 "$PR_CHECKS" >"$fixture/check-output" 2>&1; then fail 'a gate file merged before its suites started'; fi
PR_CHECKS='[{"name":"suites (0)","bucket":"cancel"}]'
if merge_pr_gate_ci_ok 17 "$PR_CHECKS" >"$fixture/check-output" 2>&1; then fail 'a gate file merged on cancelled suites'; fi
PR_CHECKS='[{"name":"suites (0)","bucket":"pass"}]'
merge_pr_gate_ci_ok 17 "$PR_CHECKS" || fail 'a gate file with green suites was refused'
PR_CHECKS='[{"name":"suites (0)","bucket":"pending"}]' PR_FILES='["tools/quick-land.sh"]'
merge_pr_gate_ci_ok 17 "$PR_CHECKS" || fail 'a non-gate file waited for pending suites'
for preserved in engine/worktree-lifecycle.sh engine/mac-autopilot/rescued_gc.sh engine/mac-autopilot/scheduler.d/cleanup.sh engine/mac-autopilot/scheduler.d/units.sh; do
  PR_FILES="[\"$preserved\"]"
  if merge_pr_gate_ci_ok 17 "$PR_CHECKS" >"$fixture/check-output" 2>&1; then fail "$preserved merged with pending suites"; fi
done
# Ruling zenoforge-limited-allow-research-first-2026-11-05: a review rule file and a credential loader wait for PR CI too.
for guarded in engine/mac-autopilot/scheduler.d/review-rules.sh engine/night/acceptance-login-probe.mjs; do
  PR_FILES="[\"$guarded\"]"
  if merge_pr_gate_ci_ok 17 '[{"name":"suites (0)","bucket":"pending"}]' >"$fixture/check-output" 2>&1; then fail "$guarded merged with pending suites"; fi
done
PR_FILES='["tools/merge-pr.sh"]'
ZF_MERGE_OVERRIDE=gate-ci merge_pr_gate_ci_ok 17 "$PR_CHECKS" || fail 'the gate-ci override was ignored'

# A PR that deletes or renames away an engine test suite is refused; a pure move, a modify or a non-engine test passes.
expect_suite() {
  local label="$1" statuses="$2" verdict="$3" out
  PR_FILE_STATUSES="$statuses"
  if out="$(merge_pr_suite_delete_ok 17 2>&1)"; then
    [[ "$verdict" == pass ]] || fail "$label was not refused"
  else
    [[ "$verdict" == refuse ]] || fail "$label refused: $out"
    [[ "$out" == *"$4"* ]] || fail "$label refusal lost its file: $out"
  fi
}
expect_suite 'removed suite' '[{"filename":"engine/old.test.sh","status":"removed","changes":9}]' refuse 'engine/old.test.sh'
expect_suite 'renamed suite with edits' '[{"filename":"engine/new.test.sh","previous_filename":"engine/old.test.sh","status":"renamed","changes":2}]' refuse 'engine/old.test.sh'
expect_suite 'renamed suite out of engine' '[{"filename":"tools/new.test.sh","previous_filename":"engine/old.test.sh","status":"renamed","changes":0}]' refuse 'engine/old.test.sh'
expect_suite 'pure suite move' '[{"filename":"engine/new.test.sh","previous_filename":"engine/old.test.sh","status":"renamed","changes":0}]' pass
expect_suite 'modified suite' '[{"filename":"engine/old.test.sh","status":"modified","changes":4}]' pass
expect_suite 'removed non-engine test' '[{"filename":"tools/old.test.sh","status":"removed","changes":3}]' pass
expect_suite 'removed engine script' '[{"filename":"engine/old.sh","status":"removed","changes":3}]' pass
PR_FILE_STATUSES='[]'

# A silent revert: removed lines that a PR merged in the last 24 h added to the same file are refused unless the title or body says revert. A failed read warns and passes.
expect_revert() {
  local label="$1" verdict="$2" must="$3" out
  if out="$(merge_pr_revert_ok 17 2>&1)"; then
    [[ "$verdict" == pass ]] || fail "$label was not refused"
  else
    [[ "$verdict" == refuse ]] || fail "$label refused: $out"
  fi
  [[ "$out" == *"$must"* ]] || fail "$label output lacks '$must': $out"
}
rem() { for i in "$@"; do printf -- '-alpha %s\n' "$i"; done; }
add_all() { for i in one two three four five six seven eight nine ten eleven twelve; do printf '+alpha %s\n' "$i"; done; }
recent="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
PR_LIST="$(jq -cn --arg recent "$recent" '[{number:640,merged_at:$recent},{number:17,merged_at:null}]')"
PR_FILES_BY_PR="$(jq -cn --arg a "$(add_all)" '{"640":[{filename:"engine/a.sh",status:"modified",patch:$a}]}')"
PR_FILE_STATUSES="$(jq -cn --arg p "$(rem one two three four five six)" '[{filename:"engine/a.sh",status:"modified",patch:$p}]')"
expect_revert 'silent revert of a 24 h merge' refuse 'engine/a.sh'
expect_revert 'silent revert names the merged PR' refuse '#640'
PR_FILE_STATUSES="$(jq -cn --arg p "$(rem one two three four five)" '[{filename:"engine/a.sh",status:"modified",patch:$p}]')"
expect_revert 'five removed lines under half of the merged PR' pass ''
PR_FILE_STATUSES="$(jq -cn --arg p "$(rem one two)" '[{filename:"engine/a.sh",status:"modified",patch:$p}]')"
expect_revert 'normal edit of the same file' pass ''
PR_FILE_STATUSES="$(jq -cn --arg p "$(rem one two three four five six)" '[{filename:"engine/a.sh",status:"modified",patch:$p}]')"
PR_META='{"title":"Revert #640: dashboard mail age","body":""}' expect_revert 'stated revert in the title' pass ''
PR_META='{"title":"fixture","body":"This reverts #640 on purpose."}' expect_revert 'stated revert in the body' pass ''
PR_META='{"title":"fixture","body":""}'
PR_LIST="$(jq -cn --arg old "$old" '[{number:600,merged_at:$old}]')"
expect_revert 'merge older than 24 h' pass ''
PR_LIST="$(jq -cn --arg recent "$recent" '[{number:640,merged_at:$recent}]')"
PR_LIST_ERROR=1 expect_revert 'failed merged-PR list warns and passes' pass 'could not list merged PRs'
PR_LIST_ERROR=''
PR_META_ERROR=1 expect_revert 'failed PR read warns and passes' pass 'could not read PR #17'
PR_META_ERROR=''
PR_FILE_STATUSES='[]' PR_FILES_BY_PR='{}' PR_LIST='[]'

echo 'PASS merge helper enforces the full-gate SHA, refuses failed or unreadable checks, allows pending checks, applies exact named overrides, requires a prior-art section unless test-only or overridden, requires a green test receipt for the PR head unless the PR is Markdown-only, and refuses a silent revert of a recent merge unless it is stated'
# Override merge check: a PR that changes an overridden engine file must merge cleanly into the target's pack copy, as the pin will do (#643 stopped every pin).
ov_dir="$fixture/override"
mkdir -p "$ov_dir"
git init -q --bare -b main "$ov_dir/engine-origin.git"
git init -q --bare -b main "$ov_dir/target-origin.git"
git -C "$repo" remote add origin "$ov_dir/engine-origin.git"
numbered() { seq -f 'line %g' 1 12; }
edit_line() { numbered | sed "$1s/\$/ $2/"; } # numbered with ' <text>' appended to line N
mkdir -p "$repo/engine/state"
numbered > "$repo/engine/state/rulings.json"
numbered > "$repo/engine/dispatch-queue.sh"
git -C "$repo" add engine
git -C "$repo" commit -qm 'override base'
base_blob="$(git -C "$repo" rev-parse HEAD:engine/state/rulings.json)"
push_pr_head() { # rulings text, dispatch text: commit the PR head on top of the base and publish it as the PR ref
  printf '%s\n' "$1" > "$repo/engine/state/rulings.json"
  printf '%s\n' "$2" > "$repo/engine/dispatch-queue.sh"
  git -C "$repo" commit -qam 'pr head'
  git -C "$repo" push -q -f origin HEAD:refs/pull/17/head
  git -C "$repo" reset -q --hard HEAD^
}
export AGENT_HOME="$ov_dir/agent"
mkdir -p "$AGENT_HOME"
git clone -q "$ov_dir/target-origin.git" "$AGENT_HOME/checkout" 2>/dev/null
tgt="$AGENT_HOME/checkout"
git -C "$tgt" config user.name t
git -C "$tgt" config user.email t@example.invalid
pack_dir=.zenoforge/build/pack/scripts/agent
mkdir -p "$tgt/$pack_dir/state" "$tgt/.zenoforge/build"
edit_line 5 'pack' > "$tgt/$pack_dir/state/rulings.json"
edit_line 2 'pack' > "$tgt/$pack_dir/dispatch-queue.sh"
printf '{"hook":".zenoforge/build/hook.sh","engine":"%s"}\n' "$(printf 'a%.0s' $(seq 40))" > "$tgt/.zenoforge/build.json"
printf '# path\tbase\nstate/rulings.json\t%s\ndispatch-queue.sh\t%s\n' "$base_blob" "$(git -C "$repo" rev-parse HEAD:engine/dispatch-queue.sh)" > "$tgt/.zenoforge/build/overrides.tsv"
git -C "$tgt" add -A
git -C "$tgt" commit -qm pack
git -C "$tgt" push -q origin HEAD:main
files_json() { jq -cn --args '[$ARGS.positional[] | {filename:., status:"modified"}]' -- "$@"; }
expect_override() { # label verdict(pass|refuse) expected-text
  local out
  if out="$(merge_pr_override_ok 17 2>&1)"; then
    [[ "$2" == pass ]] || fail "$1 was not refused"
  else
    [[ "$2" == refuse ]] || fail "$1 refused: $out"
    [[ "$out" == *"refusing to merge PR #17: "*"$3"* ]] || fail "$1 wrong refusal: $out"
  fi
}
PR_FILE_STATUSES="$(files_json engine/state/rulings.json)"
push_pr_head "$(edit_line 5 'pr')" "$(numbered)"
expect_override 'rulings conflict' refuse 'override state/rulings.json: three-way merge conflicts (1 hunk(s))'
[[ "$(merge_pr_override_ok 17 2>&1)" == *'pin would refuse'* ]] || fail 'conflict refusal does not say the pin would refuse'
push_pr_head "$(edit_line 10 'pr')" "$(numbered)"
expect_override 'clean rulings merge' pass
PR_FILE_STATUSES="$(files_json engine/dispatch-queue.sh)"
push_pr_head "$(numbered)" "$(edit_line 9 'pr')"
expect_override 'clean live-scheduler-file merge' pass
PR_FILE_STATUSES="$(files_json engine/other.sh tools/quick-land.sh)"
push_pr_head "$(edit_line 5 'pr')" "$(edit_line 2 'pr')"
expect_override 'engine file with no override row' pass
PR_FILE_STATUSES="$(files_json engine/state/rulings.json)"
push_pr_head "$(edit_line 5 'pr')" "$(numbered)"
PR_FILE_STATUSES="$(files_json tools/quick-land.sh)"
AGENT_HOME="$ov_dir/missing" expect_override 'PR with no engine file reads no target' pass
PR_FILE_STATUSES="$(files_json engine/state/rulings.json)"
AGENT_HOME="$ov_dir/missing" expect_override 'unreadable target' refuse 'could not read the target'
# A hand merge from a session has no AGENT_HOME: the check must find the same default checkout as auto-pin.
(unset AGENT_HOME ZF_HOME; HOME="$ov_dir/default-home"; mkdir -p "$HOME/.vecta-agent"; ln -s "$tgt" "$HOME/.vecta-agent/checkout"; export HOME; expect_override 'no AGENT_HOME reads the default checkout' refuse 'override state/rulings.json')
[[ "$(ZF_MERGE_OVERRIDE=override-merge AGENT_HOME="$ov_dir/missing" merge_pr_override_ok 17 2>&1)" == *'skips the override merge check'* ]] || fail 'override-merge did not skip and log'
PR_FILE_STATUSES='[{"filename":"engine/state/rulings.json","status":"removed"}]'
git -C "$repo" rm -q engine/state/rulings.json
git -C "$repo" commit -qm 'pr removes the file'
git -C "$repo" push -q -f origin HEAD:refs/pull/17/head
git -C "$repo" reset -q --hard HEAD^
expect_override 'removed overridden file' refuse 'removes or moves engine/state/rulings.json'
push_pr_head "$(edit_line 5 'pr')" "$(numbered)"
PR_FILE_STATUSES="$(files_json engine/state/rulings.json)" PR_FILES='["engine/state/rulings.json"]' PR_HEAD="$sha" PR_CHECKS='[]' PR_BODY=$'## prior-art\nno external prior art: test fixture'
: > "$fixture/gh-calls"
if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then fail 'an override conflict reached merge'; fi
[[ "$(cat "$fixture/check-output")" == *'three-way merge conflicts (1 hunk(s))'* ]] || fail "wired refusal lost its reason: $(cat "$fixture/check-output")"
! grep -q '^merge:' "$fixture/gh-calls" || fail 'an override conflict still merged'
PR_FILE_STATUSES='[]'

echo 'PASS merge helper enforces the full-gate SHA, refuses failed or unreadable checks, allows pending checks, applies exact named overrides, requires a prior-art section unless test-only or overridden, and requires a green test receipt for the PR head unless the PR is Markdown-only'
