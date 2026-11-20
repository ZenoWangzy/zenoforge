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
  {"number":401,"title":"optimizer ticket","state":"OPEN","labels":[{"name":"focus"},{"name":"opt-lane"},{"name":"hotfix"}]},
  {"number":403,"title":"session-owned ready ticket","state":"OPEN","labels":[{"name":"ready-for-agent"},{"name":"session-owned"}]}
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

CFG='{"issue_intake":{"labels":["founder-test","priority:top","focus"],"product_labels":["ready-for-agent"]}}'
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
# A ready-for-agent issue carrying session-owned is not a candidate and is reported as a label skip.
[[ "$(grep -c 'intake skip issue #403: skip label session-owned' "$LOG")" == 1 ]] || {
  printf 'intake-auto-filed.test.sh: session-owned skip not logged once: %s\n' "$(cat "$LOG")" >&2
  exit 1
}
# The ready queue orders by ready-state age within a priority band and
# promotes a ticket one band after the threshold.
now_epoch="$(date -u +%s)"
aged_at="$(date -u -d "@$((now_epoch - 76 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
band_old_at="$(date -u -d "@$((now_epoch - 24 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
fresh_band_at="$(date -u -d "@$((now_epoch - 2 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
priority_fresh_at="$(date -u -d "@$((now_epoch - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$AGENT_HOME/state"
jq -cn --arg aged "$aged_at" --arg band_old "$band_old_at" \
  --arg fresh "$fresh_band_at" --arg priority_fresh "$priority_fresh_at" '[
    {number:701,title:"aged normal",state:"OPEN",labels:[{name:"ready-for-agent"},{name:"auto-filed"}],createdAt:$aged,updatedAt:$aged},
    {number:702,title:"fresh bug",state:"OPEN",labels:[{name:"ready-for-agent"},{name:"bug"}],createdAt:$priority_fresh,updatedAt:$priority_fresh},
    {number:714,title:"older normal",state:"OPEN",labels:[{name:"ready-for-agent"}],createdAt:$band_old,updatedAt:$band_old},
    {number:715,title:"newer normal",state:"OPEN",labels:[{name:"ready-for-agent"}],createdAt:$fresh,updatedAt:$fresh}
  ]' > "$INTAKE_ISSUES_FILE"
for entry in "701:$aged_at" "702:$priority_fresh_at" "714:$band_old_at" "715:$fresh_band_at"; do
  issue="${entry%%:*}"
  ready_at="${entry#*:}"
  jq -cn --arg at "$ready_at" '{state:"ready-for-agent",state_changed_at:$at}' > "$AGENT_HOME/state/$issue.json"
done
CFG='{"issue_intake":{"labels":[],"product_labels":["ready-for-agent"],"aging_hours":75}}'
aged_numbers="$(intake_candidates false | cut -f1)"
position() { awk -v issue="$1" '$0 == issue { print NR; exit }' <<<"$aged_numbers"; }
failures=0
older_position="$(position 714)"
newer_position="$(position 715)"
if [[ -n "$older_position" && -n "$newer_position" ]] && (( older_position < newer_position )); then
  echo 'ok - older ticket is picked first within its priority band'
else
  printf 'not ok - same-band aging order is wrong: %s\n' "$(paste -sd, <<<"$aged_numbers")" >&2
  failures=$((failures + 1))
fi
aged_position="$(position 701)"
priority_position="$(position 702)"
if [[ -n "$aged_position" && -n "$priority_position" ]] && (( aged_position < priority_position )); then
  echo 'ok - a ticket past AGING_HOURS outranks a fresh ticket of the next band up'
else
  printf 'not ok - priority aging order is wrong: %s\n' "$(paste -sd, <<<"$aged_numbers")" >&2
  failures=$((failures + 1))
fi
[[ "$(jq -r '.issue_intake.aging_hours' "$script_dir/config.template.json")" == 75 ]] \
  || { echo 'not ok - default issue_intake.aging_hours is not 75' >&2; failures=$((failures + 1)); }
(( failures == 0 ))
echo 'intake-auto-filed.test.sh: PASS'
