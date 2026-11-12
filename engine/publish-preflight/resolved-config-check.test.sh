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
engine_sha=0123456789abcdef0123456789abcdef01234567
printf 'zenoforge_sha=%s\n' "$engine_sha" > "$t/new/BUILD-INFO"
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
printf 'prompts/guide.md\tprompt update\t%s\n' "$engine_sha" > "$t/intended.tsv"
out=$(run "$t/intended.tsv" 2>&1) && { echo "FAIL: unlisted config change should fail"; exit 1; }
grep -q 'changed as intended prompts/guide.md' <<<"$out" || { echo "FAIL: $out"; exit 1; }
printf 'prompts/guide.md\tstale prompt update\t%s\n' "${engine_sha%?}f" > "$t/stale.tsv"
out=$(run "$t/stale.tsv" 2>&1) && { echo "FAIL: stale intended row approved a change"; exit 1; }
grep -Fq "intended-changes: ignoring stale row prompts/guide.md (sha ${engine_sha%?}f, new engine $engine_sha)" <<<"$out" \
  && grep -q 'CHANGED prompts/guide.md' <<<"$out" || { echo "FAIL: stale row was not warned and ignored: $out"; exit 1; }
printf 'prompts/guide.md\tlegacy prompt update\n' > "$t/legacy.tsv"
out=$(run "$t/legacy.tsv" 2>&1) && { echo "FAIL: legacy intended row approved a change"; exit 1; }
grep -Fq "intended-changes: ignoring stale row prompts/guide.md (sha missing, new engine $engine_sha)" <<<"$out" \
  && grep -q 'CHANGED prompts/guide.md' <<<"$out" || { echo "FAIL: legacy row was not warned and ignored: $out"; exit 1; }
cp "$t/base/engine/state/item.json" "$t/repo/.zenoforge/state/item.json" && git -C "$t/repo" commit -qam fix
run "$t/intended.tsv" >/dev/null || { echo "FAIL: fixed tree flagged"; exit 1; }
# Content rows approve by the sha256 of the new resolved file, whatever the engine SHA.
resolved_hash=$(sha256sum "$t/repo/.zenoforge/prompts/guide.md" | cut -d' ' -f1)
printf 'prompts/guide.md\tcontent approval\tsha256:%s\n' "${resolved_hash:0:12}" > "$t/content.tsv"
out=$(run "$t/content.tsv" 2>&1) || { echo "FAIL: matching content row refused: $out"; exit 1; }
grep -q 'changed as intended prompts/guide.md' <<<"$out" || { echo "FAIL: content row not reported as intended: $out"; exit 1; }
printf 'prompts/guide.md\tcontent approval\tsha256:%s\n' "$resolved_hash" > "$t/content-full.tsv"
run "$t/content-full.tsv" >/dev/null 2>&1 || { echo "FAIL: full-length content row refused"; exit 1; }
printf 'prompts/guide.md\twrong content\tsha256:ffffffffffff\n' > "$t/content-wrong.tsv"
out=$(run "$t/content-wrong.tsv" 2>&1) && { echo "FAIL: non-matching content row approved a change"; exit 1; }
grep -Fq "intended-changes: ignoring stale row prompts/guide.md (sha sha256:ffffffffffff, new engine $engine_sha, new hash ${resolved_hash:0:12})" <<<"$out" \
  && grep -q 'CHANGED prompts/guide.md' <<<"$out" || { echo "FAIL: wrong content row was not warned and ignored: $out"; exit 1; }
printf 'prompts/guide.md\ttoo short\tsha256:%s\n' "${resolved_hash:0:11}" > "$t/content-short.tsv"
run "$t/content-short.tsv" >/dev/null 2>&1 && { echo "FAIL: 11-hex content prefix approved a change"; exit 1; }
printf 'prompts/guide.md\t\tsha256:%s\n' "${resolved_hash:0:12}" > "$t/content-noreason.tsv"
rc=0; run "$t/content-noreason.tsv" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "FAIL: content row without reason accepted (rc=$rc)"; exit 1; }
# The hash is over the resolved file: the target overlay wins over the engine source, so a prefix of the engine-only bytes does not approve it.
echo 'engine source content' > "$t/new/engine/prompts/guide.md"
engine_only_hash=$(sha256sum "$t/new/engine/prompts/guide.md" | cut -d' ' -f1)
printf 'prompts/guide.md\tengine bytes\tsha256:%s\n' "${engine_only_hash:0:12}" > "$t/content-engine.tsv"
out=$(run "$t/content-engine.tsv" 2>&1) && { echo "FAIL: row for engine-only bytes approved an overlaid file"; exit 1; }
grep -q 'CHANGED prompts/guide.md' <<<"$out" && grep -Fq "new hash ${resolved_hash:0:12}" <<<"$out" || { echo "FAIL: overlay case: $out"; exit 1; }
run "$t/content.tsv" >/dev/null 2>&1 || { echo "FAIL: resolved-hash row refused once an engine copy exists"; exit 1; }
rm "$t/new/engine/prompts/guide.md"
printf 'prompts/guide.md\t\n' > "$t/bad.tsv"
rc=0; run "$t/bad.tsv" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "FAIL: entry without reason accepted (rc=$rc)"; exit 1; }
# An unreadable engine file fails the check instead of being skipped.
if [[ $EUID != 0 ]]; then
  chmod 000 "$t/new/engine/reader.sh"
  rc=0; run "$t/intended.tsv" >/dev/null 2>&1 || rc=$?
  chmod 644 "$t/new/engine/reader.sh"
  [[ $rc == 2 ]] || { echo "FAIL: unreadable engine file skipped (rc=$rc)"; exit 1; }
fi
echo "resolved-config-check.test.sh: PASS"
