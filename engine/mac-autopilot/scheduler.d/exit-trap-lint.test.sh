#!/usr/bin/env bash
# Every EXIT trap in the scheduler libs goes through chain_exit_trap: a bare trap replaces the engine canary's trap (#753).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bad="$(grep -nE "trap +['\"].*EXIT" "$dir"/*.sh | grep -v '\.test\.sh:' | grep -v 'lint-exempt' || true)"
[[ -z "$bad" ]] || { printf 'REFUSAL found="bare EXIT trap in scheduler library" alternative="use chain_exit_trap" documented_in=docs/enforced-rules.md; offending lines:\n%s\n' "$bad" >&2; exit 1; }
awk '/^    \[\[ -z "\$config_temp" \]\] \|\| rm -f "\$config_temp"$/ { if (prev == "    fi") found=1 } { prev=$0 } END { exit !found }' "$dir/self-check.sh" || { echo 'REFUSAL found="config cleanup is outside the verdict subshell" alternative="put config cleanup after the verdict inside the subshell" documented_in=docs/enforced-rules.md' >&2; exit 1; }
# Test files that source test-env.sh: a bare EXIT trap that never names the root replaces its cleanup. The baseline only shrinks.
root="${EXIT_TRAP_ROOT:-$(cd -- "$dir/../../.." && pwd -P)}"
base="${EXIT_TRAP_BASELINE:-$dir/exit-trap-baseline.txt}"
clean() { sed '/^$/d' | sort -u; }
now="$(cd -- "$root" && grep -rl --include='*.test.sh' 'test-env\.sh' engine | xargs -r bash "$dir/../../test-exit-trap-check.sh" | sort -u || :)"
new_bad="$(comm -23 <(printf '%s\n' "$now" | clean) <(clean < "$base"))"
stale="$(comm -13 <(printf '%s\n' "$now" | clean) <(clean < "$base"))"
[[ -z "$new_bad" ]] || { printf 'REFUSAL found="bare EXIT trap in test without test_env_root" alternative="name test_env_root in the trap" documented_in=docs/enforced-rules.md; offending files:\n%s\n' "$new_bad" >&2; exit 1; }
[[ -z "$stale" ]] || { printf 'REFUSAL found="fixed test remains in exit-trap-baseline.txt" alternative="remove the stale path from exit-trap-baseline.txt" documented_in=docs/enforced-rules.md; files:\n%s\n' "$stale" >&2; exit 1; }
echo 'exit-trap-lint.test.sh: all assertions passed'
