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
  trap 'release_scheduler_lock' EXIT
}
release_scheduler_lock() {
  [[ "${SCHED_LOCK_HELD:-false}" == true ]] || return 0
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$BASHPID" ]]; then
    rm -rf -- "$SCHED_LOCK"
  fi
  SCHED_LOCK_HELD=false
}
acquire_scheduler_lock_wait() {
  until acquire_scheduler_lock; do sleep 0.05; done
}
phase_yield_lock() { # slow operation; let the local refill controller take the same ledger lock
  local rc=0
  release_scheduler_lock
  phase "$@" || rc=$?
  acquire_scheduler_lock_wait
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
  local old
  if ! mkdir "$VIEWS_LOCK" 2>/dev/null; then
    old="$(cat "$VIEWS_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi
    rm -rf -- "$VIEWS_LOCK"
    mkdir "$VIEWS_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$VIEWS_LOCK/pid"
  trap 'rm -rf "$VIEWS_LOCK"' EXIT
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
  [[ "$2" =~ ^(requeue|approve|arbiter|recut|reblock)$ && -n "$1" ]] || { echo "usage: scheduler.sh --rule <unit> requeue|approve|arbiter|recut|reblock <ref> [guidance]" >&2; return 64; }
  [[ -n "$(unit_field "$1" .id)" ]] || { echo "rule: no unit $1" >&2; return 1; }
  local issue
  case "$2" in
    reblock) issue="${5:-$(unit_field "$1" '.blocked_on // empty')}" # back to dependency wait; $5 names the blocker when the unit has none
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no blocker; pass --blocked-on N" >&2; return 1; }
      set_unit "$1" "$(hist supervisor-reblock "supervisor ruling: $3") | .stage=\"blocked-external\" | .blocked_on=$issue | .note=$(js "waiting for predecessor #$issue")" ;;
    arbiter) set_unit "$1" "$(hist supervisor-arbiter-round "supervisor ruling: $3") | .stage=\"supervisor-review\"" ;;
    recut) issue="$(unit_field "$1" '.issue // empty')"
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no issue to recut" >&2; return 1; }
      scheduler_route_to_recut "$issue" || return 1
      set_unit "$1" "$(hist supervisor-recut "supervisor ruling: $3") | .stage=\"closed\" | .note=$(js "supervisor ruling sent issue #$issue to recut: $3")" ;;
    *) if [[ "$(unit_field "$1" .stage)" == parked && "$2" == requeue ]]; then
         supervisor_requeue_unit "$1" requeue "supervisor ruling $3: ${4:-see ruling}" null
       else
         set_unit "$1" "$(hist "supervisor-$2" "supervisor ruling via hold.sh --rule: $3")"
       fi ;;
  esac
}
