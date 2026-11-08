#!/usr/bin/env bash
# A repair run that leaves the PR head unchanged is written repair-no-push at harvest, never repair-delivered
# (2026-11-07, PR 5690: a run that stopped before its push was billed as a delivered repair, and conflict triage
# re-flagged the same head before the no-push check at review dispatch could run).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/repair-no-change"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

fail() { printf 'repair-no-change.test.sh: %s\n' "$*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
alive() { return 1; }
tick_prs_changed() { :; }
tick_prs_prime() { :; }
size_admission_recheck() { :; }
pr_view() { return 1; }

# A bare origin with an agent branch, and the worker's clone of it.
git init -q --bare -b main "$fixture/origin.git"
git clone -q "$fixture/origin.git" "$fixture/wt" 2>/dev/null
git -C "$fixture/wt" checkout -q -b main 2>/dev/null || true
echo base > "$fixture/wt/f.txt"; git -C "$fixture/wt" add -A; git -C "$fixture/wt" commit -qm base
git -C "$fixture/wt" push -q origin main
git -C "$fixture/wt" checkout -q -b agent/issue-9
echo one >> "$fixture/wt/f.txt"; git -C "$fixture/wt" commit -qam one
git -C "$fixture/wt" push -q origin agent/issue-9
H1="$(git -C "$fixture/wt" rev-parse HEAD)"
echo two >> "$fixture/wt/f.txt"; git -C "$fixture/wt" commit -qam two
H2="$(git -C "$fixture/wt" rev-parse HEAD)"   # local only until a case pushes it
git -C "$fixture/wt" reset -q --hard "$H1"
printf 'repair report\n' > "$sup/repair-9.md"

# Run one finished repair worker for unit "issue-9": base = the head the run started from, history = the unit's prior events.
run_repair() { # base-head-or-empty history-json [extra unit fields json] [workdir, default the clone]
  local ws='{"stage":"write-start","work_type":"repair","at":"2026-11-07T10:00:00Z"'
  [[ -z "$1" ]] || ws+=",\"pr_head\":\"$1\""
  jq -n --argjson h "$2" --argjson ws "$ws}" --argjson extra "${3:-{\}}" \
    '{units:[({id:"issue-9",issue:9,pr:9,lane:"pr",branch:"agent/issue-9",stage:"repair",history:($h + [$ws])} + $extra)]}' > "$UNITS"
  jq -n --arg dir "${4-$fixture/wt}" '{workers:[{pid:4242,unit:"issue-9",type:"repair",log:"none.log",report:"repair-9.md",workdir:$dir}]}' > "$WORKERS"
  harvest_workers || true
}
nopush_hist() { jq -cn --arg h "$1" --argjson n "$2" '[range($n) | {stage:"repair-no-push",result:("head "+$h+" unchanged after repair")}]'; }

# 1. Head unchanged, nothing expected: repair-no-push with the exact result text the readers parse, no repair-delivered, retry.
run_repair "$H1" '[{"stage":"review-request-changes","result":"'"$H1"'"}]' '{"repair_hint":"keep me"}'
[[ "$(field issue-9 '.history[-1].stage')" == repair-no-push ]] || fail "unchanged head was not recorded repair-no-push ($(field issue-9 '.history[-1].stage'))"
[[ "$(field issue-9 '.history[-1].result')" == "head $H1 unchanged after repair" ]] || fail 'no-push result text changed; stop-loss and the arbiter parse it'
[[ "$(field issue-9 '[.history[] | select(.stage=="repair-delivered")] | length')" == 0 ]] || fail 'unchanged head still wrote repair-delivered'
[[ "$(field issue-9 .stage)" == repair-pending && "$(field issue-9 .repair_hint)" == "keep me" ]] || fail "first no-push must retry the repair and keep its hint ($(field issue-9 .stage))"
[[ "$(field issue-9 '.history[-1].head_class')" == unchanged ]] || fail 'no-push event is not classified for the dashboard row'

# 2. Second unchanged run on the same head (one no-push already): the circuit breaker parks the unit instead of a third repair.
SCHEDULER_AGENT_LIB="$fixture/agent-lib.sh"; printf '%s\n' 'supervisor_inbox_append_once() { :; }' > "$SCHEDULER_AGENT_LIB"
run_repair "$H1" "$(jq -cn --argjson n "$(nopush_hist "$H1" 1)" '[{stage:"review-request-changes",result:"'"$H1"'"}] + $n')"
[[ "$(field issue-9 .stage)" == parked && "$(field issue-9 '.history[-2].stage')" == repair-no-push && "$(field issue-9 '.history[-1].stage')" == repair-breaker ]] \
  || fail "a second unchanged run must park the unit ($(field issue-9 .stage))"

# 3. The run pushed a new head: delivered, classified changed, fresh tokens recorded.
git -C "$fixture/wt" reset -q --hard "$H2"; git -C "$fixture/wt" push -q origin agent/issue-9
run_repair "$H1" '[{"stage":"review-request-changes","result":"'"$H1"'"}]'
[[ "$(field issue-9 '.history[-1].stage')" == repair-delivered && "$(field issue-9 '.history[-1].head_class')" == changed && "$(field issue-9 .stage)" == rereview-pending ]] \
  || fail "a run that moved the head was not delivered ($(field issue-9 '.history[-1] | tojson'))"

# 4. Unchanged but expected: an approved head whose CI went red after the approval stays delivered (the scheduler reruns the CI).
run_repair "$H2" '[{"stage":"review-approve","result":"'"$H2"'"},{"stage":"ci-red","result":"external CI failure"}]'
[[ "$(field issue-9 '.history[-1].stage')" == repair-delivered && "$(field issue-9 '.history[-1].head_class')" == unchanged-expected ]] \
  || fail "an unchanged head after a CI red on the approved head must stay delivered and be marked expected ($(field issue-9 '.history[-1] | tojson'))"

# 5. Unchanged but expected: the round's findings record is verified empty.
run_repair "$H2" '[{"stage":"review-request-changes","result":"'"$H2"'"}]' '{"review_findings":[{"round":1,"block":"ok","findings":[],"all_findings":[]}]}'
[[ "$(field issue-9 '.history[-1].stage')" == repair-delivered && "$(field issue-9 '.history[-1].head_class')" == unchanged-expected ]] \
  || fail "a verified-empty round must not be treated as a failed repair ($(field issue-9 '.history[-1] | tojson'))"
# The same head with an actionable finding is a failed repair.
run_repair "$H2" '[{"stage":"review-request-changes","result":"'"$H2"'"}]' '{"review_findings":[{"round":1,"block":"ok","findings":[{"id":"F1","severity":"P1","status":"open"}],"all_findings":[{"id":"F1","severity":"P1","status":"open"}]}]}'
[[ "$(field issue-9 '.history[-1].stage')" == repair-no-push ]] || fail 'an actionable finding with an unchanged head must be repair-no-push'

# 6. No recorded start head (run started before the detector, or no PR): not classified, behaves as before.
run_repair "" '[{"stage":"review-request-changes","result":"'"$H2"'"}]'
[[ "$(field issue-9 '.history[-1].stage')" == repair-delivered && "$(field issue-9 '.history[-1].head_class')" == unknown ]] \
  || fail "an unclassifiable run must stay delivered and be marked unknown ($(field issue-9 '.history[-1] | tojson'))"

# 7. The confirmed no-push now arrives without a repair-delivered before it: the arbiter still reads it as a confirmed no-push.
units_json="$(jq -cn --arg h "$H1" '{id:"issue-9",reviewed_sha:$h,reviewed_pr_head:$h,review_findings:[{round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[]}],
  history:[{stage:"review-request-changes",result:$h},{stage:"write-start",work_type:"repair"},{stage:"repair-no-push",result:("head "+$h+" unchanged after repair")}]}')"
