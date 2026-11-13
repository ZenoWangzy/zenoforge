#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

root="$MODEL_POLICY_TEST_REPO"
config="$root/engine/mac-autopilot/config.template.json"
MODEL_POLICY_DEFAULT="$root/engine/model-policy.default.json"
MODEL_POLICY_FILE=""
source "$root/engine/lib.d/model-policy.sh"

fail() { printf 'model-policy-unit-roles.test.sh: %s\n' "$*" >&2; exit 1; }
while IFS= read -r key; do
  role="unit-${key//_/-}"
  jq -e --arg role "$role" '.roles | has($role)' "$MODEL_POLICY_DEFAULT" >/dev/null || fail "$key: missing role $role"
  for field in model effort service_tier; do
    case "$field" in model) index=0 ;; effort) index=1 ;; service_tier) index=2 ;; esac
    expected="$(jq -c --arg key "$key" --argjson index "$index" '.models[$key][$index] // null' "$config")"
    actual="$(jq -c --arg role "$role" --arg field "$field" '.roles[$role][$field] // null' "$MODEL_POLICY_DEFAULT")"
    [[ "$expected" == "$actual" ]] || fail "$key: $field differs (config=$expected policy=$actual)"
  done
  model="$(jq -r --arg role "$role" '.roles[$role].model' "$MODEL_POLICY_DEFAULT")"
  family="$(review_identity_family "$model")" || fail "$key: unknown model family for $model"
  case "$family" in codex) provider=codex ;; glm) provider=zcode ;; claude) provider=claude ;; *) fail "$key: unknown model family $family" ;; esac
  actual_provider="$(jq -r --arg role "$role" '.roles[$role].provider' "$MODEL_POLICY_DEFAULT")"
  [[ "$provider" == "$actual_provider" ]] || fail "$key: provider differs (inferred=$provider policy=$actual_provider)"
  model_policy_model_allowed_for_role "$model" "$role" || fail "$key: model validation failed for $role"
done < <(jq -r '.models | to_entries[] | select(.key != "hard" and .key != "implement_share" and .key != "codex_credits") | select(.value | type == "array") | .key' "$config")
while IFS= read -r role; do
  key="${role#unit-}"
  key="${key//-/_}"
  jq -e --arg key "$key" '($key != "hard" and $key != "implement_share" and $key != "codex_credits") and (.models[$key] | type == "array")' "$config" >/dev/null || fail "$role: missing tuple $key"
done < <(jq -r '.roles | keys[] | select(startswith("unit-"))' "$MODEL_POLICY_DEFAULT")
model_policy_model_allowed_for_role 'claude-haiku-5-5' 'unit-review' && fail 'unit-review: Haiku exception is not role-specific'
model_policy_model_allowed_for_role 'gpt-6.1-terra' 'unit-implement' && fail 'unit-implement: Terra exception is not role-specific'
echo 'model-policy-unit-roles.test.sh: all assertions passed'
