# ---------- Release-dependency station (scheduler.sh --release-deps) ----------
# release_dependency_blocks took 101-129 s of each full tick, and 341 s with 39 gh calls on 2026-11-12 10:45Z, when the tick was killed in it.
# The loop station and the full tick both start this pass detached. One per-step flock serializes them with direct calls; no scheduler lock
# is held across the pass, and each ledger write takes the lock only for that write. The tick continues immediately, and later gate reads
# use the dependency cache the pass left (dep-check.cache.json, paced by DEP_CHECK_SECONDS).
release_deps_station_tick_pass() {
  local old rc=0 gh_calls
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  if ! mkdir "$RELEASE_DEPS_STATION_LOCK" 2>/dev/null; then
    old="$(cat "$RELEASE_DEPS_STATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi # a pass is still running
    rm -rf -- "$RELEASE_DEPS_STATION_LOCK"
    mkdir "$RELEASE_DEPS_STATION_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$RELEASE_DEPS_STATION_LOCK/pid"
  date +%s > "$A/.release-deps-epoch" # also when the pass cannot run: the tick must not start a second pass
  if [[ -e "$PAUSE_FILE" ]]; then
    say "release-deps paused by $PAUSE_FILE: no pass" # the full tick releases no dependencies while paused either
  elif ! state_schema_ok; then
    say "state schema invalid; release-deps stopped before external actions"
  else
    tick_gh_calls_begin
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)" # the stacked-release restack reads it; the tick's fetch refreshes it
    release_dependency_blocks || rc=$?
    gh_calls="$(tick_gh_calls_count)"
    say "release-deps done secs=$SECONDS gh_calls=$gh_calls rc=$rc ended=$(date -u +%H:%M:%SZ)"
    rm -f -- "$GH_TICK_CALLS_FILE" "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  fi
  [[ "$(cat "$RELEASE_DEPS_STATION_LOCK/pid" 2>/dev/null)" != "$$" ]] || rm -rf -- "$RELEASE_DEPS_STATION_LOCK"
}
release_deps_station_tick() {
  local TICK_STEP_LOCK_RESULT=""
  tick_step_lock_run release_dependency_blocks release_deps_station_tick_pass "$@"
}
