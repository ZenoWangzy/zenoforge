#!/usr/bin/env bash
# Repair stop-loss (issue-5573, 2026-11-08): a report-only round is unchanged-expected, two same-head no-push repairs trip the
# breaker, and a repair that needs Dagger is refused on a host whose container runtime probe fails.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/repair-breaker"
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

fail() { printf 'repair-breaker.test.sh: %s\n' "$*" >&2; exit 1; }
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
run_repair() { # base-head-or-empty history-json [extra unit fields json]
  local ws='{"stage":"write-start","work_type":"repair","at":"2026-11-07T10:00:00Z"'
  [[ -z "$1" ]] || ws+=",\"pr_head\":\"$1\""
  jq -n --argjson h "$2" --argjson ws "$ws}" --argjson extra "${3:-{\}}" \
    '{units:[({id:"issue-9",issue:9,pr:9,lane:"pr",branch:"agent/issue-9",stage:"repair",history:($h + [$ws])} + $extra)]}' > "$UNITS"
  jq -n --arg dir "$fixture/wt" '{workers:[{pid:4242,unit:"issue-9",type:"repair",log:"none.log",report:"repair-9.md",workdir:$dir}]}' > "$WORKERS"
  harvest_workers || true
}
nopush_hist() { jq -cn --arg h "$1" --argjson n "$2" '[range($n) | {stage:"repair-no-push",result:("head "+$h+" unchanged after repair")}]'; }

INBOX="$fixture/inbox"; : > "$INBOX"
SCHEDULER_AGENT_LIB="$fixture/agent-lib.sh"
{
  printf '%s\n' 'supervisor_inbox_append_once() { grep -Fqx "$1" "'"$INBOX"'.keys" 2>/dev/null || { echo "$1" >> "'"$INBOX"'.keys"; echo "$2" >> "'"$INBOX"'"; }; }'
  printf '%s\n' 'env_fault_probe() { [[ "$1" == env:test-gate:docker ]] && return "$(cat "'"$fixture"'/probe-rc")"; return 2; }'
} > "$SCHEDULER_AGENT_LIB"
cancel_unit_runs() { :; }
decision_eval_stages() { printf '\n'; }
printf '%s\n' 'repair report' '本机 Dagger 因缺少容器运行时无法启动' '' '```review-findings' '{"findings":[],"dispositions":[]}' '```' > "$sup/repair-9.md"
rf() { jq -cn --arg f "$1" '{review_findings:[{round:1,block:"ok",findings:[{id:"F1",severity:"P1",file:$f,status:"open"}],all_findings:[{id:"F1",severity:"P1",file:$f,status:"open"}]}]}'; }
RC='[{"stage":"review-request-changes","result":"'"$H1"'"}]'

# 1. Report-only round: every blocking finding names the PR body or the delivery report, so an unchanged head is expected.
for f in '(PR #5618 body)' 'PR #4888 implementer report' 'delivery report'; do
  run_repair "$H1" "$RC" "$(rf "$f")"
  [[ "$(field issue-9 '.history[-1].stage')" == repair-delivered && "$(field issue-9 '.history[-1].head_class')" == unchanged-expected ]] \
    || fail "report-only finding \"$f\" must be unchanged-expected ($(field issue-9 '.history[-1] | tojson'))"
done
# A repo path, even one that mentions a report, and a mixed round stay waste.
for f in 'scripts/incident-report-guard.mjs' 'docs/delivery-report.md'; do
  run_repair "$H1" "$RC" "$(rf "$f")"
  [[ "$(field issue-9 '.history[-1].stage')" == repair-no-push ]] || fail "code finding \"$f\" must stay repair-no-push"
