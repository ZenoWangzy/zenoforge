#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/intake-wip"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
MAX=8
CFG='{"issue_intake":{"enabled":true,"max_upstream":16,"max_ready":30,"ready_buffer":0}}'
HANDOFF_PR_CENSUS='[]' HANDOFF_CENSUS_PARTIAL=0
footprint_waiters_revalidate() { :; }
live_workers() { echo 0; }
hotfix_issue_numbers() { :; }
intake_footprint_snapshot() { echo '[]'; }
scheduler_footprint() { echo '[]'; }
active_footprint_conflict() { :; }
predecessor_candidates() { :; }
intake_candidates() { printf '900\tpr\tfixture\t[]\t%s\n' "$(printf '%s' '{"number":900,"state":"OPEN","subIssuesSummary":{"total":0},"labels":[{"name":"ready-for-agent"}]}' | base64 -w0)"; }
issue_unit_task() { echo '{"task":"fixture","body_blocked_by":[],"labels":[]}'; }
intake_author_gate() { return 0; } # the author gate has its own test (intake-author.test.sh)
fail() { echo "intake-wip.test.sh: $*" >&2; exit 1; }
waiters() { jq -n --argjson n "$1" '{units:[range(0;$n) | {id:("waiter-"+tostring),stage:"implement-pending",footprint_wait_owner:"owner"}]} ' > "$UNITS"; }
waiters 16
register_new_issues 0 true
jq -e 'any(.units[]; .id=="issue-900")' "$UNITS" >/dev/null || fail '16 footprint waiters blocked intake'
waiters 32
: > "$LOG"
register_new_issues 0 true
jq -e '(.units | length)==32' "$UNITS" >/dev/null || fail 'total ceiling allowed intake'
grep -Fq 'intake held: 32 total units upstream (ceiling 32)' "$LOG" || fail 'total ceiling did not log its hold'
# Running development stages consume upstream capacity; all three exclusions share the pending predicate.
jq -n '{units: ([range(0;16) | {id:("running-"+tostring),stage:"review"}] +
  [{id:"supervisor",stage:"implement-pending",supervisor_owned:true},
   {id:"size",stage:"repair-pending",history:[{stage:"supervisor-escalated",result:"size admission: too large"}]}])}' > "$UNITS"
: > "$LOG"
register_new_issues 0 true
jq -e '(.units | length)==18' "$UNITS" >/dev/null || fail 'running units did not consume upstream capacity'
grep -Fq 'intake held: 16 units upstream (max_upstream 16)' "$LOG" || fail 'eligible upstream count included excluded units or omitted running units'
# The ceiling also limits predecessor admission when the merge queue is full.
waiters 31
jq '.units += [{id:"merge",stage:"ready-to-merge"},{id:"blocked",stage:"blocked-external",blocked_on:901}]' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
CFG='{"issue_intake":{"enabled":true,"max_upstream":16,"max_ready":1,"ready_buffer":0}}'
predecessor_candidates() { intake_candidates; printf '901\tpr\tfixture\t[]\t%s\n' "$(printf '%s' '{"number":901,"state":"OPEN","subIssuesSummary":{"total":0},"labels":[{"name":"ready-for-agent"}]}' | base64 -w0)"; }
register_new_issues 0 true
jq -e '[.units[] | select(.stage=="implement-pending")] | length == 32' "$UNITS" >/dev/null || fail 'ceiling did not limit predecessor batch'
# Resuming an existing handoff from outside upstream cannot bypass the ceiling.
CFG='{"issue_intake":{"enabled":true,"max_upstream":16,"max_ready":30}}'
mkdir -p "$AGENT_HOME/state"
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":{"episode":"new"}}' > "$AGENT_HOME/state/902.json"
existing_handoff_candidates() { printf '902\tpr\thandoff\t[]\n'; }
worktree_cleanup_block_reason() { return 1; }
waiters 32
jq '.units += [{id:"issue-902",issue:902,stage:"parked",lane:"pr",history:[]}]' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
: > "$LOG"
register_new_issues 1 reuse
jq -e '.units[] | select(.id=="issue-902") | .stage=="parked"' "$UNITS" >/dev/null || fail 'handoff bypassed total ceiling'
grep -Fq 'ceiling 32); handoff issue #902 deferred' "$LOG" || fail 'handoff ceiling hold not logged'
jq 'del(.units[0])' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
register_new_issues 1 reuse
jq -e '.units[] | select(.id=="issue-902") | .stage=="implement-pending"' "$UNITS" >/dev/null || fail 'handoff did not resume when ceiling had room'
# Held target: a full pass takes nothing, does no candidate work, and leaves the hold marker the station reads.
walked="$test_env_root/walked"; marker="$A/intake-held-since"
predecessor_candidates() { : > "$walked"; }
intake_candidates() { : > "$walked"; printf '900\tpr\tfixture\t[]\t%s\n' "$(printf '%s' '{"number":900,"state":"OPEN","subIssuesSummary":{"total":0},"labels":[{"name":"ready-for-agent"}]}' | base64 -w0)"; }
intake_footprint_snapshot() { : > "$walked"; echo '[]'; }
CFG='{"issue_intake":{"enabled":true,"max_upstream":16,"max_ready":30,"ready_buffer":0}}'
jq -n '{units: [range(0;8) | {id:("p-"+tostring),stage:"implement-pending"}]}' > "$UNITS"
rm -f "$walked" "$marker"; : > "$LOG"
register_new_issues 0
grep -Fq 'intake held: startable pending 8 meets target 8 (live 0 max 8)' "$LOG" || fail 'held line text changed or missing'
[[ ! -e "$walked" ]] || fail 'a held pass did candidate work'
[[ -s "$marker" ]] || fail 'a held pass left no marker'
printf '%s\n' 2026-11-07T00:00:00Z > "$marker"
register_new_issues 0
[[ "$(cat "$marker")" == 2026-11-07T00:00:00Z ]] || fail 'a second held pass moved the hold start'
# Handoffs resume known units while held: they are not new intake, and the ceiling still bounds them.
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":{"episode":"held"}}' > "$AGENT_HOME/state/903.json"
existing_handoff_candidates() { printf '903\tpr\thandoff\t[]\n'; }
jq '.units += [{id:"issue-903",issue:903,stage:"parked",lane:"pr",history:[]}]' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
register_new_issues 1 reuse
jq -e '.units[] | select(.id=="issue-903") | .stage=="implement-pending"' "$UNITS" >/dev/null || fail 'held target blocked a handoff'
[[ -s "$marker" ]] || fail 'a handoff pass cleared the hold'
# Room again: the pass adds a unit and the marker goes.
jq -n '{units: []}' > "$UNITS"
register_new_issues 0
jq -e 'any(.units[]; .id=="issue-900")' "$UNITS" >/dev/null || fail 'intake did not add once the target had room'
[[ ! -e "$marker" ]] || fail 'adding a unit left the hold marker'
# Two ticks with a consumed handoff row: the existing pass must not clear or restart the hold, so the station can see it age past 2 x bound.
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":{"episode":"done"}}' > "$AGENT_HOME/state/905.json"
printf '%s\n' '{"state":"ready-for-agent","state_changed_at":"2026-11-06T00:00:00Z"}' > "$AGENT_HOME/state/906.json"
existing_handoff_candidates() { printf '905\tpr\thandoff\t[]\n'; }
jq -n '{units: ([range(0;8) | {id:("p-"+tostring),stage:"implement-pending"}] + [{id:"issue-905",issue:905,stage:"review",lane:"pr",hold_handoff_episode:"done",history:[]}])}' > "$UNITS"
printf '%s\n' 2026-11-07T00:00:00Z > "$marker"
for tick in 1 2; do
  : > "$LOG"
  register_new_issues 1 reuse
  grep -Fq 'consumed=1' "$LOG" || fail "tick $tick: the handoff row was not consumed"
  [[ "$(cat "$marker")" == 2026-11-07T00:00:00Z ]] || fail "tick $tick: the existing pass moved the hold start"
  register_new_issues 0
  grep -Fq 'intake held: startable pending' "$LOG" || fail "tick $tick: full pass was not held"
  [[ "$(cat "$marker")" == 2026-11-07T00:00:00Z ]] || fail "tick $tick: the held pass moved the hold start"
