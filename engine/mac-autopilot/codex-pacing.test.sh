#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 "$script_dir/codex_pacing.test.py"
bash -n "$script_dir/scheduler.sh" "$script_dir/scheduler.d/models.sh" "$script_dir/scheduler.d/dispatch.sh"

source "$script_dir/scheduler.d/models.sh"
source "$script_dir/scheduler.d/dispatch.sh"
jqf() { command jq "$@"; }
log_file="$(mktemp)"
calls_file="$(mktemp)"
UNITS="$(mktemp)"
trap 'rm -f "$log_file" "$calls_file" "$UNITS"' EXIT
say() { printf '%s\n' "$*" >> "$log_file"; }
unit_field() { printf '\n'; }
build_codex_command() { printf '%s\n' "$4" >> "$calls_file"; return 1; }
LIVE_WORKER_CACHE_UNTIL=0
printf '%s\n' '{"units":[{"id":"normal"},{"id":"urgent","hotpatch":true,"labels":["hotfix"]}]}' > "$UNITS"
CODEX_PACING_HOLD=true
CODEX_PACING_HOLD_LOGGED=false
CODEX_PACING_PROJECTED=120
CODEX_PACING_USED=60
CODEX_PACING_RESET=2026-11-09T17:33:00Z
normal_unit='{"id":"normal"}'
hotfix_unit='{"id":"urgent","hotpatch":true,"labels":["hotfix"]}'

codex_pacing_should_hold_unit_json "$normal_unit" || {
  echo 'not ok - normal Codex unit was not held above the projected threshold' >&2
  exit 1
}
if codex_pacing_should_hold_unit_json "$hotfix_unit"; then
  echo 'not ok - hotfix Codex unit was held by pacing' >&2
  exit 1
fi
dispatch implement model max normal log report prompt '' "$PWD" '' '' codex || :
dispatch implement model max normal log report prompt '' "$PWD" '' '' codex || :
dispatch implement model max urgent log report prompt '' "$PWD" '' '' codex || :
[[ "$(cat "$calls_file")" == urgent ]] || {
  echo "not ok - dispatch gate did not hold normal Codex work and admit hotfix: $(cat "$calls_file")" >&2
  exit 1
}
[[ "$(grep -c '^codex-pacing hold ' "$log_file")" == 1 ]] || {
  echo 'not ok - pacing did not log exactly once per tick' >&2
  exit 1
}
CODEX_PACING_HOLD=false
if codex_pacing_should_hold_unit_json "$normal_unit"; then
  echo 'not ok - under-threshold Codex unit was held' >&2
  exit 1
fi
dispatch implement model max normal log report prompt '' "$PWD" '' '' codex || :
[[ "$(tail -n1 "$calls_file")" == normal ]] || {
  echo 'not ok - under-threshold dispatch did not reach the launch path' >&2
  exit 1
}

zcode_bin="$(mktemp -d)"
printf '#!/usr/bin/env sh\nexit 0\n' > "$zcode_bin/zcode"
chmod +x "$zcode_bin/zcode"
export PATH="$zcode_bin:$PATH"
NOW_EPOCH="$(date +%s)"
ZCODE_QUOTA_SNAPSHOT_FILE="$(mktemp)"
ZCODE_EXHAUSTED_MARKER_FILE="$(mktemp)"
trap 'rm -f "$log_file" "$calls_file" "$UNITS" "$ZCODE_QUOTA_SNAPSHOT_FILE" "$ZCODE_EXHAUSTED_MARKER_FILE"; rm -rf "$zcode_bin"' EXIT
rm -f "$ZCODE_EXHAUSTED_MARKER_FILE"
printf '{"five_h_pct":1,"week_pct":1,"cap_5h":85,"max_age_seconds":900,"freshness":"fresh","read_at":%s}\n' "$NOW_EPOCH" > "$ZCODE_QUOTA_SNAPSHOT_FILE"
SCHED_MODEL_POLICY_JSON='{"roles":{"hand-zcode":{"provider":"zcode","model":"GLM-5.3","effort":"max"}}}'
model_policy_model_allowed_for_role() { return 0; }
zcode_provider_config_model_matches() { return 0; }
provider_quota_exhausted() { return 1; }
cooling() { return 1; }
CODEX_PACING_HOLD=true
CODEX_PACING_HOLD_LOGGED=false
paced_implement='{"id":"paced-implement","issue":123,"stage":"implement-pending"}'
pick implement "$paced_implement" || {
  echo 'not ok - projected Codex overrun did not route implementation to available Zcode' >&2
  exit 1
}
[[ "$PICK_PROVIDER" == zcode && "$PICK_ROUTE_PROVIDER" == zcode && "$PICK_REASON" == codex-pacing-zcode ]] || {
  echo 'not ok - projected Codex overrun did not record the Zcode route' >&2
  exit 1
}
rm -f "$ZCODE_QUOTA_SNAPSHOT_FILE"
CODEX_PACING_HOLD_LOGGED=false
if pick implement "$paced_implement"; then
  echo 'not ok - projected Codex overrun fell back to Codex without a fresh Zcode quota' >&2
  exit 1
fi
[[ "$(grep -c '^codex-pacing hold ' "$log_file")" == 2 ]] || {
  echo 'not ok - unavailable Zcode route did not emit one pacing hold line' >&2
  exit 1
}
printf 'PASS scheduler holds normal Codex work, exempts hotfix, and routes implementation to available Zcode\n'
