#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
target="$tmp/target/.zenoforge"
pack="$tmp/pack"
mkdir -p "$target/prompts" "$pack/prompts"
printf 'target batch prompt\n' > "$target/prompts/advisor-batch.md"
printf 'pack batch prompt\n' > "$pack/prompts/advisor-batch.md"
printf 'target single prompt\n' > "$target/prompts/advisor.md"
printf 'pack single prompt\n' > "$pack/prompts/advisor.md"
printf '{"target":true}\n' > "$target/prompts/advisor.schema.json"
printf '{"pack":true}\n' > "$pack/prompts/advisor.schema.json"
cat > "$target/night.json" <<'JSON'
{"advisor":{"provider":"web-advisor-provider","prompts":{"single":"prompts/advisor.md","batch":"prompts/advisor-batch.md"},"schemas":{"single":"prompts/advisor.schema.json"},"labels":{"queue":"target-queue","priority":"target-priority"}}}
JSON
cat > "$pack/night.json" <<'JSON'
{"advisor":{"provider":"unused-provider","prompts":{"single":"prompts/pack.md","batch":"prompts/pack-batch.md"},"schemas":{"single":"prompts/pack.schema.json"},"labels":{"queue":"pack-queue","priority":"pack-priority"}}}
JSON
printf 'pack single prompt\n' > "$pack/prompts/pack.md"
printf 'pack batch prompt\n' > "$pack/prompts/pack-batch.md"
printf '{"pack":true}\n' > "$pack/prompts/pack.schema.json"

ZF_CONFIG_ROOT="$target" ZF_PACK_DIR="$pack" bash -c '
  source "$1/advisor-config.sh"
  model_policy() { [[ "$1 $2" == "identity advisor" ]] && printf "web:fixture-model\\n"; }
  advisor_provider_ready
  [[ "$(advisor_prompt_file batch)" == "$ZF_CONFIG_ROOT/prompts/advisor-batch.md" ]]
  [[ "$(advisor_prompt_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.md" ]]
  [[ "$(advisor_schema_file single)" == "$ZF_CONFIG_ROOT/prompts/advisor.schema.json" ]]
  [[ "$(advisor_queue_label)" == target-queue ]]
  [[ "$(advisor_priority_label)" == target-priority ]]
  grep -Fq "target batch prompt" "$(advisor_prompt_file batch)"
  ! grep -Fq "pack batch prompt" "$(advisor_prompt_file batch)"
' _ "$script_dir"

