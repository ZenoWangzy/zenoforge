#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/handoff-wait-stale"
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
fail() { echo "handoff-wait-stale.test.sh: $*" >&2; exit 1; }

# A unit flagged hold_handoff_waiting is skipped by dispatch_pending. The flag is stale once no issue in its wait list
# has a ready-for-agent state with a handoff episode (the shape of a unit whose issue became a tracker after the handoff).
state_dir="$AGENT_HOME/state"; mkdir -p "$state_dir"
printf '%s\n' '{"state":"tracker","scheduler_handoff":{"episode":"2026-11-05T05:28:28Z"}}' > "$state_dir/5298.json"
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":{"episode":"hold-2026-11-03T03:02:27Z"}}' > "$state_dir/2095.json"
printf '%s\n' '{"state":"tracker"}' > "$state_dir/4001.json"
printf '%s\n' '{"state":"ready-for-agent","scheduler_handoff":' > "$state_dir/4002.json"
unit() { jq -cn --arg id "issue-$1" --argjson pr "$2" --argjson wait "$3" --argjson pending "${4:-false}" \
  '{id:$id,stage:"review-pending",pr:$pr,branch:("agent/"+$id),lane:"pr",title:"fixture",history:[],hold_handoff_waiting:true,hold_handoff_wait_issues:$wait}
   + (if $pending then {hold_handoff_lookup_pending:true} else {} end)'; }
jq -s '{units:.}' <(unit 5298 504 '[5298]') <(unit 2095 503 '[2095]') <(unit 4001 505 '[4001]' true) <(unit 4002 506 '[4002]') \
  <(unit 4003 507 '[4001,2095]') <(unit 4004 508 '[]') > "$UNITS"

gh() { case "${1:-} ${2:-}" in 'pr list') echo '[]' ;; *) return 97 ;; esac; }
alive() { return 0; }
SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
printf '%s\n' 'supervisor_inbox_append_once() { :; }' > "$SCHEDULER_AGENT_LIB"
pick_review_for_unit() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
verify_handoff_delivery() { return 0; }
ensure_clone() { printf '%s\n' "$ROOT"; }
checkout_pr_head() { return 0; }
review_prompt() { :; }
arbiter_rule() { :; }
hotpatch_rule() { :; }
supervisor_rule() { :; }
dispatch_if_room() { return 0; }
write_workers() { jq -n '{workers:[]}' > "$WORKERS"; LIVE_WORKER_CACHE_UNTIL=0; }
write_workers
handoff_wait_stale issue-5298 || fail "tracker issue's wait was kept"
flag() { jq -r --arg id "$1" '.units[] | select(.id == $id) | .hold_handoff_waiting // false' "$UNITS"; }
[[ "$(flag issue-5298)" == false ]] || fail "stale wait flag was not cleared"
[[ "$(jq -r '.units[] | select(.id == "issue-5298") | has("hold_handoff_wait_issues")' "$UNITS")" == false ]] || fail "stale wait list was kept"
for keep in issue-2095 issue-4001 issue-4002 issue-4003; do
  ! handoff_wait_stale "$keep" || fail "$keep: wait cleared although a handoff is live, pending lookup or unreadable"
  [[ "$(flag "$keep")" == true ]] || fail "$keep: flag lost"
done
handoff_wait_stale issue-4004 || fail "empty wait list was kept"

# dispatch_pending reaches the check: the stale unit is no longer skipped at the flag.
jq -s '{units:.}' <(unit 5298 504 '[5298]') <(unit 2095 503 '[2095]') > "$UNITS"
: > "$LOG"
dispatch_pending true >/dev/null 2>&1 || true
[[ "$(flag issue-5298)" == false ]] || fail "dispatch_pending left the stale flag"
[[ "$(flag issue-2095)" == true ]] || fail "dispatch_pending cleared a live handoff wait"
echo 'handoff-wait-stale.test.sh: pass'
