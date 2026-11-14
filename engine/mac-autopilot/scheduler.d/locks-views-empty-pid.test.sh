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

echo 'locks-views-empty-pid.test.sh: all assertions passed'
