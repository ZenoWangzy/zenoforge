#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-queue-timing"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

A="$MAC_AUTOPILOT_RUNTIME_DIR"
UNITS="$A/units.json"
WORKERS="$A/workers.json"
LOG="$A/scheduler.log"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0

fail() { echo "dispatch-queue-timing.test.sh: $*" >&2; exit 1; }
say() { printf '%s\n' "$*" >> "$LOG"; }
footprint_waiters_revalidate() { sleep 2.2; }
footprint_convoy_alert() { :; }

dispatch_pending true
grep -Eq '^dispatch detail footprint_waiters_revalidate secs=([2-9]|[1-9][0-9]+)s$' "$LOG" \
  || fail "slow dispatch callee had no detail line: $(grep 'dispatch detail' "$LOG" || true)"
echo 'dispatch-queue-timing.test.sh: pass (slow dispatch callee logged)'
