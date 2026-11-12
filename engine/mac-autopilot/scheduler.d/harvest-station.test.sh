#!/usr/bin/env bash
# The harvest group runs as its own station (scheduler.sh --harvest-station), not as the first phases of the 800-1500 s full tick.
# Replays: the station harvests with no tick running, snapshots and commits under short ledger locks, never harvests one worker twice,
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
# The real harvest_workers needs reports, usage logs and GitHub; the station calls it unlocked and commits its ledger writes separately.
harvest_workers() {
  [[ "${SCHED_LOCK_HELD:-false}" != true && ! -e "$SCHED_LOCK" ]] || { echo "harvest_workers ran with the ledger lock" >> "$calls"; return 1; }
  printf 'harvest local_only=%s only=%s\n' "$1" "${2:-}" >> "$calls"
  [[ -n "${2:-}" ]] || return 0
  if declare -F workers_update >/dev/null; then
    workers_update --argjson pid "${2%%:*}" --arg unit "${2#*:}" '(.workers[] | select(.pid == $pid and .unit == $unit)) |= (.harvested = true)'
  else
    jqf --argjson pid "${2%%:*}" --arg unit "${2#*:}" '(.workers[] | select(.pid == $pid and .unit == $unit)) |= (.harvested = true)' "$WORKERS" | write_state "$WORKERS"
  fi
}
coord_reconcile_systemd_real="$(declare -f coord_reconcile_systemd_workers)"
for f in coord_reap_expired coord_reconcile_systemd_workers coord_reconcile_scheduler_workers self_check_harvest precheck_harvest recover_orphans; do
  if [[ "$f" =~ ^(coord_reap_expired|self_check_harvest|precheck_harvest|recover_orphans)$ ]]; then
    eval "$f() { echo $f >> \"\$calls\"; [[ \"\${SCHED_LOCK_HELD:-false}\" == true ]] || echo '$f ran without the ledger lock' >> \"\$calls\"; }"
  else
    eval "$f() { echo $f >> \"\$calls\"; [[ \"\${SCHED_LOCK_HELD:-false}\" != true ]] || echo '$f ran with the ledger lock' >> \"\$calls\"; }"
  fi
done
reset() { rm -rf "$SCHED_LOCK" "$HARVEST_STATION_LOCK" "$A/.harvest-station-epoch" "$A/.harvest-live-epoch" "$PAUSE_FILE"; : > "$calls"; : > "$LOG"; two_workers; }

# --- case 1: no tick anywhere, harvest runs unlocked, commits each worker under a short lock, then runs the follow-ups. ---
reset
harvest_station_tick
[[ "$(grep -c '^harvest ' "$calls")" == 2 ]] || fail "expected one harvest per worker: $(cat "$calls")"
grep -Fxq 'harvest local_only=false only=4101:pr-1' "$calls" && grep -Fxq 'harvest local_only=false only=4102:pr-2' "$calls" \
  || fail "each worker must be harvested on its own: $(cat "$calls")"
! grep -q 'ran with the ledger lock' "$calls" || fail "a slow step ran while the ledger lock was held: $(cat "$calls")"
for f in coord_reap_expired coord_reconcile_systemd_workers coord_reconcile_scheduler_workers self_check_harvest precheck_harvest recover_orphans; do
  grep -Fxq "$f" "$calls" || fail "follow-up $f did not run"
done
[[ "$(jq '[.workers[] | select(.harvested == true)] | length' "$WORKERS")" == 2 ]] || fail 'workers left unharvested'
[[ ! -e "$SCHED_LOCK" && ! -e "$HARVEST_STATION_LOCK" ]] || fail 'a finished pass left a lock'
line="$(grep 'harvest-station done' "$LOG")"
[[ "$line" =~ secs=[0-9]+\ gh_calls=[0-9]+\ lock_wait=[0-9]+\ lock_hold=[0-9]+\ workers=2\ harvested=2\ deferred=0\ limit=240s\ ended=[0-9:]+Z\ phases=harvest_workers:[0-9]+s/[0-9]+gh,coord_reap:[0-9]+s/[0-9]+gh,coord_systemd: ]] \
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
grep -Eq 'harvest-station done .*workers=0 harvested=0 deferred=1 ' "$LOG" || fail "busy-lock pass did not defer before reading the worker ledger: $(cat "$LOG")"
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

