#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-wip-limits"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=1 | .repair_dispatch_cap=null | .started_wip_limit=11 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
FOCUS_MODE=all
TICK_DISPATCH_PAST_DEADLINE=false
SCHED_LOCK_HELD=true

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
say() { printf '%s\n' "$*" >> "$LOG"; }
live_by_type() {
  jqf -r --arg types "$1" '[.workers[] | select(.type as $type | ($types | split("|") | index($type)) != null)] | length' "$WORKERS"
}
dispatch_capacity_free() { return 0; }
higher_priority_waiting() { return 1; }
priority_admission_has_room() { return 0; }
repair_cap_admission() { return 0; }
repair_runtime_admission() { return 0; }

room_attempt() {
  local id="$1" type="$2" unit="$3"
  if room_for "$id" "$type" "$unit" false false false; then ROOM_RC=0; else ROOM_RC=$?; fi
}
expect_rc() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || fail "$name: expected rc=$expected, got rc=$actual"
}

# An implement worker at its cap must not consume the independent repair dispatch cap.
printf '%s\n' '{"workers":[{"unit":"busy-implement","type":"implement"}]}' > "$WORKERS"
printf '%s\n' '{"units":[{"id":"new-implement","stage":"implement-pending"}]}' > "$UNITS"
DISPATCH_WHY_LAST=(); DISPATCH_WHY_TOUCHED=(); DISPATCH_WHY_DIRTY=false
room_attempt repair-unit repair '{"id":"repair-unit","stage":"repair-pending"}'
expect_rc 'repair at implement cap' 0 "$ROOM_RC"

# Active and merge-wait stages count as started WIP; parked/blocked/needs-human do not; implement starts consume a slot immediately.
jq -n '{units:[
  {id:"implement-active",stage:"implement"},
  {id:"review-active",stage:"review"},
  {id:"review",stage:"review-pending"},
  {id:"rereview-active",stage:"rereview"},
  {id:"rereview",stage:"rereview-pending"},
  {id:"repair-active",stage:"repair"},
  {id:"repair",stage:"repair-pending"},
  {id:"supervise-active",stage:"supervise"},
  {id:"supervise",stage:"supervisor-review"},
  {id:"ready",stage:"ready-to-merge"},
  {id:"landing",stage:"landing"},
  {id:"parked",stage:"parked"},
  {id:"blocked",stage:"blocked-external"},
  {id:"needs-human",stage:"needs-human"},
  {id:"awaiting-event",stage:"awaiting-live-event"},
  {id:"merged",stage:"merged"},
  {id:"not-started",stage:"implement-pending"},
  {id:"second-implement",stage:"implement-pending"}
]}' > "$UNITS"
order_with_wip="$(dispatch_order true)"
[[ "${order_with_wip%%$'\n'*}" == WIP_COUNT=11 ]] || fail "dispatch order WIP snapshot: expected 11, got ${order_with_wip%%$'\n'*}"
# One successful implement start fills the final slot; a later candidate in the same pass must see that increment.
jq 'del(.units[] | select(.id == "landing"))' "$UNITS" > "$MAC_AUTOPILOT_RUNTIME_DIR/units.next.json"
mv "$MAC_AUTOPILOT_RUNTIME_DIR/units.next.json" "$UNITS"
order_with_wip="$(dispatch_order true)"
[[ "${order_with_wip%%$'\n'*}" == WIP_COUNT=10 ]] || fail "near-limit WIP snapshot: expected 10, got ${order_with_wip%%$'\n'*}"
TICK_DISPATCH_PENDING_ACTIVE=true
TICK_STARTED_WIP_COUNT="${order_with_wip%%$'\n'*}"
TICK_STARTED_WIP_COUNT="${TICK_STARTED_WIP_COUNT#WIP_COUNT=}"
printf '%s\n' '{"workers":[]}' > "$WORKERS"
DISPATCH_WHY_LAST=(); DISPATCH_WHY_TOUCHED=(); DISPATCH_WHY_DIRTY=false
TICK_ACTIVE_FOOTPRINTS_VALID=false
dispatch_order=()
start_silent_breaker() { dispatch_order+=(breaker); return 0; }
coord_remote_enabled() { return 0; }
coord_new_owner() { printf 'owner-fixture\n'; }
coord_acquire() { dispatch_order+=(acquire); COORD_REMOTE_RESTORE_REQUIRED=0; return 0; }
coord_assert_owned() { dispatch_order+=(assert); return 0; }
size_admission_write_start() { dispatch_order+=(size-write); return 0; }
footprint_recurrence_brief() { :; }
incident_worker_prompt() { printf '%s' "$3"; }
dispatch_why_clear() { :; }
dispatch_calls=0
dispatch() {
  dispatch_calls=$((dispatch_calls + 1))
  dispatch_order+=(dispatch)
  [[ "$SCHEDULER_DISPATCH_CLAIM_KEY" == unit-not-started && "$SCHEDULER_DISPATCH_CLAIM_OWNER" == owner-fixture ]] \
    || fail 'dispatch did not receive the pre-acquired unit claim'
  dispatch_claim_clear
  return 0
}
new_unit="$(jqf -c '.units[] | select(.id == "not-started")' "$UNITS")"
if dispatch_if_room not-started implement implement impl.log impl.md model high prompt "" "" "" "" "$new_unit" false codex false configured codex; then :; else fail 'implement at WIP 10 did not dispatch'; fi
[[ "$dispatch_calls" == 1 ]] || fail "expected one implement start at WIP 10, got $dispatch_calls"
[[ "${dispatch_order[*]}" == 'breaker acquire assert size-write dispatch' ]] || fail "claim order was ${dispatch_order[*]}"
[[ "$TICK_STARTED_WIP_COUNT" == 11 ]] || fail "successful implement start did not advance WIP to 11 (got $TICK_STARTED_WIP_COUNT)"
units_before="$(sha256sum "$UNITS" | cut -d' ' -f1)"
log_before="$(sha256sum "$LOG" | cut -d' ' -f1)"
coord_remote_enabled() { return 1; }
coord_new_owner() { fail 'coordination-off dispatch generated a claim owner'; return 1; }
coord_acquire() { fail 'coordination-off dispatch acquired a claim'; return 1; }
dispatch_claim_prepare not-started "$new_unit" implement || fail 'coordination-off claim gate refused'
[[ "$(sha256sum "$UNITS" | cut -d' ' -f1)" == "$units_before" ]] || fail 'coordination-off claim gate changed units.json'
[[ "$(sha256sum "$LOG" | cut -d' ' -f1)" == "$log_before" ]] || fail 'coordination-off claim gate changed scheduler.log'
room_attempt second-implement implement '{"id":"second-implement","stage":"implement-pending"}'
expect_rc 'implement at WIP limit' 1 "$ROOM_RC"
grep -Fqx 'dispatch why unit=second-implement gate=wip-limit' "$LOG" || fail 'implement at WIP limit did not record reason wip-limit'
room_attempt repair-at-limit repair '{"id":"repair-at-limit","stage":"repair-pending"}'
expect_rc 'repair at WIP limit' 0 "$ROOM_RC"

(( failures == 0 )) || exit 1
echo 'dispatch-wip-limits.test.sh: pass'
