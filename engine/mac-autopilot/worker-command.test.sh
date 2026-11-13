#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$MAC_AUTOPILOT_ENV_ROOT"
source "$script_dir/scheduler.d/worker-command.sh"

# Keep this focused on the command builder's public boundary; unrelated scheduler policy is stubbed.
jqf() { command jq "$@"; }
provider_of() { [[ "$1" == claude-* ]] && printf claude || printf codex; }
unit_field() { case "$2" in .lane*) printf '%s' "${TEST_LANE:-pr}" ;; *sessions*) printf '{}' ;; *) printf false ;; esac; }
worker_rules() { :; }
fail() { printf 'worker-command.test.sh: %s\n' "$*" >&2; exit 1; }
SESSION_RE='^[0-9a-f-]{36}$'
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
# Default cap 64 KB = 16384 tokens for every codex type except implement, which keeps its tighter 8000.
contains_arg "$review_args" '-c tool_output_token_limit=16384' \
  || fail "review command omitted the default output cap: ${CODEX_COMMAND[*]}"
build_codex_command repair gpt-6-luna max review-1 'repair prompt'
contains_arg " ${CODEX_COMMAND[*]} " '-c tool_output_token_limit=16384' \
  || fail "repair command omitted the default output cap (4741): ${CODEX_COMMAND[*]}"
WORKER_OUTPUT_CAP_KB=16 build_codex_command repair gpt-6-luna max review-1 'repair prompt'
contains_arg " ${CODEX_COMMAND[*]} " '-c tool_output_token_limit=4096' \
  || fail "configured 16 KB cap not applied: ${CODEX_COMMAND[*]}"
WORKER_OUTPUT_CAP_KB=16 build_codex_command implement gpt-6-luna max implement-1 'implement prompt'
contains_arg " ${CODEX_COMMAND[*]} " '-c tool_output_token_limit=4096' \
  || fail "implement ignored a cap below its 8000: ${CODEX_COMMAND[*]}"
WORKER_OUTPUT_CAP_KB=junk build_codex_command repair gpt-6-luna max review-1 'repair prompt'
contains_arg " ${CODEX_COMMAND[*]} " '-c tool_output_token_limit=16384' \
  || fail "invalid cap did not fall back to 64 KB: ${CODEX_COMMAND[*]}"
# ZCode counts characters in BASH_MAX_OUTPUT_LENGTH (native default 30000), so the cap never loosens it.
zf_zcode_bin_argv() { printf '%s\n' "$test_env_bin/zcode"; }
provider_of() { printf zcode; }
build_codex_command repair glm-5.3 max review-1 'zcode prompt' '' "$test_env_root" zcode
contains_arg " ${CODEX_COMMAND[*]} " 'BASH_MAX_OUTPUT_LENGTH=30000' \
  || fail "zcode command omitted the output cap: ${CODEX_COMMAND[*]}"
WORKER_OUTPUT_CAP_KB=8 build_codex_command repair glm-5.3 max review-1 'zcode prompt' '' "$test_env_root" zcode
contains_arg " ${CODEX_COMMAND[*]} " 'BASH_MAX_OUTPUT_LENGTH=8192' \
  || fail "zcode ignored a configured 8 KB cap: ${CODEX_COMMAND[*]}"
