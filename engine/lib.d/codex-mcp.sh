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
