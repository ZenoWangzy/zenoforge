# Every factory codex start passes these: without them each start re-downloads the remote plugin catalog (~51 MB, bypassing
# the 3 h disk cache). Upstream openai/codex#47483 (open); drop this once fixed upstream. Config is not changed (interactive CLI keeps plugins).
CODEX_PLUGINS_OFF_ARGS=(-c features.plugins=false)

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
