#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$engine_dir/advisor-core.sh"

state_json='{"brief_md":"Original implementation brief.","advisor_plan_reask_attempted":true}'
state_read() { printf '%s\n' "$state_json"; }
state_merge() {
  local _issue="$1" filter="$2" _arg="${3:-}" patch_file="${4:-}"
  if [ -n "$patch_file" ]; then
    state_json="$(jq -c --slurpfile state_merge_patch "$patch_file" "$filter" <<< "$state_json")"
  else
    state_json="$(jq -c "$filter" <<< "$state_json")"
  fi
}

plan='{"changes":[{"file":"engine/worker.sh","symbol":"dispatch_worker","change":"Keep the chosen plan intact."}],"tests_fail_first":["bash engine/worker.test.sh --case missing-plan"],"non_goals":["Do not change provider selection."]}'
advisor_store_plan_in_brief 930001 "$plan"

expected_plan="$(jq -c . <<< "$plan")"
jq -e --argjson expected "$expected_plan" '.advisor_plan == $expected and (.brief_md | startswith("Original implementation brief.")) and (.advisor_plan_reask_attempted == null)' <<< "$state_json" >/dev/null
brief="$(jq -r '.brief_md' <<< "$state_json")"
[[ "$brief" == *"$expected_plan"* ]]
[[ "$(grep -Fc '<!-- advisor-plan:start -->' <<< "$brief")" == 1 ]]

echo 'ok - accepted advisor plan is persisted verbatim inside the implementer brief'
