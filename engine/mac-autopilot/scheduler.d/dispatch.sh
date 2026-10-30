
dispatch() { # type model effort unit log report prompt [sha] [workdir] [pr-head] [new-failure]
  local type="${1:-}" model="${2:-}" effort="${3:-}" unit="${4:-}" log="${5:-}" report="${6:-}" prompt="${7:-}" sha="${8:-}" workdir="${9:-$ROOT}" pr_head="${10:-}" pid cache_fresh=false cache_until="$LIVE_WORKER_CACHE_UNTIL" started=$SECONDS elapsed issue claim_key claim_owner claim_status pr_census
  local -a launcher=() worker_env=()
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) && cache_fresh=true
  if [[ "$(unit_field "$unit" '.lane // empty')" == direct-main ]]; then
    worker_env=(env ZF_NON_PRODUCT_UNIT=1 "ZF_PIPELINE_UNIT=$unit" \
      "PATH=${ZF_ENGINE_DIR:-$ROOT/engine}/non-product-test-shim:$PATH")
  fi
  # setsid：worker 自成进程组，超时可整组终止（含 codex 子进程）。
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  build_codex_command "$type" "$model" "$effort" "$unit" "$prompt" "${11-$prompt}" || return 1
  issue="$(unit_field "$unit" '.issue // empty')"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    claim_key="$(coord_issue_key "$issue")"
  else
    claim_key="$(coord_unit_key "$unit")" || { say "dispatch held unit=$unit reason=invalid-claim-key"; return 1; }
  fi
  if [[ "$type" == implement && "$issue" =~ ^[1-9][0-9]*$ \
      && "$(unit_field "$unit" '.lane // empty')" == direct-main \
      && "${TICK_DISPATCH_LOCAL_REFILL:-false}" != true ]]; then
    pr_census="$(tick_prs)" || { say "dispatch held unit=$unit reason=open-PR-census-unknown"; return 1; }
    if jqf -e --arg issue "$issue" \
        'any(.[]; (((.title // "") + " " + (.body // "") + " " + (.headRefName // "")) | test("(^|[^0-9])#" + $issue + "([^0-9]|$)")))' \
        <<<"$pr_census" >/dev/null; then
      say "dispatch held unit=$unit reason=open-PR-for-issue"
      return 1
    fi
  fi
  if coord_scheduler_live_worker "$unit" "$issue"; then
    say "dispatch held unit=$unit reason=live-worker"
    return 1
  fi
  claim_owner="$(coord_new_owner)"
  if coord_acquire "$claim_key" "$claim_owner" scheduler-worker "$issue" "$unit" "$type"; then
    :
  else
    claim_status=$?
    say "dispatch held unit=$unit reason=$(if (( claim_status == 1 )); then echo claim-owned; else echo claim-unknown; fi)"
    return 1
  fi
  if ! coord_assert_owned "$claim_key" "$claim_owner" >/dev/null; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    say "dispatch held unit=$unit reason=claim-lost-before-launch"
    return 1
  fi
  if [[ "${WORKER_STDOUT_REPORT:-0}" == 1 ]]; then
    # stdout 即报告：只有成功退出且非空才落盘，失败/中断不会留下可被回收的半截报告。
    (cd "$workdir" && GIT_PAGER=cat PAGER=cat exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} bash -c 'out="$1"; shift; "$@" > "$out.partial" && [ -s "$out.partial" ] && mv -f "$out.partial" "$out"' \
      autopilot-worker "$SUP/$report" "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  elif [[ "$type" == repair && "$CODEX_MODE" == resume ]]; then
    (cd "$workdir" && exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} bash "$CODEX_REPAIR_RUNNER" "$SUP/$log" "$CODEX_SESSION_ID" \
      "${#CODEX_FRESH_COMMAND[@]}" "${CODEX_FRESH_COMMAND[@]}" "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  else
    (cd "$workdir" && jq -cn --arg mode "$CODEX_MODE" --arg reason "$CODEX_PATH_REASON" \
      '{type:"pipeline.execution",mode:$mode,reason:$reason}' && exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  fi
  pid=$!
  local pid_started
  pid_started="$(coord_process_start_ticks "$pid" 2>/dev/null)" || {
    stuck_worker_stop "$pid" || :
    if ! kill -0 "$pid" 2>/dev/null; then coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; fi
    say "dispatch stopped unit=$unit reason=worker-start-identity-unavailable"
    return 1
  }
  if ! coord_renew "$claim_key" "$claim_owner" "$pid" "$pid_started"; then
    stuck_worker_stop "$pid" || :
    if ! alive "$pid"; then coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; fi
    say "dispatch stopped unit=$unit reason=claim-lost-after-launch"
    return 1
  fi
  local w; w="$(jqf -cn --argjson pid "${pid:-0}" --argjson pid_start "$pid_started" --arg unit "$unit" --arg type "$type" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg mode "$CODEX_MODE" --arg session_id "$CODEX_SESSION_ID" --arg sha "$sha" --arg pr_head "$pr_head" --arg workdir "$workdir" --arg model "$model" --arg issue "$issue" --arg claim_key "$claim_key" --arg claim_owner "$claim_owner" --argjson usage_start "$CODEX_USAGE_START" \
    '{pid:$pid,pid_start:$pid_start,unit:$unit,type:$type,log:$log,report:$report,started:$at,mode:$mode,session_id:$session_id,sha:$sha,pr_head:$pr_head,workdir:$workdir,model:$model,token_usage_start:$usage_start,issue:$issue,claim_key:$claim_key,claim_owner:$claim_owner}')"
  if ! jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"; then
    stuck_worker_stop "$pid" || :
    if ! alive "$pid"; then coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; fi
    say "dispatch stopped unit=$unit reason=worker-ledger-write-failed"
    return 1
  fi
  if [[ "$cache_fresh" == true ]] && (( SECONDS < cache_until )) && alive "$pid"; then
    LIVE_WORKER_CACHE_TOTAL=$((LIVE_WORKER_CACHE_TOTAL + 1))
    LIVE_WORKER_CACHE_TYPES["$type"]=$((${LIVE_WORKER_CACHE_TYPES[$type]:-0} + 1))
    LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 10))
  fi
  say "dispatch claim=owned issue=${issue:-none} mode=$CODEX_MODE reason=$CODEX_PATH_REASON pid=$pid type=$type unit=$unit"
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail worker_start unit=$unit secs=${elapsed}s"
}

critical_pending_count() {
  jqf '[.units[] | select(.critical==true) | select(.stage=="implement-pending" or .stage=="review-pending" or .stage=="repair-pending" or .stage=="rereview-pending")] | length' "$UNITS" 2>/dev/null || echo 0
}
