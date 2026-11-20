#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-config.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

repo="$tmp/repo"
config="$repo/.zenoforge/release.json"
mkdir -p "$(dirname -- "$config")"
export ZF_ENGINE_DIR="$root/engine" ZF_REPO_DIR="$repo" ZF_CONFIG_ROOT="$repo/.zenoforge" ZF_PACK_DIR=""
unset DEPLOY_HOST REGISTRY INFRA_WORKFLOW_REPOSITORY INFRA_BUILD_WORKFLOW INFRA_WORKFLOW_RUN_URL PRODUCTION_URL RELEASE_CONFIG

[[ -f "$root/engine/release/runner.sh" ]] || fail 'engine release runner skeleton is missing'
cat > "$config" <<'JSON'
{
  "release": {
    "deployHost": "deploy.example.invalid",
    "imageRegistry": "registry.example.invalid",
    "infraWorkflowRepository": "example/build-tools",
    "infraBuildWorkflow": "build-images.yml",
    "infraWorkflowRunUrl": "https://build.example.invalid/runs",
    "productionUrl": "https://service.example.invalid"
  }
}
JSON

source "$root/engine/release/runner.sh"
release_runner_load_config
assert_eq "$DEPLOY_HOST" 'deploy.example.invalid' 'deploy host config'
assert_eq "$REGISTRY" 'registry.example.invalid' 'image registry config'
assert_eq "$INFRA_WORKFLOW_REPOSITORY" 'example/build-tools' 'workflow repository config'
assert_eq "$INFRA_BUILD_WORKFLOW" 'build-images.yml' 'workflow name config'
assert_eq "$INFRA_WORKFLOW_RUN_URL" 'https://build.example.invalid/runs' 'workflow run URL config'
assert_eq "$PRODUCTION_URL" 'https://service.example.invalid' 'production URL config'

jq 'del(.release.productionUrl)' "$config" > "$config.next"
mv "$config.next" "$config"
if output="$(release_config_value productionUrl 2>&1)"; then
  fail 'missing release key unexpectedly succeeded'
fi
[[ "$output" == *'.release.productionUrl'* ]] || fail "missing-key error did not name its key: $output"

printf 'PASS: release config reads required target keys and names a missing key\n'
