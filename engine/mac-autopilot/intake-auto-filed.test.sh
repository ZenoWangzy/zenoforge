#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/intake-auto-filed"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export ZF_CONFIG_ROOT="$fixture/config"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$ZF_CONFIG_ROOT"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
cat > "$ZF_CONFIG_ROOT/night.json" <<'JSON'
{"anomaly_rules":{"production_logs":{"issue_title_prefix":"Configured anomaly: "}}}
JSON
cat > "$fixture/issues.json" <<'JSON'
[
  {"number":101,"title":"founder requirement","state":"OPEN","labels":[{"name":"founder-test"}]},
  {"number":102,"title":"Incident: machine report","state":"OPEN","labels":[{"name":"founder-test"}]},
  {"number":201,"title":"priority requirement","state":"OPEN","labels":[{"name":"priority:top"}]},
  {"number":202,"title":"machine report","state":"OPEN","labels":[{"name":"priority:top"},{"name":"auto-filed"}]},
  {"number":301,"title":"focus requirement","state":"OPEN","labels":[{"name":"focus"}]},
  {"number":302,"title":"Configured anomaly: machine report","state":"OPEN","labels":[{"name":"focus"}]},
  {"number":303,"title":"factory-f2 machine report","state":"OPEN","labels":[{"name":"focus"}]},
  {"number":304,"title":"machine report","state":"OPEN","labels":[{"name":"focus"},{"name":"prod-anomaly"}]},
  {"number":401,"title":"optimizer ticket","state":"OPEN","labels":[{"name":"focus"},{"name":"opt-lane"},{"name":"hotfix"}]}
]
JSON
export INTAKE_ISSUES_FILE="$fixture/issues.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

intake_gh_read() {
  [[ "$1:$2" == issue:list ]] || return 1
  local label="" arg
  shift 2
  while (($#)); do
    arg="$1"
    if [[ "$arg" == --label ]]; then label="${2:-}"; shift 2; else shift; fi
  done
  jq -c --arg label "$label" '[.[] | select(any(.labels[]?; .name == $label))]' "$INTAKE_ISSUES_FILE"
}

CFG='{"issue_intake":{"labels":["founder-test","priority:top","focus"],"product_labels":[]}}'
rows="$(intake_candidates false)"
numbers="$(cut -f1 <<<"$rows" | paste -sd, -)"
expected='101,102,201,202,301,304,303,302'
[[ "$numbers" == "$expected" ]] || {
  printf 'intake-auto-filed.test.sh: expected order %s, got %s\n' "$expected" "$numbers" >&2
  exit 1
}
[[ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" == 8 ]] || {
  echo 'intake-auto-filed.test.sh: auto-filed candidates were blocked' >&2
  exit 1
}
# A skip-label row is dropped, and says why once per 6h, not on every pass.
intake_candidates false >/dev/null
[[ "$(grep -c 'intake skip issue #401: skip label opt-lane,hotfix' "$LOG")" == 1 ]] || {
  printf 'intake-auto-filed.test.sh: skip-label drop not logged once: %s\n' "$(cat "$LOG")" >&2
  exit 1
}
echo 'intake-auto-filed.test.sh: PASS'
