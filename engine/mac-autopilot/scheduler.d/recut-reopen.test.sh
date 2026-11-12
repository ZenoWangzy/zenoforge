#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/recut-reopen"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$AGENT_HOME/state"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
STAMP="2026-01-03T00:00:00Z"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true

fail() { echo "recut-reopen.test.sh: $*" >&2; exit 1; }
unit_json() { jq -c --arg id "$1" '.units[] | select(.id == $id)' "$UNITS"; }
starts() { jq -n --argjson n "$TICKET_ROUND_BUDGET" '[range($n) | {stage:"write-start",at:"2026-01-01T00:00:00Z",work_type:"implement"}]'; }
# unit id, issue, last history stage, close time; state file: issue, label state, refused time ("" = none)
closed_unit() {
  jq -n --arg id "issue-$1" --argjson n "$1" --arg last "$2" --arg at "$3" --argjson starts "$(starts)" \
    '{id:$id,issue:$n,branch:("agent/issue-"+($n|tostring)),stage:"closed",history:($starts+[{stage:$last,at:$at}])}'
}
state_file() { jq -n --arg s "$2" --arg r "$3" '{state:$s} + (if $r == "" then {} else {recut_refused_at:$r} end)' > "$AGENT_HOME/state/$1.json"; }

{ closed_unit 11 supervisor-budget-recut 2026-01-02T00:00:00Z
  closed_unit 12 supervisor-budget-recut 2026-01-02T00:00:00Z
  closed_unit 13 supervisor-cap-triage-recut 2026-01-02T00:00:00Z
  closed_unit 14 supervisor-budget-recut 2026-01-02T00:00:00Z
  closed_unit 15 supervisor-budget-recut 2026-01-02T00:00:00Z; } | jq -s '{units:.}' > "$UNITS"
state_file 11 ready-for-agent 2026-01-02T00:10:00Z   # refused after the close: reopen
state_file 12 ready-for-agent ""                      # closed with no refused recut
state_file 13 ready-for-agent 2026-01-02T00:10:00Z   # cap-triage recut also reopens
state_file 14 needs-triage 2026-01-02T00:10:00Z      # issue not ready-for-agent
state_file 15 ready-for-agent 2026-01-01T12:00:00Z   # stale refusal from before the close

set_unit issue-11 '.note = "stale" | .recut_routed = true'
INTAKE_ADDED=0
[[ -n "$(ticket_budget_reason "$(unit_json issue-11)")" ]] || fail "fixture must start at the stop-loss budget"
intake_reopen_refused_recut 11 "$AGENT_HOME/state/11.json" || fail "refused recut on a ready-for-agent issue must reopen"
u="$(unit_json issue-11)"
[[ "$(jq -r '.stage' <<<"$u")" == implement-pending ]] || fail "unit not reopened: $u"
[[ -z "$(ticket_budget_reason "$u")" ]] || fail "budget not refilled"
[[ "$(jq -r '.history[-1].stage' <<<"$u")" == supervisor-requeue ]] || fail "refill must be a supervisor-requeue entry"
[[ "$(jq -r '.note' <<<"$u")" == null ]] || fail "reopen must clear the stale note"
[[ "$(jq -r '.recut_routed' <<<"$u")" == null ]] || fail "reopen must clear the route record, or a later stop-loss closes the PR with nothing routed"
intake_reopen_refused_recut 13 "$AGENT_HOME/state/13.json" || fail "cap-triage recut must reopen"
[[ "$INTAKE_ADDED" == 2 ]] || fail "each reopen must count as an intake admission, got $INTAKE_ADDED"

for n in 12 14 15; do
  ! intake_reopen_refused_recut "$n" "$AGENT_HOME/state/$n.json" || fail "issue $n must stay closed"
  [[ "$(jq -r '.stage' <<<"$(unit_json "issue-$n")")" == closed ]] || fail "issue $n changed"
done

