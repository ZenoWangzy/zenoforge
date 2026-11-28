#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../mac-autopilot" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
issue=1510
unit=unit-checkpoint
fixture="$test_env_root/checkpoint"
repo="$fixture/repo"
supervisor="$fixture/supervisor"
runtime="$supervisor/autopi"
mkdir -p "$repo" "$runtime"
mkdir -p "$AGENT_HOME/state"
cp "$engine/mac-autopilot/config.template.json" "$runtime/config.json"
printf '%s\n' '{"units":[{"id":"unit-checkpoint","issue":1510,"stage":"repair-pending","pr":42,"branch":"agent/issue-1510","lane":"direct-main","footprint":["engine/coord"],"approved_sha":"approved-old","review_sha":"review-old","blocked_on":"checks","blocked_resume_stage":"repair-pending","repair_hint":"restore this row","loop_total_allowed":4,"local_marker":"preserve"}]}' > "$runtime/units.json"
printf '%s\n' '{"attempts":3,"attempts_reset":1,"advisor_decision":{"verdict":"APPROVE"},"local_marker":"preserve"}' > "$AGENT_HOME/state/$issue.json"
export MAC_AUTOPILOT_ROOT="$repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$runtime"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export ZF_COORD=on
source "$engine/lib.sh"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
source "$engine/coord/checkpoint.sh"
source "$engine/coord-remote.sh"

fail() { printf 'checkpoint.test.sh: %s\n' "$*" >&2; exit 1; }

checkpoint="$(coord_checkpoint_project "$issue" "$unit")" || fail 'projection failed for real state and unit fixtures'
jq -e '.state.attempts == 3 and .state.attempts_reset == 1 and .state.advisor_decision.verdict == "APPROVE" and (.state.local_marker == null) and .unit.stage == "repair-pending" and .unit.pr == 42 and .unit.branch == "agent/issue-1510" and .unit.repair_hint == "restore this row" and (.unit.local_marker == null)' <<<"$checkpoint" >/dev/null \
  || fail 'projection did not retain only the recovery fields'
first_acquire_record=""
_coord_remote_read() { COORD_RECORD="" COORD_REMOTE_OID=""; return 1; }
_coord_remote_store() { first_acquire_record="$3"; COORD_RECORD="$3"; COORD_REMOTE_OID=1111111111111111111111111111111111111111; }
_coord_remote_observation_clear() { :; }
_coord_remote_acquire "issue-$issue" owner-first scheduler-worker "$issue" "$unit" repair-pending \
  || fail 'first acquisition did not publish a claim'
jq -e --argjson expected "$checkpoint" '.checkpoint == $expected' <<<"$first_acquire_record" >/dev/null \
  || fail 'first acquisition did not include the checkpoint projection'

takeover_source="$(jq -cn --argjson checkpoint "$checkpoint" \
  '{owner:"owner-old",generation:4,checkpoint:$checkpoint}')"
taken_over_record=""
_coord_remote_read() { COORD_RECORD="$takeover_source" COORD_REMOTE_OID=2222222222222222222222222222222222222222 COORD_REMOTE_EXPIRED=1; return 0; }
_coord_remote_observe() { return 0; }
_coord_remote_store() { taken_over_record="$3"; COORD_RECORD="$3"; COORD_REMOTE_OID=3333333333333333333333333333333333333333; }
_coord_remote_acquire "issue-$issue" owner-new scheduler-worker "$issue" "$unit" repair-pending \
  || fail 'takeover did not publish a claim'
jq -e --argjson expected "$checkpoint" '.checkpoint == $expected and .generation == 5' <<<"$taken_over_record" >/dev/null \
  || fail 'takeover did not preserve the remote checkpoint'
[[ "$COORD_REMOTE_RESTORE_REQUIRED" == 1 ]] || fail 'takeover did not request checkpoint restore'

claim="$(jq -cn --arg subject "$issue" --arg unit "$unit" --argjson checkpoint "$checkpoint" '{subject:$subject,unit:$unit,checkpoint:$checkpoint}')"
state_merge "$issue" '.attempts=9 | .attempts_reset=0 | .advisor_decision={verdict:"NOT_READY"} | .local_marker="keep-state"' \
  || fail 'could not prepare divergent state fixture'
units_update --arg id "$unit" '.units |= map(if .id == $id then .stage="implement-pending" | .pr=99 | .branch="local-branch" | .local_marker="keep-unit" else . end)' \
  || fail 'could not prepare divergent unit fixture'
coord_checkpoint_restore "$claim" || fail 'restore failed for real state and unit fixtures'
jq -e '.attempts == 3 and .attempts_reset == 1 and .advisor_decision.verdict == "APPROVE" and .local_marker == "keep-state"' "$AGENT_HOME/state/$issue.json" >/dev/null \
  || fail 'state fixture did not round trip through state_merge'
jq -e --arg id "$unit" '(.units[] | select(.id == $id)) as $u | $u.stage == "repair-pending" and $u.pr == 42 and $u.branch == "agent/issue-1510" and $u.repair_hint == "restore this row" and $u.local_marker == "keep-unit"' "$UNITS" >/dev/null \
  || fail 'unit fixture did not round trip through units_update'

