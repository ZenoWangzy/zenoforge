#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "dispatch-station.test.sh: $*" >&2; exit 1; }

fixture="$test_env_root/dispatch-station"
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

td="$fixture/run"
mkdir -p "$td/alerts"
A="$td"; LOG="$td/scheduler.log"; UNITS="$td/units.json"; WORKERS="$td/workers.json"
SCHED_LOCK="$td/.scheduler.lock"; SCHED_LOCK_HELD=false; PAUSE_FILE="$td/PAUSE"
DISPATCH_STATION_LOCK="$td/.dispatch-station.lock"; HARVEST_STATION_LOCK="$td/.harvest-station.lock"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo '{"units":[]}' > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"
git() { :; }
state_schema_ok() { return 0; }
tick_gh_calls_begin() { :; }
tick_gh_calls_summary() { echo 'gh_calls=0 gql=0 rest=0 gh_locked=0'; }
tick_gh_calls_count() { echo 0; }
tick_rest_usage_summary() { echo 'rest=0'; }
tick_roadmap_cache_begin() { :; }
tick_roadmap_cache_end() { :; }
record_run_spend() { :; }
mark_supervisor_owned_units() { :; }
release_session_pr_units() { :; }
supervisor_marking_deferred() { return 1; }
phase() {
  local name="$1"; shift
  if [[ "$name" == dispatch_pending ]]; then
    local TICK_STEP_LOCK_RESULT=""
    tick_step_lock_run dispatch_pending "$name" "$@"
  else "$name" "$@"; fi
}
calls="$td/dispatch-calls"
hold="$td/dispatch-hold"
entered="$td/dispatch-entered"
advance="$td/dispatch-advance"
advanced="$td/dispatch-advanced"
dispatch_pending() {
  printf '%s\n' "$*" >> "$calls"
  DISPATCH_STATION_CANDIDATES=2
  if [[ -e "$hold" ]]; then
    : > "$entered"
    while [[ -e "$hold" ]]; do
      if [[ -e "$advance" ]]; then
        SECONDS=$((SECONDS + 600))
        : > "$advanced"
        rm -f "$advance"
      fi
      command sleep 0.01
    done
  fi
}
harvest_worker_alive() { return 1; }
harvest_workers() {
  if [[ -n "${HARVEST_HOLD:-}" && -e "$HARVEST_HOLD" ]]; then
    : > "$HARVEST_ENTERED"
    while [[ -e "$HARVEST_HOLD" ]]; do command sleep 0.01; done
  fi
  workers_update --argjson pid "${2%%:*}" --arg unit "${2#*:}" \
    '(.workers[] | select(.pid == $pid and .unit == $unit)) |= (.harvested = true)'
}
coord_reap_expired() { :; }
coord_reconcile_systemd_workers() { :; }
coord_reconcile_scheduler_workers() { :; }
self_check_harvest() { :; }
precheck_harvest() { :; }
recover_orphans() { :; }

printf '2\n' > "$A/.tick-step-dispatch_pending-skips"
AUTOPI_DISPATCH_STATION_BATCH_SIZE=2 AUTOPI_DISPATCH_STATION_LIMIT_SECONDS=60 dispatch_station_tick
[[ "$(cat "$calls")" == 'false 2' ]] || fail "the station did not pass its batch limit to dispatch: $(cat "$calls")"
[[ "$(cat "$A/.tick-step-dispatch_pending-skips")" == 0 ]] || fail 'an acquired station pass did not reset dispatch contention skips'
grep -Fq 'dispatch-station done' "$LOG" || fail 'the dispatch station did not report a completed pass'
grep -Fq 'buffer=units.json batch_size=2' "$LOG" || fail 'the dispatch pass did not name its input buffer and batch size'
grep -Fq 'candidates=2' "$LOG" || fail 'the dispatch pass did not report its input batch size'
[[ ! -e "$DISPATCH_STATION_LOCK" ]] || fail 'the completed dispatch pass kept its lease'
dispatch_station_fresh || fail 'a recent dispatch station pass did not refresh its heartbeat'

printf '%s\n' '{"workers":[{"pid":4101,"unit":"pr-1","type":"review"}]}' > "$WORKERS"
touch "$hold"
AUTOPI_DISPATCH_STATION_BATCH_SIZE=1 AUTOPI_DISPATCH_STATION_LIMIT_SECONDS=600 dispatch_station_tick & dispatch_pid=$!
for _ in $(seq 100); do [[ -e "$entered" ]] && break; command sleep 0.01; done
[[ -e "$entered" ]] || fail 'the held dispatch station did not reach its batch'
touch "$advance"
for _ in $(seq 100); do [[ -e "$advanced" ]] && break; command sleep 0.01; done
[[ -e "$advanced" && -e "$hold" ]] || fail 'the dispatch hold did not span the simulated ten-minute interval'
harvest_station_tick
[[ "$(jq -r '.workers[0].harvested' "$WORKERS")" == true ]] || fail 'harvest waited for the held dispatch station lease'
grep -Fq 'harvest-station done' "$LOG" || fail 'harvest did not complete while dispatch was held'
rm -f "$hold"
wait "$dispatch_pid"
station_elapsed="$(grep 'dispatch-station done' "$LOG" | tail -1 | sed -E 's/.*secs=([0-9]+).*/\1/')"
(( station_elapsed >= 600 )) || fail "the dispatch hold did not account for ten minutes ($station_elapsed seconds)"
[[ ! -e "$DISPATCH_STATION_LOCK" && ! -e "$HARVEST_STATION_LOCK" ]] || fail 'a station pass left its lease behind'

