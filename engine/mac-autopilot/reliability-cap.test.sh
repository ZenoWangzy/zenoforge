#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

A="$test_env_root/reliability-breach/autopi"
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
# expect <label> <want log lines so far>: one tick of the read, which must leave the cap alone
expect() {
  IMPLEMENT_CAP=8
  log_reliability_breach
  [[ "$IMPLEMENT_CAP" == 8 ]] || fail "$1: cap changed to $IMPLEMENT_CAP"
  [[ "$(grep -c 'reliability breach' "$LOG" || true)" == "$2" ]] || fail "$1: want $2 log lines"
}

expect 'no scorecard' 0
scorecard "$NOW_EPOCH" OK OK;                     expect 'healthy' 0
scorecard "$NOW_EPOCH" UNHEALTHY OK;              expect 'revert breach' 1
scorecard "$NOW_EPOCH" UNHEALTHY OK;              expect 'breach persists' 1
scorecard "$NOW_EPOCH" WARN OK;                   expect 'warn band holds' 1
scorecard "$NOW_EPOCH" WARN UNHEALTHY;            expect 'second metric joins' 2
scorecard "$NOW_EPOCH" OK WARN;                   expect 'revert recovered, main red held' 3
scorecard "$((NOW_EPOCH - 7201))" OK OK;          expect 'stale scorecard logs nothing' 3
printf '{broken' > "$A/node-health.json";         expect 'unreadable scorecard logs nothing' 3
NOW_EPOCH=$((NOW_EPOCH + 5400))
scorecard "$NOW_EPOCH" OK OK;                     expect 'full recovery' 4
grep -Fq 'breached=[] secs=5400' "$LOG" || fail 'recovery line lacks secs=5400 since the first breach'
grep -Fq '"breached":[]' "$A/reliability-breach.json" || fail 'state not cleared after recovery'
echo 'ok - breach logs once per change, WARN holds it, recovery logs secs, the cap never moves'
