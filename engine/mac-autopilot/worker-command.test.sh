#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
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

printf '%s\n' 'PASS scheduler Codex commands disable configured MCP servers and limit implement tool output'
