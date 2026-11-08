#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/mac-autopilot/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/conflict-resolve"
supervisor="$fixture/supervisor"
root="$fixture/root"
source_repo="$fixture/source"
remote="$fixture/origin.git"
mkdir -p "$supervisor/autopi/alerts" "$fixture"
export MAC_AUTOPILOT_ROOT="$root" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi"
jq --arg wt "$fixture/wt" '.auto_merge = true | .worktree_root = $wt' "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
# The migration directory comes from the target's release.json through lib.sh's config, as the real hook reads it.
mkdir -p "$fixture/config"; printf '{"migration":{"path":"packs/fruit/migrations"}}\n' > "$fixture/config/release.json"
export ZF_CONFIG_ROOT="$fixture/config"
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { printf 'conflict-resolve.test.sh: %s\n' "$*" >&2; exit 1; }
export GIT_AUTHOR_NAME='resolve fixture' GIT_AUTHOR_EMAIL='resolve@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
g() { command git -C "$source_repo" "$@"; }
journal() { # entries as "tag" args, idx from 0
  local i=0 t entries=()
  for t in "$@"; do entries+=("{\"idx\":$i,\"version\":\"7\",\"when\":$((1000 + i)),\"tag\":\"$t\",\"breakpoints\":true}"); i=$((i + 1)); done
  printf '%s\n' "${entries[@]}" | jq -s '{version:"7",dialect:"postgresql",entries:.}'
}
command git init -q -b main "$source_repo"
# The target configures one migration directory (the one its renumber hook owns); a second, root migrations/ journal is not renumbered.
mig=packs/fruit/migrations
mkdir -p "$source_repo/$mig/meta" "$source_repo/migrations/meta" "$source_repo/lessons"
journal 0001_a 0002_b > "$source_repo/$mig/meta/_journal.json"
journal 0001_a 0002_b > "$source_repo/migrations/meta/_journal.json"
echo 'select 1;' > "$source_repo/$mig/0001_a.sql"; echo 'select 2;' > "$source_repo/$mig/0002_b.sql"
echo 'select 1;' > "$source_repo/migrations/0001_a.sql"; echo 'select 2;' > "$source_repo/migrations/0002_b.sql"
printf '# Catalog\n\nApplies: [V1](RULES.md#v1); full: ./full/one.md\n' > "$source_repo/lessons/CATALOG.md"
printf 'one\ntwo\nthree\n' > "$source_repo/shared.txt"
g add -A; g commit -qm base
base="$(g rev-parse HEAD)"
pr_branch() { # branch migration-tag catalog-line shared-line [migration dir]: one commit on top of base; "" skips a file
  local dir="${5:-$mig}"
  g checkout -q -b "$1" "$base"
  if [[ -n "$2" ]]; then
    echo "select '$2';" > "$source_repo/$dir/${2}.sql"
    journal 0001_a 0002_b "$2" > "$source_repo/$dir/meta/_journal.json"
  fi
  [[ -z "$3" ]] || printf '%s\n' "$3" >> "$source_repo/lessons/CATALOG.md"
  [[ -z "$4" ]] || printf '%s\n' "$4" > "$source_repo/shared.txt"
  g add -A; g commit -qm "$1"; g checkout -q main
}
pr_branch agent/issue-901 0003_pr 'Applies: [V9](RULES.md#v9); full: ./full/pr.md' ''   # hot files only
pr_branch agent/issue-902 '' '' 'pr side'                                                 # non-hot conflict
pr_branch agent/issue-903 0003_pr '' 'pr side'                                            # hot and non-hot mixed
pr_branch agent/issue-904 0003_pr 'Applies: [V9](RULES.md#v9); full: ./full/pr.md' ''   # same shape as 901
pr_branch agent/issue-905 0003_pr 'Applies: [V9](RULES.md#v9); full: ./full/pr.md' ''
pr_branch agent/issue-906 0003_pr '' '' migrations                                           # root journal only: not the renumbered directory
# main merged another PR's migration 0003 and catalog line, and edited shared.txt
for d in "$mig" migrations; do
  echo 'select 3;' > "$source_repo/$d/0003_main.sql"
  journal 0001_a 0002_b 0003_main > "$source_repo/$d/meta/_journal.json"
