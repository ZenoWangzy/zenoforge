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
  .zero_candidate_reason == "advisor queue empty" and .job_artifact == null' \
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
