#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
version="$test_env_root/version"
target="$test_env_root/target"
mkdir -p "$version" "$target/.zenoforge" "$version/.agents/skills/web-advisor-provider"
cp -a "$script_dir" "$version/engine"
: > "$version/.agents/skills/web-advisor-provider/ask.cjs"
ln -s "$version/engine" "$test_env_root/engine-live"
export ZF_REPO_DIR="$target" ZF_PACK_DIR="$test_env_root/empty-pack"
unset ZF_ENGINE_DIR ZF_WEB_ADVISOR_PROVIDER_SCRIPT ZF_CONFIG_ROOT
source "$test_env_root/engine-live/lib.sh"
[[ "$(zf_config_file providers/web-advisor-provider.sh)" == "$test_env_root/engine-live/providers/web-advisor-provider.sh" ]]
[[ "$ZF_WEB_ADVISOR_PROVIDER_SCRIPT" == "$version/.agents/skills/web-advisor-provider/ask.cjs" ]]
[[ "$(type -t web_advisor_provider_fault_signature)" == function ]]
for detail in '模型 slug' '模型标识'; do
  [[ "$(web_advisor_provider_fault_signature "$detail")" == env:web-advisor-provider:model-slug-mismatch ]]
done
for detail in '模型菜单' '选择模型' '当前模型或推理档位'; do
  [[ "$(web_advisor_provider_fault_signature "$detail")" == env:web-advisor-provider:picker-not-found ]]
done
[[ "$(web_advisor_provider_fault_signature 'ChatGPT tab lost')" == env:web-advisor-provider:browser-context-lost ]]
[[ "$(web_advisor_provider_fault_signature 'CDP port unreachable')" == env:web-advisor-provider:cdp-unreachable ]]
printf '发问前已验证的 picker 设置：first\n本次实际使用：second\n' > "$test_env_root/log"
[[ "$(web_advisor_provider_model_used "$test_env_root/log")" == second ]]
printf 'VERIFIED_MODEL: new\n' >> "$test_env_root/log"
[[ "$(web_advisor_provider_model_used "$test_env_root/log")" == new ]]
[[ "$(printf '%s' '{"text":"ok:chatgpt-content-reference{index="1"}"}' | web_advisor_provider_normalize_batch_json)" == '{"text":"ok"}' ]]
[[ "$(printf '%s' '{"text":"ok:web-content-reference{index="2"}"}' | web_advisor_provider_normalize_batch_json)" == '{"text":"ok"}' ]]
mkdir -p "$target/.zenoforge/providers"
printf '%s\n' '{"model_slug_mismatch":["custom fault"]}' > "$target/.zenoforge/providers/web-advisor-provider-fault-patterns.json"
[[ "$(web_advisor_provider_fault_signature 'custom fault')" == env:web-advisor-provider:model-slug-mismatch ]]
printf '%s\n' '{"model_markers":["CUSTOM: "],"citation_tokens":["custom.token"]}' > "$target/.zenoforge/providers/web-advisor-provider-response-formats.json"
printf 'CUSTOM: configured\n' > "$test_env_root/log"
[[ "$(web_advisor_provider_model_used "$test_env_root/log")" == configured ]]
[[ "$(printf '%s' '{"text":"ok:custom.token{index="3"}"}' | web_advisor_provider_normalize_batch_json)" == '{"text":"ok"}' ]]
printf 'ok - provider compatibility and live layout\n'
