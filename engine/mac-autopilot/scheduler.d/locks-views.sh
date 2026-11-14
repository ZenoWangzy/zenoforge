lock_us_now() { LOCK_US="${EPOCHREALTIME:-0}"; LOCK_US="${LOCK_US//[.,]/}"; } # microseconds since the epoch; 0 where bash has no EPOCHREALTIME
scheduler_lock_pid_reused() { # $1: live pid in the lock -> 0 when the owner's start ticks name another process (PID reuse)
  local want now
  want="$(cat "$SCHED_LOCK/start" 2>/dev/null || true)"
  [[ "$want" =~ ^[0-9]+$ ]] || return 1 # no start recorded (older lock): the pid test alone decides
  now="$(coord_process_start_ticks "$1" 2>/dev/null)" || return 1 # unreadable: keep the pid test
  [[ "$now" != "$want" ]]
}
# TERM from loop.sh's `timeout --foreground` (or a kill): stop this holder's own children, bounded, before the EXIT trap frees the lock.
# A foreground ledger write finishes first (bash runs a trap only after its foreground command), so a stale write cannot land after the release.
# Children in another session (setsid workers, stations) are never touched.
scheduler_proc_field() { # $1 pid, $2 field of /proc/<pid>/stat after the comm (1 state, 2 ppid, 3 pgrp, 4 session); empty when unreadable
  local st f=()
  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
  read -ra f <<<"${st##*) }"; printf '%s' "${f[$(( $2 - 1 ))]:-}"
}
scheduler_term_stop() {
  local me=$BASHPID c s kids=() alive=() i me_sid wait_s="${AUTOPI_TERM_CHILD_WAIT_SECONDS:-10}" # BASHPID changes inside $(...)
  me_sid="$(scheduler_proc_field "$me" 4)"
  for c in $(pgrep -P "$me" 2>/dev/null); do
    [[ -n "$me_sid" && "$(scheduler_proc_field "$c" 4)" == "$me_sid" ]] && kids+=("$c") # same session only: setsid workers stay
  done
  (( ${#kids[@]} )) && kill -TERM "${kids[@]}" 2>/dev/null
  for (( i = 0; i < wait_s * 10; i++ )); do
    alive=()
    for c in "${kids[@]}"; do # a zombie has exited: it no longer writes
      s="$(scheduler_proc_field "$c" 1)"; [[ "$s" != Z && "$s" != X ]] && kill -0 "$c" 2>/dev/null && alive+=("$c")
    done
    (( ${#alive[@]} )) || break
    sleep 0.1
  done
  (( ${#alive[@]} )) && kill -KILL "${alive[@]}" 2>/dev/null
  exit 143 # the EXIT trap (release_scheduler_lock) runs after the children are gone
}
acquire_scheduler_lock() {
  local old start age owner="$BASHPID"
  if ! mkdir "$SCHED_LOCK" 2>/dev/null; then
    old="$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then
      scheduler_lock_pid_reused "$old" || return 1
      say "scheduler lock: reclaimed from pid $old, its start time does not match the lock (pid reused)"
    elif [[ -z "$old" ]]; then
      # a holder that just made the dir has not written its pid yet: only a dir older than the grace is abandoned
      age=$(( $(date +%s) - $(stat -c %Y "$SCHED_LOCK" 2>/dev/null || date +%s) ))
      (( age < ${SCHED_LOCK_EMPTY_PID_GRACE:-30} )) && return 1
      say "scheduler lock: reclaimed an abandoned lock with no pid (age ${age}s)"
    fi
    rm -rf -- "$SCHED_LOCK"
    mkdir "$SCHED_LOCK" 2>/dev/null || return 1
  fi
  echo "$owner" > "$SCHED_LOCK/pid" 2>/dev/null || return 1
  # a rival that wrote its own pid after ours won the lock: this holder must not run
  [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$owner" ]] || return 1
  if start="$(coord_process_start_ticks "$owner" 2>/dev/null)"; then printf '%s\n' "$start" > "$SCHED_LOCK/start"; fi
  SCHED_LOCK_HELD=true
  trap scheduler_term_stop TERM # stops this holder's children before the EXIT trap releases the lock
  lock_us_now; SCHED_LOCK_AT_US=$LOCK_US # the existing-walk station sums holds and waits per pass
  chain_exit_trap 'release_scheduler_lock'
}
release_scheduler_lock() {
  [[ "${SCHED_LOCK_HELD:-false}" == true ]] || return 0
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$BASHPID" ]]; then
    rm -rf -- "$SCHED_LOCK"
  fi
  lock_us_now; LOCK_HOLD_US=$((${LOCK_HOLD_US:-0} + LOCK_US - ${SCHED_LOCK_AT_US:-$LOCK_US}))
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
ledger_lock_holder_phase() { # the phase the lock holder is in, read from .tick-phase; set_unit reads it before its wait, REFILL-TIMEOUT after it
  local p; p="$(cat "$A/.tick-phase" 2>/dev/null || true)"; printf '%s' "${p:-unknown}"
}
acquire_scheduler_lock_wait() { # $1: optional wait bound in seconds; past it the wait returns 1 and the caller decides
  local t0=$SECONDS
  refill_stopped && return 1
  lock_us_now; local w0=$LOCK_US
  until acquire_scheduler_lock; do
    lock_us_now; LOCK_WAIT_US=$((${LOCK_WAIT_US:-0} + LOCK_US - w0)); w0=$LOCK_US # waited so far, to the last refused try
    if refill_lock_wait_spent; then
      : > "$A/.refill-stop"
      local holder holder_phase
      holder="$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)"; holder="${holder:-none}"
      holder_phase="$(ledger_lock_holder_phase)"
      say "REFILL-TIMEOUT stop: ledger lock wait stopped at ${SECONDS}s in phase $(cat "$A/.refill-phase" 2>/dev/null || echo unknown): holder=$holder holder_phase=$holder_phase: the refill limit is near, the refill ends here and the next one resumes"
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
  chain_exit_trap 'if [[ "$(cat "$VIEWS_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then rm -rf -- "$VIEWS_LOCK"; fi'
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

rule_supersede_handoff() { # unit ruling-comment-url：清掉已被当前 PR head 取代的快照，不碰远端救援引用
  local id="$1" ruling="$2" comment_id pr head
  [[ "$ruling" =~ issuecomment-([1-9][0-9]*)$ ]] || { echo "rule: supersede-handoff requires an issuecomment URL" >&2; return 64; }
  comment_id="${BASH_REMATCH[1]}"
  pr="$(unit_field "$id" '.pr // empty')"
  if [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
    [[ "$id" =~ ^pr-([1-9][0-9]*)$ ]] || { echo "rule: $id has no PR head to supersede the handoff snapshot" >&2; return 1; }
    pr="${BASH_REMATCH[1]}"
  fi
  head="$(tick_pr_head "$pr")" || { echo "rule: could not read the current head of PR #$pr" >&2; return 1; }
  [[ "$head" =~ $SHA_RE ]] || { echo "rule: PR #$pr has no valid current head" >&2; return 1; }
  set_unit "$id" "$(hist handoff-superseded "ruling comment $comment_id superseded the handoff snapshot with PR #$pr head $head") | .history[-1].ruling_comment_id=$(js "$comment_id") | .history[-1].pr_head=$(js "$head") | .history[-1].superseded_by=$(js "$head") | del(.handoff_worktree, .handoff_worktree_sha, .handoff_worktree_dirty, .handoff_worktree_applied, .handoff_integration_sha, .handoff_original_pr_head, .handoff_delivery_verified_sha, .handoff_start_ref, .handoff_start_sha, .handoff_start_applied)"
}

closed_unit_stop_loss_open() { # id：0 = 已关闭单元的 issue 仍开着且挂着 scheduler-stop-loss hold；1 = 不符合；2 = 读不到 GitHub 状态（GraphQL 读在 secondary rate limit 下返回空，故走 REST）
  local issue state repo rest_state
  issue="$(unit_field "$1" '.issue // empty')"; [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  state="$(scheduler_issue_state "$issue")" || return 1
  jqf -e '.state == "on-hold" and .hold.holder == "scheduler-stop-loss"' <<<"$state" >/dev/null || return 1
  repo="${REPO:-${ZF_REPO:-}}"; [[ -n "$repo" ]] || return 1
  rest_state="$(gh api "repos/$repo/issues/$issue" --jq .state 2>/dev/null)" || return 2
  case "$rest_state" in open) return 0 ;; closed) return 1 ;; *) return 2 ;; esac
}
closed_unit_recut_open() { # id：0 = recut 或 arbitration cap（supervisor-close）关掉的单元，issue 仍开着、ready-for-agent、无 hold、无 recut 子单；1 = 不符合；2 = 读不到状态（只有 issue 开着才有路：#3405/#1135/#6206）
  local issue state repo rest_state last
  issue="$(unit_field "$1" '.issue // empty')"; [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  state="$(scheduler_issue_state "$issue")" || return 2
  jqf -e '.state == "ready-for-agent" and .hold == null and (has("recut_children") | not)' <<<"$state" >/dev/null || return 1
  # a delivered unit (merged/landed/done anywhere in its history) stays closed; the close must come from a recut event
  last="$(unit_field "$1" '(.history // []) as $h | if any($h[]; .stage | IN("merged", "landed", "done")) then empty else ($h | map(.stage | select(. != "supervisor-cap-default")) | last // empty) end')"
  case "$last" in
    supervisor-cap-triage-recut|supervisor-budget-recut|supervisor-recut|supervisor-close) ;; # supervisor-close: the cap closed it, a ruling released its hold and the reopen must still work
    hold-handoff|supervisor-requeue) jqf -e '(.recut_refused_at // "") != ""' <<<"$state" >/dev/null || return 1 ;; # a refused recut with no children, then only a handoff or requeue
    *) return 1 ;;
  esac
  repo="${REPO:-${ZF_REPO:-}}"; [[ -n "$repo" ]] || return 2
  rest_state="$(gh api "repos/$repo/issues/$issue" --jq .state 2>/dev/null)" || return 2
  case "$rest_state" in open) return 0 ;; closed) return 1 ;; *) return 2 ;; esac
}
closed_unit_route() { # id：0 = stop-loss hold 路，3 = recut 路（都用 --requeue 重开）；1 = 无路；2 = 读不到 GitHub 状态
  local rc=0
  closed_unit_stop_loss_open "$1" || rc=$?
  [[ "$rc" == 1 ]] || return "$rc"
  rc=0; closed_unit_recut_open "$1" || rc=$?
  [[ "$rc" == 0 ]] && return 3
  return "$rc"
}
closed_unit_refusal() { # id [rc]：已关闭单元的拒绝语只指向本环节能用的动作；调用方给了 rc 就不再查 GitHub
  local rc="${2:-}"
  [[ -n "$rc" ]] || { rc=0; closed_unit_route "$1" || rc=$?; }
  case "$rc" in
    0) echo "rule: $1 is closed but its issue is on a stop-loss hold; use --requeue" >&2 ;;
    3) echo "rule: $1 was closed by a recut and its issue is open and ready-for-agent; use --requeue" >&2 ;;
    2) echo "rule: $1 is closed and its GitHub issue state could not be read; retry the ruling" >&2 ;;
    *) echo "rule: $1 is closed; use --recut to route its issue to recut" >&2 ;;
  esac
}

rule_entry() { # unit-id requeue|approve|arbiter|recut|supersede-handoff|ready ref [guidance] [blocker] [size-waiver max_lines] [comment author]：记裁决历史（预算自此重算）；parked 单元按动作放回环节
  [[ "$2" =~ ^(requeue|reroute|approve|arbiter|recut|reblock|supersede-handoff|ready)$ && -n "$1" ]] || { echo "usage: scheduler.sh --rule <unit> requeue|reroute|approve|arbiter|recut|reblock|supersede-handoff|ready <ref> [guidance]" >&2; return 64; }
  restore_archived_unit "$1" || :
  [[ -n "$(unit_field "$1" .id)" ]] || { echo "rule: no unit $1" >&2; return 1; }
  local issue stage rc waiver="${6:-}" author="${7:-}" reason patch=""
  if [[ -n "$waiver" ]]; then # size waiver ($6 max_lines, $7 comment author): rides the requeue's single unit write, one size-waiver event before supervisor-requeue
    [[ "$2" == requeue ]] || { echo "rule: --size-waiver goes with --requeue" >&2; return 64; }
    size_waiver_range_check "$waiver" || return 1
    [[ -n "$author" ]] || { echo "rule: --size-waiver needs the ruling comment author" >&2; return 1; }
    reason="$(head -n1 <<<"${4:-}")"; reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"; reason="${reason:0:200}"
    patch="$(hist size-waiver "size limit raised to $waiver lines by $author: ${reason:-see ruling}") | .size_waiver = {max_lines: $waiver, by: $(js "$author"), at: $(js "$STAMP"), reason: $(js "${reason:-see ruling}")}"
  fi
  case "$2" in
    supersede-handoff) rule_supersede_handoff "$1" "$3" ;;
    reblock) issue="${5:-$(unit_field "$1" '.blocked_on // empty')}" # back to dependency wait; $5 names the blocker when the unit has none
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no blocker; pass --blocked-on N" >&2; return 1; }
      set_unit "$1" "$(hist_blocked supervisor-reblock "$issue" supervisor-ruling "supervisor ruling: $3") | .stage=\"blocked-external\" | .blocked_on=$issue | del(.dropped_deps[]? | select(. == $issue)) | .note=$(js "waiting for predecessor #$issue")" ;;
    arbiter) set_unit "$1" "$(hist supervisor-arbiter-round "supervisor ruling: $3") | .stage=\"supervisor-review\"" ;;
    recut) issue="$(unit_field "$1" '.issue // empty')"
      [[ "$issue" =~ ^[0-9]+$ ]] || { echo "rule: $1 has no issue to recut" >&2; return 1; }
      scheduler_route_to_recut "$issue" || return 1
      set_unit "$1" "$(hist supervisor-recut "supervisor ruling: $3") | .stage=\"closed\" | .note=$(js "supervisor ruling sent issue #$issue to recut: $3")" ;;
    reroute) [[ "$(unit_field "$1" .stage)" != closed ]] || { closed_unit_refusal "$1"; return 1; }
      supervisor_requeue_unit "$1" reroute "supervisor ruling $3: ${4:-see ruling}" null ;; # releases blocked_on and moves the unit back to its work stage, parked or not
    *) if [[ "$2" == requeue ]]; then
         stage="$(unit_field "$1" .stage)"
         case "$stage" in
           parked|supervisor-review) SUPERVISOR_REQUEUE_PATCH="$patch" supervisor_requeue_unit "$1" requeue "supervisor ruling $3: ${4:-see ruling}" null ;;
           closed) rc=0; closed_unit_route "$1" || rc=$?
             if [[ "$rc" == 0 || "$rc" == 3 ]]; then SUPERVISOR_REQUEUE_PATCH="$patch" supervisor_requeue_unit "$1" requeue "supervisor ruling $3: ${4:-see ruling}" null; else closed_unit_refusal "$1" "$rc"; return 1; fi ;; # the stop-loss ruling reopens the issue and releases its hold, the recut route (rc 3) requeues a recut-closed unit; rc 2 never requeues
           *) echo "rule: $1 is in $stage; use --reroute to move it" >&2; return 1 ;;
         esac
       else
         set_unit "$1" "$(hist "supervisor-$2" "supervisor ruling via hold.sh --rule: $3")"
       fi ;;
  esac
}
