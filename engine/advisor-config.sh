#!/usr/bin/env bash
# Read advisor settings as data from the target config overlay.

_ADVISOR_CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$_ADVISOR_CONFIG_DIR/config.sh"

advisor_config_value() {
  local filter="$1" fallback="$2" config value
  config="$(zf_config_file night.json || true)"
  [[ -n "$config" ]] || { printf '%s\n' "$fallback"; return 0; }
  value="$(jq -er "$filter | select(type == \"string\" and length > 0)" "$config" 2>/dev/null || true)"
  printf '%s\n' "${value:-$fallback}"
}

advisor_prompt_file() {
  local kind="$1" default path
  case "$kind" in
    single) default=prompts/advisor.md ;;
    batch) default=prompts/advisor-batch.md ;;
    *) return 2 ;;
  esac
  path="$(advisor_config_value ".advisor.prompts.$kind" "$default")"
  zf_config_file "$path"
}

advisor_schema_file() {
  local kind="$1" default path
  case "$kind" in
    single) default=prompts/advisor.schema.json ;;
    *) return 2 ;;
  esac
  path="$(advisor_config_value ".advisor.schemas.$kind" "$default")"
  zf_config_file "$path"
}

advisor_queue_label() {
  advisor_config_value '.advisor.labels.queue // .advisor.queue' 'needs-advisor'
}

advisor_priority_label() {
  advisor_config_value '.advisor.labels.priority' 'priority:top'
}

advisor_provider_ready() {
  local config provider identity
  config="$(zf_config_file night.json || true)"
  if [[ -n "$config" ]] && ! jq -e 'type == "object" and (.advisor? == null or (.advisor | type == "object"))' \
    "$config" >/dev/null 2>&1; then
    echo 'skip: advisor settings are invalid' >&2
    return 1
  fi
  provider=''
  if [[ -n "$config" ]] && jq -e '(.advisor? // {}) | has("provider")' "$config" >/dev/null 2>&1; then
    provider="$(jq -r '.advisor.provider // empty | strings' "$config" 2>/dev/null || true)"
  else
    identity="$(model_policy identity advisor 2>/dev/null || true)"
    [[ "$identity" == web:* ]] && provider=web-advisor-provider
  fi
  if [[ "$provider" != web-advisor-provider ]]; then
    echo 'skip: advisor provider is not configured for this engine' >&2
    return 1
  fi
  identity="$(model_policy identity advisor 2>/dev/null || true)"
  if [[ "$identity" != web:* ]]; then
    echo 'skip: advisor provider does not match the configured advisor role' >&2
    return 1
  fi
  return 0
}
