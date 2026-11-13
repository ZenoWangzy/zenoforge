#!/usr/bin/env bash
# A test that sources test-env.sh must name $test_env_root in every EXIT trap, or its cleanup replaces test-env.sh's.
# Shared by exit-trap-lint.test.sh (whole tree) and merge-pr (one PR's suites). Prints each offending file.
set -euo pipefail
for file in "$@"; do
  grep -q 'test-env\.sh' "$file" || continue
  if grep -E "trap +['\"].*EXIT" "$file" | grep -v test_env_root >/dev/null; then
    printf '%s\n' "$file"
  fi
done
exit 0