# --- case 5: both worker harvests run outside the ledger lock. ---
reset
between="$td/between"; : > "$between"
harvest_workers_inner="$(declare -f harvest_workers)"
harvest_workers() {
  [[ ! -e "$SCHED_LOCK" ]] && echo unlocked >> "$between"
  eval "${harvest_workers_inner#harvest_workers ()}"
}
harvest_station_tick
eval "$harvest_workers_inner"
[[ "$(grep -c '^unlocked$' "$between")" == 2 ]] || fail "both worker harvests must run unlocked: $(cat "$between")"

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

# --- case 10: a slow refill does not block a due harvest station launch. ---
rf="$hl/refill"; mkdir -p "$rf/live" "$rf/state"
cat > "$rf/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HL_CALLS"
SH
chmod +x "$rf/live/scheduler.sh"
(
  AUTOPI_LOOP_LIBRARY_ONLY=true; source "$engine_dir/mac-autopilot/loop.sh"
  A="$rf/state"; LIVE="$rf/live"
  export HL_CALLS="$rf/calls" HL_REFILL_ACTIVE="$rf/refill-active" HL_DURING_REFILL="$rf/during-refill" HL_TICKS="$rf/ticks"
  : > "$HL_CALLS"
  echo 0 > "$HL_TICKS"
  export AUTOPI_HARVEST_STATION_SECONDS=60 AUTOPI_REFILL_SECONDS=30 \
    AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647 AUTOPI_MERGE_STATION_SECONDS=2147483647
  echo '{"workers":[]}' > "$A/workers.json"
  unset REFILL_PID REFILL_ACTIVE_SIGNATURE
  sleep() {
    command sleep 0.005
    local ticks; ticks="$(cat "$HL_TICKS")"
    echo "$((ticks + ${1:-5}))" > "$HL_TICKS"
    SECONDS=$((SECONDS + ${1:-5}))
  }
  setsid() {
    if [[ " $* " == *" --harvest-station "* && -e "$HL_REFILL_ACTIVE" && ! -e "$HL_DURING_REFILL" ]]; then
      cat "$HL_TICKS" > "$HL_DURING_REFILL"
    fi
    command setsid "$@"
  }
  run_refill() {
    echo "$SECONDS" >> "$rf/refill-calls"
    : > "$HL_REFILL_ACTIVE"
    local remaining=120
    while (( remaining > 0 )); do
      command sleep 0.1
      SECONDS=$((SECONDS + 5)); remaining=$((remaining - 5))
    done
    rm -f "$HL_REFILL_ACTIVE"
  }
  refill_window 140
  [[ -z "${REFILL_PID:-}" ]] || wait "$REFILL_PID"
) || fail 'refill-window setup failed during the slow-refill case'
[[ -e "$rf/during-refill" ]] || fail 'the harvest station launch waited for the 120-second refill to finish'
[[ "$(cat "$rf/during-refill")" -le 120 ]] || fail "the harvest station launched after two 60-second cadences ($(cat "$rf/during-refill")s)"
[[ "$(wc -l < "$rf/refill-calls")" == 1 ]] || fail 'a slow refill was started more than once while it remained in flight'
grep -Fxq -- '--harvest-station' "$rf/calls" || fail 'the harvest station launch was not recorded'

