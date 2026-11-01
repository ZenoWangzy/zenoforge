#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/resolved-config"
for v in base new; do
  mkdir -p "$t/$v/engine/prompts"
  printf '%s\n' 'p="$(zf_config_file state/item.json)"' 'q="$(zf_config_file "prompts/$name.md")"' > "$t/$v/engine/reader.sh"
  echo "zfConfigFile('state/same.json')" > "$t/$v/engine/reader.mjs"
done
mkdir -p "$t/base/engine/state"
echo '{"label":"stable"}' > "$t/base/engine/state/item.json"
echo '{"value":1}' > "$t/base/engine/state/same.json"
echo 'initial prompt' > "$t/base/engine/prompts/guide.md"
git -C "$t" init -q repo && git -C "$t/repo" config user.email test && git -C "$t/repo" config user.name test
mkdir -p "$t/repo/.zenoforge"; touch "$t/repo/.zenoforge/.keep"
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm base && base=$(git -C "$t/repo" rev-parse HEAD)
# The target config changes bytes, while the same-byte move and engine-resolved prompt are safe.
mkdir -p "$t/repo/.zenoforge/state" "$t/repo/.zenoforge/prompts"
echo '{"label":"changed"}' > "$t/repo/.zenoforge/state/item.json"
cp "$t/base/engine/state/same.json" "$t/repo/.zenoforge/state/same.json"
echo 'updated prompt' > "$t/repo/.zenoforge/prompts/guide.md"
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm new
run() { python3 -I "$here/resolved-config-check.py" "$t/base" "$t/repo" "$base" "$t/new" "$t/repo" HEAD "$@"; }
out=$(run 2>&1) && { echo "FAIL: expected non-zero"; exit 1; }
grep -q 'CHANGED state/item.json' <<<"$out" && grep -q 'CHANGED prompts/guide.md' <<<"$out" || { echo "FAIL: $out"; exit 1; }
grep -q 'same.json' <<<"$out" && { echo "FAIL: byte-equal move flagged: $out"; exit 1; }
printf 'prompts/guide.md\tprompt update\n' > "$t/intended.tsv"
out=$(run "$t/intended.tsv" 2>&1) && { echo "FAIL: unlisted config change should fail"; exit 1; }
grep -q 'changed as intended prompts/guide.md' <<<"$out" || { echo "FAIL: $out"; exit 1; }
cp "$t/base/engine/state/item.json" "$t/repo/.zenoforge/state/item.json" && git -C "$t/repo" commit -qam fix
run "$t/intended.tsv" >/dev/null || { echo "FAIL: fixed tree flagged"; exit 1; }
printf 'prompts/guide.md\t\n' > "$t/bad.tsv"
rc=0; run "$t/bad.tsv" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "FAIL: entry without reason accepted (rc=$rc)"; exit 1; }
echo "resolved-config-check.test.sh: PASS"
