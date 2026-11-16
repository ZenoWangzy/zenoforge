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

batch_stage batch review-pending || fail 'could not prepare the indirect transition'
batch_stage_indirect batch implement-pending || fail 'indirect units_update transition was refused'
grep -F 'unit transition undeclared unit=batch from=review-pending to=implement-pending by=batch_stage_indirect' "$LOG" >/dev/null \
  || record_failure 'units_update missed a stage change written through setpath'
[[ "$(unit_field batch '.stage')" == implement-pending ]] || fail 'indirect units_update did not write the stage'

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
echo 'ok - unit stage writes log undeclared transitions without refusing them'