done
run_repair "$H1" "$RC" "$(jq -cn '{review_findings:[{round:1,block:"ok",findings:[{id:"F1",severity:"P1",file:"(PR #1 body)",status:"open"},{id:"F2",severity:"P1",file:"src/a.ts",status:"open"}],all_findings:[]}]}')"
[[ "$(field issue-9 '.history[-1].stage')" == repair-no-push ]] || fail 'a round with one code finding must stay repair-no-push'

# 2. Breaker: the second consecutive same-head no-push parks the unit; one inbox entry; a delivered run in between resets the count.
run_repair "$H1" "$RC"
[[ "$(field issue-9 .stage)" == repair-pending && "$(field issue-9 '.history[-1].stage')" == repair-no-push ]] || fail "first no-push must retry ($(field issue-9 .stage))"
run_repair "$H1" "$(jq -cn --argjson n "$(nopush_hist "$H1" 1)" --argjson rc "$RC" '$rc + $n')"
[[ "$(field issue-9 .stage)" == parked && "$(field issue-9 .parked_reason)" == repair-breaker ]] || fail "second same-head no-push must park ($(field issue-9 .stage))"
res="$(field issue-9 '.history[-1].result')"
[[ "$(field issue-9 '.history[-1].stage')" == repair-breaker && "$res" == *"head $H1"* && "$res" == *"2 consecutive"* && "$res" == *"本机 Dagger 因缺少容器运行时无法启动"* ]] \
  || fail "breaker event lacks head, count or evidence ($res)"
[[ "$(wc -l < "$INBOX")" == 1 && "$(cat "$INBOX")" == *"repair-breaker unit=issue-9"* ]] || fail "expected one inbox entry ($(cat "$INBOX"))"
run_repair "$H1" "$(jq -cn --arg h "$H1" --argjson rc "$RC" '$rc + [{stage:"repair-no-push",result:("head "+$h+" unchanged after repair")},{stage:"repair-delivered",result:"x"}]')"
[[ "$(field issue-9 .stage)" == repair-pending ]] || fail "a delivered run between must reset the count ($(field issue-9 .stage))"

# 3. Admission: a package repair on a host with no container runtime still runs (PR CI runs the Dagger gate); logged and counted once per hold.
missing() { grep -c 'repair-runtime-missing unit=issue-9' "$LOG" || true; }
units_with() { jq -cn --argjson fp "$1" '{units:[{id:"issue-9",issue:9,pr:9,lane:"pr",stage:"repair-pending",footprint:$fp,history:[]}]}' > "$UNITS"; }
admit() { TICK_CONTAINER_RUNTIME=""; repair_runtime_admission issue-9 "$(jq -c '.units[0]' "$UNITS")"; }
: > "$LOG"; echo 1 > "$fixture/probe-rc"; units_with '["packages/a/src/x.ts"]'
admit || fail 'a package repair must still be admitted when the runtime probe fails'
admit || fail 'a second tick must still admit'
[[ "$(missing)" == 1 && "$(jq -r '.admission_refusals["repair-no-container-runtime"]' "$UNITS")" == 1 && "$(field issue-9 .repair_runtime_refused)" == true ]] \
  || fail "a missing runtime must be logged and counted once per hold ($(missing), $(jq -c .admission_refusals "$UNITS"))"
echo 127 > "$fixture/probe-rc"; admit || fail 'docker missing (127) must admit'
echo 0 > "$fixture/probe-rc"; admit || fail 'a ready runtime must admit'
[[ "$(field issue-9 '.repair_runtime_refused // false')" == false ]] || fail 'the hold flag must clear when the runtime is back'
echo 2 > "$fixture/probe-rc"; admit || fail 'an unknown probe result must admit'
echo 1 > "$fixture/probe-rc"; units_with '["docs/a.md"]'; admit || fail 'a docs-only repair needs no container runtime'
# room_for: a no-runtime host still dispatches the repair (no repair-runtime skip).
units_with '["packages/a/x.ts"]'; repair_cap_admission() { return 0; }; TICK_CONTAINER_RUNTIME=""; echo 1 > "$fixture/probe-rc"
room_for issue-9 repair || fail 'room_for must admit the repair on a host with no container runtime'
[[ "${TICK_DISPATCH_SKIPS[repair-runtime]:-0}" == 0 ]] || fail 'no repair-runtime skip may be counted'

echo 'repair-breaker.test.sh: ok'
