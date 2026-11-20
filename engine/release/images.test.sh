#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-images.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

repo="$tmp/repo"
mkdir -p "$repo/.zenoforge"
export ZF_ENGINE_DIR="$root/engine" ZF_REPO_DIR="$repo" ZF_CONFIG_ROOT="$repo/.zenoforge" ZF_PACK_DIR=""
cat > "$repo/.zenoforge/release.json" <<'JSON'
{"release":{"deployHost":"deploy.example.invalid","imageRegistry":"registry.example.invalid","infraWorkflowRepository":"example/build-tools","infraBuildWorkflow":"build-images.yml","infraWorkflowRunUrl":"https://build.example.invalid/runs","productionUrl":"https://service.example.invalid"}}
JSON

source "$root/engine/release/runner.sh"
release_runner_load_config
declare -A RELEASE_DESIRED_IDS=() RELEASE_IMAGE_TAGS=()
DIFF_CHANGED_IMAGES=$'api\nweb'
[[ "$(image_inputs_changed_in_release api && echo yes)" == yes ]] || fail 'selected image was not found'
[[ "$(image_inputs_changed_in_release api-worker && echo yes || true)" != yes ]] || fail 'image selection matched a substring'

remote_trace="$tmp/remote.trace"
: > "$remote_trace"
remote() { printf '%s\n' "$1" >> "$remote_trace"; printf 'sha256:lookup-result\n'; }
RELEASE_DESIRED_IDS[api]='sha256:desired-result'
assert_eq "$(expected_image_id api)" 'sha256:desired-result' 'preselected image id'
[[ ! -s "$remote_trace" ]] || fail 'preselected image id made a remote call'

unset 'RELEASE_DESIRED_IDS[api]'
RELEASE_IMAGE_TAGS[api]='release-tag'
assert_eq "$(expected_image_id api)" 'sha256:lookup-result' 'registry image lookup'
assert_eq "$(cat "$remote_trace")" "docker image inspect -f '{{.Id}}' 'registry.example.invalid/api:release-tag'" 'registry lookup command'

printf 'PASS: changed-image selection and expected image lookup use supplied release inputs\n'
