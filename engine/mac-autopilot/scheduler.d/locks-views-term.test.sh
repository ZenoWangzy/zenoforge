#!/usr/bin/env bash
# A TERM (loop.sh's timeout --foreground) must not free the scheduler lock while the holder's ledger writer is still alive:
# a killed pass's stale write_state must not land after a second writer took the lock. Its own background children are stopped first.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/locks-views-term"
rm -rf -- "$fixture"
mkdir -p "$fixture"
fail() { echo "locks-views-term.test.sh: $*" >&2; exit 1; }
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null || :; done; }
trap cleanup EXIT

holder="$fixture/holder.sh"
cat > "$holder" <<'HOLDER'
set -uo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/../../coord.sh"
source "$SCHED_DIR/locks-views.sh"
source "$SCHED_DIR/reports.sh"
acquire_scheduler_lock || { echo refused; exit 3; }
case "$MODE" in
  ledger) # the pass's ledger write: a slow producer piped into write_state, in the foreground
    { echo "$BASHPID" > "$PRODUCER_PID"; sleep 2; printf '{"v":"STALE"}\n'; } | write_state "$DST" ;;
  children) # background children: one in this session, one detached with setsid
    sleep 60 & echo "$!" > "$CHILD_PID"
    setsid sleep 60 & echo "$!" > "$DETACHED_PID"
    wait "$(cat "$CHILD_PID")" ;;
esac
HOLDER
env_for() { # $1 mode, $2 state dir
  printf '%s\n' AGENT_HOME="$2" UNITS="$2/other-units.json" WORKERS="$2/workers.json" SCHED_DIR="$script_dir" \
    SCHED_LOCK="$2/sched.lock" LOG="$2/sched.log" STAMP=test MODE="$1" DST="$2/units.json" \
    PRODUCER_PID="$2/producer.pid" CHILD_PID="$2/child.pid" DETACHED_PID="$2/detached.pid"
}
alive() { kill -0 "$1" 2>/dev/null; }

# 1. the ledger writer outlives the TERM: the lock must stay held until it finishes, then a second writer's ledger must win.
ledger="$fixture/ledger"; mkdir -p "$ledger"
mapfile -t envs < <(env_for ledger "$ledger")
echo '{"v":"OLD"}' > "$ledger/units.json"
env "${envs[@]}" timeout --foreground -k 5 1 bash "$holder" >/dev/null 2>&1 || :
producer="$(cat "$ledger/producer.pid")"
[[ ! -d "$ledger/sched.lock" ]] || fail 'the lock survived the killed holder'
! alive "$producer" || fail 'the lock was released while the holder ledger writer was still alive'
# a second writer takes the freed lock and writes the new ledger
second() { env "${envs[@]}" bash -c 'source "$SCHED_DIR/core.sh"; source "$SCHED_DIR/../../coord.sh"; source "$SCHED_DIR/locks-views.sh"; source "$SCHED_DIR/reports.sh"; acquire_scheduler_lock && { printf "{\"v\":\"NEW\"}\n" | write_state "$DST"; release_scheduler_lock; }'; }
second
for _ in $(seq 50); do alive "$producer" || break; sleep 0.1; done
[[ "$(cat "$ledger/units.json")" == '{"v":"NEW"}' ]] || fail "a stale ledger overwrote the newer one: $(cat "$ledger/units.json")"

# 2. background children of the holder die with it; a setsid child (a worker) keeps running.
kids="$fixture/kids"; mkdir -p "$kids"
mapfile -t envs < <(env_for children "$kids")
start=$SECONDS
env "${envs[@]}" AUTOPI_TERM_CHILD_WAIT_SECONDS=2 timeout --foreground -k 5 1 bash "$holder" >/dev/null 2>&1 || :
(( SECONDS - start < 8 )) || fail 'the holder did not return within its child wait bound'
child="$(cat "$kids/child.pid")"; detached="$(cat "$kids/detached.pid")"; pids+=("$detached")
! alive "$child" || fail 'a background child of the holder outlived its TERM'
alive "$detached" || fail 'a setsid child was stopped by the holder TERM'
[[ ! -d "$kids/sched.lock" ]] || fail 'the lock survived the children test'
kill -KILL "$detached" 2>/dev/null || :
echo 'locks-views-term.test.sh: all assertions passed'