# PR #189 made every poll persist provider incident diagnostics before the
# status handling, so advisor_batch_poll_provider_job() now calls
# advisor_batch_capture_provider_diagnostics(); extract both real functions
# and give the capture step the tick globals production sets.
eval "$(sed -n '/^advisor_batch_capture_provider_diagnostics() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_poll_provider_job() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
source "$script_dir/lib.sh"
source "$script_dir/providers/web-advisor-provider.sh"
LOG_DIR="$tmp/logs"
ADVISOR_TICK_ID="fixture-tick"
WEB_ADVISOR_PROVIDER_JOB_DIR="$tmp/jobs"
BATCH_JOB_ID="fixture-job"
mkdir -p "$LOG_DIR" "$WEB_ADVISOR_PROVIDER_JOB_DIR"
(
  started="$tmp/provider-started"; web_advisor_provider_start_job_unit() { : > "$started"; }; quarantine_mark_canary_scope_list() { return 1; }
  printf 'question\n' > "$tmp/provider-question"; ZF_QUARANTINE_CANARY_SCOPES=advisor; status=0
  web_advisor_provider_dispatch_question_async charge-failure "$tmp/provider-question" 2>"$tmp/provider-charge.log" || status=$?
  [[ "$status" == 0 && -f "$started" ]] && grep -Fq 'canary mark failed after job start' "$tmp/provider-charge.log"
)
eval "$(sed -n '/^advisor_batch_web_dispatch() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
(
  quarantine_open advisor env:test-gate:advisor 'batch canary fixture' 2 "$(date +%s)" >/dev/null 2>&1
  canary_file="$(quarantine_file advisor)"; before="$(jq -r '.canaries' "$canary_file")"
  started="$tmp/batch-provider-started"; web_advisor_provider_start_job_unit() { : > "$started"; }
  model_policy() { [[ "$1 $2" == 'identity advisor' ]] && printf 'web:fixture-model\n'; }
  ZF_QUARANTINE_CANARY_SCOPES=advisor
  advisor_batch_web_dispatch batch-canary "$tmp/provider-question"
  after="$(jq -r '.canaries' "$canary_file")"
  [[ -f "$started" && "$before:$after" == '0:1' ]]
)
eval "$(sed -n '/^advisor_batch_dispatch_plan_reask() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
mkdir -p "$WEB_ADVISOR_PROVIDER_JOB_DIR/fixture-job"; printf 'saved question\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/fixture-job/question.txt"
BATCH_TOPIC=fixture WEB_ADVISOR_PROVIDER_TOPIC=fixture ACTIVE_BATCH_JOB='{}' ADVISOR_MODEL_USED=fixture INCLUDED=1 ADVISOR_MODEL_FALLBACK= ADVISOR_TICKET_LOCK_FDS=() BATCH_LOCK_FD=9
advisor_plan_contract() { printf 'plan contract'; }; record_premium_spend() { :; }; advisor_batch_state_set_job() { :; }; advisor_batch_forget_provider_job() { :; }; advisor_batch_state_read() { printf '{}\n'; }
run_with_fd_closed() { while [[ "$1" != -- ]]; do shift; done; shift; "$@"; }; web_advisor_provider_dispatch_question_async() { printf '%s' "${ZF_QUARANTINE_CANARY_SCOPES:-}" > "$tmp/reask-scopes"; }
ZF_QUARANTINE_CANARY_SCOPES=advisor
advisor_batch_dispatch_plan_reask '[]' '[930001]'
[[ ! -s "$tmp/reask-scopes" ]]; BATCH_JOB_ID=fixture-job
# 548: an over-limit plan re-ask drops the quoted rulings and sends nothing if still over; the job records the bytes sent.
(
  rulings="$(printf 'r%.0s' {1..2000})"
  advisor_batch_state_set_job() { printf '%s' "$1" > "$tmp/reask-job"; }
  web_advisor_provider_dispatch_question_async() { cp "$2" "$tmp/reask-sent"; }
  advisor_batch_state_read() { printf '{"max_safe_input_bytes":1000}\n'; }
  BATCH_JOB_ID=fixture-job; advisor_batch_dispatch_plan_reask "[\"$rulings\"]" '[930001]'
  sent_bytes="$(wc -c < "$tmp/reask-sent")"
  ! grep -Fq "$rulings" "$tmp/reask-sent"
  [[ "$sent_bytes" -le 1000 && "$(jq -r '.input_bytes' "$tmp/reask-job")" == "$sent_bytes" ]]
  rm -f "$tmp/reask-sent"; advisor_batch_state_read() { printf '{"max_safe_input_bytes":100}\n'; }
  BATCH_JOB_ID=fixture-job; ! advisor_batch_dispatch_plan_reask "[\"$rulings\"]" '[930001]' 2>/dev/null
  [[ ! -e "$tmp/reask-sent" ]]
  advisor_batch_state_read() { printf '{}\n'; }
  BATCH_JOB_ID=fixture-job; advisor_batch_dispatch_plan_reask "[\"$rulings\"]" '[930001]'
  grep -Fq "$rulings" "$tmp/reask-sent"
)
# 555: a one-ticket canary keeps the rest of its size-split group active until a job covers the whole group.
(
  split_state="$tmp/split-state.json"
  eval "$(sed -n '/^advisor_batch_size_split_record_success() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
  advisor_batch_state_read() { cat "$split_state"; }
  advisor_batch_state_write() { printf '%s\n' "$1" > "$split_state"; }
  printf '%s\n' '{"size_split":{"active_issue_ids":[930001,930002],"pending_issue_groups":[[930003]]}}' > "$split_state"
  advisor_batch_size_split_record_success '{"input_bytes":100,"members":[{"issue":930001}]}'
  jq -e '.size_split.active_issue_ids == [930001,930002] and .size_split.pending_issue_groups == [[930003]]' "$split_state" >/dev/null
  advisor_batch_size_split_record_success '{"input_bytes":200,"members":[{"issue":930002},{"issue":930001}]}'
  jq -e '.size_split.active_issue_ids == [930003] and .size_split.pending_issue_groups == [] and .max_safe_input_bytes == 200' "$split_state" >/dev/null
)
# Exercise the real batch poller through the runner adapter, including pending
# evidence retention and recovery of only complete records on timeout.
web_advisor_provider_resume_job_if_stopped() { :; }
mkdir -p "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID"
printf 'frozen question\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/question.txt"
printf 'ADVISOR_ANSWER_TIMEOUT picker-not-found\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.err"
set +e
advisor_batch_poll_provider_job fixture-job >/dev/null 2>&1
poll_status=$?
set -e
[[ "$poll_status" == 2 ]]
[[ -d "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID" && -f "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/question.txt" && -f "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.err" ]]
printf '1\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/done"
printf '%s\n%s' '{"kind":"ruling","issue":1}' '{"kind":"ruling","issue":2' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.out"
[[ "$(advisor_batch_poll_provider_job fixture-job)" == '{"kind":"ruling","issue":1}' ]]
[[ -f "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/question.txt" && -f "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.err" ]]
jq -e '.error_codes | index("ADVISOR_ANSWER_TIMEOUT") != null' "$LOG_DIR/$ADVISOR_TICK_ID.advisor-diagnostics.json" >/dev/null
jq -e '.model_fallback_signature == "picker-not-found"' "$LOG_DIR/$ADVISOR_TICK_ID.advisor-diagnostics.json" >/dev/null
printf '0\n' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/done"
printf '%s\n' '{"kind":"ruling","issue":1}' '{"kind":"ruling","issue":2}' > "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.out"
[[ "$(advisor_batch_poll_provider_job fixture-job)" == "$(cat "$WEB_ADVISOR_PROVIDER_JOB_DIR/$BATCH_JOB_ID/answer.out")" ]]
(
  web_advisor_provider_poll_ndjson() { printf '%s\n' '{"structured_output":{"kind":"ruling","issue":1}}'; }
  [[ "$(advisor_batch_poll_provider_job fixture-job)" == '{"kind":"ruling","issue":1}' ]]
)