supervisor_requeue_rereview "$units_json" || fail 'a harvest-written repair-no-push was not read as a confirmed no-push'

# 8. Dispatch records the head a repair starts from on its write-start; implement runs and PR-less units record none.
room_for() { return 0; }; size_admission_write_start() { return 0; }; dispatch() { return 0; }; refill_stopped() { return 1; }
footprint_merge_changed_owners() { :; }; tick_pr_head() { printf '%s\n' "$H1"; }
printf '%s\n' '{"units":[{"id":"issue-9","issue":9,"pr":9,"lane":"pr","branch":"agent/issue-9","stage":"repair-pending","history":[]},{"id":"issue-8","issue":8,"lane":"pr","branch":"agent/issue-8","stage":"repair-pending","history":[]}]}' > "$UNITS"
dispatch_if_room issue-9 repair repair r.log r.md GPT-5 high "prompt" "" "$fixture/wt" "" "" "" false codex false configured codex || fail 'repair dispatch failed'
[[ "$(field issue-9 '[.history[] | select(.stage=="write-start")][0].pr_head')" == "$H1" ]] || fail "repair write-start lacks the starting PR head ($(field issue-9 '.history | tojson'))"
dispatch_if_room issue-9 implement implement r.log r.md GPT-5 high "prompt" "" "$fixture/wt" "" "" "" false codex false configured codex || fail 'implement dispatch failed'
[[ "$(field issue-9 '[.history[] | select(.stage=="write-start" and .work_type=="implement")][0].pr_head // "none"')" == none ]] || fail 'an implement run recorded a repair start head'
dispatch_if_room issue-8 repair repair r.log r.md GPT-5 high "prompt" "" "$fixture/wt" "" "" "" false codex false configured codex || fail 'PR-less repair dispatch failed'
[[ "$(field issue-8 '.history[0].pr_head // "none"')" == none ]] || fail 'a PR-less repair recorded a start head'

