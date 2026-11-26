gh_tick_cache_get() {
  local key="$1" fetch="$2" cache lock_fd="" output="" tmp="" rc=0
  shift 2
  [[ -n "${GH_TICK_CACHE_DIR:-}" ]] || { "$fetch" "$@"; return $?; }
  cache="$GH_TICK_CACHE_DIR/$key"
  mkdir -p -- "$GH_TICK_CACHE_DIR" 2>/dev/null || { "$fetch" "$@"; return $?; }
  exec {lock_fd}>>"$cache.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  if [[ -f "$cache" ]]; then
    cat "$cache" || rc=$?
  else
    output="$("$fetch" "$@")" || rc=$?
    if (( rc == 0 )); then
      tmp="$(mktemp "$cache.XXXXXX")" || tmp=""
      if [[ -n "$tmp" ]]; then
        if printf '%s' "$output" >"$tmp" && mv -f -- "$tmp" "$cache"; then :; else rm -f -- "$tmp"; fi
      fi
      printf '%s' "$output"
    fi
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

gh_tick_cache_begin() {
  [[ -n "${GH_TICK_CACHE_DIR:-}" ]] && return 0
  mkdir -p -- "$AGENT_HOME/state" || return 1
  GH_TICK_CACHE_DIR="$(mktemp -d "$AGENT_HOME/state/gh-tick.XXXXXX")" || return 1
  GH_TICK_CACHE_OWNED=true
  export GH_TICK_CACHE_DIR
}

gh_tick_cache_end() {
  [[ "${GH_TICK_CACHE_OWNED:-}" == true ]] || return 0
  rm -rf -- "$GH_TICK_CACHE_DIR"
  unset GH_TICK_CACHE_DIR GH_TICK_CACHE_OWNED
}

gh_graphql_cached_with() {
  local fetch="$1" key
  shift
  key="$(printf '%s\0' "$@" | sha256sum)" || return 1
  key="${key%% *}"
  [[ "$key" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  gh_tick_cache_get "graphql-$key.json" "$fetch" "$@"
}

gh_graphql_cached() {
  gh_graphql_cached_with gh "$@"
}