# Load the same startup fragment as the runner, with a real live roster row.
sed -n '/^NIGHT="${ZF_NIGHT_DIR:-\$AGENT_HOME\/night}"/,/^source "\$SCRIPT_DIR\/night\/hand-agent-watchdog.sh"/p' "$script_dir/run-advisor-batch.sh" > "$tmp/ownership-startup"
[[ -s "$tmp/ownership-startup" ]]
SCRIPT_DIR="$script_dir"
ZF_NIGHT_DIR="$tmp/hand-night"
mkdir -p "$ZF_NIGHT_DIR"
source "$tmp/ownership-startup"
owner_ticks="$(hand_agent_process_start_ticks "$$")"
printf '%s\thand-930001\tmodel\teffort\tworktree\tbrief\treport\tlog\t0\t0\twork\t%s\t930001\t\n' "$$" "$owner_ticks" > "$NIGHT/agents.txt"
hand_agent_issue_is_live_owned 930001
! hand_agent_issue_is_live_owned 930002

# Run the actual pre-dispatch guard with the provider's fault classifier.
sed -n '/^  if ! ADVISOR_UNAVAILABLE_REASON=.*web_advisor_provider_usable/,/^  fi/p' "$script_dir/run-advisor-batch.sh" > "$tmp/unavailable-guard"
[[ -s "$tmp/unavailable-guard" ]]
for reason in 'advisor CDP port unreachable: 9222' 'other failure'; do
  result="$(
    web_advisor_provider_usable() { printf '%s\n' "$reason" >&2; return 1; }
    record_web_advisor_provider_fault() { web_advisor_provider_fault_signature "$2"; }
    PROMPT_FILE="$tmp/prompt"
    : > "$PROMPT_FILE"
    source "$tmp/unavailable-guard"
  )"
  if [[ "$reason" == *'CDP port unreachable'* ]]; then
    [[ "$result" == env:web-advisor-provider:cdp-unreachable ]]
  else
    [[ "$result" == env:web-advisor-provider:call-failed ]]
  fi
