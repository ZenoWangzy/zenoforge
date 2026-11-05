#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

# 2026-11-04 incident regression: a queued writer that is never dispatched must not
# block intake through its footprint; a running worker still must. Plus the once-only
# intake-footprint-hog incident and the orphaned hold_handoff_waiting release that
# stranded issue #4879. Run one section with INTAKE_HOG_SECTION=<name>.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/intake-footprint-hog"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent/state"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false
  | .footprint_mutex.stale_queued_minutes=120 | .footprint_mutex.intake_hog_candidates=2' \
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
AGENT_HOME="$fixture/agent"
export AGENT_HOME

fail() { echo "intake-footprint-hog.test.sh: $*" >&2; exit 1; }
write_units() { jq -n "$@" > "$UNITS"; }
owner_ids() { jqf -c '[.[].id]' <<<"$owners"; }

section_stale_owner_released() {
  # A pending unit whose last ledger progress is older than the bound leaves the
  # intake owner snapshot; a fresh pending unit and a live worker stay owners.
  local stale_at fresh_at conflict
  stale_at="$(date -u -d "@$((NOW_EPOCH - 7200 - 60))" +%Y-%m-%dT%H:%M:%SZ)"
  fresh_at="$STAMP"
  write_units --arg stale "$stale_at" --arg fresh "$fresh_at" '{units:[
    {id:"stale-owner",stage:"implement-pending",task:"never dispatched",
     footprint:["packages/fixture/stale.ts"],history:[{stage:"size-recut-resumed",result:"returned",at:$stale}]},
    {id:"fresh-owner",stage:"implement-pending",task:"queued this tick",
     footprint:["packages/fixture/fresh.ts"],history:[{stage:"supervisor-requeue",result:"r",at:$fresh}]},
    {id:"live-owner",stage:"implement",task:"running",
     footprint:["packages/fixture/live.ts"],history:[{stage:"write-start",result:"[]",at:$fresh}]}]}'
  printf '%s\n' '{"workers":[{"pid":100,"unit":"live-owner","type":"implement","started":"2026-11-04T00:00:00Z"}]}' > "$WORKERS"
  owners="$(intake_footprint_snapshot)" || fail 'intake footprint snapshot failed'
  [[ "$(owner_ids)" == *'"stale-owner"'* ]] && fail 'stale pending unit still blocks intake as a footprint owner'
  [[ "$(owner_ids)" == *'"fresh-owner"'* ]] || fail 'fresh pending unit lost its queued-writer protection'
  [[ "$(owner_ids)" == *'"live-owner"'* ]] || fail 'live worker lost its footprint protection'
  conflict="$(active_footprint_conflict '["packages/fixture/stale.ts"]' "$owners" "__intake-1")" \
    || fail 'footprint comparison failed for the stale scope'
  [[ -z "$conflict" ]] || fail "stale owner still rejected an intake candidate (owner=$conflict)"
  conflict="$(active_footprint_conflict '["packages/fixture/live.ts"]' "$owners" "__intake-2")" \
    || fail 'footprint comparison failed for the live scope'
  [[ "$conflict" == live-owner ]] || fail 'live worker no longer rejects an overlapping intake candidate'
}

section_intake_hog_alert_once() {
  # A stale owner that rejects at least N candidates in one intake run is reported to
  # the supervisor inbox exactly once per stall episode; a progressing owner is not.
  local stale_at
  stale_at="$(date -u -d "@$((NOW_EPOCH - 7200 - 60))" +%Y-%m-%dT%H:%M:%SZ)"
  SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
  cat > "$SCHEDULER_AGENT_LIB" <<'SH'
supervisor_inbox_append_once() {
  local key="$1" message="$2"
  grep -Fqx -- "$key" "$AGENT_HOME/intake-hog-keys" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$AGENT_HOME/intake-hog-keys"
  printf '%s\t%s\n' "$key" "$message" >> "$AGENT_HOME/intake-hog-inbox"
}
SH
  write_units --arg stale "$stale_at" --arg fresh "$STAMP" '{units:[
    {id:"stale-owner",stage:"implement-pending",task:"never dispatched",
     footprint:["packages/fixture/stale.ts"],history:[{stage:"size-recut-resumed",result:"returned",at:$stale}]},
    {id:"fresh-owner",stage:"implement-pending",task:"queued this tick",
     footprint:["packages/fixture/fresh.ts"],history:[{stage:"supervisor-requeue",result:"r",at:$fresh}]}]}'
  : > "$LOG"
  printf 'stale-owner\t101\nstale-owner\t102\nstale-owner\t101\n' | intake_footprint_hog_alert
  printf 'stale-owner\t101\nstale-owner\t102\n' | intake_footprint_hog_alert
  [[ "$(wc -l < "$AGENT_HOME/intake-hog-inbox")" == 1 ]] || fail 'intake-footprint-hog alert was not deduplicated across two intake runs'
  grep -Fq 'unit=stale-owner' "$AGENT_HOME/intake-hog-inbox" && grep -Fq 'blocked=2' "$AGENT_HOME/intake-hog-inbox" \
    || fail 'intake-footprint-hog alert omitted the owner or the distinct candidate count'
  grep -Fq 'intake-footprint-hog unit=stale-owner' "$LOG" || fail 'intake-footprint-hog line missing from scheduler.log'
  printf 'fresh-owner\t201\nfresh-owner\t202\n' | intake_footprint_hog_alert
  grep -Fq 'unit=fresh-owner' "$AGENT_HOME/intake-hog-inbox" \
    && fail 'progressing owner was reported as an intake footprint hog'
  [[ "$(wc -l < "$AGENT_HOME/intake-hog-inbox")" == 1 ]] || fail 'unexpected extra alert for a progressing owner'
}

