#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$TMPDIR/pipeline-system-close-evidence"
repo="$tmp/repo"
queue="$tmp/land-queue"
ticket=00000000000000001989
mkdir -p "$repo" "$queue/requests"
trap 'rm -rf -- "$tmp"' EXIT

assert_true() {
  local description="$1"
  shift
  if "$@"; then echo "ok - $description"; else echo "not ok - $description" >&2; exit 1; fi
}

assert_false() {
  local description="$1"
  shift
  if "$@"; then echo "not ok - $description" >&2; exit 1; else echo "ok - $description"; fi
}

git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm '[skip ci] fix(agent): issue 1988 separate operation'
other_issue_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty \
  -m '[skip ci] chore: record production evidence for issue 1989' \
  -m 'issue 1989; accepted production evidence: issuecomment-6015295341; release=4b7c032e0e5b5a7a554ede29da42f7e81d761eba'
linked_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$linked_sha"
mkdir -p "$repo/.zenoforge/state"
printf '{"rulings":[{"id":"nonproduct-lane-routing","membership":{"labels":["config-lane"]}}]}\n' \
  > "$repo/.zenoforge/state/rulings.json"
export ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"
[[ "$(pipeline_system_issue_labels_json)" == '["config-lane"]' ]] \
  || { echo 'pipeline-system-close-evidence.test.sh: target rulings config did not win' >&2; exit 1; }

source_close_at="$(date -u -d '2026-09-18T22:12:34Z' +%s)"
mkdir -p "$repo/docs/intent"
printf 'intent\n' > "$repo/docs/intent/example.md"
git -C "$repo" add docs/intent/example.md
GIT_AUTHOR_DATE='2026-09-18T22:12:27Z' GIT_COMMITTER_DATE='2026-09-18T22:12:27Z' \
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'docs: close docs-only issue 1340'
source_close_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$source_close_sha"
source_close_comment="$(jq -cn --arg sha "$source_close_sha" '[{user:{login:"testmaintainer"},body:("<!-- vecta-source-close-evidence issue=1340 sha=" + $sha + " -->")}]')"
assert_true 'maintainer source marker accepts merged docs-only closure evidence' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$source_close_comment" testmaintainer \
    "$source_close_at" "$(date +%s)"
wrong_source_owner="$(jq -c '.[0].user.login="intruder"' <<< "$source_close_comment")"
assert_false 'source-only closure marker requires trusted issue owner' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$wrong_source_owner" testmaintainer \
    "$source_close_at" "$(date +%s)"
wrong_source_issue="$(jq -c '.[0].body |= sub("issue=1340"; "issue=1341")' <<< "$source_close_comment")"
assert_false 'source-only closure marker must name same issue' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$wrong_source_issue" testmaintainer \
    "$source_close_at" "$(date +%s)"
mkdir -p "$repo/src"
printf 'product\n' > "$repo/src/product.ts"
GIT_AUTHOR_DATE='2026-09-18T22:12:28Z' GIT_COMMITTER_DATE='2026-09-18T22:12:28Z' \
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid add src/product.ts
GIT_AUTHOR_DATE='2026-09-18T22:12:28Z' GIT_COMMITTER_DATE='2026-09-18T22:12:28Z' \
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m 'fix: product change issue 1340'
product_source_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$product_source_sha"
product_source_comment="$(jq -cn --arg sha "$product_source_sha" '[{user:{login:"testmaintainer"},body:("<!-- vecta-source-close-evidence issue=1340 sha=" + $sha + " -->")}]')"
assert_false 'source-only closure marker rejects product paths' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$product_source_comment" testmaintainer \
    "$source_close_at" "$(date +%s)"

assert_true 'empty issue-linked main SHA proves operation-only ticket' \
  pipeline_system_close_comment_valid "$repo" 1989 "结案：production evidence commit $linked_sha"
completed_comment="已完成 1989：修复提交 \`$linked_sha\` 已在主线"
assert_true 'same-issue completion comment classifies its issue-linked main SHA' \
  pipeline_system_close_comment_valid "$repo" 1989 "$completed_comment"
assert_true 'conclude-guard accepts same-issue completion evidence' \
  issue_closure_evidence_valid "$repo" 1989 pipeline-system '[]' '' \
    "$(date +%s)" "$(date +%s)" "$completed_comment"
assert_false 'completion comment for another issue cannot classify this close' \
  pipeline_system_close_comment_valid "$repo" 1989 "已完成 1988：修复提交 \`$linked_sha\` 已在主线"
assert_false 'completion issue number must end at an identifier boundary' \
  pipeline_system_close_comment_valid "$repo" 1989 "已完成 19890：修复提交 \`$linked_sha\` 已在主线"
