#!/usr/bin/env bash
# Every EXIT trap in the scheduler libs goes through chain_exit_trap: a bare trap replaces the engine canary's trap (#753).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bad="$(grep -nE "trap +['\"].*EXIT" "$dir"/*.sh | grep -v '\.test\.sh:' | grep -v 'lint-exempt' || true)"
[[ -z "$bad" ]] || { printf 'exit-trap-lint.test.sh: bare EXIT trap, use chain_exit_trap:\n%s\n' "$bad" >&2; exit 1; }
echo 'exit-trap-lint.test.sh: all assertions passed'
