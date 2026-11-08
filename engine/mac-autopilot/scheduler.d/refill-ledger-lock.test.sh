#!/usr/bin/env bash
# Item 52: a refill never waits for the full tick's scheduler lock. Its ledger writes take the ledger lock (a flock held across one
# read-modify-write), every writer of units.json/workers.json takes it too, and the refill does not take the scheduler lock back after its batch.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/refill-ledger-lock"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
n=12
jq -n --argjson n "$n" '{units: [range($n) | {id: ("u\(.)"), stage: "implement-pending", history: []}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
limit="${AUTOPI_REFILL_LIMIT_SECONDS:-300}"
fail() { echo "refill-ledger-lock.test.sh: $*" >&2; exit 1; }
holder=""; trap '[[ -z "$holder" ]] || kill "$holder" 2>/dev/null || :' EXIT

# 1. No lost update: a refill-style writer (ledger lock only) and a tick-style writer (SCHED_LOCK held) race on both files.
mkdir "$SCHED_LOCK"; sleep 300 >/dev/null 2>&1 & holder=$!; echo "$holder" > "$SCHED_LOCK/pid" # a live foreign tick holds the scheduler lock
: > "$LOG"
pids=()
for i in $(seq 0 $((n - 1))); do
  ( TICK_LOCAL_REFILL=true REFILL_LEDGER_ONLY=true SCHED_LOCK_HELD=false
    set_unit "u$i" '.refill_mark=true' ) & pids+=("$!")
  ( ledger_jq_write --argjson w "{\"pid\":$((90000 + i)),\"unit\":\"u$i\"}" '.workers += [$w]' "$WORKERS" ) & pids+=("$!")
  ( SCHED_LOCK_HELD=true; set_unit "u$i" '.tick_mark=true' ) & pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || fail "a ledger write failed while the scheduler lock was held by another process (pid $p)"; done
jq -e --argjson n "$n" '[.units[] | select(.refill_mark == true and .tick_mark == true)] | length == $n' "$UNITS" >/dev/null \
  || fail "unit updates were lost: $(jq -c '[.units[] | select(.refill_mark == true and .tick_mark == true)] | length' "$UNITS") of $n units kept both marks"
jq -e --argjson n "$n" '.workers | length == $n and (map(.pid) | unique | length == $n)' "$WORKERS" >/dev/null \
  || fail "worker rows were lost or doubled: $(jq -c '.workers | length' "$WORKERS") of $n"
grep -q 'REFILL-TIMEOUT' "$LOG" && fail 'ledger writes beside a held scheduler lock must not wait for it'
[[ "$(cat "$SCHED_LOCK/pid")" == "$holder" ]] || fail 'the writers took over the scheduler lock they did not hold'

# 2. The ledger lock itself: a refill past its deadline stops at it once, and tells which lock.
rm -rf "$SCHED_LOCK"; kill "$holder" 2>/dev/null || :
exec {ledger_fd}>>"$A/.ledger.lock"; flock "$ledger_fd" # this shell holds the ledger lock, as a refill or tick mid-write does
: > "$LOG"; TICK_LOCAL_REFILL=true; SECONDS=$((limit - 5)); rc=0
set_unit u0 '.late=true' || rc=$?
[[ "$rc" == 1 ]] || fail "a refill past its deadline must fail a write behind a held ledger lock (rc=$rc)"
grep -q 'REFILL-TIMEOUT stop: ledger lock wait stopped' "$LOG" || fail 'the refused ledger wait must log the REFILL-TIMEOUT stop line'
jq -e 'all(.units[]; has("late") | not)' "$UNITS" >/dev/null || fail 'a refused write changed the ledger'
exec {ledger_fd}>&-; rm -f "$A/.refill-stop" "$A/.refill-lock-wait.$$"; TICK_LOCAL_REFILL=false; SECONDS=0

# 3. A refill's batch does not take the scheduler lock back: a tick that took it during the batch must not hold the refill up.
SCHED_LOCK_HELD=false; acquire_scheduler_lock || fail 'fixture could not take the scheduler lock'
sleep 300 >/dev/null 2>&1 & holder=$!
batch() { rm -rf "$SCHED_LOCK"; mkdir "$SCHED_LOCK"; echo "$holder" > "$SCHED_LOCK/pid"; } # the tick comes back and holds it
: > "$LOG"; TICK_LOCAL_REFILL=true; SECONDS=$((limit - 5)); rc=0
phase_yield_lock_batch batch || rc=$?
[[ "$rc" == 0 ]] || fail "a refill batch waited for the scheduler lock after it ended (rc=$rc)"
grep -q 'REFILL-TIMEOUT' "$LOG" && fail 'the refill logged a lock timeout after its batch'
[[ "$(cat "$SCHED_LOCK/pid")" == "$holder" ]] || fail 'the refill touched the scheduler lock it did not hold'
echo "refill-ledger-lock.test.sh: PASS"
