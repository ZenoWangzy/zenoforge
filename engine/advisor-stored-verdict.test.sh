#!/usr/bin/env bash
# advisor-stored-verdict.test.sh -- a stored (pending, not yet applied)
# advisor verdict on a ticket still labelled needs-advisor has exactly ONE
# owning dispatch path, and it resumes that ticket within the SAME tick with
# ADVISOR_RESUME_ONLY=1 (no new model call). A verdict past its resume age
# bound (default 12h), or whose Apply already failed once, is never resumed:
# it is discarded with exactly one log line naming issue, age, and reason,
# and the ticket stays queued for the batch to re-ask. A verdict unresolved
# past the stuck threshold (default 6h) emits one DEDUPLICATED signal line.
#
# 2026-11-04 recurrence guard (#5298/#5302): both tickets sat ~20h with
# verdicts no dispatch path would apply -- the batch filter only exempted
# roadmap containers, both resume pools dedup-skipped every candidate still
# in the batch queue, and the batch itself was starved by in-flight
# single-ticket jobs and provider failures. This file runs the production
# filter + pool bodies (sed-extracted, same discipline as lib.test.sh's
# STORED_VERDICT_LOOP_BODY block) against fixture state files only.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
ADVISOR_CORE_SRC="$SCRIPT_DIR/advisor-core.sh"

FAILED=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok - $name"
  else
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
    FAILED=1
  fi
}
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $name"
  else
    printf 'not ok - %s\nmissing: %s\n' "$name" "$needle" >&2
    FAILED=1
  fi
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $name"
  else
    printf 'not ok - %s\nunexpectedly found: %s\n' "$name" "$needle" >&2
    FAILED=1
  fi
}
assert_nonempty() {
  local name="$1" value="$2"
  if [ -n "$value" ]; then echo "ok - $name"; else echo "not ok - $name" >&2; FAILED=1; fi
}

# Roadmap ordering off: roadmap_issue_is_container() then answers a real,
# deterministic "not a container" (rc=1) for every fixture -- exactly the
# #5298/#5302 shape (both absent from the roadmap tree).
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' \
  "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# Production bodies under test. The filter body is the second (filtering)
# NEEDS_ADVISOR_IDS assignment: top-level code, so it is eval'd inline the
# same way the advisor slice runs it, against a stubbed outer tick.
STORED_VERDICT_FNS="$(sed -n \
  -e '/^advisor_pending_verdict_age_seconds() {/,/^}/p' \
  -e '/^advisor_stored_verdict_disposition() {/,/^}/p' \
  -e '/^advisor_discard_stored_verdict() {/,/^}/p' \
  -e '/^advisor_stored_verdict_stuck_sweep() {/,/^}/p' \
  -e '/^advisor_dispatch_stored_verdict_pool() {/,/^}/p' \
  "$PIPELINE_SRC")"
FILTER_BODY="$(sed -n '/^NEEDS_ADVISOR_IDS="\$(while IFS= read -r advisor_id; do$/,/^done <<< "\$NEEDS_ADVISOR_IDS")"$/p' "$PIPELINE_SRC")"
APPLY_FAILURE_FN="$(sed -n '/^advisor_record_apply_failure() {/,/^}/p' "$ADVISOR_CORE_SRC")"
assert_true_fixture() {
  local name="$1" body="$2"
  if [ -n "$body" ]; then echo "ok - $name"; else echo "not ok - $name (extraction empty)" >&2; FAILED=1; fi
}
assert_true_fixture "stored-verdict helpers extracted from issue-pipeline.sh" "$STORED_VERDICT_FNS"
assert_true_fixture "the needs-advisor filter body extracted from issue-pipeline.sh" "$FILTER_BODY"
assert_true_fixture "advisor_record_apply_failure extracted from advisor-core.sh" "$APPLY_FAILURE_FN"
eval "$STORED_VERDICT_FNS"
eval "$APPLY_FAILURE_FN"

# Stub every live surface (systemd units, gh, watchdog state) the tick owns.
# state_read/state_merge/agent_epoch/advisor_pending_orphan_candidates/
# roadmap_issue_is_container/issue_is_tracker_parent stay REAL: they read the
# fixture state directory this file builds.
record_advisor_decision() { ADVISOR_DECISION_LOG+="$2:$4"$'\n'; }
record_hand_owned_decision() { ADVISOR_DECISION_LOG+="hand-owned:$2"$'\n'; }
hand_agent_issue_is_live_owned() { return 1; }
prioritize_advisor_blockers() { cat; }
stage_unit_active() { return 1; }
stage_dispatch_allowed() { return 0; }
agent_memory_floor_allows() { return 0; }
ensure_issue_roadmap_parent_for_dispatch() { return 0; }
is_on_hold() { return 1; }
dispatch() { DISPATCH_LOG+="$1 $2 ${*:3}"$'\n'; return 0; }
DISPATCH_LOG=""
ADVISOR_DECISION_LOG=""

