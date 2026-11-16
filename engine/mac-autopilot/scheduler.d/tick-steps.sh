# ---------- Detached full-tick steps ----------
# Full-tick heavy passes run in separate scheduler processes. Each step has its own
# nonblocking flock, shared with its loop station and refill call sites.
tick_step_dispatch_pending_skip_count() { # consecutive dispatch_pending lock-held skips, defaulting to zero
  local file="$A/.tick-step-dispatch_pending-skips" count
  if [[ -r "$file" ]] && IFS= read -r count < "$file" && [[ "$count" =~ ^[0-9]+$ ]]; then
    count="${count#"${count%%[!0]*}"}"
    [[ -n "$count" ]] || count=0
  else
    count=0
  fi
  printf '%s\n' "$count"
}

tick_step_dispatch_pending_skips_update() { # increment on contention; reset when the detached dispatch phase starts
  local action="$1" file="$A/.tick-step-dispatch_pending-skips" lock_fd="" count tmp rc=0
  if ! exec {lock_fd}>>"$file.lock" || ! flock -x "$lock_fd"; then
    [[ -z "$lock_fd" ]] || exec {lock_fd}>&-
    return 1
  fi
  case "$action" in
    increment)
      count="$(tick_step_dispatch_pending_skip_count)"
      if ((${#count} > 10)) || { ((${#count} == 10)) && [[ "$count" > "2147483646" ]]; }; then
        count=2147483647
      else
        count=$((10#$count + 1))
      fi
      ;;
    reset) count=0 ;;
    *) rc=64 ;;
  esac
  if (( rc == 0 )); then
    tmp="$(mktemp "$file.XXXXXX")" || rc=1
    if (( rc == 0 )); then
      if ! printf '%s\n' "$count" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        rc=1
      fi
    fi
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

tick_step_dispatch_pending_skip_count_at_least() { # threshold; compare decimal strings without arithmetic overflow
  local count threshold="${1:-2}"
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
  threshold="${threshold#"${threshold%%[!0]*}"}"
  [[ -n "$threshold" ]] || threshold=0
  count="$(tick_step_dispatch_pending_skip_count)"
  if ((${#count} > ${#threshold})); then return 0; fi
  if ((${#count} < ${#threshold})); then return 1; fi
  [[ "$count" == "$threshold" || "$count" > "$threshold" ]]
}

dispatch_step_busy_summary() { # log byte offset/length → latest observed dispatch step-lock age suffix
  local offset="$1" bytes="$2"
  [[ "$offset" =~ ^[0-9]+$ && "$bytes" =~ ^[1-9][0-9]*$ && -f "$LOG" ]] || return 0
  tail -c +$((offset + 1)) "$LOG" 2>/dev/null | head -c "$bytes" | awk '
    /tick-step skipped step=dispatch_pending reason=lock-held age=/ {
      seen=1
      for (i=1; i<=NF; i++) if ($i ~ /^age=[0-9]+s$/) {
        split($i, part, "="); sub(/s$/, "", part[2]); age_seen=1; if (part[2]+0 > age) age=part[2]+0
      }
    }
    END { if (seen) { if (age_seen) printf ",dispatch-step-busy:%ds", age; else printf ",dispatch-step-busy:unknown" } }
  '
}

tick_step_lock_run() { # step command...; the caller's dynamic lock marker prevents nested flock opens
  local step="$1" lock_fd rc=0 step_lock_started step_lock_age TICK_STEP_LOCK_FD=""; shift
  case "$step" in dispatch_pending | register_new_issues | release_dependency_blocks | existing_walk) ;; *) return 64 ;; esac
  [[ "${TICK_STEP_LOCK_HELD:-}" != "$step" ]] || { "$@"; return $?; }
  if ! exec {lock_fd}>>"$A/.tick-step-$step.lock"; then say "tick-step lock unavailable step=$step"; return 1; fi
  if ! flock -n "$lock_fd"; then
    TICK_STEP_LOCK_RESULT=skipped
    step_lock_started="$(cat "$A/.tick-step-$step.started" 2>/dev/null || true)"; step_lock_age=unknown
    if [[ "$step_lock_started" =~ ^[0-9]+$ ]]; then step_lock_age=$(($(date +%s) - step_lock_started)); (( step_lock_age >= 0 )) || step_lock_age=0; fi
    say "tick-step skipped step=$step reason=lock-held age=${step_lock_age}s"
    if [[ "$step" == dispatch_pending ]] && ! tick_step_dispatch_pending_skips_update increment; then
      say 'tick-step skip counter update failed step=dispatch_pending'
    fi
    exec {lock_fd}>&-
    return 0
  fi
  TICK_STEP_LOCK_RESULT=acquired
  TICK_STEP_LOCK_FD="$lock_fd"
  local TICK_STEP_LOCK_HELD="$step"
  printf '%s\n' "$(date +%s)" > "$A/.tick-step-$step.started" 2>/dev/null || :
  "$@" || rc=$?
  rm -f -- "$A/.tick-step-$step.started"
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  TICK_STEP_LOCK_FD=""
  if [[ "$step" == dispatch_pending ]] && declare -F dispatch_stop_loss_workers_start >/dev/null 2>&1; then
    dispatch_stop_loss_workers_start || say 'dispatch stop-loss workers: launch failed'
  fi
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
      if ! tick_step_dispatch_pending_skips_update reset; then say 'tick-step skip counter reset failed step=dispatch_pending'; fi
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
  local step="$1" started=$SECONDS rc=0 gh_calls="gh_calls=0 gql=0 rest=0" TICK_STEP_LOCK_RESULT=""
  tick_step_lock_run "$step" tick_step_execute "$step" || rc=$?
  [[ "$TICK_STEP_LOCK_RESULT" == acquired ]] || return "$rc"
  if declare -F tick_gh_calls_summary >/dev/null; then gh_calls="$(tick_gh_calls_summary 2>/dev/null)" || gh_calls='gh_calls=0 gql=0 rest=0'; fi
  say "tick-phases kind=detached step=$step secs=$((SECONDS - started)) $gh_calls phases=${TICK_PHASE_DETAILS:-none} rc=$rc"
  say "tick-step done step=$step secs=$((SECONDS - started)) $gh_calls rc=$rc ended=$(date -u +%H:%M:%SZ)"
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

