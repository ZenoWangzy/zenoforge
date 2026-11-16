# Slow stop-loss routes run after the dispatch step lock is released, so one held issue cannot stop a refill using free slots.
declare -ga TICK_DISPATCH_STOP_LOSS_QUEUE=()
declare -gA TICK_DISPATCH_STOP_LOSS_QUEUED_AT=()

dispatch_stop_loss_worker_active() { # unit-json → 0 while its recorded worker is live or inside the launch grace
  local id="$1" u="${2:-}" since pid start current now
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
  set_unit "$id" 'del(.stop_loss_worker_since, .stop_loss_worker_pid, .stop_loss_worker_start)' || return 0
  return 1
}

dispatch_stop_loss_worker_enqueue() { # unit → persist a launch marker and queue it for the post-unlock launcher
  local id="$1" since="$(date +%s)"
  set_unit "$id" ".stop_loss_worker_since=$since | .stop_loss_worker_pid=null | .stop_loss_worker_start=null" || return 1
  TICK_DISPATCH_STOP_LOSS_QUEUE+=("$id"); TICK_DISPATCH_STOP_LOSS_QUEUED_AT["$id"]="$since"
  say "dispatch detail stop_loss_escalate_queued unit=$id"
}

dispatch_stop_loss_workers_start() { # called by tick_step_lock_run after both step and scheduler locks are free
  local id since limit worker_pid worker_start
  ((${#TICK_DISPATCH_STOP_LOSS_QUEUE[@]})) || return 0
  [[ "${SCHED_LOCK_HELD:-false}" != true ]] || { say 'dispatch stop-loss workers: scheduler lock still held'; return 1; }
  limit="${AUTOPI_TICK_STEP_KILL_SECONDS:-900}"; [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=900
  for id in "${TICK_DISPATCH_STOP_LOSS_QUEUE[@]}"; do
    since="${TICK_DISPATCH_STOP_LOSS_QUEUED_AT[$id]:-}"
    [[ "$since" =~ ^[0-9]+$ ]] || continue
    A="$A" LOG="$LOG" setsid timeout -k 30 "$limit" bash "$HERE/scheduler.sh" --stop-loss-worker "$id" >> "$A/loop.out" 2>&1 < /dev/null &
    worker_pid=$!
    worker_start="$(coord_process_start_ticks "$worker_pid" 2>/dev/null || true)"
    if [[ "$worker_pid" =~ ^[1-9][0-9]*$ && "$worker_start" =~ ^[0-9]+$ ]]; then
      set_unit "$id" "if .stop_loss_worker_since == $since and .stop_loss_worker_pid == null then .stop_loss_worker_pid=$worker_pid | .stop_loss_worker_start=$worker_start else . end" || say "dispatch stop-loss worker marker update failed unit=$id"
    fi
  done
  TICK_DISPATCH_STOP_LOSS_QUEUE=(); TICK_DISPATCH_STOP_LOSS_QUEUED_AT=()
}

dispatch_stop_loss_escalation_run() { # unit stage budget unit-json → perform the existing escalation outside the dispatch pass
  local id="$1" stage="$2" budget="$3" u="$4" issue pr same_check main_red_sha hold_cli finish=false outcome=supervisor rc=0
  local started_us ended_us gh_before gh_after lock_wait_us=0 subprocess_us=0 part_started part_elapsed gh_calls lock_wait_secs subprocess_secs elapsed_secs
  local TICK_STOP_LOSS_WORKER=true DISPATCH_STOP_LOSS_LOCK_WAIT_US=0
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
  lock_wait_us="$DISPATCH_STOP_LOSS_LOCK_WAIT_US"
  elapsed_secs=$((ended_us - started_us)); lock_wait_secs=$lock_wait_us; subprocess_secs=$subprocess_us
  printf -v elapsed_secs '%d.%03d' $((elapsed_secs / 1000000)) $((elapsed_secs % 1000000 / 1000))
  printf -v lock_wait_secs '%d.%03d' $((lock_wait_secs / 1000000)) $((lock_wait_secs % 1000000 / 1000))
  printf -v subprocess_secs '%d.%03d' $((subprocess_secs / 1000000)) $((subprocess_secs % 1000000 / 1000))
  say "dispatch detail stop_loss_escalate unit=$id secs=${elapsed_secs}s gh_calls=$gh_calls lock_wait=${lock_wait_secs}s subprocess=${subprocess_secs}s outcome=$outcome rc=$rc"
  return "$rc"
}

dispatch_stop_loss_worker_run() { # scheduler child: re-read budget and unit, then clear only this worker's marker
  local id="$1" u stage budget since pid_start rc=0
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 64
  SCHED_STATION=true; SCHED_LOCK_HELD=false
  tick_gh_calls_begin; tick_roadmap_cache_begin
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  since="$(jqf -r '.stop_loss_worker_since // empty' <<<"$u")"
  if [[ "$since" =~ ^[0-9]+$ ]]; then
    pid_start="$(coord_process_start_ticks "$BASHPID" 2>/dev/null || true)"
    [[ "$pid_start" =~ ^[0-9]+$ ]] && set_unit "$id" "if .stop_loss_worker_since == $since and .stop_loss_worker_pid == null then .stop_loss_worker_pid=$BASHPID | .stop_loss_worker_start=$pid_start else . end" || :
    stage="$(jqf -r '.stage // empty' <<<"$u")"; budget="$(ticket_budget_reason "$u")"
    if [[ -n "$budget" && ( "$stage" == implement-pending || "$stage" == repair-pending || "$(jqf -r '.self_fix_pending // false' <<<"$u")" == true ) ]]; then
      dispatch_stop_loss_escalation_run "$id" "$stage" "$budget" "$u" || rc=$?
    fi
    set_unit "$id" "if .stop_loss_worker_since == $since then del(.stop_loss_worker_since, .stop_loss_worker_pid, .stop_loss_worker_start) else . end" || rc=$?
  fi
  tick_step_cleanup
  return "$rc"
}
