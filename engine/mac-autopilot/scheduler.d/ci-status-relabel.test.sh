#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/ci-status-relabel"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
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

UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=2026-11-20T00:00:00Z
fail() { printf 'ci-status-relabel.test.sh: %s\n' "$*" >&2; exit 1; }

declare -A ISSUE_STATES=([801]=ready-for-agent [802]=on-hold [803]=needs-triage)
calls="$fixture/conclude-calls"; : > "$calls"
tick_prs() { printf '[]'; }
pr_view() { printf 'MERGED'; }
scheduler_issue_state() { printf '{"state":"%s"}\n' "${ISSUE_STATES[$1]}"; }
scheduler_conclude_merged_pr() {
  printf '%s %s\n' "$1" "$2" >> "$calls"
  [[ "${ISSUE_STATES[$1]}" == ready-for-agent ]] || return 1
  ISSUE_STATES[$1]=awaiting-release
}
jq -cn '{units:[
  {id:"issue-801",issue:801,pr:1801,stage:"parked",history:[]},
  {id:"issue-802",issue:802,pr:1802,stage:"parked",history:[]},
  {id:"issue-803",issue:803,pr:1803,stage:"parked",history:[]}
]}' > "$UNITS"

retire_landed_pr_units
[[ "${ISSUE_STATES[801]}" == awaiting-release ]] || fail 'a merged outside-pipeline PR must move a ready-for-agent issue to awaiting-release'
[[ "${ISSUE_STATES[802]}" == on-hold ]] || fail 'an on-hold issue must keep its session-owned state'
[[ "${ISSUE_STATES[803]}" == needs-triage ]] || fail 'a needs-triage issue must keep its session-owned state'
[[ "$(cat "$calls")" == '801 1801' ]] || fail 'only the ready-for-agent issue may use the merged-PR transition'
jq -e 'all(.units[]; .stage == "merged" and .awaiting_release_pending == null and .awaiting_release_ready_only == null)' "$UNITS" >/dev/null \
  || fail 'outside-pipeline merged units must retire and clear their bounded transition marks'

echo 'ci-status-relabel.test.sh: ok'
