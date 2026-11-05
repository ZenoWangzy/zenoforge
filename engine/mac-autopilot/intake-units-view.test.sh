#!/usr/bin/env bash
# intake_units_view keeps the fields the per-row reads use, drops the bulk, and follows every units.json write.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
jqf() { command jq "$@"; }
eval "$(sed -n '/^intake_units_view() {$/,/^}$/p' "$here/scheduler.d/intake.sh")"
UNITS="$test_env_root/units.json"
fail() { echo "not ok - intake-units-view.test.sh: $*" >&2; exit 1; }
printf '%s' '{"units":[{"id":"a","issue":1,"pr":2,"stage":"merged","history":["x"],"task":"t","review_findings":[1],"hold_handoff_episode":"e"}],"top":1}' > "$UNITS"
view="$(intake_units_view)"
[[ "$view" == "$UNITS.view" ]] || fail 'view path'
jq -e '.top == 1 and .units == [{"id":"a","issue":1,"pr":2,"stage":"merged","hold_handoff_episode":"e"}]' "$view" >/dev/null || fail 'wrong view fields'
sleep 0.05
tmp="$UNITS.new"; jq '.units[0].stage = "closed"' "$UNITS" > "$tmp"; mv -f -- "$tmp" "$UNITS"
jq -e '.units[0].stage == "closed"' "$(intake_units_view)" >/dev/null || fail 'view missed a units.json write'
printf '%s' 'not json' > "$UNITS"
[[ "$(intake_units_view 2>/dev/null)" == "$UNITS" ]] || fail 'a failed build must fall back to units.json'
compgen -G "$UNITS.view.tmp.*" >/dev/null && fail 'temp file left behind'
echo 'ok - intake units view'
