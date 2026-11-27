#!/usr/bin/env bash
set -euo pipefail

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for mode in off on; do
  if ZF_COORD_MODE="$mode" bash -c '
    set -euo pipefail
    engine="$1"
    mode="$2"
    source "$engine/test-env.sh"
    ZF_COORD="$mode"
    source "$engine/lib.sh"
    if [[ "$ZF_COORD" == off ]]; then
      if declare -F _coord_remote_read >/dev/null; then
        printf "coord-source.test.sh: coordination module loaded while off\n" >&2
        exit 1
      fi
      declare -F coord_acquire >/dev/null || exit 1
      coord_acquire issue-1 owner test 1 unit stage
    else
      declare -F _coord_remote_read >/dev/null || exit 1
    fi
  ' _ "$engine" "$mode"; then
    :
  else
    printf 'coord-source.test.sh: source path failed for mode %s\n' "$mode" >&2
    exit 1
  fi
done

printf 'coord-source.test.sh: PASS\n'