done

# 2026-11-04: ADVISOR_MODEL_UNVERIFIED at selector stage open-picker is a
# browser/page fault, not a payload fault. It must not quarantine the batch
# prompt (record_web_advisor_provider_fault already cools the advisor stage
# and canary-lifts on recovery), or the next canary tick reports
# prompt-quarantined and sends nothing even after the browser recovers.
# A real wedge failure still quarantines the exact prompt.
eval "$(sed -n '/^advisor_batch_is_wedge_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_browser_fault() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_size_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_empty_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_is_split_failure() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_should_quarantine_prompt() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_file_active() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_contains() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_inbox_notice() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
eval "$(sed -n '/^advisor_batch_quarantine_wedge() {/,/^}/p' "$script_dir/run-advisor-batch.sh")"
ADVISOR_BATCH_QUARANTINE_DIR="$tmp/quarantine/advisor-batch"
ADVISOR_BATCH_QUARANTINE_TTL_SECONDS=900
supervisor_inbox_append() { :; }

for code in ADVISOR_SESSION_SIGNED_OUT ADVISOR_SESSION_UNREADABLE ADVISOR_WRONG_ACCOUNT; do
  advisor_batch_is_browser_fault "$code: synthetic"
  ! advisor_batch_should_quarantine_prompt "$code: synthetic"
done
model_unverified_detail='ADVISOR_MODEL_UNVERIFIED: could not verify the selected model at selector stage open-picker'
advisor_batch_is_browser_fault "$model_unverified_detail"
! advisor_batch_should_quarantine_prompt "$model_unverified_detail"
# The incident's job never wrote done within its ceiling, so its answer.err
# tail carried the browser fault alongside a termination marker; neither
# quarantine call site may fire for it.
timeout_detail="job exceeded 5400s: $model_unverified_detail Terminated"
advisor_batch_is_browser_fault "$timeout_detail"
! advisor_batch_should_quarantine_prompt "$timeout_detail"
[[ -z "$(ls -A "$ADVISOR_BATCH_QUARANTINE_DIR" 2>/dev/null)" ]]

wedge_prompt_sig="$(printf 'a1%.0s' {1..32})"
wedge_detail='ADVISOR_TAB_UNRESPONSIVE: the batch tab stopped responding to CDP'
! advisor_batch_is_browser_fault "$wedge_detail"
advisor_batch_should_quarantine_prompt "$wedge_detail"
# A measured size failure is a payload fault and stays quarantined.
advisor_batch_should_quarantine_prompt 'HTTP 413: request entity too large'
advisor_batch_quarantine_wedge fixture-job "$wedge_prompt_sig" "" "$wedge_detail" '#930002' >/dev/null 2>&1
[[ -f "$ADVISOR_BATCH_QUARANTINE_DIR/prompt-$wedge_prompt_sig.json" ]]
advisor_batch_quarantine_contains "$wedge_prompt_sig" ""

mkdir -p "$tmp/disabled/.zenoforge"
printf '{"advisor":{"provider":""}}\n' > "$tmp/disabled/.zenoforge/night.json"
unconfigured_output="$(ZF_CONFIG_ROOT="$tmp/disabled/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$tmp/disabled" \
  bash "$script_dir/run-advisor-batch.sh" 2>&1)"
grep -Fq 'skip: advisor provider is not configured' <<< "$unconfigured_output"

echo 'ok - batch advisor uses target prompts and queue settings before pack fallbacks'
