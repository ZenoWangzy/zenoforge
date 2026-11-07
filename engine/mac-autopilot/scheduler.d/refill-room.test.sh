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
walk_state() { TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started; TICK_FOOTPRINT_CAP_HIT=false; TICK_DISPATCH_SKIPS=(); preflight_calls=0; : > "$LOG"; }

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
echo 'refill-room.test.sh: ok'