# --- case 11: slow harvest I/O runs unlocked, and a concurrent unit move survives its delayed write. ---
reset
echo '{"units":[{"id":"pr-1","stage":"review","note":"before"}]}' > "$UNITS"
echo '{"workers":[{"pid":4101,"unit":"pr-1","type":"review"}]}' > "$WORKERS"
slow_started="$td/slow-started"; slow_lock="$td/slow-lock"; slow_changed="$td/slow-changed"; changed_during="$td/changed-during"
harvest_workers_saved="$(declare -f harvest_workers)"
harvest_workers() {
  if [[ -e "$SCHED_LOCK" ]]; then echo held > "$slow_lock"; else echo free > "$slow_lock"; fi
  : > "$slow_started"
  for _ in $(seq 50); do [[ -e "$slow_changed" ]] && break; command sleep 0.05; done
  if [[ -e "$slow_changed" ]]; then : > "$changed_during"; printf '%s\n' "$(unit_field pr-1 .note)" > "$td/snapshot-note"; fi
  set_unit pr-1 '.stage="supervisor-review"' || :
}
(
  SCHED_LOCK_HELD=false HARVEST_STATION_ACTIVE=false
  unset HARVEST_CAS_ACTIVE HARVEST_CAS_UNIT HARVEST_CAS_EXPECTED HARVEST_CAS_STALE
  for _ in $(seq 100); do [[ -e "$slow_started" ]] && break; command sleep 0.01; done
  [[ -e "$slow_started" ]] || exit 2
  until acquire_scheduler_lock; do command sleep 0.05; done
  jqf --arg id pr-1 '.units |= map(if .id==$id then .stage="ready-to-merge" | .note="concurrent" else . end)' "$UNITS" | write_state "$UNITS"
  release_scheduler_lock
  : > "$slow_changed"
) & writer=$!
harvest_station_tick
wait "$writer" || fail 'the concurrent ledger writer did not finish'
eval "$harvest_workers_saved"
[[ "$(cat "$slow_lock")" == free ]] || fail 'the slow harvest step held the ledger lock'
[[ -e "$changed_during" ]] || fail 'the concurrent ledger change did not finish during the slow step'
[[ "$(cat "$td/snapshot-note")" == before ]] || fail 'harvest read the moved unit row outside its captured snapshot'
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == ready-to-merge ]] || fail 'the delayed harvest write overwrote the concurrent unit stage'
[[ "$(jqf -r '.units[0].note' "$UNITS")" == concurrent ]] || fail 'the delayed harvest write dropped a concurrent unit field'

# --- case 12: coordinator I/O is unlocked, then its claim mutation takes the ledger lock first. ---
reset
COORD_DIR="$td/claims"; COORD_LEASE_SECONDS=900
coord_acquire station-systemd owner-systemd systemd-worker ticket fake.service review || fail 'could not create coordinator fixture'
coord_calls="$td/coord-calls"; : > "$coord_calls"
systemctl() {
  [[ "${SCHED_LOCK_HELD:-false}" != true && ! -e "$SCHED_LOCK" ]] || fail 'systemd state read held the ledger lock'
  echo systemd-unlocked >> "$coord_calls"
  printf 'active\n'
}
coord_renew_real="$(declare -f coord_renew)"; eval "${coord_renew_real/coord_renew/coord_renew_real}"
coord_renew() {
  [[ "${SCHED_LOCK_HELD:-false}" == true && -e "$SCHED_LOCK" ]] || fail 'claim renewal did not hold the ledger lock first'
  echo renew-ledger-locked >> "$coord_calls"
  coord_renew_real "$@"
}
eval "$coord_reconcile_systemd_real"
coord_reconcile_systemd_workers || fail 'systemd claim reconciliation failed'
grep -Fxq systemd-unlocked "$coord_calls" || fail 'systemd state was not read'
grep -Fxq renew-ledger-locked "$coord_calls" || fail 'claim renewal was not serialized with the ledger'
[[ ! -e "$SCHED_LOCK" ]] || fail 'coordinator reconciliation left the ledger lock held'

echo 'harvest-station.test.sh: pass (unlocked harvest, short CAS ledger writes, no double harvest, bounded deferral, one pass at a time, tick gate, loop cadence, ordered coordinator locks)'
