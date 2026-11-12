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

# #497: an undefined zf_config_file or an unparseable config fails loud; an absent config logs and uses the default.
err="$(bash -c 'source "$1"; deploy_culprit_pack_value .migration_path' _ "$ENGINE_DIR/deploy-culprit.sh" 2>&1)" && rc=0 || rc=$?
[[ $rc -ne 0 && $err == *'zf_config_file is undefined'* ]] || { echo "deploy-culprit.test.sh: undefined zf_config_file did not fail loud: rc=$rc $err" >&2; exit 1; }

bad_root="$test_env_root/bad/.zenoforge"
mkdir -p "$bad_root/state"
printf '{"migration_path":' > "$bad_root/state/deploy-culprit.json"
err="$(ZF_CONFIG_ROOT="$bad_root" ZF_PACK_DIR="$empty_pack" deploy_culprit_pack_value '.migration_path' 2>&1)" && rc=0 || rc=$?
[[ $rc -ne 0 && $err == *'cannot read or parse'* ]] || { echo "deploy-culprit.test.sh: unparseable config did not fail loud: rc=$rc $err" >&2; exit 1; }

value="$(ZF_CONFIG_ROOT="$empty_root" ZF_PACK_DIR="$empty_pack" deploy_culprit_pack_value '.migration_path // "migrations/%s.sql"' 2>"$test_env_root/absent.err")"
[[ "$value" == 'migrations/%s.sql' && "$(cat "$test_env_root/absent.err")" == *'using default values'* ]] || { echo "deploy-culprit.test.sh: absent config did not log the default: $value" >&2; exit 1; }

# #525: migration failures attribute only on allow-listed SQLSTATE classes (22, 23, 42 minus 42501).
repo="$test_env_root/attr-repo"
git init -q "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" commit -q --allow-empty -m init
mkdir -p "$repo/migrations"
echo 'select 1;' > "$repo/migrations/release.sql"
git -C "$repo" add migrations
git -C "$repo" commit -q -m 'fix(#77): add release migration'
fix_sha="$(git -C "$repo" rev-parse HEAD)"
attributes() { # print "issue commit" for code $1 under ATTR_ROOT (default: no config), or "none"
  local out
  if out="$(ZF_CONFIG_ROOT="${ATTR_ROOT:-$empty_root}" ZF_PACK_DIR="$empty_pack" deploy_culprit "$repo" 'HEAD~1..HEAD' migration "stage=release-1 code=$1" 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    echo none
  fi
}
for code in 23505 22P02; do
  [[ "$(attributes $code)" == "77 $fix_sha" ]] || { echo "deploy-culprit.test.sh: allowed code $code did not attribute: $(attributes $code)" >&2; exit 1; }
done
for code in 57P01 40001 ECONNRESET EAI_AGAIN 42501; do
  [[ "$(attributes $code)" == none ]] || { echo "deploy-culprit.test.sh: unlisted code $code attributed" >&2; exit 1; }
done

over_root="$test_env_root/attr-override/.zenoforge"
mkdir -p "$over_root/state"
printf '{"attributable_sqlstate_classes":["57"]}\n' > "$over_root/state/deploy-culprit.json"
[[ "$(ATTR_ROOT="$over_root" attributes 57P01)" == "77 $fix_sha" ]] || { echo 'deploy-culprit.test.sh: pack override did not allow class 57' >&2; exit 1; }
[[ "$(ATTR_ROOT="$over_root" attributes 23505)" == none ]] || { echo 'deploy-culprit.test.sh: pack override kept the default classes' >&2; exit 1; }

echo 'deploy-culprit.test.sh: PASS'
