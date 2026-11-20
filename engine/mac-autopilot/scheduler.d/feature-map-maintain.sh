feature_map_maintenance_target() { # VectA repo root -> project verification skill, or empty
  local root="${1:-${ROOT:-}}" skill
  skill="$root/.agents/skills/verify-vecta/SKILL.md"
  [[ -f "$skill" && -f "$root/.agents/skills/verify-vecta/features/README.md" \
    && -f "$root/.zenoforge/state/feature-map.json" ]] || return 1
  printf '%s\n' "$skill"
}

feature_map_selector_drift() { # VectA repo root -> selector outliers among features sharing a route
  local map="${1:-${ROOT:-}}/.zenoforge/state/feature-map.json"
  [[ -f "$map" ]] || return 0
  jq -r '
    .features | to_entries | sort_by(.value.path // "") | group_by(.value.path // "")[]
    | . as $group
    | ($group | map(.value.selector // "<missing>") | group_by(.)
       | map({selector: .[0], count: length}) | sort_by(-.count, .selector)) as $counts
    | select(($counts | length) > 1)
    | .[] as $entry
    | select(($entry.value.selector // "<missing>") != $counts[0].selector)
    | "feature-map selector drift path=\($entry.value.path // "") feature=\($entry.key) selector=\($entry.value.selector // "<missing>") expected=\($counts[0].selector)"
  ' "$map"
}

feature_map_maintenance_worker_active() {
  local dir="${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}/luna/feature-map-maintain" pid
  [[ -f "$dir/rc" ]] && return 1
  pid="$(cat "$dir/wrapper.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

feature_map_maintenance_schedule() {
  local root="${ROOT:-}" runtime="${A:-}" engine_root="${ENGINE_ROOT:-}" target prompt worker
  local lock_fd now interval=604800 last drift prompt_run line
  [[ -n "$root" && -d "$runtime" && "${1:-full}" == full ]] || return 0
  [[ -z "${PAUSE_FILE:-}" || ! -e "$PAUSE_FILE" ]] || return 0
  target="$(feature_map_maintenance_target "$root")" || return 0
  if [[ -z "$engine_root" ]]; then
    engine_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
  fi
  prompt="$engine_root/engine/mac-autopilot/feature-map-maintain.prompt.md"
  worker="$engine_root/engine/bin/worker"
  [[ -r "$prompt" && -x "$worker" ]] || { say 'feature-map-maintain skipped: engine prompt or worker unavailable'; return 0; }
  now="${NOW_EPOCH:-$(date +%s)}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  last="$(cat "$runtime/.feature-map-maintain.last" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last >= interval )) || return 0
  feature_map_maintenance_worker_active && return 0
  exec {lock_fd}>"$runtime/.feature-map-maintain.lock" || return 0
  flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  last="$(cat "$runtime/.feature-map-maintain.last" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < interval )) || feature_map_maintenance_worker_active; then
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return 0
  fi
  drift="$(feature_map_selector_drift "$root")" || drift='feature-map selector scan failed: unreadable or invalid map'
  if [[ -n "$drift" ]]; then
    while IFS= read -r line; do [[ -z "$line" ]] || say "$line"; done <<< "$drift"
  else
    say 'feature-map selector check: clean'
  fi
  prompt_run="$runtime/feature-map-maintain.prompt.md"
  {
    cat -- "$prompt"
    printf '\n## Selector preflight output\n'
    if [[ -n "$drift" ]]; then printf '%s\n' "$drift"; else printf '%s\n' 'feature-map selector clean: none'; fi
  } > "$prompt_run" || {
    say 'feature-map-maintain skipped: could not write the run prompt'
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return 0
  }
  printf '%s\n' "$now" > "$runtime/.feature-map-maintain.last.tmp" \
    && mv -f -- "$runtime/.feature-map-maintain.last.tmp" "$runtime/.feature-map-maintain.last" || {
      rm -f -- "$runtime/.feature-map-maintain.last.tmp"
      say 'feature-map-maintain skipped: could not record schedule time'
      flock -u "$lock_fd" || :
      exec {lock_fd}>&-
      return 0
    }
  setsid timeout -k 30 3600 env WORKER_STALL_MINUTES=60 \
    bash "$worker" feature-map-maintain "$root" "$prompt_run" >> "$runtime/feature-map-maintain.log" 2>&1 < /dev/null &
  say "feature-map-maintain scheduled interval=${interval}s target=${target#"$root"/} pid=$!"
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
}
