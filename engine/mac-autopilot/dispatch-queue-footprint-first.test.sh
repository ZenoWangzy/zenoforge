#!/usr/bin/env bash
# Engine home of the pack dispatch-queue-footprint test. The name differs on purpose: a same-path pack file shadows the engine one in the build and needs an overrides.tsv row.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
queue_source="${1:-$here/scheduler.d/dispatch-queue.sh}"
[[ -r "$queue_source" ]] || { echo "dispatch-queue-footprint-first: missing queue source: $queue_source" >&2; exit 2; }
command -v jq >/dev/null || { echo 'dispatch-queue-footprint-first: jq is required' >&2; exit 2; }

events="$(mktemp)"
UNITS="$(mktemp)"
trap 'rm -rf -- "$events" "$UNITS" "$test_env_root"' EXIT
export DISPATCH_QUEUE_FOOTPRINT_EVENTS="$events"

unit='{"id":"issue-2095","issue":2095,"pr":5012,"stage":"repair-pending","branch":"","history":[],"title":"reproduce footprint-blocked repair dispatch","lane":"pull-request","advisor_round":0}'
LOOP_TOTAL_ROUNDS=4
LOOP_BREAKER_ROUNDS=9
ADVISOR_ROUNDS=1
CFG='{"advisor":false}'
jq -nc --argjson u "$unit" '{units:[$u]}' > "$UNITS"

source "$queue_source"
declare -F tick_step_lock_run >/dev/null 2>&1 \
  && { echo 'dispatch-queue-footprint-first: dispatch-queue.sh unexpectedly loaded tick-steps.sh' >&2; exit 1; }

jqf() { jq "$@"; }
dispatch_order() { printf '%s\n' "$unit"; }
ticket_budget_reason() { :; }
loop_rounds() { printf '0\n'; }
tick_prs_prime() { :; }
tick_prs_changed() { :; }
room_for() { :; }
pick() { :; }
subject_of() { printf 'PR #%s / issue #%s\n' "$1" "$2"; }
js() { printf '"%s"' "$1"; }
set_unit() { :; }
say() { :; }
footprint_waiters_revalidate() { :; }
footprint_convoy_alert() { :; }
dispatch_capacity_free() { return 1; }
repair_cap_admission() { :; }
# Gates that skip the unit when unknown (rc 127 takes their `|| continue` branch) must pass here; zenoforge #700 added the token gate.
token_spend_gate() { :; }
dispatch_skip() { :; }
footprint_room() {
  printf 'footprint-check\n' >> "$DISPATCH_QUEUE_FOOTPRINT_EVENTS"
  return 1
}
tick_pr_branch() {
  printf 'pr-branch-lookup\n' >> "$DISPATCH_QUEUE_FOOTPRINT_EVENTS"
  printf 'topic/issue-2095\n'
}

# A new callee is not this test's subject: it asserts the footprint order below, and bash still names an unknown one on stderr.
dispatch_pending true >/dev/null || :
observed="$(tr '\n' ' ' < "$events" | sed 's/ $//')"
if grep -qx 'pr-branch-lookup' "$events"; then
  printf 'FAIL: footprint-blocked repair requested its PR branch before rejection\n' >&2
  printf 'observed=%s\n' "$observed" >&2
  exit 1
fi
if [[ "$observed" != footprint-check ]]; then
  printf 'FAIL: expected only footprint-check, observed=%s\n' "${observed:-<none>}" >&2
  exit 1
fi

printf 'PASS: footprint rejection prevented PR branch lookup; observed=%s\n' "$observed"
