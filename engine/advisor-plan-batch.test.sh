#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

WEB_ADVISOR_PROVIDER_JOB_DIR="$tmp/jobs"
mkdir -p "$WEB_ADVISOR_PROVIDER_JOB_DIR/old-batch"
printf 'original frozen batch question\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/old-batch/question.txt"
BATCH_JOB_ID=old-batch
BATCH_TOPIC=fixture-topic
ACTIVE_BATCH_JOB='{"job_id":"old-batch","topic":"fixture-topic","started_at":10,"members":[{"issue":930001,"input":{"title":"fixture"}}]}'
ADVISOR_MODEL_USED=web:fixture-model
ADVISOR_MODEL_FALLBACK=
INCLUDED=1
BATCH_LOCK_FD=9
declare -A ADVISOR_TICKET_LOCK_FDS=()

record_premium_spend() { printf 'spend\n' >> "$tmp/calls"; }
run_with_fd_closed() {
  while (($#)); do
    if [ "$1" = -- ]; then shift; break; fi
    shift
  done
  "$@"
}
web_advisor_provider_dispatch_question_async() {
  local job_id="$1" question_file="$2" mode="$3"
  [[ "$mode" == single-request-ndjson ]]
  mkdir -p "$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id"
  cp "$question_file" "$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id/question.txt"
  printf '%s\n' "$job_id" >> "$tmp/dispatched"
}
advisor_batch_state_set_job() { printf '%s\n' "$1" > "$tmp/active-job.json"; }
advisor_batch_forget_provider_job() { printf '%s\n' "$1" >> "$tmp/forgotten"; }

eval "$(sed -n '/^advisor_batch_dispatch_plan_reask() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"

previous_ruling='[{"kind":"ruling","issue":930001,"verdict":"advised","decision_md":"keep the shared contract"}]'
advisor_batch_dispatch_plan_reask "$previous_ruling" '[930001]'

[[ "$(wc -l < "$tmp/dispatched" | tr -d '[:space:]')" == 1 ]]
new_job_id="$(cat "$tmp/dispatched")"
[[ "$BATCH_JOB_ID" == "$new_job_id" ]]
[[ "$(cat "$tmp/forgotten")" == old-batch ]]
jq -e '.plan_reask_attempted == true and .plan_reask_issues == [930001] and .members[0].issue == 930001' \
  "$tmp/active-job.json" >/dev/null
grep -Fq 'complete plan with changes (file, symbol, change)' "$WEB_ADVISOR_PROVIDER_JOB_DIR/$new_job_id/question.txt"
grep -Fq 'keep the shared contract' "$WEB_ADVISOR_PROVIDER_JOB_DIR/$new_job_id/question.txt"
[[ "$(wc -l < "$tmp/calls" | tr -d '[:space:]')" == 1 ]]

echo 'ok - missing plan dispatches one corrective batch re-ask with the prior ruling and frozen question'