# bin/luna (codex) and bin/zc (zcode) start outside build_codex_command, so they read the same cap through the lib.
grep -q 'tool_output_token_limit=$(worker_output_cap_tokens)' "$script_dir/../bin/luna" || fail 'bin/luna does not pass the output cap'
grep -q 'BASH_MAX_OUTPUT_LENGTH="$(worker_output_cap_chars)"' "$script_dir/../bin/zc" || fail 'bin/zc does not pass the output cap'
provider_of() { [[ "$1" == claude-* ]] && printf claude || printf codex; }
ENGINE_ROOT="$(cd -- "$script_dir/../.." && pwd -P)"
review_repo="$test_env_root/review-repo"
git init -q -b agent/review-1 "$review_repo"
git -C "$review_repo" config user.name reviewer-fixture
git -C "$review_repo" config user.email reviewer@example.invalid
TEST_LANE=pr build_codex_command review claude-sonnet-4-5 high review-1 'Sonnet fallback review prompt' '' "$review_repo" claude
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
[[ "$allowed_tools" == *'Edit(/'*'/**)'* && "$allowed_tools" == *'Write(/'*'/**)'* ]] || fail "reviewer cannot edit its clone: $allowed_tools"
[[ "$allowed_tools" == *'Bash(git push origin agent/review-1)'* ]] || fail "PR reviewer cannot push its own branch: $allowed_tools"
for push_grant in 'Bash(git push:*)' 'Bash(git push origin *)' 'Bash(git push -f' 'Bash(git push --force'; do
  [[ "$allowed_tools" != *"$push_grant"* ]] || fail "reviewer has an unscoped push grant: $allowed_tools"
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
[[ "$review_command" == *' --tools Read,Edit,Write,Grep,Glob,Bash '* ]] || fail 'Sonnet fallback tool surface changed'
[[ "$review_command" == *' --permission-mode dontAsk '* ]] || fail 'Sonnet fallback permission mode changed'
git -C "$review_repo" checkout -q -b main
TEST_LANE=direct-main build_codex_command review claude-sonnet-4-5 high review-1 'direct-main review prompt' '' "$review_repo" claude
direct_main_tools=""
for ((i = 0; i < ${#CODEX_COMMAND[@]}; i++)); do
  if [[ "${CODEX_COMMAND[i]}" == --allowedTools ]]; then direct_main_tools="${CODEX_COMMAND[i + 1]:-}"; break; fi
done
[[ "$direct_main_tools" != *'Bash(git push'* ]] || fail "direct-main review may push: $direct_main_tools"
for write_grant in 'Edit(/' 'Write(/' 'Bash(git add:' 'Bash(git commit:'; do
  [[ "$direct_main_tools" != *"$write_grant"* ]] || fail "direct-main review has a write grant: $direct_main_tools"
done

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
unset CODEX_FRESH_COMMAND
build_codex_command repair claude-sonnet-5-5 high impl-1 'cold' 'new failure' "$impl_repo" claude || fail 'Claude repair resume was refused'
[[ "${CODEX_COMMAND[2]}" == 'new failure'* ]] || fail 'Claude resume did not send the new failure'
[[ "${CODEX_FRESH_COMMAND[2]}" == 'cold'* && " ${CODEX_FRESH_COMMAND[*]} " != *' --resume '* ]] || fail 'Claude resume has no cold fallback for the repair runner'
# Runner: a Claude resume that dies before any work goes cold; one that already worked does not.
runner_try() { bash "$script_dir/../codex-repair-run.sh" "$test_env_root/runner.log" "$claude_sid" 2 echo fresh-ran bash -c "echo '$1'; exit 1" > "$test_env_root/runner.out" 2>&1 || true; cat "$test_env_root/runner.out" "$test_env_root/runner.log" 2>/dev/null; rm -f "$test_env_root/runner.log"; }
[[ "$(runner_try '{"type":"system"}')" == *fresh-ran* ]] || fail 'a Claude resume startup failure did not fall back cold'
[[ "$(runner_try '{"type":"assistant"}')" != *fresh-ran* ]] || fail 'a Claude resume that had started work went cold'
unit_json="{\"sessions\":{\"repair\":{\"id\":\"$claude_sid\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\"}}}"
build_codex_command repair claude-sonnet-5-5 high impl-1 'cold' 'new failure' "$impl_repo" claude || fail 'Claude repair after a provider change was refused'
[[ "$CODEX_MODE" == fresh && "$CODEX_PATH_REASON" == provider-changed ]] || fail 'Claude resumed another provider session'

# Codex repair resumes the recorded thread up to the repair cutoff (20M cumulative raw), goes cold above it.
codex_sid=223e4567-e89b-12d3-a456-426614174000
unit_field() { case "$2" in .sessions.repair*) printf '{"id":"%s","provider":"codex","model":"gpt-6-luna"}' "$codex_sid" ;; *) printf false ;; esac; }
session_file_for_id() { printf '/dev/null'; }
session_usage_for_id() { printf '{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":0,"raw":%s}' "$repair_raw" "$repair_raw"; }
session_tokens_for_id() { printf '%s' "$repair_raw"; }
repair_raw=12000000
build_codex_command repair gpt-6-luna max implement-1 'cold' 'new failure' || fail 'codex repair at 12M raw was refused'
[[ "$CODEX_MODE" == resume && "$CODEX_SESSION_ID" == "$codex_sid" ]] || fail "codex repair at 12M raw went cold ($CODEX_MODE/$CODEX_PATH_REASON)"
repair_raw=21000000
build_codex_command repair gpt-6-luna max implement-1 'cold' 'new failure' || fail 'codex repair at 21M raw was refused'
[[ "$CODEX_MODE" == fresh && "$CODEX_PATH_REASON" == session-too-large ]] || fail "codex repair above the cutoff resumed ($CODEX_MODE/$CODEX_PATH_REASON)"

printf '%s\n' 'PASS scheduler Codex commands disable configured MCP servers and cap tool output (64 KB default, implement 8000 tokens)'
printf '%s\n' 'PASS Sonnet fallback allows focused tests and confines review fixes to the PR branch'
printf '%s\n' 'PASS Claude implement is stream-json, worktree-scoped, branch-only push, resumes its own session'
