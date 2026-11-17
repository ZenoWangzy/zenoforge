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
gh() { case "$1 $2" in "issue list") echo '[{"number":910840,"state":"OPEN","labels":[{"name":"on-hold"}]}]' ;; *) return 1 ;; esac; }
for run in 1 2 3 4 5 6 7 8; do
  : > "$AGENT_HOME/walk.log"
  ( hold_sweep ) 2>/dev/null || true
  assert_eq "run $run reaches the expired hold first" 910840 "$(head -n 1 "$AGENT_HOME/walk.log")"
done
unset -f gh
state_read() { orig_state_read "$@"; }
for n in $(seq 910810 910840); do rm -f "$AGENT_HOME/state/$n.json"; done

assert_true "the sweep shuffles so a deadline cannot starve one tail" grep -Eq 'sort -u \| shuf\)' "$SCRIPT_DIR/lib.d/holds.sh"
assert_true "blocker roots run last in the suffix" grep -Eq 'suffix_steps=\(.*batch-state needs-info-blocker-roots\)' "$SCRIPT_DIR/issue-pipeline.sh"

# A slow all-comments snapshot consumes the short tick before expiry writes. The retry must
# put the already-read hold first and reuse its pending marker body on the next sweep.
FAKE_GH_LOG="$AGENT_HOME/gh.log" FAKE_GH_MARKERS="$AGENT_HOME/comments"
mkdir -p "$FAKE_GH_MARKERS"
FAKE_GH_NOW_FILE="$AGENT_HOME/gh-now" FAKE_GH_FAIL_ISSUE="" FAKE_GH_SHUFFLE_RUN=0
FAKE_GH_LIST_IDS=(910810 910811 910812)
printf '1800000000000\n' > "$FAKE_GH_NOW_FILE"
fake_advance_ms() { printf '%s\n' "$(( $(cat "$FAKE_GH_NOW_FILE") + $1 ))" > "$FAKE_GH_NOW_FILE"; }
gh_call_now_ms() { cat "$FAKE_GH_NOW_FILE"; }
gh_tick_attempt_timeout_sec() {
  local allowed=$((ZF_GH_CALL_DEADLINE_EPOCH_MS - $(gh_call_now_ms) - 6000))
  (( allowed >= 1000 )) || return 1
  printf '%s\n' "$((allowed / 1000))"
}
gh() {
  local n path body list='[]' comments item
  printf 'gh %s\n' "$*" >> "$FAKE_GH_LOG"
  if ! gh_tick_attempt_timeout_sec >/dev/null; then
    case "${1:-}:${2:-}" in api:*|issue:list) echo 'gh: refusing read because the owner-admission deadline cannot fit one bounded attempt' >&2 ;; *) echo 'gh: refusing call because the owner-admission deadline cannot fit one bounded attempt' >&2 ;; esac
    return 124
  fi
  case "${1:-}:${2:-}" in
    issue:list)
      [[ "$*" != *comments* ]] || fake_advance_ms 5000
      [[ "$*" == *comments* ]] || fake_advance_ms 1000
      for n in "${FAKE_GH_LIST_IDS[@]}"; do
        [[ "$(jq -r '.state // empty' "$AGENT_HOME/state/$n.json" 2>/dev/null || true)" == on-hold ]] || continue
        if [[ "$*" == *comments* ]]; then
          comments='[]'
          [[ ! -f "$FAKE_GH_MARKERS/$n" ]] || comments="$(jq -cn --rawfile body "$FAKE_GH_MARKERS/$n" '[{body:$body}]')"
          item="$(jq -cn --argjson n "$n" --argjson comments "$comments" '{number:$n,state:"OPEN",stateReason:null,closedAt:null,labels:[{name:"on-hold"}],comments:$comments,title:"fixture",updatedAt:"2026-11-16T00:00:00Z"}')"
        else
          item="$(jq -cn --argjson n "$n" '{number:$n,state:"OPEN",stateReason:null,closedAt:null,labels:[{name:"on-hold"}],title:"fixture",updatedAt:"2026-11-16T00:00:00Z"}')"
        fi
        list="$(jq -cn --argjson list "$list" --argjson item "$item" '$list + [$item]')"
      done
      printf '%s\n' "$list"
      ;;
    api:--paginate)
      path="${!#}"
      n="$(sed -n 's#.*issues/\([0-9][0-9]*\)/comments.*#\1#p' <<< "$path")"
      fake_advance_ms 2000
      if [[ -f "$FAKE_GH_MARKERS/$n" ]]; then
        jq -cn --rawfile body "$FAKE_GH_MARKERS/$n" '[[{node_id:"fixture",body:$body,user:{login:"bot"}}]]'
      else
        echo '[[]]'
      fi
      ;;
    api:*)
      n="${2##*/}"
      fake_advance_ms 2000
      case "$n" in
        910700|910701|910702) jq -cn --argjson n "$n" '{number:$n,title:"fixture",body:"",state:"closed",state_reason:"completed",closed_at:"2026-10-31T00:00:00Z",labels:[{name:"concluded"}]}' ;;
        *) jq -cn --argjson n "$n" '{number:$n,title:"fixture",body:"",state:"open",labels:[{name:"on-hold"}]}' ;;
      esac
      ;;
    issue:comment)
      n="$3"; body="${@: -1}"
      if [[ "$n" == "$FAKE_GH_FAIL_ISSUE" ]]; then echo 'simulated comment API failure' >&2; return 1; fi
      cat "$body" > "$FAKE_GH_MARKERS/$n"
      fake_advance_ms 1000
      ;;
    issue:edit) fake_advance_ms 1000 ;;
    *) return 0 ;;
  esac
}
shuf() {
  FAKE_GH_SHUFFLE_RUN=$((FAKE_GH_SHUFFLE_RUN + 1))
  if (( FAKE_GH_SHUFFLE_RUN == 1 )); then tac; else cat; fi
}
for n in 910810 910811; do
  state_merge "$n" '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",release_condition:"stop-loss ended",expires_at:"2026-10-31T00:00:00Z",stage_before:"finish-first",durable_record:true}' >/dev/null
