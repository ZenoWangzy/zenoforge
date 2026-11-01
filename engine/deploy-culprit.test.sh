#!/usr/bin/env bash
# deploy_culprit_pack_value resolves state/deploy-culprit.json through the config
# seam: the target's config root wins over pack values retained during migration,
# and without either the generic defaults apply.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ENGINE_DIR/config.sh"
source "$ENGINE_DIR/deploy-culprit.sh"

config_root="$test_env_root/config/.zenoforge"
pack_dir="$test_env_root/pack"
empty_root="$test_env_root/empty/.zenoforge"
empty_pack="$test_env_root/empty/pack"
mkdir -p "$config_root/state" "$pack_dir/state" "$empty_root" "$empty_pack"
printf '{"migration_path":"config-migrations/%%s.sql"}\n' > "$config_root/state/deploy-culprit.json"
printf '{"migration_path":"pack-migrations/%%s.sql"}\n' > "$pack_dir/state/deploy-culprit.json"

value="$(ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" deploy_culprit_pack_value '.migration_path')"
[[ "$value" == 'config-migrations/%s.sql' ]] || { echo "deploy-culprit.test.sh: config root value did not win: $value" >&2; exit 1; }

value="$(ZF_CONFIG_ROOT="$empty_root" ZF_PACK_DIR="$pack_dir" deploy_culprit_pack_value '.migration_path')"
[[ "$value" == 'pack-migrations/%s.sql' ]] || { echo "deploy-culprit.test.sh: pack fallback not used: $value" >&2; exit 1; }

value="$(ZF_CONFIG_ROOT="$empty_root" ZF_PACK_DIR="$empty_pack" deploy_culprit_pack_value '.migration_path // "migrations/%s.sql"')"
[[ "$value" == 'migrations/%s.sql' ]] || { echo "deploy-culprit.test.sh: generic default not applied: $value" >&2; exit 1; }

signature="$(ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" deploy_culprit_pack_value '.infrastructure_signatures[0] // "none"')"
[[ "$signature" == 'none' ]] || { echo "deploy-culprit.test.sh: missing key must fall back per expression: $signature" >&2; exit 1; }

echo 'deploy-culprit.test.sh: PASS'
