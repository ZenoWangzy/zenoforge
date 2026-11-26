#!/usr/bin/env bash
# The exit-trap ratchet: a new bare EXIT trap fails, a baseline offender passes, a fixed baseline entry fails.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
lint="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/exit-trap-lint.test.sh"
fx="$(mktemp -d)"
trap 'rm -rf -- "$fx" "$test_env_root"' EXIT
mkdir -p "$fx/engine"
exit_sig=EXIT
printf '#!/usr/bin/env bash\nsource "$1/test-env.sh"\ntrap %s %s\n' "'rm -rf \"\$t\"'" "$exit_sig" > "$fx/engine/bare.test.sh"
printf '#!/usr/bin/env bash\nsource "$1/test-env.sh"\ntrap %s %s\n' "'rm -rf -- \"\$test_env_root\"'" "$exit_sig" > "$fx/engine/clean.test.sh"
run_lint() { EXIT_TRAP_ROOT="$fx" EXIT_TRAP_BASELINE="$fx/baseline.txt" bash "$lint" 2>&1; }

printf 'engine/bare.test.sh\n' > "$fx/baseline.txt"
run_lint >/dev/null || { echo 'exit-trap-ratchet.test.sh: a baseline offender failed the lint' >&2; exit 1; }
: > "$fx/baseline.txt"
if out=$(run_lint); then echo 'exit-trap-ratchet.test.sh: a new offender passed the lint' >&2; exit 1; fi
[[ $out == *'REFUSAL found="bare EXIT trap in test without test_env_root"'*'alternative="name test_env_root in the trap"'*'documented_in=docs/enforced-rules.md'* ]] || { echo "exit-trap-ratchet.test.sh: refusal lacked its finding, alternative or documentation: $out" >&2; exit 1; }
printf 'engine/bare.test.sh\nengine/clean.test.sh\n' > "$fx/baseline.txt"
if out=$(run_lint); then echo 'exit-trap-ratchet.test.sh: a fixed baseline entry passed the lint' >&2; exit 1; fi
[[ $out == *'REFUSAL found="fixed test remains in exit-trap-baseline.txt"'*'alternative="remove the stale path from exit-trap-baseline.txt"'*'documented_in=docs/enforced-rules.md'* ]] || { echo "exit-trap-ratchet.test.sh: stale refusal lacked its finding, alternative or documentation: $out" >&2; exit 1; }
echo 'exit-trap-ratchet.test.sh: all assertions passed'
