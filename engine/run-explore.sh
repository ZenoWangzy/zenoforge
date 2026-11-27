#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib.d/explore.sh"

case "${1:-}" in
  dispatch)
    [[ "$#" == 1 ]] || { echo 'usage: run-explore.sh dispatch | run <sha> | file <sha>' >&2; exit 64; }
    explore_dispatch_live_release
    ;;
  run|file)
    [[ "$#" == 2 ]] || { echo 'usage: run-explore.sh dispatch | run <sha> | file <sha>' >&2; exit 64; }
    explore_run_release "$1" "$2"
    ;;
  *)
    echo 'usage: run-explore.sh dispatch | run <sha> | file <sha>' >&2
    exit 64
    ;;
esac
