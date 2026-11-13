# ---------- Detached full-tick steps ----------
# Full-tick heavy passes run in separate scheduler processes. Each step has its own
# nonblocking flock, shared with its loop station and refill call sites.
tick_step_lock_run() { # step command...; the caller's dynamic lock marker prevents nested flock opens
  local step="$1" lock_fd rc=0; shift
  case "$step" in dispatch_pending | register_new_issues | release_dependency_blocks | existing_walk) ;; *) return 64 ;; esac
  [[ "${TICK_STEP_LOCK_HELD:-}" != "$step" ]] || { "$@"; return $?; }
  if ! exec {lock_fd}>>"$A/.tick-step-$step.lock"; then say "tick-step lock unavailable step=$step"; return 1; fi
  if ! flock -n "$lock_fd"; then
    TICK_STEP_LOCK_RESULT=skipped
    say "tick-step skipped step=$step reason=lock-held"
    exec {lock_fd}>&-
    return 0
  fi
  TICK_STEP_LOCK_RESULT=acquired
  local TICK_STEP_LOCK_HELD="$step"
  "$@" || rc=$?
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

tick_step_execute() { # step: initialize an independent scheduler context, then run one existing phase
  local step="$1" rc=0 SCHED_STATION=true SCHED_TICK_STEP_ACTIVE=true
  cd "$ROOT" || { say "tick-step failed step=$step: root $ROOT unavailable"; return 1; }
  if [[ -e "$PAUSE_FILE" ]]; then say "tick-step paused step=$step by $PAUSE_FILE"; return 0; fi
  if ! state_schema_ok; then say "state schema invalid; tick-step $step stopped before external actions"; return 2; fi
  tick_gh_calls_begin
  tick_roadmap_cache_begin
  MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)" || MAIN_HEAD=""
  case "$step" in
    release_dependency_blocks) phase release_dependency_blocks || rc=$? ;;
    register_new_issues) tick_step_register_issues || rc=$? ;;
    dispatch_pending)
      if existing_walk_fresh; then intake_census_prime; existing_walked_load; fi
      record_run_spend || :
      phase dispatch_pending || rc=$?
      ;;
  esac
  return "$rc"
}

tick_step_register_issues() {
  run_issue_intake_phases
}

tick_step_cleanup() {
  declare -F release_scheduler_lock >/dev/null && release_scheduler_lock
  declare -F tick_roadmap_cache_end >/dev/null && tick_roadmap_cache_end
  [[ -z "${GH_TICK_CALLS_FILE:-}" ]] || rm -f -- "$GH_TICK_CALLS_FILE" 2>/dev/null || :
  if [[ -n "${TICK_INTAKE_READS_FILE:-}" ]]; then
    rm -f -- "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  fi
  GH_TICK_CALLS_FILE=""; TICK_INTAKE_READS_FILE=""
}

tick_step_run() { # scheduler.sh --tick-step step
  local step="$1" started=$SECONDS rc=0 gh_calls=0 TICK_STEP_LOCK_RESULT=""
  tick_step_lock_run "$step" tick_step_execute "$step" || rc=$?
  [[ "$TICK_STEP_LOCK_RESULT" == acquired ]] || return "$rc"
  if declare -F tick_gh_calls_count >/dev/null; then gh_calls="$(tick_gh_calls_count 2>/dev/null)" || gh_calls=0; fi
  say "tick-phases kind=detached step=$step secs=$((SECONDS - started)) gh_calls=$gh_calls phases=${TICK_PHASE_DETAILS:-none} rc=$rc"
  say "tick-step done step=$step secs=$((SECONDS - started)) gh_calls=$gh_calls rc=$rc ended=$(date -u +%H:%M:%SZ)"
  declare -F tick_step_cleanup >/dev/null && tick_step_cleanup
  return "$rc"
}

start_detached_tick_step() { # step; same detached setsid/timeout pattern as other scheduler stations
  case "${1:-}" in dispatch_pending | register_new_issues | release_dependency_blocks) ;; *) return 64 ;; esac
  if [[ "${AUTOPI_TEST_INLINE_TICK_STEPS:-false}" == true ]]; then
    local TICK_STEP_LOCK_RESULT="" rc=0
    tick_step_lock_run "$1" tick_step_execute "$1" || rc=$?
    return "$rc"
  fi
  local limit="${AUTOPI_TICK_STEP_KILL_SECONDS:-900}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=900
  A="$A" LOG="$LOG" setsid timeout -k 30 "$limit" bash "$HERE/scheduler.sh" --tick-step "$1" >> "$A/loop.out" 2>&1 < /dev/null &
}

