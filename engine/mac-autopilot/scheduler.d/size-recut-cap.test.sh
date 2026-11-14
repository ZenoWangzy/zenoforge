#!/usr/bin/env bash
# #6292: a size recut that recut refuses comes back ready-for-agent, is resumed, is admitted to recut again, and repeats.
# The first round trip resumes; the second goes to the supervisor with the size numbers and is not resumed.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/size-recut-cap"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$AGENT_HOME/state"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
STAMP="2026-11-12T00:00:00Z"
SCHED_LOCK_HELD=true

fail() { echo "size-recut-cap.test.sh: $*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
scheduler_issue_state() { cat "$AGENT_HOME/state/$1.json"; }

jq -n '{units:[{id:"issue-6292",issue:6292,branch:"agent/issue-6292",stage:"blocked-external",size_recut_pending:true,
  history:[{stage:"size-recut",result:"issue #6292: 720 lines exceed 640; head=aaa111",at:"2026-11-10T00:00:00Z"}]}]}' > "$UNITS"

# Round trip 1: recut refused, issue back to ready-for-agent. The unit resumes as before.
printf '%s\n' '{"state":"ready-for-agent","recut_refused_at":"2026-11-11T10:00:00Z"}' > "$AGENT_HOME/state/6292.json"
reconcile_size_recuts
[[ "$(field issue-6292 .stage)" == implement-pending ]] || fail "first round trip must resume the unit: $(jq -c '.units' "$UNITS")"
[[ "$(field issue-6292 .size_recut_roundtrips)" == 1 ]] || fail "first round trip must count 1: $(jq -c '.units' "$UNITS")"

# Admission sends the same unit to recut again (the write-start path), then recut refuses it a second time.
set_unit issue-6292 "$(hist size-recut "issue #6292: 720 lines exceed 640; head=bbb222") | .stage=\"blocked-external\" | .size_recut_pending=true"
printf '%s\n' '{"state":"ready-for-agent","recut_refused_at":"2026-11-12T10:00:00Z"}' > "$AGENT_HOME/state/6292.json"
reconcile_size_recuts

# Round trip 2: the unit stops at supervisor-review with the size numbers and is not resumed.
[[ "$(field issue-6292 .stage)" == supervisor-review ]] || fail "second round trip must stop at supervisor-review: $(jq -c '.units' "$UNITS")"
[[ "$(field issue-6292 .note)" == "recut refused 2 times; size estimate 720 > limit 640" ]] \
  || fail "second round trip must name the refusals and sizes: $(field issue-6292 .note)"
[[ "$(field issue-6292 '[.history[] | select(.stage == "size-recut-resumed")] | length')" == 1 ]] \
  || fail "second round trip must not resume the unit: $(field issue-6292 '[.history[].stage]' | tr -d '\n')"
[[ "$(field issue-6292 .size_recut_roundtrips)" == 2 ]] || fail "second round trip must count 2"
# Waiver alone (row 451, head 15:21Z): an implement unit that is past the limit gets .size_waiver without leaving its stage,
# and the next size admission reads the raised limit. Only *-pending and implement units take it; parked ones need requeue.
jq -n '{units:[{id:"issue-6300",issue:6300,branch:"agent/issue-6300",stage:"implement-pending",history:[]}]}' > "$UNITS"
printf '%s\n' '{"state":"ready-for-agent","recut_rounds":2}' > "$AGENT_HOME/state/6300.json"
rc=0; rule_entry issue-6300 waiver 6300 "owner: size limit for this round" "" 1000 owner || rc=$?
[[ "$rc" == 0 ]] || fail "waiver alone must be accepted on an implement unit: rc=$rc"
[[ "$(field issue-6300 .stage)" == implement-pending ]] || fail "waiver alone must not change the stage: $(field issue-6300 .stage)"
[[ "$(field issue-6300 .size_waiver.max_lines)" == 1000 ]] || fail "waiver alone must write .size_waiver: $(field issue-6300 .size_waiver)"
[[ "$(field issue-6300 '.history[-1].stage')" == size-waiver ]] || fail "waiver alone must log one size-waiver event: $(field issue-6300 '[.history[].stage]' | tr -d '\n')"
[[ "$(jq -r '.recut_rounds' "$AGENT_HOME/state/6300.json")" == 0 ]] || fail "a waiver must clear the issue recut round count"
[[ "$(size_admission_limit_for "$(jq -c '.units[0]' "$UNITS")")" == 1000 ]] || fail "the next size admission must use the waived limit"
set_unit issue-6300 '.stage="parked"'
rc=0; rule_entry issue-6300 waiver 6300 "owner: size limit" "" 1000 owner >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 && "$(field issue-6300 .stage)" == parked ]] || fail "waiver alone must refuse a parked unit and leave it parked"
echo "size-recut-cap.test.sh: ok"
