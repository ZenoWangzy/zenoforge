#!/usr/bin/env bash
# acquire_scheduler_lock never takes a lock whose holder has not written its pid yet: a young pid-less lock is busy, an old one is reclaimed and logged.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/locks-views-empty-pid"
rm -rf -- "$fixture"
mkdir -p "$fixture"
fail() { echo "locks-views-empty-pid.test.sh: $*" >&2; exit 1; }

probe="$fixture/probe.sh"
cat > "$probe" <<'PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
if acquire_scheduler_lock; then echo acquired; else echo refused; fi
PROBE
run_probe() { # $1: lock dir
  env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$1" LOG="$1.log" STAMP=test bash "$probe"
}

# A lock dir just made by a holder that has not written its pid yet is busy, and it stays in place.
fresh="$fixture/fresh.lock"
mkdir "$fresh"
[[ "$(run_probe "$fresh")" == refused ]] || fail 'a just-created pid-less lock was taken from its holder'
[[ -d "$fresh" ]] || fail 'a just-created pid-less lock was removed'

# The same pid-less lock, 60 s old, is abandoned: taken and logged.
old="$fixture/old.lock"
mkdir "$old"
touch -d '60 seconds ago' "$old"
[[ "$(run_probe "$old")" == acquired ]] || fail 'an abandoned pid-less lock was not reclaimed'
grep -q 'scheduler lock: reclaimed an abandoned lock with no pid (age [0-9]*s)' "$old.log" || fail 'reclaim of an abandoned pid-less lock was not logged'

# A live holder whose start ticks match is still busy.
live="$fixture/live.lock"
sleep 30 & holder=$!
start="$(source "$script_dir/../../coord.sh"; coord_process_start_ticks "$holder")"
mkdir "$live"
printf '%s\n' "$holder" > "$live/pid"
printf '%s\n' "$start" > "$live/start"
result="$(run_probe "$live")"
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
[[ "$result" == refused ]] || fail "a live holder with a matching start was taken: $result"

# A rival rewrites pid right after this holder writes it: the holder must not believe it still owns the lock.
lost="$fixture/lost.sh"
cat > "$lost" <<'LOST'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
echo() { builtin echo 999; } # stands in for a rival that wins the pid write
if acquire_scheduler_lock; then builtin echo acquired; else builtin echo refused; fi
LOST
lost_lock="$fixture/lost.lock"
[[ "$(env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$lost_lock" LOG="$lost_lock.log" STAMP=test bash "$lost")" == refused ]] || fail 'a lost pid write still acquired the lock'
[[ "$(cat "$lost_lock/pid")" == 999 ]] || fail 'the rival pid was overwritten'

# A hold or a wait at or over SCHED_LOCK_HOLD_LOG_SECS logs one line with its phases or holders (lock-hold-log); a short one logs nothing.
command sleep 30 & holder_a=$!
command sleep 30 & holder_b=$!
stop_holders() { kill -KILL "$holder_a" "$holder_b" 2>/dev/null || :; wait "$holder_a" "$holder_b" 2>/dev/null || :; }
hold_probe="$fixture/hold-log.sh"
cat > "$hold_probe" <<'HOLD_PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
SCHED_LOCK_HOLDER_PHASE=phase_a
acquire_scheduler_lock
printf '%s\t%s\n' "$BASHPID" phase_b > "$SCHED_LOCK/holder-phase"
command sleep "$HOLD_SECS"
release_scheduler_lock
HOLD_PROBE
run_hold() { env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$1" LOG="$1.log" STAMP=test SCHED_LOCK_HOLD_LOG_SECS=1 HOLD_SECS="$2" bash "$hold_probe"; }
run_hold "$fixture/hold-long.lock" 1.2 || { stop_holders; fail 'hold probe failed'; }
grep -q 'scheduler lock hold pid=[0-9]* secs=1 from_phase=phase_a to_phase=phase_b$' "$fixture/hold-long.lock.log" \
  || { stop_holders; fail 'a 1.2 s hold over the 1 s threshold logged no hold line with both phases'; }
run_hold "$fixture/hold-short.lock" 0 || { stop_holders; fail 'short hold probe failed'; }
if grep -q 'scheduler lock hold' "$fixture/hold-short.lock.log" 2>/dev/null; then stop_holders; fail 'a short hold logged a hold line'; fi

wait_probe="$fixture/wait-log.sh"
cat > "$wait_probe" <<'WAIT_PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
polls=0
sleep() { # stands in for the poll wait: holder A, then holder B, then the lock is released
  polls=$((polls + 1))
  case "$polls" in
    1) printf '%s\t%s\n' "$HOLDER_B" phase_b > "$SCHED_LOCK/holder-phase"; echo "$HOLDER_B" > "$SCHED_LOCK/pid" ;;
    2) rm -rf -- "$SCHED_LOCK" ;;
  esac
  command sleep 0.6
}
SCHED_LOCK_HOLDER_PHASE=phase_w
acquire_scheduler_lock_wait
release_scheduler_lock
echo acquired
WAIT_PROBE
wait_lock="$fixture/wait-long.lock"
mkdir "$wait_lock"; echo "$holder_a" > "$wait_lock/pid"; printf '%s\t%s\n' "$holder_a" phase_a > "$wait_lock/holder-phase"
wait_out="$(env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$wait_lock" LOG="$wait_lock.log" STAMP=test SCHED_LOCK_HOLD_LOG_SECS=1 HOLDER_B="$holder_b" bash "$wait_probe" 2>&1)" \
  || { stop_holders; fail "wait probe failed: $wait_out"; }
[[ "$wait_out" == acquired ]] || { stop_holders; fail "wait probe did not take the lock: $wait_out"; }
grep -q "scheduler lock wait pid=[0-9]* secs=1 phase=phase_w holders=$holder_a/phase_a,$holder_b/phase_b\$" "$wait_lock.log" \
  || { stop_holders; fail 'a wait that saw two holders in turn logged no wait line naming both'; }
short_lock="$fixture/wait-short.lock"
wait_out="$(env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$short_lock" LOG="$short_lock.log" STAMP=test SCHED_LOCK_HOLD_LOG_SECS=1 bash "$wait_probe" 2>&1)" \
  || { stop_holders; fail "short wait probe failed: $wait_out"; }
if grep -q 'scheduler lock wait' "$short_lock.log" 2>/dev/null; then stop_holders; fail 'a short wait logged a wait line'; fi
stop_holders

echo 'locks-views-empty-pid.test.sh: all assertions passed'
