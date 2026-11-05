#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

A="$test_env_root/reliability-cap/autopi"
LOG="$A/scheduler.log"
UNITS="$A/units.json"
WORKERS="$A/workers.json"
STAMP=2026-11-05T00:00:00Z
NOW_EPOCH=1793836800
mkdir -p "$A"
: > "$LOG"
source "$script_dir/scheduler.d/core.sh"
source "$script_dir/scheduler.d/reports.sh"
source "$script_dir/scheduler.d/health-release.sh"

fail() { echo "not ok - $*" >&2; cat "$LOG" >&2; exit 1; }
# scorecard <generated epoch> <revert status> <main-red status>
scorecard() {
  jq -n --arg at "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)" --arg r "$2" --arg m "$3" \
    '{generated_at:$at,metrics:[{id:"delivery.revert_rate_30d_pct",status:$r},{id:"flow.main_red_hours",status:$m}]}' > "$A/node-health.json"
}
# expect <label> <want cap>: one tick of the cap read, from the configured 8
expect() {
  IMPLEMENT_CAP=8
  apply_reliability_cap
  [[ "$IMPLEMENT_CAP" == "$2" ]] || fail "$1: cap $IMPLEMENT_CAP, want $2"
}
logged() { grep -c 'implement-cap throttle' "$LOG" || true; }

expect 'no scorecard' 8
scorecard "$NOW_EPOCH" OK OK;                     expect 'healthy' 8
scorecard "$NOW_EPOCH" UNHEALTHY OK;              expect 'revert breach' 4
scorecard "$NOW_EPOCH" UNHEALTHY OK;              expect 'breach persists' 4
scorecard "$NOW_EPOCH" WARN OK;                   expect 'warn band holds' 4
scorecard "$NOW_EPOCH" WARN UNHEALTHY;            expect 'second metric joins' 4
scorecard "$NOW_EPOCH" OK WARN;                   expect 'revert recovered, main red held' 4
scorecard "$((NOW_EPOCH - 7201))" OK OK;          expect 'stale scorecard keeps configured cap' 8
printf '{broken' > "$A/node-health.json";         expect 'unreadable scorecard keeps configured cap' 8
NOW_EPOCH=$((NOW_EPOCH + 5400))
scorecard "$NOW_EPOCH" OK OK;                     expect 'full recovery' 8
grep -Fq 'breached=[] cap=8->8 secs=5400' "$LOG" || fail 'recovery line lacks secs=5400 since the first breach'
[[ "$(logged)" == 4 ]] || fail "want 4 throttle log lines (breach, add, partial, recover), got $(logged)"
grep -Fq '"breached":[]' "$A/implement-cap-throttle.json" || fail 'state not cleared after recovery'
echo 'ok - breach lowers the cap, WARN holds it, recovery restores it, bad scorecard keeps configured'
