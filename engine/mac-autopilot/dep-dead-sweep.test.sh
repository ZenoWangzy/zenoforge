#!/usr/bin/env bash
# A marked unit reaches the arbiter once, only on proof its predecessor can never deliver; any unreadable fact means not dead.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'dep-dead-sweep.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dep-dead-sweep"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; : > "$LOG"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
cancel_unit_runs() { :; }
dep_delivered_snapshot() { :; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }

dead='{"id":"issue-10","issue":10,"stage":"closed","pr":510,"branch":"agent/issue-10","note":"closed for size","history":[]}'
marked() { printf '{"id":"issue-%s","issue":%s,"stage":"blocked-external","blocked_on":10,"dep_wait_delivery":10,"task":"t","branch":"agent/issue-%s","history":[]}' "$1" "$1" "$1"; }
reset() { # the dead case; each fail-closed case below breaks one fact
  printf '{"units":[%s,%s]}\n' "$dead" "$(marked 20)" > "$UNITS"
  printf '%s\n' '{"workers":[]}' > "$A/workers.json"
  DEP_DELIVERED_CACHE=()
  PRS='[]'; PRS_RC=0; ISSUE='{"state":"tracker"}'; ISSUE_RC=0; SUBS=''; SUBS_RC=0; CHILD='CLOSED'
}
tick_prs() { printf '%s' "$PRS"; return "$PRS_RC"; }
scheduler_issue_state() { printf '%s' "$ISSUE"; return "$ISSUE_RC"; }
dep_states() { [[ -z "$CHILD" ]] || printf '%s\t%s\t\n' "$1" "$CHILD"; }
gh() {
  case "$*" in
    *sub_issues*) [[ -z "$SUBS" ]] || printf '%s\n' "$SUBS"; return "$SUBS_RC" ;;
    *git/ref/heads/*) printf 'abcdef0123456789\n' ;;
  esac
}
alive() { dep_dead_sweep; [[ "$(field issue-20 .stage)" == blocked-external ]] || fail "$1: must stay blocked, got $(field issue-20 .stage)"; }

reset; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail "a dead predecessor must reach the arbiter: $(field issue-20 .stage)"
[[ "$(field issue-20 .dep_dead_proved)" == 10 && "$(field issue-20 .blocked_on)" == null ]] || fail 'the proof must be recorded and the wait released'
[[ "$(field issue-20 .supervisor_cap_return_stage)" == implement-pending ]] || fail 'a ruling must return the unit to work'
note="$(field issue-20 .note)"
[[ "$note" == *'#10'* && "$note" == *'agent/issue-10@abcdef012345'* && "$note" == *'closed for size'* ]] || fail "the evidence must name predecessor, branch, SHA and why: $note"

reset; DEP_DELIVERED_CACHE[10]=1; alive 'a delivered predecessor'
reset; jq -c '.units[0].stage="merged"' "$UNITS" > "$UNITS.t"; mv "$UNITS.t" "$UNITS"; alive 'a merged predecessor unit'
reset; jq -c '.units[0].stage="parked"' "$UNITS" > "$UNITS.t"; mv "$UNITS.t" "$UNITS"; alive 'a parked predecessor unit'
norow() { jq -c '.units |= map(select(.id != "issue-10"))' "$UNITS" > "$UNITS.t"; mv "$UNITS.t" "$UNITS"; }
reset; norow; ISSUE='{"state":"ready-for-agent"}'; alive 'no predecessor row on an issue that is no tracker'
reset; norow; SUBS=30; CHILD=OPEN; alive 'an open tracker with a live child'
reset; norow; ISSUE_RC=1; alive 'no predecessor row and an unreadable issue state'
reset; norow; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'an open tracker with no unit and no live child cannot deliver'
[[ "$(field issue-20 .note)" == *'open tracker with no unit'* ]] || fail "the evidence must say why: $(field issue-20 .note)"
reset; printf '%s\n' '{"workers":[{"unit":"issue-10"}]}' > "$A/workers.json"; alive 'a live worker'
reset; printf 'not json\n' > "$A/workers.json"; alive 'an unreadable worker list'
reset; printf '%s\n' '{"workers":[{"unit":"issue-10","harvested":true}]}' > "$A/workers.json"; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'a harvested worker is not live'
reset; PRS='[{"number":510,"headRefName":"x","body":""}]'; alive 'its own PR open'
reset; PRS='[{"number":600,"headRefName":"agent/issue-10","body":""}]'; alive 'a PR on its branch'
reset; PRS='[{"number":600,"headRefName":"recovered","body":"Refs #10."}]'; alive 'a PR on another branch naming it'
reset; PRS_RC=1; alive 'an unreadable PR census'
reset; ISSUE_RC=1; alive 'an unreadable issue state'
reset; ISSUE=''; alive 'an empty issue state'
reset; SUBS_RC=1; alive 'unreadable sub-issues'
reset; SUBS=30; CHILD=OPEN; alive 'an open sub-issue'
reset; ISSUE='{"state":"tracker","recut_children":[30]}'; CHILD=OPEN; alive 'an open recut child'
reset; ISSUE='{"state":"tracker","recut_children":[30]}'; CHILD=''; alive 'an unreadable child'
reset; PRS='[{"number":600,"headRefName":"other","body":"Refs #100"}]'; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'a longer issue number must not read as this predecessor'
reset; SUBS=20; CHILD=OPEN; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'the waiter is not its own live child'
reset; ISSUE='{"state":"tracker","recut_children":[30]}'; CHILD=CLOSED; dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'a closed child is not live'
reset; printf '{"units":[%s,%s,%s]}\n' "$dead" "$(marked 20)" "$(marked 30)" > "$UNITS"; SUBS=$'20\n30'; CHILD=OPEN; dep_dead_sweep
[[ "$(field issue-30 .stage)" == supervisor-review ]] || fail 'a child waiting on the same predecessor is not live'

# One per sweep, newest first, with no state: nothing can wedge the next one.
[[ "$(field issue-20 .stage)" == blocked-external ]] || fail 'only one unit moves'
dep_dead_sweep
[[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'the next sweep moves the next unit'

# A closed issue that delivered nothing does not end a marker: only the sweep and the arbiter do (#536).
NOW_EPOCH="$(date +%s)"
closed_state() { jq -cn --argjson e "$NOW_EPOCH" --arg s "$1" '{epoch:$e,states:{"10":{state:$s,labels:""}}}' > "$A/dep-check.cache.json"; printf '%s\n' "$NOW_EPOCH" > "$A/dep-check.epoch"; }
reset; closed_state CLOSED; release_dependency_blocks
[[ "$(field issue-20 .stage):$(field issue-20 .blocked_on)" == blocked-external:10 ]] || fail "a closed undelivered predecessor released a marked unit: $(field issue-20 .stage)"
[[ "$(dep_marker_open "$(jq -c '.units[1]' "$UNITS")")" == 10 ]] || fail 'the marker must stay open on a closed undelivered predecessor'
dep_dead_sweep; [[ "$(field issue-20 .stage)" == supervisor-review ]] || fail 'the sweep must take a closed undelivered predecessor to the arbiter'
reset; closed_state CLOSED; printf '{"units":[%s,%s]}\n' "$(jq -c '.stage="implement"' <<<"$dead")" "$(marked 20)" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" == blocked-external ]] || fail 'a stale closed state must not release a marked unit while the predecessor still has a live unit'
reset; closed_state CLOSED; printf '{"units":[%s,%s]}\n' "$(jq -c '.stage="wontfix"' <<<"$dead")" "$(marked 20)" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" != blocked-external ]] || fail 'a wontfix predecessor is settled: the sweep can never prove it, so it must release'
reset; closed_state CLOSED; printf '{"units":[%s,%s,%s]}\n' "$dead" "$(jq -c '.stage="done" | .id="pr-10"' <<<"$dead")" "$(marked 20)" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" != blocked-external ]] || fail 'one settled row among closed rows must release: the sweep needs all rows closed'
reset; closed_state MERGED; release_dependency_blocks
[[ "$(field issue-20 .stage)" != blocked-external ]] || fail 'a merged predecessor must release a marked unit'
reset; closed_state CLOSED; printf '{"units":[%s]}\n' "$(marked 20)" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" != blocked-external ]] || fail 'a closed predecessor with no unit row was closed by hand and must release'
! dep_marker_open "$(marked 20)" >/dev/null || fail 'a closed predecessor with no unit row must end the marker'
reset; closed_state CLOSED; printf '{"units":[%s,%s]}\n' "$dead" "$(marked 20 | jq -c 'del(.dep_wait_delivery)')" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" != blocked-external ]] || fail 'an unmarked unit keeps the old release on a closed predecessor'
reset; closed_state CLOSED; printf '{"units":[%s,%s]}\n' "$dead" "$(marked 20 | jq -c '.stage="parked"')" > "$UNITS"; release_dependency_blocks
[[ "$(field issue-20 .stage)" == parked ]] || fail 'a parked marked unit must not read a closed undelivered predecessor as delivered'
rm -f "$A/dep-check.cache.json" "$A/dep-check.epoch"

# Proof is the only way past the marker, including a body dependency on the same predecessor.
printf '{"states":{}}\n' > "$A/dep-check.cache.json"
reset
[[ -n "$(dep_marker_open "$(jq -cn '{dep_wait_delivery:10}')")" ]] || fail 'no proof: the marker holds'
ruled='[{"stage":"dep-dead-proved"},{"stage":"supervisor-requeue","decision":{"owner":"supervisor"}}]'
[[ -n "$(dep_marker_open "$(jq -cn --argjson h "$ruled" '{dep_wait_delivery:10,dep_dead_proved:11,history:$h}')")" ]] || fail 'proof of another predecessor: the marker holds'
[[ -n "$(dep_marker_open "$(jq -cn '{dep_wait_delivery:10,dep_dead_proved:10,history:[{stage:"dep-dead-proved"}]}')")" ]] || fail 'proof with no ruling: the marker holds'
[[ -n "$(dep_marker_open "$(jq -cn '{dep_wait_delivery:10,dep_dead_proved:10,history:[{stage:"dep-dead-proved"},{stage:"supervisor-requeue",result:"ownerless hold handoff"}]}')")" ]] || fail 'a handoff requeue is no ruling: the marker holds'
[[ -n "$(dep_marker_open "$(jq -cn '{dep_wait_delivery:10,dep_dead_proved:10,history:[{stage:"supervisor-requeue",decision:{owner:"supervisor"}},{stage:"dep-dead-proved"}]}')")" ]] || fail 'a ruling before the proof: the marker holds'
[[ -z "$(dep_marker_open "$(jq -cn --argjson h "$ruled" '{dep_wait_delivery:10,dep_dead_proved:10,history:$h}')")" ]] || fail 'proof and a ruling: the unit may start'
[[ -z "$(dep_marker_open "$(jq -cn '{dep_wait_delivery:10,dep_dead_proved:10,history:[{stage:"dep-dead-proved"},{stage:"supervisor-requeue",decision:{owner:"typesafe"}}]}')")" ]] || fail 'a TypeSafe requeue is a ruling too'
[[ "$(blocking_body_dependency "$(jq -cn '{body_blocked_by:[10]}')")" == 10 ]] || fail 'no proof: the body dependency blocks'
[[ "$(blocking_body_dependency "$(jq -cn '{body_blocked_by:[10],dep_dead_proved:10,history:[{stage:"dep-dead-proved"}]}')")" == 10 ]] || fail 'no ruling: the body dependency blocks'
[[ -z "$(blocking_body_dependency "$(jq -cn --argjson h "$ruled" '{body_blocked_by:[10],dep_dead_proved:10,history:$h}')")" ]] || fail 'proof and a ruling: the body dependency does not block'

# Blocking on it again after the ruling is a visible terminal park, not a second arbiter round.
reset; jq -c '(.units[] | select(.id=="issue-20")).dep_dead_proved=10' "$UNITS" > "$UNITS.t"; mv "$UNITS.t" "$UNITS"; dep_dead_sweep
jq -e '.units[] | select(.id=="issue-20") | .stage=="parked" and .parked_reason=="dep-dead-repeat" and (.unpark_condition | length > 0) and (.note | contains("#10")) and .blocked_on == null' "$UNITS" >/dev/null \
  || fail "a repeat must park visibly: $(jq -c '.units[1]' "$UNITS")"
grep -q 'dep-dead unit=issue-20 predecessor=#10 action=parked' "$A/alerts/events.md" || fail 'a repeat must raise an alert'

echo 'dep-dead-sweep.test.sh: PASS'
