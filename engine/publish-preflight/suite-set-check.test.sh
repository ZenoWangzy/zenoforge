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
git -C "$t" init -q repo && git -C "$t/repo" config user.email test && git -C "$t/repo" config user.name test
mkdir -p "$t/repo/.zenoforge" "$t/repo/scripts/checks"
echo '{"pipeline_suite_roots":["scripts/checks"]}' > "$t/repo/.zenoforge/ci.json"
sed 's#\$tmp#$TMP_DIR#' "$t/base/engine/moved.test.sh" > "$t/repo/scripts/checks/moved.test.sh"
head -20 "$t/base/engine/split.test.sh" > "$t/repo/scripts/checks/split.test.sh"
printf 'node --test %s\n' '"$0".mjs' > "$t/repo/scripts/checks/missing.test.sh"
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm initial
run() { python3 -I "$here/suite-set-check.py" "$t/base" "$t/new" "$t/repo" HEAD; }
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'NOT A MOVED SUITE.*scripts/checks/missing.test.sh' <<<"$out" || { echo "FAIL: $out"; exit 1; }
grep -qE 'moved.test.sh|split.test.sh' <<<"$out" && { echo "FAIL: moved or split flagged: $out"; exit 1; }
git -C "$t/repo" rm -q scripts/checks/missing.test.sh && git -C "$t/repo" commit -qm remove
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'LOST baseline suite: missing.test.sh' <<<"$out" || { echo "FAIL: $out"; exit 1; }
# The same suite outside every place the pipeline runs suites is still lost.
mkdir -p "$t/repo/docs" "$t/repo/.zenoforge/systemd"
cp "$t/base/engine/missing.test.sh" "$t/repo/docs/missing.test.sh" && git -C "$t/repo" add -A && git -C "$t/repo" commit -qm out-of-root
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'LOST baseline suite: missing.test.sh' <<<"$out" || { echo "FAIL: out-of-root copy accepted: $out"; exit 1; }
git -C "$t/repo" mv docs/missing.test.sh .zenoforge/systemd/missing.test.sh && git -C "$t/repo" commit -qm systemd
run | grep -q 'OK resolvable == moved (2 suites' || { echo "FAIL: systemd-dir suite not accepted"; exit 1; }
git -C "$t/repo" mv .zenoforge/systemd/missing.test.sh scripts/checks/missing.test.sh && git -C "$t/repo" commit -qm restore
run | grep -q 'OK resolvable == moved (3 suites' || { echo "FAIL: clean tree"; exit 1; }
echo "suite-set-check.test.sh: PASS"
