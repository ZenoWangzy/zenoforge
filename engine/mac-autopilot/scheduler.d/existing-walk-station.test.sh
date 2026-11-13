#!/usr/bin/env bash
# Intake's existing-units walk runs as its own station (scheduler.sh --existing-walk), not as the first intake phase of the 800-1500 s full tick.
# Replays: a pass walks with no tick running, never holds the ledger lock across the walk (each write takes it for that one write), measures
# its lock wait and hold, excludes a second pass, stops on PAUSE, leaves a heartbeat and what it walked; the tick walks itself only while
# that heartbeat is stale, and reads the walked rows and waiting PRs while it is fresh; loop.sh launches the station on its own cadence.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "existing-walk-station.test.sh: $*" >&2; exit 1; }

fixture="$test_env_root/existing-walk-station"
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
EXISTING_WALK_LOCK="$td/.existing-walk-station.lock"; PAUSE_FILE="$td/PAUSE"
echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"
git() { :; } # the fixture root is not a repository
write_state() { if [[ -e "$td/slow-write" ]]; then read -t 0.3 <> <(:) || :; fi; cat > "$1.new" && mv -f "$1.new" "$1"; } # the ledger write; slow on demand

calls="$td/calls"
# The real walk needs state files, a PR census and GitHub; the station's contract is how it calls it and under which lock.
register_new_issues() {
  printf 'walk arg=%s budget=%s held=%s\n' "$1" "${ISSUE_INTAKE_EXISTING_BUDGET_SECONDS:-}" "${SCHED_LOCK_HELD:-false}" >> "$calls"
  [[ -e "$td/hold" ]] && { : >> "$td/in-pass"; while [[ -e "$td/hold" ]]; do read -t 0.1 <> <(:) || :; done; }
  [[ ! -d "$SCHED_LOCK" ]] || echo 'lock held while the walk read GitHub' >> "$calls"
  units_update '.units += [{"id":"issue-7","issue":7,"stage":"blocked-external"}]' # a ledger write: the lock for this write only
  [[ ! -d "$SCHED_LOCK" ]] || echo 'lock still held after the write' >> "$calls"
  INTAKE_EXISTING_WALKED=([7]=ok [9]=ok [11]=skip); INTAKE_WALK_ROWS=3 INTAKE_WALK_LAP=true
  HANDOFF_WAIT_PRS='[41]'; HANDOFF_WAIT_BRANCHES='["agent/issue-3"]'
}
reset() {
  rm -rf "$SCHED_LOCK" "$EXISTING_WALK_LOCK" "$A/.existing-walk-epoch" "$A/.existing-walked" "$PAUSE_FILE" "$td/slow-write" "$td/hold" "$td/in-pass"
  : > "$calls"; : > "$LOG"; echo '{"units":[]}' > "$UNITS"
  INTAKE_EXISTING_WALKED=(); HANDOFF_WAIT_PRS='[]'; HANDOFF_WAIT_BRANCHES='[]'
}
num() { sed -E "s/.*[ ]$1=([0-9.]+).*/\\1/" <<<"$2"; }

# --- case 1: no tick anywhere; one pass walks with the existing-only argument and the pass bound, never under the ledger lock, and logs its line. ---
reset
existing_walk_tick
grep -Fxq 'walk arg=1 budget=240 held=false' "$calls" || fail "the pass did not run the existing walk unlocked with its bound: $(cat "$calls")"
! grep -q 'lock' "$calls" || fail "the ledger lock was held across the walk: $(cat "$calls")"
jq -e '.units | map(.id) == ["issue-7"]' "$UNITS" >/dev/null || fail 'the walk write did not land'
[[ ! -e "$SCHED_LOCK" && ! -e "$EXISTING_WALK_LOCK" ]] || fail 'a finished pass left a lock'
line="$(grep 'existing-walk done' "$LOG")"
[[ "$line" =~ existing-walk\ done\ secs=[0-9]+\ rows=3\ lock_wait=[0-9]+\.[0-9]\ lock_hold=[0-9]+\.[0-9]\ lap_done=true\ walked=2\ gh_calls=[0-9]+\ rc=0\ limit=240s\ ended=[0-9:]+Z$ ]] \
  || fail "the pass line lacks its measured fields: $line"
