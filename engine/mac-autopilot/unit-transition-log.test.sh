#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/unit-transition-log"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[{"id":"u","stage":"implement-pending","history":[]},{"id":"batch","stage":"review-pending","history":[]}]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
cp "$script_dir/../state/scheduling-policy.json" "$fixture/policy.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export UNIT_TRANSITION_POLICY_FILE="$fixture/policy.json" SCHED_LOCK_HELD=true AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
rm "$UNIT_TRANSITION_POLICY_FILE"

fail() { echo "unit-transition-log.test.sh: $*" >&2; exit 1; }
write_stage() { set_unit "$1" ".stage=$(js "$2")"; }
batch_stage() { units_update --arg id "$1" --arg stage "$2" '.units |= map(if .id == $id then .stage = $stage else . end)'; }
batch_stage_indirect() { units_update --arg id "$1" --arg stage "$2" '.units |= map(if .id == $id then setpath(["stage"]; $stage) else . end)'; }
batch_mixed_stage() { units_update '.units |= map(if .id == "u" then .stage = "review-pending" elif .id == "batch" then .stage = "landing" else . end)'; }

failures=()
record_failure() { failures+=("$1"); echo "not ok - $1" >&2; }

write_stage u review-pending || fail 'declared set_unit transition failed'
! grep -q 'unit transition undeclared' "$LOG" || fail 'declared transition was logged'
write_stage u implement-pending || fail 'undeclared set_unit transition was refused'
grep -F 'unit transition undeclared unit=u from=review-pending to=implement-pending by=write_stage' "$LOG" >/dev/null \
  || fail 'set_unit did not log the undeclared transition with its caller'
[[ "$(unit_field u '.stage')" == implement-pending ]] || fail 'log-only mode did not write the undeclared transition'

batch_stage batch implement-pending || fail 'undeclared units_update transition was refused'
grep -F 'unit transition undeclared unit=batch from=review-pending to=implement-pending by=batch_stage' "$LOG" >/dev/null \
  || fail 'units_update did not log the undeclared transition with its caller'
[[ "$(unit_field batch '.stage')" == implement-pending ]] || fail 'log-only mode did not write the batch transition'
[[ "$(grep -c 'unit transition undeclared' "$LOG")" == 2 ]] || fail 'expected one log line for each undeclared transition'

undeclared_before="$(grep -c 'unit transition undeclared' "$LOG")"
set_unit u '.note=(.history[-1].stage // "metadata only")' || fail 'metadata-only set_unit failed'
[[ "$(unit_field u '.stage')" == implement-pending ]] || fail 'metadata-only write changed the stage'
[[ "$(grep -c 'unit transition undeclared' "$LOG")" == "$undeclared_before" ]] \
  || fail 'metadata-only write logged a stage transition'

set_unit u '.history += [{stage:"supervisor-rule",result:"ruling recorded",decision:{decision:"requeue",owner:"supervisor",why:"scope fits"}}] | .stage="supervisor-review"' \
  || fail 'unit stage with a stored ruling failed'
jq -e '.id == "u" and .stage == "supervisor-review" and .owner == "u"' "$AGENT_HOME/task-state/u/task.json" >/dev/null \
  || fail 'set_unit did not update the current task record'
jq -se 'length == 2 and .[0].record_type == "handoff" and .[0].to == "hold" and .[1].record_type == "decision" and .[1].decision == "requeue" and .[1].by == "supervisor"' \
  "$AGENT_HOME/task-state/u/events.jsonl" >/dev/null || fail 'set_unit did not append its hold and ruling records'
set_unit u '.worker_id="worker-u"' || fail 'unit owner handoff failed'
jq -e '.stage == "supervisor-review" and .owner == "worker-u"' "$AGENT_HOME/task-state/u/task.json" >/dev/null \
  || fail 'set_unit did not update the task when only its owner changed'
jq -se 'length == 3 and .[2].record_type == "handoff" and .[2].from == "u" and .[2].to == "worker-u"' \
  "$AGENT_HOME/task-state/u/events.jsonl" >/dev/null || fail 'set_unit did not append the owner-change handoff'
set_unit u '.history += [{stage:"supervisor-cap-rule",result:"same-stage supervisor ruling",decision:{decision:"hold",owner:"supervisor",why:"cap remains"}}]' \
  || fail 'same-stage supervisor ruling failed'
jq -se 'length == 4 and .[3].record_type == "decision" and .[3].decision == "hold" and .[3].by == "supervisor"' \
  "$AGENT_HOME/task-state/u/events.jsonl" >/dev/null || fail 'set_unit did not record a decision-only history append'
set_unit u '.history += [{stage:"supervisor-approve",result:"supervisor ruling via hold.sh --rule: comment-1"}]' \
  || fail 'plain supervisor ruling failed'
jq -se 'length == 5 and .[4].record_type == "decision" and .[4].decision == "approve" and .[4].by == "supervisor"' \
  "$AGENT_HOME/task-state/u/events.jsonl" >/dev/null || fail 'set_unit did not record a plain supervisor ruling'

batch_stage batch review-pending || fail 'could not prepare the indirect transition'
batch_stage_indirect batch implement-pending || fail 'indirect units_update transition was refused'
grep -F 'unit transition undeclared unit=batch from=review-pending to=implement-pending by=batch_stage_indirect' "$LOG" >/dev/null \
  || record_failure 'units_update missed a stage change written through setpath'
