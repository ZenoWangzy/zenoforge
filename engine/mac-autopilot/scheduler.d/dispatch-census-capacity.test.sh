#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-census-capacity"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0

fail() { echo "dispatch-census-capacity.test.sh: $*" >&2; exit 1; }
write_workers() { # n live implement workers
  jq -n --argjson n "$1" '{workers:[range(1; ($n + 1)) | {pid:(100000 + .),unit:("busy-" + tostring),type:"implement"}]}' > "$WORKERS"
  LIVE_WORKER_CACHE_UNTIL=0
}

# Incident #5147 shape: every gh call from dispatch_pending lands in this file; the canned
# census answers `pr list`, and anything else fails loudly instead of touching the network.
GH_CALLS="$fixture/gh-calls"
FIXTURE_PRS="$fixture/prs.json"
sha=2222222222222222222222222222222222222222
jq -n --arg sha "$sha" '[{number:503,headRefOid:$sha,headRefName:"agent/issue-4903",baseRefName:"main",
  isDraft:false,title:"fixture",labels:[],body:"",statusCheckRollup:[],mergeable:"UNKNOWN",createdAt:"2026-11-03T00:00:00Z"}]' > "$FIXTURE_PRS"
: > "$GH_CALLS"
gh() {
  printf '%s %s\n' "${1:-}" "${2:-}" >> "$GH_CALLS"
  case "${1:-} ${2:-}" in
    'pr list') cat "$FIXTURE_PRS" ;;
    'pr view') printf 'CONFLICTING %s\n' "$sha" ;; # the one GitHub re-check merge_conflict_to_repair makes
    *) printf 'unexpected gh query during dispatch: %s\n' "$*" >&2; return 97 ;;
  esac
}
alive() { return 0; }
SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
printf '%s\n' 'supervisor_inbox_append_once() { :; }' > "$SCHEDULER_AGENT_LIB"

pr_stage_units() { # one unit per dispatch stage, none at stop-loss/advisor/reopen boundaries
  jq -n '{units:[
    {id:"issue-4901",stage:"repair-pending",pr:501,branch:"agent/issue-4901",lane:"pr",title:"fixture repair",
     review_report:"review-501.md",history:[]},
    {id:"issue-4902",stage:"rereview-pending",pr:502,branch:"agent/issue-4902",lane:"pr",title:"fixture rereview",history:[]},
    {id:"issue-4903",stage:"review-pending",pr:503,branch:"agent/issue-4903",lane:"pr",title:"fixture review",history:[]},
    {id:"issue-4904",stage:"implement-pending",task:"fixture task text",branch:"agent/issue-4904",lane:"pr",title:"fixture implement",history:[]}]}' > "$UNITS"
}

# A full factory (live == max_workers) must dispatch nothing and read no PR census: every
# PR-stage candidate dies at room_for's capacity check, so the census fetch is pure waste
# (12h of live logs: 51/387 refills at 8/8 each paid a 9-15s `gh pr list`).
pr_stage_units
write_workers 8
for mode in true false; do
  : > "$GH_CALLS"; : > "$LOG"
  dispatch_pending "$mode"
  [[ -z "$(cat "$GH_CALLS")" ]] || fail "full-capacity dispatch_pending (refill=$mode) made gh calls: $(tr '\n' ';' < "$GH_CALLS")"
  grep -Fq 'capacity 8/8' "$LOG" || fail "full-capacity dispatch_pending (refill=$mode) never reached the capacity skip"
done

# At capacity a refill stops at the first unit. A full tick's pass walks every unit, so parks and holds still run.
walk_stops() { grep -c 'dispatch walk stopped at capacity 8/8' "$LOG" || true; }
walk_skips() { grep -c 'skip dispatch unit=.*capacity 8/8' "$LOG" || true; }
: > "$LOG"; dispatch_pending false
[[ "$(walk_stops)" == 0 && "$(walk_skips)" -ge 2 ]] || fail "the first pass of a full tick did not walk every unit: $(cat "$LOG")"
: > "$LOG"; dispatch_pending true
[[ "$(walk_stops)" == 1 && "$(walk_skips)" == 0 ]] || fail "a refill walked at capacity: $(cat "$LOG")"

