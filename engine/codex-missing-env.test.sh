#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
export ZF_LOCAL_BIN_DIR="$test_env_root/local-bin"
export ZF_CHATGPT_RESOURCES_DIR="$test_env_root/chatgpt-resources"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/advisor-core.sh"
jq ".roles.advisor.disabled = false" "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

FAILED=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$label" "$expected" "$actual"
    FAILED=1
  fi
}
assert_contains() {
  local label="$1" value="$2" expected="$3"
  if [[ "$value" == *"$expected"* ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected to find [%s])\n' "$label" "$expected"
    FAILED=1
  fi
}

cat > "$test_env_bin/codex" <<'CODEX'
#!/usr/bin/env bash
echo "env: 'codex': No such file or directory" >&2
exit 127
CODEX
chmod +x "$test_env_bin/codex"

TEST_ISSUE=9901801
state_merge "$TEST_ISSUE" '{state:"ready-for-agent",attempts:2,model_policy:{unit:"implement",step:"work",active:{unit:"implement",step:"work",role:"work",model_started:false}}}'
if preflight_output="$(codex_dispatch_preflight issue-pipeline 2>&1)"; then preflight_status=0; else preflight_status=$?; fi
assert_eq 'missing Codex pauses shared dispatch preflight' 1 "$preflight_status"
assert_contains 'preflight records binary environment fault' "$preflight_output" 'env:codex-binary-missing'
assert_eq 'preflight leaves ticket stage untouched' ready-for-agent "$(state_read "$TEST_ISSUE" | jq -r '.state')"
assert_eq 'preflight consumes no attempt' 2 "$(state_read "$TEST_ISSUE" | jq -r '.attempts')"

# Exercise issue-pipeline's actual earliest guard. It must exit before issue
# discovery and all stage dispatches when the shared probe fails.
if pipeline_output="$(bash "$SCRIPT_DIR/issue-pipeline.sh" --stage implement 2>&1)"; then pipeline_status=0; else pipeline_status=$?; fi
assert_eq 'issue-pipeline exits cleanly while Codex is unavailable' 0 "$pipeline_status"
assert_contains 'issue-pipeline says no tickets consumed' "$pipeline_output" 'no tickets consumed; dispatch paused'
assert_eq 'paused pipeline still leaves ticket stage untouched' ready-for-agent "$(state_read "$TEST_ISSUE" | jq -r '.state')"
assert_eq 'paused pipeline still consumes no attempt' 2 "$(state_read "$TEST_ISSUE" | jq -r '.attempts')"

schema_file="$test_env_root/schema.json"
prompt_file="$test_env_root/prompt.md"
printf '%s\n' '{"type":"object"}' > "$schema_file"
printf '%s\n' 'Return one object.' > "$prompt_file"
model="$MODEL_POLICY_TEST_WORK_MODEL"
effort="$MODEL_POLICY_TEST_WORK_EFFORT"
identity="codex:$model:$effort"
state_bump_attempts "$TEST_ISSUE"
if model_output="$(run_codex_json "$REPO_DIR" "$model" "$effort" "$schema_file" "$prompt_file")"; then call_status=0; else call_status=$?; fi
assert_eq 'missing agent binary returns exit 127 from model call' 127 "$call_status"
assert_eq 'exit 127 is a transient environment failure' transient "$(model_call_failure_kind "$model_output" "$call_status")"
pause_for_backoff "$TEST_ISSUE" "$model_output" "$call_status" 0 codex "$identity" run-implement:implement
model_policy_record_failure "$TEST_ISSUE" work implement 'Codex could not start' "$model_output" "$call_status" ready-for-agent implement
assert_eq 'implement model fault refunds attempt' 2 "$(state_read "$TEST_ISSUE" | jq -r '.attempts')"
assert_eq 'implement model fault keeps ticket stage' ready-for-agent "$(state_read "$TEST_ISSUE" | jq -r '.state')"
assert_eq 'implement model fault keeps policy rung' work "$(state_read "$TEST_ISSUE" | jq -r '.model_policy.step')"
assert_eq 'implement model fault creates no advisor transition' null "$(state_read "$TEST_ISSUE" | jq -r '.model_policy.failure.transition // null')"
assert_contains 'Codex fault enters existing environment ledger' \
  "$(cat "$AGENT_HOME/env-faults/env:codex-binary-missing.log")" $'\timplement\t'

# The same shared failure handler covers each Codex model leg: repair/review
# inside implement, plus standalone recut and triage policy units.
exercise_model_leg_fault() {
  local number="$1" call_stage="$2" state_stage="$3" policy_unit="$4"
  state_merge "$number" ".state = \"$state_stage\" | .attempts = 2 | .model_policy = {unit:\"$policy_unit\",step:\"work\",active:{unit:\"$policy_unit\",step:\"work\",role:\"work\",model_started:true}}"
  state_bump_attempts "$number"
  pause_for_backoff "$number" "$model_output" "$call_status" 0 codex "$identity" "run-$call_stage:$call_stage"
  model_policy_record_failure "$number" work "$call_stage" 'Codex could not start' "$model_output" \
    "$call_status" "$state_stage" "$policy_unit"
  assert_eq "$call_stage missing binary refunds attempt" 2 "$(state_read "$number" | jq -r '.attempts')"
  assert_eq "$call_stage missing binary preserves stage" "$state_stage" "$(state_read "$number" | jq -r '.state')"
  assert_eq "$call_stage missing binary preserves model rung" work "$(state_read "$number" | jq -r '.model_policy.step')"
  assert_eq "$call_stage missing binary creates no policy transition" null \
    "$(state_read "$number" | jq -r '.model_policy.failure.transition // null')"
}
exercise_model_leg_fault 9901810 repair ready-for-agent implement
exercise_model_leg_fault 9901811 review ready-for-agent implement
exercise_model_leg_fault 9901812 recut needs-recut recut
exercise_model_leg_fault 9901813 triage needs-triage triage

ADVISOR_ISSUE=9901802
state_merge "$ADVISOR_ISSUE" '{state:"needs-advisor",attempts:4,model_policy:{unit:"implement",step:"advisor"}}'
advisor_record_failed_attempt "$ADVISOR_ISSUE" 'advisor tool could not start' 1 'agent tool exit 127' \
  'agent-tool exit 127: codex No such file or directory' 127 run-advisor:advisor "$MODEL_POLICY_TEST_ADVISOR_MODEL"
assert_eq 'advisor missing binary refunds attempt' 4 "$(state_read "$ADVISOR_ISSUE" | jq -r '.attempts')"
assert_eq 'advisor missing binary stays at advisor stage' needs-advisor "$(state_read "$ADVISOR_ISSUE" | jq -r '.state')"
assert_eq 'advisor missing binary records no semantic failure' null "$(state_read "$ADVISOR_ISSUE" | jq -r '.last_failure_reason // null')"

# A dangling user link is repaired only from working bundled binaries.
mkdir -p "$ZF_LOCAL_BIN_DIR" "$ZF_CHATGPT_RESOURCES_DIR"
cat > "$ZF_CHATGPT_RESOURCES_DIR/codex" <<'BUNDLED_CODEX'
#!/usr/bin/env bash
[[ "$*" == 'features list' ]]
BUNDLED_CODEX
cat > "$ZF_CHATGPT_RESOURCES_DIR/rg" <<'BUNDLED_RG'
#!/usr/bin/env bash
[[ "$1" == --version ]]
BUNDLED_RG
chmod +x "$ZF_CHATGPT_RESOURCES_DIR/codex" "$ZF_CHATGPT_RESOURCES_DIR/rg"
ln -s "$test_env_root/missing-codex" "$ZF_LOCAL_BIN_DIR/codex"
ln -s "$test_env_root/missing-rg" "$ZF_LOCAL_BIN_DIR/rg"
env_fault_repair env:codex-binary-missing
assert_eq 'dangling Codex link points to tested bundled binary' "$ZF_CHATGPT_RESOURCES_DIR/codex" "$(readlink "$ZF_LOCAL_BIN_DIR/codex")"
assert_eq 'dangling rg link points to tested bundled binary' "$ZF_CHATGPT_RESOURCES_DIR/rg" "$(readlink "$ZF_LOCAL_BIN_DIR/rg")"
assert_eq 'repaired Codex clears the shared runtime probe' 0 "$(PATH="$ZF_LOCAL_BIN_DIR:$PATH" codex_config_probe >/dev/null 2>&1; echo $?)"
assert_eq 'supervisor inbox records each repaired binary' 2 "$(grep -c 'codex-runtime-repair binary=' "$AGENT_HOME/supervisor-inbox")"
assert_contains 'hand dispatcher uses shared Codex preflight' "$(cat "$SCRIPT_DIR/night/dispatch.sh")" 'codex_dispatch_preflight hand-dispatch'
assert_contains 'Codex dispatcher uses shared Codex preflight' "$(cat "$SCRIPT_DIR/dispatch-codex.sh")" 'codex_dispatch_preflight "$stage"'

rm -f "$CODEX_PROBE_MARKER"
assert_eq 'missing sandbox marker keeps the codex-sandbox quarantine closed' 1 "$(env_fault_probe env:codex-sandbox-probe; echo $?)"
date -u +%FT%TZ > "$CODEX_PROBE_MARKER"
assert_eq 'a written sandbox marker lets the quarantine lift' 0 "$(env_fault_probe env:codex-sandbox-probe; echo $?)"

if (( FAILED )); then exit 1; fi
printf 'codex-missing-env.test.sh: PASS\n'
