#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
target="$tmp/target/.zenoforge"
pack="$tmp/pack"
mkdir -p "$target/prompts" "$pack/prompts"
printf 'target prompt\n' > "$target/prompts/advisor.md"
printf 'pack prompt\n' > "$pack/prompts/advisor.md"
printf '{"target":true}\n' > "$target/prompts/advisor.schema.json"
printf '{"pack":true}\n' > "$pack/prompts/advisor.schema.json"
printf '{"advisor":{"provider":"web-advisor-provider","prompts":{"single":"prompts/advisor.md"},"schemas":{"single":"prompts/advisor.schema.json"},"labels":{"queue":"target-queue"}}}\n' > "$target/night.json"
printf '{"advisor":{"provider":"unused-provider","prompts":{"single":"prompts/pack.md"},"schemas":{"single":"prompts/pack.schema.json"},"labels":{"queue":"pack-queue"}}}\n' > "$pack/night.json"
printf 'pack prompt\n' > "$pack/prompts/pack.md"
printf '{"pack":true}\n' > "$pack/prompts/pack.schema.json"

ZF_CONFIG_ROOT="$target" ZF_PACK_DIR="$pack" bash -c '
  source "$1/advisor-config.sh"
  model_policy() { [[ "$1 $2" == "identity advisor" ]] && printf "web:fixture-model\\n"; }
  advisor_provider_ready
  [[ "$(advisor_prompt_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.md" ]]
  [[ "$(advisor_schema_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.schema.json" ]]
  [[ "$(advisor_queue_label)" == target-queue ]]
  grep -Fq "target prompt" "$(advisor_prompt_file single)"
  ! grep -Fq "pack prompt" "$(advisor_prompt_file single)"
' _ "$script_dir"

set +e
unset_provider_output="$(ZF_CONFIG_ROOT="$tmp/empty/.zenoforge" ZF_PACK_DIR='' bash -c '
  source "$1/advisor-config.sh"
  model_policy() { return 1; }
  advisor_provider_ready
' _ "$script_dir" 2>&1)"
unset_provider_status=$?
set -e
[[ "$unset_provider_status" == 1 ]]
grep -Fq 'skip: advisor provider is not configured' <<< "$unset_provider_output"

mkdir -p "$tmp/disabled/.zenoforge"
printf '{"advisor":{"provider":""}}\n' > "$tmp/disabled/.zenoforge/night.json"
runner_output="$(ZF_CONFIG_ROOT="$tmp/disabled/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$PWD" \
  bash "$script_dir/run-advisor.sh" 930001 2>&1)"
grep -Fq 'skip: advisor provider is not configured' <<< "$runner_output"

echo 'ok - advisor settings use the target config override and skip when the provider is unset'
