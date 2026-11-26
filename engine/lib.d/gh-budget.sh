gh_budget_paths() {
  [[ -n "${AGENT_HOME:-}" ]] || return 1
  GH_BUDGET_METRICS_DIR="${AGENT_HOME%/}/metrics"
  GH_BUDGET_STATE_DIR="${AGENT_HOME%/}/state"
  GH_BUDGET_LATEST_FILE="$GH_BUDGET_STATE_DIR/gh-budget.latest.json"
  GH_BUDGET_ATTEMPT_FILE="$GH_BUDGET_STATE_DIR/gh-budget.last-attempt"
  GH_BUDGET_LOCK_DIR="$GH_BUDGET_STATE_DIR/gh-budget-sample.lock"
}

gh_budget_latest() {
  gh_budget_paths || return 1
  [[ -r "$GH_BUDGET_LATEST_FILE" ]] || return 1
  cat -- "$GH_BUDGET_LATEST_FILE"
}

gh_budget_recent() {
  local now="$1" file value
  for file in "$GH_BUDGET_ATTEMPT_FILE" "$GH_BUDGET_LATEST_FILE"; do
    [[ -r "$file" ]] || continue
    if [[ "$file" == *.json ]]; then
      value="$(jq -er '.sampled_epoch | select(type == "number")' "$file" 2>/dev/null)" || continue
    else
      IFS= read -r value < "$file" || continue
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    if (( now < value || now - value < 60 )); then return 0; fi
  done
  return 1
}

gh_budget_lock() {
  local now="$1" pid mtime
  if mkdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$BASHPID" > "$GH_BUDGET_LOCK_DIR/pid" || { rmdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null || :; return 1; }
    return 0
  fi
  if [[ -r "$GH_BUDGET_LOCK_DIR/pid" ]]; then
    IFS= read -r pid < "$GH_BUDGET_LOCK_DIR/pid" || pid=""
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$GH_BUDGET_LOCK_DIR/pid"
      rmdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null || :
    fi
  else
    mtime="$(stat -c %Y "$GH_BUDGET_LOCK_DIR" 2>/dev/null || stat -f %m "$GH_BUDGET_LOCK_DIR" 2>/dev/null || true)"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now > mtime && now - mtime >= 60 )); then
      rmdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null || :
    fi
  fi
  if mkdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$BASHPID" > "$GH_BUDGET_LOCK_DIR/pid" || { rmdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null || :; return 1; }
    return 0
  fi
  return 1
}

gh_budget_unlock() {
  rm -f -- "$GH_BUDGET_LOCK_DIR/pid"
  rmdir -- "$GH_BUDGET_LOCK_DIR" 2>/dev/null || :
}

gh_budget_record_rollup() {
  local previous="$1" current="$2" key="$3" name="$4" old_reset new_reset row file latest_file latest updated latest_tmp
  old_reset="$(jq -er ".resources.$key.reset" <<< "$previous" 2>/dev/null)" || return 0
  new_reset="$(jq -er ".resources.$key.reset" <<< "$current" 2>/dev/null)" || return 0
  (( new_reset > old_reset )) || return 0
  row="$(jq -cn --arg resource "$name" --arg sampled_at "$(jq -r '.sampled_at' <<< "$previous")" \
    --argjson reset "$old_reset" --argjson used "$(jq -r ".resources.$key.used" <<< "$previous")" \
    '{resource:$resource,reset:$reset,used:$used,sampled_at:$sampled_at}')" || return 1
  file="$GH_BUDGET_METRICS_DIR/gh-budget-hourly-$(date -u +%Y-%m).jsonl"
  printf '%s\n' "$row" >> "$file" || return 1
  latest_file="$GH_BUDGET_STATE_DIR/gh-budget-hourly.latest.json"
  latest="$(cat -- "$latest_file" 2>/dev/null || printf '{}')"
  updated="$(jq -cn --argjson latest "$latest" --arg resource "$name" --argjson row "$row" '$latest + {($resource):$row}')" || return 1
  latest_tmp="$(mktemp "$GH_BUDGET_STATE_DIR/.gh-budget-hourly.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$updated" > "$latest_tmp" && mv -f -- "$latest_tmp" "$latest_file"; then
    chmod 600 "$latest_file" 2>/dev/null || :
  else
    rm -f -- "$latest_tmp"
    return 1
  fi
}

