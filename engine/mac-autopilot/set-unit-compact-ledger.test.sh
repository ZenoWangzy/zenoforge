#!/usr/bin/env bash
# set_unit writes the unit ledger as one compact line, reads the row count and old stage in one jq call, and keeps rc 3 on a missing id.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/set-unit-compact-ledger"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[{"id":"u1","stage":"implement-pending","history":[]},{"id":"u2","stage":"parked","history":[]}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "set-unit-compact-ledger.test.sh: $*" >&2; exit 1; }
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
calls="$fixture/units-jqf-calls"
transitions="$fixture/footprint-transitions"
: > "$LOG"

# Count jqf calls that read the ledger, and record the old and new stage that set_unit hands to the footprint hook.
eval "$(declare -f jqf | sed '1s/^jqf /jqf_real /')"
jqf() { case "$*" in *"$UNITS"*) echo call >> "$calls" ;; esac; jqf_real "$@"; }
footprint_owner_transition() { echo "$1 $2 $3" >> "$transitions"; }

: > "$calls"
set_unit u1 '.note="counted"' || fail "set_unit returned rc $?"
[[ "$(wc -l < "$UNITS")" == 1 ]] || fail "ledger is not one line after set_unit: $(wc -l < "$UNITS") lines"
# #1332 removed the post-write unit_field read: set_unit takes the new stage from the row it already holds (units.sh new_unit), so 2 reads of the ledger.
[[ "$(wc -l < "$calls")" == 2 ]] || fail "set_unit read the ledger $(wc -l < "$calls") times, want 2"
jq -e '.units[0].note == "counted"' "$UNITS" >/dev/null || fail 'the update did not land'

: > "$transitions"
set_unit u2 '.stage="review-pending"' || fail "stage change returned rc $?"
[[ "$(cat "$transitions")" == 'u2 parked review-pending' ]] || fail "footprint hook got '$(cat "$transitions")', want 'u2 parked review-pending'"
[[ "$(wc -l < "$UNITS")" == 1 ]] || fail 'ledger not one line after a stage change'
jq -e '.units[1].stage == "review-pending"' "$UNITS" >/dev/null || fail 'the stage change did not land'

before="$(cat "$UNITS")"
rc=0; set_unit nope '.note="lost"' || rc=$?
[[ "$rc" == 3 ]] || fail "set_unit on a missing id returned rc $rc, want 3"
grep -Fq 'ledger-write-missed unit=nope caller=' "$LOG" || fail "no ledger-write-missed line: $(cat "$LOG")"
[[ "$(cat "$UNITS")" == "$before" ]] || fail 'a missing id changed the ledger'

echo 'ok - set_unit writes one compact line, reads the old stage and row count in one call, and keeps rc 3'