# Capacity free: the first PR-stage candidate that passes room_for still gets exactly one
# fresh census, and the review dispatch proceeds on it (no per-PR view fallbacks).
dispatch_calls=0
pick_review_for_unit() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
verify_handoff_delivery() { return 0; }
ensure_clone() { printf '%s\n' "$ROOT"; }
checkout_pr_head() { return 0; }
review_prompt() { :; }
arbiter_rule() { :; }
hotpatch_rule() { :; }
supervisor_rule() { :; }
dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); return 0; }
jq -n '{units:[{id:"issue-4903",stage:"review-pending",pr:503,branch:"agent/issue-4903",lane:"pr",title:"fixture review",history:[]}]}' > "$UNITS"
write_workers 7
: > "$GH_CALLS"; : > "$LOG"
TICK_PRS=''
dispatch_pending true
[[ "$(cat "$GH_CALLS")" == 'pr list' ]] || fail "expected exactly one census read at 7/8, got: $(tr '\n' ';' < "$GH_CALLS")"
[[ "$dispatch_calls" == 1 ]] || fail "admitted review candidate was not dispatched (calls=$dispatch_calls)"
# One steps line per pass: every row step it ran, with seconds and counts, in the shape of `intake detail steps`.
steps_line="$(grep -F 'dispatch detail steps refill=true' "$LOG")" || fail "no dispatch steps line: $(cat "$LOG")"
for step in order row_head room_for review_target reviewer_pick clone checkout prompt dispatch; do
  [[ "$steps_line" =~ \ $step=[0-9]+\.[0-9]{3}s/1(\ |$) ]] || fail "steps line lacks $step/1: $steps_line"
done

# A CONFLICTING census row sends a review-pending and a rereview-pending unit to conflict repair, not review: no worker is
# dispatched, and the only extra gh call is the one `pr view` re-check per unit (the clean census above made none).
dispatch_calls=0
jq -n --arg sha "$sha" '[range(503; 505) | {number:.,headRefOid:$sha,headRefName:"agent/issue-49\(. - 500)",baseRefName:"main",
  isDraft:false,title:"fixture",labels:[],body:"",statusCheckRollup:[],mergeable:"CONFLICTING",createdAt:"2026-11-03T00:00:00Z"}]' > "$FIXTURE_PRS"
jq -n '{units:[{id:"issue-4903",stage:"review-pending",pr:503,branch:"agent/issue-4903",lane:"pr",title:"fixture review",history:[]},
  {id:"issue-4904",stage:"rereview-pending",pr:504,branch:"agent/issue-4904",lane:"pr",title:"fixture rereview",history:[]}]}' > "$UNITS"
write_workers 7
: > "$GH_CALLS"; : > "$LOG"
TICK_PRS=''
dispatch_pending true
[[ "$dispatch_calls" == 0 ]] || fail "a CONFLICTING PR was dispatched to review (calls=$dispatch_calls)"
[[ "$(sort "$GH_CALLS" | uniq -c | tr -s ' ' | tr '\n' ';')" == ' 1 pr list; 2 pr view;' ]] || fail "unexpected gh calls for two conflicts: $(tr '\n' ';' < "$GH_CALLS")"
for u in issue-4903 issue-4904; do
  jq -e --arg id "$u" '.units[] | select(.id == $id) | .stage == "repair-pending" and (.repair_hint | contains("git merge --no-edit origin/main")) and ([.history[].stage] | index("merge-conflict") != null)' "$UNITS" >/dev/null \
    || fail "$u was not routed to conflict repair: $(jq -c --arg id "$u" '.units[] | select(.id == $id)' "$UNITS")"
done
jq -n --arg sha "$sha" '[{number:503,headRefOid:$sha,headRefName:"agent/issue-4903",baseRefName:"main",isDraft:false,title:"fixture",labels:[],body:"",
  statusCheckRollup:[],mergeable:"UNKNOWN",createdAt:"2026-11-03T00:00:00Z"}]' > "$FIXTURE_PRS"
jq -n '{units:[{id:"issue-4903",stage:"review-pending",pr:503,branch:"agent/issue-4903",lane:"pr",title:"fixture review",history:[]}]}' > "$UNITS"

