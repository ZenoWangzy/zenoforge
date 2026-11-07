#!/usr/bin/env bash
# A park with no reason has no exit: every writer names a reason and an unpark condition, and a label never changes who releases a unit.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'park-reason.test.sh: %s\n' "$*" >&2; exit 1; }

# Landing check: a write of stage parked without both fields fails here, which is what makes a reason-less park impossible.
bad="$(grep -rnE '\.stage ?= ?\\?"parked\\?"' "$engine_dir" --include='*.sh' --exclude='*.test.sh' | grep -vE 'park_fields|parked_reason.*unpark_condition|unpark_condition.*parked_reason' || true)"
[[ -z "$bad" ]] || fail "a park write lacks parked_reason and unpark_condition: $bad"

fixture="$test_env_root/park-reason"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; : > "$LOG"
A="$MAC_AUTOPILOT_RUNTIME_DIR"; printf '%s\n' '{"workers":[]}' > "$A/workers.json"
cancel_unit_runs() { :; }
dep_delivered_snapshot() { :; }
DEP_DELIVERED_CACHE=()
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
unit() { jq -cn --arg id "issue-$1" --argjson i "$1" --arg note "$2" '{id:$id,issue:$i,stage:"parked",note:$note,task:"t",branch:("agent/" + $id),history:[]}'; }
ledger() { jq -cs '{units:.}' > "$UNITS"; }
: > "$fixture/recut-calls"
SCHEDULER_AGENT_LIB="$fixture/agent-lib.sh"
printf 'complete_recut_parent() { printf "%%s %%s\\n" "$1" "$2" >> %q; }\n' "$fixture/recut-calls" > "$SCHEDULER_AGENT_LIB"

# park_fields: a named predecessor wins, so delivery still releases the unit.
jq -cn '{units:[{id:"a",stage:"parked",blocked_on:7},{id:"b",stage:"parked"}]}' > "$UNITS"
set_unit a "$(park_fields supervisor-park 'a supervisor decision')"; set_unit b "$(park_fields supervisor-park 'a supervisor decision')"
[[ "$(field a .parked_reason):$(field a .unpark_condition)" == 'waiting-predecessor:#7 delivered' ]] || fail "a predecessor must name the reason: $(field a .parked_reason)"
[[ "$(field b .parked_reason)" == supervisor-park ]] || fail 'no predecessor keeps the given reason'

# Every class, labels only, and a second sweep changes nothing.
{ unit 900 'waits' | jq -c '.blocked_on=70'; unit 901 'supervisor budget exhausted: ticket stop-loss budget: rounds 3 of 3'; unit 902 'supervisor budget exhausted: third entry into supervisor-review; arbitration cap is 2 (#4369)'
  unit 903 'head 11-04: recut into child issues (see issue comment); close'; unit 904 'issue #904 recut is on hold' | jq -c '.size_recut_pending=true'; unit 905 'cap triage could not complete the recut route: x'; unit 906 'anything else'; } | ledger
park_label_sweep
for row in 900:waiting-predecessor 901:ticket-stop-loss 902:preserved-clone-hold 903:recut-children 904:on-hold 905:cap-recut-failed 906:supervisor-park; do
  [[ "$(field "issue-${row%:*}" .parked_reason)" == "${row#*:}" ]] || fail "wrong label for $row: $(field "issue-${row%:*}" .parked_reason)"
  [[ "$(field "issue-${row%:*}" .stage)" == parked && -n "$(field "issue-${row%:*}" '.unpark_condition // empty')" ]] || fail "a label must not move $row"
done
before="$(cat "$UNITS")"; park_label_sweep; [[ "$(cat "$UNITS")" == "$before" ]] || fail 'the sweep must be idempotent'

# G: a labelled unit still releases on delivery. Without the selector change this class strands silently.
NOW_EPOCH="$(date +%s)"
jq -cn --argjson e "$NOW_EPOCH" '{epoch:$e,states:{"70":{state:"CLOSED",labels:""}}}' > "$A/dep-check.cache.json"; printf '%s\n' "$NOW_EPOCH" > "$A/dep-check.epoch"
release_dependency_blocks
[[ "$(field issue-900 .stage)" != parked ]] || fail 'a labelled waiting-predecessor unit must release on delivery'
[[ "$(field issue-901 .stage)" == parked ]] || fail 'a release must not reach an unrelated park'
rm -f "$A/dep-check.cache.json" "$A/dep-check.epoch"

# obsolete_evidence_gate: an OBSOLETE line closes an issue only if it names something checkable on current main.
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.name fixture; git -C "$ROOT" config user.email fixture@example.invalid
printf 'x\n' > "$ROOT/a.ts"; git -C "$ROOT" add a.ts; git -C "$ROOT" commit -qm base
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
main_sha="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
for line in 'OBSOLETE: already handled at a.ts:1' "OBSOLETE: fixed by $main_sha" 'OBSOLETE: measured 0 in https://github.com/o/r/actions/runs/123'; do
  obsolete_evidence_gate "$line" || fail "evidence refused: $line"