renew_claim="$(jq -cn --arg subject "$issue" --arg unit "$unit" --argjson checkpoint "$checkpoint" \
  '{key:"issue-1510",owner:"owner-checkpoint",subject:$subject,unit:$unit,checkpoint:$checkpoint,expires_at:0}')"
state_merge "$issue" '.attempts=12' || fail 'could not change state before renewal'
units_update --arg id "$unit" '.units |= map(if .id == $id then .stage="implement-pending" else . end)' \
  || fail 'could not change unit before renewal'
_coord_remote_read() { COORD_RECORD="$renew_claim" COORD_REMOTE_OID=0000000000000000000000000000000000000000 COORD_REMOTE_EXPIRED=0; }
renewed_record=""
_coord_remote_store() { renewed_record="$3"; COORD_RECORD="$3"; COORD_REMOTE_OID=1111111111111111111111111111111111111111; }
_coord_remote_renew issue-1510 owner-checkpoint || fail 'renewal did not publish its checkpoint projection'
jq -e '.checkpoint.state.attempts == 12 and .checkpoint.unit.stage == "implement-pending"' <<<"$renewed_record" >/dev/null \
  || fail 'renewal did not refresh the checkpoint from the state and unit fixtures'

renew_claim="$renewed_record"
old_unit_checkpoint="$(jq -c '.checkpoint.unit' <<<"$renew_claim")"
state_merge "$issue" '.attempts=13' || fail 'could not change state before the missing-unit renewal'
UNITS="$fixture/missing-units.json"
_coord_remote_renew issue-1510 owner-checkpoint || fail 'renewal failed when the unit ledger was unavailable'
UNITS="$runtime/units.json"
jq -e --argjson old "$old_unit_checkpoint" '.checkpoint.state.attempts == 13 and .checkpoint.unit == $old' <<<"$renewed_record" >/dev/null \
  || fail 'renewal replaced unit recovery data when the unit ledger was unavailable'

large_value="$(printf '%9000s' '' | tr ' ' x)"
renew_claim="$renewed_record"
old_checkpoint="$(jq -c '.checkpoint' <<<"$renew_claim")"
state_merge "$issue" ".last_failure_reason=\"$large_value\"" || fail 'could not make state exceed the checkpoint limit'
_coord_remote_renew issue-1510 owner-checkpoint || fail 'oversize renewal did not publish its claim'
jq -e --argjson old "$old_checkpoint" '.checkpoint == $old and .checkpoint_truncated == true' <<<"$renewed_record" >/dev/null \
  || fail 'oversize renewal did not retain the previous checkpoint'

if ! env AGENT_HOME="$AGENT_HOME" ZF_ENGINE_DIR="$engine" ZF_REPO_DIR="$repo" \
  MAC_AUTOPILOT_RUNTIME_DIR="$runtime" bash -c '
    source "$ZF_ENGINE_DIR/lib.sh"
    source "$ZF_ENGINE_DIR/coord.sh"
    coord_checkpoint_restore "$1"
  ' _ "$claim"; then
  fail 'restore failed without the scheduler already loaded'
fi
jq -e --arg id "$unit" '(.units[] | select(.id == $id)) | .stage == "repair-pending" and .pr == 42' "$UNITS" >/dev/null \
  || fail 'standalone coordinator did not restore the unit row'

old_claim='{"key":"issue-1510","checkpoint":{"state":{"attempts":3},"unit":{}}}'
large_checkpoint="$(jq -cn --arg value "$large_value" '{state:{last_failure_reason:$value},unit:{}}')"
fitted_claim="$(coord_checkpoint_fit_claim "$old_claim" "$large_checkpoint")" || fail 'oversize projection was rejected instead of retaining the prior checkpoint'
jq -e '.checkpoint == {state:{attempts:3},unit:{}} and .checkpoint_truncated == true' <<<"$fitted_claim" >/dev/null \
  || fail 'oversize projection replaced the previous checkpoint'

failure_claim="$(jq -cn --arg subject "$issue" --arg unit unit-missing --argjson checkpoint "$checkpoint" \
  '{proto:1,version:1,key:"unit-unit-missing",owner:"owner-checkpoint",owner_kind:"scheduler-worker",subject:$subject,unit:$unit,stage:"repair-pending",checkpoint:$checkpoint}')"
coord_control_allows_acquire() { return 0; }
_coord_remote_acquire() {
  COORD_REMOTE_ACQUIRE_NEW=1
  COORD_REMOTE_RESTORE_REQUIRED=1
  COORD_REMOTE_OID=0000000000000000000000000000000000000000
  COORD_RECORD="$failure_claim"
  return 0
}
_coord_remote_held_write() { return 0; }
release_calls=0
coord_release() { release_calls=$((release_calls + 1)); [[ "$1" == unit-unit-missing && "$2" == owner-checkpoint ]]; }
if coord_acquire unit-unit-missing owner-checkpoint scheduler-worker "$issue" unit-missing repair-pending; then
  fail 'acquisition succeeded after checkpoint restore failed'
else
  rc=$?
  [[ "$rc" == 3 ]] || fail "restore failure returned $rc instead of 3"
fi
[[ "$release_calls" == 1 ]] || fail 'restore failure did not release the claim'
grep -q 'checkpoint-restore-failed' "$AGENT_HOME/supervisor-inbox" || fail 'restore failure did not raise an alert'

printf 'checkpoint.test.sh: PASS\n'
