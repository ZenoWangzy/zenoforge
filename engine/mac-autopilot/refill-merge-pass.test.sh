#!/usr/bin/env bash
# The refill runs a merge pass for a ready-to-merge unit, never alongside the tick's pass.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'refill-merge-pass.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/refill-merge-pass"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.auto_merge=true' "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; A="$MAC_AUTOPILOT_RUNTIME_DIR"; : > "$LOG"

# The refill is killed at its limit: the pass stops before the next candidate, leaving room for the one in progress.
CFG="$(jq -c . "$A/config.json")"; STAMP=T; ROOT="$fixture/repo"; MAIN_HEAD=""
declare -gA TICK_PR_STATE=()
git() { :; }
merge_gate_suites_active() { MERGE_GATE_SUITES_NOTE=""; return 1; }
ci_classify_run() { :; }
tick_prs_prime() { :; }
merge_census_watch() { :; }
retry_blocked_units() { :; }
ready_row='{"id":"u","stage":"ready-to-merge","pr":7,"lane":"pr","issue":9}'
merge_candidates() { printf '%s\n' "$ready_row"; }
printf '{"units":[%s]}\n' "$ready_row" > "$UNITS"
TICK_LOCAL_REFILL=true AUTOPI_REFILL_LIMIT_SECONDS=0 run_merge_lane_pass
grep -q 'merge pass deadline' "$LOG" || fail 'the pass went on past its deadline'
grep -q 'check census unavailable' "$LOG" && fail 'the pass read a candidate past its deadline'
unset -f git merge_candidates
: > "$LOG"

passes=0; run_merge_lane_pass() { passes=$((passes + 1)); }
ready='{"units":[{"id":"u","stage":"ready-to-merge","pr":7,"lane":"pr"}]}'
CFG="$(jq -c . "$A/config.json")"

printf '%s\n' '{"units":[{"id":"u","stage":"review-pending","pr":7}]}' > "$UNITS"
refill_merge_pass; (( passes == 0 )) || fail 'ran without a ready-to-merge unit'
for blocked in '.hold_handoff_waiting=true' '.supervisor_owned=true' '.lane="direct-main"' 'del(.pr)'; do
  printf '%s\n' "$ready" | jq -c ".units[0] |= ($blocked)" > "$UNITS"
  refill_merge_pass; (( passes == 0 )) || fail "ran for a unit excluded by $blocked"
done
printf '%s\n' "$ready" > "$UNITS"
CFG="$(jq -c '.auto_merge=false' "$A/config.json")"; refill_merge_pass; (( passes == 0 )) || fail 'ran with auto_merge off'
CFG="$(jq -c . "$A/config.json")"
refill_merge_pass; (( passes == 1 )) || fail 'did not run for a ready-to-merge unit'
refill_merge_pass; (( passes == 1 )) || fail 'ran again inside merge_refill_min_seconds'
printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$A/.refill-merge-epoch"
refill_merge_pass; (( passes == 2 )) || fail 'did not run again after merge_refill_min_seconds'

# Mutual exclusion with the tick's pass: a held merge lock makes the refill skip and the tick wait.
passes=0
( exec 8>"$A/.merge-lane.lock"; flock -x 8
  MERGE_LANE_WAIT=0 run_merge_lane; [[ "$passes" == 0 ]] || exit 1
  printf '%s\n' 0 > "$fixture/refill-skip" )
[[ -e "$fixture/refill-skip" ]] || fail 'refill ran a pass while another pass held the merge lock'
grep -q 'merge lane busy' "$LOG" || fail 'skip was not logged'
( exec 8>"$A/.merge-lane.lock"; flock -x 8; sleep 3 ) &
holder=$!; sleep 1
start=$SECONDS; run_merge_lane; (( passes == 1 )) || fail 'the tick pass did not run after the lock was released'
(( SECONDS - start >= 1 )) || fail 'the tick pass did not wait for the pass in progress'
wait "$holder"

grep -Fq 'phase_yield_lock refill_merge_pass' "$script_dir/scheduler.sh" || fail 'refill_tick does not run the merge pass'
# The refill is killed at 300s: a pass after intake inherits that deadline in the middle of a merge.
refill_body="$(sed -n '/^refill_tick() {/,/^}/p' "$script_dir/scheduler.sh")"
[[ "${refill_body%%phase_yield_lock refill_merge_pass*}" != *run_refill_intake_dispatch_phases* ]] \
  || fail 'refill_tick runs intake before the merge pass'
printf 'ok - refill merge pass: gated on a ready unit, rate limited, exclusive with the tick pass\n'