# A refill near its 300s kill stops the walk and leaves the unit for the next refill; a full tick has no such limit.
dispatch_calls=0
: > "$GH_CALLS"; : > "$LOG"
TICK_PRS=''
SECONDS=250
TICK_LOCAL_REFILL=true dispatch_pending true
[[ "$dispatch_calls" == 0 ]] || fail "a late refill still dispatched (calls=$dispatch_calls)"
grep -Eq 'dispatch deadline after [0-9]+s: units from issue-4903 wait for the next refill' "$LOG" || fail "no deadline line: $(cat "$LOG")"
: > "$LOG"
SECONDS=100
TICK_LOCAL_REFILL=true dispatch_pending true
[[ "$dispatch_calls" == 1 ]] || fail "a refill before the deadline did not dispatch (calls=$dispatch_calls)"
! grep -Fq 'dispatch deadline' "$LOG" || fail "an early refill stopped: $(cat "$LOG")"
: > "$LOG"
SECONDS=250
dispatch_pending false
[[ "$dispatch_calls" == 2 ]] || fail "a full tick stopped at the refill deadline (calls=$dispatch_calls)"

# A self-fix is a repair round too: at the ticket stop-loss it goes to the supervisor, and below it the fix starts.
jq -n '{units:[{id:"issue-4903",issue:4903,pr:503,stage:"review-pending",self_fix_pending:true,branch:"agent/issue-4903",lane:"pr",title:"fixture self-fix",history:[]}]}' > "$UNITS"
write_workers 7
self_fix_calls=0; stop_loss_calls=0
self_fix_dispatch() { self_fix_calls=$((self_fix_calls + 1)); }
to_supervisor() { stop_loss_calls=$((stop_loss_calls + 1)); }
: > "$fixture/hold.sh"; export ZF_ENGINE_DIR="$fixture"
gh() { return 0; }
ticket_budget_reason() { printf '9 rounds\n'; }
: > "$LOG"; SECONDS=0; dispatch_pending false
[[ "$self_fix_calls" == 0 && "$stop_loss_calls" == 1 ]] || fail "a self-fix passed the stop-loss (fix=$self_fix_calls supervisor=$stop_loss_calls)"
ticket_budget_reason() { :; }
: > "$LOG"; stop_loss_calls=0; dispatch_pending false
[[ "$self_fix_calls" == 1 && "$stop_loss_calls" == 0 ]] || fail "a self-fix under budget did not start (fix=$self_fix_calls supervisor=$stop_loss_calls)"

# A review-pending unit without a PR is dropped by the walk with no log line: the pass names it, and the refill summary carries it.
jq -n '{units:[{id:"issue-4905",stage:"review-pending",lane:"pr",title:"fixture no-pr review",history:[]}]}' > "$UNITS"
write_workers 7
: > "$GH_CALLS"; : > "$LOG"
dispatch_pending true
[[ "$(dispatch_skip_summary)" == 'no-pr:1' ]] || fail "a silent no-PR pass was not counted: $(dispatch_skip_summary)"
[[ "$(refill_dispatch_metrics 0 7)" == *' skips=footprint:0,handoff:0,memory:0,no-pr:1' ]] || fail "refill summary omitted the no-PR skip"

# A full tick past its walk deadline still reaches the stop-loss park, but refuses every start at room_for and counts it.
jq -n '{units:[
  {id:"issue-4904",stage:"implement-pending",task:"fixture task text",branch:"agent/issue-4904",lane:"pr",title:"fixture implement",history:[]},
  {id:"issue-4907",issue:4907,pr:507,stage:"repair-pending",branch:"agent/issue-4907",lane:"pr",title:"fixture repair",review_report:"review-507.md",history:[]}]}' > "$UNITS"
write_workers 3
ticket_budget_reason() { [[ "$1" == *issue-4907* ]] && printf '9 rounds\n' || :; }
dispatch_calls=0; stop_loss_calls=0
: > "$LOG"; SECONDS=0
AUTOPI_TICK_DISPATCH_SECONDS=0 dispatch_pending false
[[ "$(grep -c 'dispatch deadline after .*parks and holds only' "$LOG")" == 1 ]] || fail "no single tick walk deadline line: $(cat "$LOG")"
[[ "$stop_loss_calls" == 1 ]] || fail "a unit past the walk deadline missed its stop-loss park (calls=$stop_loss_calls)"
[[ "$dispatch_calls" == 0 ]] || fail "a start ran past the walk deadline (calls=$dispatch_calls)"
[[ "$(dispatch_skip_summary)" == 'tick-deadline:1' ]] || fail "the refused start was not counted: $(dispatch_skip_summary)"
: > "$LOG"; dispatch_pending false
! grep -Fq 'dispatch deadline' "$LOG" || fail "the default walk deadline fired at once: $(cat "$LOG")"