done
for line in 'OBSOLETE: nothing to do' 'OBSOLETE: gone from b.ts:1' 'OBSOLETE: fixed by 0123456789ab' \
  'OBSOLETE: no comparable data, see a.ts:1' 'OBSOLETE: 当前 main 的可比窗口没有复测值；旧样本 a.ts:1' 'OBSOLETE: no measurement on main'; do
  ! obsolete_evidence_gate "$line" || fail "no evidence passed: $line"
done
to_supervisor() { set_unit "$1" '.stage="supervisor-review"'; }
: > "$fixture/closes"
gh() { [[ "$1 $2" != 'issue close' ]] || printf '%s\n' "$3" >> "$fixture/closes"; }
unit 909 'x' | jq -c '.stage="implement"' | ledger
obsolete_unit_close issue-909 909 'OBSOLETE: nothing to do'
[[ "$(field issue-909 .stage)" == supervisor-review && ! -s "$fixture/closes" ]] || fail 'a line with no evidence must go to review, not close'

# A failed issue close keeps the unit out of closed; a closed unit under an open issue is skipped by intake for good.
rm -f "$fixture/close-fails"
gh() { if [[ "$1 $2" == 'issue close' ]]; then printf '%s\n' "$3" >> "$fixture/closes"; [[ ! -f "$fixture/close-fails" ]]; fi; }
touch "$fixture/close-fails"
unit 910 'x' | jq -c '.stage="implement"' | ledger
obsolete_unit_close issue-910 910 'OBSOLETE: handled at a.ts:1'
[[ "$(field issue-910 .stage):$(field issue-910 .parked_reason)" == parked:obsolete-close-failed ]] || fail 'a failed close must park the unit'
obsolete_close_retry
[[ "$(field issue-910 .stage)" == parked ]] || fail 'a retry that fails must stay parked'
rm -f "$fixture/close-fails"
obsolete_close_retry
[[ "$(field issue-910 .stage)" == closed && "$(field issue-910 '.parked_reason // "none"')" == none ]] || fail 'a retry that works must close the unit'
[[ "$(field issue-910 '[.history[] | select(.stage=="obsolete")] | length')" == 1 ]] || fail 'the close must keep the report line'
[[ "$(wc -l < "$fixture/closes")" == 3 ]] || fail 'expected one first close and two retries'
unit 911 'x' | jq -c '.stage="implement"' | ledger
obsolete_unit_close issue-911 911 'OBSOLETE: handled at a.ts:1'
[[ "$(field issue-911 .stage)" == closed ]] || fail 'a close that works must close the unit'

# A branch holding changes at the end of the same run contradicts "no change needed"; an older run's files do not.
unit 912 'x' | jq -c '.stage="implement" | .history=[{stage:"write-start",result:"[]"},{stage:"write-end",result:"[\"a.ts\"]"}]' | ledger
obsolete_unit_close issue-912 912 'OBSOLETE: handled at a.ts:1'
[[ "$(field issue-912 .stage)" == supervisor-review ]] && ! grep -qx 912 "$fixture/closes" || fail 'a run that left changes must not close the issue'
unit 913 'x' | jq -c '.stage="implement" | .history=[{stage:"write-end",result:"[\"a.ts\"]"},{stage:"write-start",result:"[]"}]' | ledger
obsolete_unit_close issue-913 913 'OBSOLETE: handled at a.ts:1'
[[ "$(field issue-913 .stage)" == closed ]] || fail 'an older run must not refuse this close'
unit 914 'x' | jq -c '.stage="implement" | .history=[{stage:"write-start",result:"[]"},{stage:"write-end",result:"[]"}]' | ledger
obsolete_unit_close issue-914 914 'OBSOLETE: handled at a.ts:1'
[[ "$(field issue-914 .stage)" == closed ]] || fail 'an empty write-end must not refuse this close'
unset -f gh

# NEEDS-DIRECT moves the lane once, and never under an open PR.
unit 915 'x' | jq -c '.stage="implement" | .lane="pr" | .task="t"' | ledger
needs_direct_route issue-915 'NEEDS-DIRECT: only docs changed'
[[ "$(field issue-915 .stage):$(field issue-915 .lane)" == implement-pending:direct-main && "$(field issue-915 .task)" == *'only docs changed'* ]] || fail 'NEEDS-DIRECT must rerun on the direct-main lane'
set_unit issue-915 '.stage="implement"'; needs_direct_route issue-915 'NEEDS-DIRECT: again'
[[ "$(field issue-915 .stage)" == supervisor-review ]] || fail 'a second NEEDS-DIRECT must go to the supervisor'
unit 916 'x' | jq -c '.stage="implement" | .lane="pr" | .pr=77' | ledger
needs_direct_route issue-916 'NEEDS-DIRECT: only docs changed'
[[ "$(field issue-916 .stage):$(field issue-916 .lane)" == supervisor-review:pr ]] || fail 'a unit with a PR must not change lane on a report'

