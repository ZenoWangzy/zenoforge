#!/usr/bin/env bash
# The refill runs a merge pass for a ready-to-merge unit, never alongside the tick's pass.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
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
# The candidate loop's own stop (limit - 90) needs the clock to pass the pre-loop stop (limit - 120) between those two checks.
tick_prs_prime() { SECONDS=250; }
SECONDS=100; TICK_LOCAL_REFILL=true AUTOPI_REFILL_LIMIT_SECONDS=300 run_merge_lane_pass
grep -q 'merge pass deadline' "$LOG" || fail 'the pass went on past its deadline'
grep -q 'check census unavailable' "$LOG" && fail 'the pass read a candidate past its deadline'
tick_prs_prime() { :; }

# A failed open-PR read is read again inside the pass: bounded in tries and by the refill deadline, and a census that was read is never repeated.
MERGE_CENSUS_RETRY_WAIT=0
tick_prs() { reads=$((reads + 1)); (( reads >= 2 )) || return 1; TICK_PRS='[]'; }
: > "$LOG"; reads=0; TICK_PRS=""; SECONDS=0; run_merge_lane_pass
(( reads == 2 )) || fail "the pass did not read the census again after a failed read: reads=$reads"
grep -Fq 'merge census read failed; retry 1' "$LOG" || fail 'the retry was not logged'
tick_prs() { reads=$((reads + 1)); return 1; }
reads=0; TICK_PRS=""; merge_census_retry; (( reads == 3 )) || fail "a failing read was not bounded to 3 tries: reads=$reads"
reads=0; TICK_PRS=""; SECONDS=200 TICK_LOCAL_REFILL=true merge_census_retry; (( reads == 0 )) || fail 'the retry ran past the refill deadline'
reads=0; TICK_PRS='[]'; merge_census_retry; (( reads == 0 )) || fail 'a census that was read was read again'
unset MERGE_CENSUS_RETRY_WAIT; unset -f tick_prs; TICK_PRS=""; : > "$LOG"

# The stages before the loop cannot stop themselves: a spent budget skips the pass, or ends it between two stages.
: > "$LOG"; stages=0; SECONDS=0
merge_candidates() { stages=$((stages + 1)); printf '%s\n' "$ready_row"; }
ci_classify_run() { SECONDS=200; }
TICK_LOCAL_REFILL=true AUTOPI_REFILL_LIMIT_SECONDS=300 run_merge_lane_pass
grep -Fq 'merge stage main_ci_classify start' "$LOG" || fail "no start line for main_ci_classify: $(cat "$LOG")"
grep -Eq 'merge pass stopped before candidate_build at [0-9]+s' "$LOG" || fail "the pass did not stop between its stages: $(cat "$LOG")"
grep -Fq 'merge stage candidate_build start' "$LOG" && fail 'candidate_build started with the budget spent'
(( stages == 0 )) || fail 'the candidate census ran with the budget spent'
: > "$LOG"; SECONDS=180
TICK_LOCAL_REFILL=true AUTOPI_REFILL_LIMIT_SECONDS=300 run_merge_lane_pass
grep -Eq 'merge pass stopped before suite_gate_lookup at [0-9]+s' "$LOG" || fail "a spent budget did not stop the first stage: $(cat "$LOG")"
SECONDS=0; ci_classify_run() { :; }
: > "$LOG"; : > "$A/.refill-merge-epoch"; TICK_LOCAL_REFILL=true; SECONDS=180
refill_merge_pass
grep -Eq 'merge pass stopped before refill_merge_pass at [0-9]+s' "$LOG" || fail "refill_merge_pass ran with the budget spent: $(cat "$LOG")"
[[ ! -s "$A/.refill-merge-epoch" ]] || fail 'a skipped pass spent the rate-limit slot'
SECONDS=0; unset TICK_LOCAL_REFILL
# The pass names where its time went: a candidate's seconds go to the branch it took, and the step lines print once the pass ran 2s or more.
: > "$LOG"; SECONDS=0; TICK_PRS='[]'
refill_stopped() { SECONDS=$((SECONDS + 3)); return 1; }
run_merge_lane_pass
unset -f refill_stopped; TICK_PRS=""
grep -Eq 'merge detail pass_steps [a-z-]+=[0-9]+s/[0-9]+' "$LOG" || fail "no pass_steps line with a step name: $(cat "$LOG")"
grep -Fq 'merge detail pass_steps skipped-census=3s/1' "$LOG" || fail "pass_steps did not charge the census skip: $(cat "$LOG")"
grep -Fq 'merge detail pass_slowest pr=7 secs=3 outcome=skipped-census' "$LOG" || fail "no pass_slowest line: $(cat "$LOG")"
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
printf '%s\n' "$(( $(date +%s) - 90 ))" > "$A/.refill-merge-epoch"
refill_merge_pass; (( passes == 2 )) || fail 'did not run again 90s after the last pass: the default gap is 60s'
printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$A/.refill-merge-epoch"
refill_merge_pass; (( passes == 3 )) || fail 'did not run again after merge_refill_min_seconds'

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

# The refill is killed at 300s: dispatch runs first so a stalled merge pass cannot starve it, and the merge pass runs before intake
# (a pass after intake inherits that deadline in the middle of a merge).
batch_body="$(sed -n '/^run_refill_intake_dispatch_phases() {/,/^}/p' "$script_dir/scheduler.sh")"
grep -Fq 'phase refill_merge_pass' <<<"$batch_body" || fail 'the refill batch does not run the merge pass'
[[ "${batch_body%%phase refill_merge_pass*}" == *'phase dispatch_pending'* ]] || fail 'the refill merge pass runs before dispatch'
[[ "${batch_body%%phase register_new_issues*}" == *'phase refill_merge_pass'* ]] || fail 'the refill merge pass runs after intake'
printf 'ok - refill merge pass: gated on a ready unit, rate limited, exclusive with the tick pass\n'
