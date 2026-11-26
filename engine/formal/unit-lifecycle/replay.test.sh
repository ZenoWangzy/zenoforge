#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
set +e
AGENT_DIR="${FORMAL_AGENT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
SCHEDULER="$AGENT_DIR/mac-autopilot/scheduler.sh"
SD="$AGENT_DIR/mac-autopilot/scheduler.d"
T="$(mktemp -d)"
HOLDER_PID=""
A="$T"
LOG="$T/log"
UNITS="$T/units.json"
WORKERS="$T/workers.json"
cleanup() {
  if [[ -n "$HOLDER_PID" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || :
    wait "$HOLDER_PID" 2>/dev/null || :
  fi
  rm -rf "$T"
}
fail() { echo "replay failed: $*" >&2; exit 1; }
say() { printf '%s\n' "$*" >> "$LOG"; }
run_merge_lane_pass() { printf 'ran\n' >> "$T/passes"; }
phase_yield_lock() { "$@"; }
jqf() { jq "$@"; }
fn() { sed -n "/^$2() {/,/^}/p" "$SD/$1"; }
source <(fn core.sh chain_exit_trap)
source <(fn merge-lane.sh run_merge_lane)
source <(fn locks-views.sh state_schema_ok)
chain_exit_trap cleanup
tick_sites="$(grep -c 'phase_yield_lock run_merge_lane' "$SCHEDULER")"
[[ "$tick_sites" == 1 ]] || fail 'tick merge-lane call site changed'
tick_line="$(grep 'phase_yield_lock run_merge_lane' "$SCHEDULER")"
tick_call="${tick_line#*||}"
tick_call="${tick_call%%#*}"
tick_call="$(sed 's/[[:space:]]*$//' <<< "$tick_call")"
tick_call="${tick_call#"${tick_call%%[![:space:]]*}"}"
[[ "$tick_call" == 'phase_yield_lock run_merge_lane' ]] || fail 'could not read tick merge-lane call'
mapfile -t lane_calls < <(grep -Eo '((MERGE_SCAN_NOWAIT=true[[:space:]]+)?MERGE_LANE_WAIT=0[[:space:]]+run_merge_lane)' "$SD/merge-lane.sh")
[[ "${#lane_calls[@]}" == 2 ]] || fail 'refill or station merge-lane call site changed'
refill_call="${lane_calls[0]}"
station_call="${lane_calls[1]}"
mapfile -d '' -t sd_sources < <(find "$SD" -maxdepth 1 -type f -name '*.sh' ! -name '*.test.sh' -print0)
pass_calls="$(grep -nH 'run_merge_lane_pass' "${sd_sources[@]}" | awk -F: '$3 !~ /^[[:space:]]*#/ && $3 !~ /^[[:space:]]*run_merge_lane_pass[[:space:]]*\(\)/ { count++ } END { print count+0 }')"
lane_callers="$(grep -nH -E 'run_merge_lane([^[:alnum:]_]|$)' "$SCHEDULER" "${sd_sources[@]}" | awk -F: '$3 !~ /^[[:space:]]*#/ && $3 !~ /^[[:space:]]*run_merge_lane[[:space:]]*\(\)/ { count++ } END { print count+0 }')"
[[ "$pass_calls" == 1 ]] || fail "expected one pass call site, found $pass_calls"
[[ "$lane_callers" == 3 ]] || fail "expected three lane callers, found $lane_callers"
pass_count() { [[ ! -f "$T/passes" ]] && echo 0 || wc -l < "$T/passes" | tr -d '[:space:]'; }
start_lock_holder() {
  rm -f "$T/lock-held" "$T/lock-released"
  (
    exec 8>"$A/.merge-lane.lock"
    flock -x 8
    : > "$T/lock-held"
    sleep 3
    exec 8>&-
    : > "$T/lock-released"
  ) &
  HOLDER_PID=$!
  for _ in {1..100}; do
    [[ -f "$T/lock-held" ]] && return 0
    sleep 0.02
  done
  fail 'merge-lane lock holder did not start'
}
finish_lock_holder() {
  wait "$HOLDER_PID" || fail 'merge-lane lock holder failed'
  HOLDER_PID=""
}
eval "$station_call" || fail 'lane-free station call failed'
[[ "$(pass_count)" == 1 ]] || fail 'lane-free caller did not run a pass'
start_lock_holder
before="$(pass_count)"
eval "$refill_call" || fail 'held refill call failed'
eval "$station_call" || fail 'held station call failed'
[[ "$(pass_count)" == "$before" ]] || fail 'refill or station ran while the lane was held'
finish_lock_holder
start_lock_holder
before="$(pass_count)"
MERGE_LANE_WAIT=6
eval "$tick_call" || fail 'tick call failed'
unset MERGE_LANE_WAIT
finish_lock_holder
[[ -f "$T/lock-released" && "$(pass_count)" == "$((before + 1))" ]] || fail 'tick did not run after the lane lock was released'
printf '{"units":[{"id":"u","stage":"implement-pending"},{"id":"u","stage":"review-pending"}]}\n' > "$UNITS"
printf '{"workers":[]}\n' > "$WORKERS"
if state_schema_ok; then fail 'duplicate ledger id was accepted'; fi
duplicate_result=REFUSED
printf '{"units":[{"id":"u"}]}\n' > "$UNITS"
if state_schema_ok; then fail 'ledger row with missing stage was accepted'; fi
missing_stage_result=REFUSED
printf 'RESULT lane-free: RAN\n'
printf 'RESULT lane-held-refill: SKIPPED\n'
printf 'RESULT lane-held-station: SKIPPED\n'
printf 'RESULT lane-held-tick: RAN-AFTER-RELEASE\n'
printf 'RESULT pass-call-sites: %s\n' "$pass_calls"
printf 'RESULT lane-callers: %s\n' "$lane_callers"
printf 'RESULT ledger-duplicate-id: %s\n' "$duplicate_result"
printf 'RESULT ledger-missing-stage: %s\n' "$missing_stage_result"
