#!/usr/bin/env bash
# Every agent test suite opens with `set -euo pipefail` and then sources test-env.sh,
# skipping comments and blank lines. Shared by check-rulings and the commit preflight:
# hand agents run only --mode commit, so suites without the bootstrap reached CI twice
# on 2026-10-06 (PR 2654, PR 2660).
set -euo pipefail
(($#)) || exit 0
if ! awk '
  FNR == 1 {
    if (NR > 1 && count < 2) { printf "invalid test bootstrap: %s\n", previous > "/dev/stderr"; bad=1 }
    previous=FILENAME
    count=0
  }
  count >= 2 { next }
  /^[[:space:]]*(#|$)/ { next }
  {
    if (count == 0 && $0 != "set -euo pipefail") {
      printf "invalid test bootstrap: %s\n", FILENAME > "/dev/stderr"; bad=1
    } else if (count == 1 && $0 !~ /^source .*test-env\.sh/) {
      printf "invalid test bootstrap: %s\n", FILENAME > "/dev/stderr"; bad=1
    }
    count++
  }
  END {
    if (NR > 0 && count < 2) { printf "invalid test bootstrap: %s\n", previous > "/dev/stderr"; bad=1 }
    exit bad
  }
' "$@"; then
  echo 'ERROR check-rulings: test suite must start with set -euo pipefail and source test-env.sh' >&2
  exit 2
fi
