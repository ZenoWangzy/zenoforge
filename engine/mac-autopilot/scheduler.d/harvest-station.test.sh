#!/usr/bin/env bash
# The harvest group runs as its own station (scheduler.sh --harvest-station), not as the first phases of the 800-1500 s full tick.
# Replays: the station harvests with no tick running, takes the ledger lock one worker at a time, never harvests one worker twice,
# defers instead of racing a lock holder, excludes a second pass, writes its heartbeat; the tick skips the group only while that
# heartbeat is fresh; live workers are visited once per sweep window; the dashboard row is computed from the pass lines.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "harvest-station.test.sh: $*" >&2; exit 1; }

fixture="$test_env_root/harvest-station"
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
HARVEST_STATION_LOCK="$td/.harvest-station.lock"; PAUSE_FILE="$td/PAUSE"
echo '{"units":[]}' > "$UNITS"
git() { :; } # the fixture root is not a repository

two_workers() { printf '%s\n' '{"workers":[{"pid":4101,"unit":"pr-1","type":"review"},{"pid":4102,"unit":"pr-2","type":"repair"}]}' > "$WORKERS"; }
calls="$td/calls"
harvest_worker_alive() { return 1; } # both workers have finished
# The real harvest_workers needs reports, usage logs and GitHub; the station's contract is how it calls it and under which lock.
harvest_workers() {
  [[ "${SCHED_LOCK_HELD:-false}" == true && "$(cat "$SCHED_LOCK/pid")" == "$BASHPID" ]] || { echo "harvest_workers ran without the ledger lock" >> "$calls"; return 1; }
  printf 'harvest local_only=%s only=%s\n' "$1" "${2:-}" >> "$calls"
  [[ -n "${2:-}" ]] || return 0
  jqf --argjson pid "${2%%:*}" --arg unit "${2#*:}" '(.workers[] | select(.pid == $pid and .unit == $unit)) |= (.harvested = true)' "$WORKERS" | write_state "$WORKERS"
}
for f in coord_reap_expired coord_reconcile_systemd_workers coord_reconcile_scheduler_workers self_check_harvest precheck_harvest recover_orphans; do
  eval "$f() { echo $f >> \"\$calls\"; [[ \"\${SCHED_LOCK_HELD:-false}\" == true ]] || echo '$f ran without the ledger lock' >> \"\$calls\"; }"
done
reset() { rm -rf "$SCHED_LOCK" "$HARVEST_STATION_LOCK" "$A/.harvest-station-epoch" "$A/.harvest-live-epoch" "$PAUSE_FILE"; : > "$calls"; : > "$LOG"; two_workers; }

# --- case 1: no tick anywhere, one pass harvests both workers, each under the ledger lock, then runs the follow-ups. ---
reset
harvest_station_tick
[[ "$(grep -c '^harvest ' "$calls")" == 2 ]] || fail "expected one harvest per worker: $(cat "$calls")"
grep -Fxq 'harvest local_only=false only=4101:pr-1' "$calls" && grep -Fxq 'harvest local_only=false only=4102:pr-2' "$calls" \
  || fail "each worker must be harvested on its own: $(cat "$calls")"
! grep -q 'without the ledger lock' "$calls" || fail "a harvest step ran unlocked: $(cat "$calls")"
for f in coord_reap_expired coord_reconcile_systemd_workers coord_reconcile_scheduler_workers self_check_harvest precheck_harvest recover_orphans; do
  grep -Fxq "$f" "$calls" || fail "follow-up $f did not run"
done
[[ "$(jq '[.workers[] | select(.harvested == true)] | length' "$WORKERS")" == 2 ]] || fail 'workers left unharvested'
[[ ! -e "$SCHED_LOCK" && ! -e "$HARVEST_STATION_LOCK" ]] || fail 'a finished pass left a lock'
line="$(grep 'harvest-station done' "$LOG")"
[[ "$line" =~ secs=[0-9]+\ gh_calls=[0-9]+\ lock_wait=[0-9]+\ lock_hold=[0-9]+\ workers=2\ harvested=2\ deferred=0\ limit=240s\ ended=[0-9:]+Z\ phases=harvest_workers:[0-9]+s/[0-9]+gh,coord_sweeps: ]] \
  || fail "the pass line lacks its measured fields: $line"