done
printf 'Applies: [V8](RULES.md#v8); full: ./full/main.md\n' >> "$source_repo/lessons/CATALOG.md"
printf 'main side\ntwo\nthree\n' > "$source_repo/shared.txt"
g add -A; g commit -qm main-moves
command git init -q --bare -b main "$remote"
g push -q "$remote" main
command git clone -q "$remote" "$root"
for n in 901 902 903 904 905 906; do
  # As on GitHub: the PR head is on the remote under refs/pull/N/head, and the clone starts without it.
  command git --git-dir="$remote" fetch -q "$source_repo" "agent/issue-$n:refs/heads/agent/issue-$n" "agent/issue-$n:refs/pull/$n/head"
done
head_of() { g rev-parse "agent/issue-$1"; }
remote_head() { command git --git-dir="$remote" rev-parse "refs/heads/agent/issue-$1"; }
MAIN_HEAD="$(command git -C "$root" rev-parse refs/remotes/origin/main)"
SCHED_LOCK_HELD=true
gh() { [[ "$1 $2" == 'pr view' ]] && { printf 'UNKNOWN %s\n' "$(remote_head "$3")"; return 0; }; return 1; }
tick_prs() { :; }

# Stand-in for the pack's renumber hook: move the PR's migration to the number after main's last one, fix the journal, commit.
hook_calls=0 hook_rc=0
conflict_pack_hook() { # dir pr
  local d="$1" tag new n
  hook_calls=$((hook_calls + 1)); (( hook_rc == 0 )) || return 1
  tag="$(jq -r '[.entries[] | select(.tag | endswith("_pr")) | .tag][0]' "$d/$mig/meta/_journal.json")"
  n="$(jq -r '[.entries[] | select(.tag | endswith("_pr") | not) | .tag[0:4] | tonumber] | max' "$d/$mig/meta/_journal.json")"
  new="$(printf '%04d' $((n + 1)))_pr"
  [[ "$tag" == "$new" ]] || {
    git -C "$d" mv "$mig/$tag.sql" "$mig/$new.sql"
    jq --arg o "$tag" --arg n "$new" '(.entries[] | select(.tag == $o)) |= (.tag = $n)' "$d/$mig/meta/_journal.json" > "$d/j" && mv "$d/j" "$d/$mig/meta/_journal.json"
  }
  git -C "$d" add -A && git -C "$d" commit -qm "assign migration number" 2>/dev/null || :
}
ensure_calls=0
real_ensure_clone="$(declare -f ensure_clone)"; eval "${real_ensure_clone/ensure_clone/real_ensure_clone}"
ensure_clone() { ensure_calls=$((ensure_calls + 1)); real_ensure_clone "$@"; }
unit() { # n extra-json: ready-to-merge unit with one earlier merge-conflict unless extra says otherwise
  jq -cn --argjson n "$1" --argjson extra "${2:-{\}}" '{id:"issue-\($n)",pr:$n,issue:$n,branch:"agent/issue-\($n)",stage:"ready-to-merge",approved_sha:"x",
    history:[{stage:"merge-conflict",result:"earlier",at:"2026-11-07T00:00:00Z"}]} + $extra'
}
reset() { printf '%s\n' "$@" | jq -cs '{units:.}' > "$UNITS"; : > "$LOG"; ensure_calls=0; hook_calls=0; hook_rc=0; MERGE_HEAD=""; }
stage_of() { unit_field "issue-$1" .stage; }
conflict() { merge_conflict_to_repair "issue-$1" "$1" 'conflicts with main' 'hint' "$(head_of "$1")"; }
count() { jq -r --arg id "issue-$1" --arg st "$2" '[.units[] | select(.id == $id) | .history[] | select(.stage == $st)] | length' "$UNITS"; }