[[ "$(unit_field batch '.stage')" == implement-pending ]] || fail 'indirect units_update did not write the stage'

UNIT_TRANSITION_MODE=enforce
cp "$UNITS" "$fixture/before-set-unit-refusal.json"
if write_stage u landing; then fail 'enforce mode accepted an undeclared set_unit transition'; fi
cmp -s "$fixture/before-set-unit-refusal.json" "$UNITS" || fail 'refused set_unit transition changed the ledger'
grep -F 'unit-transition refused unit=u from=supervisor-review to=landing caller=write_stage' "$LOG" >/dev/null \
  || fail 'set_unit refusal did not log unit, stages and caller'

cp "$UNITS" "$fixture/before-units-update-refusal.json"
if batch_mixed_stage; then fail 'enforce mode accepted an undeclared units_update transition'; fi
cmp -s "$fixture/before-units-update-refusal.json" "$UNITS" \
  || fail 'refused units_update transition wrote the other legal stage change'
grep -F 'unit-transition refused unit=batch from=implement-pending to=landing caller=batch_mixed_stage' "$LOG" >/dev/null \
  || fail 'units_update refusal did not log unit, stages and caller'
unset UNIT_TRANSITION_MODE
declare -A intake_step_secs=() intake_step_counts=()
intake_step_at=0
SET_UNIT_QUEUE=1
set_unit batch '.stage="review-pending"' || fail 'queued set_unit transition failed'
SET_UNIT_QUEUE=0
dep_q_flush || fail 'queued unit transition flush failed'
jq -e '.id == "batch" and .stage == "review-pending"' "$AGENT_HOME/task-state/batch/task.json" >/dev/null \
  || fail 'queued unit transition did not update the current task record'
batch_task="$AGENT_HOME/task-state/batch/task.json"
batch_events="$AGENT_HOME/task-state/batch/events.jsonl"
before_task="$(cat "$batch_task")"
before_events="$(cat "$batch_events" 2>/dev/null || true)"
mv() { [[ "${2:-}" != "$UNITS" ]] || return 1; command mv "$@"; }
ledger_rc=0
set_unit batch '.stage="supervisor-review"' 2>/dev/null || ledger_rc=$?
unset -f mv
[[ "$ledger_rc" -ne 0 ]] || fail 'unit ledger rename failure unexpectedly succeeded'
[[ "$(unit_field batch '.stage')" == review-pending ]] || fail 'failed ledger rename committed the unit stage'
[[ "$(cat "$batch_task")" == "$before_task" ]] || fail 'failed ledger rename left a task record ahead of the unit ledger'
if [[ -n "$before_events" ]]; then
  [[ "$(cat "$batch_events")" == "$before_events" ]] || fail 'failed ledger rename left a task event behind'
else
  [[ ! -e "$batch_events" ]] || fail 'failed ledger rename left a new task event file behind'
fi
real_engine_dir="${ZF_ENGINE_DIR:-$ENGINE_ROOT/engine}"
ZF_ENGINE_DIR="$fixture/missing-engine"
task_rc=0
set_unit batch '.stage="supervisor-review"' 2>/dev/null || task_rc=$?
ZF_ENGINE_DIR="$real_engine_dir"
[[ "$task_rc" -ne 0 ]] || fail 'task-state writer failure unexpectedly committed a unit transition'
[[ "$(unit_field batch '.stage')" == review-pending ]] || fail 'task-state writer failure left the unit stage changed'

transition_log="$LOG"
mkdir "$fixture/unwritable-log"
LOG="$fixture/unwritable-log"
if write_stage u landing 2>/dev/null; then :; else record_failure 'an unwritable transition log made set_unit fail'; fi
[[ "$(unit_field u '.stage')" == landing ]] || record_failure 'an unwritable transition log prevented the ledger write'
LOG="$transition_log"

bad_policy="$fixture/broken-policy.json"
printf '%s\n' '{"state_machine":' > "$bad_policy"
UNIT_TRANSITION_POLICY_FILE="$bad_policy"
UNIT_TRANSITION_POLICY_LOADED=false
unit_transition_load || record_failure 'broken policy made unit_transition_load fail'
unit_transition_load || record_failure 'repeated broken policy load failed'
[[ "$(grep -Fc "unit transition log off: invalid policy $bad_policy" "$LOG" || true)" == 1 ]] \
  || record_failure 'broken policy did not emit exactly one policy-off line'
if write_stage u review-pending; then :; else record_failure 'broken policy made set_unit fail'; fi
[[ "$(unit_field u '.stage')" == review-pending ]] || record_failure 'broken policy prevented the ledger write'

unreadable_policy="$fixture/unreadable-policy"
mkdir "$unreadable_policy"
policy_log="$fixture/unreadable-policy.log"
(
  LOG="$policy_log"
  UNIT_TRANSITION_POLICY_FILE="$unreadable_policy"
  UNIT_TRANSITION_POLICY_LOADED=false
  say() { echo "$*" >> "$LOG"; }
  source "$script_dir/scheduler.d/unit-transition-log.sh"
  unit_transition_load
)
[[ "$(grep -Fc "unit transition log off: unreadable policy $unreadable_policy" "$policy_log" || true)" == 1 ]] \
  || record_failure 'unreadable policy did not emit exactly one policy-off line'

if ((${#failures[@]})); then
  printf 'failed negative cases: %s\n' "${failures[*]}" >&2
  exit 1
fi
echo 'ok - unit stage writes honor log and enforce modes at both ledger writers'