gh_budget_sample() {
  local now="${1:-}" force="${2:-}" sampled_at month response rc record previous attempt_tmp latest_tmp
  gh_budget_paths || return 0
  [[ "$force" == force || "${ZF_AGENT_TEST_MODE:-0}" != 1 ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)" || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  mkdir -p -- "$GH_BUDGET_METRICS_DIR" "$GH_BUDGET_STATE_DIR" 2>/dev/null || return 0
  chmod 700 "$GH_BUDGET_METRICS_DIR" "$GH_BUDGET_STATE_DIR" 2>/dev/null || :
  gh_budget_recent "$now" && return 0
  gh_budget_lock "$now" || return 0
  if gh_budget_recent "$now"; then gh_budget_unlock; return 0; fi
  attempt_tmp="$(mktemp "$GH_BUDGET_STATE_DIR/.gh-budget-attempt.XXXXXX" 2>/dev/null)" || { gh_budget_unlock; return 0; }
  if ! printf '%s\n' "$now" > "$attempt_tmp" || ! mv -f -- "$attempt_tmp" "$GH_BUDGET_ATTEMPT_FILE"; then
    rm -f -- "$attempt_tmp"
    echo 'gh-budget: could not write sample interval state' >&2
    gh_budget_unlock
    return 0
  fi
  if response="$(command timeout --kill-after=1s 10s gh api rate_limit 2>/dev/null)"; then
    :
  else
    rc=$?
    echo "gh-budget: rate_limit sample failed rc=$rc" >&2
    gh_budget_unlock
    return 0
  fi
  if ! jq -e 'type == "object" and (.resources.graphql.used | type == "number" and floor == . and . >= 0)
    and (.resources.graphql.remaining | type == "number" and floor == . and . >= 0)
    and (.resources.graphql.reset | type == "number" and floor == . and . >= 0)
    and (.resources.core.used | type == "number" and floor == . and . >= 0)
    and (.resources.core.remaining | type == "number" and floor == . and . >= 0)
    and (.resources.core.reset | type == "number" and floor == . and . >= 0)' <<< "$response" >/dev/null 2>&1; then
    echo 'gh-budget: rate_limit sample invalid' >&2
    gh_budget_unlock
    return 0
  fi
  sampled_at="$(date -u +%FT%TZ)" || sampled_at=""
  month="$(date -u +%Y-%m)" || month=""
  [[ "$sampled_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]] || {
    echo 'gh-budget: sample timestamp invalid' >&2
    gh_budget_unlock
    return 0
  }
  record="$(jq -cn --arg sampled_at "$sampled_at" --argjson sampled_epoch "$now" --argjson rate "$response" \
    '{sampled_at:$sampled_at,sampled_epoch:$sampled_epoch,resources:{graphql:{used:$rate.resources.graphql.used,remaining:$rate.resources.graphql.remaining,reset:$rate.resources.graphql.reset},core:{used:$rate.resources.core.used,remaining:$rate.resources.core.remaining,reset:$rate.resources.core.reset}}}')" || {
    gh_budget_unlock
    return 0
  }
  previous="$(cat -- "$GH_BUDGET_LATEST_FILE" 2>/dev/null || true)"
  if ! printf '%s\n' "$record" >> "$GH_BUDGET_METRICS_DIR/gh-budget-$month.jsonl"; then
    echo 'gh-budget: could not append sample row' >&2
    gh_budget_unlock
    return 0
  fi
  chmod 600 "$GH_BUDGET_METRICS_DIR/gh-budget-$month.jsonl" 2>/dev/null || :
  if [[ -n "$previous" ]]; then
    gh_budget_record_rollup "$previous" "$record" graphql graphql || echo 'gh-budget: could not append GraphQL hourly roll-up' >&2
    gh_budget_record_rollup "$previous" "$record" core rest || echo 'gh-budget: could not append REST hourly roll-up' >&2
  fi
  latest_tmp="$(mktemp "$GH_BUDGET_STATE_DIR/.gh-budget-latest.XXXXXX" 2>/dev/null)" || { gh_budget_unlock; return 0; }
  if printf '%s\n' "$record" > "$latest_tmp" && mv -f -- "$latest_tmp" "$GH_BUDGET_LATEST_FILE"; then
    chmod 600 "$GH_BUDGET_LATEST_FILE" 2>/dev/null || :
  else
    rm -f -- "$latest_tmp"
    echo 'gh-budget: could not update latest sample' >&2
  fi
  gh_budget_unlock
  return 0
}

gh_rate_limit_quota() {
  local key quota snapshot sampled_epoch now
  case "$1" in
    graphql) key=graphql ;;
    rest) key=core ;;
    *) return 1 ;;
  esac
  gh_budget_sample '' force || :
  snapshot="$(gh_budget_latest)" || return 1
  sampled_epoch="$(jq -er '.sampled_epoch | select(type == "number" and floor == .)' <<< "$snapshot" 2>/dev/null)" || return 1
  now="$(date +%s)" || return 1
  [[ "$sampled_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  (( now >= sampled_epoch && now - sampled_epoch < 60 )) || return 1
  quota="$(jq -er --arg key "$key" '.resources[$key] | "\(.remaining) \(.reset)" | select(test("^[0-9]+ [0-9]+$"))' <<< "$snapshot" 2>/dev/null)" || return 1
  printf '%s\n' "$quota"
}
