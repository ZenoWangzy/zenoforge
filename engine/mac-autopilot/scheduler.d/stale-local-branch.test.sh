#!/usr/bin/env bash
# A never-pushed local branch moves up to main unless it has commits of its own.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/stale-local-branch"
mkdir -p "$fixture/supervisor/autopi/alerts"
git init -q --bare "$fixture/origin.git"
git init -q -b main "$fixture/repo"
git -C "$fixture/repo" config user.name t; git -C "$fixture/repo" config user.email t@example.com
git -C "$fixture/repo" remote add origin "$fixture/origin.git"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "stale-local-branch.test.sh: $*" >&2; exit 1; }
main_commit() {
  printf '%s\n' "$1" > "$fixture/repo/$1.txt"
  git -C "$fixture/repo" add -A; git -C "$fixture/repo" commit -qm "$1"
  git -C "$fixture/repo" push -q origin HEAD:refs/heads/main; git -C "$fixture/repo" fetch -q origin
  MAIN_HEAD="$(git -C "$fixture/repo" rev-parse HEAD)"
}

main_commit one
dir="$(ensure_clone_impl unit-1 agent/unit-1)" || fail "first clone refused"
main_commit two
[[ "$(ensure_clone_impl unit-1 agent/unit-1)" == "$dir" ]] || fail "second pass moved the clone"
[[ "$(git -C "$dir" rev-parse HEAD)" == "$MAIN_HEAD" ]] || fail "a branch with no commits of its own stayed on old main"

git -C "$dir" config user.name t; git -C "$dir" config user.email t@example.com
printf 'own\n' > "$dir/own.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm own
own="$(git -C "$dir" rev-parse HEAD)"
main_commit three
ensure_clone_impl unit-1 agent/unit-1 >/dev/null || fail "third pass refused"
[[ "$(git -C "$dir" rev-parse HEAD)" == "$own" ]] || fail "a local commit was moved or lost"
# Dirty over a path main changed: the tree is stashed first as before, so nothing is lost and the pass goes on.
dir2="$(ensure_clone_impl unit-2 agent/unit-2)" || fail "second clone refused"
git -C "$dir2" config user.name t; git -C "$dir2" config user.email t@example.com
printf 'dirty\n' >> "$dir2/one.txt"
printf 'main side\n' >> "$fixture/repo/one.txt"; main_commit four
ensure_clone_impl unit-2 agent/unit-2 >/dev/null || fail "a dirty clone stopped the pass"
[[ "$(git -C "$dir2" stash list | wc -l)" == 1 ]] || fail "the dirty edit was not kept"
[[ "$(git -C "$dir2" show 'stash@{0}:one.txt' | tail -1)" == dirty ]] || fail "the kept stash lost the edit"
[[ "$(git -C "$dir2" rev-parse HEAD)" == "$MAIN_HEAD" ]] || fail "a clean tree after the stash stayed on old main"

# Diverged, and an ff that cannot run: the branch stays and set -e must not stop the pass.
main_commit five
git -C "$dir" checkout -q agent/unit-1
ensure_clone_impl unit-1 agent/unit-1 >/dev/null || fail "a diverged clone stopped the pass"
[[ "$(git -C "$dir" rev-parse HEAD)" == "$own" ]] || fail "a diverged branch moved"
echo "stale-local-branch.test.sh: all assertions passed"
