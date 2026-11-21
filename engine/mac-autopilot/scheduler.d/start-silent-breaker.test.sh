#!/usr/bin/env bash
# Start-silent breaker (queue row 935): the newest implement/repair/supervise workers that all wrote 0 bytes hold starts, except one
# probe per probe window; a counted byte or a new engine build closes it. Stubs only: no process start, no sleep, no GitHub call.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/start-silent-breaker"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent" \
  "$fixture/engine-versions/build-abc/engine" "$fixture/engine-versions/build-def/engine"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

A="$MAC_AUTOPILOT_RUNTIME_DIR"
SUP="$MAC_AUTOPILOT_SUPERVISOR_DIR"
WORKERS="$A/workers.json"
LOG="$A/scheduler.log"
SLO="$A/alerts/slo.md"
STATE="$A/start-silent-breaker.json"
STAMP="2026-11-21T22:00:00Z"
BUILD_ABC="$fixture/engine-versions/build-abc/engine"
BUILD_DEF="$fixture/engine-versions/build-def/engine"
ZF_ENGINE_DIR="$BUILD_ABC"
say() { printf '%s\n' "$*" >> "$LOG"; }

fail() { echo "start-silent-breaker.test.sh: $*" >&2; exit 1; }
ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
rec() { jq -cn --arg type "$1" --arg started "$2" --arg log "$3" '{type:$type,started:$started,log:$log,unit:$log,pid:1}'; }
set_workers() { printf '%s\n' "$@" | jq -s '{workers: .}' > "$WORKERS"; }
silent() { : > "$SUP/$1"; }
busy() { printf 'x' > "$SUP/$1"; }
alerts() { grep -c 'WORKER-START-SILENT' "$SLO" || true; }
reset() { rm -f -- "$STATE" "$LOG" "$SUP"/*.log; : > "$SLO"; unset START_SILENT_DONE START_SILENT_OPEN; ZF_ENGINE_DIR="$BUILD_ABC"; }
expect_rc() { # want-rc command...
  local want="$1" got=0; shift
  "$@" || got=$?
  [[ "$got" == "$want" ]] || fail "$* returned $got, want $want"
}

T_A="$(ago 3400)"; T_B="$(ago 3500)"; T_C="$(ago 3600)"
R_A="$(ago 1600)"; R_B="$(ago 1700)"; R_C="$(ago 1800)"
impl_three() {
  silent impl-a.log; silent impl-b.log; silent impl-c.log
  set_workers "$(rec implement "$T_A" impl-a.log)" "$(rec implement "$T_B" impl-b.log)" "$(rec implement "$T_C" impl-c.log)"
}

# (a) three silent implement records open the breaker: one probe start, one alert naming the build and the oldest counted log
reset; impl_three
expect_rc 0 start_silent_breaker implement
[[ "$(alerts)" == 1 ]] || fail "(a) want 1 alert, got $(alerts)"
grep -qF "WORKER-START-SILENT engine=build-abc silent=3 first_log=impl-c.log since=$T_C dispatch held, probe every 15 min" "$SLO" \
  || fail "(a) alert text wrong: $(cat "$SLO")"
unset START_SILENT_DONE
expect_rc 1 start_silent_breaker review
[[ "$(alerts)" == 1 ]] || fail "(a) second call added an alert: $(alerts)"

# (b1) newer silent claude reviews do not change the decision: still the three implement records, one alert, same first log
reset; impl_three
silent rev-a.log; silent rev-b.log; silent rev-c.log
set_workers "$(rec implement "$T_A" impl-a.log)" "$(rec implement "$T_B" impl-b.log)" "$(rec implement "$T_C" impl-c.log)" \
  "$(rec review "$R_A" rev-a.log)" "$(rec review "$R_B" rev-b.log)" "$(rec review "$R_C" rev-c.log)"
expect_rc 0 start_silent_breaker implement
grep -qF "silent=3 first_log=impl-c.log since=$T_C" "$SLO" || fail "(b1) reviews changed the decision: $(cat "$SLO")"

# (b2) two silent implement records and five silent reviews: closed
reset
silent impl-a.log; silent impl-b.log
for n in 1 2 3 4 5; do silent "rev-$n.log"; done
set_workers "$(rec implement "$T_A" impl-a.log)" "$(rec implement "$T_B" impl-b.log)" \
  "$(rec review "$R_A" rev-1.log)" "$(rec review "$R_A" rev-2.log)" "$(rec review "$R_A" rev-3.log)" \
  "$(rec review "$R_A" rev-4.log)" "$(rec review "$R_A" rev-5.log)"
expect_rc 0 start_silent_breaker review
[[ "$(alerts)" == 0 && ! -e "$STATE" ]] || fail "(b2) two implement records opened the breaker"

# (c) open, then the stored engine name differs: closed, floor set, the old build's records no longer count
reset; impl_three
expect_rc 0 start_silent_breaker implement
[[ -e "$STATE" ]] || fail "(c) no state file after open"
ZF_ENGINE_DIR="$BUILD_DEF"; unset START_SILENT_DONE
expect_rc 0 start_silent_breaker implement
[[ "$(jq -r .engine "$STATE")" == build-def && "$(jq -r .opened_at "$STATE")" == "" && -n "$(jq -r .floor "$STATE")" ]] \
  || fail "(c) build change did not set floor and close: $(cat "$STATE")"
[[ "$(alerts)" == 1 ]] || fail "(c) build change added an alert"

# (d) open: one implement probe is let through, the next inside the probe window is held, a review is held
reset; impl_three
expect_rc 0 start_silent_breaker implement
unset START_SILENT_DONE
expect_rc 1 start_silent_breaker implement
unset START_SILENT_DONE
expect_rc 1 start_silent_breaker review
# (d2) a probe older than the window lets one more start through
jq --arg p "$(ago 1000)" '.last_probe=$p' "$STATE" > "$STATE.tmp" && mv -f -- "$STATE.tmp" "$STATE"
unset START_SILENT_DONE
expect_rc 0 start_silent_breaker implement

# (e) one of the three newest now has bytes: closed, state file gone
reset; impl_three
expect_rc 0 start_silent_breaker implement
[[ -e "$STATE" ]] || fail "(e) no state file after open"
busy impl-a.log
unset START_SILENT_DONE
expect_rc 0 start_silent_breaker implement
[[ ! -e "$STATE" ]] || fail "(e) state file kept after a counted byte"
grep -qF 'start-silent-breaker closed: impl-a.log has output' "$LOG" || fail "(e) no closed line"

echo "start-silent-breaker.test.sh: pass (open, reviews ignored, build change, probe window, closed by bytes)"