# --- case 2: a worker another pass harvested after the list was read is not harvested twice. ---
reset
real_candidates="$(declare -f hs_candidates)"
hs_candidates() { printf '4101:pr-1\n4101:pr-1\n'; }
harvest_station_tick
eval "$real_candidates"
[[ "$(grep -c '^harvest ' "$calls")" == 1 ]] || fail "a worker was harvested twice: $(cat "$calls")"

# --- case 3: the ledger lock held by a live pid (the tick) is never taken; the pass defers and keeps its own bound. ---
reset
mkdir "$SCHED_LOCK"; printf '%s\n' "$$" > "$SCHED_LOCK/pid"
AUTOPI_HARVEST_STATION_LIMIT_SECONDS=2 harvest_station_tick
[[ "$(cat "$SCHED_LOCK/pid")" == "$$" ]] || fail 'the station took or released a lock it did not own'
! grep -q '^harvest ' "$calls" || fail "the station harvested while the tick held the ledger lock: $(cat "$calls")"
grep -Eq 'harvest-station done .*workers=2 harvested=0 deferred=2 ' "$LOG" || fail "deferred workers not logged: $(cat "$LOG")"
grep -Eq 'lock_wait=[1-9]' "$LOG" || fail "the lock wait was not measured: $(cat "$LOG")"
rm -rf "$SCHED_LOCK"

# --- case 4: a second pass exits at once while the first runs; the first still finishes and frees its lock. ---
reset
harvest_workers_real="$(declare -f harvest_workers)"
touch "$td/hold"
harvest_workers() { : >> "$td/in-pass"; while [[ -e "$td/hold" ]]; do read -t 0.1 <> <(:) || :; done; eval "${harvest_workers_real#harvest_workers ()}"; }
( harvest_station_tick ) & first=$!
for _ in $(seq 100); do [[ -e "$td/in-pass" ]] && break; read -t 0.1 <> <(:) || :; done
[[ -e "$td/in-pass" ]] || fail 'the first pass never reached a harvest'
harvest_station_tick # must return at once
[[ "$(grep -c 'harvest-station done' "$LOG")" == 0 ]] || fail 'a second pass ran beside the first'
rm -f "$td/hold"; wait "$first"
eval "$harvest_workers_real"
[[ ! -e "$HARVEST_STATION_LOCK" && ! -e "$SCHED_LOCK" ]] || fail 'locks left behind after the first pass'

# --- case 5: the ledger lock is free between two workers' harvests. ---
reset
between="$td/between"; : > "$between"
harvest_workers_inner="$(declare -f harvest_workers)"
harvest_workers() { # at the second worker's start the first worker's hold is gone: only this call owns the lock
  [[ -d "$SCHED_LOCK" ]] && printf 'held-by=%s\n' "$(cat "$SCHED_LOCK/pid")" >> "$between"
  eval "${harvest_workers_inner#harvest_workers ()}"
}
harvest_station_tick
eval "$harvest_workers_inner"
[[ "$(grep -c '^held-by=' "$between")" == 2 ]] || fail "expected the lock held once per worker, saw: $(cat "$between")"

# --- case 6: PAUSE does not stop the station (the paused tick harvests too); a stale epoch heals. ---
reset; touch "$PAUSE_FILE"
harvest_station_tick
[[ "$(grep -c '^harvest ' "$calls")" == 2 ]] || fail 'a paused pass did not harvest'
rm -f "$PAUSE_FILE"

# --- case 7: live workers are visited once per sweep window, finished ones every pass. ---
reset
printf '%s\n' '{"workers":[{"pid":4101,"unit":"pr-1","type":"review"},{"pid":4102,"unit":"pr-2","type":"repair"}]}' > "$WORKERS"
harvest_worker_alive() { [[ "$(jqf -r .pid <<<"$1")" == 4101 ]]; } # 4101 still runs
harvest_station_tick
grep -Fxq 'harvest local_only=false only=4101:pr-1' "$calls" || fail 'the first pass skipped the live-worker sweep'
: > "$calls"; printf '%s\n' '{"workers":[{"pid":4101,"unit":"pr-1","type":"review"},{"pid":4103,"unit":"pr-3","type":"repair"}]}' > "$WORKERS"
rm -rf "$HARVEST_STATION_LOCK"
harvest_station_tick
! grep -Fq 'only=4101:pr-1' "$calls" || fail "a live worker was visited again inside the sweep window: $(cat "$calls")"
grep -Fxq 'harvest local_only=false only=4103:pr-3' "$calls" || fail 'a finished worker waited for the live sweep'
harvest_worker_alive() { return 1; }

