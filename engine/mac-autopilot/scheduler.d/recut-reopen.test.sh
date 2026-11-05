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

set_unit issue-11 '.note = "stale"'
INTAKE_ADDED=0
[[ -n "$(ticket_budget_reason "$(unit_json issue-11)")" ]] || fail "fixture must start at the stop-loss budget"
intake_reopen_refused_recut 11 "$AGENT_HOME/state/11.json" || fail "refused recut on a ready-for-agent issue must reopen"
u="$(unit_json issue-11)"
[[ "$(jq -r '.stage' <<<"$u")" == implement-pending ]] || fail "unit not reopened: $u"
[[ -z "$(ticket_budget_reason "$u")" ]] || fail "budget not refilled"
[[ "$(jq -r '.history[-1].stage' <<<"$u")" == supervisor-requeue ]] || fail "refill must be a supervisor-requeue entry"
[[ "$(jq -r '.note' <<<"$u")" == null ]] || fail "reopen must clear the stale note"
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
grep -qF '(( existing_only )) || ! intake_reopen_refused_recut' "$engine_dir/mac-autopilot/scheduler.d/intake.sh" || fail "intake call site missing"
echo "recut-reopen.test.sh ok"