# A refill stops once the units that reached footprint work pass the cap; cheap skips before it do not count.
jq -n '{units:[range(0;3) | {id:("issue-490" + tostring),stage:"implement-pending",task:"fixture task text",branch:("agent/issue-490" + tostring),lane:"pr",title:"fixture implement",history:[]}]}' > "$UNITS"
write_workers 3
ticket_budget_reason() { :; }
footprint_calls=0
_footprint_room() { footprint_calls=$((footprint_calls + 1)); return 1; }
saved_cfg="$CFG"; CFG="$(jq -c '.issue_intake.refill_max_footprint_candidates = 2' <<<"$CFG")"
: > "$LOG"; SECONDS=0
dispatch_pending true
[[ "$footprint_calls" == 2 ]] || fail "footprint work ran for $footprint_calls candidates, want the cap of 2"
[[ "$(grep -c 'dispatch walk stopped at cap 2' "$LOG")" == 1 ]] || fail "no single cap line: $(cat "$LOG")"
[[ "$(dispatch_skip_summary)" == *footprint-cap:1* ]] || fail "the cap was not counted: $(dispatch_skip_summary)"
CFG="$saved_cfg"

# A stop-loss that repeats an earlier round's failure is decided by the cap-default route, not sent to the arbiter (row 93: row 90 saw 0 of 4 requeues deliver).
# Hash and number noise must not hide the repeat; a fresh failure and a unit already given a cap default still go to the supervisor.
scheduler_issue_state() { printf '{"state":"in-progress"}\n'; }
scheduler_route_to_recut() { :; }
tick_pr_state() { printf 'OPEN\n'; }
ticket_budget_reason() { printf 'rounds 3 of 3\n'; }
write_workers 3
red_history() { # first-result second-result [extra-first-event]
  jq -cn --arg a "$1" --arg b "$2" --argjson extra "${3:-[]}" '$extra + [{stage:"self-check-red",result:$a,at:"2026-11-08T10:00:00Z"},{stage:"repair-no-push",at:"2026-11-08T10:30:00Z"},{stage:"self-check-red",result:$b,at:"2026-11-08T11:00:00Z"}]'
}
stop_loss_case() { # id history pr-or-empty stage → runs one dispatch pass at the stop-loss
  jq -n --arg id "$1" --argjson h "$2" --arg pr "$3" --arg stage "$4" \
    '{units:[({id:$id,issue:($id | ltrimstr("issue-") | tonumber),stage:$stage,task:"fixture task text",branch:("agent/" + $id),lane:"pr",title:"fixture stop-loss",history:$h} + (if $pr == "" then {} else {pr:($pr | tonumber),review_report:"review-fixture.md"} end))]}' > "$UNITS"
  stop_loss_calls=0; : > "$LOG"; SECONDS=0
  dispatch_pending false
}
case_stage() { jq -r --arg id "$1" '.units[] | select(.id == $id) | .stage' "$UNITS"; }
case_events() { jq -r --arg id "$1" '[.units[] | select(.id == $id) | .history[].stage] | join(",")' "$UNITS"; }
same_a='self-check failed at 4f9a2c1d: 12 tests, 3 failed (core/budget)'
same_b='self-check failed at 77be0e3a: 15 tests, 3 failed (core/budget)'
head_one=2222222222222222222222222222222222222222
tick_pr_head() { printf '%s\n' "$head_one"; }
stop_loss_case issue-4911 "$(red_history "$same_a" "$same_b")" '' implement-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4911)" == closed ]] || fail "a repeated failure was not recut (calls=$stop_loss_calls stage=$(case_stage issue-4911))"
[[ "$(case_events issue-4911)" == *supervisor-budget-recut,supervisor-cap-default ]] || fail "recut and cap-default events missing: $(case_events issue-4911)"
[[ "$(case_events issue-4911)" != *supervisor-escalated* && "$(case_events issue-4911)" != *supervisor-review* ]] || fail "a repeated failure reached the arbiter: $(case_events issue-4911)"
jq -e '.units[0].history[-1].result | contains("stop-loss same failure")' "$UNITS" >/dev/null || fail "the cap-default event does not name the stop-loss same failure"
# Same again after a recut was already spent: park (an open PR is never closed by this route).
stop_loss_case issue-4912 "$(red_history "$same_a" "$same_b" '[{"stage":"supervisor-budget-recut","result":"earlier","at":"2026-11-07T10:00:00Z"}]')" '' implement-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4912)" == parked && "$(case_events issue-4912)" == *supervisor-budget-park,supervisor-cap-default ]] \
  || fail "a repeat after a spent recut was not parked (calls=$stop_loss_calls stage=$(case_stage issue-4912) events=$(case_events issue-4912))"