[[ "$(wc -l < "$LOG")" == 1 ]] || fail "a pass must log one line: $(cat "$LOG")"
existing_walk_fresh || fail 'a pass left no heartbeat'
# What the pass left reaches the tick: the rows walked ok (not the skipped one) and the PRs and branches handoffs wait on.
INTAKE_EXISTING_WALKED=(); HANDOFF_WAIT_PRS='[5]'; HANDOFF_WAIT_BRANCHES='[]'
existing_walked_load
[[ "$(printf '%s\n' "${!INTAKE_EXISTING_WALKED[@]}" | sort -n | paste -sd, -)" == 7,9 ]] || fail "walked rows not loaded: ${!INTAKE_EXISTING_WALKED[*]}"
[[ "$HANDOFF_WAIT_PRS" == '[5,41]' && "$HANDOFF_WAIT_BRANCHES" == '["agent/issue-3"]' ]] || fail "waiting PRs not loaded: $HANDOFF_WAIT_PRS $HANDOFF_WAIT_BRANCHES"

# --- case 2: the pass bound is its knob, and a slow ledger write shows in lock_hold. ---
reset; touch "$td/slow-write"
AUTOPI_EXISTING_WALK_LIMIT_SECONDS=77 existing_walk_tick
grep -Fxq 'walk arg=1 budget=77 held=false' "$calls" || fail "the pass bound knob did not reach the walk: $(cat "$calls")"
line="$(grep 'existing-walk done' "$LOG")"
awk -v v="$(num lock_hold "$line")" 'BEGIN { exit !(v >= 0.2 && v < 3) }' || fail "a 0.3 s ledger write was not measured as lock_hold: $line"

# --- case 3: a ledger lock held by the tick is waited for, not taken; the wait is measured. ---
reset
mkdir "$SCHED_LOCK"; sleep 1 & holder=$!; printf '%s\n' "$holder" > "$SCHED_LOCK/pid" # a live pid for one second, then a stale lock the write clears
existing_walk_tick
wait "$holder" || :
line="$(grep 'existing-walk done' "$LOG")"
awk -v v="$(num lock_wait "$line")" 'BEGIN { exit !(v >= 0.7) }' || fail "the wait for the tick's lock was not measured: $line"
jq -e '.units | length == 1' "$UNITS" >/dev/null || fail 'the write did not land once the lock freed'

# --- case 4: a second pass exits at once while the first runs; the first still finishes and frees its lock. ---
reset; touch "$td/hold"
( existing_walk_tick ) & first=$!
for _ in $(seq 100); do [[ -e "$td/in-pass" ]] && break; read -t 0.1 <> <(:) || :; done
[[ -e "$td/in-pass" ]] || fail 'the first pass never reached the walk'
existing_walk_tick # must return at once
[[ "$(grep -c '^walk ' "$calls")" == 1 ]] || fail 'a second pass walked beside the first'
rm -f "$td/hold"; wait "$first"
[[ "$(grep -c 'existing-walk done' "$LOG")" == 1 && ! -e "$EXISTING_WALK_LOCK" ]] || fail 'the first pass did not finish cleanly'

# --- case 5: PAUSE stops the walk (the tick runs no intake while paused) but the heartbeat stays, and no done line is logged. ---
reset; touch "$PAUSE_FILE"
existing_walk_tick
[[ ! -s "$calls" ]] || fail "a paused pass walked: $(cat "$calls")"
! grep -q 'existing-walk done' "$LOG" || fail 'a paused pass logged a done line'
grep -Fq 'existing-walk paused' "$LOG" || fail 'a paused pass left no line'
existing_walk_fresh || fail 'a paused pass left no heartbeat'
rm -f "$PAUSE_FILE"

