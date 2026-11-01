#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

target="$test_env_root/target"
engine="$target/engine"
pack="$test_env_root/pack"
mkdir -p "$engine" "$pack"
ZF_ENGINE_DIR="$engine" ZF_REPO_DIR="$target" ZF_PACK_DIR="$pack"
source "$SCRIPT_DIR/config.sh"

declare -F zf_config_file >/dev/null || fail 'zf_config_file is defined'
check 'default config root follows the target repo' "$ZF_CONFIG_ROOT" "$target/.zenoforge"

mkdir -p "$target/.zenoforge"
printf root > "$target/.zenoforge/shared.json"
printf pack > "$pack/shared.json"
printf engine > "$engine/shared.json"
check 'config root wins over pack and engine' "$(zf_config_file shared.json)" "$target/.zenoforge/shared.json"

check 'advisor batch runner defaults to the engine' "$(zf_advisor_batch_runner)" "$engine/run-advisor-batch.sh"
check 'advisor comment disclaimer uses the neutral default' \
  "$(zf_advisor_comment_disclaimer 'generic agent comment')" 'generic agent comment'
mkdir -p "$target/scripts/ops"
printf '#!/usr/bin/env bash\n' > "$target/scripts/ops/advisor-batch.sh"
chmod +x "$target/scripts/ops/advisor-batch.sh"
printf '{"batchRunner":"scripts/ops/advisor-batch.sh","commentDisclaimer":"configured agent comment"}\n' > "$target/.zenoforge/advisor.json"
check 'advisor batch runner resolves from target config' "$(zf_advisor_batch_runner)" "$target/scripts/ops/advisor-batch.sh"
check 'advisor comment disclaimer resolves from target config' \
  "$(zf_advisor_comment_disclaimer 'generic agent comment')" 'configured agent comment'
printf '{"batchRunner":"../outside.sh"}\n' > "$target/.zenoforge/advisor.json"
if zf_advisor_batch_runner >/dev/null 2>&1; then
  fail 'advisor batch runner rejects parent traversal'
else
  check 'advisor batch runner rejects parent traversal' "$?" 2
fi
printf '{"commentDisclaimer":17}\n' > "$target/.zenoforge/advisor.json"
if zf_advisor_comment_disclaimer 'generic agent comment' >/dev/null 2>&1; then
  fail 'advisor comment disclaimer rejects a non-string value'
else
  check 'advisor comment disclaimer rejects a non-string value' "$?" 2
fi
rm "$target/.zenoforge/advisor.json"

printf '{"migration":{"path":"migrations"}}\n' > "$target/.zenoforge/release.json"
touch "$engine/lib-migration-gate.sh"
check 'migration gate defaults to the generic engine module' "$(zf_migration_gate_file)" "$engine/lib-migration-gate.sh"
mkdir -p "$target/scripts/release"
touch "$target/scripts/release/lib-migration-gate.sh"
printf '{"migration":{"gate":"scripts/release/lib-migration-gate.sh"}}\n' > "$target/.zenoforge/release.json"
check 'migration gate resolves from target config' "$(zf_migration_gate_file)" "$target/scripts/release/lib-migration-gate.sh"
printf '{"migration":{"gate":"../outside.sh"}}\n' > "$target/.zenoforge/release.json"
if zf_migration_gate_file >/dev/null 2>&1; then
  fail 'migration gate rejects parent traversal'
else
  check 'migration gate rejects parent traversal' "$?" 2
fi
rm "$target/.zenoforge/release.json"
touch "$pack/lib-migration-gate.sh"
printf '{"release":{"runner":"run-release.sh"}}\n' > "$target/.zenoforge/release.json"
check 'migration gate retains the legacy pack fallback when no migration is configured' "$(zf_migration_gate_file)" "$pack/lib-migration-gate.sh"
rm "$target/.zenoforge/release.json"

mkdir -p "$target/.zenoforge/prompts" "$pack/prompts" "$engine/prompts"
printf 'target prompt\n' > "$target/.zenoforge/prompts/advisor.md"
printf 'pack prompt\n' > "$pack/prompts/advisor.md"
printf 'engine prompt\n' > "$engine/prompts/advisor.md"
check 'a nested prompt read uses the target config override' "$(cat "$(zf_config_file prompts/advisor.md)")" 'target prompt'

