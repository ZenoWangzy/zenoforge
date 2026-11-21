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
lock_poll_pause() { # stands in for the poll pause: holder A, then holder B, then the lock is released
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

# Queue order: with the lock held, waiter A starts before B; on release A takes the lock first. Eight rounds, so a poll race (B first) shows up.
fifo_probe="$fixture/fifo-waiter.sh"
cat > "$fifo_probe" <<'FIFO_PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
if acquire_scheduler_lock_wait 20; then printf '%s\n' "$WAITER" >> "$ORDER"; release_scheduler_lock; fi
FIFO_PROBE
fifo_run() { env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$1" LOG="$1.log" STAMP=test ORDER="$2" WAITER="$3" bash "$fifo_probe"; }
for round in 1 2 3 4 5 6 7 8; do
  lock="$fixture/fifo-$round.lock"; order="$fixture/fifo-$round.order"
  command sleep 60 & fifo_holder=$!
  mkdir "$lock"; echo "$fifo_holder" > "$lock/pid"
  fifo_run "$lock" "$order" A & wa=$!
  for _ in $(seq 100); do compgen -G "$lock.q/*" >/dev/null && break; command sleep 0.05; done # A has queued (bounded: main has no queue)
  fifo_run "$lock" "$order" B & wb=$!
  for _ in $(seq 100); do [[ "$(compgen -G "$lock.q/*" | wc -l)" -ge 2 ]] && break; command sleep 0.05; done
  command sleep 0.2
  rm -rf -- "$lock"
  wait "$wa" || :; wait "$wb" || :
  kill "$fifo_holder" 2>/dev/null || :; wait "$fifo_holder" 2>/dev/null || :
  if [[ "$(head -n 1 "$order" 2>/dev/null)" != A ]]; then fail "round $round: waiter B took the lock before the earlier waiter A (order: $(tr '\n' ' ' < "$order" 2>/dev/null))"; fi
done

# Refill priority: with the lock held, a non-refill waiter A queues first and a refill waiter R second; on release R takes the lock before A.
prio_run() { env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$1" LOG="$1.log" STAMP=test A="$fixture" ORDER="$2" WAITER="$3" TICK_LOCAL_REFILL="$4" bash "$fifo_probe"; }
for round in 1 2 3; do
  lock="$fixture/prio-$round.lock"; order="$fixture/prio-$round.order"
  command sleep 60 & prio_holder=$!
  mkdir "$lock"; echo "$prio_holder" > "$lock/pid"
  prio_run "$lock" "$order" A false & pa=$!
  for _ in $(seq 100); do compgen -G "$lock.q/*" >/dev/null && break; command sleep 0.05; done # A has queued
  prio_run "$lock" "$order" R true & pr=$!
  for _ in $(seq 100); do [[ "$(compgen -G "$lock.q/*" | wc -l)" -ge 2 ]] && break; command sleep 0.05; done
  command sleep 0.2
  rm -rf -- "$lock"
  wait "$pa" || :; wait "$pr" || :
  kill "$prio_holder" 2>/dev/null || :; wait "$prio_holder" 2>/dev/null || :
  if [[ "$(head -n 1 "$order" 2>/dev/null)" != R ]]; then fail "round $round: non-refill waiter A took the lock before refill waiter R (order: $(tr '\n' ' ' < "$order" 2>/dev/null))"; fi
done

# A ticket from a dead pid does not block a live waiter, and the dead ticket is removed when it is passed over.
dead_lock="$fixture/dead-ticket.lock"
command sleep 0 & dead_pid=$!; wait "$dead_pid" || :
mkdir -p "$dead_lock.q"; dead_ticket="$dead_lock.q/0000000000000001-$dead_pid"; : > "$dead_ticket"
fifo_run "$dead_lock" "$fixture/dead-ticket.order" C || fail 'a live waiter failed behind a dead ticket'
[[ "$(cat "$fixture/dead-ticket.order")" == C ]] || fail 'a live waiter was blocked by a dead pid ticket'
[[ ! -e "$dead_ticket" ]] || fail 'a dead pid ticket was left in the queue'

# A REFILL-TIMEOUT stop leaves no ticket: the stop finds the waiter's own ticket in the queue, and none is left after it.
stop_lock="$fixture/stop-ticket.lock"; stop_A="$fixture/stop-A"; mkdir -p "$stop_A"
command sleep 60 & stop_holder=$!
mkdir "$stop_lock"; echo "$stop_holder" > "$stop_lock/pid"
stop_probe="$fixture/stop-waiter.sh"
cat > "$stop_probe" <<'STOP_PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
say() { echo "[$STAMP] $*" >> "$LOG"; echo "tickets_at_stop=$(ls -1 "$SCHED_LOCK.q" 2>/dev/null | wc -l)" >> "$LOG"; }
TICK_LOCAL_REFILL=true AUTOPI_REFILL_LIMIT_SECONDS=10 AUTOPI_REFILL_LOCK_MARGIN_SECONDS=0
SECONDS=10
rc=0; acquire_scheduler_lock_wait || rc=$?
echo "rc=$rc tickets_after=$(ls -1 "$SCHED_LOCK.q" 2>/dev/null | wc -l)" >> "$LOG"
STOP_PROBE
env AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$stop_lock" LOG="$stop_lock.log" STAMP=test A="$stop_A" bash "$stop_probe" || :
kill "$stop_holder" 2>/dev/null || :; wait "$stop_holder" 2>/dev/null || :
grep -q 'REFILL-TIMEOUT stop: ledger lock wait stopped' "$stop_lock.log" || fail 'the refill past its deadline did not stop the wait'
grep -q 'tickets_at_stop=1' "$stop_lock.log" || fail 'the waiter held no ticket while it waited in the queue'
grep -q 'rc=1 tickets_after=0' "$stop_lock.log" || fail 'a REFILL-TIMEOUT stop left a ticket in the queue'

# A blocked ledger wait forks nothing per poll. A 0 s bound makes one try and no poll; a 2 s bound makes about 40 polls. Subshells are counted by a DEBUG trap (set -T),
# external commands by shims on PATH. Equal counts mean the polls add no fork. Not seen: the lazy pause pipe (opened once, before the count) and bash builtins.
fork_lock="$fixture/fork-held.lock"
command sleep 60 & fork_holder=$!
fork_start="$(source "$script_dir/../../coord.sh"; coord_process_start_ticks "$fork_holder")"
mkdir "$fork_lock"
printf '%s\n' "$fork_holder" > "$fork_lock/pid"
printf '%s\n' "$fork_start" > "$fork_lock/start"
shim_dir="$fixture/wait-shims"
mkdir -p "$shim_dir"
for c in cat sleep mkdir rm stat date ps; do
  real="$(command -v "$c")"
  printf '#!/bin/sh\necho %s >> "$SHIM_LOG"\nexec %s "$@"\n' "$c" "$real" > "$shim_dir/$c"
  chmod +x "$shim_dir/$c"
done
wait_probe="$fixture/wait-forks.sh"
cat > "$wait_probe" <<'WAIT_PROBE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
lock_poll_pause # the first pause opens the pause pipe once; that one-time cost is not part of the polls
set -T
trap 'if (( BASH_SUBSHELL > 0 )); then echo subshell >> "$COUNT_LOG"; fi' DEBUG
rc=0; acquire_scheduler_lock_wait "$BOUND" || rc=$?
trap - DEBUG
set +T
echo "rc=$rc"
WAIT_PROBE
run_wait() { # $1: bound in seconds -> prints rc; the shim and subshell counts go to their logs
  : > "$fixture/wait.shim.log"; : > "$fixture/wait.count.log"
  env PATH="$shim_dir:$PATH" AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$fork_lock" LOG="$fork_lock.log" STAMP=test \
    SHIM_LOG="$fixture/wait.shim.log" COUNT_LOG="$fixture/wait.count.log" BOUND="$1" bash "$wait_probe"
}
zero_rc="$(run_wait 0)"; zero_shims="$(wc -l < "$fixture/wait.shim.log")"; zero_subs="$(wc -l < "$fixture/wait.count.log")"
fork_t0=$SECONDS
two_rc="$(run_wait 2)"; two_elapsed=$((SECONDS - fork_t0)); two_shims="$(wc -l < "$fixture/wait.shim.log")"; two_subs="$(wc -l < "$fixture/wait.count.log")"
kill -KILL "$fork_holder" 2>/dev/null || :; wait "$fork_holder" 2>/dev/null || :
[[ "$zero_rc" == rc=1 && "$two_rc" == rc=1 ]] || fail "a bounded ledger wait did not return 1: $zero_rc / $two_rc"
(( two_elapsed >= 2 )) || fail 'the 2 s ledger wait returned early, so no polls were counted'
(( two_shims == zero_shims )) || fail "a blocked ledger wait ran $((two_shims - zero_shims)) external commands over its polls"
(( two_subs == zero_subs )) || fail "a blocked ledger wait ran $((two_subs - zero_subs)) subshells over its polls"

echo 'locks-views-empty-pid.test.sh: all assertions passed'