# Second stop-loss after the reopen, then a second refused recut: stays closed, one log line.
set_unit issue-11 ".history += $(starts) | .history += [{stage:\"supervisor-budget-recut\",at:\"2026-01-03T01:00:00Z\"}] | .stage = \"closed\""
state_file 11 ready-for-agent 2026-01-03T01:10:00Z
for _ in 1 2; do ! intake_reopen_refused_recut 11 "$AGENT_HOME/state/11.json" || fail "second stop-loss must not reopen"; done
[[ "$(jq -r '.stage' <<<"$(unit_json issue-11)")" == closed ]] || fail "second stop-loss reopened the unit"
[[ "$(grep -c 'issue-11 issue=#11: stop-loss budget already refilled once' "$LOG")" == 1 ]] || fail "expected exactly one log line"
# A retired closed unit sits in units-archive.json: the reopen must still find it, restore it to the hot ledger, and not
# leave a second issue-16 row behind.
closed_unit 16 supervisor-budget-recut 2026-01-02T00:00:00Z | jq -s '{units:.}' > "$UNITS_ARCHIVE"
state_file 16 ready-for-agent 2026-01-02T00:10:00Z
[[ -z "$(unit_json issue-16)" ]] || fail "fixture: issue-16 must start archived only"
intake_reopen_refused_recut 16 "$AGENT_HOME/state/16.json" || fail "archived closed unit must reopen"
[[ "$(jq -r '.stage' <<<"$(unit_json issue-16)")" == implement-pending ]] || fail "archived unit not reopened"
[[ "$(jq '[.units[] | select(.id == "issue-16")] | length' "$UNITS")" == 1 ]] || fail "reopen duplicated issue-16 in the ledger"
echo "$(jq -c . "$UNITS_ARCHIVE")" | jq -e 'any(.units[]; .id == "issue-16")' >/dev/null || fail "archive row must stay (append-only)"
# The cap default records its decision after the recut event; a refused recut must still reopen that unit.
jq --argjson u "$(closed_unit 17 supervisor-cap-triage-recut 2026-01-02T00:00:00Z | jq -c '.history += [{stage:"supervisor-cap-default",at:"2026-01-02T00:00:00Z"}]')" '.units += [$u]' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
state_file 17 ready-for-agent 2026-01-02T00:10:00Z
intake_reopen_refused_recut 17 "$AGENT_HOME/state/17.json" || fail "a cap-default recut must reopen when recut refuses"
grep -qF '(( existing_only )) || ! intake_reopen_refused_recut' "$engine_dir/mac-autopilot/scheduler.d/intake.sh" || fail "intake call site missing"
# Closed units under an open issue act by themselves (closed-units-auto). The exclusion is the hold, not a list of issue numbers.
cu_unit() { # issue stage last-history-stage [extra jq]
  jq -n --argjson n "$1" --arg stage "$2" --arg last "$3" '{id:("issue-"+($n|tostring)),issue:$n,branch:("agent/issue-"+($n|tostring)),stage:$stage,history:[{stage:$last,at:"2026-01-02T00:00:00Z"}]}'
}
cu_recut_requeue_pr_closed() {
  cu_unit "$1" closed supervisor-cap-triage-recut \
    | jq '.history += [{stage:"supervisor-requeue",at:"2026-01-02T00:01:00Z"},{stage:"pr-closed",at:"2026-01-02T00:02:00Z"}]'
}
cu_state() { jq -n --argjson extra "${3:-{\}}" --arg from "$2" '{state:"ready-for-agent",state_changed_from:$from,state_changed_at:"2026-01-01T00:00:00Z"} + $extra' > "$AGENT_HOME/state/$1.json"; }
cu_episode() { jq -r '.scheduler_handoff.episode // "none"' "$AGENT_HOME/state/$1.json"; }
{ cu_unit 21 merged merged; cu_unit 22 closed supervisor-cap-triage-recut; cu_unit 23 closed obsolete; cu_unit 24 merged merged
  cu_unit 25 closed supervisor-cap-triage-recut; cu_unit 26 merged merged; cu_unit 27 merged merged; cu_unit 28 merged merged; } | jq -s '{units:.}' > "$UNITS"