# 9. A repair that pushed an over-limit head is recut, not escalated to the supervisor (the harvest passes the repaired head to the recheck).
source "$script_dir/scheduler.d/size-admission.sh"   # restore the real recheck over this file's no-op stub
size_admission_exempt_unit() { return 1; }; changed_lines_of() { echo 900; }; changed_files_of() { echo '[]'; }
size_admission_limit_for() { echo 800; }; gh() { return 1; }
scheduler_size_recut() { echo "recut issue=$1 lines=$2 unit=$4" >> "$fixture/recut-calls"; return 0; }
to_supervisor() { echo "supervisor $1" >> "$fixture/recut-calls"; }
rm -f "$fixture/recut-calls"
run_repair "$H1" '[{"stage":"review-request-changes","result":"'"$H1"'"}]'
[[ "$(field issue-9 '[.history[] | select(.stage=="size-recut")] | length')" == 1 && "$(field issue-9 .stage)" == blocked-external ]] \
  || fail "an over-limit repaired head must route to recut ($(field issue-9 '.history | tojson'))"
grep -q '^recut issue=9 lines=900 unit=issue-9$' "$fixture/recut-calls" && ! grep -q '^supervisor' "$fixture/recut-calls" \
  || fail "an over-limit repaired head escalated instead of recutting ($(cat "$fixture/recut-calls" 2>/dev/null))"
# 10. A recheck with no head says so in the scheduler log instead of skipping the recut silently.
rm -f "$fixture/recut-calls"; : > "$LOG"
size_admission_recheck issue-9 "$fixture/wt" agent/issue-9 "ctx-nohead" || true
grep -qx '\[.*\] size recheck without head: issue-9 ctx-nohead' "$LOG" || fail "a headless recheck left no scheduler.log line ($(cat "$LOG"))"
# 11. An empty workdir gives no head, so no recut is routed; the log line records the skipped recheck.
rm -f "$fixture/recut-calls"; : > "$LOG"
run_repair "$H1" '[{"stage":"review-request-changes","result":"'"$H1"'"}]' '{}' ""
[[ "$(field issue-9 '[.history[] | select(.stage=="size-recut")] | length')" == 0 && ! -e "$fixture/recut-calls" ]] \
  || fail "an empty workdir must not route a recut ($(cat "$fixture/recut-calls" 2>/dev/null))"
grep -q 'size recheck without head: issue-9 on agent/issue-9 after repair' "$LOG" || fail "an empty workdir left no scheduler.log line ($(cat "$LOG"))"

echo 'repair-no-change.test.sh: ok'