# --- case 8: the heartbeat gates the tick. ---
rm -f "$A/.harvest-station-epoch"
! harvest_station_fresh || fail 'a missing heartbeat counted as fresh'
echo $(( $(date +%s) - 1000 )) > "$A/.harvest-station-epoch"
! harvest_station_fresh || fail 'a stale heartbeat counted as fresh'
echo $(( $(date +%s) - 10 )) > "$A/.harvest-station-epoch"
harvest_station_fresh || fail 'a recent heartbeat did not count as fresh'
main_body="$(sed -n '/^main() {/,/^}/p' "$engine_dir/mac-autopilot/scheduler.sh")"
# The tick runs the whole group only when the station is not fresh: every harvest-class phase and the sweeps sit inside the gate.
gate="$(awk '/tick_harvests=true/ { g = 1 } g' <<<"$main_body" | sed -n '1,/^  phase reconcile_size_recuts/p')"
for p in 'phase harvest_workers' 'coord_reap_expired' 'coord_reconcile_systemd_workers' 'coord_reconcile_scheduler_workers'; do
  grep -Fq "$p" <<<"$gate" || fail "the tick's gated block lacks $p"
done
before_gate="$(sed -n '1,/tick_harvests=true/p' <<<"$main_body")"
for p in 'phase harvest_workers' 'phase self_check_harvest' 'phase precheck_harvest' 'phase recover_orphans' 'coord_reap_expired'; do
  ! grep -Fq "$p" <<<"$before_gate" || fail "the tick runs $p before the station gate"
done
after_recut="$(sed -n '/^  phase reconcile_size_recuts/,/phase recover_orphan_landing/p' <<<"$main_body")"
for p in 'phase self_check_harvest' 'phase precheck_harvest' 'phase recover_orphans'; do
  grep -Fq "$p" <<<"$after_recut" || fail "the tick lost its fallback $p"
done
grep -Fq 'if [[ "$tick_harvests" == true ]]; then' <<<"$after_recut" || fail 'the tick self-check phases are not behind the same gate'

# --- case 9: loop.sh launches the station on its own cadence, detached, and never before it is due. ---
hl="$fixture/loop"; mkdir -p "$hl/live" "$hl/state"
cat > "$hl/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HL_CALLS"
SH
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$engine_dir/mac-autopilot/loop.sh"
  A="$hl/state"; LIVE="$hl/live"; export HL_CALLS="$hl/calls"; : > "$HL_CALLS"
  export AUTOPI_HARVEST_STATION_SECONDS=30 AUTOPI_REFILL_SECONDS=2147483647 AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647
  echo '{"workers":[]}' > "$A/workers.json"
  sleep() { SECONDS=$((SECONDS + 5)); }
  refill_window 25 ) || fail 'refill window failed before the harvest station cadence'
[[ ! -s "$hl/calls" ]] || fail "the harvest station started before its cadence ($(cat "$hl/calls"))"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$engine_dir/mac-autopilot/loop.sh"
  A="$hl/state"; LIVE="$hl/live"; export HL_CALLS="$hl/calls"
  export AUTOPI_HARVEST_STATION_SECONDS=30 AUTOPI_REFILL_SECONDS=2147483647 AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647
  sleep() { SECONDS=$((SECONDS + 5)); }
  refill_window 40 ) || fail 'refill window failed at the harvest station cadence'
for _ in $(seq 50); do [[ -s "$hl/calls" ]] && break; command sleep 0.1; done
[[ "$(cat "$hl/calls")" == '--harvest-station' ]] || fail "the harvest station was not launched once on cadence ($(cat "$hl/calls" 2>/dev/null))"

echo 'harvest-station.test.sh: pass (station harvests without a tick, one lock hold per worker, no double harvest, defers on a busy lock, one pass at a time, tick gate, loop cadence)'
