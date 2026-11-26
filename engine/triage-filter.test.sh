#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT" "$test_env_root"' EXIT
export AGENT_HOME="$TEST_ROOT/agent" REPO="test/repo" REPO_DIR="$TEST_ROOT/repo" ZF_REPO_DIR="$TEST_ROOT/repo"
export ZF_CONFIG_ROOT="$TEST_ROOT/config" MAC_AUTOPILOT_RUNTIME_DIR="$TEST_ROOT/runtime"
export MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json" TRIAGE_FILTER_FIXTURE="$SCRIPT_DIR/mac-autopilot/triage-fixture.json"
mkdir -p "$AGENT_HOME/state" "$REPO_DIR" "$ZF_CONFIG_ROOT/state" "$MAC_AUTOPILOT_RUNTIME_DIR" "$TEST_ROOT/bin"
cp "$SCRIPT_DIR/state/rulings.json" "$ZF_CONFIG_ROOT/state/rulings.json"
jq '.switches["roadmap-order"] = false' "$SCRIPT_DIR/model-policy.default.json" > "$MODEL_POLICY_FILE"
jq -n --argjson until "$(( $(date +%s) + 3600 ))" '{model_failure_backoff:{until_epoch:$until}}' > "$AGENT_HOME/state/1004.json"
jq -n --argjson until "$(( $(date +%s) + 3600 ))" '{triage_retry_after_epoch:$until}' > "$AGENT_HOME/state/1005.json"
jq -n '{units:[{id:"issue-805",issue:805,stage:"implement-pending"}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
echo '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
cat > "$TEST_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$TRIAGE_FILTER_FIXTURE"
SH
chmod +x "$TEST_ROOT/bin/gh"
cat > "$TEST_ROOT/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --user && "${2:-}" == list-units ]]; then
  if [[ -n "${TRIAGE_FILTER_ACTIVE_UNIT:-}" ]]; then
    printf '%s loaded active running fixture\n' "$TRIAGE_FILTER_ACTIVE_UNIT"
  fi
  exit 0
fi
exit 1
SH
chmod +x "$TEST_ROOT/bin/systemctl"
export PATH="$TEST_ROOT/bin:$PATH"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib.d/triage-filter.sh"
eligible="$(triage_filter_issues_json "$(cat "$TRIAGE_FILTER_FIXTURE")" | jq -r '.[].number')"
[[ "$eligible" == $'1000\n1006' ]] || { printf 'triage-filter.test.sh: unexpected dispatcher set %s\n' "$eligible" >&2; exit 1; }
count="$(triage_needs_queue_selectable_count)"
jq -n '{issues:[1000,1006]}' > "$AGENT_HOME/triage-batch-active.json"
export TRIAGE_FILTER_ACTIVE_UNIT=zf-triage-batch.service
active_eligible="$(triage_filter_issues_json "$(cat "$TRIAGE_FILTER_FIXTURE")" | jq -r '.[].number')"
[[ -z "$active_eligible" ]] || { printf 'triage-filter.test.sh: active batch markers left candidates %s\n' "$active_eligible" >&2; exit 1; }
active_count="$(triage_needs_queue_selectable_count)"
[[ "$active_count" == 0 ]] || { printf 'triage-filter.test.sh: active batch count should be 0, got %s\n' "$active_count" >&2; exit 1; }
export TRIAGE_FILTER_ACTIVE_UNIT=zf-triage-batch-owner-test.service
mv "$AGENT_HOME/triage-batch-active.json" "$AGENT_HOME/triage-batch-active-owner-test.json"
dynamic_eligible="$(triage_filter_issues_json "$(cat "$TRIAGE_FILTER_FIXTURE")" | jq -r '.[].number')"
[[ -z "$dynamic_eligible" ]] || { printf 'triage-filter.test.sh: dynamic active batch markers left candidates %s\n' "$dynamic_eligible" >&2; exit 1; }
TRIAGE_FILTER_ACTIVE_UNIT=""
stale_marker_eligible="$(triage_filter_issues_json "$(cat "$TRIAGE_FILTER_FIXTURE")" | jq -r '.[].number')"
[[ "$stale_marker_eligible" == $'1000\n1006' ]] || { printf 'triage-filter.test.sh: stale marker excluded candidates %s\n' "$stale_marker_eligible" >&2; exit 1; }
[[ "$count" == 2 ]] || { printf 'triage-filter.test.sh: expected shared batch count 2, got %s\n' "$count" >&2; exit 1; }
echo "triage-filter.test.sh: PASS"
