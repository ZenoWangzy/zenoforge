#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
source "$engine_dir/mac-autopilot/test-env.sh"

fixture="$test_env_root/merge-result-check"
supervisor="$fixture/supervisor"
root="$fixture/root"
source_repo="$fixture/source"
remote="$fixture/origin.git"
mkdir -p "$supervisor/autopi/alerts" "$fixture"
export MAC_AUTOPILOT_ROOT="$root" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.auto_merge = true | .batch_max = 1' "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { printf 'merge-result-check.test.sh: %s\n' "$*" >&2; exit 1; }
export GIT_AUTHOR_NAME='merge-result fixture' GIT_AUTHOR_EMAIL='merge-result@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
command git init -q -b main "$source_repo"
command git -C "$source_repo" config user.name "$GIT_AUTHOR_NAME"
command git -C "$source_repo" config user.email "$GIT_AUTHOR_EMAIL"
mkdir -p "$source_repo/scripts" "$source_repo/engine"
cat > "$source_repo/scripts/branch-delivery-preflight.mjs" <<'JS'
export function first() { return 1; }
// spacer one
// spacer two
// spacer three
// spacer four
// spacer five
export function last() { return 2; }
JS
cat > "$source_repo/engine/rule-lane.sh" <<'SH'
#!/usr/bin/env bash
printf 'rule-lane: decision=pass actor=%s touched=0\n' "${ZF_AGENT_NAME:-unit}"
SH
command git -C "$source_repo" add -A
command git -C "$source_repo" commit -qm base
base="$(command git -C "$source_repo" rev-parse HEAD)"
{ printf 'function runMigrationNumberCheck() { return "main"; }\n'; cat "$source_repo/scripts/branch-delivery-preflight.mjs"; } > "$fixture/main.mjs"
cp "$fixture/main.mjs" "$source_repo/scripts/branch-delivery-preflight.mjs"
command git -C "$source_repo" add scripts/branch-delivery-preflight.mjs
command git -C "$source_repo" commit -qm main-addition
main="$(command git -C "$source_repo" rev-parse HEAD)"
command git clone -q --bare "$source_repo" "$remote"
command git -C "$source_repo" checkout -q -b agent/issue-771 "$base"
{ cat "$source_repo/scripts/branch-delivery-preflight.mjs"; printf '\nfunction runMigrationNumberCheck() { return "pr"; }\n'; } > "$fixture/duplicate.mjs"
cp "$fixture/duplicate.mjs" "$source_repo/scripts/branch-delivery-preflight.mjs"
command git -C "$source_repo" add scripts/branch-delivery-preflight.mjs
command git -C "$source_repo" commit -qm pr-duplicate-addition
bad_head="$(command git -C "$source_repo" rev-parse HEAD)"
command git --git-dir="$remote" fetch -q "$source_repo" +refs/heads/agent/issue-771:refs/pull/771/head
command git -C "$source_repo" checkout -q -b agent/issue-772 "$base"
printf '\nfunction runDifferentCheck() { return true; }\n' >> "$source_repo/scripts/branch-delivery-preflight.mjs"
command git -C "$source_repo" add scripts/branch-delivery-preflight.mjs
command git -C "$source_repo" commit -qm pr-valid-addition
good_head="$(command git -C "$source_repo" rev-parse HEAD)"
command git --git-dir="$remote" fetch -q "$source_repo" +refs/heads/agent/issue-772:refs/pull/772/head
command git clone -q "$remote" "$root"

node --check "$fixture/main.mjs" || fail 'main side of the fixture must parse'
node --check "$fixture/duplicate.mjs" || fail 'PR side of the fixture must parse'

MAIN_HEAD="$main"
GH_MERGE_SHA="$main"
GH_HEAD=""
GH_MERGES_FILE="$fixture/merges.log"
: > "$GH_MERGES_FILE"
SCHED_LOCK_HELD=true
gate_eval_sha() { printf '%s\n' "$MAIN_HEAD"; }
suites_run_for() { printf '{"headSha":"%s","status":"completed","conclusion":"success","databaseId":1}\n' "$1"; }
ci_classify_run() { CI_CLASS=pass; CI_REASON='fixture main suites pass'; CI_RUN_ID=1; CI_RUN_ATTEMPT=1; }
gate_note() { :; }
retry_blocked_units() { :; }
tick_prs() { TICK_PRS="$(cat "$fixture/prs.json")"; printf '%s' "$TICK_PRS"; }
gh() {
  case "$1 $2" in
    'pr merge') printf '%s\n' "$*" >> "$GH_MERGES_FILE"; return 0 ;;
    'pr view')
      case "${5:-}" in
        mergeCommit) printf '%s\n' "$GH_MERGE_SHA" ;;
        mergeable,headRefOid) printf 'UNKNOWN %s\n' "$GH_HEAD" ;;
        *) printf '\n' ;;
      esac ;;
    *) return 1 ;;
  esac
}
set_candidate() {
  local number="$1" head="$2" branch="$3" id="$4"
  GH_HEAD="$head"
  jq -cn --argjson number "$number" --arg head "$head" --arg branch "$branch" \
    '[{number:$number,headRefOid:$head,headRefName:$branch,baseRefName:"main",isDraft:false,title:"fixture",labels:[],body:"",mergeable:"MERGEABLE",statusCheckRollup:[{__typename:"CheckRun",name:"fixture checks",status:"COMPLETED",conclusion:"SUCCESS",startedAt:"2026-10-30T00:00:00Z"}]}]' \
    > "$fixture/prs.json"
  jq -cn --arg id "$id" --argjson pr "$number" --arg branch "$branch" --arg head "$head" \
    '{units:[{id:$id,pr:$pr,branch:$branch,stage:"ready-to-merge",approved_sha:$head,history:[]}]}' > "$UNITS"
  TICK_PRS=""; TICK_PR_CHECK_CENSUS=""; TICK_PR_STATE=()
  : > "$GH_MERGES_FILE"
  : > "$LOG"
}

set_candidate 771 "$bad_head" agent/issue-771 merge-result-duplicate
run_merge_lane || :
[[ ! -s "$GH_MERGES_FILE" && "$(unit_field merge-result-duplicate .stage)" == repair-pending ]] \
  || fail 'the scheduler merged a PR whose merge result has a duplicate top-level declaration'
[[ "$(unit_field merge-result-duplicate .repair_hint)" == *'scripts/branch-delivery-preflight.mjs: SyntaxError: Identifier'* ]] \
  || fail 'the merge-result SyntaxError was not included in the repair reason'
grep -Fq 'merge result Node syntax check failed' "$LOG" \
  || fail 'the merge-result syntax refusal was not recorded'

set_candidate 772 "$good_head" agent/issue-772 merge-result-valid
run_merge_lane || :
[[ "$(cat "$GH_MERGES_FILE")" == *'pr merge 772'* && "$(unit_field merge-result-valid .stage)" == merged ]] \
  || fail 'a syntactically valid merge result was not allowed through the merge lane'

printf 'merge-result-check.test.sh: PASS\n'
