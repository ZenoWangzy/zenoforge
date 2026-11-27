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

fail() { printf 'model-calls.test.sh: %s\n' "$*" >&2; exit 1; }

test_codex_uses_pinned_project_instructions() {
  local fixture="$test_env_root/pinned-context" repo="$test_env_root/candidate-context" version="$test_env_root/accepted-version" fakebin="$test_env_root/fake-codex" accepted_sha candidate_sha result
  mkdir -p "$repo" "$version/.agents/skills" "$fakebin"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf 'accepted instructions\n' > "$repo/AGENTS.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm accepted
  accepted_sha="$(git -C "$repo" rev-parse HEAD)"
  printf 'candidate instructions\n' > "$repo/AGENTS.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm candidate
  candidate_sha="$(git -C "$repo" rev-parse HEAD)"
  printf 'product_sha=%s\n' "$accepted_sha" > "$version/BUILD-INFO"
  _MATT_SKILLS_ENGINE_DIR="$version/.agents/skills"
  printf 'prompt\n' > "$fixture.prompt"
  printf '{}' > "$fixture.schema"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_CAPTURE_ARGS"
cat > "$CODEX_CAPTURE_STDIN"
while (($#)); do
  if [[ "$1" == --output-last-message ]]; then output_file="$2"; shift 2; else shift; fi
done
printf '{"ok":true}' > "$output_file"
SH
  chmod +x "$fakebin/codex"
  export CODEX_CAPTURE_ARGS="$fixture.args" CODEX_CAPTURE_STDIN="$fixture.stdin"
  PATH="$fakebin:$PATH"
  model_policy_require_implementer_identity() { return 0; }
  model_policy() { return 0; }
  pipeline_execution_run() { "$@"; }
  codex_mcp_context_mode_sentinel_dir() { return 0; }
  CODEX_SANDBOX_MODE=read-only CODEX_PLUGINS_OFF_ARGS=() CODEX_JSON_TIMEOUT_SECONDS=10
  result="$(run_codex_json "$repo" model effort "$fixture.schema" "$fixture.prompt")"
  [[ "$result" == *'"is_error":false'* ]] || fail 'pinned-context Codex call did not complete'
  grep -Fxq "$version" "$CODEX_CAPTURE_ARGS" || fail 'Codex did not start from the accepted instruction revision'
  grep -Fxq "$repo" "$CODEX_CAPTURE_ARGS" || fail 'Codex was not given the candidate checkout as an added directory'
  grep -Fq "$repo" "$CODEX_CAPTURE_STDIN" || fail 'Codex prompt did not name the candidate checkout'
  run_codex_implement "$repo" model effort "$fixture.prompt" "$fixture.log" 1 context-test
  grep -Fxq "$version" "$CODEX_CAPTURE_ARGS" || fail 'Codex implement loaded an unevaluated AGENTS.md'
  grep -Fxq "$repo" "$CODEX_CAPTURE_ARGS" || fail 'Codex implement lost access to the candidate checkout'
  grep -Fq "$repo" "$CODEX_CAPTURE_STDIN" || fail 'Codex implement prompt did not name the candidate checkout'
  printf 'product_sha=%s\n' "$candidate_sha" > "$version/BUILD-INFO"
  run_codex_json "$repo" model effort "$fixture.schema" "$fixture.prompt" >/dev/null
  grep -Fxq "$repo" "$CODEX_CAPTURE_ARGS" || fail 'accepted AGENTS.md did not restore the target checkout context'
}
test_codex_uses_pinned_project_instructions

grep -Fq 'matt_codex_context_prepare "$REPO_DIR"' "$LIB_TEST_ROOT/lib.d/codex-budget.sh" \
  || fail 'Codex recovery probe does not use the accepted project instruction context'
grep -Fq -- '--cd "$MATT_CODEX_CONTEXT_ROOT" --skip-git-repo-check' "$LIB_TEST_ROOT/lib.d/codex-budget.sh" \
  || fail 'Codex recovery probe does not launch from the accepted project instruction root'

lib_case_exit
