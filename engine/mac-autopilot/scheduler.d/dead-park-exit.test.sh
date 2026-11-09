#!/usr/bin/env bash
# Row 131: cap-default, repair-breaker and budget parks leave through the budget-recut route once per 24h; other parks and owned units stay.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dead-park-exit"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
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

UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SCHED_LOCK_HELD=true
DEAD_PARK_EXIT_PER_TICK=20 # the cap gets its own case at the end
fail() { echo "dead-park-exit.test.sh: $*" >&2; exit 1; }
unit_json() { jq -c --arg id "$1" '.units[] | select(.id == $id)' "$UNITS"; }
events() { jq -r --arg id "$1" '[.units[] | select(.id == $id) | .history[].stage] | join(",")' "$UNITS"; }
stage() { jq -r --arg id "$1" '.units[] | select(.id == $id) | .stage' "$UNITS"; }

ROUTES="$fixture/routes"; CLOSES="$fixture/closes"; : > "$ROUTES"; : > "$CLOSES"
scheduler_route_to_recut() { echo "$1" >> "$ROUTES"; }
tick_pr_state() { echo OPEN; }
tick_prs_changed() { :; }
gh() { [[ "$1 $2" == 'pr close' ]] && { echo "$3" >> "$CLOSES"; return 0; }; return 97; }
PRS='[{"number":9102,"labels":[{"name":"session-owned"}]}]'
tick_prs() { printf '%s' "$PRS"; }

