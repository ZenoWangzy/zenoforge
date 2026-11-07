#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/mac-autopilot/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/merge-tree-sweep"
supervisor="$fixture/supervisor"
root="$fixture/root"
source_repo="$fixture/source"
remote="$fixture/origin.git"
mkdir -p "$supervisor/autopi/alerts" "$fixture"
export MAC_AUTOPILOT_ROOT="$root" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi"
jq '.auto_merge = true' "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { printf 'merge-tree-sweep.test.sh: %s\n' "$*" >&2; exit 1; }
export GIT_AUTHOR_NAME='sweep fixture' GIT_AUTHOR_EMAIL='sweep@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
g() { command git -C "$source_repo" "$@"; }
command git init -q -b main "$source_repo"
printf 'one\ntwo\nthree\n' > "$source_repo/shared.txt"
printf 'a\n' > "$source_repo/other.txt"
g add -A; g commit -qm base
base="$(g rev-parse HEAD)"
branch_from_base() { # branch file content: one commit on top of base
  g checkout -q -b "$1" "$base"; printf '%s\n' "$3" > "$source_repo/$2"; g add -A; g commit -qm "$1"; g checkout -q main
}
branch_from_base agent/issue-801 shared.txt 'pr side'     # conflicts with main
branch_from_base agent/issue-802 other.txt 'b'            # merges clean
for n in 803 804 805 806 807 808 809; do branch_from_base "agent/issue-$n" shared.txt "pr $n"; done
branch_from_base hand/issue-810 shared.txt 'pr 810'
printf 'main side\ntwo\nthree\n' > "$source_repo/shared.txt"; g add -A; g commit -qm main-moves
command git init -q --bare -b main "$remote"
g push -q "$remote" main
command git clone -q "$remote" "$root"
# The PR heads reach the remote only now, so the clone lacks them and the sweep must fetch.
# Only refs/pull/N/head, as on GitHub: the branch names are not on the remote, so a fetch by branch name would find nothing.
for b in $(g for-each-ref --format='%(refname:short)' refs/heads/agent refs/heads/hand); do command git --git-dir="$remote" fetch -q "$source_repo" "$b:refs/pull/${b##*-}/head"; done
head_of() { g rev-parse "$1"; }
MAIN_HEAD="$(command git -C "$root" rev-parse refs/remotes/origin/main)"
SCHED_LOCK_HELD=true
git() { [[ "$*" != *" merge-tree --write-tree "* ]] || echo x >> "$fixture/mt-calls"; command git "$@"; }
mt_calls() { wc -l < "$fixture/mt-calls"; }
gh() { [[ "$1 $2" == 'pr view' ]] && { printf ' %s' "$3" >> "$fixture/gh-views"; printf 'UNKNOWN %s\n' "$(head_of "agent/issue-$3" 2>/dev/null || true)"; return 0; }; return 1; }
tick_prs() { TICK_PRS="$(cat "$fixture/prs.json")"; printf '%s' "$TICK_PRS"; }

# unit rows: id pr branch stage [extra jq object]
census() { # pr:branch:label ...
  local rows=() spec n b l
  for spec in "$@"; do IFS=: read -r n b l <<<"$spec"
    rows+=("$(jq -cn --argjson n "$n" --arg b "$b" --arg h "$(head_of "$b")" --arg l "$l" \
      '{number:$n,headRefOid:$h,headRefName:$b,baseRefName:"main",labels:(if $l == "" then [] else [{name:$l}] end),isDraft:false,mergeable:"UNKNOWN"}')")
  done
  printf '%s\n' "${rows[@]}" | jq -cs . > "$fixture/prs.json"
}
unit() { # id pr stage [extra]
  jq -cn --arg id "$1" --argjson pr "$2" --arg st "$3" --argjson extra "${4:-{\}}" '{id:$id,pr:$pr,issue:$pr,stage:$st,approved_sha:"x",history:[]} + $extra'
}
reset() { # unit json lines...; clears memo, call counters and log
  printf '%s\n' "$@" | jq -cs '{units:.}' > "$UNITS"
  rm -f -- "$A/merge-tree-sweep.json"; : > "$LOG"; : > "$fixture/mt-calls"; : > "$fixture/gh-views"; TICK_PRS=""
}
stage_of() { unit_field "$1" .stage; }

