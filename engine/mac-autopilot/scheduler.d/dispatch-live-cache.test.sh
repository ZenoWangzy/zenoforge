#!/usr/bin/env bash
# The live-worker count is read as $(live_workers); a cache refresh inside that subshell is lost, so a pass re-ran the refresh
# (a jq per field and a process-table read for every worker) on every capacity check. dispatch_pending now refreshes in its own shell:
# the number of refreshes in a pass must not grow with the number of pending units.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-live-cache"
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

fail() { echo "dispatch-live-cache.test.sh: $*" >&2; exit 1; }

sha=2222222222222222222222222222222222222222
FIXTURE_PRS="$fixture/prs.json"
gh() { case "${1:-} ${2:-}" in 'pr list') cat "$FIXTURE_PRS" ;; *) return 97 ;; esac; }
alive() { return 0; }
SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
printf '%s\n' 'supervisor_inbox_append_once() { :; }' > "$SCHEDULER_AGENT_LIB"
dispatch_calls=0
pick_review_for_unit() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
verify_handoff_delivery() { return 0; }
ensure_clone() { printf '%s\n' "$ROOT"; }
checkout_pr_head() { return 0; }
review_prompt() { :; }
arbiter_rule() { :; }
hotpatch_rule() { :; }
supervisor_rule() { :; }
review_conflict_to_repair() { return 1; }
dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); return 0; }

# Count refreshes through a file: a call inside $(...) increments nothing in this shell, which is the bug.
REFRESHES="$fixture/refreshes"
eval "real_refresh_live_worker_cache() $(declare -f refresh_live_worker_cache | tail -n +2)"
# The 10 s TTL runs on wall time, so a slow host would add refreshes to a long pass: pin it for the test.
refresh_live_worker_cache() { echo r >> "$REFRESHES"; real_refresh_live_worker_cache; LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 100000)); }

pass_refreshes() { # pending units -> refreshes in one full-tick pass, 3 of 8 slots taken
  local n="$1"
  jq -n --arg sha "$sha" --argjson n "$n" '[range(0; $n) | {number:(500 + .),headRefOid:$sha,headRefName:"agent/issue-\(4900 + .)",baseRefName:"main",
    isDraft:false,title:"fixture",labels:[],body:"",statusCheckRollup:[],mergeable:"UNKNOWN",createdAt:"2026-11-03T00:00:00Z"}]' > "$FIXTURE_PRS"
  jq -n --argjson n "$n" '{units:[range(0; $n) | {id:"issue-\(4900 + .)",stage:"review-pending",pr:(500 + .),branch:"agent/issue-\(4900 + .)",lane:"pr",title:"fixture review",history:[]}]}' > "$UNITS"
  jq -n '{workers:[range(1; 4) | {pid:(100000 + .),unit:("busy-" + tostring),type:"implement"}]}' > "$WORKERS"
  LIVE_WORKER_CACHE_UNTIL=0; TICK_PRS=''; dispatch_calls=0
  : > "$REFRESHES"; : > "$LOG"
  dispatch_pending false
  [[ "$dispatch_calls" == "$n" ]] || fail "$n pending units: $dispatch_calls dispatched, expected $n"
  wc -l < "$REFRESHES" | tr -d ' '
}
small="$(pass_refreshes 5)"; large="$(pass_refreshes 20)"
[[ "$small" == "$large" ]] || fail "refreshes grew with the pending units: 5 units $small, 20 units $large"
(( large == 1 )) || fail "expected a single refresh with the TTL pinned, got $large"
echo "dispatch-live-cache.test.sh: pass (live-worker refreshes per pass: $small for 5 pending units, $large for 20)"
