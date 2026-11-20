#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../" && pwd -P)/test-env.sh"

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
autopilot_dir="$engine_dir/mac-autopilot"
fixture="$test_env_root/stage-exit-routing"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi"
export ZF_CONFIG_ROOT="$fixture/config"
export ZF_REPO="test/repo"
export STAGE_EXIT_GH_LOG="$fixture/gh.log"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$ZF_CONFIG_ROOT" "$AGENT_HOME/state"
cp "$autopilot_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
jq '.switches["roadmap-order"] = false' "$engine_dir/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
: > "$STAGE_EXIT_GH_LOG"
cat > "$test_env_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$STAGE_EXIT_GH_LOG"
case "${1:-}:${2:-}" in
  label:list)
    printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded tracker
    ;;
  issue:list) : ;;
  issue:view)
    if [[ "$*" == *"--json number,labels"* ]]; then
      printf '{"number":%s,"labels":[{"name":"ready-for-agent"}]}\n' "$3"
    elif [[ "$*" == *"-q .labels[].name"* ]]; then
      printf '%s\n' ready-for-agent
    else
      printf '%s\n' '{"labels":[{"name":"ready-for-agent"}]}'
    fi
    ;;
  issue:edit) ;;
  api) printf '[]\n' ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$test_env_bin/gh"

export AUTOPI_TEST_LIBRARY_ONLY=true
source "$autopilot_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

seed_ready() {
  printf '%s\n' '{"state":"ready-for-agent","state_changed_at":"2026-01-01T00:00:00Z"}' \
    > "$AGENT_HOME/state/$1.json"
}
stage_exits() {
  local issue="$1" metrics="$AGENT_HOME/metrics/efficiency-$(date -u +%Y-%m).jsonl"
  [[ -f "$metrics" ]] || { printf '0\n'; return; }
  jq -sr --argjson issue "$issue" \
    '[.[] | select(.event_type == "stage-exited" and .issue == $issue and .stage == "ready-for-agent")] | length' \
    "$metrics"
}
stage_enters() {
  local issue="$1" stage="$2" metrics="$AGENT_HOME/metrics/efficiency-$(date -u +%Y-%m).jsonl"
  jq -sr --argjson issue "$issue" --arg stage "$stage" \
    '[.[] | select(.event_type == "stage-entered" and .issue == $issue and .stage == $stage)] | length' \
    "$metrics"
}
check_exit() {
  local issue="$1" target="$2" count
  count="$(stage_exits "$issue")"
  [[ "$count" == 1 ]] || { echo "not ok - #$issue -> $target wrote $count ready-for-agent stage-exited events" >&2; return 1; }
  [[ "$(stage_enters "$issue" "$target")" == 1 ]] \
    || { echo "not ok - #$issue transition did not enter $target once" >&2; return 1; }
  echo "ok - ready-for-agent -> $target writes one stage-exited event"
}

failures=0
seed_ready 5310
if ! scheduler_issue_transition 5310 tracker recut-parent-retired; then
  echo 'not ok - ready-for-agent -> tracker transition failed' >&2
  failures=$((failures + 1))
elif ! check_exit 5310 tracker; then
  failures=$((failures + 1))
fi

seed_ready 5311
if ! scheduler_route_to_recut 5311; then
  echo 'not ok - ready-for-agent -> needs-recut transition failed' >&2
  failures=$((failures + 1))
elif ! check_exit 5311 needs-recut; then
  failures=$((failures + 1))
fi
(( failures == 0 ))
