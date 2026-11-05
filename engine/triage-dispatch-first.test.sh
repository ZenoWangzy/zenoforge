#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
CALLS="$TMP/calls"; : > "$CALLS"
FAILED=0
assert_eq() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (expected [$2], got [$3])"; FAILED=1; fi; }

# The real run_intake_dispatch, with every collaborator stubbed.
# run_intake_dispatch holds nested function definitions, so it ends at the line before its caller.
eval "$(sed -n '/^triage_slice_seconds_left() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
eval "$(sed -n '/^run_intake_dispatch() {/,/^if \[\[ "\$PIPELINE_STAGE" == triage/p' "$SCRIPT_DIR/issue-pipeline.sh" | sed '$d')"
gh_call_now_ms() { echo $(( ${EPOCHREALTIME/./} / 1000 )); }
profile_mark() { :; }; profile_finish() { :; }
REPO=test/repo; PIPELINE_STAGE=triage; ROADMAP_ORDER_ENABLED=false; PIPELINE_SYSTEM_LABELS_JSON='[]'; TRIAGE_CAP=5
cap_slots_remaining() { echo 5; }; stage_unit_count() { echo 0; }; stage_unit_active() { return 1; }
hand_agent_issue_is_live_owned() { return 1; }; is_on_hold() { return 1; }
issue_model_failure_backoff_remaining() { echo 0; }; triage_retry_deferred() { return 1; }
pipeline_triage_skip_inflight() { return 1; }; stage_dispatch_allowed() { return 0; }
ensure_issue_roadmap_parent_for_dispatch() { echo "ensure $1" >> "$CALLS"; }
state_read() { echo '{}'; }; triage_unmeasured_issue_ids() { :; }; triage_classification_status() { echo measured; }
dispatch_gitnexus_refresh() { :; }
dispatch_triage_batch() { echo "dispatch $*" >> "$CALLS"; }
gh() { # needs-triage snapshot: #11 plain, #12 founder-test (ranks first from its label)
  if [[ "$*" == *needs-triage* ]]; then
    echo '[{"number":11,"createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"needs-triage"}]},{"number":12,"createdAt":"2026-01-02T00:00:00Z","labels":[{"name":"needs-triage"},{"name":"founder-test"}]}]'
  else echo '[]'; fi
}
# A slow, failing admit loop and label step: they must run after dispatch and cannot block it.
intake_admit_unlabeled_issues() { echo admit >> "$CALLS"; sleep 1; return 1; }
label_maintainer_test_candidates() { echo label >> "$CALLS"; sleep 1; return 1; }

run_intake_dispatch 2> "$TMP/err" || true
assert_eq "dispatch runs before admit and founder-test labelling" "dispatch 12 11|admit|label" \
  "$(grep -v '^ensure' "$CALLS" | paste -sd'|')"
assert_eq "founder-test ranking works from labels already on the issue" "dispatch 12 11" "$(grep '^dispatch' "$CALLS")"
grep -q 'dispatched one triage batch for 2 issue' "$TMP/err" && ok=1 || ok=0
assert_eq "dispatch line is logged despite failing admit and label steps" 1 "$ok"

# An expired slice deadline gives a distinct line instead of a silent kill.
: > "$CALLS"
ZF_GH_CALL_DEADLINE_EPOCH_MS=$(( $(gh_call_now_ms) + 5000 ))
run_intake_dispatch 2> "$TMP/err" || true
unset ZF_GH_CALL_DEADLINE_EPOCH_MS
assert_eq "no dispatch when the deadline leaves no time" 0 "$(grep -c '^dispatch' "$CALLS" || true)"
grep -q 'triage batch could not be built within the slice' "$TMP/err" && ok=1 || ok=0
assert_eq "slice-deadline failure logs its own line" 1 "$ok"
assert_eq "no admit or labelling once the slice deadline is gone" 0 "$(grep -cE '^(admit|label)' "$CALLS" || true)"

# Candidates beyond the cap pay no roadmap placement call.
: > "$CALLS"; cap_slots_remaining() { echo 1; }
run_intake_dispatch 2> "$TMP/err" || true
assert_eq "only the selected candidate is placed on the roadmap" 1 "$(grep -c '^ensure' "$CALLS" || true)"

[ "$FAILED" -eq 0 ] && echo "ALL PASSED" || { echo FAILURES; exit 1; }
