#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/test-env.sh"
source "$repo_root/tools/run-engine-tests-helpers.sh"

slow_line="$(engine_test_log_if_slow engine/example.test.sh 301 600)"
[[ "$slow_line" == 'SLOW-TEST engine/example.test.sh 301' ]] || {
  echo "run-engine-tests-slow.test.sh: wrong slow-suite log: [$slow_line]" >&2
  exit 1
}
on_boundary="$(engine_test_log_if_slow engine/example.test.sh 300 600)"
[[ -z "$on_boundary" ]] || {
  echo "run-engine-tests-slow.test.sh: logged a suite at exactly half its timeout" >&2
  exit 1
}
small_limit="$(engine_test_log_if_slow engine/example.test.sh 3 5)"
[[ "$small_limit" == 'SLOW-TEST engine/example.test.sh 3' ]] || {
  echo "run-engine-tests-slow.test.sh: did not apply the configured limit" >&2
  exit 1
}
grep -Fq 'engine_test_log_if_slow "$t" "$elapsed" "$limit"' "$repo_root/tools/run-engine-tests.sh" || {
  echo "run-engine-tests-slow.test.sh: runner is not wired to the slow-suite logger" >&2
  exit 1
}
echo 'run-engine-tests-slow.test.sh: PASS'