printf '%s\n' '{"workers":[{"pid":4102,"unit":"pr-2","type":"repair"}]}' > "$WORKERS"
HARVEST_HOLD="$td/harvest-hold" HARVEST_ENTERED="$td/harvest-entered"
touch "$HARVEST_HOLD"
AUTOPI_HARVEST_STATION_LIMIT_SECONDS=600 harvest_station_tick & harvest_pid=$!
for _ in $(seq 100); do [[ -e "$HARVEST_ENTERED" ]] && break; command sleep 0.01; done
[[ -e "$HARVEST_ENTERED" ]] || fail 'the held harvest station did not reach its batch'
AUTOPI_DISPATCH_STATION_BATCH_SIZE=1 AUTOPI_DISPATCH_STATION_LIMIT_SECONDS=600 dispatch_station_tick
[[ -e "$HARVEST_HOLD" && "$(jq -r '.workers[0].harvested // false' "$WORKERS")" == false ]] \
  || fail 'dispatch waited for the held harvest station lease'
[[ "$(grep -c 'dispatch-station done' "$LOG")" == 3 ]] || fail 'dispatch did not complete while harvest was held'
rm -f "$HARVEST_HOLD"
wait "$harvest_pid"
[[ "$(jq -r '.workers[0].harvested' "$WORKERS")" == true ]] || fail 'the released harvest station did not finish its worker'

jq -n '{units:[
  {id:"unit-1",stage:"implement-pending",issue:1},
  {id:"unit-2",stage:"repair-pending",issue:2},
  {id:"unit-3",stage:"review-pending",issue:3}
]}' > "$UNITS"
ordered="$(dispatch_order true 2)"
[[ "$(wc -l <<<"$ordered")" == 3 ]] || fail 'dispatch input batch exceeded its requested size'
[[ "$(sed -n '2p' <<<"$ordered" | jq -r .id)" == unit-2 ]] || fail 'the bounded dispatch input lost priority order'
[[ "$(sed -n '3p' <<<"$ordered" | jq -r .id)" == unit-3 ]] || fail 'the bounded dispatch input included the wrong second unit'
grep -Fq -- '--dispatch-station) SCHED_STATION=true; dispatch_station_tick ;;' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh does not route the dispatch station'

wake="$td/wake"; mkdir -p "$wake/live" "$wake/state"
cat > "$wake/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WAKE_CALLS"
SH
chmod +x "$wake/live/scheduler.sh"
(
  AUTOPI_LOOP_LIBRARY_ONLY=true
  source "$engine_dir/mac-autopilot/loop.sh"
  A="$wake/state"; LIVE="$wake/live"
  export WAKE_CALLS="$wake/cadence-calls"
  AUTOPI_DISPATCH_STATION_SECONDS=30
  : > "$WAKE_CALLS"
  launch_dispatch_station
  [[ ! -s "$WAKE_CALLS" ]] || exit 1
  SECONDS="$DISPATCH_STATION_NEXT"
  launch_dispatch_station
  while IFS= read -r pid; do wait "$pid" || :; done < <(jobs -pr)
) || fail 'the dispatch station did not launch on its cadence'
[[ "$(cat "$wake/cadence-calls")" == '--dispatch-station' ]] || fail 'the dispatch cadence did not start one pass'
(
  AUTOPI_LOOP_LIBRARY_ONLY=true
  source "$engine_dir/mac-autopilot/loop.sh"
  A="$wake/state"; LIVE="$wake/live"
  export WAKE_CALLS="$wake/calls"
  AUTOPI_HARVEST_STATION_SECONDS=2147483647 AUTOPI_DISPATCH_STATION_SECONDS=2147483647
  true & dead=$!; wait "$dead"
  jq -n --argjson d "$dead" '{workers:[{pid:$d}]}' > "$A/workers.json"
  sleep() { SECONDS=$((SECONDS + 5)); }
  run_refill() { printf '%s\n' --refill >> "$WAKE_CALLS"; }
  refill_window 6
  [[ -z "${REFILL_PID:-}" ]] || wait "$REFILL_PID"
  while IFS= read -r pid; do wait "$pid" || :; done < <(jobs -pr)
) || fail 'the worker-exit station wake failed'
[[ "$(grep -xc -- '--harvest-station' "$wake/calls")" == 1 ]] || fail 'a worker exit did not wake harvest exactly once'
[[ "$(grep -xc -- '--dispatch-station' "$wake/calls")" == 1 ]] || fail 'a worker exit did not wake dispatch exactly once'

echo 'dispatch-station.test.sh: pass'
