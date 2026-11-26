#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
WORK_MODEL="$(jq -r '.roles.work.model' "$SCRIPT_DIR/model-policy.default.json")"
WORK_EFFORT="$(jq -r '.roles.work.effort' "$SCRIPT_DIR/model-policy.default.json")"
CODEX_EXHAUSTED_MARKER_FILE="$AGENT_HOME/codex-exhausted-until"
CODEX_SCOPE_CALL_FILE="$test_env_root/codex-scope-call"
PROMPT_FILE="$test_env_root/prompt.md"
OWNER_LOG_ROOT="$test_env_root/logs"
OWNER_MANIFEST="$test_env_root/owner.json"
OWNER_PENDING_LOG="$test_env_root/owner.pending.log"
OWNER_PID_FILE="$test_env_root/owner.pid"
export CODEX_EXHAUSTED_MARKER_FILE CODEX_SCOPE_CALL_FILE
mkdir -p "$AGENT_HOME" "$OWNER_LOG_ROOT"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
printf '%s\n' 'Run the owner session.' > "$PROMPT_FILE"
cat > "$test_env_bin/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == 'features list' ]]; then printf 'feature flags parsed\n'; exit 0; fi
printf 'called\n' > "$CODEX_SCOPE_CALL_FILE"
cat >/dev/null
exit 0
STUB
chmod +x "$test_env_bin/codex"

run_owner() {
  local id="$1" cfg="${2:-}"
  printf '%s\n' '{"status":"launching"}' > "$OWNER_MANIFEST"
  : > "$OWNER_PENDING_LOG"
  if [[ -n "$cfg" ]]; then export CFG="$cfg"; else unset CFG || true; fi
  OWNER_STATUS=0
  OWNER_OUTPUT="$(PATH="$test_env_bin:$PATH" AGENT_HOME="$AGENT_HOME" \
    CODEX_HOME="$HOME/.codex" ZF_REPO_DIR="$ROOT" REPO_DIR="$ROOT" \
    bash "$SCRIPT_DIR/dispatch-codex.sh" --owner-session "$PROMPT_FILE" "$OWNER_PID_FILE" \
      "$OWNER_MANIFEST" "$OWNER_PENDING_LOG" "$OWNER_LOG_ROOT" "$ROOT" \
      work "$WORK_MODEL" "$WORK_EFFORT" delivery zf-owner-test "$id" test 2>&1)" || OWNER_STATUS=$?
}

run_owner owner-scope-default
[[ "$OWNER_STATUS" == 75 ]] || { printf 'default scope status=%s output=%s\n' "$OWNER_STATUS" "$OWNER_OUTPUT" >&2; exit 1; }
[[ ! -e "$CODEX_SCOPE_CALL_FILE" ]] || { echo 'default scope ran Codex under a provider hold' >&2; exit 1; }
routing_file="$AGENT_HOME/model-routing.json"
printf '%s\n' '{"quota_marker_scope":{"codex":{"owner_session":"allow"}}}' > "$routing_file"
cfg="$(jq -cn --arg file "$routing_file" '{models:{routing_file:$file}}')"
run_owner owner-scope-allow "$cfg"
[[ "$OWNER_STATUS" == 0 ]] || { printf 'allow scope status=%s output=%s\n' "$OWNER_STATUS" "$OWNER_OUTPUT" >&2; exit 1; }
jq -e '.status == "exited" and .exit_code == 0' "$OWNER_MANIFEST" >/dev/null
[[ -s "$CODEX_SCOPE_CALL_FILE" ]] || { echo 'scope allow did not reach Codex' >&2; exit 1; }
printf '%s\n' 'owner-session-quota-scope.test.sh: rc=0'
