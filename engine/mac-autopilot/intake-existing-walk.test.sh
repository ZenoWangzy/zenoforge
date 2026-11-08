#!/usr/bin/env bash
# The existing-only intake walk stops at its budget, stores a cursor, resumes there on the next walk, wraps, and clears the cursor after a lap.
# Per-row ledger work is constant: one read of the units view per walk, and one ledger update for all census_partial rows.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fixture="$test_env_root/intake-existing-walk"
AGENT_HOME="$fixture/agent-home"
A="$fixture/autopi"
LOG="$A/scheduler.log"
UNITS="$A/units.json"
WORKERS="$A/workers.json"
STAMP=2026-11-08T00:00:00Z
NOW_EPOCH=1793577600
MAX=1
CFG='{"issue_intake":{"enabled":true,"max_upstream":8,"max_ready":30,"ready_buffer":0,"labels":[],"product_labels":["ready-for-agent"]}}'
mkdir -p "$AGENT_HOME/state" "$A/alerts"
: > "$LOG"
jq -cn '{units: [range(1;6) | {id:"issue-\(.)",issue:.,branch:"agent/issue-\(.)",stage:"blocked-external",pr:null}]}' > "$UNITS"

source "$script_dir/scheduler.d/core.sh"
source "$script_dir/scheduler.d/units.sh"
source "$script_dir/scheduler.d/intake-steps.sh"
source "$script_dir/scheduler.d/intake.sh"
UNITS_ARCHIVE="$A/units-archive.json"

units_update() { :; } # the census clears wait marks; nothing to clear here
refill_stopped() { return 1; }
hotfix_lane_label() { printf 'hotfix-lane\n'; }
hotfix_issue_numbers() { return 0; }
tick_prs_prime() { :; }
tick_prs() { printf '[]\n'; }
# Rows come unsorted on purpose: the walk orders them by number.
existing_handoff_candidates() { local n; for n in 3 1 5 2 4; do printf '%s\tpr\thandoff\t[]\n' "$n"; done; }
# Each row reads its state file once or twice: record the row. Row #3 is slow on the first walk only, shown as a 100 s jump of the clock.
visits="$fixture/visits"
eval "$(declare -f jqf_optional_file | sed '1s/jqf_optional_file/real_jqf_optional_file/')"
jqf_optional_file() { printf '%s\n' "$(basename "$1" .json)" >> "$visits"; real_jqf_optional_file "$@"; }
real_intake_mark="$(declare -f intake_mark)"; eval "${real_intake_mark/intake_mark/real_intake_mark}"
intake_mark() { # n is register_new_issues' row variable (dynamic scope)
  if [[ "${n:-}" == 3 && "$1" == state_read && ! -e "$fixture/slow-done" ]]; then : > "$fixture/slow-done"; SECONDS=$((SECONDS + 100)); fi
  real_intake_mark "$@"
}

cursor="$A/intake-existing-cursor"
ISSUE_INTAKE_EXISTING_BUDGET_SECONDS=50

: > "$visits"
register_new_issues 1
walk1="$(awk '!s[$0]++' "$visits" | paste -sd, -)"
[[ "$walk1" == 1,2,3 ]] || { echo "not ok - first walk visited $walk1, want 1,2,3" >&2; exit 1; }
[[ "$(cat "$cursor")" == 4 ]] || { echo 'not ok - cursor is not 4 after the budget break' >&2; exit 1; }
grep -Fq 'intake detail existing_walk start=#1 rows=3 lap_done=false' "$LOG" || { echo 'not ok - first walk line' >&2; cat "$LOG" >&2; exit 1; }

: > "$visits"
register_new_issues 1
walk2="$(awk '!s[$0]++' "$visits" | paste -sd, -)"
[[ "$walk2" == 4,5,1,2,3 ]] || { echo "not ok - second walk visited $walk2, want 4,5,1,2,3" >&2; exit 1; }
[[ ! -e "$cursor" ]] || { echo 'not ok - a full lap left the cursor' >&2; exit 1; }
grep -Fq 'intake detail existing_walk start=#4 rows=5 lap_done=true' "$LOG" || { echo 'not ok - second walk line' >&2; cat "$LOG" >&2; exit 1; }

echo 'ok - existing intake walk resumes at its cursor, wraps, and clears it after a lap'

# A walk reads the units view a constant number of times, however many rows it has.
eval "$(declare -f jqf | sed '1s/jqf/real_jqf/')"
reads="$fixture/units-reads"
jqf() { local a; for a; do [[ "$a" == "$UNITS" || "$a" == "$UNITS.view" ]] && printf x >> "$reads"; done; real_jqf "$@"; }
walk_reads() { # rows: units 1..rows exist and every row is a handoff row
  jq -cn --argjson n "$1" '{units: [range(1;$n+1) | {id:"issue-\(.)",issue:.,branch:"agent/issue-\(.)",stage:"blocked-external",pr:null}]}' > "$UNITS"
  walk_n="$1"
  existing_handoff_candidates() { local n; for ((n = 1; n <= walk_n; n++)); do printf '%s\tpr\thandoff\t[]\n' "$n"; done; }
  : > "$reads"; register_new_issues 1; wc -c < "$reads"
}
reads_5="$(walk_reads 5)"; reads_20="$(walk_reads 20)"
[[ "$reads_5" == 1 && "$reads_20" == 1 ]] || { echo "not ok - units view reads per walk: $reads_5 rows=5, $reads_20 rows=20; want 1 each" >&2; exit 1; }

# With only part of the PR census read, the rows' stale-wait clear and add are one ledger update at the end of the walk, with the per-row result.
tick_prs() { return 1; }
intake_gh_read() { return 1; }
jq -cn '{units: ([range(1;5) | {id:"issue-\(.)",issue:.,branch:"agent/issue-\(.)",stage:"blocked-external",pr:null}]
  + [{id:"issue-6",issue:6,branch:"agent/issue-6",stage:"blocked-external",pr:null,hold_handoff_wait_issues:[1],hold_handoff_waiting:true}])}' > "$UNITS"
for n in 1 2 3 4; do printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"e%s"}}\n' "$n" > "$AGENT_HOME/state/$n.json"; done
existing_handoff_candidates() { local n; for n in 1 2 3 4; do printf '%s\tpr\thandoff\t[]\n' "$n"; done; }
updates="$fixture/updates"; : > "$updates"
units_update() { printf '%s\n' "$*" >> "$updates"; local t="$UNITS.t"; jq "$@" "$UNITS" > "$t" && mv -f "$t" "$UNITS"; }
register_new_issues 1
[[ "$(grep -c -- '--slurpfile pairs' "$updates")" == 1 ]] || { echo 'not ok - census_partial rows were not one ledger update' >&2; cat "$updates" >&2; exit 1; }
jq -e '[.units[] | select(.issue <= 4)] | all(.hold_handoff_waiting == true and .hold_handoff_wait_issues == [.issue])' "$UNITS" >/dev/null \
  || { echo 'not ok - census_partial rows did not wait' >&2; jq -c '.units[]' "$UNITS" >&2; exit 1; }
jq -e '.units[] | select(.id == "issue-6") | (has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not' "$UNITS" >/dev/null \
  || { echo 'not ok - the stale wait on issue 6 was not cleared' >&2; exit 1; }
grep -Fq 'intake skip counts refill=false added=0 census_partial=4' "$LOG" || { echo 'not ok - census_partial count' >&2; exit 1; }

echo 'ok - a walk reads the units view once and updates the census_partial rows in one ledger write'
