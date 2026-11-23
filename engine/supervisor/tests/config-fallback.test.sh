#!/usr/bin/env bash
# Focused test for the config.cjs fallback. Run only this file: bash engine/supervisor/tests/config-fallback.test.sh
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
lib="$root/engine/supervisor/lib/config.cjs"
work=$(mktemp -d "${TMPDIR:-/tmp}/config-fallback.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
fallback="$HOME/.vecta-agent/checkout/.zenoforge/supervisor/config.json"
mkdir -p "$(dirname "$fallback")"
load() { node -e 'require(process.argv[1])' "$lib"; }

# 1. main missing, fallback readable: loads, warns once on stderr
echo '{}' > "$fallback"
rc=0; ZF_SUPERVISOR_CONFIG="$work/missing.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL fallback rc=$rc"; cat "$work/err"; exit 1; }
grep -q 'config fallback in use' "$work/err" || { echo "FAIL no fallback warning"; cat "$work/err"; exit 1; }

# 2. main readable: no fallback warning
echo '{}' > "$work/main.json"
rc=0; ZF_SUPERVISOR_CONFIG="$work/main.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL main rc=$rc"; cat "$work/err"; exit 1; }
if grep -q 'fallback' "$work/err"; then echo "FAIL warned although main readable"; exit 1; fi

# 3. main and fallback both missing: exit 1, error lists every path tried
rm -f "$fallback"
rc=0; ZF_SUPERVISOR_CONFIG="$work/missing.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 1 ] || { echo "FAIL both missing rc=$rc, want 1"; exit 1; }
grep -q "$work/missing.json" "$work/err" && grep -q "$fallback" "$work/err" || { echo "FAIL error does not list both paths"; cat "$work/err"; exit 1; }

echo "config-fallback ok"
