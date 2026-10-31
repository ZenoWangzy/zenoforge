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

eval "$(sed -n '/^advisor_batch_poll_provider_job() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
web_advisor_provider_poll() {
  [[ "$1" == fixture-job ]]
  printf '%s\n' '{"is_error":false,"structured_output":"{\"kind\":\"advisor_batch_result\"}"}'
}
[[ "$(advisor_batch_poll_provider_job fixture-job)" == '{"kind":"advisor_batch_result"}' ]]
web_advisor_provider_poll() { return 2; }
set +e
advisor_batch_poll_provider_job fixture-job >/dev/null 2>&1
poll_status=$?
set -e
[[ "$poll_status" == 2 ]]

mkdir -p "$tmp/disabled/.zenoforge"
printf '{"advisor":{"provider":""}}\n' > "$tmp/disabled/.zenoforge/night.json"
unconfigured_output="$(ZF_CONFIG_ROOT="$tmp/disabled/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$PWD" \
  bash "$script_dir/run-advisor-batch.sh" 2>&1)"
grep -Fq 'skip: advisor provider is not configured' <<< "$unconfigured_output"

echo 'ok - batch advisor uses target prompts and queue settings before pack fallbacks'
