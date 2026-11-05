#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
ROOT="$MAC_AUTOPILOT_ENV_ROOT"
source "$script_dir/scheduler.d/worker-command.sh"

# Keep this focused on the command builder's public boundary; unrelated scheduler policy is stubbed.
jqf() { command jq "$@"; }
provider_of() { [[ "$1" == claude-* ]] && printf claude || printf codex; }
unit_field() { printf false; }
worker_rules() { :; }
fail() { printf 'worker-command.test.sh: %s\n' "$*" >&2; exit 1; }
contains_arg() { [[ " $1 " == *" $2 "* ]]; }

CFG='{"models":[["gpt-6-luna","max","fast"]]}'
CODEX_ENV_ARGS=(-c shell_environment_policy.inherit=all)
UNITS="$test_env_root/units.json"
printf '%s\n' '{"units":[{"id":"implement-1"},{"id":"review-1"}]}' > "$UNITS"
CODEX_HOME="$test_env_root/codex-home"
export CODEX_HOME
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[mcp_servers.chrome-devtools-shared]
command = "fake-chrome"

[mcp_servers.gbrain]
command = "fake-gbrain"
TOML

build_codex_command implement gpt-6-luna max implement-1 'implement prompt'
implement_args=" ${CODEX_COMMAND[*]} "
contains_arg "$implement_args" '-c mcp_servers.chrome-devtools-shared.enabled=false' \
  || fail "implement command omitted chrome MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$implement_args" '-c mcp_servers.gbrain.enabled=false' \
  || fail "implement command omitted gbrain MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$implement_args" '-c tool_output_token_limit=8000' \
  || fail "implement command omitted output limit: ${CODEX_COMMAND[*]}"

build_codex_command review gpt-6-luna max review-1 'review prompt'
review_args=" ${CODEX_COMMAND[*]} "
contains_arg "$review_args" '-c mcp_servers.chrome-devtools-shared.enabled=false' \
  || fail "review command omitted chrome MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$review_args" '-c mcp_servers.gbrain.enabled=false' \
  || fail "review command omitted gbrain MCP override: ${CODEX_COMMAND[*]}"
[[ "$review_args" != *'tool_output_token_limit='* ]] \
  || fail "review command unexpectedly set output limit: ${CODEX_COMMAND[*]}"

