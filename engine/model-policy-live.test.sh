#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$MODEL_POLICY_TEST_REPO/engine/lib.sh"
ps() { printf '%s\n' "$process_row"; }

# Exercise every active Codex identity, not only the usual work role.
while IFS=$'\t' read -r model effort; do
  process_row="0 codex codex exec --cd $HOME/wt/fixture -m $model -c model_reasoning_effort=$effort"
  output="$(model_policy live)"
  [[ "$output" == clean ]] || { echo "FAIL configured identity $model:$effort" >&2; exit 1; }
done < <(jq -r '.roles[] | select(.provider == "codex" and .disabled != true) | [.model, .effort] | @tsv' "$MODEL_POLICY_DEFAULT")

for model in "$(jq -r '.forbidden[0]' "$MODEL_POLICY_DEFAULT")" unconfigured-fixture; do
  process_row="0 codex codex exec --cd $HOME/wt/fixture -m $model -c model_reasoning_effort=$MODEL_POLICY_TEST_WORK_EFFORT"
  if model_policy live; then echo 'FAIL invalid model admitted' >&2; exit 1; fi
done

echo 'PASS model-policy live active roles without fallbacks'
