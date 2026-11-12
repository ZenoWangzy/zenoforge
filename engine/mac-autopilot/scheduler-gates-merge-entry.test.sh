#!/usr/bin/env bash
# scheduler.sh --merge runs the merge lane alone: a CLEAN ready-to-merge PR is merged with the refill budget spent and without a ledger lock held,
# and nothing is dispatched or launched. The entry must exist in the table, and a pass already in progress is skipped, not doubled.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates-merge-entry.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ "${3:-}" == rev-parse && "${!#}" == refs/remotes/origin/main ]]; then printf '%s\n' "$M1"
  elif [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=unit touched=0\\n"\n' > "$ROOT/engine/rule-lane.sh"
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-10-19T00:00:00Z\",\"databaseId\":7}]"
GH_MERGE_SHA="$M2"
# The entry starts no work: any dispatch, intake or launch is a failure.
STARTED=""
for fn in dispatch_pending dispatch_supervisor_arbiters dispatch_prompt_evals register_new_issues launch_land launch_views fast_land_lane; do
  eval "$fn() { STARTED+=\" $fn\"; return 0; }"
done
# Ledger-lock state seen by each write: the entry must not hold the lock across the pass.
HELD_AT_MERGE=""
gh_before_entry="$(declare -f gh)"; eval "${gh_before_entry/gh ()/gh_inner ()}"
gh() { [[ "$1 $2" != "pr merge" ]] || HELD_AT_MERGE="${SCHED_LOCK_HELD:-false}"; gh_inner "$@"; }
# A spent refill budget: merge_refill_budget_spent fires only when TICK_LOCAL_REFILL is set, which --merge never sets.
SECONDS=290; AUTOPI_REFILL_LIMIT_SECONDS=300

grep -Eq '^  --merge\) SCHED_STATION=true; merge_entry ;;' "$script_dir/scheduler.sh" || fail 'scheduler.sh has no --merge entry in its table'
grep -Fq '"${1:-}" != --merge' "$script_dir/scheduler.sh" || fail '--merge is not exempt from the full tick config reconcile'

units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-clean",pr:21,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
TICK_HOTFIX_ISSUES='[]'; TICK_HOTFIX_ISSUES_LOADED=true # no hotfix issues
# One open CLEAN PR with a green check, as the census reads it.
GH_PR_TABLE="$fixture/merge-entry-prs.json"; echo '[]' > "$GH_PR_TABLE"
gh_pr_open 21 "$H1" false MERGEABLE agent/issue-21 '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
# Control: the same pass inside a refill with this budget stops before it merges.
GH_MERGES=(); : > "$LOG"
TICK_LOCAL_REFILL=true run_merge_lane || :
grep -Fq 'merge pass stopped before' "$LOG" && [[ ${#GH_MERGES[@]} == 0 ]] || fail 'the control refill pass was not starved; the fixture proves nothing'
GH_MERGES=(); : > "$LOG"
merge_entry
[[ "${GH_MERGES[0]:-}" == *"pr merge 21"*"--match-head-commit $H1"* && "$(field pr-clean .stage)" == merged ]] || fail "--merge did not merge the CLEAN PR (${GH_MERGES[*]:-none}; $(tail -n 5 "$LOG"))"
[[ -z "$STARTED" ]] || fail "--merge started work:$STARTED"
[[ "$HELD_AT_MERGE" == false ]] || fail "--merge held the ledger lock across the merge ($HELD_AT_MERGE)"
grep -Fq 'merge pass stopped' "$LOG" && fail 'the refill budget stopped the --merge pass'
grep -Eq 'merge entry done secs=' "$LOG" || fail 'no closing line'

# Paused: no merge. A pass already in progress: skipped, not doubled.
units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-clean",pr:21,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
GH_MERGES=(); : > "$LOG"; : > "$fixture/PAUSE"
PAUSE_FILE="$fixture/PAUSE" merge_entry
[[ ${#GH_MERGES[@]} == 0 ]] || fail 'a paused --merge merged'
rm -f "$fixture/PAUSE"
( exec 8>"$A/.merge-lane.lock"; flock -x 8; merge_entry; [[ ${#GH_MERGES[@]} == 0 ]] ) || fail '--merge ran a pass while another pass held the merge lock'
grep -Fq 'merge lane busy' "$LOG" || fail 'the skipped pass was not logged'
printf 'ok - --merge: merges a CLEAN PR with the budget spent, no lock held, no work started, skips a busy lane\n'
