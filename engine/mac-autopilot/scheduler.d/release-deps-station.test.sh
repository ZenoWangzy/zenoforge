#!/usr/bin/env bash
# release_dependency_blocks runs as its own station (scheduler.sh --release-deps), not in the full tick's acting phases.
# Replays: the station runs the pass with no scheduler lock held and logs its line; the full tick skips the pass while a station pass is fresh,
# and runs it through phase_yield_lock once the heartbeat is stale; PAUSE stops the station; a failing pass keeps its rc in the line.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "release-deps-station.test.sh: $*" >&2; exit 1; }

fixture="$test_env_root/release-deps-station"
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
RELEASE_DEPS_STATION_LOCK="$td/.release-deps-station.lock"; PAUSE_FILE="$td/PAUSE"
echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"
git() { :; } # the fixture root is not a repository

calls="$td/calls"
# The real pass needs GitHub and a full ledger; the station's contract is that it runs the pass unlocked, writes through the ledger, and reports rc.
release_dependency_blocks() {
  printf 'pass held=%s\n' "${SCHED_LOCK_HELD:-false}" >> "$calls"
  [[ ! -d "$SCHED_LOCK" ]] || echo 'lock held across the pass' >> "$calls"
  units_update '.units += [{"id":"issue-7","issue":7,"stage":"blocked-external"}]' # a ledger write: the lock for this write only
  [[ ! -e "$td/fail" ]] || return 7
}
phase_yield_lock() { echo "yield $*" >> "$calls"; "$@"; } # the full tick's call: it releases the lock, runs the phase, and takes the lock back
tick_prs_changed() { :; }
reset() {
  rm -rf "$SCHED_LOCK" "$RELEASE_DEPS_STATION_LOCK" "$A/.release-deps-epoch" "$PAUSE_FILE" "$td/fail"
  : > "$calls"; : > "$LOG"; echo '{"units":[]}' > "$UNITS"
}

# --- case 1: no tick anywhere; the station runs the pass with no lock held, its write lands, and its line is logged. ---
reset
release_deps_station_tick
[[ "$(paste -sd, "$calls")" == 'pass held=false' ]] || fail "the station did not run the pass unlocked: $(paste -sd, "$calls")"
jq -e '.units | map(.id) == ["issue-7"]' "$UNITS" >/dev/null || fail 'the pass write did not land'
[[ ! -e "$SCHED_LOCK" && ! -e "$RELEASE_DEPS_STATION_LOCK" ]] || fail 'a finished pass left a lock'
[[ -e "$A/.release-deps-epoch" ]] || fail 'a pass left no heartbeat'
line="$(cat "$LOG")"
[[ "$line" =~ release-deps\ done\ secs=[0-9]+\ gh_calls=[0-9]+\ rc=0\ ended=[0-9:]+Z$ ]] || fail "the pass line lacks its fields: $line"
[[ "$(wc -l < "$LOG")" == 1 ]] || fail "a pass must log one line: $(cat "$LOG")"

# --- case 2: a live station, the full tick skips the pass; a stale heartbeat, the tick runs it through phase_yield_lock. ---
reset; date +%s > "$A/.release-deps-epoch"
release_deps_tick_phase
[[ ! -s "$calls" ]] || fail "the full tick ran the pass beside a live station: $(paste -sd, "$calls")"
reset; echo $(( $(date +%s) - 1000 )) > "$A/.release-deps-epoch"
release_deps_tick_phase
[[ "$(paste -sd, "$calls")" == 'yield release_dependency_blocks,pass held=false' ]] \
  || fail "a stale station did not leave the pass to the tick: $(paste -sd, "$calls")"

# --- case 3: PAUSE stops the station pass: no pass, no done line, a paused line instead. ---
reset; touch "$PAUSE_FILE"
release_deps_station_tick
[[ ! -s "$calls" ]] || fail "a paused station ran the pass: $(paste -sd, "$calls")"
! grep -q 'release-deps done' "$LOG" || fail 'a paused station logged a done line'
grep -Fq 'release-deps paused' "$LOG" || fail 'a paused station left no line'
rm -f "$PAUSE_FILE"

# --- case 4: a failing pass keeps its rc in the line and still frees the station lock. ---
reset; touch "$td/fail"
release_deps_station_tick
grep -Fq 'release-deps done secs=' "$LOG" && grep -Fq ' rc=7 ' "$LOG" || fail "the failing pass line lacks rc=7: $(cat "$LOG")"
[[ ! -e "$RELEASE_DEPS_STATION_LOCK" ]] || fail 'a failing pass left its station lock'

# --- case 5: scheduler.sh routes --release-deps without reading the tick's runtime config; loop.sh launches the station on its cadence. ---
grep -Fq -- '--release-deps) release_deps_station_tick ;;' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh does not route --release-deps'
grep -Fq '"${1:-}" != --release-deps' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'a station pass would reconcile the tick runtime config'
grep -Fq 'launch_release_deps' "$engine_dir/mac-autopilot/loop.sh" || fail 'loop.sh does not launch the release-deps station'

echo 'release-deps-station.test.sh: pass (station runs the pass unlocked, full tick skips it while live and runs it when stale, PAUSE, failing rc kept, routing and launch)'
