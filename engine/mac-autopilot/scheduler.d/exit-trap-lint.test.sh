#!/usr/bin/env bash
# Every EXIT trap in the scheduler libs goes through chain_exit_trap: a bare trap replaces the engine canary's trap (#753).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bad="$(grep -nE "trap +['\"].*EXIT" "$dir"/*.sh | grep -v '\.test\.sh:' | grep -v 'lint-exempt' || true)"
[[ -z "$bad" ]] || { printf 'exit-trap-lint.test.sh: bare EXIT trap, use chain_exit_trap:\n%s\n' "$bad" >&2; exit 1; }
# Test files that source test-env.sh: a bare EXIT trap that never names the root replaces its cleanup. The baseline only shrinks.
root="${EXIT_TRAP_ROOT:-$(cd -- "$dir/../../.." && pwd -P)}"
base="${EXIT_TRAP_BASELINE:-$dir/exit-trap-baseline.txt}"
clean() { sed '/^$/d' | sort -u; }
now="$(cd -- "$root" && grep -rl --include='*.test.sh' 'test-env\.sh' engine | xargs -r grep -EH "trap +['\"].*EXIT" | grep -v test_env_root | cut -d: -f1 | sort -u || :)"
new_bad="$(comm -23 <(printf '%s\n' "$now" | clean) <(clean < "$base"))"
stale="$(comm -13 <(printf '%s\n' "$now" | clean) <(clean < "$base"))"
[[ -z "$new_bad" ]] || { printf 'exit-trap-lint.test.sh: bare EXIT trap in a test, name $test_env_root in the trap:\n%s\n' "$new_bad" >&2; exit 1; }
[[ -z "$stale" ]] || { printf 'exit-trap-lint.test.sh: fixed, remove from exit-trap-baseline.txt:\n%s\n' "$stale" >&2; exit 1; }
echo 'exit-trap-lint.test.sh: all assertions passed'
