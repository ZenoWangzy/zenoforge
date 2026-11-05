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
echo 'intake-terminal-skip.test.sh: pass'
