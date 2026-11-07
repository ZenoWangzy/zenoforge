#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$MODEL_POLICY_TEST_REPO/tools/quick-land.sh"

repo="$test_env_root/quick-land"
mkdir -p "$repo/engine/vendor"
git init -q -b main "$repo"
git -C "$repo" config user.name 'Quick Land Test'
git -C "$repo" config user.email quick-land-test@example.invalid
printf 'fixture\n' > "$repo/doc.md"
git -C "$repo" add doc.md
git -C "$repo" commit -qm fixture
cd "$repo"

fail() { printf 'quick-land.test.sh: %s\n' "$*" >&2; exit 1; }
reset_fixture() { git reset -q --hard; git clean -qfd; }

[[ "$(quick_land_refusal)" == 'nothing to land' ]] || fail 'an empty diff was accepted'

printf 'one line\n' >> doc.md
git add -A
[[ -z "$(quick_land_refusal)" ]] || fail 'a one-line Markdown edit was refused'
reset_fixture

seq 1 "$((QUICK_LAND_MAX_LINES + 2))" > doc.md
git add -A
[[ "$(quick_land_refusal)" == *"limit $QUICK_LAND_MAX_LINES" ]] || fail 'an oversized edit was accepted'
reset_fixture

printf 'echo hi\n' > run.sh
git add -A
[[ "$(quick_land_refusal)" == 'not Markdown: run.sh' ]] || fail 'code was accepted'
reset_fixture

mkdir -p engine/vendor
printf 'x\n' > engine/vendor/skill.md
git add -A
[[ "$(quick_land_refusal)" == 'vendored file: engine/vendor/skill.md' ]] || fail 'a vendored file was accepted'
reset_fixture

# quick_land_main end to end with stubbed gh and merge-pr: wait for checks, restore main on failure.
git init -q --bare -b main "$test_env_root/quick-land-origin.git"
git remote add origin "$test_env_root/quick-land-origin.git"
git push -q origin main
git fetch -q origin main
git switch -q --detach origin/main
mkdir -p tools "$test_env_root/bin"
cat > "$test_env_root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  'pr create') echo 'https://github.com/o/r/pull/7' ;;
  'pr checks')
    n="$(cat "$STUB_DIR/checks-calls" 2>/dev/null || echo 0)"; echo "$((n + 1))" > "$STUB_DIR/checks-calls"
    if (( n < STUB_EMPTY_CHECKS )); then echo 'no checks reported'; exit 1; fi
    echo '[{"name":"ci"}]' ;;
esac
STUB
chmod +x "$test_env_root/bin/gh"
cat > tools/merge-pr.sh <<'STUB'
#!/usr/bin/env bash
echo "$1 checks-calls=$(cat "$STUB_DIR/checks-calls")" > "$STUB_DIR/merged"
exit "${STUB_MERGE_RC:-0}"
STUB
export STUB_DIR="$test_env_root/stub" PATH="$test_env_root/bin:$PATH" QUICK_LAND_CHECKS_SLEEP=0 QUICK_LAND_CHECKS_TRIES=5
git add tools/merge-pr.sh
git commit -qm 'stub merge-pr'
git push -q origin HEAD:main
git fetch -q origin main
git switch -q --detach origin/main
land() { # <empty checks> <merge rc>; leaves the result in $land_rc
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
  printf 'edit\n' >> doc.md
  land_rc=0; STUB_EMPTY_CHECKS=$1 STUB_MERGE_RC=$2 quick_land_main 'subject' >/dev/null 2>&1 || land_rc=$?
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" && -z "$(git symbolic-ref -q HEAD || true)" ]] || fail 'clone is not on detached origin/main'
  git reset -q --hard
}
land 3 0
[[ "$land_rc" == 0 && "$(cat "$STUB_DIR/merged")" == '7 checks-calls=4' ]] || fail 'merge-pr did not wait for readable checks'
land 99 0
[[ "$land_rc" != 0 && ! -e "$STUB_DIR/merged" ]] || fail 'merge-pr ran without readable checks'
land 0 1
[[ "$land_rc" == 1 && -e "$STUB_DIR/merged" ]] || fail 'a merge-pr failure was swallowed'

echo 'quick-land.test.sh: PASS'
