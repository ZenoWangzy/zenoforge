#!/usr/bin/env bash
# open_main_red_unit reads $AGENT_HOME/main-red/<sha>.json before the bisect session writes it. A missing file
# means "no bisect session": the unit must open with no jqf error logged. A bisecting session must defer it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/main-red-optional-file"
rm -rf "$fixture"; mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent/main-red"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.precheck = false' "$engine_dir/mac-autopilot/config.template.json" > "$fixture/supervisor/autopi/config.json"
echo '{"units":[]}' > "$fixture/supervisor/autopi/units.json"
echo '{"workers":[]}' > "$fixture/supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
export AGENT_HOME="$fixture/agent"

fail() { echo "main-red-optional-file.test.sh: $*" >&2; exit 1; }
sha=1111111111111111111111111111111111111111
A="$fixture/supervisor/autopi"; LOG="$fixture/scheduler.log"; STAMP="2026-11-17T00:00:00Z"
UNITS="$fixture/units.json"; echo '{"units":[]}' > "$UNITS"
updates="$fixture/updates"; : > "$updates"
main_gate_workflow() { echo ci; }
main_red_lane_ready() { return 0; }
gh() { echo 'FAILED suite=fixture.test.sh exit_code=1 first_error=boom'; }
units_update() { printf 'update\n' >> "$updates"; }

# 1. no recovery file: the unit opens, and no jqf error is logged for the absent file
rm -f "$AGENT_HOME/main-red/$sha.json"; : > "$LOG"
open_main_red_unit "$sha" 41 1 || fail "missing recovery file: open_main_red_unit returned $?"
grep -q "opened main-red-${sha:0:9}" "$LOG" || fail "unit not opened: $(cat "$LOG")"
! grep -q 'jqf error' "$LOG" || fail "missing recovery file logged: $(grep 'jqf error' "$LOG")"

# 2. bisecting session for this sha: the unit is deferred, nothing is opened
jq -cn --arg sha "$sha" '{red_sha:$sha, red_workflow:"pipeline-suites.yml", status:"bisecting"}' > "$AGENT_HOME/main-red/$sha.json"
: > "$LOG"; : > "$updates"
open_main_red_unit "$sha" 41 1 || fail "bisecting session: open_main_red_unit returned $?"
grep -q "deferred to the Pipeline suites bisect session" "$LOG" || fail "bisecting session not deferred: $(cat "$LOG")"
[[ ! -s "$updates" ]] || fail "bisecting session still opened a unit"

echo 'main-red-optional-file.test.sh: PASS'
