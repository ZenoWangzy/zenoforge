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
echo 'ok - unit stage writes log undeclared transitions without refusing them'
