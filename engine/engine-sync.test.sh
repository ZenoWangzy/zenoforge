#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
target=$test_env_root/target
mkdir -p "$target/.zenoforge" "$target/bin"
printf '{"hook":"bin/build", "engine":"abc123"}\n' > "$target/.zenoforge/build.json"
cat > "$target/bin/build" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$ZF_BUILD_ENGINE" "$@"
HOOK
chmod +x "$target/bin/build"
for mode in --build --check --converge; do
  result=$(ZF_REPO_DIR="$target" "$here/engine-sync.sh" "$mode" 'argument with spaces')
  [[ $result == "$(printf 'abc123\n%s\nargument with spaces' "$mode")" ]]
done
echo 'engine-sync.test.sh: PASS'
