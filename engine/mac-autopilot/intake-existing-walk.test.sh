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
source "$script_dir/scheduler.d/intake-index.sh"
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
[[ "$INTAKE_WALK_ROWS $INTAKE_WALK_LAP" == '3 false' ]] || { echo "not ok - the station's walk result is $INTAKE_WALK_ROWS $INTAKE_WALK_LAP, want 3 false" >&2; exit 1; }

: > "$visits"
register_new_issues 1
walk2="$(awk '!s[$0]++' "$visits" | paste -sd, -)"
[[ "$walk2" == 4,5,1,2,3 ]] || { echo "not ok - second walk visited $walk2, want 4,5,1,2,3" >&2; exit 1; }
[[ ! -e "$cursor" ]] || { echo 'not ok - a full lap left the cursor' >&2; exit 1; }
grep -Fq 'intake detail existing_walk start=#4 rows=5 lap_done=true' "$LOG" || { echo 'not ok - second walk line' >&2; cat "$LOG" >&2; exit 1; }
[[ "$INTAKE_WALK_ROWS $INTAKE_WALK_LAP" == '5 true' ]] || { echo "not ok - the station's walk result is $INTAKE_WALK_ROWS $INTAKE_WALK_LAP, want 5 true" >&2; exit 1; }

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
[[ "$(grep -c -- '--slurpfile ops' "$updates")" == 1 ]] || { echo 'not ok - census_partial rows were not one ledger update' >&2; cat "$updates" >&2; exit 1; }
jq -e '[.units[] | select(.issue <= 4)] | all(.hold_handoff_waiting == true and .hold_handoff_wait_issues == [.issue])' "$UNITS" >/dev/null \
  || { echo 'not ok - census_partial rows did not wait' >&2; jq -c '.units[]' "$UNITS" >&2; exit 1; }
jq -e '.units[] | select(.id == "issue-6") | (has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not' "$UNITS" >/dev/null \
  || { echo 'not ok - the stale wait on issue 6 was not cleared' >&2; exit 1; }
grep -Fq 'intake skip counts refill=false added=0 census_partial=4' "$LOG" || { echo 'not ok - census_partial count' >&2; exit 1; }

# A supervisor review unit that already holds the handoff episode and recorded PR has consumed it.
# The issue's own wait blocks its old approval until this point, then must be cleared without re-adding it.
handoff_issue=9417 handoff_pr=9418 handoff_episode='2026-11-07T03:58:28Z'
handoff_fixture() {
  local state_episode="$1"
  jq -n --argjson issue "$handoff_issue" --argjson pr "$handoff_pr" --arg episode "$handoff_episode" \
    '{units:[{id:("issue-"+($issue|tostring)),issue:$issue,branch:("agent/issue-"+($issue|tostring)),stage:"supervisor-review",pr:$pr,hold_handoff_episode:$episode,hold_handoff_wait_issues:[$issue],hold_handoff_waiting:true}]}' > "$UNITS"
  printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"%s","open_pr":%s,"open_branch":"agent/issue-%s"}}\n' \
    "$state_episode" "$handoff_pr" "$handoff_issue" > "$AGENT_HOME/state/$handoff_issue.json"
  printf '{"workers":[{"unit":"issue-%s","harvested":false}]}\n' "$handoff_issue" > "$WORKERS"
  rm -f "$UNITS.view"
  : > "$LOG"
}
stale_handoff_view() { # view issue row that is newer than the ledger but still has the prior cached episode
  jq --arg episode "$1" '.units[0].hold_handoff_episode = $episode' "$UNITS" > "$UNITS.view"
  touch -d '2035-01-01T00:00:00Z' "$UNITS.view"
}
existing_handoff_candidates() { printf '%s\tpr\thandoff\t[]\n' "$handoff_issue"; }
tick_prs() {
  printf '%s\n' '[{"number":9418,"headRefName":"agent/issue-9417","title":"fixture","body":"Refs #9417","labels":[]}]'
}
handoff_fixture "$handoff_episode"
stale_handoff_view 'prior-cache-episode'
register_new_issues 1
grep -Fq 'consumed=1' "$LOG" || { echo 'not ok - matching supervisor-review handoff did not count as consumed' >&2; cat "$LOG" >&2; exit 1; }
jq -e '.units[0] | (has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not' "$UNITS" >/dev/null \
  || { echo 'not ok - consumed handoff kept its own approval wait' >&2; jq -c '.units[0]' "$UNITS" >&2; exit 1; }

# A genuinely new episode is still unconsumed, so its old PR approval stays blocked.
handoff_fixture '2026-11-09T00:00:00Z'
stale_handoff_view "$handoff_episode"
register_new_issues 1
jq -e --argjson issue "$handoff_issue" '.units[0] | .hold_handoff_waiting == true and .hold_handoff_wait_issues == [$issue]' "$UNITS" >/dev/null \
  || { echo 'not ok - unconsumed episode did not keep the approval wait' >&2; jq -c '.units[0]' "$UNITS" >&2; exit 1; }

echo 'ok - a walk reads the units view once and updates the census_partial rows in one ledger write'