stop_loss_case issue-4913 "$(red_history "$same_a" "$same_b")" 513 repair-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4913)" == parked ]] || fail "a repeated failure on a PR unit was not parked (calls=$stop_loss_calls stage=$(case_stage issue-4913))"
[[ "$(jq -r '.units[0].parked_reason' "$UNITS")" == "stop-loss same failure: $same_b" && "$(jq -r '.units[0].stop_loss_park_head' "$UNITS")" == "$head_one" ]] \
  || fail "the park reason or the PR head it waits on is wrong: $(jq -c '.units[0] | [.parked_reason, .unpark_condition, .stop_loss_park_head]' "$UNITS")"
# Exit 1: the park holds while the PR head is the one it parked on, and requeues with a refilled budget when it changes.
stop_loss_unpark_sweep
[[ "$(case_stage issue-4913)" == parked ]] || fail "the park lifted with an unchanged PR head"
head_one=3333333333333333333333333333333333333333
tick_pr_head() { printf '%s\n' "$head_one"; }
stop_loss_unpark_sweep
[[ "$(case_stage issue-4913)" == repair-pending && "$(case_events issue-4913)" == *,supervisor-requeue ]] || fail "a changed PR head did not requeue: $(case_stage issue-4913) $(case_events issue-4913)"
jq -e '.units[0] | .parked_reason == null and .stop_loss_park_head == null' "$UNITS" >/dev/null || fail "the park fields survived the requeue"
stop_loss_same_failure "$(jq -c '.units[0]' "$UNITS")" >/dev/null && fail "the requeue did not restart the failure window"
# A check that is red on main belongs to main: the unit waits (main-red park, no cap default, no arbiter) and requeues once that main red is resolved.
main_sha=4444444444444444444444444444444444444444
main_red_failed_checks() { printf '["Pipeline suites"]\n'; }
tick_pr_head() { printf '%s\n' "$head_one"; }
red_check_history() { red_history 'Pipeline suites' 'Pipeline suites'; }
jq -n --argjson h "$(red_check_history | jq -c 'map(.stage = "ci-test-red")')" --arg sha "$main_sha" \
  '{units:[{id:"issue-4917",issue:4917,pr:517,stage:"repair-pending",branch:"agent/issue-4917",lane:"pr",title:"fixture stop-loss",review_report:"review-fixture.md",history:$h},
    {id:"main-red-444444444",main_red:true,ci_sha:$sha,stage:"supervisor-review",history:[]}]}' > "$UNITS"
stop_loss_calls=0; : > "$LOG"; SECONDS=0
dispatch_pending false
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4917)" == parked && "$(jq -r '.units[0].parked_reason' "$UNITS")" == main-red ]] \
  || fail "a failure red on main was not left waiting (calls=$stop_loss_calls $(jq -c '.units[0] | [.stage,.parked_reason]' "$UNITS"))"
[[ "$(case_events issue-4917)" != *supervisor-cap-default* && "$(case_events issue-4917)" != *supervisor-escalated* ]] || fail "a main-red failure got a cap default or reached the arbiter: $(case_events issue-4917)"
[[ "$(jq -r '.units[0].history[-1].result' "$UNITS")" == "stop-loss same failure: Pipeline suites also failed on main $main_sha" ]] || fail "the wait names the wrong reason: $(jq -r '.units[0].history[-1].result' "$UNITS")"
# Exit 2: main green. The main-red unit is still open, so the wait holds; closed with a resolving SHA, it requeues.
stop_loss_unpark_sweep
[[ "$(case_stage issue-4917)" == parked ]] || fail "the wait lifted while main was still red"
jq -c '.units[1] += {stage:"closed",resolved_main_sha:"5555555555555555555555555555555555555555",resolved_main_at:"2026-11-08T12:00:00Z"}' "$UNITS" > "$UNITS.new" && mv "$UNITS.new" "$UNITS"
stop_loss_unpark_sweep
[[ "$(case_stage issue-4917)" == repair-pending && "$(case_events issue-4917)" == *,supervisor-requeue ]] || fail "main green did not requeue: $(case_stage issue-4917) $(case_events issue-4917)"
stop_loss_main_red_sha 'Pipeline suites' >/dev/null && fail "a resolved main red still counted as red"
# A same-failure park with an open PR gets one timed retry: parked 24 h and main advanced -> update the branch and requeue once. Not before 24 h, not with main unchanged.
main_red_failed_checks() { return 1; }
rebases=0; ci_update_branch() { rebases=$((rebases + 1)); rebased_to="$1 $2"; return 0; }
m1=6666666666666666666666666666666666666666 m2=7777777777777777777777777777777777777777 m3=8888888888888888888888888888888888888888
park_now=$(date +%s); NOW_EPOCH=$park_now; MAIN_HEAD=$m1
stop_loss_case issue-4918 "$(red_history "$same_a" "$same_b")" 518 repair-pending
[[ "$(case_stage issue-4918)" == parked && "$(jq -r '.units[0].stop_loss_park_epoch' "$UNITS")" == "$park_now" && "$(jq -r '.units[0].stop_loss_park_main' "$UNITS")" == "$m1" ]] \
  || fail "the park did not record its time and main: $(jq -c '.units[0] | [.stage,.stop_loss_park_epoch,.stop_loss_park_main]' "$UNITS")"
