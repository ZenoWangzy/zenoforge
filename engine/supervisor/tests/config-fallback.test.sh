#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
lib="$root/engine/supervisor/lib/config.cjs"
work="$test_env_root/config-fallback"; mkdir -p "$work"
export HOME="$work/home"
fallback="$HOME/.vecta-agent/checkout/.zenoforge/supervisor/config.json"
mkdir -p "$(dirname "$fallback")"
load() { node -e 'require(process.argv[1])' "$lib"; }

echo '{}' > "$fallback"
rc=0; ZF_SUPERVISOR_CONFIG="$work/missing.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL fallback rc=$rc"; cat "$work/err"; exit 1; }
grep -q 'config fallback in use' "$work/err" || { echo "FAIL no fallback warning"; cat "$work/err"; exit 1; }

echo '{}' > "$work/main.json"
rc=0; ZF_SUPERVISOR_CONFIG="$work/main.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL main rc=$rc"; cat "$work/err"; exit 1; }
if grep -q 'fallback' "$work/err"; then echo "FAIL warned although main readable"; exit 1; fi

rm -f "$fallback"
rc=0; ZF_SUPERVISOR_CONFIG="$work/missing.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 1 ] || { echo "FAIL both missing rc=$rc, want 1"; exit 1; }
grep -q "$work/missing.json" "$work/err" && grep -q "$fallback" "$work/err" || { echo "FAIL error does not list both paths"; cat "$work/err"; exit 1; }

echo "config-fallback ok"
