#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

fail() { printf 'size-ratchet.test.sh: %s\n' "$*" >&2; exit 1; }

# The real tree passes against its committed baseline (the ratchet is live in CI through this check).
bash "$MODEL_POLICY_TEST_REPO/tools/size-ratchet.sh" > "$test_env_root/real.out" || fail "current tree fails: $(cat "$test_env_root/real.out")"

repo="$test_env_root/ratchet"
mkdir -p "$repo/tools" "$repo/engine/vendor"
cp "$MODEL_POLICY_TEST_REPO/tools/size-ratchet.sh" "$repo/tools/"
git init -q -b main "$repo"
cd "$repo"
seq 1 900 > engine/big.sh
seq 1 100 > engine/small.sh
printf '900\tengine/big.sh\n' > tools/size-baseline.txt
git add -A
run() { bash tools/size-ratchet.sh 2>&1 || true; }
fails() { if bash tools/size-ratchet.sh > out.txt 2>&1; then return 1; fi; cat out.txt; }

[[ "$(run)" == 'size-ratchet ok' ]] || fail 'a file at its baseline was refused'

seq 1 901 > engine/big.sh
msg=$(fails) || fail 'a grown file passed'
[[ $msg == *'REFUSAL found="engine/big.sh has 901 lines'*'alternative="'*'documented_in=docs/enforced-rules.md'* ]] || fail "grow refusal lacks finding, alternative or documentation: $msg"

seq 1 850 > engine/big.sh
out=$(run)
[[ $out == *'NOTE engine/big.sh shrank to 850'*'lower its baseline'* && $out == *'size-ratchet ok' ]] || fail "shrink was not allowed with a lower-baseline note: $out"

seq 1 801 > engine/new.sh
msg=$(fails) || fail 'a new file over the cap passed'
[[ $msg == *'REFUSAL found="engine/new.sh has 801 lines'*'alternative="'*'documented_in=docs/enforced-rules.md'* ]] || fail "new-file refusal lacks finding, alternative or documentation: $msg"
seq 1 800 > engine/new.sh

seq 1 900 > engine/vendor/x.sh
seq 1 900 > engine/big.test.sh
seq 1 900 > engine/notes.md
out=$(run)
[[ $out == *'size-ratchet ok' && $out != *FAIL* ]] || fail "vendor, test or non-source file was counted: $out"
