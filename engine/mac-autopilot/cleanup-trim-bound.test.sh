#!/usr/bin/env bash
# The workers-ledger trim waits for the ledger lock only a few seconds. On 2026-11-08 a refill held the lock and the unbounded wait ran
# a full tick into its 1800 s kill: a busy lock now skips the trim with one line, and the next tick does it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/cleanup-trim-bound"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$fixture/wt" "$fixture/sys-tmp" "$fixture/tmpdir"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
WT_ROOT="$fixture/wt"; SUP="$fixture/supervisor"; A="$MAC_AUTOPILOT_RUNTIME_DIR"; UNITS="$A/units.json"; WORKERS="$A/workers.json"; LOG="$A/scheduler.log"
SCHED_LOCK="$A/.scheduler.lock"; SCHED_LOCK_HELD=false
export AP_SYSTEM_TMP="$fixture/sys-tmp" AP_SYSTEM_TMP_FS=ext4 AP_TMPDIR="$fixture/tmpdir"
fail() { echo "cleanup-trim-bound.test.sh: $*" >&2; exit 1; }
printf '%s\n' '{"units":[]}' > "$UNITS"
touch "$A/.branch-gc"
ledger() { jq -n '{workers: [range(61) | {id: "w\(.)", unit: "u\(.)", pid: (. + 100), harvested: true, started: .}]}' > "$WORKERS"; } # write_state's guard needs pid and unit
workers_count() { jq '.workers | length' "$WORKERS"; }
tick() { : > "$LOG"; SECONDS=0; cleanup_tick || fail "$1: cleanup_tick failed"; }

# Busy lock: a live holder (a sleep this test started) keeps the lock for 25 s. The bounded wait gives up at 5 s with one line and
# leaves workers.json alone. The old unbounded wait would sit out the holder and trim after it.
ledger; before="$fixture/workers.before"; cp "$WORKERS" "$before"
mkdir -p "$SCHED_LOCK"; sleep 25 & holder=$!; echo "$holder" > "$SCHED_LOCK/pid"
t0=$(date +%s); tick busy-lock; waited=$(( $(date +%s) - t0 ))
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; rm -rf -- "$SCHED_LOCK"
(( waited < 15 )) || fail "busy lock: tick waited ${waited}s, wanted a bound near 5s"
grep -q 'cleanup trim skipped at [0-9]*s: ledger lock busy' "$LOG" || fail 'busy lock: no skip line'
! grep -q 'trim workers ledger' "$LOG" || fail 'busy lock: trim ran'
cmp -s "$before" "$WORKERS" || fail 'busy lock: workers.json changed'
[[ ! -d "$SCHED_LOCK" ]] || fail 'busy lock: lock left held'

# Free lock: trimmed to the newest 60 harvested workers, with the timing on the line.
tick free-lock
[[ "$(workers_count)" == 60 ]] || fail "free lock: $(workers_count) workers, wanted 60"
grep -Eq 'trim workers ledger 61 secs=[0-9]+$' "$LOG" || fail 'free lock: no timed trim line'
[[ ! -d "$SCHED_LOCK" ]] || fail 'free lock: lock left held'

echo 'ok - the ledger trim waits a bounded time for the lock; a busy lock skips it to the next tick, a free lock trims as before'
