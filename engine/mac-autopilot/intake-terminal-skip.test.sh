#!/usr/bin/env bash
# A candidate row whose units are all terminal must cost no gh call; a live handoff row still reads its PR.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/intake-terminal-skip"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$fixture/bin"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
fail() { echo "intake-terminal-skip.test.sh: $*" >&2; exit 1; }

gh_log="$fixture/gh.log"; : > "$gh_log"
cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[[ "$1 $2" == "pr view" ]] && printf '{"number":%s,"headRefName":"agent/issue-x","title":"t","body":"","state":"MERGED","labels":[]}\n' "$3"
exit 0
GH
chmod +x "$fixture/bin/gh"
export GH_LOG="$gh_log" TICK_INTAKE_GH_INVOKE="$fixture/bin/gh"

MAX=8
CFG='{"issue_intake":{"enabled":true,"max_upstream":16,"max_ready":30,"ready_buffer":0}}'
HANDOFF_PR_CENSUS='[]' HANDOFF_CENSUS_PARTIAL=1
footprint_waiters_revalidate() { :; }
live_workers() { echo 0; }
hotfix_issue_numbers() { :; }
tick_prs_prime() { :; }
tick_prs() { echo '[]'; }
intake_footprint_snapshot() { echo '[]'; }
scheduler_footprint() { echo '[]'; }
active_footprint_conflict() { :; }
predecessor_candidates() { :; }
issue_unit_task() { echo '{"task":"fixture","body_blocked_by":[],"labels":[]}'; }
row() { printf '%s\tpr\tfixture\t[]\t%s\n' "$1" "$(printf '{"number":%s,"state":"OPEN","subIssuesSummary":{"total":0},"labels":[{"name":"ready-for-agent"}]}' "$1" | base64 -w0)"; }
intake_candidates() { for n in 10 11 12 13; do row "$n"; done; }

# 10: merged, episode consumed; 11: done, no episode; 12: merged but a new episode is waiting; 13: non-terminal unit.
jq -n '{units:[
  {id:"issue-10",issue:10,stage:"merged",pr:100,hold_handoff_episode:"e1"},
  {id:"issue-11",issue:11,stage:"done",pr:110},
  {id:"issue-12",issue:12,stage:"merged",pr:120,hold_handoff_episode:"old"},
  {id:"issue-13",issue:13,stage:"repair-pending",pr:130,hold_handoff_episode:"e3"}]}' > "$UNITS"
mkdir -p "$AGENT_HOME/state"
st() { printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"%s"}}\n' "$2" > "$AGENT_HOME/state/$1.json"; }
st 10 e1; printf '{"state":"ready-for-agent"}\n' > "$AGENT_HOME/state/11.json"; st 12 new; st 13 e3

: > "$LOG"
register_new_issues 0 true
for pr in 100 110; do ! grep -Fq "pr view $pr " "$gh_log" || fail "terminal row read PR $pr"; done
for pr in 120 130; do grep -Fq "pr view $pr " "$gh_log" || fail "live handoff row did not read PR $pr"; done
grep -Fq 'intake skip counts refill=true added=0 ' "$LOG" || fail "no count line: $(cat "$LOG")"
grep -Fq ' terminal=2' "$LOG" || fail "terminal not counted: $(grep 'skip counts' "$LOG")"
grep -Fq ' census_partial=2' "$LOG" || fail "live rows not counted: $(grep 'skip counts' "$LOG")"
! grep -Fq 'intake budget spent' "$LOG" || fail "an early refill spent its budget: $(cat "$LOG")"
steps_line="$(grep 'intake detail steps' "$LOG" || true)"
for step in state_read terminal_check skip_terminal skip_census_partial; do
  [[ "$steps_line" == *" $step="*"s/"* ]] || fail "steps line lacks $step: $steps_line"
done