# id issue pr reason park-stage park-result [extra jq fields]: a parked unit whose last history event is the park
parked() {
  local extra="${7:-}"; [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg id "$1" --argjson n "$2" --argjson pr "$3" --arg reason "$4" --arg st "$5" --arg res "$6" --argjson extra "$extra" \
    '{id:$id,issue:$n,pr:$pr,branch:("agent/"+$id),stage:"parked",parked_reason:$reason,history:[{stage:"implement-start",at:"2026-11-01T00:00:00Z"},{stage:$st,result:$res,at:"2026-11-01T01:00:00Z"}]} + $extra'
}
cap_default() { jq -c '.history += [{stage:"supervisor-cap-default",result:"branch=park: cap",at:"2026-11-01T01:00:01Z"}]'; }

{ parked issue-9101 9101 9101 supervisor-budget supervisor-cap-triage-park 'supervisor cap default: cap' | cap_default
  parked issue-9103 9103 9103 repair-breaker repair-breaker 'head abc: 2 consecutive repair runs'
  parked issue-9104 9104 9104 supervisor-budget supervisor-budget-park 'stop-loss budget'
  # owned or outside the classes: all must stay
  parked issue-9102 9102 9102 supervisor-budget supervisor-budget-park 'stop-loss budget'
  parked issue-9105 9105 9105 supervisor-budget supervisor-budget-park 'stop-loss budget' '{"supervisor_owned":true}'
  parked issue-9106 9106 null on-hold size-recut-held 'issue #9106 recut is on hold'
  parked issue-9107 9107 9107 token-hard-park token-park 'hard: 9 tokens'
  parked issue-9108 9108 9108 recut-refused-unpushed supervisor-recut-refused 'unpushed' | cap_default
  parked issue-9109 9109 9109 supervisor-budget supervisor-budget-park 'arbitration budget exhausted for issue-9109 (runs=2 entries=3)'
  parked issue-9110 9110 9110 supervisor-arbitration-cap supervisor-cap-triage-park 'cap triage pending' | cap_default
  parked issue-9111 9111 9111 'stop-loss same failure: x' supervisor-budget-park 'stop-loss budget' | cap_default
  parked issue-9112 9112 9112 supervisor-budget supervisor-budget-park 'stop-loss budget' '{"hold_handoff_waiting":true}'
  parked issue-9113 9113 9113 supervisor-budget supervisor-park 'handed to a session' | cap_default; } | jq -s '{units:.}' > "$UNITS"

# Each class routes to recut once, closes its PR, and records the exit before the recut event.
dead_park_exit
for id in issue-9101 issue-9103 issue-9104; do
  [[ "$(stage "$id")" == closed && "$(events "$id")" == *dead-park-exit,supervisor-budget-recut ]] || fail "$id did not exit through recut: $(unit_json "$id")"
done
[[ "$(sort "$ROUTES" | tr '\n' ' ')" == '9101 9103 9104 ' ]] || fail "routes were: $(cat "$ROUTES")"
[[ "$(sort "$CLOSES" | tr '\n' ' ')" == '9101 9103 9104 ' ]] || fail "PR closes were: $(cat "$CLOSES")"
[[ "$(jq -r '.units[] | select(.id == "issue-9101") | .history[-2].result' "$UNITS")" == 'cap-default park has no automatic exit; sent to recut' ]] || fail "exit event does not name the class"

# Owned, other-class and in-flight handoff units are untouched; the three above prove the pass ran.
for id in issue-9102 issue-9105 issue-9106 issue-9107 issue-9108 issue-9109 issue-9110 issue-9111 issue-9112 issue-9113; do
  [[ "$(stage "$id")" == parked && "$(events "$id")" != *dead-park-exit* ]] || fail "$id must stay parked and untouched: $(unit_json "$id")"
done

# A unit that parks again within 24h is not exited again; a day later it gets a recut again, not a requeue.
set_unit issue-9104 '.stage = "parked" | .recut_routed = null | .history += [{stage:"supervisor-budget-park",result:"stop-loss budget",at:"2026-11-09T00:00:00Z"}]'
: > "$ROUTES"; : > "$CLOSES"
dead_park_exit
[[ "$(stage issue-9104)" == parked && ! -s "$ROUTES" && ! -s "$CLOSES" ]] || fail "second exit inside 24h: $(unit_json issue-9104)"
old="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
set_unit issue-9104 "(.history[] | select(.stage == \"dead-park-exit\") | .at) = \"$old\""
dead_park_exit
[[ "$(stage issue-9104)" == closed && "$(cat "$ROUTES")" == 9104 && "$(cat "$CLOSES")" == 9104 ]] || fail "no recut 25 h after the first exit: $(unit_json issue-9104)"
[[ "$(events issue-9104)" == *supervisor-budget-park,dead-park-exit,supervisor-budget-recut ]] || fail "events: $(events issue-9104)"

# A refused route leaves the unit parked and the PR open; the exit marker still holds it for 24h.
scheduler_route_to_recut() { return 1; }
jq -c --arg id issue-9120 '.units += [{id:$id,issue:9120,pr:9120,branch:"agent/issue-9120",stage:"parked",parked_reason:"repair-breaker",history:[{stage:"repair-breaker",result:"x",at:"2026-11-01T00:00:00Z"}]}]' "$UNITS" | write_state "$UNITS"
: > "$CLOSES"
dead_park_exit
[[ "$(stage issue-9120)" == parked && ! -s "$CLOSES" && "$(events issue-9120)" == repair-breaker,dead-park-exit,supervisor-budget-park ]] || fail "refused route: $(unit_json issue-9120)"
dead_park_exit
[[ "$(events issue-9120)" == repair-breaker,dead-park-exit,supervisor-budget-park ]] || fail "refused route retried inside 24h: $(events issue-9120)"

# At most DEAD_PARK_EXIT_PER_TICK exits per tick.
scheduler_route_to_recut() { echo "$1" >> "$ROUTES"; }
for n in 9131 9132 9133; do
  jq -c --arg id "issue-$n" --argjson n "$n" '.units += [{id:$id,issue:$n,branch:("agent/"+$id),stage:"parked",parked_reason:"repair-breaker",history:[{stage:"repair-breaker",result:"x",at:"2026-11-01T00:00:00Z"}]}]' "$UNITS" | write_state "$UNITS"
done
: > "$ROUTES"
DEAD_PARK_EXIT_PER_TICK=2 dead_park_exit
[[ "$(wc -l < "$ROUTES")" == 2 ]] || fail "per-tick cap not held: $(cat "$ROUTES")"

echo "dead-park-exit.test.sh ok"