done
station() {
  local now="$1" created_at issue encoded row
  created_at="$(date -u -d "$now" +%s)"
  issue='{"number":906,"title":"held wait","body":"","state":"OPEN","labels":[{"name":"ready-for-agent"}],"subIssuesSummary":{"total":0}}'
  encoded="$(printf '%s' "$issue" | base64 -w0)"
  printf -v row '906\tpr\theld wait\t["ready-for-agent"]\t%s' "$encoded"
  jq -cn --argjson created_at "$created_at" --arg rows "$row" '{schema:4,created_at:$created_at,rows:$rows}' > "$A/intake-candidates.json"
  python3 "$script_dir/station_health.py" --runtime "$A" --agent-home "$AGENT_HOME" --pause-file "$AGENT_HOME/PAUSE" --now "$now" >/dev/null
  jq -r .stations.intake.status "$A/station-health.json"
}
[[ "$(station 2026-11-07T01:40:00Z)" == HELD ]] || fail 'a hold under 2 x bound must be HELD'
[[ "$(station 2026-11-07T03:10:00Z)" == STALLED ]] || fail 'a hold past 2 x bound must be STALLED'
# units_update: a no-op writes nothing (mtime and inode kept, so the history view cache lives), a change writes, a jq failure keeps the ledger.
jq -n '{units: [{id:"u1",stage:"implement-pending",history:[]}]}' > "$UNITS"
units_update '.'
stat_of() { stat -c '%i %y' "$UNITS"; }
temps() { compgen -G "$UNITS.noop.*" || compgen -G "$UNITS.tmp.*" || true; }
read -t 0.05 <> <(:) || true
before="$(stat_of)"
units_update '.units[0].stage |= .' || fail 'a no-op update returned nonzero'
[[ "$(stat_of)" == "$before" ]] || fail 'a no-op update rewrote the ledger'
read -t 0.05 <> <(:) || true
units_update '.units[0].stage = "review"' || fail 'a real update returned nonzero'
jq -e '.units[0].stage == "review"' "$UNITS" >/dev/null || fail 'a real update did not write'
[[ "$(stat_of)" != "$before" ]] || fail 'a real update kept the old file time and inode'
cp "$UNITS" "$test_env_root/units.keep"; before="$(stat_of)"; rc=0
units_update 'error("boom")' 2>/dev/null || rc=$?
(( rc != 0 )) || fail 'a jq failure returned zero'
[[ "$(stat_of)" == "$before" ]] && cmp -s "$UNITS" "$test_env_root/units.keep" || fail 'a jq failure touched the ledger'
[[ -z "$(temps)" ]] || fail "temp file left behind: $(temps)"
echo 'intake-wip.test.sh: pass'