done
run_short_hold_sweep() {
  ZF_GH_CALL_DEADLINE_EPOCH_MS=$(($(gh_call_now_ms) + 11000))
  export ZF_GH_CALL_DEADLINE_EPOCH_MS
  hold_sweep 2>> "$AGENT_HOME/short-sweep.err" || true
}
: > "$FAKE_GH_LOG"
run_short_hold_sweep
pending_issue="$(jq -r 'select(.hold_sweep_refusal.reason == "expiry-comment-pending") | input_filename | split("/")[-1] | rtrimstr(".json")' "$AGENT_HOME/state/910810.json" "$AGENT_HOME/state/910811.json" | head -n 1)"
assert_eq "a refused expiry write is retained for the next tick" 910811 "$pending_issue"
: > "$FAKE_GH_LOG"
run_short_hold_sweep
first_issue_action="$(grep -E '^gh (issue comment|api )' "$FAKE_GH_LOG" | head -n 1 | sed -E 's/^gh //')"
assert_contains "the pending hold retries before another detail read" "$first_issue_action" 'issue comment 910811 '
for run in 3 4; do run_short_hold_sweep; done
assert_eq "repeated short sweeps release the first expired hold" finish-first "$(jq -r '.state' "$AGENT_HOME/state/910810.json")"
assert_eq "repeated short sweeps release the pending expired hold" finish-first "$(jq -r '.state' "$AGENT_HOME/state/910811.json")"

