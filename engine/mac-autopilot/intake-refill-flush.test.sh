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
real_intake_candidates="$(declare -f intake_candidates)"
UNITS_ARCHIVE="$A/units-archive.json"

refill_room() { return 0; }
refill_stopped() { return 1; }
live_workers() { printf '0\n'; }
startable_pending_count() { printf '0\n'; }
intake_footprint_snapshot() { printf '[]\n'; }
predecessor_candidates() { :; }
intake_candidates() {
  if [[ "${TERMINAL_ROW_ONLY:-}" == true ]]; then printf '1\tpr\tt\t[]\t\n'; else printf '1\tpr\tt\t[]\t\n2\tpr\tt\t[]\t\n3\tpr\tt\t[]\t\n4\tpr\tt\t[]\t\n'; fi
}
hotfix_issue_numbers() { return 0; }
tick_prs_prime() { :; }
tick_prs() { return 1; }
intake_gh_read() { printf '[]\n'; }
closed_unit_calls="$fixture/closed-unit-calls"
intake_reopen_episodes() { :; }
intake_ruling_episodes() { :; }
intake_closed_unit_rows() { printf '%s\n' "$*" >> "$closed_unit_calls"; }
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
jq -cn '{schema:5,created_at:0,rows:"1\tpr\tt\t[]\t\n2\tpr\tt\t[]\t\n3\tpr\tt\t[]\t\n4\tpr\tt\t[]\t\n",skipped:{}}' > "$A/intake-candidates.json"
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

# The detached register step owns terminal-row work; refill only reports that it deferred it.
reset_units
jq '(.units[] | select(.issue == 1)) |= (.stage = "closed" | .hold_handoff_episode = "e1")' "$UNITS" > "$UNITS.tmp" && mv -f "$UNITS.tmp" "$UNITS"
rm -f "$UNITS.view" "$closed_unit_calls"
TERMINAL_ROW_ONLY=true register_new_issues 0 true
[[ ! -e "$closed_unit_calls" ]] || { echo 'not ok - refill ran closed-unit handling' >&2; exit 1; }
grep -Fq 'intake closed units deferred to the register step count=1 ids=1' "$LOG" || { echo 'not ok - refill did not log deferred closed-unit handling' >&2; cat "$LOG" >&2; exit 1; }
rm -f "$closed_unit_calls"
TERMINAL_ROW_ONLY=true register_new_issues 0 false
[[ "$(cat "$closed_unit_calls")" == 1 ]] || { echo 'not ok - non-refill intake did not run closed-unit handling' >&2; exit 1; }

# Reuse an issue-derived skip while updated_at is stable, and revisit the issue after it changes.
issue_reads="$fixture/issue-views"; : > "$issue_reads"
candidate_updated_at=2026-11-12T00:00:00Z
intake_candidates() { printf '99\tpr\tfixture\t[]\t-\t%s\n' "$candidate_updated_at"; }
intake_gh_read() {
  if [[ "$1 $2" == 'issue view' ]]; then
    printf '%s\n' "$*" >> "$issue_reads"
    printf '%s\n' '{"number":99,"title":"fixture","body":"","state":"OPEN","labels":[{"name":"ready-for-agent"}]}'
  else
    printf '[]\n'
  fi
}
scheduler_issue_intake_parent_reason() { return 1; }
scheduler_lib_context() { :; }
intake_author_gate() { return 1; }
HANDOFF_PR_CENSUS='[]' HANDOFF_CENSUS_PARTIAL=1 HANDOFF_WAIT_PRS='[]' HANDOFF_WAIT_BRANCHES='[]'
jq -cn --arg rows "$(printf '99\tpr\tfixture\t[]\t-\t%s' "$candidate_updated_at")" \
  '{schema:5,created_at:0,rows:$rows,skipped:{}}' > "$A/intake-candidates.json"
jq -n '{units:[]}' > "$UNITS"
register_new_issues 0 true
[[ "$(wc -l < "$issue_reads")" == 1 ]] || { echo 'not ok - first walk did not read issue 99 once' >&2; exit 1; }
cp "$LOG" "$fixture/first-walk.log"
: > "$LOG"
register_new_issues 0 true
[[ "$(wc -l < "$issue_reads")" == 1 ]] || { echo 'not ok - unchanged issue 99 was reread' >&2; cat "$issue_reads" >&2; exit 1; }
grep -Eq 'intake walk refill=true walked=1 cached=0 secs=[0-9]+' "$fixture/first-walk.log" || { echo 'not ok - first walk metrics' >&2; cat "$fixture/first-walk.log" >&2; exit 1; }
grep -Eq 'intake walk refill=true walked=0 cached=1 secs=[0-9]+' "$LOG" || { echo 'not ok - cached walk metrics' >&2; cat "$LOG" >&2; exit 1; }
candidate_updated_at=2026-11-12T00:00:01Z
: > "$LOG"
register_new_issues 0 true
[[ "$(wc -l < "$issue_reads")" == 2 ]] || { echo 'not ok - changed issue 99 updated_at did not trigger a reread' >&2; cat "$issue_reads" >&2; exit 1; }
jq -e '.skipped["99"].updated_at == "2026-11-12T00:00:01Z"' "$A/intake-candidates.json" >/dev/null \
  || { echo 'not ok - changed updated_at did not replace the cached verdict key' >&2; cat "$A/intake-candidates.json" >&2; exit 1; }
grep -Eq 'intake walk refill=true walked=1 cached=0 secs=[0-9]+' "$LOG" || { echo 'not ok - changed walk metrics' >&2; cat "$LOG" >&2; exit 1; }
jq '.skipped["100"] = {updated_at:"2026-11-12T00:00:00Z",verdict:"parent"}' "$A/intake-candidates.json" > "$A/intake-candidates.next"
mv -f "$A/intake-candidates.next" "$A/intake-candidates.json"
eval "$real_intake_candidates"
list_args="$fixture/issue-list-args"; : > "$list_args"
intake_gh_read() {
  if [[ "$1 $2" == 'issue list' ]]; then
    printf '%s\n' "$*" >> "$list_args"
    printf '%s\n' '[{"number":99,"title":"fixture","body":"","state":"OPEN","labels":[{"name":"ready-for-agent"}],"subIssuesSummary":{"total":0},"blockedBy":{"nodes":[]},"updatedAt":"2026-11-12T00:00:01Z"}]'
  else
    printf '[]\n'
  fi
}
actual_candidate_rows="$(intake_candidates false)"
grep -Fq -- '--json number,title,body,state,labels,subIssuesSummary,blockedBy,updatedAt' "$list_args" \
  || { echo 'not ok - issue list did not request updatedAt' >&2; cat "$list_args" >&2; exit 1; }
[[ "$(cut -f6 <<<"$actual_candidate_rows")" == 2026-11-12T00:00:01Z ]] \
  || { echo 'not ok - candidate row did not carry updatedAt' >&2; printf '%s\n' "$actual_candidate_rows" >&2; exit 1; }
jq -e '.schema == 5 and ([.skipped | keys[]] == ["99"])' "$A/intake-candidates.json" >/dev/null \
  || { echo 'not ok - candidate refresh kept verdicts for removed issues' >&2; cat "$A/intake-candidates.json" >&2; exit 1; }

echo 'ok - refill intake writes its census_partial wait marks in one ledger update, also on a budget stop'
