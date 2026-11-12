#!/usr/bin/env bash
# release_dependency_blocks runs as its own station (scheduler.sh --dependency-station), not inside the 400-800 s full tick.
# Replays: a fresh station pass makes the tick skip the release and rebuild only the delivered snapshot; a stale or missing pass leaves the
# release to the tick; a pass runs the release with no tick around it, under no ledger lock, excludes a second pass, stops on PAUSE, and
# leaves its line; scheduler.sh routes the argument and loop.sh launches the station.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "dependency-station.test.sh: $*" >&2; exit 1; }

fixture="$test_env_root/dependency-station"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
cp "$engine_dir/mac-autopilot/config.template.json" "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

td="$fixture/run"; mkdir -p "$td/alerts"
A="$td"; LOG="$td/scheduler.log"; UNITS="$td/units.json"; WORKERS="$td/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SCHED_LOCK="$td/.scheduler.lock"; SCHED_LOCK_HELD=false
DEPENDENCY_STATION_LOCK="$td/.dependency-station.lock"; PAUSE_FILE="$td/PAUSE"
echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"
git() { :; } # the fixture root is not a repository
calls="$td/calls"
# The real release reads GitHub and the ledger; the station's contract is which lock it holds and how the tick calls it.
release_dependency_blocks() {
  printf 'release lock=%s\n' "$([[ -d "$SCHED_LOCK" ]] && echo held || echo free)" >> "$calls"
  units_update '.units += [{"id":"issue-7","issue":7,"stage":"blocked-external"}]' # one ledger write takes the lock for itself
  [[ "${RELEASE_FAIL:-0}" == 1 ]] && return 3 || return 0
}
dep_delivered_snapshot() { echo snapshot >> "$calls"; }
phase_yield_lock() { echo "tick-release $*" >> "$calls"; }
step_timed() { shift; "$@"; }
reset() {
  rm -rf "$SCHED_LOCK" "$DEPENDENCY_STATION_LOCK" "$A/.dependency-station-epoch" "$PAUSE_FILE"
  : > "$calls"; : > "$LOG"; echo '{"units":[]}' > "$UNITS"; RELEASE_FAIL=0
}

# --- case 1: the tick skips the release while a station pass is fresh, and rebuilds only the delivered snapshot the gates read. ---
reset
echo "$(date +%s)" > "$A/.dependency-station-epoch"
dependency_release_tick
[[ "$(paste -sd, "$calls")" == snapshot ]] || fail "a live station did not leave the release to itself: $(paste -sd, "$calls")"

# --- case 2: a stale or missing pass leaves the release to the tick, as before. ---
reset
echo $(( $(date +%s) - 1000 )) > "$A/.dependency-station-epoch"
dependency_release_tick
[[ "$(paste -sd, "$calls")" == 'tick-release release_dependency_blocks' ]] || fail "a stale station did not hand the release to the tick: $(paste -sd, "$calls")"
reset
dependency_release_tick
[[ "$(paste -sd, "$calls")" == 'tick-release release_dependency_blocks' ]] || fail "a missing station did not hand the release to the tick: $(paste -sd, "$calls")"

# --- case 3: a pass runs the release with no tick around it, unlocked, and logs its line. ---
reset
dependency_station_tick
[[ "$(paste -sd, "$calls")" == 'release lock=free' ]] || fail "the pass did not run the release unlocked: $(paste -sd, "$calls")"
jq -e '.units | map(.id) == ["issue-7"]' "$UNITS" >/dev/null || fail 'the release write did not land'
[[ ! -e "$SCHED_LOCK" && ! -e "$DEPENDENCY_STATION_LOCK" ]] || fail 'a finished pass left a lock'
[[ -e "$A/.dependency-station-epoch" ]] || fail 'a pass left no heartbeat'
line="$(grep 'dependency-station done' "$LOG")"
[[ "$line" =~ dependency-station\ done\ secs=[0-9]+\ lock_wait=[0-9]+\.[0-9]\ lock_hold=[0-9]+\.[0-9]\ gh_calls=[0-9]+\ rc=0\ ended=[0-9:]+Z$ ]] \
  || fail "the pass line lacks its measured fields: $line"

# --- case 4: a failed release is logged with its rc, and the lock is still released. ---
reset
RELEASE_FAIL=1 dependency_station_tick
grep -Fq 'rc=3' "$LOG" || fail "a failed release did not report its rc: $(cat "$LOG")"
[[ ! -e "$SCHED_LOCK" ]] || fail 'a failed pass left the ledger lock'

# --- case 5: a second pass does not start while one is running, and PAUSE stops the pass. ---
reset
mkdir "$DEPENDENCY_STATION_LOCK"; echo "$$" > "$DEPENDENCY_STATION_LOCK/pid"
dependency_station_tick
[[ ! -s "$calls" ]] || fail "a second pass ran beside a live one: $(cat "$calls")"
rm -rf "$DEPENDENCY_STATION_LOCK"
: > "$PAUSE_FILE"
dependency_station_tick
[[ ! -s "$calls" ]] && grep -Fq 'dependency-station paused' "$LOG" || fail "PAUSE did not stop the pass: $(cat "$LOG")"
rm -f "$PAUSE_FILE"

# --- case 6: scheduler.sh routes the argument without running the full tick, and loop.sh launches the station. ---
grep -Fq -- '--dependency-station) dependency_station_tick ;;' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh does not route --dependency-station'
grep -Fq -- '"${1:-}" != --dependency-station &&' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh would run the full tick for --dependency-station'
grep -Fq -- '--dependency-station >> "$A/loop.out"' "$engine_dir/mac-autopilot/loop.sh" || fail 'loop.sh does not launch the dependency station'
grep -Fq -- 'launch_dependency_station' "$engine_dir/mac-autopilot/loop.sh" || fail 'loop.sh does not call the dependency station launcher'

echo 'dependency-station.test.sh: pass (fresh station leaves the release to itself, stale or missing pass returns it to the tick, unlocked pass with its line, failed release reports rc, one pass at a time, PAUSE, routing and launch)'
