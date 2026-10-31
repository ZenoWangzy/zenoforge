#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
GATE="$SCRIPT_DIR/cutover-gate.sh"

test_root="$(mktemp -d "$REPO_ROOT/.git/cutover-gate-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$test_root"
  find "$test_root" -depth -delete
}
trap cleanup EXIT
export ZF_HOST_OPS_DIR="$test_root/host-ops"
mkdir -p "$ZF_HOST_OPS_DIR"
printf 'result\ttest\nPASS\tfixture\n' > "$ZF_HOST_OPS_DIR/BASELINE.tsv"
printf '#!/usr/bin/env bash\nprintf "PASS\\tfixture\\n"\n' > "$ZF_HOST_OPS_DIR/run-tests.sh"

engine="$test_root/engine"
target="$test_root/target"
mkdir -p "$engine/night" "$engine/state" "$target/.zenoforge"
cp "$REPO_ROOT/engine/night/incident-guard-audit.mjs" "$engine/night/incident-guard-audit.mjs"
cp "$REPO_ROOT/engine/pack-dir.mjs" "$engine/pack-dir.mjs"
printf '{"incidents":[]}' > "$engine/state/incident-guards.json"

assert_fails_with() {
  local expected="$1" output status
  shift
  if output="$("$GATE" "$engine" "$target" "$@" 2>&1)"; then
    printf 'not ok - expected gate failure containing: %s\n' "$expected" >&2
    exit 1
  else
    status=$?
  fi
  if [[ "$status" -ne 1 ]]; then
    printf 'not ok - gate failure exited %s instead of 1:\n%s\n' "$status" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'not ok - gate failure did not contain: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
}

assert_passes() {
  local output
  if ! output="$("$GATE" "$engine" "$target" "$@" 2>&1)"; then
    printf 'not ok - clean fixture failed:\n%s\n' "$output" >&2
    exit 1
  fi

}

# A green baseline regression fails; a failure present in both versions passes.
printf '#!/usr/bin/env bash\nexit 0\n' > "$engine/comparison.test.sh"
printf 'bash engine/comparison.test.sh\n' > "$test_root/compare-suites.txt"
"$GATE" --baseline "$test_root" --out "$test_root/baseline.tsv" --suites "$test_root/compare-suites.txt"
printf '#!/usr/bin/env bash\nexit 1\n' > "$engine/comparison.test.sh"
assert_fails_with 'suite failed: engine/comparison.test.sh' --baseline "$test_root/baseline.tsv" --suites "$test_root/compare-suites.txt"
printf 'FAIL\tengine/comparison.test.sh\n' > "$test_root/baseline.tsv"
assert_passes --baseline "$test_root/baseline.tsv" --suites "$test_root/compare-suites.txt"

# Host-ops failures follow its per-test baseline, even when the runner exits 1.
printf '#!/usr/bin/env bash\nprintf "FAIL\\tfixture\\n"\nexit 1\n' > "$ZF_HOST_OPS_DIR/run-tests.sh"
assert_fails_with 'host-ops test failed: fixture'
printf 'result\ttest\nFAIL\tfixture\n' > "$ZF_HOST_OPS_DIR/BASELINE.tsv"
assert_passes
printf 'result\ttest\nPASS\tfixture\n' > "$ZF_HOST_OPS_DIR/BASELINE.tsv"
printf '#!/usr/bin/env bash\nprintf "PASS\\tfixture\\n"\n' > "$ZF_HOST_OPS_DIR/run-tests.sh"

# A literal path crossing from the engine into the target must resolve.
cat > "$engine/boundary.sh" <<'EOF'
source "$ZF_REPO_DIR/ops/missing.sh"
EOF
assert_fails_with 'unresolved path'
mkdir -p "$target/ops"
: > "$target/ops/missing.sh"

# Calls to a shell function must have a definition somewhere in the engine.
printf 'missing_engine_helper\n' > "$engine/functions.sh"
assert_fails_with 'undefined shell function: missing_engine_helper'
printf 'missing_engine_helper\tfunctions.sh\tfixture caller is disabled\n' > "$test_root/allow.tsv"
assert_passes --allow-undefined "$test_root/allow.tsv"
printf 'missing_engine_helper\tother.sh\twrong caller\n' > "$test_root/allow.tsv"
assert_fails_with 'undefined shell function: missing_engine_helper' --allow-undefined "$test_root/allow.tsv"
printf 'missing_engine_helper() { :; }\n' > "$engine/functions.sh"

# Guard audit failures are surfaced from its structured missingTargets result.
printf '{"incidents":[{"id":"fixture","machine_checks":[{"command":["test","-f","absent.test.sh"]}]}]}' \
  > "$engine/state/incident-guards.json"
assert_fails_with 'incident guard fixture missing target absent.test.sh'
printf '{"incidents":[]}' > "$engine/state/incident-guards.json"

printf '#!/usr/bin/env bash\nsleep 5\n' > "$engine/slow.test.sh"
printf 'timeout -s KILL 1 bash engine/slow.test.sh\n' > "$test_root/suites.txt"
if output="$("$GATE" "$engine" "$target" --suites "$test_root/suites.txt" 2>&1)"; then
  printf 'not ok - timed out suite unexpectedly passed\n' >&2
  exit 1
else
  status=$?
fi
if [[ "$status" -ne 1 ]]; then
  printf 'not ok - timed out suite exited %s instead of 1:\n%s\n' "$status" "$output" >&2
  exit 1
fi
[[ "$output" == *'cutover-gate: suite failed: engine/slow.test.sh' ]] || {
  printf 'not ok - timeout should produce one gate failure line:\n%s\n' "$output" >&2
  exit 1
}

printf 'ok - cutover gate resolves boundaries, checks guards, filters baseline reds, and passes a clean fixture\n'
