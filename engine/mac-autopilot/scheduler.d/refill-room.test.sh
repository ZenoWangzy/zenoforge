#!/usr/bin/env bash
# One whole-refill budget: refill_room refuses a long step when the seconds already spent plus that step's recent cost
# pass the refill limit, and a full tick never feels it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/refill-room"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false | .auto_merge=true' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
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
SCHED_LOCK_HELD=true
DRY_RUN=0
COST_FILE="$A/.refill-stage-cost"
limit="${AUTOPI_REFILL_LIMIT_SECONDS:-300}"

fail() { echo "refill-room.test.sh: $*" >&2; exit 1; }
refusals() { grep -c "refill room refused stage=$1 " "$LOG" || :; }

git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.name fixture
git -C "$ROOT" config user.email fixture@example.invalid
mkdir -p "$ROOT/src"
printf 'x\n' > "$ROOT/src/a"
git -C "$ROOT" add .
git -C "$ROOT" commit -qm base
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
HOTSPOT_LOG=''; HOTSPOT_LOG_LOADED=true HOTSPOT_LOG_OK=true

# First run, nothing recorded: a default cost applies, below the limit, so an early refill runs and a late one stops.
TICK_LOCAL_REFILL=true
rm -f "$COST_FILE"; : > "$LOG"
need="$(refill_stage_cost preflight)"
(( need > 0 && need < limit )) || fail "default preflight cost out of range: [$need]"
SECONDS=0
refill_room preflight || fail 'an early refill with no recorded cost must have room'
SECONDS=$((limit - 1)); rc=0
refill_room preflight || rc=$?
(( rc == 1 )) || fail "a refill at the limit must be refused with the default cost (rc=$rc)"
grep -Eq "refill room refused stage=preflight at [0-9]+s need=${need}s limit=${limit}s" "$LOG" || fail "refusal line missing or wrong: $(cat "$LOG")"

# A short recorded cost does not let a step start in the last 30s: the kill counts from the refill start, not from SECONDS.
: > "$LOG"; printf 'register_new_issues 9\n' > "$COST_FILE"
SECONDS=$((limit - 10)); rc=0
refill_room register_new_issues || rc=$?
(( rc == 1 )) || fail "intake with a 9s cost must not start 10s before the kill (rc=$rc)"
SECONDS=$((limit - 40))
refill_room register_new_issues || fail 'intake with a 9s cost has room 40s before the kill'

# The recorded cost is the largest of the last few runs, so one slow run counts until newer runs push it out.
: > "$LOG"; rm -f "$COST_FILE"
refill_cost_record preflight 100; refill_cost_record preflight 20
(( $(refill_stage_cost preflight) >= 100 )) || fail 'the slow run must set the cost'
for _ in 1 2 3 4 5; do refill_cost_record preflight 20; done
(( $(refill_stage_cost preflight) < 100 )) || fail 'the slow run must leave the window after five newer runs'
(( $(grep -c '^preflight ' "$COST_FILE") <= 5 )) || fail 'the cost file must keep at most five runs per stage'
refill_cost_record preflight 290
SECONDS=0
refill_room preflight || fail 'a recorded cost never refuses a refill that has just started, or the stage could not run again to record a lower one'

# footprint_room: a refused preflight runs no footprint work, leaves the unit waiting, and shows up in skips.
printf '%s\n' '{"units":[{"id":"u1","issue":1,"stage":"implement-pending","footprint":["src/a"]}]}' > "$UNITS"
unit="$(jq -c '.units[0]' "$UNITS")"
preflight_calls=0
footprint_preflight_snapshot() { preflight_calls=$((preflight_calls + 1)); TICK_FOOTPRINT_PREFLIGHT_STATUS=ready; return 0; }
footprint_shadow_directory_rule() { :; }
TICK_FOOTPRINT_CACHE=([u1]='["src/a"]'); TICK_FOOTPRINT_PREFLIGHT_CONFLICT=()
walk_state() { TICK_FOOTPRINT_DEFER=true; TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started; TICK_FOOTPRINT_CAP_HIT=false; TICK_DISPATCH_SKIPS=(); preflight_calls=0; : > "$LOG"; }

