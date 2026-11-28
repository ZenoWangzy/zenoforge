# Every factory codex start passes these: without them each start re-downloads the remote plugin catalog (~51 MB, bypassing
# the 3 h disk cache). Upstream openai/codex#47483 (open); drop this once fixed upstream. Config is not changed (interactive CLI keeps plugins).
CODEX_PLUGINS_OFF_ARGS=(-c features.plugins=false -c features.apps=false)

# Print Codex argv pairs that disable every server configured in this user's Codex home.
# Names are restricted by the table-header pattern, so newline-delimited output is unambiguous.
codex_mcp_disable_args() {
  local config="${CODEX_HOME:-${HOME:-}/.codex}/config.toml" name
  [[ -r "$config" ]] || return 0
  while IFS= read -r name; do
    printf '%s\n%s\n' '-c' "mcp_servers.$name.enabled=false"
  done < <(grep -oE '^\[mcp_servers\.[A-Za-z0-9_-]+\]' "$config" \
    | sed -E 's/^\[mcp_servers\.([^]]+)\]/\1/' | sort -u)
}

# Give one Codex run an empty sentinel directory so host context-mode MCPs cannot mark it ready.
codex_mcp_context_mode_sentinel_dir() {
  local parent="${1:?parent directory required}"
  mkdir -p "$parent" || return 1
  CONTEXT_MODE_MCP_SENTINEL_DIR="$(mktemp -d "$parent/context-mode-mcp-ready.XXXXXX")" || return 1
  export CONTEXT_MODE_MCP_SENTINEL_DIR
}