# Defaults under test (issue-pipeline.sh's own knobs; asserted equal there by
# issue-pipeline.test.sh's config block, re-declared here because only the
# advisor slice's function bodies are eval'd, not the tick's assignments).
ADVISOR_VERDICT_RESUME_MAX_AGE_SECONDS=$((12 * 60 * 60))
ADVISOR_VERDICT_STUCK_SIGNAL_SECONDS=$((6 * 60 * 60))

NOW_S="$(date +%s)"
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# write_verdict_fixture <n> <age-seconds> [apply_failed_at ISO|""]
write_verdict_fixture() {
  local n="$1" age="$2" failed="${3:-}"
  mkdir -p "$STATE_DIR"
  jq -cn --arg state needs-advisor --arg computed "$(iso_utc $((NOW_S - age)))" \
    --arg failed "$failed" --argjson n "$n" \
    '{attempts:0, state:$state, number:$n,
      pending_advisor_verdict: ({result:{verdict:"advised"}, input:{title:"t", body:"b", comments:[]},
        computed_at:$computed, episode_seq:0, model_used:"web:test", effects:{}}
        + (if $failed == "" then {} else {apply_failed_at:$failed} end))}' \
    > "$STATE_DIR/$n.json"
}

# --- case 1: fresh never-failed verdict on a queued needs-advisor ticket ----
# is dispatched for resume within the same tick (the recurrence guard), and a
# label-moved pool-only ticket resumes through the same single owner.
write_verdict_fixture 6001 $((30 * 60))
write_verdict_fixture 6005 $((45 * 60))   # not queued below: label moved off
write_verdict_fixture 6002 $((13 * 60 * 60))           # past the 12h bound
write_verdict_fixture 6003 $((20 * 60)) "2026-11-03T19:27:00Z"  # apply failed

FILTER_ERR_FILE="$AGENT_HOME/filter.err"
NEEDS_ADVISOR_IDS=$'6001\n6002\n6003'
eval "$FILTER_BODY" 2>"$FILTER_ERR_FILE" || true
FILTER_ERR="$(cat "$FILTER_ERR_FILE")"

assert_not_contains "recurrence guard: the fresh stored verdict LEAVES the batch queue (the pool owns it)" \
  "$NEEDS_ADVISOR_IDS" "6001"
assert_contains "recurrence guard: the past-bound verdict STAYS queued for the batch re-ask" \
  "$NEEDS_ADVISOR_IDS" "6002"
assert_contains "recurrence guard: the failed-apply verdict STAYS queued for the batch re-ask" \
  "$NEEDS_ADVISOR_IDS" "6003"
assert_eq "recurrence guard: the batch queue is exactly the two re-ask tickets" \
  $'6002\n6003' "$NEEDS_ADVISOR_IDS"

advisor_slots=4
advisor_dispatch_stored_verdict_pool 2>>"$FILTER_ERR_FILE" || true
assert_contains "recurrence guard: the queued fresh verdict is dispatched for resume within the same tick" \
  "$DISPATCH_LOG" "advisor 6001 -E ADVISOR_RESUME_ONLY=1"
assert_contains "recurrence guard: a label-moved fresh verdict resumes through the same one owner" \
  "$DISPATCH_LOG" "advisor 6005 -E ADVISOR_RESUME_ONLY=1"
assert_eq "recurrence guard: exactly the two fresh verdicts were dispatched (no re-ask dispatch)" \
  $'advisor 6001 -E ADVISOR_RESUME_ONLY=1\nadvisor 6005 -E ADVISOR_RESUME_ONLY=1\n' "$DISPATCH_LOG"
assert_not_contains "recurrence guard: resume-only dispatch never opens a fresh model dialogue" \
  "$DISPATCH_LOG" "6002"
assert_eq "the resumed verdict itself stays stored until Apply completes" \
  "true" "$(jq '.pending_advisor_verdict != null' "$STATE_DIR/6001.json")"

# --- case 2: discard by age -- one line, verdict dropped, ticket re-asked ---
assert_contains "discard by age: exactly one line names issue, age, and reason" \
  "$FILTER_ERR" "advisor stored verdict discarded: issue=#6002 age=13h"
assert_contains "discard by age: the line states the reason" \
  "$FILTER_ERR" "reason=discard-age"
assert_eq "discard by age: the line appears exactly once for #6002" \
  "1" "$(grep -cF 'issue=#6002' <<< "$FILTER_ERR")"
assert_eq "discard by age: the stale verdict is gone from state" \
  "false" "$(jq 'has("pending_advisor_verdict")' "$STATE_DIR/6002.json")"

# --- case 3: discard after a failed apply -- same contract ------------------
assert_contains "discard after failed apply: one line names issue and reason" \
  "$FILTER_ERR" "advisor stored verdict discarded: issue=#6003"
