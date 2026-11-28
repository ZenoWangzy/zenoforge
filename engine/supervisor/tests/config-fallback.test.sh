#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
lib="$root/engine/supervisor/lib/config.cjs"
work="$test_env_root/config-fallback"; mkdir -p "$work"
export HOME="$work/home"
default="$HOME/.zenoforge/supervisor/config.json"
load() { node -e 'require(process.argv[1])' "$lib"; }

echo '{}' > "$work/main.json"
rc=0; ZF_SUPERVISOR_CONFIG="$work/main.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL main rc=$rc"; cat "$work/err"; exit 1; }
if [ -s "$work/err" ]; then echo "FAIL warned although main readable"; cat "$work/err"; exit 1; fi

mkdir -p "$(dirname "$default")"
echo '{}' > "$default"
rc=0; env -u ZF_SUPERVISOR_CONFIG node -e 'require(process.argv[1])' "$lib" > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL default rc=$rc"; cat "$work/err"; exit 1; }
[ ! -s "$work/err" ] || { echo "FAIL default emitted a warning"; cat "$work/err"; exit 1; }

rm -f "$default"
rc=0; ZF_SUPERVISOR_CONFIG="$work/missing.json" load > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 1 ] || { echo "FAIL both missing rc=$rc, want 1"; exit 1; }
grep -qx 'zenoforge supervisor: config unavailable; set ZF_SUPERVISOR_CONFIG or create ~/.zenoforge/supervisor/config.json' "$work/err" || { echo "FAIL error names only supported config sources"; cat "$work/err"; exit 1; }

echo "config source ok"