refill_cost_record preflight 200
walk_state; SECONDS=$((limit - 50)); rc=0
footprint_room u1 "$unit" false || rc=$?
(( rc == 1 )) || fail "a refused preflight must refuse the unit (rc=$rc)"
(( preflight_calls == 0 )) || fail 'no footprint work may run once the preflight is refused'
[[ "$TICK_FOOTPRINT_CAP_HIT" == true ]] || fail 'a refused preflight must stop the walk'
[[ "$(dispatch_skip_summary)" == refill-room:1 ]] || fail "skips must name refill-room only: [$(dispatch_skip_summary)]"
(( $(refusals preflight) == 1 )) || fail 'one refusal line expected'
[[ "$(jq -r '.units[0] | .stage + "/" + (.footprint_wait_owner // "none")' "$UNITS")" == implement-pending/none ]] || fail 'the unit must stay pending with no wait mark'

# With room the preflight runs and the unit is admitted.
walk_state; SECONDS=0; rc=0
footprint_room u1 "$unit" false || rc=$?
(( rc == 0 && preflight_calls == 1 )) || fail "a refill with room must run the preflight (rc=$rc calls=$preflight_calls)"
(( $(refusals preflight) == 0 )) || fail 'no refusal expected with room'

# A full tick is never refused, however late and however slow the recorded preflight.
walk_state; TICK_LOCAL_REFILL=false; SECONDS=$((limit * 3)); rc=0
footprint_room u1 "$unit" false || rc=$?
(( rc == 0 && preflight_calls == 1 )) || fail "a full tick must run the preflight (rc=$rc calls=$preflight_calls)"
(( $(refusals preflight) == 0 )) || fail 'a full tick must log no refusal'
TICK_LOCAL_REFILL=true

# The real preflight records how long it took, only in a refill, and only when the run took real time.
unset -f footprint_preflight_snapshot
source "$engine_dir/mac-autopilot/scheduler.d/footprint.sh"
footprint_refresh_conflicts() { SECONDS=$((SECONDS + 3)); TICK_FOOTPRINT_CONFLICT_VALID=true; }
rm -f "$COST_FILE"; TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started; SECONDS=0
footprint_preflight_snapshot || fail 'the real preflight failed on the fixture'
grep -Eq '^preflight [0-9]+$' "$COST_FILE" || fail "a refill preflight must record its cost: $(cat "$COST_FILE" 2>/dev/null)"
rm -f "$COST_FILE"; TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started; TICK_LOCAL_REFILL=false
footprint_preflight_snapshot || fail 'the real preflight failed on a full tick'
[[ ! -e "$COST_FILE" ]] || fail 'a full tick must not write refill costs'
TICK_LOCAL_REFILL=true

# The merge pass: refused by the helper where the older bound (limit-120) still lets it start, and no interval is spent.
run_calls=0; run_merge_lane() { run_calls=$((run_calls + 1)); }
printf '%s\n' '{"units":[{"id":"m1","issue":2,"stage":"ready-to-merge","pr":7,"lane":"pr"}]}' > "$UNITS"
rm -f "$COST_FILE" "$A/.refill-merge-epoch"; : > "$LOG"
refill_cost_record refill_merge_pass 140
SECONDS=$((limit - 125))
refill_merge_pass
(( run_calls == 0 )) || fail 'the merge pass must not start when its recent cost passes the limit'
[[ ! -e "$A/.refill-merge-epoch" ]] || fail 'a refused merge pass must not spend the refill interval'
(( $(refusals refill_merge_pass) == 1 )) || fail 'one merge refusal line expected'
SECONDS=0
refill_merge_pass
(( run_calls == 1 )) || fail "the merge pass must run with room (calls=$run_calls)"

# Intake: refused at its head, before any read.
: > "$LOG"; rm -f "$COST_FILE"
refill_cost_record register_new_issues 140
SECONDS=$((limit - 125)); rc=0
register_new_issues 0 true || rc=$?
(( rc == 0 && $(refusals register_new_issues) == 1 )) || fail "a refill intake that cannot finish must stop at its head (rc=$rc)"