pending_fixture_stubs() {
  dispatch_calls=0
  dispatch_order() { jqf -c '.units[] | select(.stage | test("-pending$"))' "$UNITS"; }
  ticket_budget_reason() { return 0; }
  loop_rounds() { echo 0; }
  blocking_body_dependency() { return 0; }
  room_for() { return 0; }
  pick() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
  footprint_room() {
    local owner
    owner="$(unit_field "$1" '.footprint_wait_owner // empty')"
    if [[ -n "$owner" ]] && footprint_wait_owner_active "$owner"; then return 1; fi
    set_unit "$1" 'del(.footprint_wait_owner,.footprint_wait_since)'
  }
  ensure_clone() { printf '%s\n' "$ROOT"; }
  resume_handoff_integration() { return 0; }
  verification_plan_for_state() { echo '{}'; }
  verification_plan_brief() { echo focused; }
  matt_method_rule() { :; }
  decision_scope() { :; }
  dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); return 0; }
  live_workers() { echo 0; }
  live_by_type() { echo 0; }
}

section_hold_handoff_orphan_released() {
  # The handoff wait marker is released once no ready-for-agent handoff episode exists,
  # so dispatch no longer strands the unit forever (issue #4879); a live episode keeps it.
  local state_file="$AGENT_HOME/state/556.json"
  : > "$LOG"
  write_units '{units:[
    {id:"issue-555",issue:555,stage:"implement-pending",task:"fixture task",branch:"agent/issue-555",
     hold_handoff_waiting:true,hold_handoff_wait_issues:[555],history:[]}]}'
  pending_fixture_stubs
  dispatch_pending true
  [[ "$dispatch_calls" == 1 ]] || fail "orphaned handoff wait still blocked dispatch (calls=$dispatch_calls)"
  jqf -e '.units[] | select(.id=="issue-555") | (has("hold_handoff_waiting") or has("hold_handoff_wait_issues")) | not' \
    "$UNITS" >/dev/null || fail 'orphaned handoff wait markers were not cleared'
  grep -Fq 'hold handoff wait cleared unit=issue-555' "$LOG" || fail 'handoff wait release was not logged'

  jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"ep-1"}}' > "$state_file"
  write_units '{units:[
    {id:"issue-556",issue:556,stage:"implement-pending",task:"fixture task",branch:"agent/issue-556",
     hold_handoff_waiting:true,hold_handoff_wait_issues:[556],history:[]}]}'
  pending_fixture_stubs
  dispatch_pending true
  [[ "$dispatch_calls" == 0 ]] || fail 'a live handoff episode no longer holds its unit back from dispatch'
  jqf -e '.units[] | select(.id=="issue-556") | .hold_handoff_waiting == true' "$UNITS" >/dev/null \
    || fail 'a live handoff episode lost its wait marker'
  rm -f "$state_file"
}

for section in stale_owner_released intake_hog_alert_once hold_handoff_orphan_released; do
  [[ -z "${INTAKE_HOG_SECTION:-}" || "$INTAKE_HOG_SECTION" == "$section" ]] || continue
  "section_$section"
done

echo 'intake-footprint-hog.test.sh: pass (stale owner released, live owner kept, alert once, handoff orphan released)'
