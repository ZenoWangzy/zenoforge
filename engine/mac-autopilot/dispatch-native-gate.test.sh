#!/usr/bin/env bash
# Engine home of the VectA native blocked-by dispatch test (the pack copy is retired with the patch, VectA #6223).
# Named differently so a same-path pack file cannot shadow it in the build.
set -euo pipefail
mac_autopilot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$mac_autopilot/test-env.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$mac_autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$mac_autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$mac_autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0

fail() { echo "dispatch-native-gate.test.sh: $*" >&2; exit 1; }
write_issue() {
  jq -nc --argjson issue 6121 --arg stage implement-pending --argjson delivered_blocker "${1:-false}" \
    '{units:([{id:"issue-6121",issue:$issue,stage:$stage,lane:"pr",branch:"agent/issue-6121",title:"native blocker regression",task:"Implement the issue slice.",body_blocked_by:[],labels:[],history:[]}]
      + (if $delivered_blocker then [{id:"issue-6120",issue:6120,stage:"merged"}] else [] end))}' \
    > "$UNITS"
}

api_calls="$fixture/api-calls"
gh() {
  if [[ "${1:-}" == api && "$*" == *"dependencies/blocked_by"* ]]; then
    printf '%s\n' "$*" >> "$api_calls"
    if [[ "${NATIVE_BLOCKER_STATE:-open}" == none ]]; then
      printf '[]\n'
      return 0
    fi
    printf '[{"number":6120,"title":"native accounting prerequisite","state":"%s"}]\n' \
      "${NATIVE_BLOCKER_STATE:-open}"
    return 0
  fi
  return 97
}
dispatch_order() { jqf -c '.units[] | select(.stage=="implement-pending")' "$UNITS"; }
ticket_budget_reason() { return 0; }
loop_rounds() { printf '0\n'; }
blocking_body_dependency() { return 0; }
room_for() { return 0; }
pick() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
footprint_room() { return 0; }
ensure_clone() { printf '%s\n' "$ROOT"; }
resume_handoff_integration() { return 0; }
verification_plan_for_state() { printf '{}\n'; }
verification_plan_brief() { printf 'none\n'; }
matt_method_rule() { :; }
decision_scope() { :; }
live_workers() { printf '0\n'; }
live_by_type() { printf '0\n'; }
dispatch_calls=0
captured_prompt=""
dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); captured_prompt="${8:-}"; return 0; }

write_issue
: > "$api_calls"
dispatch_pending true >/dev/null || :
[[ "$dispatch_calls" == 0 ]] || fail "issue #6121 dispatched with open native blocker #6120"
[[ "$(wc -l < "$api_calls" | tr -d ' ')" == 1 ]] || fail 'dispatch did not refresh the native blocked-by edge once'
jqf -e 'any(.units[]; .id == "issue-6121" and .stage == "blocked-external" and .blocked_on == 6120)
  and all(.units[]; .id != "issue-6121" or .stage != "implement-pending")' "$UNITS" >/dev/null \
  || fail 'open native blocker did not park the unit on #6120'

# An undelivered open blocker parks again on the next tick without arming the dep-disagreement real wait (the native gate has its own recheck).
NATIVE_BLOCKER_STATE=open
write_issue
: > "$api_calls"
dispatch_pending true >/dev/null || :
jqf -e 'any(.units[]; .id == "issue-6121" and .stage == "blocked-external" and .blocked_on == 6120 and (.dep_wait_delivery == null))' "$UNITS" >/dev/null \
  || fail 'native park armed the dep-disagreement real wait'

NATIVE_BLOCKER_STATE=open
write_issue true
: > "$api_calls"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null || :
dispatch_pending true >/dev/null || :
[[ "$dispatch_calls" == 2 ]] || fail "open native blocker delivered in the ledger was not dispatched on two ticks (calls=$dispatch_calls)"
[[ "$(wc -l < "$api_calls" | tr -d ' ')" == 2 ]] || fail 'consecutive dispatch ticks did not refresh the native blocked-by edge'
jqf -e 'any(.units[]; .id == "issue-6121" and .stage == "implement-pending" and .blocked_on == null)
  and all(.units[]; .id != "issue-6121" or .stage != "blocked-external")' "$UNITS" >/dev/null \
  || fail 'ledger-delivered open native blocker parked the unit instead of dispatching it'

NATIVE_BLOCKER_STATE=closed
write_issue
: > "$api_calls"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null || :
[[ "$dispatch_calls" == 1 ]] || fail "issue with a closed native blocker was not dispatched once (calls=$dispatch_calls)"
[[ "$captured_prompt" == *'#6120'* && "$captured_prompt" == *'native accounting prerequisite'* && "$captured_prompt" == *'(closed)'* ]] \
  || fail 'implementer prompt did not list the native blocker number, title, and state'
[[ "$(wc -l < "$api_calls" | tr -d ' ')" == 1 ]] || fail 'prompt dispatch did not use its current native blocker snapshot'

NATIVE_BLOCKER_STATE=none
write_issue
: > "$api_calls"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null || :
[[ "$dispatch_calls" == 1 ]] || fail "issue without native blockers was not dispatched once (calls=$dispatch_calls)"
[[ "$captured_prompt" == *'- None'* ]] || fail 'implementer prompt did not say there are no native blockers'
[[ "$(wc -l < "$api_calls" | tr -d ' ')" == 1 ]] || fail 'dispatch did not refresh the empty native blocker list once'

echo 'dispatch-native-gate.test.sh: pass (undelivered open blockers held; ledger-delivered open blockers dispatched; closed blockers listed in implementer prompt)'