# phase() feeds the costs: a refill phase that took real time is recorded under its name.
rm -f "$COST_FILE"; SECONDS=0
slow_stage() { SECONDS=$((SECONDS + 4)); }
phase slow_stage
grep -q '^slow_stage ' "$COST_FILE" 2>/dev/null && fail 'only the named long stages are recorded'
register_new_issues() { SECONDS=$((SECONDS + 4)); }
phase register_new_issues 0 true
grep -Eq '^register_new_issues [0-9]+$' "$COST_FILE" || fail 'phase must record register_new_issues'
# The ledger-lock wait: a refill stops waiting at its own deadline (the full tick can hold the lock for minutes), a full tick keeps waiting.
# A waiter that never returns is stopped by its own pid after a generous poll, so a missing fix fails the test and does not hang it.
await_rc() { # rc-file: poll for the waiter's exit code
  local _
  for _ in $(seq 100); do [[ -e "$1" ]] && return 0; read -r -t 0.1 <> <(:) || :; done
  return 1
}
SCHED_LOCK_HELD=false
mkdir "$SCHED_LOCK"; sleep 300 >/dev/null 2>&1 & holder=$!; echo "$holder" > "$SCHED_LOCK/pid" # a live foreign owner
trap 'kill "$holder" 2>/dev/null || :; test_env_chain_exit "$test_env_root" "$test_env_prior_exit"' EXIT
lock_rc="$A/.lock-wait-rc"; rm -f "$lock_rc"; : > "$LOG"
TICK_LOCAL_REFILL=true; SECONDS=$((limit - 5))
( rc=0; acquire_scheduler_lock_wait || rc=$?; echo "$rc" > "$lock_rc" ) & waiter=$!
await_rc "$lock_rc" || { kill "$waiter" 2>/dev/null || :; wait "$waiter" 2>/dev/null || :; fail 'a refill past its deadline kept waiting for the ledger lock'; }
[[ "$(cat "$lock_rc")" == 1 ]] || fail "a refill past its deadline must fail the lock wait (rc=$(cat "$lock_rc"))"
grep -q 'ledger lock wait stopped' "$LOG" || fail 'the refused wait must say so in the log'
# The stop is counted once per refill, with the token bell.sh and engine-canary.sh match, and tells itself from a kill by "stop".
for _ in 1 2; do rm -f "$lock_rc"; ( rc=0; acquire_scheduler_lock_wait || rc=$?; echo "$rc" > "$lock_rc" ) & waiter=$!
  await_rc "$lock_rc" || { kill "$waiter" 2>/dev/null || :; fail 'a wait after the stop must fail at once'; }; wait "$waiter"; done
