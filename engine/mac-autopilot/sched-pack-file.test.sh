#!/usr/bin/env bash
# sched_config_file resolves the scheduler's pack data through the config seam:
# the target's config root wins over a pack copy retained during migration, and a
# file that exists in neither place fails (the caller keeps its empty default).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/scheduler.d/core.sh"

config_root="$test_env_root/config/.zenoforge"
pack_dir="$test_env_root/pack"
empty_root="$test_env_root/empty/.zenoforge"
empty_pack="$test_env_root/empty/pack"
mkdir -p "$config_root/mac-autopilot" "$pack_dir/mac-autopilot" "$empty_root" "$empty_pack"
printf 'config copy\n' > "$config_root/mac-autopilot/worker-docs.json"
printf 'pack copy\n' > "$pack_dir/mac-autopilot/worker-docs.json"

resolved="$(ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" sched_config_file mac-autopilot/worker-docs.json)"
[[ "$(cat "$resolved")" == 'config copy' ]] || { echo "sched-pack-file.test.sh: config root copy did not win: $resolved" >&2; exit 1; }

resolved="$(ZF_CONFIG_ROOT="$empty_root" ZF_PACK_DIR="$pack_dir" sched_config_file mac-autopilot/worker-docs.json)"
[[ "$(cat "$resolved")" == 'pack copy' ]] || { echo "sched-pack-file.test.sh: pack fallback not used: $resolved" >&2; exit 1; }

if ZF_CONFIG_ROOT="$empty_root" ZF_PACK_DIR="$empty_pack" sched_config_file mac-autopilot/worker-docs.json; then
  echo 'sched-pack-file.test.sh: missing file must fail, not resolve' >&2; exit 1
fi

echo 'sched-pack-file.test.sh: PASS'
