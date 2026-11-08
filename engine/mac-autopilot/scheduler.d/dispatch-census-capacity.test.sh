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
# A fresh failure, a different red kind, a ruling between the reds, or a cap default already given: the supervisor as before.
stop_loss_case issue-4914 "$(red_history "$same_a" 'self-check failed at 77be0e3a: 15 tests, 1 failed (lib/other)')" 140 repair-pending
[[ "$stop_loss_calls" == 1 && "$(case_events issue-4914)" != *supervisor-cap-default* ]] || fail "a fresh failure skipped the supervisor (calls=$stop_loss_calls)"
stop_loss_case issue-4915 "$(red_history "$same_a" "$same_b" '[]' | jq -c '.[0:2] + [{stage:"supervisor-requeue",at:"2026-11-08T10:45:00Z"}] + .[2:]')" 150 repair-pending
[[ "$stop_loss_calls" == 1 ]] || fail "a red from before a ruling counted as an earlier round (calls=$stop_loss_calls)"
stop_loss_case issue-4916 "$(red_history "$same_a" "$same_b" '[{"stage":"supervisor-cap-default","result":"branch=park: earlier","at":"2026-11-07T10:00:00Z"}]')" 160 repair-pending
[[ "$stop_loss_calls" == 1 && "$(case_stage issue-4916)" == repair-pending ]] || fail "a unit that already had its cap default must still go to the supervisor (calls=$stop_loss_calls)"
unset -f red_history stop_loss_case case_stage case_events

echo 'dispatch-census-capacity.test.sh: pass (0 gh calls at 8/8 for refill and full tick; one census at 7/8; CONFLICTING census row repaired not reviewed; refill deadline; silent skip named)'
