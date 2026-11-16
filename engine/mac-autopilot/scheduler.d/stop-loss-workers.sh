# Slow stop-loss routes run after the dispatch step lock is released, so one held issue cannot stop a refill using free slots.
declare -ga TICK_DISPATCH_STOP_LOSS_QUEUE=()

dispatch_stop_loss_worker_active() { # unit-json → 0 while its recorded worker is live or inside the launch grace
  local id="$1" u="${2:-}" since pid start current now fresh_since fresh_pid fresh_start update
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  since="$(jqf -r '.stop_loss_worker_since // empty' <<<"$u")"
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  pid="$(jqf -r '.stop_loss_worker_pid // empty' <<<"$u")"; start="$(jqf -r '.stop_loss_worker_start // empty' <<<"$u")"
  now="$(date +%s)"; (( now >= since )) || now=$since
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    current="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
    if [[ ! "$start" =~ ^[0-9]+$ || ! "$current" =~ ^[0-9]+$ || "$current" == "$start" ]]; then return 0; fi
  elif (( now - since < 30 )); then
    return 0
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[0-9]+$ ]]; then
    update="if .stop_loss_worker_since == $since and .stop_loss_worker_pid == $pid and .stop_loss_worker_start == $start then del(.stop_loss_worker_since, .stop_loss_worker_pid, .stop_loss_worker_start) else . end"
  else
    update="if .stop_loss_worker_since == $since and (.stop_loss_worker_pid // null) == null then del(.stop_loss_worker_since, .stop_loss_worker_pid, .stop_loss_worker_start) else . end"
  fi
  set_unit "$id" "$update" || return 0
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  fresh_since="$(jqf -r '.stop_loss_worker_since // empty' <<<"$u")"
  [[ "$fresh_since" == "$since" ]] || return 1
  fresh_pid="$(jqf -r '.stop_loss_worker_pid // empty' <<<"$u")"; fresh_start="$(jqf -r '.stop_loss_worker_start // empty' <<<"$u")"
  if [[ "$fresh_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$fresh_pid" 2>/dev/null; then
    current="$(coord_process_start_ticks "$fresh_pid" 2>/dev/null || true)"
    [[ ! "$fresh_start" =~ ^[0-9]+$ || ! "$current" =~ ^[0-9]+$ || "$current" == "$fresh_start" ]] && return 0
  fi
  # A concurrent worker may have claimed the marker after the stale snapshot. Leave it for the next pass to recheck.
  [[ "$fresh_pid" =~ ^[1-9][0-9]*$ ]] && return 0
  return 1
}

dispatch_stop_loss_worker_enqueue() { # unit → persist a launch marker and queue it for the post-unlock launcher
  local id="$1" since="$(date +%s)"
  set_unit "$id" ".stop_loss_worker_since=$since | .stop_loss_worker_pid=null | .stop_loss_worker_start=null" || return 1
  TICK_DISPATCH_STOP_LOSS_QUEUE+=("$id:$since")
  say "dispatch detail stop_loss_escalate_queued unit=$id"
}

dispatch_stop_loss_workers_start() { # called by tick_step_lock_run after both step and scheduler locks are free
  local id since queued limit
  ((${#TICK_DISPATCH_STOP_LOSS_QUEUE[@]})) || return 0
  [[ "${SCHED_LOCK_HELD:-false}" != true ]] || { say 'dispatch stop-loss workers: scheduler lock still held'; return 1; }
  limit="${AUTOPI_TICK_STEP_KILL_SECONDS:-900}"; [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=900
  for queued in "${TICK_DISPATCH_STOP_LOSS_QUEUE[@]}"; do
    id="${queued%%:*}"; since="${queued#*:}"
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ && "$since" =~ ^[0-9]+$ ]] || continue
    A="$A" LOG="$LOG" setsid timeout -k 30 "$limit" bash "$HERE/scheduler.sh" --stop-loss-worker "$id" >> "$A/loop.out" 2>&1 < /dev/null &
  done
  TICK_DISPATCH_STOP_LOSS_QUEUE=()
}

dispatch_stop_loss_escalation_run() { # unit stage budget unit-json → perform the existing escalation outside the dispatch pass
  local id="$1" stage="$2" budget="$3" u="$4" issue pr same_check main_red_sha hold_cli finish=false outcome=supervisor rc=0
  local started_us ended_us gh_before gh_after gh_elapsed_us=0 other_us=0 lock_wait_us=0 subprocess_us=0 part_started part_elapsed gh_calls lock_wait_secs subprocess_secs elapsed_secs gh_secs other_secs
  local TICK_STOP_LOSS_WORKER=true TICK_DISPATCH_PENDING_ACTIVE=true DISPATCH_STOP_LOSS_LOCK_WAIT_US=0 TICK_STOP_LOSS_GH_FILE="$A/.stop-loss-gh.$BASHPID"
  : > "$TICK_STOP_LOSS_GH_FILE"
  lock_us_now; started_us=$LOCK_US
  gh_before="$(tick_gh_calls_count 2>/dev/null || echo 0)"
  issue="$(jqf -r '.issue // empty' <<<"$u")"; pr="$(jqf -r '.pr // empty' <<<"$u")"
  if same_check="$(stop_loss_same_failure "$u")"; then
    if main_red_sha="$(stop_loss_main_red_sha "$same_check")"; then
      if stop_loss_same_failure_hold "$id" "$stage" "$same_check" "$main_red_sha"; then outcome=same-failure-hold; finish=true; fi
    elif supervisor_cap_default "$id" "$u" stop-loss "$budget" && [[ "$(unit_field "$id" '.stage // empty')" != "$stage" ]]; then
      stop_loss_same_failure_hold "$id" "$stage" "$same_check" || :
      outcome=cap-default; finish=true
    fi
  fi
  if [[ "$finish" != true ]] && stop_loss_fresh_requeue "$id" "$u" "$budget"; then outcome=fresh-requeue; finish=true; fi
  if [[ "$finish" != true ]]; then
    if [[ "$issue" =~ ^[0-9]+$ && -z "$pr" ]]; then
      supervisor_budget_recut "$id" "ticket stop-loss budget: $budget"
      outcome=budget-recut
    else
      if [[ -n "$issue" ]]; then
        hold_cli="${ZF_ENGINE_DIR:-$ROOT/engine}/hold.sh"; [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
        lock_us_now; part_started=$LOCK_US
        bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss \
          --release 'supervisor rules on the stop-loss escalation; requeue or approve refills the budget' \
          --expires 24h --kind stop-loss >/dev/null 2>&1 || true
        lock_us_now; part_elapsed=$((LOCK_US - part_started)); subprocess_us=$((subprocess_us + part_elapsed))
        gh issue comment "$issue" --body "止损预算（#4363）：这张票自最近一次裁决起已用 ${budget}，自动搁置（on-hold，24h 后未裁决自动恢复），停止下一轮自动派发。单元 $id 已转 supervisor 裁决；supervisor requeue/approve 后预算重新给满。" >/dev/null 2>&1 || true
      fi
      to_supervisor "$id" "stop-loss: $budget since the last supervisor ruling; the issue is held on-hold" \
        'Held at the per-ticket stop-loss budget; supervisor decides rescope, split, or requeue' \
        'the per-ticket round and wall-clock budget was reached' \
        "budget of $TICKET_ROUND_BUDGET rounds (implement+repair) or $((TICKET_WALL_BUDGET_SECONDS / 60)) minutes exceeded: $budget" \
        '["Dispatch another implement/repair round at the same scope"]'
    fi
  fi
  lock_us_now; ended_us=$LOCK_US
  gh_after="$(tick_gh_calls_count 2>/dev/null || echo "$gh_before")"
  (( gh_after >= gh_before )) && gh_calls=$((gh_after - gh_before)) || gh_calls=0
  gh_elapsed_us="$(awk '{ total += $1 } END { printf "%.0f", total }' "$TICK_STOP_LOSS_GH_FILE" 2>/dev/null || echo 0)"; rm -f -- "$TICK_STOP_LOSS_GH_FILE"
  lock_wait_us="$DISPATCH_STOP_LOSS_LOCK_WAIT_US"
  elapsed_secs=$((ended_us - started_us)); other_us=$((elapsed_secs - lock_wait_us - subprocess_us - gh_elapsed_us)); (( other_us >= 0 )) || other_us=0
  elapsed_secs="$(format_duration_us "$elapsed_secs")"; lock_wait_secs="$(format_duration_us "$lock_wait_us")"; subprocess_secs="$(format_duration_us "$subprocess_us")"
  gh_secs="$(format_duration_us "$gh_elapsed_us")"; other_secs="$(format_duration_us "$other_us")"
  say "dispatch detail stop_loss_escalate unit=$id secs=${elapsed_secs}s gh_calls=$gh_calls gh_secs=${gh_secs}s lock_wait=${lock_wait_secs}s subprocess=${subprocess_secs}s other=${other_secs}s outcome=$outcome rc=$rc"
  return "$rc"
}

dispatch_stop_loss_worker_run() { # scheduler child: claim the marker before escalation, then clear only this worker's marker
  local id="$1" u stage budget since pid_start rc=0
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 64
  SCHED_STATION=true; SCHED_LOCK_HELD=false
  tick_gh_calls_begin; tick_roadmap_cache_begin
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  since="$(jqf -r '.stop_loss_worker_since // empty' <<<"$u")"
  if [[ "$since" =~ ^[0-9]+$ ]]; then
    pid_start="$(coord_process_start_ticks "$BASHPID" 2>/dev/null || true)"
    if [[ "$pid_start" =~ ^[0-9]+$ ]] && set_unit "$id" "if .stop_loss_worker_since == $since and .stop_loss_worker_pid == null then .stop_loss_worker_pid=$BASHPID | .stop_loss_worker_start=$pid_start else . end"; then
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
      if [[ "$(jqf -r '.stop_loss_worker_since // empty' <<<"$u")" == "$since" \
        && "$(jqf -r '.stop_loss_worker_pid // empty' <<<"$u")" == "$BASHPID" \
        && "$(jqf -r '.stop_loss_worker_start // empty' <<<"$u")" == "$pid_start" ]]; then
        stage="$(jqf -r '.stage // empty' <<<"$u")"; budget="$(ticket_budget_reason "$u")"
        if [[ -n "$budget" && ( "$stage" == implement-pending || "$stage" == repair-pending || "$(jqf -r '.self_fix_pending // false' <<<"$u")" == true ) ]]; then
          dispatch_stop_loss_escalation_run "$id" "$stage" "$budget" "$u" || rc=$?
        fi
        set_unit "$id" "if .stop_loss_worker_since == $since and .stop_loss_worker_pid == $BASHPID and .stop_loss_worker_start == $pid_start then del(.stop_loss_worker_since, .stop_loss_worker_pid, .stop_loss_worker_start) else . end" || rc=$?
      fi
    fi
  fi
  tick_step_cleanup
  return "$rc"
}
