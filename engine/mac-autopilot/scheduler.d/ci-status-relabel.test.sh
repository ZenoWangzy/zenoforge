#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/ci-status-relabel"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=2026-11-20T00:00:00Z
fail() { printf 'ci-status-relabel.test.sh: %s\n' "$*" >&2; exit 1; }

declare -A ISSUE_STATES=([801]=ready-for-agent [802]=on-hold [803]=needs-triage)
calls="$fixture/conclude-calls"; : > "$calls"
tick_prs() { printf '[]'; }
pr_view() { printf 'MERGED'; }
scheduler_issue_state() { printf '{"state":"%s"}\n' "${ISSUE_STATES[$1]}"; }
scheduler_conclude_merged_pr() {
  printf '%s %s\n' "$1" "$2" >> "$calls"
  [[ "${ISSUE_STATES[$1]}" == ready-for-agent ]] || return 1
  ISSUE_STATES[$1]=awaiting-release
}
jq -cn '{units:[
  {id:"issue-801",issue:801,pr:1801,stage:"parked",history:[]},
  {id:"issue-802",issue:802,pr:1802,stage:"parked",history:[]},
  {id:"issue-803",issue:803,pr:1803,stage:"parked",history:[]}
]}' > "$UNITS"

retire_landed_pr_units
[[ "${ISSUE_STATES[801]}" == awaiting-release ]] || fail 'a merged outside-pipeline PR must move a ready-for-agent issue to awaiting-release'
[[ "${ISSUE_STATES[802]}" == on-hold ]] || fail 'an on-hold issue must keep its session-owned state'
[[ "${ISSUE_STATES[803]}" == needs-triage ]] || fail 'a needs-triage issue must keep its session-owned state'
[[ "$(cat "$calls")" == '801 1801' ]] || fail 'only the ready-for-agent issue may use the merged-PR transition'
jq -e 'all(.units[]; .stage == "merged" and .awaiting_release_pending == null and .awaiting_release_ready_only == null)' "$UNITS" >/dev/null \
  || fail 'outside-pipeline merged units must retire and clear their bounded transition marks'

echo 'ci-status-relabel.test.sh: ok'

# Row 898: retire's GitHub reads (pr_view, and behind it mergeCommit) run with the ledger lock released;
# the retire write sees the lock held; a unit changed inside the window is not written and logs one skip line.
release_scheduler_lock
acquire_scheduler_lock || fail 'probe could not take the scheduler lock'
# pr_view runs inside a $( ) capture in retire_unit_collect, so the counters must live in a file:
# a shell variable bumped inside the command substitution dies with the subshell (round 2).
probe_counts="$fixture/retire-probe-counts"
probe_write_free=0
eval "pr_view_orig() $(declare -f pr_view | sed '1d')"
eval "set_unit_orig() $(declare -f set_unit | sed '1d')"
pr_view() {
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then echo held >>"$probe_counts"; else echo free >>"$probe_counts"; fi
  printf 'MERGED'
}
set_unit() {
  [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$$" ]] || probe_write_free=$((probe_write_free + 1))
  set_unit_orig "$@"
}
jq -cn '{units:[{id:"issue-804",pr:1804,stage:"review-pending",history:[]}]}' > "$UNITS"
: >"$probe_counts"
retire_landed_pr_units
probe_free="$(grep -c '^free$' "$probe_counts" || true)"; probe_held="$(grep -c '^held$' "$probe_counts" || true)"
[[ "$probe_free" -ge 1 && "$probe_held" == 0 ]] || fail "retire's pr_view ran under the ledger lock (free=$probe_free held=$probe_held)"
[[ "$probe_write_free" == 0 ]] || fail "$probe_write_free retire writes ran with the lock released"
jq -e '.units[0].stage == "merged"' "$UNITS" >/dev/null || fail 'the merged outside-pipeline PR did not retire: '"$(jq -c '.units[0]' "$UNITS")"
grep -q 'unit=issue-804 PR#1804 already merged on GitHub; retired before dispatch' "$LOG" || fail 'the retire line is missing'
# the unit changes while the lock is released: the stale decision is not written
: > "$LOG"
jq -cn '{units:[{id:"issue-804",pr:1804,stage:"review-pending",history:[]}]}' > "$UNITS"
pr_view() {
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then echo held >>"$probe_counts"; else echo free >>"$probe_counts"; fi
  # a concurrent writer landed the unit while the ledger lock was released
  jq '(.units[] | select(.id=="issue-804") | .stage) = "landed"' "$UNITS" > "$UNITS.p" && mv "$UNITS.p" "$UNITS"
  printf 'MERGED'
}
retire_landed_pr_units
jq -e '.units[0].stage == "landed" and (.units[0].history | length) == 0' "$UNITS" >/dev/null \
  || fail 'a stale retire decision was written: '"$(jq -c '.units[0]' "$UNITS")"
grep -q 'retire skip unit=issue-804' "$LOG" || fail 'the stale retire skip did not log its one line'
release_scheduler_lock
echo 'ci-status-relabel.test.sh: retire lock discipline ok'
