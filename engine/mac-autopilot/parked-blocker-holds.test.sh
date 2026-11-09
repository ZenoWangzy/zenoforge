#!/usr/bin/env bash
# A parked blocker never releases its dependents (2026-11-08: five units ran against prerequisites that never shipped and every review
# returned INPUT_INCOMPLETE). It is escalated with the dependents it holds counted on it, and a unit the old rule already released
# goes back to waiting while it has no PR. The sweep is idempotent: no marker, the ledger decides every tick.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'parked-blocker-holds.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/parked-blocker-holds"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; A="$MAC_AUTOPILOT_RUNTIME_DIR"; : > "$LOG"
STAMP=2026-11-08T10:47:12Z; NOW_EPOCH=1794221232
cancel_unit_runs() { :; }
tick_prs() { printf '[]'; }
scheduler_issue_state() { printf '{"state":"ready-for-agent"}'; }
dep_states() { :; } # no GitHub state for any blocker: only the ledger decides
gh() { return 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
unit() { jq -cn --arg id "$1" --argjson issue "$2" --arg stage "$3" '{id:$id,issue:$issue,stage:$stage,task:"t",branch:"agent/issue-\($issue)",history:[]}' | jq -c "${4:-.}"; }
load() { printf '%s\n' "$@" | jq -cs '{units: .}' > "$UNITS"; echo '{"workers":[]}' > "$A/workers.json"; DEP_DELIVERED_CACHE=(); rm -f "$A/dep-check.epoch" "$A/dep-check.cache.json"; }
released='[{stage:"unblocked",result:"stopped waiting on #10: blocker is parked or waits on a parked unit"}]'

# 1. A dependent of a parked blocker (and a dependent of that dependent) stays blocked across a tick; the blocker is escalated with the count.
load "$(unit issue-10 10 parked '.parked_reason="supervisor-park"')" \
  "$(unit issue-20 20 blocked-external '.blocked_on=10 | .body_blocked_by=[10]')" \
  "$(unit issue-30 30 blocked-external '.blocked_on=20 | .body_blocked_by=[20]')"
release_dependency_blocks || :
[[ "$(field issue-20 .stage):$(field issue-30 .stage)" == blocked-external:blocked-external ]] || fail "a parked blocker released its dependents: $(field issue-20 .stage) $(field issue-30 .stage)"
[[ "$(field issue-20 '.history | length'):$(field issue-20 .blocked_on)" == 0:10 ]] || fail 'the dependent must keep waiting on #10 with no new history'
[[ "$(field issue-10 .held_dependents)" == 2 ]] || fail "the blocker must carry its dependents count, got $(field issue-10 .held_dependents)"
[[ "$(field issue-10 .stage)" == supervisor-review && "$(field issue-10 .note)" == "parked blocker holds 2 dependents"* ]] || fail "the blocker must reach the supervisor with the count: $(field issue-10 .stage) $(field issue-10 .note)"
sum="$(cksum < "$UNITS")"; release_dependency_blocks || :
[[ "$(cksum < "$UNITS")" == "$sum" ]] || fail 'a second tick must change nothing: the escalation is not repeated'

# 2. A unit the old rule released is blocked again while it has no PR, and counted; units with work in review or merged are left alone.
load "$(unit issue-10 10 parked '.parked_reason="supervisor-cap-founder"')" \
  "$(unit issue-21 21 implement-pending ".history=$released | .task=\"t\n\nScheduler note: predecessor #10 is parked or can never deliver (blocker is parked or waits on a parked unit), so this unit no longer waits for it. Do not report BLOCKED-ON #10. Implement what you can; if the dependency is real in code, say so in the report and let review decide.\"")" \
  "$(unit issue-22 22 merged ".history=$released | .pr=52")" \
  "$(unit issue-23 23 review-pending ".history=$released | .pr=53")" \
  "$(unit issue-24 24 implement-pending ".history=$released | .history += [{stage:\"unblocked\",result:\"#10 delivered\"}]")" \
  "$(unit issue-11 11 merged)" \
  "$(unit issue-25 25 implement-pending '.history=[{stage:"unblocked",result:"stopped waiting on #11: blocker is parked or waits on a parked unit"}]')"
dep_delivered_snapshot
dep_hold_parked
[[ "$(field issue-21 .stage):$(field issue-21 .blocked_on)" == blocked-external:10 ]] || fail "a released pre-PR unit must wait on #10 again: $(field issue-21 .stage)"
[[ "$(field issue-21 .task)" == t ]] || fail "the stale 'no longer waits' note must leave the task: $(field issue-21 .task)"
[[ "$(field issue-10 .held_dependents)" == 1 ]] || fail "the blocker must count the re-blocked unit, got $(field issue-10 .held_dependents)"
[[ "$(field issue-10 .stage)" == parked ]] || fail 'a cap-founder park is already the arbiter'"'"'s: no second escalation'
[[ "$(field issue-22 .stage)" == merged && "$(field issue-23 .stage)" == review-pending ]] || fail 'a unit with a merged PR or a PR in review is left alone'
[[ "$(field issue-24 .stage)" == implement-pending ]] || fail 'a later release by another route ends the claim'
[[ "$(field issue-25 .stage)" == implement-pending ]] || fail 'a delivered blocker is not waited on again'
sum="$(cksum < "$UNITS")"; dep_hold_parked
[[ "$(cksum < "$UNITS")" == "$sum" ]] || fail 'a second sweep must change nothing'
echo 'parked-blocker-holds.test.sh: ok'
