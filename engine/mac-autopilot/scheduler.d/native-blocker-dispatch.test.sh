#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../test-env.sh"
engine_dir="${1:-$(cd -- "$script_dir/../.." && pwd -P)}"
fixture="$(mktemp -d "$test_env_root/native-blocker-dispatch.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0

fail() { echo "native-blocker-dispatch.test.sh: $*" >&2; exit 1; }
write_units() {
  jq -nc --argjson delivered "${1:-false}" --argjson repeat "${2:-false}" \
    '{units:([{id:"issue-6121",issue:6121,stage:"implement-pending",lane:"pr",branch:"agent/issue-6121",
       title:"native blocker regression",task:"Implement the issue slice.",body_blocked_by:[],labels:[],
       history:(if $repeat then [{stage:"blocked-on",result:"#6120"}] else [] end)}]
      + (if $delivered then [{id:"issue-6120",issue:6120,stage:"merged",pr:6120,merge_sha:"abcdef0123456789",history:[]}] else [] end))}' \
    > "$UNITS"
}

API_CALLS="$fixture/api-calls"
INBOX_KEYS="$fixture/inbox.keys"
INBOX_LINES="$fixture/inbox.lines"
export API_CALLS INBOX_KEYS INBOX_LINES
gh() {
  if [[ "${1:-}" == api && "$*" == *"dependencies/blocked_by"* ]]; then
    printf '%s\n' "$*" >> "$API_CALLS"
    if [[ "${NATIVE_BLOCKER_STATE:-open}" == none ]]; then
      printf '[]\n'
    else
      printf '[{"number":6120,"title":"native accounting prerequisite","state":"%s"}]\n' \
        "${NATIVE_BLOCKER_STATE:-open}"
    fi
    return 0
  fi
  return 97
}
dispatch_order() { jqf -c '.units[] | select(.stage=="implement-pending")' "$UNITS"; }
ticket_budget_reason() { return 0; }
loop_rounds() { printf '0\n'; }
subject_of() { printf 'native blocker regression\n'; }
paused_midrun() { return 1; }
footprint_waiters_revalidate() { return 0; }
dispatch_live_prime() { :; }
tick_prs_changed() { :; }
room_for() { return 0; }
pick() { PICK_MODEL=fixture; PICK_EFFORT=high; PICK_PROVIDER=fixture; return 0; }
footprint_room() { return 0; }
blocking_body_dependency() { return 1; }
park_if_body_blocked() { return 1; }
ensure_clone() { printf '%s\n' "$ROOT"; }
resume_handoff_integration() { return 0; }
verification_plan_for_state() { printf '{}\n'; }
verification_plan_brief() { printf 'none\n'; }
matt_method_rule() { :; }
decision_scope() { :; }
feature_verification_prompt() { printf 'none\n'; }
direct_main_worker_prompt() { printf '%s' "$1"; }
live_workers() { printf '0\n'; }
live_by_type() { printf '0\n'; }
dispatch_if_room() {
  dispatch_calls=$((dispatch_calls + 1))
  captured_prompt="${8:-}"
  return 0
}
SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
cat > "$SCHEDULER_AGENT_LIB" <<'EOF'
supervisor_inbox_append_once() {
  if ! grep -Fqx -- "$1" "$INBOX_KEYS" 2>/dev/null; then
    printf '%s\n' "$1" >> "$INBOX_KEYS"
    printf '%s\n' "$2" >> "$INBOX_LINES"
  fi
}
EOF

dispatch_calls=0
captured_prompt=""
write_units
: > "$API_CALLS"
NATIVE_BLOCKER_STATE=open
dispatch_pending true >/dev/null
[[ "$dispatch_calls" == 0 ]] || fail "issue #6121 dispatched with open native blocker #6120"
[[ "$(wc -l < "$API_CALLS" | tr -d ' ')" == 1 ]] || fail 'dispatch did not refresh the native blocked-by edge once'
jqf -e 'any(.units[]; .id == "issue-6121" and .stage == "blocked-external" and .blocked_on == 6120)
  and all(.units[]; .id != "issue-6121" or .stage != "implement-pending")' "$UNITS" >/dev/null \
  || fail 'open native blocker did not park the unit on #6120'

write_units true
: > "$API_CALLS"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null
dispatch_pending true >/dev/null
[[ "$dispatch_calls" == 2 ]] || fail "open native blocker delivered in the ledger was not dispatched on two ticks (calls=$dispatch_calls)"
[[ "$(wc -l < "$API_CALLS" | tr -d ' ')" == 2 ]] || fail 'consecutive dispatch ticks did not refresh the native blocked-by edge'
[[ "$captured_prompt" == *'#6120'* && "$captured_prompt" == *'native accounting prerequisite'* && "$captured_prompt" == *'(open)'* ]] \
  || fail 'implementer prompt did not list the ledger-delivered native blocker'
jqf -e 'any(.units[]; .id == "issue-6121" and .stage == "implement-pending" and .blocked_on == null)
  and all(.units[]; .id != "issue-6121" or .stage != "blocked-external")' "$UNITS" >/dev/null \
  || fail 'ledger-delivered open native blocker parked the unit instead of dispatching it'

NATIVE_BLOCKER_STATE=closed
write_units
: > "$API_CALLS"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null
[[ "$dispatch_calls" == 1 ]] || fail "issue with a closed native blocker was not dispatched once (calls=$dispatch_calls)"
[[ "$captured_prompt" == *'#6120'* && "$captured_prompt" == *'native accounting prerequisite'* && "$captured_prompt" == *'(closed)'* ]] \
  || fail 'implementer prompt did not list the native blocker number, title, and state'
[[ "$(wc -l < "$API_CALLS" | tr -d ' ')" == 1 ]] || fail 'prompt dispatch did not use its current native blocker snapshot'

NATIVE_BLOCKER_STATE=none
write_units
: > "$API_CALLS"
dispatch_calls=0
captured_prompt=""
dispatch_pending true >/dev/null
[[ "$dispatch_calls" == 1 ]] || fail "issue without native blockers was not dispatched once (calls=$dispatch_calls)"
[[ "$captured_prompt" == *'- None'* ]] || fail 'implementer prompt did not say there are no native blockers'
[[ "$(wc -l < "$API_CALLS" | tr -d ' ')" == 1 ]] || fail 'dispatch did not refresh the empty native blocker list once'

NATIVE_BLOCKER_STATE=open
write_units false true
: > "$API_CALLS"; : > "$INBOX_KEYS"; : > "$INBOX_LINES"
dispatch_calls=0
dispatch_pending true >/dev/null
jqf '(.units[] | select(.id=="issue-6121")) |= (del(.dep_wait_delivery,.unpark_condition) | .stage="implement-pending")' \
  "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
dispatch_pending true >/dev/null
[[ "$(wc -l < "$INBOX_KEYS" | tr -d ' ')" == 1 ]] || fail 'repeat blocked native dependency emitted more than one inbox key'
[[ "$(cat "$INBOX_KEYS")" == 'dep-disagreement:issue-6121:6120' ]] || fail 'inbox key was not scoped to this unit and blocker'
[[ "$(cat "$INBOX_LINES")" == 'dep-disagreement unit=issue-6121: a worker blocked twice on #6120 after a release; it now waits for #6120 to be delivered' ]] \
  || fail 'repeat blocked native dependency emitted the wrong inbox line'

echo 'native-blocker-dispatch.test.sh: pass (open blockers park; ledger-delivered blockers dispatch; prompt lists blockers; inbox deduplicates by unit and dependency)'
