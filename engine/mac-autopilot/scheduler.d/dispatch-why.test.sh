#!/usr/bin/env bash
# Dispatch why-log: a unit's skip gate is logged once per change of gate, a start clears its entry, and the refill's tick-phases line names the steps phase() did not time.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
set +e # test-env.sh turns errexit on; the scheduler runs without it, and refill_tick reads a ref that a fixture lacks
trap 'rm -rf -- "$test_env_root"' EXIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-why"
rm -rf -- "$fixture"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false | .auto_merge=true' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
UNIT='{"id":"issue-100","issue":100,"stage":"implement-pending","title":"t","lane":"pull-request","history":[]}'
printf '{"units":[%s]}\n' "$UNIT" > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
SAY_LOG="$fixture/say.log"
: > "$SAY_LOG"
say() { printf '%s\n' "$*" >> "$SAY_LOG"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The pass's externals: the gates under test are real, the rest stand still.
TICK_ACTIVE_FOOTPRINTS_VALID=false
declare -gA TICK_FOOTPRINT_CACHE=()
TOKEN_RESULT=fail BUDGET_RESULT=""
token_spend_gate() { [[ "$TOKEN_RESULT" == pass ]]; }
ticket_budget_reason() { printf '%s' "$BUDGET_RESULT"; }
unit_blocked_run_dep() { :; }
dispatch_order() { printf '%s\n' "$UNIT"; }
footprint_waiters_revalidate() { :; }
dispatch_live_prime() { :; }
tick_prs_changed() { :; }
paused_midrun() { return 1; }
dispatch_walk_full() { return 1; }
footprint_convoy_alert() { :; }
pass_refill() { dispatch_pending true >/dev/null; }
why_count() { grep -c 'dispatch why unit=issue-100 ' "$SAY_LOG" || true; }

# A ledger entry for a unit that left units.json must not survive the pass.
printf 'ghost-7\ttoken-gate-refill\n' > "$A/.dispatch-why"

# (a) Two refills with the same gate log one why line.
TOKEN_RESULT=fail
pass_refill
pass_refill
[[ "$(why_count)" == 1 ]] || fail "two refills with the same gate must log one why line, got $(why_count)"
grep -q 'dispatch why unit=issue-100 gate=token-gate-refill$' "$SAY_LOG" || fail 'the why line must name the gate'
grep -q 'ghost-7' "$A/.dispatch-why" && fail 'an entry for a unit that left units.json must be pruned'
grep -qP '^issue-100\ttoken-gate-refill$' "$A/.dispatch-why" || fail 'the last gate per unit must persist in .dispatch-why'

# (b) A changed gate logs a second line.
TOKEN_RESULT=pass BUDGET_RESULT=stop-loss-budget
pass_refill
[[ "$(why_count)" == 2 ]] || fail "a changed gate must log a second line, got $(why_count)"
grep -q 'dispatch why unit=issue-100 gate=stop-loss-refill$' "$SAY_LOG" || fail 'the changed gate must be named'

# (c) A start clears the unit's entry, so its next skip is logged again.
dispatch_if_room_stubs() {
  room_for() { return 0; }
  size_admission_write_start() { return 0; }
  footprint_recurrence_brief() { :; }
  incident_worker_prompt() { printf '%s' "$3"; }
  dispatch() { return 0; }
  set_unit() { :; }
  unit_field() { :; }
  hist() { :; }
  provider_of() { printf codex; }
}
dispatch_if_room_stubs
dispatch_if_room issue-100 implement implement "$fixture/w.log" "$fixture/w.md" model effort prompt "" "" "" prompt "$UNIT" false codex false configured codex >/dev/null
dispatch_why_save
grep -q 'issue-100' "$A/.dispatch-why" && fail 'a started unit must clear its entry'
TOKEN_RESULT=pass BUDGET_RESULT=stop-loss-budget
pass_refill
[[ "$(why_count)" == 3 ]] || fail "after a start the same gate must log again, got $(why_count)"

# (e) A pass saves only its own changes: a refill that overlapped a full tick must not put its stale copy of the tick's units back.
printf '{"units":[%s,{"id":"issue-101","issue":101,"stage":"implement-pending","history":[]}]}\n' "$UNIT" > "$UNITS" # live-only
printf 'issue-100\tself-fix-refill\n' > "$A/.dispatch-why"
dispatch_why_load
printf 'issue-100\thost-capacity\n' > "$A/.dispatch-why" # the full tick saved while this refill ran
dispatch_why issue-101 handoff-pending
dispatch_why_save
grep -qP '^issue-100\thost-capacity$' "$A/.dispatch-why" || fail "a stale refill overwrote the tick's gate: $(tr '\t\n' '= ' < "$A/.dispatch-why")"
grep -qP '^issue-101\thandoff-pending$' "$A/.dispatch-why" || fail 'the refill lost its own gate'
printf '{"units":[%s]}\n' "$UNIT" > "$UNITS" # live-only

# (f) A refill takes a self-fix only after repeated lock-held dispatch_pending skips.
UNIT='{"id":"issue-1133","issue":1133,"pr":503,"stage":"review-pending","self_fix_pending":true,"branch":"agent/issue-1133","lane":"pr","title":"fixture self-fix","history":[]}'
printf '{"units":[%s]}\n' "$UNIT" > "$UNITS"
unset AUTOPI_SELFFIX_REFILL_AFTER_SKIPS
SKIP_COUNTER="$A/.tick-step-dispatch_pending-skips"
self_fix_calls=0
self_fix_dispatch() { self_fix_calls=$((self_fix_calls + 1)); }
TOKEN_RESULT=pass BUDGET_RESULT=""
printf '2\n' > "$SKIP_COUNTER"
pass_refill
(( self_fix_calls > 0 )) || fail 'a refill with two lock-held dispatch_pending skips did not start the self-fix'
! grep -q 'dispatch why unit=issue-1133 gate=self-fix-refill$' "$SAY_LOG" \
  || fail 'a refill at the skip threshold still logged self-fix-refill'

self_fix_calls=0
: > "$SAY_LOG"
printf '1\n' > "$SKIP_COUNTER"
pass_refill
[[ "$self_fix_calls" == 0 ]] || fail "a refill below the skip threshold started the self-fix ($self_fix_calls starts)"
grep -q 'dispatch why unit=issue-1133 gate=self-fix-refill$' "$SAY_LOG" \
  || fail 'a refill below the skip threshold did not log self-fix-refill'

# A dispatch_pending lock-held skip increments the persisted counter atomically.
printf '0\n' > "$SKIP_COUNTER"
exec {held_lock_fd}>>"$A/.tick-step-dispatch_pending.lock"
flock -x "$held_lock_fd" || fail 'could not hold the dispatch_pending lock for the skip-count check'
TICK_STEP_LOCK_RESULT=""
tick_step_lock_run dispatch_pending :
[[ "$TICK_STEP_LOCK_RESULT" == skipped ]] || fail "a held dispatch_pending lock was not reported as skipped ($TICK_STEP_LOCK_RESULT)"
[[ "$(cat "$SKIP_COUNTER")" == 1 ]] || fail "a lock-held dispatch_pending skip did not increment the counter: $(cat "$SKIP_COUNTER")"
flock -u "$held_lock_fd" || fail 'could not release the dispatch_pending test lock'
exec {held_lock_fd}>&-

# (d) The refill's tick-phases line names the steps that phase() does not wrap.
dispatch_pending() { :; }
acquire_scheduler_lock() { return 0; }
release_scheduler_lock() { :; }
tick_gh_calls_begin() { :; }
tick_roadmap_cache_begin() { :; }
tick_roadmap_cache_end() { :; }
harvest_workers() { :; }
coord_reap_expired() { :; }
coord_reconcile_systemd_workers() { :; }
coord_reconcile_scheduler_workers() { :; }
self_check_harvest() { :; }
precheck_harvest() { :; }
recover_orphans() { :; }
mark_supervisor_owned_units() { :; }
release_session_pr_units() { :; }
register_new_issues() { :; }
dep_delivered_snapshot() { :; }
record_run_spend() { :; }
tick_prs_changed() { :; }
live_workers() { echo 0; }
refill_dispatch_metrics() { echo 'free_slots=1'; }
paused_midrun() { return 0; }
refill_tick
phase_line="$(grep 'tick-phases kind=refill' "$SAY_LOG" | tail -1)"
[[ -n "$phase_line" ]] || fail 'the refill printed no tick-phases line'
for step in state_schema coord_reap coord_systemd coord_scheduler dep_snapshot record_run_spend dispatch_pending; do
  grep -Eq "(phases=|,)${step}:[0-9]+s/[0-9]+gh" <<<"$phase_line" || fail "the tick-phases line lacks $step: $phase_line"
done

# A real detached dispatch_pending tick-step clears the count when it runs its phase.
printf '2\n' > "$SKIP_COUNTER"
state_schema_ok() { return 0; }
existing_walk_fresh() { return 1; }
record_run_spend() { :; }
phase_calls=0
phase() { [[ "$1" == dispatch_pending ]] || return 64; phase_calls=$((phase_calls + 1)); }
tick_step_run dispatch_pending
[[ "$phase_calls" == 1 ]] || fail "the dispatch_pending tick-step did not run its phase ($phase_calls calls)"
[[ "$(cat "$SKIP_COUNTER")" == 0 ]] || fail "the dispatch_pending tick-step did not reset the skip counter: $(cat "$SKIP_COUNTER")"

printf 'PASS: dispatch why-log, gate change, start clear, prune and refill phase names all hold\n'
