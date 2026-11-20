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
mkdir -p "$target/.zenoforge/build/pack/scripts/zenoforge-pack"
printf 'queue = engine_root / "mac-autopilot/patched.sh"\n' > "$target/.zenoforge/build/pack/scripts/zenoforge-pack/patch-x.py"
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
[[ "$(quick_land_refusal 1 "$pa")" == "gate file tools/merge-pr.sh needs --test 'bash engine/merge-pr-helper.test.sh'" ]] || fail 'a gate file was accepted without its own suite'
[[ -z "$(quick_land_refusal 1 "$pa" 'bash engine/merge-pr-helper.test.sh')" ]] || fail 'a gate file with its own suite was refused (founder 11-19: changes go live directly)'
reset_fixture

printf 'x\n' > engine/over.sh
git add -A
[[ -z "$(quick_land_refusal 1 "$pa")" ]] || fail 'an overridden file was refused before its pin dry run (founder 11-19: changes go live directly)'
# Focused tests (11-19, 47bc387): a focused path not named by a --test refuses; the 25-min scheduler suites are left to CI.
QUICK_LAND_FOCUSED='printf %s\n engine/a.test.sh engine/mac-autopilot/scheduler-part-3.test.sh engine/b.test.mjs #'
[[ "$(quick_land_missing_focused 'bash engine/a.test.sh')" == engine/b.test.mjs ]] || fail 'a focused test missing from --test was not named'
[[ -z "$(quick_land_missing_focused 'bash engine/a.test.sh node engine/b.test.mjs')" ]] || fail 'all focused tests given still refused'
[[ -z "$(quick_land_missing_focused 'bash engine/a.test.sh node engine/b.test.mjs' | grep scheduler-part)" ]] || fail 'a scheduler partition was required locally'
QUICK_LAND_FOCUSED=false
[[ "$(quick_land_commit_refusal 'bash engine/a.test.sh')" == 'focused-test-paths failed'* ]] || fail 'a failing focused selection was not a refusal'
QUICK_LAND_FOCUSED=true # the fixture repos below have no focused-test-paths.mjs: select nothing
[[ "$(quick_land_override_hit engine/over.sh)" == engine/over.sh ]] || fail 'the override table no longer names engine/over.sh, so no pin dry run would run'
[[ "$(quick_land_override_hit engine/mac-autopilot/patched.sh)" == engine/mac-autopilot/patched.sh ]] || fail 'a file a VectA pack patch rewrites got no pin dry run (11-19 PIN-STALL)'
[[ -z "$(quick_land_override_hit engine/mac-autopilot/other.sh)" ]] || fail 'a file no pack patch names was sent to the pin dry run'
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

# Main moves while the suites run: a commit on another file is replayed under the change; a commit on the same file refuses.
git clone -q "$test_env_root/quick-land-origin.git" "$test_env_root/mover"
git -C "$test_env_root/mover" config user.name 'Mover'; git -C "$test_env_root/mover" config user.email mover@example.invalid
printf 'cd "%s" && git pull -q origin main && echo moved >> "$1" && git add -A && git commit -qm "move $1" && git push -q origin HEAD:main\n' "$test_env_root/mover" > "$test_env_root/move-main.sh"
printf 'echo replay\n' > run.sh
land 0 --test "bash $test_env_root/move-main.sh elsewhere.md" --prior-art "$pa" 'lands after main moved on another file'
[[ "$(git show origin/main:run.sh)" == 'echo replay' && "$(git show origin/main:elsewhere.md)" == 'moved' ]] || fail 'main moved on another file: the change did not land on top of it'
[[ "$(git log -1 --format=%s origin/main)" == 'lands after main moved on another file' && "$(git log -1 --format=%s origin/main~1)" == 'move elsewhere.md' ]] || fail 'the replayed change is not one commit on top of the moved main'
before="$(origin_main)"
printf 'echo clash\n' > run.sh
land 1 --test "bash $test_env_root/move-main.sh run.sh" --prior-art "$pa" 'same file moved'
[[ "$(git log -1 --format=%s origin/main)" == 'move run.sh' ]] || fail 'main moved on the same file: the change landed anyway'
git branch --list 'quick/*' | grep -q . || fail 'the refused replay did not keep its branch'
reset_fixture
# A suite this land ran changed on main: the green result is for the old suite, so the change is not replayed.
printf 'echo stale suite\n' > run.sh
land 1 --test "bash $test_env_root/move-main.sh engine/old.test.sh" --test 'bash engine/old.test.sh' --prior-art "$pa" 'ran suite moved'
[[ "$(git log -1 --format=%s origin/main)" == 'move engine/old.test.sh' ]] || fail 'main moved on a suite this land ran: the change landed without a rerun'
reset_fixture

echo 'quick-land.test.sh: PASS'
