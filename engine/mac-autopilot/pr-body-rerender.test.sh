#!/usr/bin/env bash
# The PR body is derived from the unit's report (PR 5650, 2026-11-08): a report that gains ## prior-art after the PR opened must reach the
# body through one gh pr edit before the next review or merge, and an unchanged report must cost no edit.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "pr-body-rerender.test.sh: $*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }

fixture="$test_env_root/pr-body-rerender"
origin="$fixture/origin.git"
WT_ROOT="$fixture/worktrees"
GH_CALLS="$fixture/gh-calls"
mkdir -p "$fixture" "$WT_ROOT"
command git init -q --bare -b main "$origin"
command git clone -q "$origin" "$WT_ROOT/wt-body-1" 2>/dev/null
command git -C "$WT_ROOT/wt-body-1" config user.email t@example.invalid
command git -C "$WT_ROOT/wt-body-1" config user.name t
printf 'base\n' > "$WT_ROOT/wt-body-1/f.txt"
command git -C "$WT_ROOT/wt-body-1" add -A
command git -C "$WT_ROOT/wt-body-1" commit -qm base
command git -C "$WT_ROOT/wt-body-1" push -q origin HEAD:main
command git -C "$WT_ROOT/wt-body-1" checkout -q -b agent/body-1
printf 'work\n' > "$WT_ROOT/wt-body-1/g.txt"
command git -C "$WT_ROOT/wt-body-1" add -A
command git -C "$WT_ROOT/wt-body-1" commit -qm work
command git -C "$WT_ROOT/wt-body-1" push -q origin agent/body-1

GH_BODY=''
gh() {
  case "$1 $2" in
    'pr list') ;;
    'pr view') printf '%s' "$GH_BODY" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; echo 'https://github.com/example/repo/pull/4500' ;;
    'pr edit')
      printf 'pr edit %s\n' "$3" >> "$GH_CALLS"
      [[ "$4" == --body-file ]] && cp "$5" "$fixture/edited-body"
      ;;
    *) return 0 ;;
  esac
}
edits() { grep -c '^pr edit' "$GH_CALLS" || true; }

printf '%s\n' '## root-cause' 'a' > "$sup/impl-body-1.md"
echo '{"units":[{"id":"body-1","issue":1100,"title":"body","branch":"agent/body-1","lane":"pr","stage":"implement","history":[]}]}' > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"
: > "$GH_CALLS"
harvest_pr_implement body-1 "$sup/impl-body-1.md" || :
[[ "$(field body-1 .pr)" == 4500 && "$(field body-1 .pr_body_hash)" =~ ^[0-9a-f]{64}$ ]] || fail 'the opened PR did not store the body hash'

# Unchanged report: no edit before a review or a merge.
set_unit body-1 '.implementation_report="impl-body-1.md"'
pr_body_refresh "$(jq -c '.units[0]' "$UNITS")"
[[ "$(edits)" == 0 ]] || fail 'an unchanged report edited the PR body'

# The report gains ## prior-art: one edit carrying it, hash stored, a second call is quiet.
printf '%s\n' '## root-cause' 'a' '## prior-art' 'https://example.com/x' > "$sup/impl-body-1.md"
pr_body_refresh "$(jq -c '.units[0]' "$UNITS")"
[[ "$(edits)" == 1 && "$(grep -c '^pr edit 4500$' "$GH_CALLS")" == 1 ]] || fail 'a changed report did not edit PR 4500 once'
grep -qx '## prior-art' "$fixture/edited-body" || fail 'the edited body lacks ## prior-art'
grep -q '^Refs #1100' "$fixture/edited-body" || fail 'the edited body lost the Refs line'
pr_body_refresh "$(jq -c '.units[0]' "$UNITS")"
[[ "$(edits)" == 1 ]] || fail 'the stored hash did not stop a second edit'

# Before the review dispatch: dispatch_if_room refreshes through the same function.
printf '%s\n' '## root-cause' 'a' '## prior-art' 'https://example.com/y' > "$sup/impl-body-1.md"
room_for() { return 0; }; dispatch() { return 1; } # stop after the refresh: no worker starts
dispatch_if_room body-1 review-pending review log.md rep.md model high "prompt" "" "" "" "" "$(jq -c '.units[0]' "$UNITS")" || :
[[ "$(edits)" == 2 ]] || fail 'the review dispatch did not refresh the body'

# A legacy unit (no stored hash) keeps its body: only the sections it lacks are appended, from the report, hand text verbatim.
printf '%s\n' '## root-cause' 'rc text' '## recurrence-guard' 'guard text' '## prior-art' 'https://example.com/z' 'more art' '## blast-radius' 'not appended' > "$sup/impl-body-1.md"
set_unit body-1 'del(.pr_body_hash)'
GH_BODY=$'HAND EDIT KEEP\n\n## root-cause\nhand rc\n\n## recurrence-guard\nhand guard'
pr_body_refresh "$(jq -c '.units[0]' "$UNITS")"
[[ "$(edits)" == 3 ]] || fail 'a legacy body lacking prior-art was not edited once'
grep -qx 'HAND EDIT KEEP' "$fixture/edited-body" && grep -qx 'hand guard' "$fixture/edited-body" || fail 'the legacy edit lost the hand-written text'
[[ "$(grep -c '^## root-cause' "$fixture/edited-body")" == 1 && "$(grep -c '^## prior-art' "$fixture/edited-body")" == 1 ]] || fail 'the legacy edit repeated or missed a section'
grep -qx 'more art' "$fixture/edited-body" && ! grep -q 'not appended' "$fixture/edited-body" || fail 'the appended section does not run exactly to the next ## heading'
[[ "$(field body-1 .pr_body_hash)" =~ ^[0-9a-f]{64}$ ]] || fail 'the legacy append did not store the hash'
# A legacy body that has all three gets no edit, and the hash is stored.
set_unit body-1 'del(.pr_body_hash)'
GH_BODY=$'## root-cause\nx\n## recurrence-guard\ny\n## prior-art\nz'
pr_body_refresh "$(jq -c '.units[0]' "$UNITS")"
[[ "$(edits)" == 3 && "$(field body-1 .pr_body_hash)" =~ ^[0-9a-f]{64}$ ]] || fail 'a complete legacy body was edited or left without a hash'
echo 'pr-body-rerender.test.sh: ok'