assert_false 'different issue SHA is rejected' \
  pipeline_system_close_comment_valid "$repo" 1989 "结案：production evidence commit $other_issue_sha"

jq -n --arg ticket "$ticket" --arg sha "$other_issue_sha" \
  '{ticket:$ticket,owner:"hand-1989",owned_issues:"1989",state:"landed",landed_sha:$sha,post_land_verdict:{outcome:"green"}}' \
  > "$queue/requests/$ticket.json"
assert_false 'queue ownership cannot replace exact issue reference in commit' \
  env AGENT_HOME="$queue" ZF_LAND_QUEUE_DIR="$queue" \
  bash -c 'source "$1/lib.sh"; pipeline_system_close_comment_valid "$2" 1989 "$3"' \
    _ "$SCRIPT_DIR" "$repo" "结案：land-queue ticket=$ticket sha=$other_issue_sha"

git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -qm '[skip ci] chore: another issue 1989 evidence'
unpublished_sha="$(git -C "$repo" rev-parse HEAD)"
assert_false 'issue-linked commit outside origin/main is rejected' \
  pipeline_system_close_comment_valid "$repo" 1989 "结案：production evidence commit $unpublished_sha"
pinned_probe_sha="$product_source_sha"
git -C "$repo" update-ref refs/remotes/origin/main "$unpublished_sha"
late_main_comment="结案：production evidence commit $unpublished_sha"
assert_true 'un-pinned evidence sees the current main commit' \
  pipeline_system_close_comment_valid "$repo" 1989 "$late_main_comment"
assert_false 'pinned evidence ignores main commits newer than the captured probe SHA' \
  pipeline_system_close_comment_valid "$repo" 1989 "$late_main_comment" false "$pinned_probe_sha"
assert_true 'shared close predicate sees current main without a probe SHA' \
  issue_closure_evidence_valid "$repo" 1989 pipeline-system '[]' '' \
    "$(date +%s)" "$(date +%s)" "$late_main_comment"
assert_false 'shared close predicate stays pinned when main advances mid-probe' \
  issue_closure_evidence_valid "$repo" 1989 pipeline-system '[]' '' \
    "$(date +%s)" "$(date +%s)" "$late_main_comment" '' "$pinned_probe_sha"
assert_true 'un-pinned source closure sees current main' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$source_close_comment" testmaintainer \
    "$source_close_at" "$(date +%s)"
assert_false 'source closure also stays pinned to the captured probe SHA' \
  issue_closure_evidence_valid "$repo" 1340 concluded "$source_close_comment" testmaintainer \
    "$source_close_at" "$(date +%s)" '' '' "$other_issue_sha"
export ZF_LAND_QUEUE_DIR="$queue"
legacy_closed_at="$(date +%s)"
legacy_queue_comment="结案：land-queue ticket=$ticket sha=$other_issue_sha"
assert_true 'closed-issue audit accepts exact landed queue evidence for its owner issue' \
  issue_closure_evidence_valid "$repo" 1989 pipeline-system '[]' '' \
    "$legacy_closed_at" "$legacy_closed_at" "$legacy_queue_comment"
assert_false 'legacy queue evidence cannot authorize a new close' \
  issue_closure_evidence_valid "$repo" 1989 pipeline-system '[]' '' 0 "$legacy_closed_at" "$legacy_queue_comment"
assert_false 'legacy queue owner mapping cannot prove another issue' \
  issue_closure_evidence_valid "$repo" 198 pipeline-system '[]' '' \
    "$legacy_closed_at" "$legacy_closed_at" "$legacy_queue_comment"

external_sha=292d7ba0ec68b00a886f2d279898c4426eda5ca9
external_issue=3034
external_repo=example-org/example-infra
external_body="Refs example-maintainer/example-repo#$external_issue"
external_default_branch=main
external_gh_failure=''
external_pr_json=''
external_calls="$tmp/external-gh-calls"
gh() {
  printf '%s\n' "$*" >> "$external_calls"
  case "$1 $2" in
    'issue view')
      [[ "$3" == "$external_issue" ]] || return 91
      printf '%s\n' "$(jq -cn --argjson issue "$external_issue" '{number:$issue,state:"OPEN",labels:[{name:"pipeline-system"}]}')"
      ;;
    'repo view')
      [[ "$3" == "$external_repo" ]] || return 91
      [[ "$external_gh_failure" != repo ]] || return 1
      printf '%s\n' "$external_default_branch"
      ;;
    'pr view')
      [[ "$4" == --repo && "$5" == "$external_repo" ]] || return 91
      [[ "$external_gh_failure" != pr ]] || return 1
      printf '%s\n' "$external_pr_json"
      ;;
    *) return 91 ;;
  esac
}
external_pr_json="$(jq -cn --arg body "$external_body" --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"main",mergeCommit:{oid:$sha},body:$body}')"
external_comment="结案 (closing): delivered in example-infra PR 113, merged as example-org/example-infra@$external_sha."
if git -C "$repo" cat-file -e "$external_sha^{commit}" >/dev/null 2>&1; then
  echo 'not ok - external merge SHA unexpectedly exists in the product checkout fixture' >&2
  exit 1