# Only an open PR's own branch (agent/issue-N) or a `Refs|Fixes|Closes|Resolves #N` body line holds issue N; prose, titles and longer numbers do not.
cp "$UNITS" "$fixture/units.keep"
open_pr_case() { # name, PR JSON, held|free
  jq -n '{units:[]}' > "$UNITS"; rm -f "$A/intake-skip-noted.tsv"; : > "$LOG"
  PRS="$2" register_new_issues 0 true
  if grep -Fq "intake skip issue #5028: an open PR's branch, title or body names it" "$LOG"; then got=held; else got=free; fi
  [[ "$got" == "$3" ]] || fail "$1: expected $3, got $got: $(cat "$LOG")"
  if [[ "$3" == held ]]; then grep -Fq ' open_pr=1' "$LOG" || fail "$1: held but not counted: $(grep 'skip counts' "$LOG")"
  else ! grep -Fq ' open_pr=' "$LOG" || fail "$1: free but counted open_pr"; fi
}
tick_prs() { echo "$PRS"; }
intake_candidates() { row 5028; }
open_pr_case 'sibling prose'  '[{"headRefName":"agent/issue-5398","title":"x (#5028)","body":"Sibling #5028 owns screen-read authorization.\nsee #5028"}]' free
open_pr_case 'Refs line'      '[{"headRefName":"agent/issue-9","title":"x","body":"intro\nRefs #5028\n"}]' held
open_pr_case 'lower case'     '[{"headRefName":"agent/issue-9","title":"x","body":"  refs #5028"}]' held
open_pr_case 'own branch'     '[{"headRefName":"agent/issue-5028","title":"x","body":""}]' held
open_pr_case 'branch suffix'  '[{"headRefName":"agent/issue-5028-recovered-abc123","title":"x","body":""}]' held
open_pr_case 'longer branch'  '[{"headRefName":"agent/issue-50281","title":"x","body":""}]' free
open_pr_case 'longer number'  '[{"headRefName":"agent/issue-50281","title":"x","body":"Refs #50281"}]' free
cp "$fixture/units.keep" "$UNITS"; rm -f "$A/intake-skip-noted.tsv"
tick_prs() { echo '[]'; }
intake_candidates() { for n in 10 11 12 13; do row "$n"; done; }

# A refill near its 300s kill stops intake cleanly, whatever is left of its own budget.
: > "$LOG"
SECONDS=280
register_new_issues 0 true
grep -Eq 'intake budget spent after [0-9]+s: rows from #10 wait for the next tick' "$LOG" || fail "a late refill ran into the kill: $(cat "$LOG")"
# A closed unit with its recut reopen spent is removed before the handoff lookup, and its note is throttled.
handoff_reads="$fixture/handoff-reads"; : > "$handoff_reads"
handoff_open_pr() { printf '%s\n' "$1" >> "$handoff_reads"; echo '[]'; }
intake_census_load() { return 1; } # exercise the GitHub fallback on the unpatched path
existing_handoff_candidates() { printf '4932\tpr\tfixture\t[]\n'; }
HANDOFF_PR_CENSUS='[]' HANDOFF_CENSUS_PARTIAL=0
jq -n '{units:[{id:"issue-4932",issue:4932,stage:"closed",pr:null,recut_reopen_refused:true,hold_handoff_episode:"old"}]}' > "$UNITS"
rm -f "$UNITS.view" "$A/intake-skip-noted.tsv"
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":{"episode":"new"}}' > "$AGENT_HOME/state/4932.json"
: > "$LOG"
register_new_issues 1
first_notes="$(grep -Fc 'intake skip issue #4932: closed unit issue-4932 recut refused and its reopen is spent' "$LOG" || true)"
: > "$LOG"; : > "$handoff_reads"
register_new_issues 1
[[ ! -s "$handoff_reads" ]] || fail "second pass performed handoff lookup: $(cat "$handoff_reads")"
! grep -Fq 'intake hold handoff issue #4932:' "$LOG" || fail "second pass repeated the hold line: $(cat "$LOG")"
[[ "$first_notes" == 1 ]] || fail "the first pass did not log one throttled note: $first_notes"

# The cheaper status mode still treats a nested untracked file as preserved work.
unsafe_wt="$fixture/wt-unsafe"; mkdir -p "$unsafe_wt"
git -C "$unsafe_wt" init -q
git -C "$unsafe_wt" config user.name test; git -C "$unsafe_wt" config user.email test@example.com
printf 'base\n' > "$unsafe_wt/base.txt"; git -C "$unsafe_wt" add base.txt; git -C "$unsafe_wt" commit -qm base
mkdir -p "$unsafe_wt/build/cache/deep"; printf 'untracked\n' > "$unsafe_wt/build/cache/deep/result.txt"
reason="$(worktree_cleanup_block_reason "$unsafe_wt")" || fail 'nested untracked work was not preserved'
[[ "$reason" == 'uncommitted changes' ]] || fail "wrong preserved-worktree reason: $reason"

echo 'intake-terminal-skip.test.sh: pass'
