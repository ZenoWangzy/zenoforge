#!/usr/bin/env bash
# set_unit's dispatch detail ledger_write line names the lock wait, the write and the lock holder's phase, so a slow pass shows whom to fix.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-ledger-wait"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[{"id":"issue-1","stage":"parked","issue":1,"pr":null,"history":[]}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "dispatch-ledger-wait.test.sh: $*" >&2; exit 1; }
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
: > "$LOG"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A contended lock: the wait takes at least 2 s on the SECONDS clock, then the lock is ours.
printf '%s\n' dispatch_pending > "$A/.tick-phase"
acquire_scheduler_lock_wait() { local t=$SECONDS; while (( SECONDS - t < 2 )); do sleep 0.1; done; SCHED_LOCK_HELD=true; }
release_scheduler_lock() { SCHED_LOCK_HELD=false; }
SCHED_LOCK_HELD=false TICK_DISPATCH_PENDING_ACTIVE=true
set_unit issue-1 '.note="waited for the lock"' || fail "set_unit returned rc $?"

line="$(grep -F 'dispatch detail ledger_write unit=issue-1' "$LOG" || true)"
[[ -n "$line" ]] || fail "no ledger_write line after a 2 s lock wait: $(cat "$LOG")"
[[ "$line" == *'lock_wait='* ]] || fail "ledger_write line has no lock_wait=: $line"
[[ "$line" == *'holder_phase=dispatch_pending'* ]] || fail "ledger_write line has no holder_phase= of the lock holder: $line"
[[ "$(jq -r '.units[0].note' "$UNITS")" == 'waited for the lock' ]] || fail "the write itself did not land"

# A write to an id with no row fails with rc 3, is logged, and leaves units.json byte-identical.
cp "$UNITS" "$A/units.before"
rc=0; set_unit issue-404 '.note="lost"' || rc=$?
[[ "$rc" == 3 ]] || fail "set_unit on a missing id returned rc $rc, want 3"
grep -Fq 'ledger-write-missed unit=issue-404 caller=' "$LOG" || fail "no ledger-write-missed line: $(cat "$LOG")"
cmp -s "$A/units.before" "$UNITS" || fail "units.json changed on a write that matched no row"

echo "dispatch-ledger-wait.test.sh ok"