# 1. main moved: the conflicting PR goes to repair through the existing route, the clean one is left alone; 2. an unfetched head is fetched.
census 801:agent/issue-801: 802:agent/issue-802:
reset "$(unit pr-801 801 ready-to-merge)" "$(unit pr-802 802 review-pending)"
command git -C "$root" cat-file -e "$(head_of agent/issue-801)^{commit}" 2>/dev/null && fail 'fixture: the clone must start without the PR heads'
merge_tree_sweep
[[ "$(stage_of pr-801)" == repair-pending && "$(unit_field pr-801 .approved_sha)" == '' ]] || fail 'a PR conflicting with main was not sent to repair'
[[ "$(unit_field pr-801 .merge_sweep_head)" == "$(head_of agent/issue-801)" ]] || fail 'the conflicting head was not recorded for the once-per-head guard'
[[ "$(stage_of pr-802)" == review-pending ]] || fail 'a PR that merges clean was moved'
[[ "$(cat "$fixture/gh-views")" == ' 801' ]] || fail "gh was asked about PRs other than the conflicting one: $(cat "$fixture/gh-views")"

# 3. memo: the same (head, main) is not merged again, and a moved main checks it again.
reset "$(unit pr-802 802 review-pending)"
merge_tree_sweep
[[ "$(mt_calls)" == 1 ]] || fail "first pass made $(mt_calls) merge-tree calls, want 1"
merge_tree_sweep
[[ "$(mt_calls)" == 1 ]] || fail 'an unchanged (head, main) was merged again'
MAIN_HEAD="$(head_of agent/issue-801)"
merge_tree_sweep
[[ "$(mt_calls)" == 2 ]] || fail 'a moved main did not trigger a new check'
MAIN_HEAD="$(command git -C "$root" rev-parse refs/remotes/origin/main)"

# 4. only idle stages: a unit already in repair or in a live review is not touched.
census 801:agent/issue-801:
for st in repair-pending repair review rereview supervisor-review parked; do
  reset "$(unit pr-801 801 "$st")"
  merge_tree_sweep
  [[ "$(stage_of pr-801)" == "$st" && "$(mt_calls)" == 0 ]] || fail "a $st unit was swept"
done

# 5. a head already sent to repair is not sent again when main moves and the unit comes back with the same head.
reset "$(unit pr-801 801 ready-to-merge)"
merge_tree_sweep
[[ "$(stage_of pr-801)" == repair-pending ]] || fail 'precondition: first sweep sends the conflict to repair'
set_unit pr-801 '.stage="review-pending"'
rm -f -- "$A/merge-tree-sweep.json"; : > "$fixture/gh-views"
merge_tree_sweep
[[ "$(stage_of pr-801)" == review-pending && ! -s "$fixture/gh-views" ]] || fail 'the same head was sent to repair twice'

# 6. not the factory's: session-owned label, hand/ branch, supervisor-owned unit, handoff wait.
census 801:agent/issue-801:session-owned
reset "$(unit pr-801 801 ready-to-merge)"; merge_tree_sweep
[[ "$(stage_of pr-801)" == ready-to-merge ]] || fail 'a session-owned PR was repaired'
census 801:agent/issue-801:
reset "$(unit pr-801 801 ready-to-merge '{"supervisor_owned":true}')"; merge_tree_sweep
[[ "$(stage_of pr-801)" == ready-to-merge ]] || fail 'a supervisor-owned unit was repaired'
reset "$(unit pr-801 801 ready-to-merge '{"hold_handoff_waiting":true}')"; merge_tree_sweep
[[ "$(stage_of pr-801)" == ready-to-merge ]] || fail 'a handoff-waiting unit was repaired'
census 810:hand/issue-810:
reset "$(unit pr-810 810 ready-to-merge)"; merge_tree_sweep
[[ "$(stage_of pr-810)" == ready-to-merge ]] || fail 'a hand-owned PR was repaired'

# 7. attempt cap: two repair rounds since the last ruling leave the unit to the cap path.
census 801:agent/issue-801:
reset "$(unit pr-801 801 review-pending '{"history":[{"stage":"repair-delivered"},{"stage":"repair-delivered"}]}')"; merge_tree_sweep
[[ "$(stage_of pr-801)" == review-pending ]] || fail 'a unit at the repair cap was sent to repair again'

# 8. bounded: MERGE_SWEEP_MAX stops the pass, and the memo keeps only open PRs.
census 803:agent/issue-803: 804:agent/issue-804: 805:agent/issue-805:
reset "$(unit pr-803 803 review-pending)" "$(unit pr-804 804 review-pending)" "$(unit pr-805 805 review-pending)" "$(unit pr-806 806 review-pending)"
MERGE_SWEEP_MAX=2 merge_tree_sweep
[[ "$(mt_calls)" == 2 ]] || fail "MERGE_SWEEP_MAX=2 allowed $(mt_calls) checks"
census 803:agent/issue-803: 806:agent/issue-806:
merge_tree_sweep
[[ "$(jq -r 'keys | join(",")' "$A/merge-tree-sweep.json")" == 803,806 ]] || fail 'the memo kept a PR that is no longer open'

printf 'merge-tree-sweep.test.sh: PASS\n'
