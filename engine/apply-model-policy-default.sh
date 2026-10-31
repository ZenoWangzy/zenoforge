#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh"
REPO_DIR="$(git -C "$ZF_REPO_DIR" rev-parse --show-toplevel)"
policy_file="$(zf_config_file model-policy.default.json)" \
  || { echo 'apply-model-policy-default: model policy default is unavailable' >&2; exit 1; }
if [[ "$policy_file" == "$REPO_DIR/"* ]]; then
  POLICY_PATH="${policy_file#"$REPO_DIR"/}"
else
  POLICY_PATH="${ZF_PACK_REL:-engine}/model-policy.default.json"
fi
LIVE_FILE="$AGENT_HOME/model-policy.json"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/apply-model-policy.XXXXXX")"
install_tmp=""
trap 'rm -rf -- "$tmp_dir"; [[ -z "$install_tmp" ]] || rm -f -- "$install_tmp"' EXIT

git -C "$REPO_DIR" fetch origin main
git -C "$REPO_DIR" show "origin/main:$POLICY_PATH" > "$tmp_dir/landed-policy.json"
if ! cmp -s "$policy_file" "$tmp_dir/landed-policy.json"; then
  echo "apply-model-policy-default: checkout default is not the landed origin/main default" >&2
  exit 1
fi

[[ -f "$LIVE_FILE" ]] || { echo "apply-model-policy-default: live policy missing; cannot back it up" >&2; exit 1; }
validation_home="$tmp_dir/validation-home"
mkdir -p -- "$validation_home"
cp -- "$LIVE_FILE" "$validation_home/model-policy.json"
(
  export AGENT_HOME="$validation_home" ZF_REPO_DIR="$REPO_DIR"
  while IFS= read -r variable; do
    [[ "$variable" == AGENT_MODEL* ]] && unset "$variable"
  done < <(compgen -e)
  source "$SCRIPT_DIR/lib.sh"
  # This command validates and publishes the durable policy itself. Do not let
  # lib.sh redirect migration into its compatibility view; that would leave
  # the raw file schema-less while the caller later copies it back unchanged.
  MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
  model_policy_migrate_live 1
  model_policy source-check
  model_policy_validate_file "$MODEL_POLICY_FILE"
  for role in work production; do
    expected_identity="$(jq -er --arg role "$role" '.roles[$role] as $r | "codex:" + $r.model + ":" + $r.effort' "$tmp_dir/landed-policy.json")"
    expected_tier="$(jq -r --arg role "$role" '.roles[$role].service_tier // empty' "$tmp_dir/landed-policy.json")"
    actual_identity="$(model_policy identity "$role")"
    actual_tier="$(model_policy tier "$role")"
    [[ "$actual_identity" == "$expected_identity" && "$actual_tier" == "$expected_tier" ]] || {
      echo "apply-model-policy-default: $role resolution differs from landed policy" >&2
      exit 1
    }
    printf '%s\t%s\t%s\n' "$role" "$actual_identity" "$actual_tier"
  done
)
# Forced migration selects the landed default, which was compared with the
# resolved config file and validated above. lib.sh may migrate a derived policy view, so
# validation-home/model-policy.json is not necessarily the migrated file.
cp -- "$tmp_dir/landed-policy.json" "$tmp_dir/migrated-policy.json"

backup="$LIVE_FILE.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
cp -p -- "$LIVE_FILE" "$backup"
install_tmp="$(mktemp "$AGENT_HOME/.model-policy.json.XXXXXX")"
cp -- "$tmp_dir/migrated-policy.json" "$install_tmp"
chmod 600 "$install_tmp"
mv -f -- "$install_tmp" "$LIVE_FILE"
install_tmp=""
