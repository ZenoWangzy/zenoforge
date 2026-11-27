dispatch_station_advance_cursor() {
  local id="$1" tmp
  [[ "${DISPATCH_STATION_ACTIVE:-false}" == true && -n "${DISPATCH_STATION_CURSOR_FILE:-}" && -n "$id" ]] || return 0
  tmp="$(mktemp "${DISPATCH_STATION_CURSOR_FILE}.XXXXXX")" || return 1
  if printf '%s\n' "$id" > "$tmp" && mv -f -- "$tmp" "$DISPATCH_STATION_CURSOR_FILE"; then
    DISPATCH_STATION_CURSOR="$id"
  else
    rm -f -- "$tmp"
    return 1
  fi
}
dispatch_station_fresh() {
  local at
  at="$(cat "$A/.dispatch-station-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_DISPATCH_STATION_FRESH_SECONDS:-90} ))
}

dispatch_station_tick() {
  local SCHED_STATION=true old batch limit started=$SECONDS gh_calls rest_used rc=0 DISPATCH_STATION_CANDIDATES=0 DISPATCH_STATION_ACTIVE=true DISPATCH_STATION_CURSOR=""
  local DISPATCH_STATION_LOCK="$A/.dispatch-station.lock" DISPATCH_STATION_CURSOR_FILE="$A/.dispatch-station-cursor" GH_ETAG_DIR="$A/.gh-etag-dispatch"
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  if ! mkdir "$DISPATCH_STATION_LOCK" 2>/dev/null; then
    old="$(cat "$DISPATCH_STATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi
    rm -rf -- "$DISPATCH_STATION_LOCK"
    mkdir "$DISPATCH_STATION_LOCK" 2>/dev/null || return 0
  fi
  echo "$BASHPID" > "$DISPATCH_STATION_LOCK/pid"
  DISPATCH_STATION_CURSOR="$(cat "$DISPATCH_STATION_CURSOR_FILE" 2>/dev/null || :)"
  if [[ -e "$PAUSE_FILE" ]]; then
    say "dispatch station paused by $PAUSE_FILE: no dispatch"
  elif ! state_schema_ok; then
    say 'state schema invalid; dispatch station stopped before external actions'
  else
    batch="${AUTOPI_DISPATCH_STATION_BATCH_SIZE:-8}"
    [[ "$batch" =~ ^[1-9][0-9]*$ ]] || batch=8
    limit="${AUTOPI_DISPATCH_STATION_LIMIT_SECONDS:-240}"
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=240
    local AUTOPI_TICK_DISPATCH_SECONDS="$limit" TICK_LOCAL_REFILL=false DISPATCH_RESET_SKIPS_ON_LOCK=true
    tick_gh_calls_begin
    tick_roadmap_cache_begin
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)" || MAIN_HEAD=""
    mark_supervisor_owned_units || rc=$?
    release_session_pr_units || rc=$?
    if (( rc == 0 )) && supervisor_marking_deferred; then
      say 'dispatch station held: supervisor-owned marking deferred'
    elif (( rc == 0 )); then
      if existing_walk_fresh; then intake_census_prime; existing_walked_load; fi
      record_run_spend || :
      AUTOPI_TICK_DISPATCH_SECONDS=$((limit - (SECONDS - started)))
      if (( AUTOPI_TICK_DISPATCH_SECONDS > 0 )); then
        phase dispatch_pending false "$batch" || rc=$?
      else
        say "dispatch station deadline before dispatch elapsed=$((SECONDS - started))s limit=${limit}s"
      fi
    fi
    gh_calls="$(tick_gh_calls_summary)"
    rest_used="$(tick_rest_usage_summary)"
    say "dispatch-station done secs=$((SECONDS - started)) $gh_calls buffer=units.json batch_size=$batch candidates=$DISPATCH_STATION_CANDIDATES limit=${limit}s rc=$rc ended=$(date -u +%H:%M:%SZ) $rest_used"
    tick_step_cleanup
  fi
  [[ "$(cat "$DISPATCH_STATION_LOCK/pid" 2>/dev/null)" != "$BASHPID" ]] || rm -rf -- "$DISPATCH_STATION_LOCK"
  return "$rc"
}