eval "$(sed -n '/^CLAUDE_REVIEW_TOOLS=/p' "$script_dir/scheduler.sh")"
ENGINE_ROOT="$(cd -- "$script_dir/../.." && pwd -P)"
build_codex_command review claude-sonnet-4-5 high review-1 'Sonnet fallback review prompt'
allowed_tools=""
for ((i = 0; i < ${#CODEX_COMMAND[@]}; i++)); do
  if [[ "${CODEX_COMMAND[i]}" == --allowedTools ]]; then
    allowed_tools="${CODEX_COMMAND[i + 1]:-}"
    break
  fi
done
[[ -n "$allowed_tools" ]] || fail 'Sonnet fallback command omitted --allowedTools'
[[ "$allowed_tools" == *'Bash(node --test:*)'* ]] || fail "Sonnet fallback cannot rerun node tests: $allowed_tools"
for runner in 'Bash(pnpm:*)' 'Bash(npx vitest:*)' 'Bash(bash *.test.sh)'; do
  [[ "$allowed_tools" == *"$runner"* ]] || fail "Sonnet fallback omitted test runner $runner: $allowed_tools"
done
for push_grant in 'Bash(git push' 'Bash(git:*)' 'Bash(git *)' 'Bash(git*)'; do
  [[ "$allowed_tools" != *"$push_grant"* ]] || fail "Sonnet fallback must not be allowed to push: $allowed_tools"
done
gh_permissions=()
IFS=',' read -r -a permission_entries <<<"$allowed_tools"
for permission in "${permission_entries[@]}"; do
  case "$permission" in
    'Bash(gh pr view:*)'|'Bash(gh pr diff:*)'|'Bash(gh pr checks:*)'|'Bash(gh issue view:*)')
      gh_permissions+=("$permission")
      ;;
    Bash\(gh*) fail "Sonnet fallback has unexpected GitHub permission: $permission" ;;
  esac
done
expected_gh_permissions='Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr checks:*),Bash(gh issue view:*)'
actual_gh_permissions="$(IFS=,; printf '%s' "${gh_permissions[*]}")"
[[ "$actual_gh_permissions" == "$expected_gh_permissions" ]] \
  || fail "Sonnet fallback GitHub read permissions changed: $actual_gh_permissions"
review_prompt="${CODEX_COMMAND[2]}"
for runner in 'pnpm <script>' 'npx vitest <file>' 'node --test <file>' 'bash <file>.test.sh'; do
  [[ "$review_prompt" == *"$runner"* ]] || fail "Sonnet fallback prompt omitted test runner $runner"
done
review_command=" ${CODEX_COMMAND[*]} "
[[ "$review_command" == *' --tools Read,Grep,Glob,Bash '* ]] || fail 'Sonnet fallback tool surface changed'
[[ "$review_command" == *' --permission-mode dontAsk '* ]] || fail 'Sonnet fallback permission mode changed'

# Claude implement: stream-json, isolated from user settings, write/push confined to the unit worktree and branch.
SESSION_RE='^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$'
SUP="$test_env_root/sup"
impl_repo="$test_env_root/impl-repo"
git init -q -b unit/impl-1 "$impl_repo"
git -C "$impl_repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
unit_json='{}'
unit_field() { jq -r "$2" <<<"$unit_json"; }
impl_value() { # flag name -> the argument after it
  local i
  for ((i = 0; i < ${#CODEX_COMMAND[@]}; i++)); do
    [[ "${CODEX_COMMAND[i]}" == "$1" ]] && { printf '%s' "${CODEX_COMMAND[i + 1]}"; return 0; }
  done
  return 1
}
build_codex_command implement claude-sonnet-5-5 high impl-1 'implement prompt' 'implement prompt' "$impl_repo" claude \
  || fail 'Claude implement command was refused'
[[ "${CODEX_COMMAND[0]}" == claude && "${CODEX_COMMAND[1]}" == -p ]] || fail "Claude implement is not claude -p: ${CODEX_COMMAND[*]:0:2}"
impl_command=" ${CODEX_COMMAND[*]} "
for flag in '--model claude-sonnet-5-5' '--effort high' '--output-format stream-json' '--verbose' '--permission-mode dontAsk' '--safe-mode' '--strict-mcp-config'; do
  [[ "$impl_command" == *" $flag "* ]] || fail "Claude implement command omitted $flag"
done
[[ "$(impl_value --setting-sources)" == '' ]] || fail 'Claude implement loads user/project settings'
[[ "$impl_command" != *bypassPermissions* && "$impl_command" != *dangerously* ]] || fail 'Claude implement bypasses permissions'
[[ "$WORKER_STDOUT_REPORT" == 0 && "$CODEX_MODE" == fresh && "$CODEX_USAGE_START" == *'"input_tokens":0'* ]] || fail 'Claude implement mode/accounting baseline wrong'
impl_tools="$(impl_value --allowedTools)"
[[ ",$impl_tools," == *",Edit(/$impl_repo/**),"* && ",$impl_tools," == *",Write(/$impl_repo/**),"* ]] || fail "Claude implement writes are not scoped to the worktree: $impl_tools"
[[ ",$impl_tools," == *",Read(/$SUP/**),"* ]] || fail 'Claude implement cannot read the supervisor reports'
[[ ",$impl_tools," == *',Bash(git push origin unit/impl-1),'* ]] || fail "Claude implement cannot push its own branch: $impl_tools"
for bare in Edit Write Read 'Bash(git push:*)' 'Bash(git:*)' 'Bash(git *)' 'Bash(gh pr merge:*)' 'Bash(curl:*)' 'Bash(node:*)'; do
  [[ ",$impl_tools," != *",$bare,"* ]] || fail "Claude implement allows $bare"
done
git -C "$impl_repo" checkout -q -b main
build_codex_command implement claude-sonnet-5-5 high impl-1 'p' 'p' "$impl_repo" claude || fail 'Claude implement on main was refused'
[[ "$(impl_value --allowedTools)" != *'git push'* ]] || fail 'Claude implement may push from main'
git -C "$impl_repo" checkout -q unit/impl-1
unit_json='{"lane":"direct-main"}'
build_codex_command implement claude-sonnet-5-5 high impl-1 'p' 'p' "$impl_repo" claude || fail 'Claude direct-main implement was refused'
[[ "$(impl_value --allowedTools)" != *'git push'* ]] || fail 'Claude direct-main implement may push'

# repair resumes the recorded Claude session when its file exists, with a fresh start otherwise.
claude_sid=123e4567-e89b-12d3-a456-426614174000
export CLAUDE_CONFIG_DIR="$test_env_root/claude-home"
unit_json="{\"sessions\":{\"repair\":{\"id\":\"$claude_sid\",\"provider\":\"claude\",\"model\":\"claude-sonnet-5-5\"}}}"
build_codex_command repair claude-sonnet-5-5 high impl-1 'cold' 'new failure' "$impl_repo" claude || fail 'Claude repair was refused'
[[ "$CODEX_MODE" == fresh && "$CODEX_PATH_REASON" == session-files-missing ]] || fail "Claude repair resumed without a session file ($CODEX_MODE/$CODEX_PATH_REASON)"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-x" && : > "$CLAUDE_CONFIG_DIR/projects/-x/$claude_sid.jsonl"
build_codex_command repair claude-sonnet-5-5 high impl-1 'cold' 'new failure' "$impl_repo" claude || fail 'Claude repair resume was refused'
[[ "$CODEX_MODE" == resume && "$CODEX_SESSION_ID" == "$claude_sid" && "$(impl_value --resume)" == "$claude_sid" ]] || fail 'Claude repair did not --resume the recorded session'
[[ "${CODEX_COMMAND[2]}" == 'new failure'* ]] || fail 'Claude resume did not send the new failure'
unit_json="{\"sessions\":{\"repair\":{\"id\":\"$claude_sid\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\"}}}"
build_codex_command repair claude-sonnet-5-5 high impl-1 'cold' 'new failure' "$impl_repo" claude || fail 'Claude repair after a provider change was refused'
[[ "$CODEX_MODE" == fresh && "$CODEX_PATH_REASON" == provider-changed ]] || fail 'Claude resumed another provider session'

printf '%s\n' 'PASS scheduler Codex commands disable configured MCP servers and limit implement tool output'
printf '%s\n' 'PASS Sonnet fallback allows focused test runners and does not allow git push'
printf '%s\n' 'PASS Claude implement is stream-json, worktree-scoped, branch-only push, resumes its own session'
