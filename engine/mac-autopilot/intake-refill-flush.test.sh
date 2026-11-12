#!/usr/bin/env bash
# The refill intake walk queues its census_partial wait marks and writes the ledger once per walk, as the existing walk does, and the queued marks survive a budget stop.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fixture="$test_env_root/intake-refill-flush"
AGENT_HOME="$fixture/agent-home"
A="$fixture/autopi"
LOG="$A/scheduler.log"
UNITS="$A/units.json"
WORKERS="$A/workers.json"
STAMP=2026-11-12T00:00:00Z
NOW_EPOCH=1794528000
MAX=1
CFG='{"issue_intake":{"enabled":true,"max_upstream":8,"max_ready":30,"ready_buffer":0,"labels":[],"product_labels":["ready-for-agent"]}}'
mkdir -p "$AGENT_HOME/state" "$A/alerts"
: > "$LOG"

source "$script_dir/scheduler.d/core.sh"
source "$script_dir/scheduler.d/units.sh"
source "$script_dir/scheduler.d/intake-steps.sh"
source "$script_dir/scheduler.d/intake-index.sh"
source "$script_dir/scheduler.d/recut-reopen.sh"
source "$script_dir/scheduler.d/intake.sh"
UNITS_ARCHIVE="$A/units-archive.json"

refill_room() { return 0; }
refill_stopped() { return 1; }
live_workers() { printf '0\n'; }
startable_pending_count() { printf '0\n'; }
intake_footprint_snapshot() { printf '[]\n'; }
predecessor_candidates() { :; }
intake_candidates() { printf '1\tpr\tt\t[]\t\n2\tpr\tt\t[]\t\n3\tpr\tt\t[]\t\n4\tpr\tt\t[]\t\n'; }
hotfix_issue_numbers() { return 0; }
tick_prs_prime() { :; }
tick_prs() { return 1; }
intake_gh_read() { printf '[]\n'; }
# The census is partial: no PR list, so every row with an episode is a census_partial row.
for n in 1 2 3 4; do printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"e%s"}}\n' "$n" > "$AGENT_HOME/state/$n.json"; done
updates="$fixture/updates"
units_update() { printf '%s\n' "$*" >> "$updates"; local t="$UNITS.t"; jq "$@" "$UNITS" > "$t" && mv -f "$t" "$UNITS"; }
real_intake_mark="$(declare -f intake_mark)"; eval "${real_intake_mark/intake_mark/real_intake_mark}"
intake_mark() { # the budget scenario moves the clock past the budget while row 2 reads its state
  if [[ "${n:-}" == 2 && "$1" == state_read && -n "${SLOW_ROW3:-}" ]]; then SECONDS=$((SECONDS + 100)); fi
  real_intake_mark "$@"
}

reset_units() {
  jq -cn '{units: ([range(1;5) | {id:"issue-\(.)",issue:.,branch:"agent/issue-\(.)",stage:"blocked-external",pr:null}]
    + [{id:"issue-6",issue:6,branch:"agent/issue-6",stage:"blocked-external",pr:null,hold_handoff_wait_issues:[1],hold_handoff_waiting:true}])}' > "$UNITS"
  : > "$updates"
}

# All four rows are census_partial: one ledger write for the walk, and every row's wait is there at the end.
jq -cn '{schema:4,created_at:0,rows:"1\tpr\tt\t[]\t\n2\tpr\tt\t[]\t\n3\tpr\tt\t[]\t\n4\tpr\tt\t[]\t\n"}' > "$A/intake-candidates.json"
reset_units
register_new_issues 0 true
[[ "$(grep -c -- '--slurpfile ops' "$updates")" == 1 ]] || { echo 'not ok - refill census_partial rows were not one ledger update' >&2; cat "$updates" >&2; exit 1; }
jq -e '[.units[] | select(.issue <= 4)] | all(.hold_handoff_waiting == true and .hold_handoff_wait_issues == [.issue])' "$UNITS" >/dev/null \
  || { echo 'not ok - refill census_partial rows did not wait' >&2; jq -c '.units[]' "$UNITS" >&2; exit 1; }
jq -e '.units[] | select(.id == "issue-6") | (has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not' "$UNITS" >/dev/null \
  || { echo 'not ok - refill did not clear the stale wait on issue 6' >&2; exit 1; }
grep -Fq 'intake skip counts refill=true added=0 census_partial=4' "$LOG" || { echo 'not ok - refill census_partial count' >&2; cat "$LOG" >&2; exit 1; }
# Nothing admitted: the idle alert goes to head-watch.alerts with the candidates' unit stages.
alerts="$AGENT_HOME/logs/head-watch.alerts"
grep -Fq 'IDLE-CAPACITY live=0/1 pending=0' "$alerts" && grep -Fq 'stages: blocked-external=4' "$alerts" || { echo 'not ok - idle capacity alert' >&2; cat "$alerts" >&2 2>/dev/null; exit 1; }

# A budget stop after two rows still writes the two queued rows' marks, once.
reset_units
SLOW_ROW3=1 ISSUE_INTAKE_BUDGET_SECONDS=50 register_new_issues 0 true
[[ "$(grep -c -- '--slurpfile ops' "$updates")" == 1 ]] || { echo 'not ok - budget stop was not one ledger update' >&2; cat "$updates" >&2; exit 1; }
jq -e '[.units[] | select(.issue <= 2)] | all(.hold_handoff_waiting == true and .hold_handoff_wait_issues == [.issue])' "$UNITS" >/dev/null \
  || { echo 'not ok - budget stop lost the queued marks of rows 1 and 2' >&2; jq -c '.units[]' "$UNITS" >&2; exit 1; }
jq -e '[.units[] | select(.issue >= 3 and .issue <= 4)] | all((has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not)' "$UNITS" >/dev/null \
  || { echo 'not ok - budget stop marked rows it did not reach' >&2; jq -c '.units[]' "$UNITS" >&2; exit 1; }
[[ "$(grep -c 'IDLE-CAPACITY' "$alerts" || true)" == 1 ]] || { echo 'not ok - idle alert was not deduplicated within the hour' >&2; cat "$alerts" >&2; exit 1; }

echo 'ok - refill intake writes its census_partial wait marks in one ledger update, also on a budget stop'
