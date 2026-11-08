
capture_worker_stdout_report() { # report-path command...
  local report="$1" partial="${1}.partial" status=0
  shift
  "$@" > "$partial" || status=$?
  if (( status != 0 )); then return "$status"; fi
  [[ -s "$partial" ]] || return 1
  if [[ -e "$report" ]]; then
    mv -f -- "$partial" "${report}.final-message"
  else
    # A worker may have written its prompted report while the CLI was running.
    # Never let this final-message capture replace that report, including a
    # report that appears between the existence check and the rename.
    mv -n -- "$partial" "$report" || return 1
    [[ ! -e "$partial" ]] || mv -f -- "$partial" "${report}.final-message"
  fi
}

dispatch() { # type model effort unit log report prompt [sha] [workdir] [pr-head] [new-failure] [provider] [hard] [route-reason] [worker-context-json]
  local type="${1:-}" model="${2:-}" effort="${3:-}" unit="${4:-}" log="${5:-}" report="${6:-}" prompt="${7:-}" sha="${8:-}" workdir="${9:-$ROOT}" pr_head="${10:-}" provider="${12:-$(provider_of "${2:-}")}" hard_escalation="${13:-false}" route_reason="${14:-configured}" worker_context="${15:-}" report_only=false expected_session_id="" pid cache_fresh=false cache_until="$LIVE_WORKER_CACHE_UNTIL" started=$SECONDS elapsed issue claim_key claim_owner claim_status pr_census guard_env_word
  local -a launcher=() worker_env=() launch_command=()
  if [[ -n "$worker_context" ]]; then
    report_only="$(jqf -r '.incident_report_resume // false' <<<"$worker_context")"
    expected_session_id="$(jqf -r '.incident_report_resume_session_id // empty' <<<"$worker_context")"
  fi
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) && cache_fresh=true
  if [[ "$(unit_field "$unit" '.lane // empty')" == direct-main ]]; then
    worker_env=(env ZF_NON_PRODUCT_UNIT=1 "ZF_PIPELINE_UNIT=$unit" \
      "PATH=${ZF_ENGINE_DIR:-$ROOT/engine}/non-product-test-shim:$PATH")
  fi
  # Worker write guard: a node or python write into the deployment checkout fails loudly (2026-11-07).
  if ((${#worker_env[@]} == 0)); then worker_env=(env); fi
  while IFS= read -r guard_env_word; do
    [[ -n "$guard_env_word" ]] && worker_env+=("$guard_env_word")
  done < <(worker_write_guard_env "$workdir" || true)
  # setsid：worker 自成进程组，超时可整组终止（含 codex 子进程）。
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  build_codex_command "$type" "$model" "$effort" "$unit" "$prompt" "${11-$prompt}" "$workdir" "$provider" "$report_only" "$expected_session_id" || return 1
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
    # stdout supplies a missing report, but must not replace a report the worker wrote itself.
    export -f capture_worker_stdout_report
    launch_command=(env GIT_PAGER=cat PAGER=cat bash -c 'capture_worker_stdout_report "$@"' _ "$SUP/$report" \
      "${CODEX_COMMAND[@]}")
  elif [[ "$type" == repair && "$CODEX_MODE" == resume && "$report_only" == true ]]; then
    # Do one strict, read-only continuation of the same session. A startup
    # failure stays a failed report completion; it never falls back to a fresh
    # code-writing repair.
    launch_command=(bash -c 'jq -cn --arg model "$1" "$2" && shift 2 && exec "$@"' autopilot-worker "$model" \
      '{type:"pipeline.execution",mode:"resume",reason:"incident-report-only",model:$model}' "${CODEX_COMMAND[@]}")
  elif [[ "$type" == repair && "$CODEX_MODE" == resume ]]; then
    launch_command=(bash "$CODEX_REPAIR_RUNNER" "$SUP/$log" "$CODEX_SESSION_ID" \
      "${#CODEX_FRESH_COMMAND[@]}" "${CODEX_FRESH_COMMAND[@]}" "${CODEX_COMMAND[@]}")
  else
    launch_command=(bash -c 'jq -cn --arg mode "$1" --arg reason "$2" --arg model "$3" "$4" \
      && shift 4 && exec "$@"' autopilot-worker "$CODEX_MODE" "$CODEX_PATH_REASON" "$model" \
      '{type:"pipeline.execution",mode:$mode,reason:$reason,model:$model}' "${CODEX_COMMAND[@]}")
  fi
  local worker_pid_file WORKER_PIDFILE WORKER_COST_TAG # not exported: the worker must not inherit them; worker_scope_launch reads them
  WORKER_PIDFILE="$(worker_pidfile "$unit")"
  WORKER_COST_TAG="type=$type unit=$unit"
  worker_pid_file="$(mktemp "$A/.worker-start.XXXXXX")" || return 1
  rm -f -- "$worker_pid_file"
  worker_scope_launch "$worker_pid_file" "$workdir" "$SUP/$log" "${launcher[@]}" -- \
    "${worker_env[@]}" "${launch_command[@]}" || { rm -f -- "$worker_pid_file"; return 1; }
  pid="$WORKER_SCOPE_PID"
  rm -f -- "$worker_pid_file"
  local pid_started
  pid_started="${WORKER_SCOPE_PID_START:-}"
  [[ "$pid_started" =~ ^[0-9]+$ ]] || pid_started="$(coord_process_start_ticks "$pid" 2>/dev/null)" || {
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
  local w; w="$(jqf -cn --argjson pid "${pid:-0}" --argjson pid_start "$pid_started" --arg unit "$unit" --arg type "$type" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg mode "$CODEX_MODE" --arg session_id "$CODEX_SESSION_ID" --arg sha "$sha" --arg pr_head "$pr_head" --arg workdir "$workdir" --arg model "$model" --arg provider "$provider" --arg effort "$effort" --arg route_reason "$route_reason" --argjson hard_escalation "$hard_escalation" --arg issue "$issue" --arg claim_key "$claim_key" --arg claim_owner "$claim_owner" --argjson usage_start "$CODEX_USAGE_START" \
    '{pid:$pid,pid_start:$pid_start,unit:$unit,type:$type,log:$log,report:$report,started:$at,mode:$mode,session_id:$session_id,sha:$sha,pr_head:$pr_head,workdir:$workdir,provider:$provider,model:$model,effort:$effort,hard_escalation:$hard_escalation,route_reason:$route_reason,token_usage_start:$usage_start,issue:$issue,claim_key:$claim_key,claim_owner:$claim_owner}')"
  [[ -z "$worker_context" ]] || w="$(jqf --argjson context "$worker_context" '. + $context' <<<"$w")"
  if [[ ( "${WORKER_STDOUT_REPORT:-0}" == 1 || "$provider" == claude ) && ${#launcher[@]} -gt 0 ]]; then
    w="$(jqf --argjson pgid "$pid" '. + {process_group:$pgid}' <<<"$w")"
  fi
  if ! jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"; then
    stuck_worker_stop "$pid" || :
    if ! alive "$pid"; then coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; fi
    say "dispatch stopped unit=$unit reason=worker-ledger-write-failed"
    return 1
  fi
  if [[ "$type" == implement || "$type" == repair ]]; then
    say "implement-route unit=$unit provider=$provider reason=$route_reason"
  fi
  if [[ "$cache_fresh" == true ]] && (( SECONDS < cache_until )) && harvest_worker_alive "$w"; then
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
