#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
TLA_HOME="${TLA_HOME:-${test_host_home:-$HOME}/.local/opt/tla}"
export TLA_HOME
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
set +e
full="$(bash "$HERE/verify-model.sh" 2>&1)"
rc=$?
set -e
if [[ "$rc" == 0 ]]; then
  printf '%s\n' "$full"
elif [[ "$rc" == 2 && "$full" == 'BLOCKED: TLC not found; see README.md' ]]; then
  printf '%s\n' "$full"
else
  printf '%s\n' "$full" >&2
  exit 1
fi