# Rulings move one unit per sweep, each once.
to_supervisor() { set_unit "$1" '.stage="supervisor-review"'; }
{ unit 3015 'supervisor budget exhausted: third entry into supervisor-review; arbitration cap is 2 (#4369)' | jq -c '.pr=4693 | .hold_handoff_waiting=true | .hold_handoff_wait_issues=[3015]'
  unit 4402 'supervisor budget exhausted: third entry into supervisor-review; arbitration cap is 2 (#4369)' | jq -c '.hold_handoff_waiting=true'
  unit 4247 'head 11-04: PARKED — its run-release test work' | jq -c '.pr=5285'
  unit 5171 'supervisor budget exhausted: ticket stop-loss budget: wall 249min of 240min after 1 rounds'; unit 1207 'supervisor budget exhausted: ticket stop-loss budget: rounds 3 of 3'
  unit 4508 'head 11-04: recut into child issues (see issue comment); close'; } | ledger
park_label_sweep
[[ "$(field issue-3015 .stage):$(field issue-3015 .parked_reason):$(field issue-3015 .hold_handoff_waiting)" == supervisor-review:null:null && "$(field issue-4247 .stage)" == parked ]] || fail 'the first sweep must return 3015 to its path with no parked_reason, and move only 3015'
[[ "$(field issue-3015 '[.history[] | select(.stage == "park-sweep-resume")] | length')" == 1 ]] || fail 'the hold release must add exactly one history entry'
[[ "$(field issue-4402 .parked_reason):$(field issue-4402 .hold_handoff_waiting)" == preserved-clone-hold:true ]] || fail '4402 stays held'
park_label_sweep
[[ "$(field issue-4247 .stage):$(field issue-4247 .parked_reason)" == repair-pending:null && "$(field issue-5171 .stage)" == parked ]] || fail 'the second sweep must move only 4247'
park_label_sweep
[[ "$(field issue-5171 .stage)" == supervisor-review && "$(field issue-1207 .stage)" == parked ]] || fail 'a wall-alone unit resumes and a rounds unit stays'
set_unit issue-5171 '.stage="parked"'
park_label_sweep
[[ "$(field issue-5171 .stage)" == parked ]] || fail 'a unit resumes once'
[[ "$(cat "$fixture/recut-calls")" == '4508 [5315,5331]' ]] || fail "the confirmed children must reach complete_recut_parent: $(cat "$fixture/recut-calls")"
[[ "$(field issue-4508 .stage):$(field issue-4508 .parked_reason)" == parked:recut-children ]] || fail 'a recut parent stays parked until its issue closes'
park_label_sweep
[[ "$(wc -l < "$fixture/recut-calls")" == 1 ]] || fail 'the recut record must run once'
grep -q 'park-sweep unit=issue-4508 action=children' "$A/alerts/events.md" || fail 'each action must print'
# A cap-triage founder park returns once its stop-loss hold is gone, and only then: a live hold, another reason, a spent retry or a pending handoff episode keep the park.
mkdir -p "$AGENT_HOME/state"
issue_state() { printf '%s\n' "$2" > "$AGENT_HOME/state/$1.json"; }
founder() { unit "$1" 'founder decision required' | jq -c --arg reason "${2:-supervisor-cap-founder}" '.parked_reason=$reason | .unpark_condition="the maintainer answers the question"'; }
{ founder 7001; founder 7002; founder 7003; founder 7004 supervisor-cap-exhausted; founder 7005 | jq -c '.supervisor_cap_retry="spent"'; founder 7006 | jq -c '.hold_handoff_episode="old"'; } | ledger
issue_state 7001 '{"state":"ready-for-agent","hold":null}'
issue_state 7002 '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss","kind":"stop-loss"}}'
issue_state 7004 '{"state":"ready-for-agent","hold":null}'
issue_state 7005 '{"state":"ready-for-agent","hold":null}'
issue_state 7006 '{"state":"ready-for-agent","hold":null,"scheduler_handoff":{"episode":"new"}}'
park_label_sweep
[[ "$(field issue-7001 .stage):$(field issue-7001 .parked_reason):$(field issue-7001 .supervisor_cap_retry)" == supervisor-review:null:pending ]] || fail 'a lifted stop-loss hold must return the founder park with one retry'
for n in 7002 7003 7004 7005 7006; do [[ "$(field issue-$n .stage)" == parked ]] || fail "issue-$n must stay parked"; done
[[ "$(field issue-7001 '[.history[] | select(.stage == "park-sweep-hold-lifted")] | length')" == 1 ]] || fail 'the return must add exactly one history entry'

echo 'park-reason.test.sh: PASS'
