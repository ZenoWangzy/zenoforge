#!/usr/bin/env bash
# Regression tests for model calls.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
LIB_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$LIB_TEST_ROOT/lib-test-setup.sh"; LIB_TEST_SETUP_DEFERRED=1; source "$LIB_TEST_ROOT/test-lib-helpers.sh"; unset LIB_TEST_SETUP_DEFERRED; lib_test_setup "$LIB_TEST_ROOT"; LIB_TEST_SETUP_COMPLETE=1

test_provider_quota_classification() {
  local refusal="ERROR: You’ve hit your usage limit. Try again at Oct 19th, 2099 1:13 AM." event
  assert_false "signal status never classifies even a real refusal" premium_call_is_quota_refused "$refusal" 143
  assert_false "successful exit never creates quota hold" premium_call_is_quota_refused "$refusal" 0
  assert_false "bare quota prose is not provider evidence" premium_call_is_quota_refused 'an overly broad quota regex' 1
  assert_false "bare rate limit prose is not provider evidence" premium_call_is_quota_refused 'rate limit exceeded, try again later' 1
  assert_false "bare HTTP status is not provider evidence" premium_call_is_quota_refused 'HTTP 429 Too Many Requests' 1
  assert_false "codex-error prose is not provider evidence" premium_call_is_quota_refused '2026-10-11T23:07:06Z codex-error fixing quota and rate limit' 1
  assert_true "actual Codex usage-limit line is provider evidence" premium_call_is_quota_refused "$refusal" 1
  assert_true "normalized HTTP 429 error remains supported" premium_call_is_quota_refused '{"api_error_status":429}' 1
  event="$(jq -cn --arg message "${refusal#ERROR: }" '{type:"turn.failed",error:{message:$message}}')"
  assert_true "CLI turn.failed event is provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg message "${refusal#ERROR: }" '{type:"error",message:$message}')"
  assert_true "CLI error event is provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg text "$refusal" '{type:"item.completed",item:{type:"agent_message",text:$text}}')"
  assert_false "agent JSON quoting refusal is not provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg result "$refusal" '{is_error:true,result:$result}')"
  assert_true "run_codex_json failure envelope retains provider error" premium_call_is_quota_refused "$event" 1
  assert_false "504 containing quota prose is not quota" premium_call_is_quota_refused 'ERROR: unexpected status 504 Gateway Timeout: quota proxy unavailable' 1
  assert_false "websocket close containing quota prose is not quota" premium_call_is_quota_refused 'ERROR: websocket closed by server before response.completed: quota' 1
  assert_eq "uppercase CLI Try again parses exact reset" "$(agent_epoch 'Oct 19, 2099 1:13 AM')" "$(parse_quota_reset_epoch "$refusal")"
  assert_eq "same-day CLI reset time parses" "$(agent_epoch '1:13 AM')" "$(parse_quota_reset_epoch 'ERROR: You’ve hit your usage limit. Try again at 1:13 AM.')"
}
test_provider_quota_classification

lib_case_exit