override="$test_env_root/config-override"
mkdir -p "$override"
printf override > "$override/override.json"
ZF_CONFIG_ROOT="$override"
check 'caller config root override wins' "$(zf_config_file override.json)" "$override/override.json"

ZF_CONFIG_ROOT="$target/.zenoforge"
rm "$target/.zenoforge/shared.json"
check 'falls back to pack' "$(zf_config_file shared.json)" "$pack/shared.json"

ZF_PACK_DIR=
check 'falls back to engine default' "$(zf_config_file shared.json)" "$engine/shared.json"

if zf_config_file absent.json >/dev/null 2>&1; then
  missing_status=0
else
  missing_status=$?
fi
check 'no file returns 1' "$missing_status" 1

for invalid_path in ../x /etc/x nested/../x; do
  if zf_config_file "$invalid_path" >/dev/null 2>&1; then
    invalid_status=0
  else
    invalid_status=$?
  fi
  check "rejects $invalid_path with status 2" "$invalid_status" 2
done

# An absent optional directory preserves the existing pack_file result for current readers.
rm -rf "$target/.zenoforge"
unset ZF_CONFIG_ROOT
source "$SCRIPT_DIR/config.sh"
ZF_PACK_DIR="$pack"
printf existing > "$pack/existing-reader.json"
check 'missing optional config directory keeps the default path' "$ZF_CONFIG_ROOT" "$target/.zenoforge"
check 'pack_file still resolves the same reader path' "$(pack_file existing-reader.json)" "$pack/existing-reader.json"
check 'config lookup reaches that same pack path' "$(zf_config_file existing-reader.json)" "$pack/existing-reader.json"

node_config_path() {
  local config_root="$1" pack_dir="$2" engine_dir="$3" relative_path="$4"
  NODE_CONFIG_MODULE="$SCRIPT_DIR/pack-dir.mjs" \
    ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" ZF_ENGINE_DIR="$engine_dir" \
    NODE_RELATIVE_PATH="$relative_path" node --input-type=module -e '
      import { pathToFileURL } from "node:url";
      const { zfConfigFile } = await import(pathToFileURL(process.env.NODE_CONFIG_MODULE));
      const result = zfConfigFile(process.env.NODE_RELATIVE_PATH);
      if (result === null) process.exit(1);
      console.log(result);
    '
}
node_exported_config_path() {
  NODE_CONFIG_MODULE="$SCRIPT_DIR/pack-dir.mjs" NODE_RELATIVE_PATH="$1" node --input-type=module -e '
    import { pathToFileURL } from "node:url";
    const { zfConfigFile } = await import(pathToFileURL(process.env.NODE_CONFIG_MODULE));
    const result = zfConfigFile(process.env.NODE_RELATIVE_PATH);
    if (result === null) process.exit(1);
    console.log(result);
  '
}

mkdir -p "$target/.zenoforge"
printf node-root > "$target/.zenoforge/node.json"
printf node-pack > "$pack/node.json"
printf node-engine > "$engine/node.json"
check 'exported default config root reaches Node' "$(node_exported_config_path node.json)" "$target/.zenoforge/node.json"
check 'Node config root wins' "$(node_config_path "$target/.zenoforge" "$pack" "$engine" node.json)" "$target/.zenoforge/node.json"
check 'Node pack fallback' "$(node_config_path "$test_env_root/no-config" "$pack" "$engine" node.json)" "$pack/node.json"
check 'Node engine fallback' "$(node_config_path "$test_env_root/no-config" '' "$engine" node.json)" "$engine/node.json"
if node_config_path "$test_env_root/no-config" '' "$engine" absent.json >/dev/null 2>&1; then
  fail 'Node missing file returns null'
fi
for invalid_path in ../x /etc/x nested/../x; do
  if node_config_path "$test_env_root/no-config" "$pack" "$engine" "$invalid_path" >/dev/null 2>&1; then
    fail "Node rejects $invalid_path"
  fi
done

printf 'config-root.test.sh: PASS\n'
