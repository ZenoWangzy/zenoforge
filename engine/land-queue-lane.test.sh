#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp="$test_env_root/land-queue-lane"
repo="$tmp/repo"
live_engine="$tmp/live-engine"
output="$tmp/output"
request="$tmp/request.json"
mkdir -p "$repo" "$live_engine"
source "$root/engine/land-queue-lane.sh"
cat > "$live_engine/land-direct-main.sh" <<'SH'
printf '%s\n' "$PWD" "$AGENT_HOME" "$ZF_REPO_DIR" "$REPO_DIR" \
  "$ZF_LAND_RESULT_DIR" "$PLAN_PACKAGE" "$ZF_AGENT_NAME" "$ZF_AGENT_ISSUES" \
  "$ZF_AGENT_REPORT" "$ZF_TEST_LEASE_HELD" "$#" "$@"
SH
chmod +x "$live_engine/land-direct-main.sh"
jq -n '{owned_issues:"26"}' > "$request"
export AGENT_HOME="$tmp/agent-home"
export ZF_ENGINE_LIVE="$live_engine"
export ZF_COORD_LAND_LANE_WAIT_SECONDS=3
export ZF_TEST_LEASE_HELD=0
unset ZF_AGENT_NAME ZF_AGENT_REPORT
owner=queue-owner
report="$tmp/report"
result_dir="$tmp/results"
queue_source_lib() { :; }
coord_lane_run() {
  [[ "$1" == land && "$2" == 3 && "$3" == queue_run_lander_owned ]] || return 91
  export ZF_TEST_LEASE_HELD=1
  shift 3
  queue_run_lander_owned "$@"
}
queue_run_lander "$repo" package "$output" --ticket 26
mapfile -t observed < "$output"
expected=(
  "$repo"
  "$AGENT_HOME"
  "$repo"
  "$repo"
  "$result_dir"
  package
  queue-owner
  26
  "$report"
  1
  2
  --ticket
  26
)
[[ "${observed[*]}" == "${expected[*]}" ]]