for n in $(seq 910810 910840); do rm -f "$AGENT_HOME/state/$n.json" "$FAKE_GH_MARKERS/$n"; done
state_merge 910812 '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",release_condition:"stop-loss ended",expires_at:"2026-10-31T00:00:00Z",stage_before:"finish-first",durable_record:true}' >/dev/null
FAKE_GH_FAIL_ISSUE=910812
ZF_GH_CALL_DEADLINE_EPOCH_MS=$(($(gh_call_now_ms) + 60000)); export ZF_GH_CALL_DEADLINE_EPOCH_MS
: > "$FAKE_GH_LOG"
status=0; hold_sweep 2>"$AGENT_HOME/comment-failure.err" || status=$?
assert_eq "a real expiry comment failure is returned" 1 "$status"
assert_eq "a real expiry comment failure leaves the hold" on-hold "$(jq -r '.state' "$AGENT_HOME/state/910812.json")"
assert_contains "a real expiry comment failure is logged" "$(cat "$AGENT_HOME/comment-failure.err")" 'could not record expiry for #910812; leaving hold untouched'
assert_contains "the fake API reports a real write failure" "$(cat "$AGENT_HOME/comment-failure.err")" 'simulated comment API failure'

# Stale expired state-only holds must not take the short tick ahead of expired holds in the live snapshot.
FAKE_GH_FAIL_ISSUE=""
FAKE_GH_SHUFFLE_RUN=0
shuf() { cat; }
FAKE_GH_LIST_IDS=()
mapfile -t FAKE_GH_LIST_IDS < <(seq 910810 910839)
FAKE_GH_LIST_IDS+=(910840 910841)
printf '1800000000000\n' > "$FAKE_GH_NOW_FILE"
for n in "${FAKE_GH_LIST_IDS[@]}"; do
  expiry=2099-01-01T00:00:00Z
  [[ "$n" != 910840 && "$n" != 910841 ]] || expiry=2026-10-31T00:00:00Z
  state_merge "$n" ".state = \"on-hold\" | .hold = {kind:\"stop-loss\",holder:\"scheduler-stop-loss\",release_condition:\"stop-loss ended\",expires_at:\"$expiry\",stage_before:\"finish-first\",durable_record:true}" >/dev/null
done
for n in 910700 910701 910702; do
  state_merge "$n" '.state = "on-hold" | .hold = {kind:"stop-loss",holder:"scheduler-stop-loss",release_condition:"stop-loss ended",expires_at:"2026-10-31T00:00:00Z",stage_before:"finish-first",durable_record:true}' >/dev/null
done
run_short_hold_sweep_16s() {
  ZF_GH_CALL_DEADLINE_EPOCH_MS=$(($(gh_call_now_ms) + 16000))
  export ZF_GH_CALL_DEADLINE_EPOCH_MS
  hold_sweep 2>> "$AGENT_HOME/short-sweep.err" || true
}
: > "$FAKE_GH_LOG"
run_short_hold_sweep_16s
first_hold_read="$(grep -E '^gh api ' "$FAKE_GH_LOG" | head -n 1)"
assert_contains "the first per-hold read targets a live expired issue" "$first_hold_read" 'issues/910840'
assert_eq "one live expired hold releases before state-only holds use the slice" finish-first "$(jq -r '.state' "$AGENT_HOME/state/910840.json")"
assert_eq "the next live expiry persists its pending comment for the next tick" expiry-comment-pending "$(jq -r '.hold_sweep_refusal.reason // empty' "$AGENT_HOME/state/910841.json")"
for run in 2 3 4; do run_short_hold_sweep_16s; done
assert_eq "short repeated sweeps release the other live expired hold" finish-first "$(jq -r '.state' "$AGENT_HOME/state/910841.json")"
assert_eq "state-only expired holds reconcile through their closed issue snapshot" concluded "$(jq -r '.state' "$AGENT_HOME/state/910700.json")"
for n in "${FAKE_GH_LIST_IDS[@]}" 910700 910701 910702; do rm -f "$AGENT_HOME/state/$n.json" "$FAKE_GH_MARKERS/$n"; done

lib_case_exit