[[ "$(grep -c 'REFILL-TIMEOUT stop: ledger lock wait stopped' "$LOG")" == 1 ]] || fail 'the stop must log one REFILL-TIMEOUT line per refill'
grep -q 'REFILL-TIMEOUT refill tick killed' "$LOG" && fail 'a stop must not read as a kill'
rm -f "$lock_rc" "$A/.refill-stop"; refill_lock_stage() { :; }
( rc=0; phase_yield_lock refill_lock_stage || rc=$?; echo "$rc" > "$lock_rc" ) & waiter=$!
await_rc "$lock_rc" || { kill "$waiter" 2>/dev/null || :; wait "$waiter" 2>/dev/null || :; fail 'a yielded phase kept waiting past the refill deadline'; }
[[ "$(cat "$lock_rc")" == 1 ]] || fail 'a yielded phase that cannot retake the lock must return failure'
rm -f "$lock_rc" "$A/.refill-stop"
# A wait refused in the middle of a dispatch ends the refill: the unit after it starts no worker and gets no ledger write, and no later phase runs.
# The first start takes 70s and the foreign holder takes the lock meanwhile, so the stage write after the start is the refused one.
# The margin is widened to 200s so the stop lands before the walk's own limit-90 deadline, which would otherwise end the walk by itself.
rm -rf "$SCHED_LOCK"; : > "$LOG"; SECONDS=50; started=""; export AUTOPI_REFILL_LOCK_MARGIN_SECONDS=200
jq -n '{units:[range(0;2) | {id:"u\(.)",stage:"implement-pending",task:"t",branch:"agent/u\(.)",history:[]}]}' > "$UNITS"
dispatch_order() { jqf -c '.units[]' "$UNITS"; }
ticket_budget_reason() { return 0; }; loop_rounds() { echo 0; }; blocking_body_dependency() { return 0; }; room_for() { return 0; }
pick() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }; footprint_room() { return 0; }
ensure_clone() { printf '%s\n' "$ROOT"; }; resume_handoff_integration() { return 0; }; size_admission_write_start() { return 0; }
verification_plan_for_state() { echo '{}'; }; verification_plan_brief() { echo focused; }; matt_method_rule() { :; }; decision_scope() { :; }
live_workers() { echo 0; }; live_by_type() { echo 0; }; footprint_waiters_revalidate() { return 0; }; tick_prs_prime() { :; }
dispatch() { started+=" $4"; mkdir "$SCHED_LOCK"; echo "$holder" > "$SCHED_LOCK/pid"; SECONDS=120; return 0; }
dispatch_pending true >/dev/null 2>&1 || :
[[ "$started" == " u0" ]] || fail "a worker started after the ledger wait was refused (started:$started)"
[[ "$(jq -r '.units[1] | [.report // "none", .stage] | join(" ")' "$UNITS")" == 'none implement-pending' ]] || fail 'the unit after the stop got a ledger write'
[[ "$(grep -c 'REFILL-TIMEOUT stop:' "$LOG")" == 1 ]] || fail 'the stop in a dispatch must be logged once'
ran=""; stopped_phase() { ran=yes; }
! phase stopped_phase && [[ -z "$ran" ]] || fail 'a phase ran after the refill was stopped'
rm -f "$A/.refill-stop"; unset AUTOPI_REFILL_LOCK_MARGIN_SECONDS; unset -f dispatch dispatch_order room_for pick footprint_room ensure_clone size_admission_write_start tick_prs_prime
TICK_LOCAL_REFILL=false
( rc=0; acquire_scheduler_lock_wait || rc=$?; echo "$rc" > "$lock_rc" ) & waiter=$!
read -r -t 1 <> <(:) || :
[[ ! -e "$lock_rc" ]] || { kill "$holder" "$waiter" 2>/dev/null || :; fail 'a full tick must keep waiting for the ledger lock'; }
kill "$holder"; wait "$holder" 2>/dev/null || :
await_rc "$lock_rc" || { kill "$waiter" 2>/dev/null || :; wait "$waiter" 2>/dev/null || :; fail 'a full tick did not take the lock once it was free'; }
[[ "$(cat "$lock_rc")" == 0 ]] || fail 'a full tick must take the free lock'
rm -rf "$SCHED_LOCK"; SCHED_LOCK_HELD=true; TICK_LOCAL_REFILL=true
# cleanup_tick runs without the ledger lock at the end of a tick: its one workers write takes the lock itself and gives it back.
SCHED_LOCK_HELD=false; rm -rf "$SCHED_LOCK"
jq -n '{workers: [range(0;70) | {pid: (. + 1000), unit: "u\(.)", harvested: true, started: "2026-11-07T00:00:\(10 + (. % 50))Z"}]}' > "$WORKERS"
sys_tmp="$(mktemp -d)"
AP_SYSTEM_TMP="$sys_tmp" AP_SYSTEM_TMP_FS=ext4 cleanup_tick || : # its last step is a best-effort branch sweep
[[ "$(jq '.workers | length' "$WORKERS")" == 60 ]] || fail 'cleanup_tick did not trim the workers ledger without the lock held'
[[ ! -e "$SCHED_LOCK" && "$SCHED_LOCK_HELD" == false ]] || fail 'cleanup_tick kept the ledger lock'
SCHED_LOCK_HELD=true
echo 'refill-room.test.sh: ok'