# 1. Two PRs added migration 0003: the second (a repeat conflict, hot files only) is renumbered and pushed with no repair.
old="$(head_of 901)"
reset "$(unit 901)"
conflict 901
[[ "$(stage_of 901)" == rereview-pending ]] || fail "hot-file repeat conflict was not resolved in place: stage=$(stage_of 901)"
[[ "$(count 901 conflict-auto-resolved)" == 1 && "$(count 901 merge-conflict)" == 1 ]] || fail 'history must hold one conflict-auto-resolved and no new merge-conflict'
[[ "$(unit_field issue-901 .approved_sha)" == '' ]] || fail 'the approval must be cleared: the head changed'
new="$(remote_head 901)"
[[ "$new" != "$old" ]] || fail 'nothing was pushed'
r() { command git --git-dir="$remote" "$@"; }
[[ "$(r rev-list --merges "$old..$new" | wc -l)" == 1 ]] || fail 'the push should add one merge of main into the PR'
r merge-base --is-ancestor "$old" "$new" || fail 'the push was not a fast-forward of the observed head'
r merge-base --is-ancestor "$MAIN_HEAD" "$new" || fail 'the pushed head does not contain main'
r cat-file -e "$new:$mig/0004_pr.sql" 2>/dev/null || fail 'the PR migration was not renumbered to 0004'
! r cat-file -e "$new:$mig/0003_pr.sql" 2>/dev/null || fail 'the old 0003_pr is still there'
[[ "$(r show "$new:$mig/meta/_journal.json" | jq -r '[.entries[].tag] | join(",")')" == 0001_a,0002_b,0003_main,0004_pr ]] || fail 'journal must be main plus the PR entry, renumbered'
[[ "$(r show "$new:$mig/meta/_journal.json" | jq -r '[.entries[].idx] | join(",")')" == 0,1,2,3 ]] || fail 'journal idx must continue from main'
[[ "$(r show "$new:lessons/CATALOG.md" | grep -c '^Applies:')" == 3 ]] || fail 'CATALOG.md must keep the base line plus both sides'
grep -q 'merge-conflict-auto-resolved unit=issue-901' "$LOG" || fail 'no log line for the auto-resolve'
(( hook_calls == 1 )) || fail "the pack renumber hook ran $hook_calls times"

# 2. The unit's first conflict still goes to repair: the resolver acts on a repeat only.
reset "$(unit 904 '{"history":[]}')"
conflict 904
[[ "$(stage_of 904)" == repair-pending && "$(count 904 merge-conflict)" == 1 && "$ensure_calls" == 0 ]] || fail 'a first conflict must go to repair without a clone'
[[ "$(remote_head 904)" == "$(head_of 904)" ]] || fail 'a first conflict must not push'

# 3. A repeat conflict in a non-hot file still goes to the normal repair, and no clone is made for it.
reset "$(unit 902)"
conflict 902
[[ "$(stage_of 902)" == repair-pending && "$(count 902 merge-conflict)" == 2 && "$ensure_calls" == 0 ]] || fail 'a non-hot conflict must go to repair untouched'
grep -q 'conflicting_files=shared.txt count=1' "$LOG" || fail "the attribution line must name the real file even though the PR head was not in the clone: $(grep attribution "$LOG")"

# 4. Hot and non-hot files together: not resolved, repair as before, remote untouched.
reset "$(unit 903)"
conflict 903
[[ "$(stage_of 903)" == repair-pending && "$(remote_head 903)" == "$(head_of 903)" ]] || fail 'a mixed conflict must go to repair'

# 5. The pack renumber hook failing (or absent) leaves the PR as it was and sends it to repair.
reset "$(unit 905)"; hook_rc=1
conflict 905
[[ "$(stage_of 905)" == repair-pending && "$(remote_head 905)" == "$(head_of 905)" ]] || fail 'a failed renumber must fall through to repair with no push'
[[ "$(git -C "$WT_ROOT/wt-issue-905" rev-parse HEAD)" == "$(head_of 905)" && -z "$(git -C "$WT_ROOT/wt-issue-905" status --porcelain)" ]] || fail 'the clone must be left at the observed head'

# 6. Cap: a unit already auto-resolved CONFLICT_AUTO_MAX times goes to repair.
reset "$(unit 905 "{\"history\":[{\"stage\":\"merge-conflict\",\"result\":\"a\",\"at\":\"x\"},{\"stage\":\"conflict-auto-resolved\",\"result\":\"a\",\"at\":\"x\"},{\"stage\":\"conflict-auto-resolved\",\"result\":\"a\",\"at\":\"x\"},{\"stage\":\"conflict-auto-resolved\",\"result\":\"a\",\"at\":\"x\"}]}")"
conflict 905
[[ "$(stage_of 905)" == repair-pending && "$hook_calls" == 0 ]] || fail 'the per-unit cap was not honoured'
# 7. The root migrations/ journal is not the directory the renumber hook owns: a repeat conflict there goes to repair, nothing is pushed or cloned.
reset "$(unit 906)"
conflict 906
[[ "$(stage_of 906)" == repair-pending && "$(count 906 merge-conflict)" == 2 && "$ensure_calls" == 0 && "$hook_calls" == 0 ]] || fail "a root migrations/ journal conflict must go to repair: stage=$(stage_of 906)"
[[ "$(remote_head 906)" == "$(head_of 906)" ]] || fail 'a root journal conflict must not push'
echo 'conflict-resolve.test.sh: ok'