cu_state 21 needs-hold                                   # delivered, nobody decided since: nothing acts (no signal says the PR did the whole work)
cu_state 22 needs-hold                                   # closed by a stop-loss recut: restore once
cu_state 23 needs-hold                                   # closed on purpose: stays closed
cu_state 24 needs-triage '{"state_changed_at":"2026-01-03T00:00:00Z"}'  # triage ruled after the merge: restore as the next slice
cu_state 25 needs-hold '{"hold":{"holder":"head"}}'      # held: not touched
cu_state 26 needs-hold '{"external_deliverable":{"required":true}}'
cu_state 27 needs-hold '{"attempts":4}'                  # at CONCLUDE_RUN_ATTEMPT_CAP
cu_state 28 needs-triage '{"state_changed_at":"2026-01-03T00:00:00Z"}'  # ruled after the merge, but still owed its awaiting-release write
set_unit issue-28 '.awaiting_release_pending = 99'
CU_ROUTED=""
scheduler_issue_transition() { CU_ROUTED+=" $1:$2"; }
intake_ruling_episodes 21 22 23 24 25 26 27 28
intake_closed_unit_rows 21 22 23 24 25 26 27 28
[[ -z "$CU_ROUTED" ]] || fail "no closed-unit path may route a delivered issue to triage (it would conclude on a partial PR), got:$CU_ROUTED"
[[ "$(cu_episode 24)" == ruling-2026-01-03T00:00:00Z ]] || fail "a triage ruling after a merge must restore it as the next slice"
[[ "$(cu_episode 22)" == "ruling-$STAMP" ]] || fail "a recut-closed unit must be restored"
[[ "$(unit_json issue-22 | jq -r .closed_units_restored_at)" == "$STAMP" ]] || fail "restore must be marked on the unit"
for n in 21 23 25 26 27 28; do [[ "$(cu_episode $n)" == none ]] || fail "issue $n must take no episode"; done
# One restore per unit: the unit closes again, a later tick leaves it closed and says so once.
set_unit issue-22 '.stage = "closed" | .history += [{stage:"supervisor-cap-triage-recut",at:"2026-01-04T00:00:00Z"}]'
cu_state 22 needs-hold
for _ in 1 2; do intake_closed_unit_rows 22; done
[[ "$(cu_episode 22)" == none ]] || fail "a unit restored once must not be restored again"
[[ "$(grep -c 'issue-22 issue=#22: already restored once' "$LOG")" == 1 ]] || fail "expected exactly one refusal line"
# The hold ends: the same issue acts again.
cu_state 25 needs-hold
intake_closed_unit_rows 25
[[ "$(cu_episode 25)" == "ruling-$STAMP" ]] || fail "an issue whose hold is gone must act again"
grep -qF 'intake_closed_unit_rows "${intake_terminal_rows[@]}"' "$engine_dir/mac-autopilot/scheduler.d/intake.sh" || fail "intake call site missing"
# A recut closes its own PR; a later supervisor-requeue may be followed by the PR-close observation.
{ cu_recut_requeue_pr_closed 29; cu_unit 30 closed pr-closed; } | jq -s '{units:.}' > "$UNITS"
cu_state 29 needs-hold
cu_state 30 needs-hold
intake_closed_unit_rows 29 30
[[ "$(cu_episode 29)" == "ruling-$STAMP" ]] || fail "a recut followed by requeue and pr-closed must restore once"
[[ "$(unit_json issue-29 | jq -r '.closed_units_restored_at // "none"')" == "$STAMP" ]] || fail "recut restore must be recorded"
[[ "$(cu_episode 30)" == none && "$(unit_json issue-30 | jq -r .stage)" == closed ]] || fail "pr-closed without a recut must stay closed"
set_unit issue-29 '.stage = "closed"'
cu_state 29 needs-hold
intake_closed_unit_rows 29
[[ "$(cu_episode 29)" == none && "$(unit_json issue-29 | jq -r '.closed_units_restore_refused // false')" == true ]] || fail "recut restore must not happen twice"
# hold.sh --rule --ready on a tracker parent (vecta#6299 shape) is a ruling: one episode, from the tracker state.
jq --argjson u "$(closed_unit 31 supervisor-budget-recut 2026-01-02T00:00:00Z)" '.units += [$u]' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
cu_state 31 tracker '{"state_changed_at":"2026-01-03T00:00:00Z"}'
intake_ruling_episodes 31
[[ "$(cu_episode 31)" == "ruling-2026-01-03T00:00:00Z" ]] || fail "a ready ruling from tracker must record a ruling episode"
intake_ruling_episodes 31
[[ "$(cu_episode 31)" == "ruling-2026-01-03T00:00:00Z" ]] || fail "a repeated tick must not move the ruling episode"
echo "recut-reopen.test.sh ok"
