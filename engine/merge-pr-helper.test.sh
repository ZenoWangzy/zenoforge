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
PR_BODY=$'## prior-art\nFollows required status checks: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches\n'
PR_FILES='["tools/quick-land.sh"]'
gh() {
  case "$1 $2" in
    'pr view')
      printf 'view:%s\n' "$*" >> "$fixture/gh-calls"
      if [[ "$*" == *body,files* ]]; then
        [[ "$PR_BODY" != gh-error ]] || return 1
        jq -cn --arg body "$PR_BODY" --argjson files "$PR_FILES" --arg at "${PR_HEAD_DATE:-}" \
          '{body:$body,files:($files | map({path:.})),commits:(if $at == "" then [] else [{committedDate:$at}] end)}'
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
    'run list')
      printf '[{"databaseId":7,"status":"queued"},{"databaseId":8,"status":"completed"}]\n'
      ;;
    'run cancel')
      printf '%s\n' "$3" >> "$fixture/cancelled"
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
[[ "$(cat "$fixture/gh-calls")" == $'view:pr view 17 --json headRefOid\nchecks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nmerge:pr merge 17 --squash --delete-branch\nview:pr view 17 --json headRefOid' ]] \
  || fail "green matching result did not squash merge: $(cat "$fixture/gh-calls")"

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"unit","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
if ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then
  fail 'override for one failed check also allowed an unnamed failed check'
fi
check_output="$(cat "$fixture/check-output")"
[[ "$check_output" == *'failed checks: cla, unit'* && "$check_output" == *'checks without a matching ZF_MERGE_OVERRIDE: unit'* ]] \
  || fail "failed check names or unmatched override were not reported: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits' ]] \
  || fail "an unmatched failed check reached merge: $(cat "$fixture/gh-calls")"

PR_CHECKS='[{"name":"cla","bucket":"fail"},{"name":"CI","bucket":"pending"}]'
: > "$fixture/gh-calls"
check_output="$(ZF_MERGE_OVERRIDE=cla merge_pr_checks_and_merge 17 2>&1)" \
  || fail "named failed-check override did not allow the merge: $check_output"
[[ "$check_output" == *'explicit ZF_MERGE_OVERRIDE allows failed checks: cla'* ]] \
  || fail "merge did not print the failed check covered by its override: $check_output"
[[ "$(cat "$fixture/gh-calls")" == $'checks:pr checks 17 --json bucket,name\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json headRefOid\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nview:pr view 17 --json body,files,commits\nmerge:pr merge 17 --squash --delete-branch\nview:pr view 17 --json headRefOid' ]] \
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
PR_HEAD="$rsha" # no full-suite result exists for this head, so only a receipt can pass
rm -rf "$receipt_dir"
expect_receipt_refusal 'no test receipt' "no test receipt exists for $rsha: run the tests at that HEAD through tools/test-receipt.sh"
mkdir -p "$receipt_dir"
printf '0\tbash engine/quick-land.test.sh\n1\tbash engine/merge-pr-helper.test.sh\n' >"$receipt_dir/$rsha"
expect_receipt_refusal 'failed last run' 'bash engine/merge-pr-helper.test.sh (exit 1)'
printf '0\tbash engine/quick-land.test.sh\n1\tbash engine/merge-pr-helper.test.sh\n0\tbash engine/merge-pr-helper.test.sh\n' >"$receipt_dir/$rsha"
expect_receipt_merge 'later pass of the same command'
printf '1\tbash engine/x.test.sh\nnot-a-receipt-line\n' >"$receipt_dir/$rsha"
expect_receipt_refusal 'malformed receipt line' 'malformed receipt line 2'
rm -f "$receipt_dir/$rsha"
PR_FILES='["docs/notes.md","README.md"]'
expect_receipt_merge 'Markdown-only PR with no receipt'
PR_FILES='["tools/quick-land.sh"]'
PR_HEAD="$sha" # the green full-suite result above proves this head and counts as a receipt

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

# A scheduler change runs the scheduler.test.sh prelude; a red prelude refuses, other changes skip it.
merge_pr_scheduler_prelude() { echo called >> "$fixture/prelude-calls"; echo 'not ok - stale grep'; return 1; }
: > "$fixture/prelude-calls"
PR_CHECKS='[]' PR_FILES='["tools/quick-land.sh"]' PR_BODY=$'## prior-art\nno external prior art: test fixture'
merge_pr_scheduler_prelude_ok 17 || fail 'a non-scheduler PR was refused by the prelude check'
[[ ! -s "$fixture/prelude-calls" ]] || fail 'a non-scheduler PR ran the prelude'
PR_BODY=gh-error
if merge_pr_scheduler_prelude_ok 17 >"$fixture/check-output" 2>&1; then fail 'an unreadable PR skipped the prelude check'; fi
[[ "$(cat "$fixture/check-output")" == *'could not read PR files'* ]] || fail "unreadable PR refusal lost its reason: $(cat "$fixture/check-output")"
PR_BODY=$'## prior-art\nno external prior art: test fixture'
PR_FILES='["engine/mac-autopilot/scheduler.d/models.sh"]'
: > "$fixture/gh-calls"
if merge_pr_checks_and_merge 17 >"$fixture/check-output" 2>&1; then fail 'a red prelude did not refuse the merge'; fi
[[ "$(cat "$fixture/check-output")" == *'prelude failed: not ok - stale grep'* ]] || fail "prelude refusal lost its reason: $(cat "$fixture/check-output")"
! grep -q '^merge:' "$fixture/gh-calls" || fail 'a red prelude still merged'

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
PR_FILES='["tools/merge-pr.sh"]'
ZF_MERGE_OVERRIDE=gate-ci merge_pr_gate_ci_ok 17 "$PR_CHECKS" || fail 'the gate-ci override was ignored'

echo 'PASS merge helper enforces the full-gate SHA, refuses failed or unreadable checks, allows pending checks, applies exact named overrides, requires a prior-art section unless test-only or overridden, and requires a green test receipt for the PR head unless the PR is Markdown-only'