NOW_EPOCH=$((park_now + 86401)); MAIN_HEAD=$m1; stop_loss_unpark_sweep
[[ "$(case_stage issue-4918)" == parked && "$rebases" == 0 ]] || fail "24 h with main unchanged lifted the park (rebases=$rebases)"
NOW_EPOCH=$((park_now + 3600)); MAIN_HEAD=$m2; stop_loss_unpark_sweep
[[ "$(case_stage issue-4918)" == parked && "$rebases" == 0 ]] || fail "main advanced inside 24 h lifted the park (rebases=$rebases)"
NOW_EPOCH=$((park_now + 86401)); MAIN_HEAD=$m2; stop_loss_unpark_sweep
[[ "$(case_stage issue-4918)" == repair-pending && "$(case_events issue-4918)" == *,supervisor-requeue && "$rebases" == 1 && "$rebased_to" == "518 $head_one" ]] \
  || fail "24 h plus main advanced did not requeue once with a branch update ($(case_stage issue-4918) rebases=$rebases $rebased_to)"
jq -e '.units[0] | .stop_loss_timed_requeue == true and .stop_loss_park_epoch == null' "$UNITS" >/dev/null || fail "the timed requeue left its marks wrong"
# The second same failure parks again, with no timed exit however long it waits or however far main moves.
jq -c --argjson more "$(red_history "$same_a" "$same_b")" '.units[0].history += $more' "$UNITS" > "$UNITS.new" && mv "$UNITS.new" "$UNITS"
stop_loss_calls=0; : > "$LOG"; SECONDS=0; MAIN_HEAD=$m2; dispatch_pending false
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4918)" == parked && "$(jq -r '.units[0].parked_reason' "$UNITS")" == "stop-loss same failure: $same_b" ]] \
  || fail "the second same failure did not park (calls=$stop_loss_calls $(jq -c '.units[0] | [.stage,.parked_reason]' "$UNITS"))"
jq -e '.units[0] | .stop_loss_park_epoch == null and .stop_loss_park_main == null' "$UNITS" >/dev/null || fail "the second park got a timed exit"
NOW_EPOCH=$((park_now + 10 * 86400)); MAIN_HEAD=$m3; stop_loss_unpark_sweep
[[ "$(case_stage issue-4918)" == parked && "$rebases" == 1 ]] || fail "the second park lifted on a timer (rebases=$rebases)"
NOW_EPOCH=$(date +%s); MAIN_HEAD=""

# A first-time red is a fresh signal now: the scheduler requeues it once (see below). A ruling between the reds, or a cap default already given: as before.
stop_loss_case issue-4915 "$(red_history "$same_a" "$same_b" '[]' | jq -c '.[0:2] + [{stage:"supervisor-requeue",at:"2026-11-08T10:45:00Z"}] + .[2:]')" 150 repair-pending
[[ "$stop_loss_calls" == 0 && "$(case_events issue-4915)" == *,supervisor-requeue,self-check-red,supervisor-requeue ]] || fail "a red from before a ruling counted as an earlier round (calls=$stop_loss_calls $(case_events issue-4915))"
stop_loss_case issue-4916 "$(red_history "$same_a" "$same_b" '[{"stage":"supervisor-cap-default","result":"branch=park: earlier","at":"2026-11-07T10:00:00Z"}]')" 160 repair-pending
[[ "$stop_loss_calls" == 1 && "$(case_stage issue-4916)" == repair-pending ]] || fail "a unit that already had its cap default must still go to the supervisor (calls=$stop_loss_calls)"

