acquire_scheduler_lock() {
  local old owner="$BASHPID"
  if ! mkdir "$SCHED_LOCK" 2>/dev/null; then
    old="$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 1; fi
    rm -rf -- "$SCHED_LOCK"
    mkdir "$SCHED_LOCK" 2>/dev/null || return 1
  fi
  echo "$owner" > "$SCHED_LOCK/pid"
  SCHED_LOCK_HELD=true
  chain_exit_trap 'release_scheduler_lock'
}
release_scheduler_lock() {
  [[ "${SCHED_LOCK_HELD:-false}" == true ]] || return 0
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$BASHPID" ]]; then
    rm -rf -- "$SCHED_LOCK"
  fi
  SCHED_LOCK_HELD=false
}
# A refill waits for the ledger lock only until its own deadline, like a lock_timeout under a statement deadline: the full tick holds the lock for
# minutes (a refill's ledger write waited 93 to 158s on 2026-11-07), and a wait that outlasts the 300s kill loses the refill's closing lines.
# After the deadline a free lock is still taken; only the wait is refused. A full tick waits as before.
refill_lock_wait_spent() {
  [[ "${TICK_LOCAL_REFILL:-false}" == true ]] && (( SECONDS >= ${AUTOPI_REFILL_LIMIT_SECONDS:-300} - ${AUTOPI_REFILL_LOCK_MARGIN_SECONDS:-15} ))
}
# The first refused wait ENDS the refill: a write that depends on one refused ledger write must not run after it (a worker started whose stage
# write was refused would stay *-pending). The marker is a file because the wait can run in a $(...) subshell; refill_tick clears it at its start.
# One REFILL-TIMEOUT line per refill, so a stop is counted like a kill (bell.sh and engine-canary.sh match the token); "stop" tells it from "refill tick killed".
refill_stopped() {
  [[ "${TICK_LOCAL_REFILL:-false}" == true && -e "$A/.refill-stop" ]]
}
acquire_scheduler_lock_wait() { # $1: optional wait bound in seconds; past it the wait returns 1 and the caller decides
  local t0=$SECONDS
  refill_stopped && return 1
  until acquire_scheduler_lock; do
    if refill_lock_wait_spent; then
      : > "$A/.refill-stop"
      say "REFILL-TIMEOUT stop: ledger lock wait stopped at ${SECONDS}s in phase $(cat "$A/.refill-phase" 2>/dev/null || echo unknown): the refill limit is near, the refill ends here and the next one resumes"
      return 1
    fi
    if [[ -n "${1:-}" ]] && (( SECONDS - t0 >= $1 )); then return 1; fi
    sleep 0.05
  done
}
reacquire_scheduler_lock_timed() { # the seconds waiting here go to tick-phases lock_wait=
  local t0=$SECONDS rc=0
  phase_mark lock_wait # a full tick has no deadline here: a kill in this wait must not be blamed on the phase before it
  acquire_scheduler_lock_wait || rc=1
  TICK_LOCK_WAIT=$((TICK_LOCK_WAIT + SECONDS - t0))
  return "$rc"
}
phase_yield_lock() { # slow operation; let the local refill controller take the same ledger lock
  local rc=0
  release_scheduler_lock
  phase "$@" || rc=$?
  reacquire_scheduler_lock_timed || rc=1
  tick_prs_changed # Refill can change PRs while the scheduler lock is released.
  LIVE_WORKER_CACHE_UNTIL=0
  TICK_ACTIVE_FOOTPRINTS_VALID=false
  TICK_FOOTPRINT_CONFLICT_VALID=false
  return "$rc"
}
phase_yield_lock_batch() { # Callback that records its own phases while sharing one lock-yield window.
  local rc=0
  release_scheduler_lock
  "$@" || rc=$?
  reacquire_scheduler_lock_timed || rc=1
  tick_prs_changed # Refill can change PRs while the scheduler lock is released.
  LIVE_WORKER_CACHE_UNTIL=0
  TICK_ACTIVE_FOOTPRINTS_VALID=false
  TICK_FOOTPRINT_CONFLICT_VALID=false
  return "$rc"
}
run_views() { # full = 体检 + 看板；dashboard = 只渲染看板（暂停时）
  [[ "$1" == full ]] && run_node_health
  SESSION_TZ="$SESSION_TZ" python3 "$HERE/gen_dashboard.py" 2>>"$A/autopilot.err"
}
views_entry() { # scheduler.sh --views <mode>：分离进程入口，自己持有视图锁
  local old waited=0
  # A dashboard-only run (loop.sh cadence) can hold the lock when the tick ends; the full run waits so health scoring is not skipped.
  while [[ "${1:-}" == full ]] && (( waited < ${AUTOPI_VIEWS_WAIT_SECONDS:-300} )) \
    && old="$(cat "$VIEWS_LOCK/pid" 2>/dev/null)" && [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
  done
  if ! mkdir "$VIEWS_LOCK" 2>/dev/null; then
    old="$(cat "$VIEWS_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi
    rm -rf -- "$VIEWS_LOCK"
    mkdir "$VIEWS_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$VIEWS_LOCK/pid"
  chain_exit_trap 'rm -rf "$VIEWS_LOCK"'
  run_views "${1:-dashboard}"
}
launch_views() { # mode；AUTOPI_VIEWS_INLINE=true 时就地跑完（测试与排障）
  if [[ "${AUTOPI_VIEWS_INLINE:-false}" == true ]]; then run_views "$1"; return 0; fi
  setsid timeout -k 30 900 bash "$HERE/scheduler.sh" --views "$1" >> "$A/views.log" 2>&1 < /dev/null &
}

state_schema_ok() {
  jqf -e 'type=="object" and (.units|type)=="array"
    and all(.units[]; type=="object" and (.id|type)=="string" and (.id|length)>0 and (.stage|type)=="string")
    and ([.units[].id]|length)==([.units[].id]|unique|length)' "$UNITS" >/dev/null \
    && jqf -e 'type=="object" and (.workers|type)=="array"
    and all(.workers[]; type=="object" and (.pid|type)=="number" and .pid>0 and (.unit|type)=="string")' "$WORKERS" >/dev/null
}

rule_entry() { # unit-id requeue|approve|arbiter|recut ref [guidance]：记裁决历史（预算自此重算）；parked 单元按动作放回环节
  [[ "$2" =~ ^(requeue|reroute|approve|arbiter|recut|reblock)$ && -n "$1" ]] || { echo "usage: scheduler.sh --rule <unit> requeue|reroute|approve|arbiter|recut|reblock <ref> [guidance]" >&2; return 64; }
  restore_archived_unit "$1" || :
  [[ -n "$(unit_field "$1" .id)" ]] || { echo "rule: no unit $1" >&2; return 1; }
  local issue
  case "$2" in
    reblock) issue="${5:-$(unit_field "$1" '.blocked_on // empty')}" # back to dependency wait; $5 names the blocker when the unit has none
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no blocker; pass --blocked-on N" >&2; return 1; }
      set_unit "$1" "$(hist supervisor-reblock "supervisor ruling: $3") | .stage=\"blocked-external\" | .blocked_on=$issue | del(.dropped_deps[]? | select(. == $issue)) | .note=$(js "waiting for predecessor #$issue")" ;;
    arbiter) set_unit "$1" "$(hist supervisor-arbiter-round "supervisor ruling: $3") | .stage=\"supervisor-review\"" ;;
    recut) issue="$(unit_field "$1" '.issue // empty')"
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no issue to recut" >&2; return 1; }
      scheduler_route_to_recut "$issue" || return 1
      set_unit "$1" "$(hist supervisor-recut "supervisor ruling: $3") | .stage=\"closed\" | .note=$(js "supervisor ruling sent issue #$issue to recut: $3")" ;;
    reroute) [[ "$(unit_field "$1" .stage)" != closed ]] || { echo "rule: $1 is closed" >&2; return 1; }
      supervisor_requeue_unit "$1" reroute "supervisor ruling $3: ${4:-see ruling}" null ;; # releases blocked_on and moves the unit back to its work stage, parked or not
    *) if [[ "$(unit_field "$1" .stage)" == parked && "$2" == requeue ]]; then
         supervisor_requeue_unit "$1" requeue "supervisor ruling $3: ${4:-see ruling}" null
       else
         set_unit "$1" "$(hist "supervisor-$2" "supervisor ruling via hold.sh --rule: $3")"
       fi ;;
  esac
}
