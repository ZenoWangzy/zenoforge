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
mkdir -p "$test_env_root/agent/engine-versions/live/engine" "$test_env_root/new-version/engine"
ln -s "$test_env_root/agent/engine-versions/live/engine" "$test_env_root/agent/engine-live"
echo '{"pipeline_suite_roots":[]}' > "$target/.zenoforge/ci.json"
git -C "$target" init -q && git -C "$target" config user.email test && git -C "$target" config user.name test
git -C "$target" add -A && git -C "$target" commit -qm initial
preflight() { ZF_REPO_DIR="$target" AGENT_HOME="$test_env_root/agent" "$here/engine-sync.sh" --preflight "$test_env_root/new-version"; }
# Without BUILD-INFO the live target commit is unknown: preflight refuses instead of comparing HEAD with itself.
if preflight >/dev/null 2>&1; then echo 'FAIL: preflight ran without the live target commit' >&2; exit 1; fi
# The new version may lack BUILD-INFO (falls back to HEAD). product_sha wins over pack_sha in any order: the pack
# commit here does not exist, so reading it would fail the preflight.
printf 'pack_sha=%s:.zenoforge/build/pack\nproduct_sha=%s\n' "$(printf '0%.0s' {1..40})" "$(git -C "$target" rev-parse HEAD)" \
  > "$test_env_root/agent/engine-versions/live/BUILD-INFO"
result=$(preflight)
grep -q 'publish-preflight: OK' <<<"$result"
printf 'pack_sha=%s:.zenoforge/build/pack\n' "$(git -C "$target" rev-parse HEAD)" > "$test_env_root/agent/engine-versions/live/BUILD-INFO"
printf 'product_sha=%s\n' "$(git -C "$target" rev-parse HEAD)" > "$test_env_root/new-version/BUILD-INFO"
result=$(preflight)
grep -q 'publish-preflight: OK' <<<"$result"
echo 'engine-sync.test.sh: PASS'