# --- case 6: the heartbeat and the walked file go stale; the tick then loads nothing. ---
rm -f "$A/.existing-walk-epoch"
! existing_walk_fresh || fail 'a missing heartbeat counted as fresh'
echo $(( $(date +%s) - 1000 )) > "$A/.existing-walk-epoch"
! existing_walk_fresh || fail 'a stale heartbeat counted as fresh'
echo $(( $(date +%s) - 10 )) > "$A/.existing-walk-epoch"
existing_walk_fresh || fail 'a recent heartbeat did not count as fresh'
printf '%s\n[77]\n["b"]\n3\nnot-a-row\n4\n' "$(( $(date +%s) - 1000 ))" > "$A/.existing-walked"
INTAKE_EXISTING_WALKED=([1]=ok); HANDOFF_WAIT_PRS='[]'; HANDOFF_WAIT_BRANCHES='[]'
existing_walked_load
[[ ${#INTAKE_EXISTING_WALKED[@]} == 0 && "$HANDOFF_WAIT_PRS" == '[]' ]] || fail 'a stale walked file was loaded'
printf '%s\n[77]\n["b"]\n3\nnot-a-row\n4\n' "$(date +%s)" > "$A/.existing-walked"
existing_walked_load
[[ "$(printf '%s\n' "${!INTAKE_EXISTING_WALKED[@]}" | sort -n | paste -sd, -)" == 3,4 && "$HANDOFF_WAIT_PRS" == '[77]' ]] || fail "a fresh walked file with a bad row loaded wrong: ${!INTAKE_EXISTING_WALKED[*]} $HANDOFF_WAIT_PRS"
rm -f "$A/.existing-walked"; INTAKE_EXISTING_WALKED=([1]=ok); existing_walked_load
[[ ${#INTAKE_EXISTING_WALKED[@]} == 0 ]] || fail 'a missing walked file left rows behind'

# --- case 7: the detached intake worker walks stale rows before new intake; a fresh station supplies its census and walked rows. ---
phase() { echo "phase $*" >> "$calls"; }
intake_census_prime() { echo census >> "$calls"; }
existing_walked_load() { echo load >> "$calls"; }
reset; echo $(( $(date +%s) - 1000 )) > "$A/.existing-walk-epoch"
run_issue_intake_phases
[[ "$(paste -sd, "$calls")" == 'phase register_new_issues 1,phase register_new_issues' ]] || fail "a stale walk did not finish before new intake: $(paste -sd, "$calls")"
reset; echo $(( $(date +%s) - 10 )) > "$A/.existing-walk-epoch"
run_issue_intake_phases
[[ "$(paste -sd, "$calls")" == 'census,load,phase register_new_issues' ]] || fail "a live station did not take the walk from the tick: $(paste -sd, "$calls")"
unset -f phase intake_census_prime existing_walked_load

# --- case 8: the census the walk and the tick prime comes from the tick's PR cache, whole, and clears the waiting lists. ---
source "$engine_dir/mac-autopilot/scheduler.d/intake.sh"
source "$engine_dir/mac-autopilot/scheduler.d/existing-walk-station.sh"
tick_prs_prime() { :; }
tick_prs() { printf '%s\n' '[{"number":5,"headRefName":"agent/issue-5","title":"t","body":"b","labels":[],"isDraft":false}]'; }
HANDOFF_WAIT_PRS='[9]'; HANDOFF_PR_CENSUS=''; HANDOFF_CENSUS_PARTIAL=1
intake_census_prime
[[ "$HANDOFF_PR_CENSUS" == '[{"number":5,"headRefName":"agent/issue-5","title":"t","body":"b","labels":[]}]' && "$HANDOFF_CENSUS_PARTIAL" == 0 && "$HANDOFF_WAIT_PRS" == '[]' ]] \
  || fail "census prime wrong: $HANDOFF_PR_CENSUS partial=$HANDOFF_CENSUS_PARTIAL wait=$HANDOFF_WAIT_PRS"

# --- case 9: scheduler.sh routes --existing-walk to the pass without reading the tick's runtime config first; loop.sh launches it on its cadence. ---
grep -Fq -- '--existing-walk) SCHED_STATION=true; existing_walk_tick ;;' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh does not route --existing-walk'
grep -Fq '"${1:-}" != --existing-walk' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'a station pass would reconcile the tick runtime config'
hl="$fixture/loop"; mkdir -p "$hl/live" "$hl/state"
cat > "$hl/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HL_CALLS"
SH
loop_window() { # seconds
  ( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$engine_dir/mac-autopilot/loop.sh"
    A="$hl/state"; LIVE="$hl/live"; export HL_CALLS="$hl/calls"
    export AUTOPI_EXISTING_WALK_SECONDS=30 AUTOPI_HARVEST_STATION_SECONDS=2147483647 AUTOPI_REFILL_SECONDS=2147483647 AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647 AUTOPI_MERGE_STATION_SECONDS=2147483647
    echo '{"workers":[]}' > "$A/workers.json"
    sleep() { SECONDS=$((SECONDS + 5)); }
    refill_window "$1" )
}
: > "$hl/calls"
loop_window 25 || fail 'refill window failed before the existing-walk cadence'
[[ ! -s "$hl/calls" ]] || fail "the existing-walk station started before its cadence ($(cat "$hl/calls"))"
loop_window 40 || fail 'refill window failed at the existing-walk cadence'
for _ in $(seq 50); do [[ -s "$hl/calls" ]] && break; command sleep 0.1; done
[[ "$(cat "$hl/calls")" == '--existing-walk' ]] || fail "the existing-walk station was not launched once on cadence ($(cat "$hl/calls" 2>/dev/null))"

echo 'existing-walk-station.test.sh: pass (walk unlocked, per-write lock measured, no second pass, PAUSE, heartbeat gate, walked rows and waiting PRs reach the tick, loop cadence)'
