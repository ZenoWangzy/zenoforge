#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

fail() { printf 'shortcut-ratchet.test.sh: %s\n' "$*" >&2; exit 1; }

real=$(bash "$MODEL_POLICY_TEST_REPO/tools/shortcut-ratchet.sh" 2>&1) || fail "current tree fails: $real"
[[ $real == 'shortcut-ratchet ok' ]] || fail "current tree did not report success: $real"

repo="$test_env_root/ratchet"
mkdir -p "$repo/tools" "$repo/engine/vendor"
cp "$MODEL_POLICY_TEST_REPO/tools/shortcut-ratchet.sh" "$repo/tools/"
git init -q -b main "$repo"
cd "$repo"
printf '# shortcut: a limit, upgrade later\n' > engine/a.sh
printf '1\tengine/a.sh\n' > tools/shortcut-baseline.txt
run() { bash tools/shortcut-ratchet.sh 2>&1 || true; }
fails() { if bash tools/shortcut-ratchet.sh > out.txt 2>&1; then return 1; fi; cat out.txt; }

[[ "$(run)" == 'shortcut-ratchet ok' ]] || fail 'a file at its baseline was refused'

printf '# shortcut: another limit, upgrade later\n' >> engine/a.sh
msg=$(fails) || fail 'a grown file passed'
[[ $msg == *'REFUSAL found="engine/a.sh has 2 shortcut comments'*'alternative="'*'documented_in=docs/enforced-rules.md'* ]] || fail "grow refusal lacks finding, alternative or documentation: $msg"

printf '# shortcut: a new limit, upgrade later\n' > engine/b.sh
msg=$(fails) || fail 'a new file with a marker passed'
[[ $msg == *'REFUSAL found="engine/b.sh has 1 shortcut comments'*'alternative="'*'documented_in=docs/enforced-rules.md'* ]] || fail "new-file refusal lacks finding, alternative or documentation: $msg"
rm engine/b.sh

printf '# no marker remains\n' > engine/a.sh
out=$(run)
[[ $out == *'NOTE engine/a.sh has no shortcut comments left'*'run bash tools/shortcut-ratchet.sh --tighten'*'shortcut-ratchet ok' ]] || fail "removing markers was not allowed with a tighten note: $out"
bash tools/shortcut-ratchet.sh --tighten > tighten.out || fail 'tightening after removal failed'
if grep -q $'\tengine/a.sh$' tools/shortcut-baseline.txt; then fail 'tighten kept an empty baseline row'; fi
[[ "$(run)" == 'shortcut-ratchet ok' ]] || fail 'tightened baseline was refused'

printf '# shortcut: ignored vendor marker\n' > engine/vendor/x.sh
printf '# shortcut: ignored test marker\n' > engine/c.test.sh
out=$(run)
[[ $out == *'shortcut-ratchet ok' && $out != *FAIL* ]] || fail "vendor or test marker was counted: $out"

printf '# shortcut: grown marker, upgrade later\n# shortcut: another grown marker, upgrade later\n' > engine/a.sh
cp tools/shortcut-baseline.txt before.txt
msg=$(fails) || fail 'a grown count passed before tighten'
[[ $msg == *'engine/a.sh has 2 shortcut comments'* ]] || fail "grown count was not named: $msg"
if bash tools/shortcut-ratchet.sh --tighten > out.txt 2>&1; then fail '--tighten accepted a grown count'; fi
cmp -s before.txt tools/shortcut-baseline.txt || fail '--tighten changed the baseline after growth'
