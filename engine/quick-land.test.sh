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

echo 'quick-land.test.sh: PASS'
