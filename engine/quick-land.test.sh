#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$MODEL_POLICY_TEST_REPO/tools/quick-land.sh"

fail() { printf 'quick-land.test.sh: %s\n' "$*" >&2; exit 1; }

# The pin target: an override table naming engine/over.sh, read from its origin/main.
export AGENT_HOME="$test_env_root/home"
target="$AGENT_HOME/checkout"
mkdir -p "$target/.zenoforge/build"
git init -q -b main "$target"
printf '{"hook":".zenoforge/build/hook.sh"}\n' > "$target/.zenoforge/build.json"
printf '# path\tbase\nover.sh\tabc\n' > "$target/.zenoforge/build/overrides.tsv"
git -C "$target" add -A
git -C "$target" -c user.name=t -c user.email=t@example.invalid commit -qm table
git -C "$target" update-ref refs/remotes/origin/main HEAD

repo="$test_env_root/quick-land"
mkdir -p "$repo/engine" "$repo/tools"
git init -q -b main "$repo"
git -C "$repo" config user.name 'Quick Land Test'
git -C "$repo" config user.email quick-land-test@example.invalid
printf 'fixture\n' > "$repo/doc.md"
printf 'exit "${STUB_RULE_RC:-0}"\n' > "$repo/engine/rule-lane.sh"
printf '[[ -z ${STUB_SIZE_FAIL:-} ]] || { echo "FAIL tools/big.sh grew"; exit 1; }\necho size-ratchet ok\n' > "$repo/tools/size-ratchet.sh"
printf 'echo suite\n' > "$repo/engine/old.test.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm fixture
git init -q --bare -b main "$test_env_root/quick-land-origin.git"
git -C "$repo" remote add origin "$test_env_root/quick-land-origin.git"
git -C "$repo" push -q origin main
cd "$repo"
git fetch -q origin main
git switch -q --detach origin/main

reset_fixture() { git switch -q --detach origin/main; git reset -q --hard; git clean -qfd; }

# quick_land_refusal reads the staged diff, the number of --test given and the --prior-art text.
pa='no external prior art: fixture'
[[ "$(quick_land_refusal 0)" == 'nothing to land' ]] || fail 'an empty diff was accepted'

printf 'one line\n' >> doc.md
git add -A
[[ -z "$(quick_land_refusal 0)" ]] || fail 'a Markdown edit was refused'
reset_fixture

seq 1 500 > doc.md
git add -A
[[ -z "$(quick_land_refusal 0)" ]] || fail 'a long Markdown edit was refused'
reset_fixture

printf 'echo hi\n' > run.sh
git add -A
[[ "$(quick_land_refusal 0)" == 'code change needs at least one --test' ]] || fail 'code without --test was accepted'
[[ "$(quick_land_refusal 1)" == 'code change needs --prior-art'* ]] || fail 'code without --prior-art was accepted'
[[ "$(quick_land_refusal 1 'I thought hard')" == 'code change needs --prior-art'* ]] || fail 'a prior-art text with no source was accepted'
[[ -z "$(quick_land_refusal 1 'https://trunkbaseddevelopment.com/')" ]] || fail 'a URL prior-art was refused'
[[ -z "$(quick_land_refusal 1 "$pa")" ]] || fail 'code with --test and --prior-art was refused'
reset_fixture

mkdir -p engine/vendor
printf 'x\n' > engine/vendor/skill.md
git add -A
[[ "$(quick_land_refusal 1 "$pa")" == 'vendored file: engine/vendor/skill.md' ]] || fail 'a vendored file was accepted'
reset_fixture

printf 'x\n' > tools/merge-pr.sh
git add -A
[[ "$(quick_land_refusal 1 "$pa")" == 'gate file: tools/merge-pr.sh' ]] || fail 'a gate file was accepted'
reset_fixture

printf 'x\n' > engine/over.sh
git add -A
[[ "$(quick_land_refusal 1 "$pa")" == 'VectA override table file: engine/over.sh' ]] || fail 'an overridden file was accepted'
reset_fixture

printf 'x\n' > engine/other.sh
git add -A
[[ -z "$(quick_land_refusal 1 "$pa")" ]] || fail 'an engine file outside the override table was refused'
reset_fixture

git rm -q engine/old.test.sh
[[ "$(quick_land_refusal 1 "$pa")" == 'deletes or renames away test suite: engine/old.test.sh' ]] || fail 'a deleted suite was accepted'
reset_fixture

# End to end against the bare origin: the change lands on main with no PR.
origin_main() { git rev-parse origin/main; }
land() { # <expected rc> <quick-land args...>; leaves origin/main at what the run did
  local want="$1" got=0
  shift
  git fetch -q origin main
  git switch -q --detach origin/main
  quick_land_main "$@" >/dev/null 2>&1 || got=$?
  [[ "$got" == "$want" ]] || fail "quick_land_main $* returned $got, wanted $want"
  git fetch -q origin main
}

before="$(origin_main)"
printf 'echo hi\n' > run.sh
land 0 --test 'true' --test 'echo second' --prior-art 'https://trunkbaseddevelopment.com/' 'code lands'
[[ "$(origin_main)" != "$before" && "$(git show origin/main:run.sh)" == 'echo hi' ]] || fail 'a green --test did not land the change'
[[ "$(git rev-parse HEAD)" == "$(origin_main)" && -z "$(git symbolic-ref -q HEAD || true)" ]] || fail 'clone is not on detached origin/main after landing'
[[ "$(git log -1 --format=%b origin/main)" == $'## prior-art\nhttps://trunkbaseddevelopment.com/' ]] || fail 'prior-art did not reach the commit message'
[[ "$(cat "$(git rev-parse --git-common-dir)/zf-test-receipts/$(origin_main)")" == $'0\ttrue\n0\techo second' ]] || fail 'receipts were not recorded at the landed HEAD'

before="$(origin_main)"
printf 'echo red\n' > run.sh
land 1 --test 'false' --test 'touch ran-second' --prior-art "$pa" 'red test'
[[ "$(origin_main)" == "$before" ]] || fail 'a red --test landed the change'
[[ ! -e ran-second ]] || fail 'a test ran after a red one'
git branch --list 'quick/*' | grep -q . || fail 'the red run did not keep its branch'
[[ "$(cat "$(git rev-parse --git-common-dir)/zf-test-receipts/$(git rev-parse HEAD)")" == $'1\tfalse' ]] || fail 'the red rc was not recorded'
reset_fixture

printf 'echo no test\n' > run.sh
land 1 --prior-art "$pa" 'no test'
[[ "$(origin_main)" == "$before" ]] || fail 'code without --test landed'
reset_fixture

printf 'echo no prior art\n' > run.sh
land 1 --test 'true' 'no prior art'
[[ "$(origin_main)" == "$before" ]] || fail 'code without --prior-art landed'
reset_fixture

printf 'x\n' > engine/other.sh
STUB_RULE_RC=1 land 1 --test 'true' --prior-art "$pa" 'rule lane'
[[ "$(origin_main)" == "$before" ]] || fail 'a rule-lane refusal landed'
reset_fixture

printf 'x\n' > tools/big.sh
STUB_SIZE_FAIL=1 land 1 --test 'true' --prior-art "$pa" 'size'
[[ "$(origin_main)" == "$before" ]] || fail 'a size-ratchet refusal landed'
reset_fixture

printf 'doc\n' >> doc.md
land 0 'doc lands'
[[ "$(origin_main)" != "$before" ]] || fail 'a Markdown change without --test did not land'

echo 'quick-land.test.sh: PASS'
