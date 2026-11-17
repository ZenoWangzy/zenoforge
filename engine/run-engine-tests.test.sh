#!/usr/bin/env bash
# run-engine-tests.sh shards only the suites supplied through ZF_SUITES_FILE.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT

fixture="$test_env_root/runner-fixture"
suite_dir="$fixture/engine"
tools_dir="$fixture/tools"
suite_file="$test_env_root/suites.txt"
log="$test_env_root/executed.txt"
mkdir -p "$suite_dir" "$tools_dir"
cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../tools" && pwd -P)/run-engine-tests.sh" "$tools_dir/run-engine-tests.sh"

for suite in first second third; do
  cat > "$suite_dir/$suite.test.sh" <<EOF
printf '%s\\n' '$suite' >> "\$RUN_ENGINE_TESTS_LOG"
EOF
done
printf '%s\n' "$suite_dir/first.test.sh" "$suite_dir/second.test.sh" "$suite_dir/third.test.sh" > "$suite_file"

RUN_ENGINE_TESTS_LOG="$log" ZF_SUITES_FILE="$suite_file" PORTABLE_ONLY= bash "$tools_dir/run-engine-tests.sh" 1 2
actual="$(cat "$log")"
[[ "$actual" == $'first\nthird' ]] || {
  echo "run-engine-tests.test.sh: expected shard 1/2 to run first and third, got: $actual" >&2
  exit 1
}
echo 'run-engine-tests.test.sh: ok'
