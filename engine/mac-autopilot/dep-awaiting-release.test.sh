#!/usr/bin/env bash
# A merged blocker still awaiting release holds a dependent only when the dependent needs it live (dep-disagreement marker or its own text); plain dependents and closed blockers are unchanged.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'dep-awaiting-release.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dep-awaiting-release"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; : > "$LOG"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
scheduler_issue_state() { printf '{}'; }

# Predecessor #10 has a merged unit (the ledger says delivered); the dep cache holds its GitHub state and labels.
blocker_cache() { printf '{"epoch":1,"states":{"10":{"state":"%s","labels":"%s"}}}\n' "$1" "$2" > "$A/dep-check.cache.json"; }
units_with() { # $1 = predecessor stage, $2 = dependent fields
  printf '{"units":[{"id":"issue-10","issue":10,"stage":"%s","history":[]},{"id":"issue-20","issue":20,%s}]}\n' "$1" "$2" > "$UNITS"
}
body_waiter='"stage":"implement-pending","body_blocked_by":[10],"task":"t","branch":"agent/issue-20","history":[]'
text_waiter='"stage":"implement-pending","body_blocked_by":[10],"task":"Needs #10 live before this can run.","branch":"agent/issue-20","history":[]'
zh_waiter='"stage":"implement-pending","body_blocked_by":[10],"task":"本单需要 #10 上线后才能验证。","branch":"agent/issue-20","history":[]'
zh_plain='"stage":"implement-pending","body_blocked_by":[10],"task":"#10 已在 main 上，本票只复用它的接口。","branch":"agent/issue-20","history":[]'
marked_waiter='"stage":"blocked-external","blocked_on":10,"dep_wait_delivery":10,"task":"t","branch":"agent/issue-20","history":[]'
dependent() { jq -c '.units[] | select(.id=="issue-20")' "$UNITS"; }
reset() { DEP_DELIVERED_CACHE=(); TRACKER_KIDS=(); }

# Plain code dependency on a merged, awaiting-release blocker, no signal: dispatched.
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$body_waiter"; blocker_cache MERGED awaiting-release
[[ -z "$(blocking_body_dependency "$(dependent)" || true)" ]] || fail 'a plain dependent of an awaiting-release blocker must dispatch'

# Dep-disagreement marker on an awaiting-release blocker: the dependent waits for release.
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$marked_waiter"; blocker_cache MERGED awaiting-release
dep="$(dep_marker_open "$(dependent)" || true)"
[[ "$dep" == 10 ]] || fail "a dep marker on an awaiting-release blocker must stay open, got '${dep:-none}'"

# The dependent's own text says it needs the blocker live: it waits for release.
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$text_waiter"; blocker_cache MERGED awaiting-release
dep="$(blocking_body_dependency "$(dependent)" || true)"
[[ "$dep" == 10 ]] || fail "a dependent whose text needs #10 live must wait, got '${dep:-none}'"

# VectA tickets are mostly Chinese (11-19 review): "需要 #10 上线" waits; a plain Chinese mention of #10 does not.
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$zh_waiter"; blocker_cache MERGED awaiting-release
dep="$(blocking_body_dependency "$(dependent)" || true)"
[[ "$dep" == 10 ]] || fail "a Chinese ticket that needs #10 上线 must wait, got '${dep:-none}'"
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$zh_plain"; blocker_cache MERGED awaiting-release
[[ -z "$(blocking_body_dependency "$(dependent)" || true)" ]] || fail 'a plain Chinese mention of #10 must dispatch'

# Released: the same marked dependent clears once the blocker carries released.
reset; DEP_DELIVERED_CACHE[10]=1; units_with merged "$marked_waiter"; blocker_cache MERGED released
[[ -z "$(dep_marker_open "$(dependent)" || true)" ]] || fail 'a released blocker must end the dep marker'

# Closed: a dependent of a closed blocker is unaffected.
reset; units_with done "$body_waiter"; blocker_cache CLOSED ''
[[ -z "$(blocking_body_dependency "$(dependent)" || true)" ]] || fail 'a closed blocker must clear its dependent'

echo 'ok - dep-awaiting-release: merged-not-released blockers hold only signalled or live-needing dependents; plain, released and closed clear'
