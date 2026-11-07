#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
eval "$(sed -n '/^record_batch_result() {/,/^cleanup() {/p' "$script_dir/run-advisor-batch.sh" | sed '$d')"
LOG_DIR="$AGENT_HOME/logs"
mkdir -p "$LOG_DIR"
declare -A BATCH_SELECTION_GATES=()
CANDIDATE_ISSUES=()
ADVISOR_TICK_ID=advisor-batch-empty
BATCH_OUTCOME=no-candidates
BATCH_JOB_ID=
INCLUDED=0
record_batch_result 0
jq -e '.eligible_count == 0 and .outcome == "no-candidates" and
  .zero_candidate_reason == "advisor queue empty" and .job_artifact == null and
  .engine_version == null' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
printf 'ok - empty queue outcome is recorded\n'

BATCH_SELECTION_GATES=([930001]=applied)
CANDIDATE_ISSUES=(930001)
ADVISOR_TICK_ID=advisor-batch-completed
BATCH_OUTCOME=completed
BATCH_JOB_ID=fixture-job
ACTIVE_BATCH_JOB='{"job_id":"fixture-job","members":[{"issue":930001}]}'
RAW_OUTPUT='{"kind":"advisor_batch_result","requested_issues":[930001],"rulings":[]}'
INCLUDED=1
APPLIED=1
record_batch_result 0
jq -e '.eligible_count == 1 and .applied_count == 1 and .job_id == "fixture-job"' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
jq -e '.members[0].issue == 930001' \
  "$(jq -r '.job_artifact' "$LOG_DIR/$ADVISOR_TICK_ID.result.json")" >/dev/null
jq -e '.requested_issues == [930001]' \
  "$(jq -r '.ruling_artifact' "$LOG_DIR/$ADVISOR_TICK_ID.result.json")" >/dev/null
printf 'ok - completed batch artifacts survive provider cleanup\n'

# engine_version records the engine version directory this job runs from,
# resolved once at start (2026-11-04: which engine advisor-batch-1793828604924428167
# tested was only recoverable from the journal).
source "$script_dir/config.sh"
mkdir -p "$AGENT_HOME/engine-versions/ver-abc123/engine" "$AGENT_HOME/engine-versions/ver-def456/engine"
ln -sfn -- "$AGENT_HOME/engine-versions/ver-def456/engine" "$AGENT_HOME/engine-live"
ZF_ENGINE_DIR="$AGENT_HOME/engine-versions/ver-abc123/engine"
ADVISOR_BATCH_ENGINE_VERSION="$(zf_engine_version_id)"
ADVISOR_TICK_ID=advisor-batch-engine-version-pinned
BATCH_OUTCOME=dispatched
record_batch_result 0
jq -e '.engine_version == "ver-abc123"' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
printf 'ok - engine_version records the pinned engine version directory\n'

ZF_ENGINE_DIR="$AGENT_HOME/engine-live"
ADVISOR_BATCH_ENGINE_VERSION="$(zf_engine_version_id)"
ADVISOR_TICK_ID=advisor-batch-engine-version-live
record_batch_result 0
jq -e '.engine_version == "ver-def456"' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
printf 'ok - engine_version follows a logical engine-live path to its version\n'

# failure_detail makes a failed or timed-out job countable by window; it is truncated, single-line, and absent otherwise.
ADVISOR_TICK_ID=advisor-batch-job-failed
BATCH_OUTCOME=job-failed
ADVISOR_FAILURE_DETAIL="$(printf 'provider said no\n\tline two %0400d' 0)"
record_batch_result 1
jq -e '.outcome == "job-failed" and (.failure_detail | startswith("provider said no line two")) and
  (.failure_detail | length <= 300) and (.failure_detail | test("[\\n\\t]") | not)' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
ADVISOR_TICK_ID=advisor-batch-job-timeout
BATCH_OUTCOME=job-timeout
unset ADVISOR_FAILURE_DETAIL
record_batch_result 0
jq -e '.outcome == "job-timeout" and (has("failure_detail") | not)' \
  "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
ADVISOR_TICK_ID=advisor-batch-after-failure
BATCH_OUTCOME=completed
ADVISOR_FAILURE_DETAIL="stale"
record_batch_result 0
jq -e 'has("failure_detail") | not' "$LOG_DIR/$ADVISOR_TICK_ID.result.json" >/dev/null
printf 'ok - failure_detail is recorded only for job-failed and job-timeout\n'
