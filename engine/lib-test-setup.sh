#!/usr/bin/env bash
# Shared setup for the library test suites.
lib_test_setup() {
  LIB_TEST_AGENT_HOME="$AGENT_HOME"
  INBOX_HELPER_HOME="$(mktemp -d)"
  LIB_TEST_TMP_DIRS=()
  SCRIPT_DIR="$1"
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

  # Default-value assertions must ignore operator runtime overrides.
  while IFS= read -r model_variable; do
    if [[ "$model_variable" == AGENT_MODEL* ]]; then unset "$model_variable"; fi
  done < <(compgen -e)

  # shellcheck source=./lib.sh
  source "$SCRIPT_DIR/lib.sh"
  POLICY_WORK_MODEL="$(jq -r '.roles.work.model' "$MODEL_POLICY_DEFAULT")"
  POLICY_WORK_EFFORT="$(jq -r '.roles.work.effort' "$MODEL_POLICY_DEFAULT")"
  POLICY_WORK_TIER="$(jq -r '.roles.work.service_tier // empty' "$MODEL_POLICY_DEFAULT")"
  POLICY_PRODUCTION_MODEL="$(jq -r '.roles.production.model' "$MODEL_POLICY_DEFAULT")"
  POLICY_PRODUCTION_EFFORT="$(jq -r '.roles.production.effort' "$MODEL_POLICY_DEFAULT")"
  POLICY_ADVISOR_IDENTITY="$MODEL_POLICY_TEST_ADVISOR_IDENTITY"
  printf -v POLICY_WORK_IDENTITY 'codex:%s:%s' "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT"
  printf -v POLICY_PRODUCTION_IDENTITY 'codex:%s:%s' "$POLICY_PRODUCTION_MODEL" "$POLICY_PRODUCTION_EFFORT"
  export POLICY_WORK_MODEL POLICY_WORK_EFFORT POLICY_WORK_IDENTITY POLICY_PRODUCTION_IDENTITY POLICY_ADVISOR_IDENTITY POLICY_WORK_TIER

  FAILED=0
  ASSERTIONS=0

  LIB_TEST_STDERR_LOG="$(mktemp)"
  exec 3>&1 4>&2 >/dev/null 2>"$LIB_TEST_STDERR_LOG"
}
