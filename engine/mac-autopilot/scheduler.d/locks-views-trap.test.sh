#!/usr/bin/env bash
# acquire_scheduler_lock keeps the EXIT trap set before it (the engine canary) and runs it once, even after a re-acquire.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/locks-views-trap"
mkdir -p "$fixture"
probe="$fixture/probe.sh"
cat > "$probe" <<'EOF'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
trap 'printf x >> "$PROBE_COUNT"' EXIT
acquire_scheduler_lock
release_scheduler_lock
acquire_scheduler_lock
EOF
SCHED_DIR="$script_dir" SCHED_LOCK="$fixture/sched.lock" PROBE_COUNT="$fixture/prior.count" bash "$probe"

[[ "$(cat "$fixture/prior.count" 2>/dev/null)" == x ]] || { echo 'locks-views-trap.test.sh: prior EXIT trap did not run after acquire_scheduler_lock' >&2; exit 1; }
[[ ! -e "$fixture/sched.lock" ]] || { echo 'locks-views-trap.test.sh: lock dir survived exit' >&2; exit 1; }
[[ "$(wc -c < "$fixture/prior.count")" == 1 ]] || { echo 'locks-views-trap.test.sh: prior EXIT trap ran more than once after a re-acquire' >&2; exit 1; }
# A subshell that takes the lock must not run the parent's EXIT trap (in a subshell trap -p shows the parent's trap).
sub="$fixture/sub.sh"
cat > "$sub" <<'SUB'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
trap 'printf p >> "$PROBE_COUNT"' EXIT
( acquire_scheduler_lock; chain_exit_trap 'printf s >> "$PROBE_COUNT"' )
printf '|' >> "$PROBE_COUNT"
SUB
SCHED_DIR="$script_dir" SCHED_LOCK="$fixture/sub.lock" PROBE_COUNT="$fixture/sub.count" bash "$sub"
[[ "$(cat "$fixture/sub.count")" == 's|p' ]] || { echo "locks-views-trap.test.sh: subshell ran the parent's EXIT trap or lost its own: $(cat "$fixture/sub.count")" >&2; exit 1; }
[[ ! -e "$fixture/sub.lock" ]] || { echo 'locks-views-trap.test.sh: subshell lock dir survived its exit' >&2; exit 1; }
# A views EXIT trap only removes the lock directory while its pid file still names that owner.
views="$fixture/views.sh"
cat > "$views" <<'VIEWS'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
run_views() { printf '%s\n' "$NEXT_OWNER" > "$VIEWS_LOCK/pid"; }
views_entry dashboard
VIEWS
SCHED_DIR="$script_dir" VIEWS_LOCK="$fixture/views.lock" NEXT_OWNER=987654321 bash "$views"
[[ "$(cat "$fixture/views.lock/pid")" == 987654321 ]] || { echo 'locks-views-trap.test.sh: exiting owner removed a replacement views lock' >&2; exit 1; }
rm -rf -- "$fixture/views.lock"
cat > "$views" <<'VIEWS'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
run_views() { :; }
views_entry dashboard
VIEWS
SCHED_DIR="$script_dir" VIEWS_LOCK="$fixture/views.lock" bash "$views"
[[ ! -e "$fixture/views.lock" ]] || { echo 'locks-views-trap.test.sh: owned views lock survived exit' >&2; exit 1; }
# SIGKILL cannot run EXIT cleanup; the next views entry must retire that stale owner lock.
killed="$fixture/killed.sh"; ready="$fixture/killed.ready"
cat > "$killed" <<'KILLED'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
run_views() { command sleep 30 & child=$!; printf '%s\n' "$child" > "$READY"; wait "$child"; }
views_entry dashboard
KILLED
SCHED_DIR="$script_dir" VIEWS_LOCK="$fixture/killed.lock" READY="$ready" bash "$killed" & owner=$!
for _ in $(seq 50); do [[ -s "$ready" ]] && break; sleep 0.02; done
[[ -s "$ready" ]] || { kill -KILL "$owner" 2>/dev/null || :; wait "$owner" 2>/dev/null || :; echo 'locks-views-trap.test.sh: killed views fixture did not start' >&2; exit 1; }
read -r child < "$ready"
kill -KILL "$owner" 2>/dev/null || :
wait "$owner" 2>/dev/null || :
kill -TERM "$child" 2>/dev/null || :
[[ -d "$fixture/killed.lock" ]] || { echo 'locks-views-trap.test.sh: SIGKILL unexpectedly ran views cleanup' >&2; exit 1; }
SCHED_DIR="$script_dir" VIEWS_LOCK="$fixture/killed.lock" bash "$views"
[[ ! -e "$fixture/killed.lock" ]] || { echo 'locks-views-trap.test.sh: next views entry did not clear killed run lock' >&2; exit 1; }
# A scheduler lock whose pid is alive but whose start ticks name another process is a reused pid: reclaimed and logged.
# A live owner with its own start ticks still refuses the second tick.
reuse="$fixture/reuse.sh"
cat > "$reuse" <<'REUSE'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
sleep 30 & holder=$!
mkdir "$SCHED_LOCK"; printf '%s\n' "$holder" > "$SCHED_LOCK/pid"
printf '%s\n' "$(( $(coord_process_start_ticks "$holder") + WRONG_START ))" > "$SCHED_LOCK/start"
if acquire_scheduler_lock; then echo acquired; else echo refused; fi
kill "$holder" 2>/dev/null || :; wait "$holder" 2>/dev/null || :
REUSE
reused="$(AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$fixture/reuse.lock" LOG="$fixture/reuse.log" STAMP=test WRONG_START=1 bash "$reuse")"
[[ "$reused" == acquired ]] || { echo "locks-views-trap.test.sh: lock of a reused pid blocked the tick: $reused" >&2; exit 1; }
grep -q 'reclaimed from pid .* (pid reused)' "$fixture/reuse.log" || { echo 'locks-views-trap.test.sh: reclaim of a reused pid was not logged' >&2; exit 1; }
[[ ! -e "$fixture/reuse.lock" ]] || { echo 'locks-views-trap.test.sh: reclaimed lock survived exit' >&2; exit 1; }
live="$(AGENT_HOME="$fixture" SCHED_DIR="$script_dir" SCHED_LOCK="$fixture/live.lock" LOG="$fixture/live.log" STAMP=test WRONG_START=0 bash "$reuse")"
[[ "$live" == refused ]] || { echo "locks-views-trap.test.sh: live owner did not block a second tick: $live" >&2; exit 1; }
[[ ! -e "$fixture/live.log" ]] || { echo 'locks-views-trap.test.sh: live owner was reclaimed' >&2; exit 1; }
echo 'locks-views-trap.test.sh: all assertions passed'
