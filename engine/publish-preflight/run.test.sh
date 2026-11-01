#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/publish-preflight"
mkdir -p "$t/live/engine/state" "$t/new/engine/state" "$t/repo/.zenoforge/state"
printf '%s\n' 'value="$(zf_config_file state/value.json)"' > "$t/live/engine/reader.sh"
cp "$t/live/engine/reader.sh" "$t/new/engine/reader.sh"
echo '{"value":"same"}' > "$t/live/engine/state/value.json"
cp "$t/live/engine/state/value.json" "$t/new/engine/state/value.json"
echo '{"value":"same"}' > "$t/repo/.zenoforge/state/value.json"
echo '{"pipeline_suite_roots":[]}' > "$t/repo/.zenoforge/ci.json"
git -C "$t" init -q repo && git -C "$t/repo" config user.email test && git -C "$t/repo" config user.name test
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm initial
base_ref=$(git -C "$t/repo" rev-parse HEAD)
out=$(bash "$here/run.sh" "$t/live" "$t/new" "$t/repo" "$base_ref" "$base_ref" 2>&1) || { echo "FAIL: clean preflight: $out"; exit 1; }
grep -q 'unit-paths-check: OK' <<<"$out" && grep -q 'resolved-config-check: OK' <<<"$out" \
  && grep -q 'suite-set-check: OK' <<<"$out" || { echo "FAIL: missing successful check: $out"; exit 1; }

# A live unit path failure stops the runner before resolved-config or suite checks.
mkdir -p "$t/live/engine" "$HOME/.config/systemd/user"
touch "$t/live/engine/retained.sh"
echo 'ExecStart=/bin/bash %h/.agent/engine-live/retained.sh' > "$HOME/.config/systemd/user/example.service"
out=$(bash "$here/run.sh" "$t/live" "$t/new" "$t/repo" "$base_ref" "$base_ref" 2>&1) && { echo "FAIL: expected unit-path failure"; exit 1; }
grep -q 'publish-preflight: unit-paths check failed' <<<"$out" \
  && ! grep -q 'resolved-config-check:' <<<"$out" || { echo "FAIL: did not stop at unit-path failure: $out"; exit 1; }
rm "$HOME/.config/systemd/user/example.service"

# A resolved config change fails when no intended list is supplied.
echo '{"value":"changed"}' > "$t/repo/.zenoforge/state/value.json"
git -C "$t/repo" add -A && git -C "$t/repo" commit -qm changed
new_ref=$(git -C "$t/repo" rev-parse HEAD)
out=$(bash "$here/run.sh" "$t/live" "$t/new" "$t/repo" "$base_ref" "$new_ref" 2>&1) && { echo "FAIL: unlisted config change passed"; exit 1; }
grep -q 'CHANGED state/value.json' <<<"$out" && grep -q 'publish-preflight: resolved-config check failed' <<<"$out" \
  && ! grep -q 'suite-set-check: OK' <<<"$out" || { echo "FAIL: did not stop at config failure: $out"; exit 1; }
printf 'state/value.json\tplanned update\n' > "$t/intended.tsv"
out=$(bash "$here/run.sh" "$t/live" "$t/new" "$t/repo" "$base_ref" "$new_ref" "$t/intended.tsv" 2>&1) \
  || { echo "FAIL: intended config change: $out"; exit 1; }
grep -q 'changed as intended state/value.json' <<<"$out" && grep -q 'suite-set-check: OK' <<<"$out" \
  || { echo "FAIL: intended change was not accepted: $out"; exit 1; }
echo "run.test.sh: PASS"