# A fresh signal (review request-changes, merge conflict, a first-time red) at rounds 3 of 3 is requeued by the scheduler with no model run (row 94: the arbiter
# requeued 30 of 31 and 16 of 22 delivered). The event names the signal. A repeat of that signal is the same failure; a different one requeues once more; a third goes to the arbiter.
fresh_prefix='scheduler fresh-signal requeue: '
fresh_events() { # stages and results of the unit's history, one per line
  jq -r --arg id "$1" '.units[] | select(.id == $id) | .history[] | .stage + " " + (.result // "")' "$UNITS"
}
rework='{"stage":"review-request-changes","result":"2 findings","at":"2026-11-08T10:00:00Z"}'
sched_rework="{\"stage\":\"supervisor-requeue\",\"result\":\"${fresh_prefix}review-request-changes\",\"at\":\"2026-11-08T10:30:00Z\"}"
conflict='{"stage":"merge-conflict","result":"main moved","at":"2026-11-08T11:00:00Z"}'
sched_conflict="{\"stage\":\"supervisor-requeue\",\"result\":\"${fresh_prefix}merge-conflict\",\"at\":\"2026-11-08T11:30:00Z\"}"
rm -f "$MAC_AUTOPILOT_RUNTIME_DIR/node-health.json"
stop_loss_case issue-4921 "[$rework]" 521 repair-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4921)" == repair-pending ]] || fail "a fresh signal was not requeued in place (calls=$stop_loss_calls stage=$(case_stage issue-4921))"
[[ "$(fresh_events issue-4921 | tail -1)" == "supervisor-requeue ${fresh_prefix}review-request-changes" ]] || fail "the requeue event does not name the signal: $(fresh_events issue-4921)"
[[ "$(case_events issue-4921)" != *supervisor-review* && "$(case_events issue-4921)" != *supervisor-escalated* && "$(case_events issue-4921)" != *supervisor-arbiter* ]] || fail "a fresh signal reached the arbiter: $(case_events issue-4921)"
# Repeated review requests already in the ruling window are not fresh; they use the existing supervisor stop-loss route.
stop_loss_case issue-4934 "[$rework,$rework,$rework]" 534 repair-pending
[[ "$stop_loss_calls" == 1 && "$(fresh_events issue-4934 | grep -c "$fresh_prefix")" == 0 ]] \
  || fail "repeated review requests were requeued as fresh (calls=$stop_loss_calls stage=$(case_stage issue-4934) events=$(case_events issue-4934))"
stop_loss_case issue-4922 "$(red_history 'Pipeline suites' 'Pipeline suites' | jq -c '.[0:1]')" '' implement-pending
[[ "$stop_loss_calls" == 0 && "$(fresh_events issue-4922 | tail -1)" == "supervisor-requeue ${fresh_prefix}self-check-red Pipeline suites" ]] || fail "a first-time red was not requeued with its check named: $(fresh_events issue-4922)"
# Same signal again after the requeue: the same-failure route (park, an open PR is never closed by it), no second requeue and no arbiter.
stop_loss_case issue-4923 "[$rework,$sched_rework,$rework]" 523 repair-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4923)" == parked && "$(jq -r '.units[0].parked_reason' "$UNITS")" == 'stop-loss same failure: review-request-changes' ]] \
  || fail "the same signal after a requeue did not take the same-failure route (calls=$stop_loss_calls stage=$(case_stage issue-4923) $(jq -c '.units[0] | [.parked_reason]' "$UNITS"))"
[[ "$(fresh_events issue-4923 | grep -c "$fresh_prefix")" == 1 ]] || fail "a repeated signal was requeued again: $(fresh_events issue-4923)"
stop_loss_case issue-4924 "$(red_history 'Pipeline suites' 'Pipeline suites' | jq -c --argjson s "{\"stage\":\"supervisor-requeue\",\"result\":\"${fresh_prefix}self-check-red Pipeline suites\",\"at\":\"2026-11-08T10:45:00Z\"}" '.[0:2] + [$s] + .[2:]')" 524 repair-pending
[[ "$stop_loss_calls" == 0 && "$(case_stage issue-4924)" == parked && "$(jq -r '.units[0].parked_reason' "$UNITS")" == 'stop-loss same failure: Pipeline suites' ]] \
  || fail "a red repeating the requeued one did not take the same-failure route (calls=$stop_loss_calls stage=$(case_stage issue-4924))"
