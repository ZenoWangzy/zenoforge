# ---------- Release-dependency station (scheduler.sh --dependency-station) ----------
# release_dependency_blocks ran inside the full tick (phase_yield_lock): 101-129 s of a 413-799 s tick (live scheduler.log, 2026-11-12 09:07-09:47Z).
# The station runs it alone, on loop.sh's short cadence, under its own lock. The function already yields the lock: each ledger write takes it
# for that one write (dep_q_flush -> units_update, set_unit), so the tick, the refill and the merge lane run between writes.
# The tick runs it itself only while no pass started within AUTOPI_DEPENDENCY_STATION_FRESH_SECONDS (an older loop.sh without the launcher,
# or a stuck station). While the station is live the tick reads what it left: the dep-check cache file the body gate reads, and it rebuilds
# the in-memory delivered snapshot (dep_delivered_snapshot) that the dispatch gates read.
dependency_station_fresh() { # 0 = a station pass started within the freshness window, so the tick skips release_dependency_blocks
  local at; at="$(cat "$A/.dependency-station-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_DEPENDENCY_STATION_FRESH_SECONDS:-600} ))
}
dependency_release_tick() { # the full tick's release: a live station runs it, so the tick only rebuilds the delivered snapshot the dispatch gates read
  if dependency_station_fresh; then step_timed dep_snapshot dep_delivered_snapshot; else phase_yield_lock release_dependency_blocks; fi
}
dependency_station_tick() {
  local old rc=0 gh_calls GH_ETAG_DIR="$A/.gh-etag-dependency-station"
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  if ! mkdir "$DEPENDENCY_STATION_LOCK" 2>/dev/null; then
    old="$(cat "$DEPENDENCY_STATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi # a pass is still running
    rm -rf -- "$DEPENDENCY_STATION_LOCK"
    mkdir "$DEPENDENCY_STATION_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$DEPENDENCY_STATION_LOCK/pid"
  date +%s > "$A/.dependency-station-epoch" # also when the pass cannot run: the tick must not start a second one
  if [[ -e "$PAUSE_FILE" ]]; then
    say "dependency-station paused by $PAUSE_FILE: no pass" # the tick runs no release while paused either
  elif ! state_schema_ok; then
    say "state schema invalid; dependency-station stopped before external actions"
  else
    tick_gh_calls_begin
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
    LOCK_WAIT_US=0 LOCK_HOLD_US=0
    release_dependency_blocks || rc=$?
    release_scheduler_lock # a write that failed midway must not leave the lock to the next pass
    gh_calls="$(tick_gh_calls_count)"
    say "dependency-station done secs=$SECONDS lock_wait=$(ew_secs "$LOCK_WAIT_US") lock_hold=$(ew_secs "$LOCK_HOLD_US") gh_calls=$gh_calls rc=$rc ended=$(date -u +%H:%M:%SZ)"
    rm -f -- "$GH_TICK_CALLS_FILE" "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  fi
  [[ "$(cat "$DEPENDENCY_STATION_LOCK/pid" 2>/dev/null)" != "$$" ]] || rm -rf -- "$DEPENDENCY_STATION_LOCK"
}
