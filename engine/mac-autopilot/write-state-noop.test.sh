#!/usr/bin/env bash
# write_state on bytes the file already holds must not rewrite it: a rewrite bumps the mtime, which drops every cached ledger view.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/write-state-noop"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[{"id":"u1","stage":"implement-pending"}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
fail() { echo "write-state-noop.test.sh: $*" >&2; exit 1; }
jqf '.' "$UNITS" | write_state "$UNITS" || fail 'the normalising write was refused' # the fixture's one-line file is not jq's own formatting
before="$(stat -c '%i' "$UNITS")"
jqf '.' "$UNITS" | write_state "$UNITS" || fail 'an identical write was refused'
[[ "$(stat -c '%i' "$UNITS")" == "$before" ]] || fail 'an identical write replaced the ledger file'
[[ -z "$(find "$A" -maxdepth 1 -name 'units.json.tmp.*' -print -quit)" ]] || fail 'an identical write left its temp file'
jqf '.units[0].stage = "review-pending"' "$UNITS" | write_state "$UNITS" || fail 'a changed write was refused'
[[ "$(stat -c '%i' "$UNITS")" != "$before" ]] || fail 'a changed write did not replace the ledger file'
jq -e '.units[0].stage == "review-pending"' "$UNITS" >/dev/null || fail 'a changed write lost its change'
if printf '%s\n' '{"units":[{"id":"u1"}]}' | write_state "$UNITS" 2>/dev/null; then fail 'an invalid shape was accepted'; fi
jq -e '.units[0].stage == "review-pending"' "$UNITS" >/dev/null || fail 'an invalid write replaced the ledger'
echo 'ok - write_state skips identical bytes and still validates a real change'
