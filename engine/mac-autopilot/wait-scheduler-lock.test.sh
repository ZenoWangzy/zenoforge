#!/usr/bin/env bash
# wait-scheduler-lock.sh: restart safety for a lock still held by the old tick (KillMode=process).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "wait-scheduler-lock.test.sh: $*" >&2; exit 1; }
export MAC_AUTOPILOT_ROOT="$test_env_root/root"
export MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/rt"
mkdir -p "$MAC_AUTOPILOT_RUNTIME_DIR"
lock="$MAC_AUTOPILOT_RUNTIME_DIR/.scheduler.lock"
log="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
wait_lock() { local t0=$SECONDS; bash "$here/wait-scheduler-lock.sh"; elapsed=$((SECONDS - t0)); }

wait_lock; (( elapsed < 2 )) || fail 'no lock: waited'
mkdir "$lock"; true & dead=$!; wait "$dead"; echo "$dead" > "$lock/pid"
wait_lock; (( elapsed < 2 )) || fail 'lock of a dead holder was not treated as free'
echo garbage > "$lock/pid"
wait_lock; (( elapsed < 2 )) || fail 'lock with an unreadable pid was not treated as free'
[[ ! -s "$log" ]] || fail 'a free lock logged a line'

# Live holder that exits after 2s: the wait ends when it is gone, well inside the bound.
command sleep 2 & holder=$!; echo "$holder" > "$lock/pid"
AUTOPI_LOCK_WAIT_SECONDS=30 wait_lock
(( elapsed >= 1 && elapsed < 10 )) || fail "did not wait for the live holder (elapsed=$elapsed)"
wait "$holder" || :

# Live holder that never leaves: fail open at the bound with a logged line.
command sleep 30 & holder=$!; echo "$holder" > "$lock/pid"
AUTOPI_LOCK_WAIT_SECONDS=2 wait_lock
kill "$holder"; wait "$holder" 2>/dev/null || :
(( elapsed >= 2 && elapsed < 10 )) || fail "bound not honoured (elapsed=$elapsed)"
grep -Eq "pid $holder still holds .scheduler.lock after [0-9]+s; starting anyway" "$log" || fail 'fail-open line not logged'
# A free lock is not a finished tick: a running tick yields the lock in every slow phase. The wait must hold for the tick itself.
export MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup"
mkdir -p "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
printf 'sleep 2; : > "$TICK_DONE"\n' > "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/scheduler.sh"
rm -rf "$lock"; rm -f "$test_env_root/tick-done"
TICK_DONE="$test_env_root/tick-done" bash "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/scheduler.sh" & tick=$!
AUTOPI_LOCK_WAIT_SECONDS=30 wait_lock
[[ -e "$test_env_root/tick-done" ]] || fail 'the loop started while the old tick was still running with the lock free'
wait "$tick" || :
# A tick-shaped process with an argument (a refill, a views run) is not the main tick.
TICK_DONE="$test_env_root/tick-never" bash "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/scheduler.sh" --refill & refill=$!
AUTOPI_LOCK_WAIT_SECONDS=30 wait_lock
[[ ! -e "$test_env_root/tick-never" ]] || fail 'waited for a refill-shaped process as if it were the main tick'
wait "$refill" || :
echo 'wait-scheduler-lock.test.sh: PASS'