assert_contains "discard after failed apply: the line states the reason" \
  "$FILTER_ERR" "reason=discard-apply-failed"
assert_eq "discard after failed apply: the failed verdict is gone from state" \
  "false" "$(jq 'has("pending_advisor_verdict")' "$STATE_DIR/6003.json")"

# A second tick over the same fixtures stays silent (nothing left to discard).
SECOND_TICK_ERR_FILE="$AGENT_HOME/second-tick.err"
NEEDS_ADVISOR_IDS=$'6002\n6003'
eval "$FILTER_BODY" 2>"$SECOND_TICK_ERR_FILE" || true
SECOND_TICK_ERR="$(cat "$SECOND_TICK_ERR_FILE")"
assert_not_contains "a second tick does not re-discard an already-discarded verdict" \
  "$SECOND_TICK_ERR" "advisor stored verdict discarded"

# --- case 4: the stuck signal fires once per verdict, deduplicated ----------
write_verdict_fixture 6004 $((7 * 60 * 60))   # between 6h signal and 12h bound
STUCK_ERR_FILE="$AGENT_HOME/stuck.err"
advisor_stored_verdict_stuck_sweep 2>"$STUCK_ERR_FILE" || true
advisor_stored_verdict_stuck_sweep 2>>"$STUCK_ERR_FILE" || true
advisor_stored_verdict_stuck_sweep 2>>"$STUCK_ERR_FILE" || true
STUCK_ERR="$(cat "$STUCK_ERR_FILE")"
assert_contains "stuck signal: one line names the issue and its age past the 6h threshold" \
  "$STUCK_ERR" "advisor stored verdict stuck: issue=#6004 age=7h"
assert_eq "stuck signal: three sweeps still emit exactly ONE line for #6004" \
  "1" "$(grep -cF 'issue=#6004' <<< "$STUCK_ERR")"
assert_not_contains "stuck signal: a fresh (30m) verdict is not signalled" \
  "$STUCK_ERR" "#6001"
assert_eq "stuck signal: the dedup marker is persisted on the verdict" \
  "true" "$(jq '.pending_advisor_verdict.stuck_signal_at != null' "$STATE_DIR/6004.json")"

# --- case 5: apply failures are recorded at the apply site, once ------------
write_verdict_fixture 6100 $((10 * 60))
advisor_record_apply_failure 6100 "test first failure" 2>/dev/null
FIRST_FAILURE_AT="$(jq -r '.pending_advisor_verdict.apply_failed_at // empty' "$STATE_DIR/6100.json")"
assert_nonempty "advisor_record_apply_failure stamps apply_failed_at on a pending verdict" "$FIRST_FAILURE_AT"
advisor_record_apply_failure 6100 "test second failure" 2>/dev/null
assert_eq "advisor_record_apply_failure keeps the FIRST failure timestamp (idempotent)" \
  "$FIRST_FAILURE_AT" "$(jq -r '.pending_advisor_verdict.apply_failed_at // empty' "$STATE_DIR/6100.json")"
assert_eq "a stamped verdict is no longer resumable" \
  "discard-apply-failed" "$(advisor_stored_verdict_disposition 6100 "$(state_read 6100)")"
echo '{"attempts":0,"state":"needs-advisor"}' > "$STATE_DIR/6101.json"
advisor_record_apply_failure 6101 "no verdict here" 2>/dev/null || true
assert_eq "a ticket without a stored verdict is left unchanged" \
  "false" "$(jq 'has("pending_advisor_verdict") or has("apply_failed_at")' "$STATE_DIR/6101.json")"
write_verdict_fixture 6102 $((60 * 60))
assert_eq "a fresh never-failed verdict is the only resumable disposition" \
  "resume" "$(advisor_stored_verdict_disposition 6102 "$(state_read 6102)")"

# run_intake_dispatch defines functions as it runs, so a call above a nested definition is 'command not found'.
INTAKE_BODY="$(sed -n '/^run_intake_dispatch() {/,/^if \[\[ "\$PIPELINE_STAGE" == triage/p' "$PIPELINE_SRC")"
while IFS= read -r nested_fn; do
  assert_eq "$nested_fn is not called above its nested definition" "" \
    "$(awk -v fn="$nested_fn" '$0 ~ "^" fn "\\(\\) \\{" { exit } !/^[[:space:]]*#/ && $0 ~ "(^|[^a-z_])" fn "([^a-z_]|$)" { print NR }' <<< "$INTAKE_BODY")"
done < <(sed -n 's/^\([a-z_][a-z0-9_]*\)() {.*/\1/p' <<< "$INTAKE_BODY" | grep -v '^run_intake_dispatch$')

if [ "$FAILED" -ne 0 ]; then
  echo 'advisor-stored-verdict: FAILED' >&2
  exit 1
fi
echo 'advisor-stored-verdict: all cases passed'
