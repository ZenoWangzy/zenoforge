#!/usr/bin/env bash
# A policy view used during validation must be the version installed live.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
repo="$tmp/repo"
remote="$tmp/origin.git"
agent_home="$tmp/agent"
mkdir -p "$repo/engine" "$agent_home"
git init -q --bare -b main "$remote"
git -C "$repo" init -q -b main
git -C "$repo" config user.name 'Policy Test'
git -C "$repo" config user.email policy-test@example.invalid
cp "$engine/model-policy.default.json" "$repo/engine/model-policy.default.json"
git -C "$repo" add engine/model-policy.default.json
git -C "$repo" commit -qm 'fixture default'
git -C "$repo" remote add origin "$remote"
git --git-dir="$remote" fetch -q "$repo" main:refs/heads/main
export ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_PACK_DIR="$repo/engine" ZF_PACK_REL=engine AGENT_HOME="$agent_home"
live="$agent_home/model-policy.json"
jq '.switches["roadmap-order"] = (.switches["roadmap-order"] | not)' \
  "$repo/engine/model-policy.default.json" > "$live"
cp "$live" "$tmp/previous.json"
bash "$engine/apply-model-policy-default.sh" > "$tmp/apply.log"
if [[ "$(jq -Sc . "$live")" != "$(jq -Sc . "$repo/engine/model-policy.default.json")" ]]; then
  echo 'not ok - applied policy did not contain the validated landed default' >&2
  exit 1
fi
backups=("$agent_home"/model-policy.json.bak.*)
[[ ${#backups[@]} == 1 ]] && cmp -s "$tmp/previous.json" "${backups[0]}"
[[ "$(stat -c '%a' "$live")" == 600 ]]
echo 'ok - migrated policy view is installed and the previous live bytes are backed up'
