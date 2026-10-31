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

# The target config policy wins, and fast-forward notices its path instead of the old pack path.
old_head="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/.zenoforge/mac-autopilot"
jq '.switches["roadmap-order"] = true' "$repo/engine/model-policy.default.json" \
  > "$repo/.zenoforge/model-policy.default.json"
printf '{"required":["Config required check"]}\n' \
  > "$repo/.zenoforge/mac-autopilot/required-pr-checks.json"
git -C "$repo" add .zenoforge
git -C "$repo" commit -qm 'fixture: add target policy overrides'
new_head="$(git -C "$repo" rev-parse HEAD)"
git --git-dir="$remote" fetch -q "$repo" "$new_head"
git --git-dir="$remote" update-ref refs/heads/main "$new_head"
source "$engine/config.sh"
source "$engine/model-policy-fast-forward.sh"
ZF_ENGINE_LIVE="$engine" sync_model_policy_default_after_fast_forward "$repo" "$agent_home" "$old_head" "$new_head"
if [[ "$(jq -Sc . "$live")" != "$(jq -Sc . "$repo/.zenoforge/model-policy.default.json")" ]]; then
  echo 'not ok - fast-forward did not apply the changed target config policy' >&2
  exit 1
fi
resolved_checks="$(MODEL_POLICY_SOURCE_CHECK_ONLY=1 bash -c 'source "$1/lib.sh"; printf "%s" "${REQUIRED_PR_CHECKS[*]}"' _ "$engine")"
[[ "$resolved_checks" == 'Config required check' ]] || {
  echo "not ok - required checks did not resolve target config: $resolved_checks" >&2
  exit 1
}
echo 'ok - target config policy and required checks override the engine defaults'
