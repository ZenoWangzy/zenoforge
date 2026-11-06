#!/usr/bin/env bash
# The end-of-tick dispatch_pending runs only when something it reads changed since the first pass.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'dispatch-dirty-gate.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dispatch-dirty-gate"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
base='{"units":[{"id":"a","stage":"implement-pending"},{"id":"b","stage":"implement","note":"x"},{"id":"c","stage":"merged","note":"x"}]}'
printf '%s\n' "$base" > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; : > "$LOG"
live=1; live_workers() { printf '%s\n' "$live"; }
MAIN_HEAD=aaa

fp0="$(dispatch_inputs_fingerprint)"
[[ "$(dispatch_inputs_fingerprint)" == "$fp0" ]] || fail 'fingerprint is not stable'
changed() { # label jq-filter: ledger edit that must change the fingerprint
  printf '%s\n' "$base" | jq -c "$2" > "$UNITS"
  [[ "$(dispatch_inputs_fingerprint)" != "$fp0" ]] || fail "$1 did not change the fingerprint"
}
unchanged() {
  printf '%s\n' "$base" | jq -c "$2" > "$UNITS"
  [[ "$(dispatch_inputs_fingerprint)" == "$fp0" ]] || fail "$1 changed the fingerprint"
}
changed 'stage change' '.units[0].stage="implement"'
changed 'new pending unit' '.units += [{id:"d",stage:"repair-pending"}]'
changed 'footprint owner mark' '.units[0].footprint_wait_owner="b"'
changed 'owner leaving the ledger' 'del(.units[1])'
unchanged 'note edit' '.units[1].note="y"'
unchanged 'terminal unit change' '.units[2].note="z" | .units[2].stage="closed"'
printf '%s\n' "$base" > "$UNITS"
live=2; [[ "$(dispatch_inputs_fingerprint)" != "$fp0" ]] || fail 'worker count change did not change the fingerprint'
live=1; MAIN_HEAD=bbb; [[ "$(dispatch_inputs_fingerprint)" != "$fp0" ]] || fail 'main change did not change the fingerprint'
MAIN_HEAD=aaa

runs=0; phase_yield_lock() { [[ "$1" == dispatch_pending ]] && runs=$((runs + 1)); return 0; }
TICK_DISPATCH_FP=''; dispatch_pending_if_dirty; (( runs == 1 )) || fail 'ran no second pass without a first-pass fingerprint'
TICK_DISPATCH_FP="$fp0"; dispatch_pending_if_dirty; (( runs == 1 )) || fail 'unchanged inputs still ran the second pass'
grep -q 'second dispatch_pending skipped' "$LOG" || fail 'skip was not logged'
live=3; dispatch_pending_if_dirty; (( runs == 2 )) || fail 'changed inputs did not run the second pass'

grep -Fq 'phase_yield_lock dispatch_pending && TICK_DISPATCH_FP="$(dispatch_inputs_fingerprint)"' "$script_dir/scheduler.sh" \
  || fail 'the first dispatch_pending does not record the fingerprint'
grep -Fq 'supervisor_marking_deferred || dispatch_pending_if_dirty' "$script_dir/scheduler.sh" \
  || fail 'the end-of-tick dispatch_pending is not gated'
printf 'ok - second dispatch_pending is gated on a ledger/worker/main fingerprint\n'

# PAUSE set while a tick is already running stops dispatch and the merge phases.
PAUSE_FILE="$fixture/pause"; rm -f "$PAUSE_FILE"; : > "$LOG"
if paused_midrun probe; then fail 'paused_midrun fired without a PAUSE file'; fi
touch "$PAUSE_FILE"
footprint_waiters_revalidate() { return 0; }
dispatch_order() { printf '%s\n' '{"id":"a","stage":"implement-pending"}'; }
room_for() { fail 'dispatch reached a candidate after PAUSE'; }
dispatch_pending true
grep -q 'dispatch stopped: paused by' "$LOG" || fail 'dispatch did not log the mid-run PAUSE stop'
rm -f "$PAUSE_FILE"
grep -Fq 'if ! paused_midrun "acting phases"; then' "$script_dir/scheduler.sh" || fail 'the merge phases are not gated on a mid-run PAUSE'
grep -Fq 'paused_midrun "refill merge" ||' "$script_dir/scheduler.sh" || fail 'the refill merge is not gated on a mid-run PAUSE'
printf 'ok - PAUSE set mid-run stops dispatch and the merge phases\n'

# A refill reads the delivery snapshot before its first dispatch: release_dependency_blocks, which fills it, runs on full ticks only.
order=''
dep_delivered_snapshot() { order+='snapshot '; }
phase() { order+="$1 "; }
run_refill_intake_dispatch_phases
[[ "$order" == 'snapshot dispatch_pending register_new_issues ' ]] || fail "refill phases out of order: $order"
printf 'ok - a refill fills the delivery snapshot before it dispatches\n'
