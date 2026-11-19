#!/usr/bin/env bash
# The body gate reads a predecessor's GitHub state once per tick, not once per unit: a CLOSED predecessor that the cache does not
# list was re-read by gh for every implement-pending unit. Counts gh reads with a stub (timing-free) and checks the gate's decisions:
# CLOSED frees the unit, OPEN keeps it blocked.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { printf 'dep-fresh-tick.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dep-fresh-tick"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=2026-11-18T10:00:00Z; NOW_EPOCH=1795003200
declare -gA DEP_DELIVERED_CACHE=()
calls="$fixture/dep-states-calls"; : > "$calls"

# Stub for the one gh GraphQL read: 5002 is OPEN, every other predecessor is CLOSED. Each call is counted.
dep_states() { printf 'x\n' >> "$calls"; if [[ "$1" == 5002 ]]; then printf '%s\tOPEN\t\tOPEN\t\t\t\n' "$1"; else printf '%s\tCLOSED\t\tCLOSED\t\t\t\n' "$1"; fi; }
tracker_dep_cleared() { return 1; } # isolates the read count from the tracker path

# Five implement-pending units all blocked on the same closed predecessor 5001, and one unit on the open 5002.
for n in 1 2 3 4 5; do
  unit="$(jq -cn --argjson n "$n" '{id:("u\($n)"),issue:(6000+$n),stage:"implement-pending",body_blocked_by:[5001]}')"
  dep="$(blocking_body_dependency "$unit")" && fail "closed predecessor still blocks unit u$n: $dep" || :
done
closed_reads="$(wc -l < "$calls")"
[[ "$closed_reads" -eq 1 ]] || fail "closed predecessor 5001 read $closed_reads times for 5 units, expected 1 in one tick"

open_unit="$(jq -cn '{id:"open",issue:6100,stage:"implement-pending",body_blocked_by:[5002]}')"
blocked_by="$(blocking_body_dependency "$open_unit")" || fail "open predecessor 5002 did not block its unit"
[[ "$blocked_by" == 5002 ]] || fail "open predecessor reported as $blocked_by, expected 5002"

# A new tick (new STAMP) reads the closed predecessor again: the per-tick memo never carries a decision across ticks.
STAMP=2026-11-18T10:10:00Z
blocking_body_dependency "$(jq -cn '{id:"next",issue:6200,stage:"implement-pending",body_blocked_by:[5001]}')" >/dev/null || :
[[ "$(wc -l < "$calls")" -eq 3 ]] || fail "next tick did not re-read: $(wc -l < "$calls") total reads, expected 3 (1 closed, 1 open, 1 closed next tick)"
echo "dep-fresh-tick.test.sh: ok closed_reads_in_tick=$closed_reads"