else
  echo 'ok - external merge SHA is absent from the the product checkout fixture'
fi
assert_true 'allowlisted external PR merge proves its linked issue without local ancestry' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"
external_closed_at="$(date -u -d '2026-10-11T09:07:16Z' +%s)"
assert_true '#3034 external PR evidence passes the shared conclude-guard predicate' \
  issue_closure_evidence_valid "$repo" "$external_issue" pipeline-system '[]' '' \
    "$external_closed_at" "$(date +%s)" "$external_comment"

external_calls="$tmp/rejected-repo-gh-calls"
assert_false 'unconfigured external repository is rejected' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" \
    "结案：Other/repo PR 113 merged as Other/repo@$external_sha"
[[ ! -s "$external_calls" ]] || { echo 'not ok - unconfigured repository reached GitHub' >&2; exit 1; }

external_pr_json="$(jq -cn --arg body "$external_body" --arg sha "$external_sha" \
  '{number:113,state:"OPEN",mergedAt:null,baseRefName:"main",mergeCommit:{oid:$sha},body:$body}')"
assert_false 'unmerged external PR is rejected' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_pr_json="$(jq -cn --arg body "$external_body" --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"main",mergeCommit:{oid:$sha},body:$body}')"
wrong_external_sha=abcdef0123456789abcdef0123456789abcdef01
assert_false 'external merge SHA must equal PR merge commit' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" \
    "结案：example-infra PR 113 merged as example-org/example-infra@$wrong_external_sha"
assert_false 'external PR number must match queried PR metadata' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" \
    "结案：example-infra PR 114 merged as example-org/example-infra@$external_sha"

external_pr_json="$(jq -cn --arg body "$external_body" --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"release",mergeCommit:{oid:$sha},body:$body}')"
assert_false 'external PR must target configured repository default branch' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_pr_json="$(jq -cn --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"main",mergeCommit:{oid:$sha},body:"Refs example-maintainer/example-repo#1990"}')"
assert_false 'external PR must reference the issue being closed' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_gh_failure=pr
assert_false 'external PR read failure fails closed' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_gh_failure=repo
assert_false 'external default-branch read failure fails closed' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_gh_failure=''
external_pr_json="$(jq -cn --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"main",mergeCommit:{oid:$sha},body:"Refs example-maintainer/example-repo#3034x"}')"
assert_false 'issue reference must end at identifier boundary' \
  pipeline_system_close_comment_valid "$repo" "$external_issue" "$external_comment"

external_pr_json="$(jq -cn --arg body "$external_body" --arg sha "$external_sha" \
  '{number:113,state:"MERGED",mergedAt:"2026-10-11T09:07:16Z",baseRefName:"main",mergeCommit:{oid:$sha},body:$body}')"
external_finish_log="$tmp/external-finish.log"
REPO=example-maintainer/example-repo
guarded_write() { printf 'write:%s\n' "$*" >> "$external_finish_log"; }
issue_transition() { printf 'transition:%s:%s:%s\n' "$1" "$2" "$3" >> "$external_finish_log"; }
assert_true 'external factory landing closes its pipeline issue using validated merge SHA' \
  pipeline_system_finish_external_landing "$repo" "$external_issue" 113 "$external_sha"
assert_true 'external close writes the the product issue closed with merge evidence' \
  grep -Fq -- "write:gh issue close $external_issue --repo $REPO --reason completed --comment 结案：delivered in $external_repo PR 113, merged as $external_repo@$external_sha." "$external_finish_log"
assert_true 'external close records concluded state and cross-repo SHA' \
  grep -Fq -- 'transition:3034:concluded:close-external-factory-pr' "$external_finish_log"
: > "$external_finish_log"
assert_false 'external landing rejects a mismatched merge SHA before closing issue' \
  pipeline_system_finish_external_landing "$repo" "$external_issue" 113 "$wrong_external_sha"
assert_false 'invalid external merge evidence causes no issue write' test -s "$external_finish_log"

echo 'PASS: 32 closure-evidence assertions'
