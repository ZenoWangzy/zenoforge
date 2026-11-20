#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/suite-set"
mkdir -p "$t/base/engine" "$t/new/engine"
body() { for i in $(seq 1 40); do echo "assert_case_$1_$i \"\$tmp/$1\" || fail $1 step $i"; done; }
body moved > "$t/base/engine/moved.test.sh"
body split > "$t/base/engine/split.test.sh"; body split > "$t/new/engine/split.test.sh"
body missing > "$t/base/engine/missing.test.sh"
# The engine keeps its own suite under a name the target also uses for an unrelated suite.
body kept > "$t/base/engine/kept.test.sh"; body kept > "$t/new/engine/kept.test.sh"
git -C "$t" init -q repo && git -C "$t/repo" config user.email test && git -C "$t/repo" config user.name test
mkdir -p "$t/repo/.zenoforge" "$t/repo/scripts/checks" "$t/repo/project-tests"
echo '{"pipeline_suite_roots":["scripts/checks"]}' > "$t/repo/.zenoforge/ci.json"
# A tracked baseline suite outside the configured roots is still resolvable.
sed 's#\$tmp#$TMP_DIR#' "$t/base/engine/moved.test.sh" > "$t/repo/project-tests/moved.test.sh"
head -20 "$t/base/engine/split.test.sh" > "$t/repo/scripts/checks/split.test.sh"
printf 'node --test %s\n' '"$0".mjs' > "$t/repo/scripts/checks/missing.test.sh"
printf 'echo unrelated target suite\n' > "$t/repo/scripts/checks/kept.test.sh"
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm initial
run() { python3 -I "$here/suite-set-check.py" "$t/base" "$t/new" "$t/repo" HEAD; }
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'NOT A MOVED SUITE.*scripts/checks/missing.test.sh' <<<"$out" || { echo "FAIL: $out"; exit 1; }
grep -qE 'moved.test.sh|split.test.sh|kept.test.sh' <<<"$out" && { echo "FAIL: moved, split or kept flagged: $out"; exit 1; }
git -C "$t/repo" rm -q scripts/checks/missing.test.sh && git -C "$t/repo" commit -qm remove
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'LOST baseline suite: missing.test.sh' <<<"$out" || { echo "FAIL: $out"; exit 1; }
# A suite under packages/ is excluded and cannot preserve the baseline.
mkdir -p "$t/repo/packages" "$t/repo/.zenoforge/systemd"
cp "$t/base/engine/missing.test.sh" "$t/repo/packages/missing.test.sh" && git -C "$t/repo" add -A && git -C "$t/repo" commit -qm packages
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'LOST baseline suite: missing.test.sh' <<<"$out" || { echo "FAIL: packages copy preserved baseline: $out"; exit 1; }
git -C "$t/repo" mv packages/missing.test.sh .zenoforge/systemd/missing.test.sh && git -C "$t/repo" commit -qm systemd
run | grep -q 'OK resolvable == moved (1 suites' || { echo "FAIL: systemd-dir suite not accepted"; exit 1; }
git -C "$t/repo" mv .zenoforge/systemd/missing.test.sh scripts/checks/missing.test.sh && git -C "$t/repo" commit -qm restore
run | grep -q 'OK resolvable == moved (2 suites' || { echo "FAIL: suite outside configured roots not accepted"; exit 1; }
echo "suite-set-check.test.sh: PASS"
