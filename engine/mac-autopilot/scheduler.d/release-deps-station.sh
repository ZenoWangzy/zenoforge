# ---------- Release-dependency station (scheduler.sh --release-deps) ----------
# release_dependency_blocks took 101-129 s of each full tick, and 341 s with 39 gh calls on 2026-11-12 10:45Z, when the tick was killed in it.
# The station runs that pass alone, on loop.sh's cadence, under its own lock. No scheduler lock is held across the pass, as the full tick
# already does (phase_yield_lock releases it for the call): each ledger write takes the lock for that one write. The full tick runs the pass
# only while no station pass started within AUTOPI_RELEASE_DEPS_FRESH_SECONDS (an older loop.sh without the launcher, or a stuck station);
# while the station is live, the tick reads the dependency cache the pass left (dep-check.cache.json, paced by DEP_CHECK_SECONDS).
release_deps_fresh() { # 0 = a station pass started within the freshness window, so the full tick skips the pass
  local at; at="$(cat "$A/.release-deps-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_RELEASE_DEPS_FRESH_SECONDS:-600} ))
}
release_deps_tick_phase() { # the full tick's call: the station owns the pass while it is live
  release_deps_fresh || phase_yield_lock release_dependency_blocks
}
release_deps_station_tick() {
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
