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

gh() { # REST only: issue_rest_view reads the issue, then its comments (slurped pages)
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "api "*)
      case "${*: -1}" in
        */comments\?*) echo '[[]]' ;;
        */issues/910801) jq -cn '{number:910801,state:"closed",state_reason:"completed",closed_at:"2026-10-29T06:12:09Z",labels:[{name:"concluded"}],title:"t",body:""}' ;;
        *) return 1 ;;
      esac ;;
    *) return 0 ;;
  esac
}
state_merge 910801 '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",expires_at:"2026-10-31T00:00:00Z",stage_before:"ready-for-agent"}' >/dev/null
status=0; hold_sweep 2>"$AGENT_HOME/sweep.err" || status=$?
assert_eq "a closed state-only hold reconciles" 0 "$status"
assert_not_contains "the closed snapshot carries its number" "$(cat "$AGENT_HOME/sweep.err")" 'invalid closed issue snapshot'

# An unreadable state-only hold is left on hold: the sweep reports failure and writes nothing for it.
state_merge 910803 '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",expires_at:"2026-10-31T00:00:00Z",stage_before:"ready-for-agent"}' >/dev/null
gh() { case "$1 $2" in "issue list") echo '[]' ;; *) return 1 ;; esac; }
status=0; hold_sweep 2>"$AGENT_HOME/sweep.err" || status=$?
assert_eq "an unreadable state-only hold fails the sweep" 1 "$status"
assert_contains "the unreadable hold is reported" "$(cat "$AGENT_HOME/sweep.err")" 'could not inspect state-only held #910803; leaving state untouched'
assert_eq "an unreadable state-only hold stays on-hold" on-hold "$(jq -r .state "$AGENT_HOME/state/910803.json")"
rm -f "$AGENT_HOME/state/910803.json"

# Past the slice deadline every read is refused: the sweep stops and says so, it does not report owners unreadable.
supervisor_holds_snapshot() { jq -cn '[{issue:910802,kind:"external-deliverable",age_seconds:99,owner:"none",holder:"supervisor",hold:{}}]'; }
status=0; ZF_GH_CALL_DEADLINE_EPOCH_MS=$(( $(date +%s%3N) + 3000 )) supervisor_hold_sweep 2>"$AGENT_HOME/sweep.err" || status=$?
assert_eq "a deadline stop is not a sweep failure" 0 "$status"
assert_contains "a deadline stop names where it stopped" "$(cat "$AGENT_HOME/sweep.err")" 'gh deadline reached at #910802'
unset -f supervisor_holds_snapshot
assert_true "the supervisor sweep shuffles too" grep -Fq '<<< "$rows" | shuf)' "$SCRIPT_DIR/supervisor-holds.sh"

# An expired hold among many unexpired ones is walked first, so a deadline that cuts the walk after a few holds cannot skip it.
for n in $(seq 910810 910839); do
  state_merge "$n" '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",expires_at:"2099-01-01T00:00:00Z",stage_before:"ready-for-agent"}' >/dev/null
done
state_merge 910840 '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",expires_at:"2026-10-31T00:00:00Z",stage_before:"ready-for-agent"}' >/dev/null
eval "orig_$(declare -f state_read)"
state_read() { # logs the walk order and stands in for the gh deadline: the third read ends the sweep
  echo "$1" >> "$AGENT_HOME/walk.log"
  [ "$(wc -l < "$AGENT_HOME/walk.log")" -lt 3 ] || exit 0
  orig_state_read "$1"
}
gh() { case "$1 $2" in "issue list") echo '[]' ;; *) return 1 ;; esac; }
for run in 1 2 3 4 5 6 7 8; do
  : > "$AGENT_HOME/walk.log"
  ( hold_sweep ) 2>/dev/null || true
  assert_eq "run $run reaches the expired hold first" 910840 "$(head -n 1 "$AGENT_HOME/walk.log")"
done
unset -f state_read gh

assert_true "the sweep shuffles so a deadline cannot starve one tail" grep -Eq 'sort -u \| shuf\)' "$SCRIPT_DIR/lib.d/holds.sh"
assert_true "blocker roots run last in the suffix" grep -Eq 'suffix_steps=\(.*batch-state needs-info-blocker-roots\)' "$SCRIPT_DIR/issue-pipeline.sh"

lib_case_exit
