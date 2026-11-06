#!/usr/bin/env bash
# Expired and closed holds must leave the sweep: a closed state-only hold, a finish-first stop-loss, and the tail of a cut loop.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
REPO=test/repo

assert_true "an expired stop-loss resumes at finish-first" issue_transition_allowed on-hold finish-first hold-expired
assert_true "conclude still leaves on-hold for finish-first" issue_transition_allowed on-hold finish-first conclude:merged
assert_false "other reasons stay refused for finish-first" issue_transition_allowed on-hold finish-first hold-release
assert_false "hold-expired does not conclude a ticket" issue_transition_allowed on-hold concluded hold-expired

gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "issue view")
      local fields="" previous=""
      for arg in "$@"; do [ "$previous" != --json ] || fields="$arg"; previous="$arg"; done
      jq -cn --arg fields "$fields" '{number:910801,state:"CLOSED",stateReason:"COMPLETED",closedAt:"2026-10-29T06:12:09Z",labels:[{name:"concluded"}],comments:[],title:"t"}
        | with_entries(select(.key as $k | $fields | split(",") | index($k)))' ;;
    *) return 0 ;;
  esac
}
state_merge 910801 '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",expires_at:"2026-10-31T00:00:00Z",stage_before:"ready-for-agent"}' >/dev/null
status=0; hold_sweep 2>"$AGENT_HOME/sweep.err" || status=$?
assert_eq "a closed state-only hold reconciles" 0 "$status"
assert_not_contains "the closed snapshot carries its number" "$(cat "$AGENT_HOME/sweep.err")" 'invalid closed issue snapshot'

# Past the slice deadline every read is refused: the sweep stops and says so, it does not report owners unreadable.
supervisor_holds_snapshot() { jq -cn '[{issue:910802,kind:"external-deliverable",age_seconds:99,owner:"none",holder:"supervisor",hold:{}}]'; }
status=0; ZF_GH_CALL_DEADLINE_EPOCH_MS=$(( $(date +%s%3N) + 3000 )) supervisor_hold_sweep 2>"$AGENT_HOME/sweep.err" || status=$?
assert_eq "a deadline stop is not a sweep failure" 0 "$status"
assert_contains "a deadline stop names where it stopped" "$(cat "$AGENT_HOME/sweep.err")" 'gh deadline reached at #910802'
unset -f supervisor_holds_snapshot
assert_true "the supervisor sweep shuffles too" grep -Fq '<<< "$rows" | shuf)' "$SCRIPT_DIR/supervisor-holds.sh"

assert_true "the sweep shuffles so a deadline cannot starve one tail" grep -Eq 'sort -u \| shuf\)' "$SCRIPT_DIR/lib.d/holds.sh"
assert_true "blocker roots run last in the suffix" grep -Eq 'suffix_steps=\(.*batch-state needs-info-blocker-roots\)' "$SCRIPT_DIR/issue-pipeline.sh"

lib_case_exit