# A different fresh signal requeues once more; the third requeue-worthy stop-loss since the ruling goes to the arbiter.
stop_loss_case issue-4925 "[$rework,$sched_rework,$conflict]" 525 repair-pending
[[ "$stop_loss_calls" == 0 && "$(fresh_events issue-4925 | tail -1)" == "supervisor-requeue ${fresh_prefix}merge-conflict" ]] || fail "a different fresh signal was not requeued: $(fresh_events issue-4925)"
stop_loss_case issue-4926 "[$rework,$sched_rework,$conflict,$sched_conflict,{\"stage\":\"ci-test-red\",\"result\":\"Other suite\",\"at\":\"2026-11-08T12:00:00Z\"}]" 526 repair-pending
[[ "$stop_loss_calls" == 1 && "$(fresh_events issue-4926 | grep -c "$fresh_prefix")" == 2 ]] || fail "a third stop-loss was not left to the arbiter (calls=$stop_loss_calls $(fresh_events issue-4926))"
# A real ruling in between starts the count over.
stop_loss_case issue-4927 "[$rework,$sched_rework,$conflict,$sched_conflict,{\"stage\":\"supervisor-requeue\",\"result\":\"arbiter\",\"at\":\"2026-11-08T11:45:00Z\"},$rework]" 527 repair-pending
[[ "$stop_loss_calls" == 0 && "$(fresh_events issue-4927 | tail -1)" == "supervisor-requeue ${fresh_prefix}review-request-changes" ]] || fail "an arbiter ruling did not restart the fresh-requeue count (calls=$stop_loss_calls)"
# A front that is not a fresh signal, and a wall budget, stay with the arbiter.
stop_loss_case issue-4928 '[{"stage":"repair-no-push","result":"head unchanged","at":"2026-11-08T10:00:00Z"}]' 528 repair-pending
[[ "$stop_loss_calls" == 1 && "$(fresh_events issue-4928 | grep -c "$fresh_prefix")" == 0 ]] || fail "a non-fresh front was requeued by the scheduler (calls=$stop_loss_calls)"
ticket_budget_reason() { printf 'wall 300min of 240min after 3 rounds\n'; }
stop_loss_case issue-4929 "[$rework]" 529 repair-pending
[[ "$stop_loss_calls" == 1 && "$(fresh_events issue-4929 | grep -c "$fresh_prefix")" == 0 ]] || fail "a wall-budget stop-loss was requeued by the scheduler (calls=$stop_loss_calls)"
ticket_budget_reason() { printf 'rounds 3 of 3\n'; }
# Delivery rate: under 50% on the scorecard (it is null below 6 outcomes) sends fresh signals back to the arbiter; 50% or null requeues.
fresh_rate() { printf '{"metrics":[{"id":"supervisor.fresh_requeue_delivery_24h","value":%s}]}\n' "$1" > "$MAC_AUTOPILOT_RUNTIME_DIR/node-health.json"; }
fresh_rate 33.3
stop_loss_case issue-4931 "[$rework]" 531 repair-pending
[[ "$stop_loss_calls" == 1 && "$(fresh_events issue-4931 | grep -c "$fresh_prefix")" == 0 ]] || fail "a delivery rate of 33.3% still requeued in the scheduler (calls=$stop_loss_calls)"
fresh_rate 50
stop_loss_case issue-4932 "[$rework]" 532 repair-pending
[[ "$stop_loss_calls" == 0 && "$(fresh_events issue-4932 | grep -c "$fresh_prefix")" == 1 ]] || fail "a delivery rate of 50% did not requeue (calls=$stop_loss_calls)"
fresh_rate null
stop_loss_case issue-4933 "[$rework]" 533 repair-pending
[[ "$stop_loss_calls" == 0 && "$(fresh_events issue-4933 | grep -c "$fresh_prefix")" == 1 ]] || fail "no rate (under 6 outcomes) did not requeue (calls=$stop_loss_calls)"
rm -f "$MAC_AUTOPILOT_RUNTIME_DIR/node-health.json"
unset -f fresh_events fresh_rate
unset -f red_history stop_loss_case case_stage case_events

unset -f red_history stop_loss_case case_stage case_events red_check_history ci_update_branch
echo 'dispatch-census-capacity.test.sh: pass (0 gh calls at 8/8 for refill and full tick; one census at 7/8; CONFLICTING census row repaired not reviewed; refill deadline; silent skip named)'
