#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
target="$tmp/target/.zenoforge"
pack="$tmp/pack"
mkdir -p "$target/prompts" "$pack/prompts"
printf 'target batch prompt\n' > "$target/prompts/advisor-batch.md"
printf 'pack batch prompt\n' > "$pack/prompts/advisor-batch.md"
printf 'target single prompt\n' > "$target/prompts/advisor.md"
printf 'pack single prompt\n' > "$pack/prompts/advisor.md"
printf '{"target":true}\n' > "$target/prompts/advisor.schema.json"
printf '{"pack":true}\n' > "$pack/prompts/advisor.schema.json"
cat > "$target/night.json" <<'JSON'
{"advisor":{"provider":"web-advisor-provider","prompts":{"single":"prompts/advisor.md","batch":"prompts/advisor-batch.md"},"schemas":{"single":"prompts/advisor.schema.json"},"labels":{"queue":"target-queue","priority":"target-priority"}}}
JSON
cat > "$pack/night.json" <<'JSON'
{"advisor":{"provider":"unused-provider","prompts":{"single":"prompts/pack.md","batch":"prompts/pack-batch.md"},"schemas":{"single":"prompts/pack.schema.json"},"labels":{"queue":"pack-queue","priority":"pack-priority"}}}
JSON
printf 'pack single prompt\n' > "$pack/prompts/pack.md"
printf 'pack batch prompt\n' > "$pack/prompts/pack-batch.md"
printf '{"pack":true}\n' > "$pack/prompts/pack.schema.json"

ZF_CONFIG_ROOT="$target" ZF_PACK_DIR="$pack" bash -c '
  source "$1/advisor-config.sh"
  model_policy() { [[ "$1 $2" == "identity advisor" ]] && printf "web:fixture-model\\n"; }
  advisor_provider_ready
  [[ "$(advisor_prompt_file batch)" == "$ZF_CONFIG_ROOT/prompts/advisor-batch.md" ]]
  [[ "$(advisor_prompt_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.md" ]]
  [[ "$(advisor_schema_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.schema.json" ]]
  [[ "$(advisor_queue_label)" == target-queue ]]
  [[ "$(advisor_priority_label)" == target-priority ]]
  grep -Fq "target batch prompt" "$(advisor_prompt_file batch)"
  ! grep -Fq "pack batch prompt" "$(advisor_prompt_file batch)"
' _ "$script_dir"

# PR #189 made every poll persist provider incident diagnostics before the
# status handling, so advisor_batch_poll_provider_job() now calls
# advisor_batch_capture_provider_diagnostics(); extract both real functions
# and give the capture step the tick globals production sets.
eval "$(sed -n '/^advisor_batch_capture_provider_diagnostics() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_poll_provider_job() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
LOG_DIR="$tmp/logs"
ADVISOR_TICK_ID="fixture-tick"
WEB_ADVISOR_PROVIDER_JOB_DIR="$tmp/jobs"
BATCH_JOB_ID="fixture-job"
mkdir -p "$LOG_DIR" "$WEB_ADVISOR_PROVIDER_JOB_DIR"
web_advisor_provider_poll() {
  [[ "$1" == fixture-job ]]
  printf '%s\n' '{"is_error":false,"structured_output":"{\"kind\":\"advisor_batch_result\"}"}'
}
[[ "$(advisor_batch_poll_provider_job fixture-job)" == '{"kind":"advisor_batch_result"}' ]]
[[ -f "$LOG_DIR/$ADVISOR_TICK_ID.advisor-diagnostics.json" ]]
[[ "$(jq -c '.error_codes' "$LOG_DIR/$ADVISOR_TICK_ID.advisor-diagnostics.json")" == '[]' ]]
web_advisor_provider_poll() { return 2; }
set +e
advisor_batch_poll_provider_job fixture-job >/dev/null 2>&1
poll_status=$?
set -e
[[ "$poll_status" == 2 ]]

# 2026-11-04: ADVISOR_MODEL_UNVERIFIED at selector stage open-picker is a
# browser/page fault, not a payload fault. It must not quarantine the batch
# prompt (record_web_advisor_provider_fault already cools the advisor stage
# and canary-lifts on recovery), or the next canary tick reports
# prompt-quarantined and sends nothing even after the browser recovers.
# A real wedge failure still quarantines the exact prompt.
eval "$(sed -n '/^advisor_batch_is_wedge_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_browser_fault() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_size_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_empty_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_split_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_should_quarantine_prompt() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_file_active() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_contains() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_inbox_notice() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_wedge() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
ADVISOR_BATCH_QUARANTINE_DIR="$tmp/quarantine/advisor-batch"
ADVISOR_BATCH_QUARANTINE_TTL_SECONDS=900
supervisor_inbox_append() { :; }

model_unverified_detail='ADVISOR_MODEL_UNVERIFIED: could not verify the selected model at selector stage open-picker'
advisor_batch_is_browser_fault "$model_unverified_detail"
! advisor_batch_should_quarantine_prompt "$model_unverified_detail"
# The incident's job never wrote done within its ceiling, so its answer.err
# tail carried the browser fault alongside a termination marker; neither
# quarantine call site may fire for it.
timeout_detail="job exceeded 5400s: $model_unverified_detail Terminated"
advisor_batch_is_browser_fault "$timeout_detail"
! advisor_batch_should_quarantine_prompt "$timeout_detail"
[[ -z "$(ls -A "$ADVISOR_BATCH_QUARANTINE_DIR" 2>/dev/null)" ]]

wedge_prompt_sig="$(printf 'a1%.0s' {1..32})"
wedge_detail='ADVISOR_TAB_UNRESPONSIVE: the batch tab stopped responding to CDP'
! advisor_batch_is_browser_fault "$wedge_detail"
advisor_batch_should_quarantine_prompt "$wedge_detail"
# A measured size failure is a payload fault and stays quarantined.
advisor_batch_should_quarantine_prompt 'HTTP 413: request entity too large'
advisor_batch_quarantine_wedge fixture-job "$wedge_prompt_sig" "" "$wedge_detail" '#930002' >/dev/null 2>&1
[[ -f "$ADVISOR_BATCH_QUARANTINE_DIR/prompt-$wedge_prompt_sig.json" ]]
advisor_batch_quarantine_contains "$wedge_prompt_sig" ""

mkdir -p "$tmp/disabled/.zenoforge"
printf '{"advisor":{"provider":""}}\n' > "$tmp/disabled/.zenoforge/night.json"
unconfigured_output="$(ZF_CONFIG_ROOT="$tmp/disabled/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$PWD" \
  bash "$script_dir/run-advisor-batch.sh" 2>&1)"
grep -Fq 'skip: advisor provider is not configured' <<< "$unconfigured_output"

echo 'ok - batch advisor uses target prompts and queue settings before pack fallbacks'
