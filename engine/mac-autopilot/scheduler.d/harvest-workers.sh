
# ---------- 1. 回收（按 worker.type 分类推进） ----------
harvest_workers() { # [local-only]: fast refill completes direct-main implement workers locally plus <=2 finished PR-lane implement workers
  local pr_harvested=0 local_only="${1:-false}" w pid unit wtype report rep lg session_id tk v msg wmode wsha wprhead role dispatch_usage_count session_usage_count usage_end usage_start accounting started s mins no_output pgid limit_hit stream decision
  while read -r w; do
    [[ "$(jqf -r '.harvested // false' <<<"$w")" == "true" ]] && continue
    pid="$(jqf -r .pid <<<"$w")"; unit="$(jqf -r .unit <<<"$w")"; wtype="$(jqf -r .type <<<"$w")"
    report="$(jqf -r .report <<<"$w")"; rep="$SUP/$report"; lg="$SUP/$(jqf -r .log <<<"$w")"
    if [[ "$local_only" == true ]]; then
      if [[ "$wtype" == implement && "$(unit_field "$unit" '.lane // empty')" == pr ]]; then
        # Finished PR-lane worker: harvest now so its footprint frees without waiting for the slow tick.
        # At most 2 per refill: harvest_pr_implement makes GitHub calls and the REST quota is shared with releases.
        [[ -s "$rep" ]] && ! alive "$pid" && (( pr_harvested < 2 )) || continue
        pr_harvested=$((pr_harvested + 1))
      else
        [[ "$wtype" == implement && "$(unit_field "$unit" '.lane // empty')" == direct-main ]] || continue
      fi
      # OBSOLETE closes the GitHub issue; leave it for the slow tick to deliver that side effect.
      [[ "$(grep -m1 -v '^[[:space:]]*$' "$rep" 2>/dev/null)" != OBSOLETE:* ]] || continue
    fi
    if [[ "$wtype" == eval ]]; then
      alive "$pid" && continue
      tick_prs_prime
      harvest_prompt_eval "$w"
      continue
    fi
    if [[ "$wtype" == supervise ]]; then
      alive "$pid" && continue
      tick_prs_prime
      harvest_supervisor_arbiter "$w"
      continue
    fi
    # --json 日志：末次累计 turn.completed 的新鲜 token（旧页脚 blended 口径一致）；legacy 日志退回页脚
    stream="$(python3 "$USAGE_READER" codex-stream "$lg" 2>/dev/null || true)"
    tk="$(jqf -r '.fresh // empty' <<<"$stream")"
    [[ "$tk" =~ ^[0-9]+$ ]] || tk="$(tokens_of "$lg")"
    [[ "$tk" =~ ^[0-9]+$ ]] || tk=""  # 读不出来就是 unavailable，不当 0
    if alive "$pid"; then
      started="$(jqf -r .started <<<"$w")"
      s="$(ap_iso_epoch "$started")"; [[ "$s" =~ ^[0-9]+$ ]] || s="$NOW_EPOCH"
      mins=$(( (NOW_EPOCH - s) / 60 ))
      if (( mins > $(jqf -r '.waste.slow_worker_minutes // 60' <<<"$CFG") )); then
        echo "[$STAMP] SLOW worker pid=$pid unit=$unit ${mins}min" >> "$A/alerts/waste.md"
      fi
      # 运行多久本身不触发停止（会误杀有进展的长任务）：停止决策在 stuck_worker_disposition，
      # 由 f8 的在制品年龄信号加进展指纹驱动（#4371）。
      if [[ -n "$tk" ]] && (( tk > $(jqf -r '.waste.burn_tokens_no_output // 800000' <<<"$CFG") )); then
        echo "[$STAMP] BURN worker pid=$pid unit=$unit tokens=$tk no-output" >> "$A/alerts/waste.md"
      fi
      continue
    fi

    case "$wtype" in implement|repair|land) tick_prs_changed ;; esac # Finished workers may have pushed.
    tick_prs_prime
    # --json 日志先取事件流自身的 session id（thread.started）；legacy 日志退回页脚 grep，再退回台账（resume 派发时已知）
    local execution
    execution="$(jq -Rsc '[split("\n")[] | fromjson? | select(.type=="pipeline.execution")] | last // {}' "$lg" 2>/dev/null)"
    if [[ "$(jqf -r '.reason // empty' <<<"$execution")" == resume-startup-failed ]]; then
      w="$(jqf '.mode="fresh" | .session_id="" | .token_usage_start={input_tokens:0,cached_input_tokens:0,output_tokens:0}' <<<"$w")"
      say "repair fallback unit=$unit mode=fresh reason=resume-startup-failed"
    fi
    session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(grep -m1 -Eo 'session id: [[:xdigit:]-]{36}' "$lg" 2>/dev/null | sed 's/^session id: //' || true)"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(jqf -r '.session_id // empty' <<<"$w")"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id=""
    # Persist every run, including runs without a report. Review has its own slot.
    if [[ -n "$session_id" && "$wtype" =~ ^(implement|repair|review|rereview)$ ]]; then
      role="$(session_role "$wtype")"
      local session_model session_provider session_record
      session_model="$(jqf -r '.model // empty' <<<"$w")"
      session_provider="$(provider_of "$session_model")"
      session_record="$(jqf -cn --arg id "$session_id" --arg provider "$session_provider" --arg model "$session_model" '{id:$id,provider:$provider,model:$model}')"
      set_unit "$unit" ".session_id=$(js "$session_id") | .session_ids[\"$role\"]=$(js "$session_id") | .sessions[\"$role\"]=$session_record"
    fi
    # 原生 turn 事件入库（provider/session/turn 幂等键，重复交付/重扫不重复计数）；legacy 日志无事件，no-op
    python3 "$USAGE_READER" codex-ingest "$lg" "$session_id" "$(jqf -r '.started // empty' <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
    if [[ ! -s "$rep" && "$rep" == *-r-* && -s "${rep/-r-/-}" ]]; then
      # 复审 worker 偶尔把报告写成 review-N-<TAG>.md（丢了 -r-）：pr-3972 两次 APPROVE 因此被当成无产出死亡。
      mv -f -- "${rep/-r-/-}" "$rep" && say "report for unit=$unit was written as $(basename "${rep/-r-/-}"); moved to $report"
    fi
    if [[ ! -s "$rep" ]]; then
      msg="$(final_message_of "$lg")"
      # --json 日志没有页脚：只有全部 turn 都收到 turn.completed 的日志，最后的 agent_message 才是最终答复；
      # 被杀/中断的 worker 只剩旁白，不能当报告（否则绕过无产出计数、重试与限额冷却）
      [[ -n "${msg//[[:space:]]/}" ]] || msg="$(jqf -r 'select(.complete == true) | .message // empty' <<<"$stream")"
      if [[ -n "${msg//[[:space:]]/}" ]]; then
        # 正常结束却没写报告文件：13/83 次"无产出"其实带着结论（issue-2593 BLOCKED-ON 被当死亡重跑）。
        printf '%s\n' "$msg" > "$rep" && say "report for unit=$unit missing; recovered the worker's final message into $report"
      fi
    fi
    usage_end="$(session_usage_for_id "$session_id")"
    usage_start="$(jqf -c '.token_usage_start // null' <<<"$w")"
    accounting="$(jqf -cn --argjson start "$usage_start" --argjson end "$usage_end" \
      --arg mode "$(jqf -r '.mode // "fresh"' <<<"$w")" --arg before "$(jqf -r '.session_id // empty' <<<"$w")" --arg after "$session_id" '
      def valid: type=="object" and all(.input_tokens,.cached_input_tokens,.output_tokens; type=="number" and .>=0);
      (if ($start|valid|not) then "missing-baseline"
       elif $mode=="resume" and $before!=$after then "session-changed"
       elif ($end|valid|not) then "missing-end"
       elif any(["input_tokens","cached_input_tokens","output_tokens"][]; $end[.] < $start[.]) then "counter-reset"
       else "measured" end) as $status |
      {token_accounting:$status,token_usage_end:$end,dispatch_tokens:
        (if $status=="measured" then ($end.input_tokens - $start.input_tokens + $end.output_tokens - $start.output_tokens) else null end)}
    ')"
    accounting="$(jqf --arg sid "$session_id" --arg mode "$(jqf -r '.mode // "fresh"' <<<"$w")" \
      --arg reason "$(jqf -r '.reason // empty' <<<"$execution")" '. + {session_id:$sid,mode:$mode,execution_reason:$reason}' <<<"$accounting")"
    if [[ "$(jqf -r '.reason // empty' <<<"$execution")" == resume-startup-failed ]]; then
      accounting="$(jqf --arg sid "$(jqf -r '.resume_session_id // empty' <<<"$execution")" '.resume_session_id=$sid' <<<"$accounting")"
    fi
    dispatch_usage_count="$(jqf -r '.dispatch_tokens // "unknown"' <<<"$accounting")"
    session_usage_count="$(jqf -r 'if .==null then "unknown" else .input_tokens + .output_tokens end' <<<"$usage_end")"
    if [[ "$dispatch_usage_count" =~ ^[0-9]+$ ]]; then
      set_unit "$unit" ".tokens = ((.tokens // 0) + $dispatch_usage_count)"
    fi
    if [[ "$wtype" == implement || "$wtype" == repair ]]; then
      local actual paths_dir
      paths_dir="$(jqf -r '.workdir // empty' <<<"$w")"
      if [[ "$(jqf -r '.lease_expired // false' <<<"$w")" == true ]]; then
        set_unit "$unit" '.footprint=[]'
      else
        if actual="$(set -o pipefail; git -C "$paths_dir" diff --name-only origin/main...HEAD | jq -Rsc 'split("\n") | map(select(length>0))')"; then
          set_unit "$unit" "$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-end "$actual") | .footprint=((.footprint // []) + $actual | unique)"
        else
          say "unit $unit footprint refresh failed; keeping existing footprint"
        fi
      fi
    fi
    if [[ -s "$rep" ]]; then
      v="$(verdict_of "$rep")"
      wmode="$(jqf -r '.mode // "fresh"' <<<"$w")"
      wsha="$(jqf -r '.sha // empty' <<<"$w")"; [[ "$wsha" =~ $SHA_RE ]] || wsha=""
      wprhead="$(jqf -r '.pr_head // empty' <<<"$w")"; [[ "$wprhead" =~ $SHA_RE ]] || wprhead=""
      say "harvest unit=$unit type=$wtype verdict=${v:-none} mode=$wmode tokens=${tk:-unavailable} session_id=${session_id:-none} session_tokens=$dispatch_usage_count session_total_tokens=$session_usage_count"
      case "$wtype" in
        review|rereview)
          local reviewed=".reviewed_sha=$(js "$wsha") | .reviewed_pr_head=$(js "$wprhead") | .review_report=$(js "$report")"
          case "$v" in
            READY)
              # 同时保留审核候选与当时观察到的 GitHub PR head；旧 worker 缺失 PR head 时拒绝批准。
              if [[ "$wprhead" =~ $SHA_RE ]]; then
                local eval_stages eval_reason eval_workdir eval_tree eval_label eval_report eval_safe_id eval_stages_json eval_gate
                eval_workdir="$(jqf -r '.workdir // empty' <<<"$w")"
                eval_reason=""
                if eval_stages="$(decision_eval_stages "$eval_workdir" "$wsha")"; then
                  :
                else
                  eval_stages='triage advisor implement review end-to-end'
                  eval_reason='candidate diff unavailable; eval reports every stage'
                fi
                if [[ -n "${eval_stages//[[:space:]]/}" ]]; then
                  eval_tree="$(git -C "$eval_workdir" rev-parse "$wsha^{tree}" 2>/dev/null)" || eval_tree=""
                  if [[ -z "$eval_tree" ]]; then
                    eval_stages='triage advisor implement review end-to-end'
                    eval_reason='candidate tree unavailable; eval reports every stage'
                  fi
                  eval_safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$unit" | sed 's/-$//')"
                  eval_label=""
                  eval_report="eval-gate-${eval_safe_id}-${eval_tree:-pending}.json"
                  [[ -n "$eval_tree" ]] && eval_label="gate-$eval_tree"
                  eval_stages_json="$(jqf -cn --arg stages "$eval_stages" '$stages | split(" ") | map(select(length>0))')"
                  eval_gate="$(jqf -cn --arg sha "$wsha" --arg pr_head "$wprhead" --arg tree "$eval_tree" \
                    --arg label "$eval_label" --arg workdir "$eval_workdir" --arg report "$eval_report" \
                    --arg reason "$eval_reason" --argjson stages "$eval_stages_json" \
                    '{status:"pending",sha:$sha,pr_head:$pr_head,tree:$tree,label:$label,workdir:$workdir,report:$report,stages:$stages} + (if $reason=="" then {} else {reason:$reason} end)')"
                  # #4656（裁决 architecture-ships-evals-alongside）：架构面改动照常批准进 ready-to-merge，
                  # eval_gate 只是并行报告任务的派发凭据，不是交付前置。
                  set_unit "$unit" "$(hist review-approve "$wsha") | $reviewed | .approved_sha=$(js "$wsha") | .ready_since=(.ready_since // $NOW_EPOCH) | .eval_gate=$eval_gate | .stage=\"ready-to-merge\""
                  post_approved_status "$unit" "$wprhead"
                  say "review approved unit=$unit sha=$wsha; eval reporting stages=$(tr ' ' ',' <<<"${eval_stages% }") runs alongside delivery"
                else
                  set_unit "$unit" "$(hist review-approve "$wsha") | $reviewed | .approved_sha=$(js "$wsha") | .ready_since=(.ready_since // $NOW_EPOCH) | del(.eval_gate) | .stage=\"ready-to-merge\""
                  post_approved_status "$unit" "$wprhead"
                fi
              else
                set_unit "$unit" "$reviewed | .approved_sha=null"
                to_supervisor "$unit" "review worker $report did not record the observed PR head"
              fi ;;
            NOT_READY)
              set_unit "$unit" "$(hist review-request-changes "$wsha") | $reviewed | .approved_sha=null | .stage=\"repair-pending\"$(review_findings_update "$rep" "$report")$(review_findings_hint_update "$rep") | .author_dispositions_pending=true"
              cancel_unit_runs "$unit" "review requested changes; head will change" ;;
            INPUT_INCOMPLETE)
              set_unit "$unit" "$(hist review-block "$wsha") | $reviewed | .approved_sha=null | .blocked_main_sha=$(js "$MAIN_HEAD") | .stage=\"blocked-external\""
              local bdep; bdep="$(blocked_on_of "$rep")"
              [[ -n "$bdep" ]] && set_unit "$unit" ".blocked_on=$bdep | .note=$(js "waiting for predecessor #$bdep")"
              cancel_unit_runs "$unit" "review blocked" ;;
            *)
              set_unit "$unit" "$reviewed | .approved_sha=null"
              if [[ "$(unit_retries "$unit" verdict-missing)" == 0 ]]; then
                set_unit "$unit" "$(hist verdict-missing "$report") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
              else
                to_supervisor "$unit" "review report $report has no single VERDICT line (twice)"
              fi ;;
          esac ;;
        repair)
          if [[ "$(unit_field "$unit" '.self_fix_active // false')" == true ]]; then
            set_unit "$unit" "$(hist self-fix-delivered) | .self_fix_active=false | .self_fix_pending=false | .self_check_sha=null | .self_check_status=null | .stage=.self_check_return_stage"
          else
            local current_unit disposition_update
            if [[ "$(unit_field "$unit" '.author_dispositions_pending // false')" == true ]]; then
              current_unit="$(jqf -c --arg id "$unit" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
              disposition_update="$(review_dispositions_update "$rep" "$current_unit")"
            else
              disposition_update=""
            fi
            set_unit "$unit" "$(hist repair-delivered) $disposition_update | .repair_hint=null | (.stage=\"rereview-pending\")"
            set_unit "$unit" ".author_dispositions_pending=false"
          fi
          # f6 复查（#4482）：repair/self-fix 推的新 head 重新过尺寸准入；超线同样转 supervisor 拆分
          local recheck_dir recheck_branch
          recheck_dir="$(jqf -r '.workdir // empty' <<<"$w")"; recheck_branch="$(unit_field "$unit" '.branch // empty')"
          if [[ "$(unit_field "$unit" '.lane // "pr"')" != direct-main ]] && [[ "$(unit_field "$unit" '.pr // empty')" =~ ^[0-9]+$ ]]; then
            size_admission_recheck "$unit" "$recheck_dir" "$recheck_branch" "on $recheck_branch after repair" || :
          fi ;;
        land)
          local land_result; land_result="$(head -1 "$rep")"
          case "$land_result" in
            LANDED-HEAD-MOVED*)
                     local landed_sha moved_head
                     read -r _ landed_sha moved_head <<<"$land_result"
                     set_unit "$unit" "$(hist land-head-moved "$land_result") | .land_sha=$(js "$landed_sha") | .approved_sha=null | .land_pr_head=$(js "$moved_head") | .stage=\"rereview-pending\""
                     echo "[$STAMP] fast-landed-with-new-head unit=$unit $land_result" >> "$A/alerts/events.md" ;;
            LANDED*) set_unit "$unit" "$(hist landed "$land_result") | .stage=\"landed\" | .land_sha=$(js "${land_result#LANDED }")"
                     local land_issue; land_issue="$(unit_field "$unit" .issue)"
                     # M5（#4501）：验收块带 live-event 项的票不立即关票，转等待生产事件（live_event_watch）
                     if [[ -n "$land_issue" && -z "$(unit_field "$unit" .pr)" ]] \
                       && landed_live_event_wait "$unit" "$land_issue" "${land_result#LANDED }"; then
                       gh issue close "$land_issue" --comment "Landed on main as ${land_result#LANDED } through the autopilot direct-main lane (reviewed local commit, no PR)." >/dev/null 2>&1
                     fi
                     echo "[$STAMP] fast-landed unit=$unit $land_result" >> "$A/alerts/merge.md" ;;
            *"not eligible"*)
              if [[ -z "$(unit_field "$unit" .pr)" ]]; then to_supervisor "$unit" "NEEDS-PR: $land_result"
              else set_unit "$unit" "$(hist land-refused "$land_result") | .lane=\"pr\" | .stage=\"ready-to-merge\""; fi ;;
            *"head moved"*) set_unit "$unit" "$(hist land-refused "$land_result") | .approved_sha=null | .stage=\"rereview-pending\"" ;;
            FAILED\ POST-LAND*)
              local landed_sha="${land_result##* }"
              if [[ "$landed_sha" =~ $SHA_RE ]]; then
                set_unit "$unit" "$(hist land-post-step-failed "$land_result") | .land_sha=$(js "$landed_sha") | .approved_sha=null"
              fi
              to_supervisor "$unit" "直落 main 已完成但 PR 后续处理失败：${land_result}。详情见 $SUP/${report}.land.log。"
              echo "[$STAMP] post-land follow-up failed unit=$unit $land_result" >> "$A/alerts/events.md"
              ;;
            *"push-failed"*|*"fetch"*|*"clone"*)
              # 传输类失败：同一批准 head 重试一次，再失败转人工
              if [[ "$(jqf -r --arg id "$unit" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="land-retry")] | length' "$UNITS")" == 0 ]]; then
                set_unit "$unit" "$(hist land-retry "$land_result") | .stage=\"ready-to-merge\""
              else
                to_supervisor "$unit" "fast land failed twice: $land_result (log ${report}.land.log)"
              fi ;;
            *) # 冲突、预检失败、落地卡死：改动本身要修，交给 repair 并附落地日志
               set_unit "$unit" "$(hist land-failed "$land_result") | .approved_sha=null | .repair_hint=$(js "直落 main 失败：${land_result}。落地日志 $SUP/${report}.land.log；与 main 冲突就 merge origin/main 解决；检查失败或卡死就修复根因并补回归测试。") | .stage=\"repair-pending\"" ;;
          esac ;;
        implement|triage)
          if [[ "$wtype" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == direct-main ]]; then
            harvest_prless_implement "$unit" "$rep" "$local_only"
          elif [[ "$wtype" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == pr ]]; then
            harvest_pr_implement "$unit" "$rep"
          else
            decision="$(decision_entry 'Hand off delivered worker result to supervisor' 'the current unit state has no automatic delivery transition' "$report" '["Advance the unit without supervisor handling"]' scheduler)"
            set_unit "$unit" "$(hist delivered "" "$decision") | (.stage=\"supervisor-review\")"
            echo "[$STAMP] IMPL-DELIVERED unit=$unit report=$(basename "$rep")" >> "$A/alerts/events.md"
          fi ;;
      esac
    else
      limit_hit="$( { tail -n 40 "$lg"; cat "$rep.partial"; } 2>/dev/null | grep -m1 -oiE "$PROVIDER_LIMIT_RE" || true)"
      rm -f -- "$rep.partial"
      if [[ -n "$limit_hit" ]]; then
        # 提供方上限：冷却该提供方，不计入无产出、不算失败回合；单元留在原 stage 由孤儿自愈回到 pending。
        start_cooldown "$(provider_of "$(jqf -r '.model // ""' <<<"$w")")" "$limit_hit (unit=$unit)"
        set_unit "$unit" "$(hist worker-provider-limit "$limit_hit")"
        jqf --argjson accounting "$accounting" --arg finished "$STAMP" "(.workers[] |= (if .pid==$pid and .unit==\"$unit\" and .harvested != true then (. += \$accounting | .harvested=true | .finished_at=\$finished) else . end))" "$WORKERS" | write_state "$WORKERS"
        continue
      fi
      echo "[$STAMP] WASTE zero-output worker pid=$pid unit=$unit log=$(basename "$lg")" >> "$A/alerts/waste.md"
      say "WASTE zero-output pid=$pid unit=$unit"
      # L9：无产出死亡计数；到上限转人工，不再无限重派。
      set_unit "$unit" "$(hist worker-no-output "$wtype")"
      no_output="$(jqf -r --arg id "$unit" '[.units[] | select(.id==$id) | (.history // []) | map(select(.stage=="worker-no-output")) | length][0] // 0' "$UNITS")"
      if [[ "$(unit_field "$unit" '.self_fix_active // false')" != true && "$no_output" =~ ^[0-9]+$ ]] && (( no_output >= MAX_NO_OUTPUT )); then
        if [[ "$wtype" =~ ^(review|rereview|repair|implement)$ && "$(unit_retries "$unit" fresh-session-retry)" == 0 ]]; then
          # 续接的会话可能已坏（上下文爆、提供方会话失效）：丢掉会话 ID 再试一次全新会话。
          set_unit "$unit" "$(hist fresh-session-retry "$no_output deaths") | .session_ids={} | .sessions={} | .session_id=null | .stage=\"${wtype}-pending\""
          say "unit=$unit: $no_output workers died -> one fresh-session retry"
        else
          to_supervisor "$unit" "$no_output workers died without a report, fresh session too (last log $(basename "$lg"))"
        fi
      fi
    fi
    jqf --argjson accounting "$accounting" --arg finished "$STAMP" "(.workers[] |= (if .pid==$pid and .unit==\"$unit\" and .harvested != true then (. += \$accounting | .harvested=true | .finished_at=\$finished) else . end))" "$WORKERS" | write_state "$WORKERS"
  done < <(jqf -c '.workers[]' "$WORKERS")
}

# ---------- 1b. 孤儿自愈：worker stage 无未收割 worker 记录时回对应 pending ----------
# 只看记录、不看进程：worker 在 harvest_workers 判活之后、本阶段之前退出（中间隔几十秒），按进程判会再派一个，
# 下一拍又收割原报告，同一单元两条评审/修复链并行（pr-2350 01:30、热修 pr-3588 02:44）。死了未收割的记录交给下一拍收割。
recover_orphans() {
  local id st
  while read -r id st; do
    [[ -z "$id" ]] && continue
    if [[ "$(jqf -r --arg u "$id" '[.workers[] | select(.unit==$u and .harvested != true)] | length' "$WORKERS")" == 0 ]]; then
      if [[ "$(unit_field "$id" '.self_fix_active // false')" == true ]]; then
        set_unit "$id" '.self_fix_active=false | .self_fix_pending=false | .stage=.self_check_return_stage'
      else
        set_unit "$id" ".stage=\"${st}-pending\""
      fi
      say "orphan-recover unit=$id ${st} -> ${st}-pending"
    fi
  done < <(jqf -r '.units[] | select(.stage=="review" or .stage=="rereview" or .stage=="repair" or .stage=="implement") | "\(.id) \(.stage)"' "$UNITS")
}
stuck_worker_progress_fp() { # worker-json → "<log字节>|<HEAD>|<工作区内容指纹>"
  local wd lg size head dirty path
  wd="$(jqf -r '.workdir // ""' <<<"$1")"; lg="$SUP/$(jqf -r .log <<<"$1")"
  size="$(stat -c %s "$lg" 2>/dev/null || echo 0)"
  if { [[ -d "$wd/.git" ]] || [[ -f "$wd/.git" ]]; }; then
    head="$(git -C "$wd" rev-parse HEAD 2>/dev/null || echo none)"
    dirty="$(
      {
        git -C "$wd" diff --binary HEAD -- 2>/dev/null || true
        while IFS= read -r -d '' path; do
          printf '\0%s\0' "$path"
          git -C "$wd" diff --no-index --binary /dev/null "$path" 2>/dev/null || true
        done < <(git -C "$wd" ls-files --others --exclude-standard -z 2>/dev/null)
      } | cksum | awk '{print $1 ":" $2}'
    )"
  else
    head=nogit; dirty=nogit
  fi
  printf '%s|%s|%s' "$size" "$head" "$dirty"
}
stuck_worker_stop() { # pid; dispatch() gives model workers their own process group via setsid
  local pid="$1" pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ "$pgid" == "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in {1..10}; do
      kill -0 -- "-$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..10}; do
      alive "$pid" || return 0
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
}
coord_scheduler_live_worker() { # unit issue -> true if an unharvested worker for this ticket is still alive
  local unit="$1" issue="${2:-}" worker worker_unit worker_issue pid expected_start current_start
  while IFS= read -r worker; do
    worker_unit="$(jqf -r '.unit // empty' <<<"$worker")"
    worker_issue="$(jqf -r '.issue // empty' <<<"$worker")"
    if [[ -z "$worker_issue" && -n "$issue" ]]; then worker_issue="$(unit_field "$worker_unit" '.issue // empty')"; fi
    [[ "$worker_unit" == "$unit" || ( -n "$issue" && "$worker_issue" == "$issue" ) ]] || continue
    pid="$(jqf -r '.pid // empty' <<<"$worker")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    expected_start="$(jqf -r '.pid_start // empty' <<<"$worker")"
    if [[ "$expected_start" =~ ^[0-9]+$ ]]; then
      current_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
      [[ "$current_start" == "$expected_start" ]] || continue
    fi
    alive "$pid" && return 0
  done < <(jqf -cr '.workers[] | select(.harvested != true and .lease_expired != true)' "$WORKERS")
  return 1
}

coord_on_expire() { # claim JSON; called under that ticket's claim lock
  local claim="$1" owner unit type worker pid expected_start current_start pgid
  [[ "$(jqf -r '.owner_kind // empty' <<<"$claim")" == scheduler-worker ]] || return 0
  owner="$(jqf -r '.owner // empty' <<<"$claim")"
  unit="$(jqf -r '.unit // empty' <<<"$claim")"
  type="$(jqf -r '.stage // empty' <<<"$claim")"
  worker="$(jqf -c --arg owner "$owner" '[.workers[] | select(.claim_owner==$owner and .harvested!=true)][0] // empty' "$WORKERS")"
  if [[ -n "$worker" ]]; then
    pid="$(jqf -r '.pid // empty' <<<"$worker")"
  else
    pid="$(jqf -r '.pid // empty' <<<"$claim")"
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { say "claim expiry cannot find worker pid owner=$owner; retaining claim"; return 1; }
  expected_start="$(jqf -r '.pid_start // empty' <<<"$claim")"
  [[ "$expected_start" =~ ^[0-9]+$ ]] || expected_start="$(jqf -r '.pid_start // empty' <<<"$worker")"
  if [[ "$expected_start" =~ ^[0-9]+$ ]]; then
    current_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
    if [[ -n "$current_start" && "$current_start" == "$expected_start" ]]; then
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
      stuck_worker_stop "$pid" || return 1
      current_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
      [[ "$current_start" != "$expected_start" ]] \
        || { say "claim expiry worker still alive owner=$owner pid=$pid; retaining claim"; return 1; }
      if [[ "$pgid" == "$pid" ]] && kill -0 -- "-$pid" 2>/dev/null; then
        say "claim expiry process group still alive owner=$owner pid=$pid; retaining claim"
        return 1
      fi
    elif [[ -n "$current_start" ]]; then
      say "claim expiry pid was reused owner=$owner pid=$pid; did not stop the new process"
    elif kill -0 "$pid" 2>/dev/null; then
      say "claim expiry cannot verify worker process identity owner=$owner pid=$pid; retaining claim"
      return 1
    fi
  elif kill -0 "$pid" 2>/dev/null; then
    say "claim expiry lacks worker start identity owner=$owner pid=$pid; retaining claim"
    return 1
  fi
  if [[ -n "$worker" ]]; then
    jqf --arg owner "$owner" \
      '(.workers[] |= (if .claim_owner==$owner and .harvested!=true then .lease_expired=true else . end))' \
      "$WORKERS" | write_state "$WORKERS" || return 1
  fi
  if [[ "$type" == implement || "$type" == repair ]]; then
    [[ -n "$unit" ]] && set_unit "$unit" '.footprint=[]' || return 1
    TICK_ACTIVE_FOOTPRINTS_VALID=false
    unset "TICK_FOOTPRINT_CACHE[$unit]" "TICK_CHECK_SCOPE_SOURCE[$unit]" "TICK_CHECK_SCOPE[$unit]"
  fi
  LIVE_WORKER_CACHE_UNTIL=0
  say "claim expired unit=$unit type=$type footprint=$([[ "$type" == implement || "$type" == repair ]] && echo released || echo none)"
}

coord_reconcile_scheduler_workers() { # renew active owners and release claims already harvested
  local worker key owner unit pid harvested expired expected_start current_start
  while IFS= read -r worker; do
    key="$(jqf -r '.claim_key // empty' <<<"$worker")"
    owner="$(jqf -r '.claim_owner // empty' <<<"$worker")"
    [[ -n "$key" && -n "$owner" ]] || continue
    unit="$(jqf -r '.unit' <<<"$worker")"
    harvested="$(jqf -r '.harvested // false' <<<"$worker")"
    expired="$(jqf -r '.lease_expired // false' <<<"$worker")"
    if [[ "$harvested" == true ]]; then
      coord_release "$key" "$owner" >/dev/null 2>&1 || :
    elif [[ "$expired" != true ]]; then
      pid="$(jqf -r '.pid // empty' <<<"$worker")"
      if [[ "$pid" =~ ^[0-9]+$ ]] && alive "$pid"; then
        expected_start="$(jqf -r '.pid_start // empty' <<<"$worker")"
        current_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
        if [[ "$expected_start" =~ ^[0-9]+$ && "$current_start" != "$expected_start" ]]; then
          say "claim not renewed unit=$unit reason=worker-pid-reused"
        else
          coord_renew "$key" "$owner" || say "claim renewal lost unit=$unit"
        fi
      fi
    fi
  done < <(jqf -c '.workers[]' "$WORKERS")
}
stuck_worker_disposition() {
  local scorecard="$A/node-health.json" bound offenders id w pid wtype probe fp held kills next issue hold_cli hold_ok
  local signal_active=0 named_count=0 live_count=0 killed_count=0
  local first_seen=0 progress=0 unchanged_window=0 unchanged_confirmed=0 no_live_worker=0 action
  local cap_worker cap_pid cap_unit cap_log cap_count cap_commands cap_summary cap_workdir cap_issue cap_branch cap_evidence cap_recut_ok cap_stash
  if [[ "$IMPLEMENT_COMMAND_CAP" =~ ^[0-9]+$ ]] && (( IMPLEMENT_COMMAND_CAP > 0 )); then
    while IFS= read -r cap_worker; do
      cap_unit="$(jqf -r '.unit // empty' <<<"$cap_worker")"
      cap_pid="$(jqf -r '.pid // empty' <<<"$cap_worker")"
      [[ "$(jqf -r '.type // empty' <<<"$cap_worker")" == implement ]] || continue
      [[ "$cap_pid" =~ ^[0-9]+$ ]] && alive "$cap_pid" || continue
      cap_log="$SUP/$(jqf -r '.log // empty' <<<"$cap_worker")"
      cap_count="$(awk 'index($0, "\"item.completed\"") && index($0, "\"command_execution\"") { count++ } END { print count+0 }' "$cap_log" 2>/dev/null || printf '0')"
      [[ "$cap_count" =~ ^[0-9]+$ ]] && (( cap_count > IMPLEMENT_COMMAND_CAP )) || continue
      stuck_worker_stop "$cap_pid"
      cap_workdir="$(jqf -r '.workdir // empty' <<<"$cap_worker")"
      cap_summary="command count: $cap_count; cap: $IMPLEMENT_COMMAND_CAP"
      cap_stash=""
      if [[ -n "$cap_workdir" && -n "$(git -C "$cap_workdir" status --porcelain 2>/dev/null)" ]]; then
        if git -C "$cap_workdir" stash push -u -q -m "autopilot: kept before redispatch $STAMP"; then
          cap_stash="$(git -C "$cap_workdir" rev-parse -q --verify refs/stash 2>/dev/null || true)"
          cap_summary+=$'\nworktree: uncommitted changes kept in stash '"$cap_stash"
        else
          cap_summary+=$'\nworktree: stash failed; dirty clone remains in place'
          say "IMPLEMENT-COMMAND-CAP stash failed unit=$cap_unit pid=$cap_pid workdir=$cap_workdir"
        fi
      fi
      cap_commands="$(jq -Rr 'fromjson? | select(.type=="item.completed" and .item.type=="command_execution") | .item.command // empty | gsub("[\\r\\n]+"; " ") | .[0:200]' "$cap_log" 2>/dev/null | tail -n 20 || true)"
      jqf --argjson pid "$cap_pid" --arg unit "$cap_unit" --arg finished "$STAMP" \
        --argjson count "$cap_count" --argjson cap "$IMPLEMENT_COMMAND_CAP" \
        '(.workers[] |= (if .pid==$pid and .unit==$unit and .harvested != true then (.harvested=true | .finished_at=$finished | .implement_command_capped={count:$count,cap:$cap}) else . end))' \
        "$WORKERS" | write_state "$WORKERS"
      cap_issue="$(unit_field "$cap_unit" '.issue // empty')"
      cap_branch="$(unit_field "$cap_unit" '.branch // empty')"
      cap_recut_ok=0
      if [[ -n "$cap_issue" ]]; then
        cap_evidence="$(jq -cn --argjson commands "$cap_count" --argjson limit "$IMPLEMENT_COMMAND_CAP" \
          --arg unit "$cap_unit" --arg branch "$cap_branch" --arg stash "$cap_stash" --arg workdir "$cap_workdir" \
          '{kind:"implement-command-cap",commands:$commands,limit:$limit,unit:$unit,branch:$branch,stash:$stash,workdir:$workdir}')"
        if scheduler_recut_route "$cap_issue" "$cap_evidence"; then
          if scheduler_issue_state "$cap_issue" | jq -e '.state == "needs-recut"' >/dev/null; then
            cap_recut_ok=1
          fi
        fi
      fi
      if (( cap_recut_ok )); then
        set_unit "$cap_unit" "$(hist implement-command-cap "$cap_count/$IMPLEMENT_COMMAND_CAP -> needs-recut") | .stage=\"blocked-external\" | .size_recut_pending=true | del(.stuck_probe)"
      else
        cap_summary+=$'\nrecut route failed'
        cap_summary+=$'\nlast 20 commands:\n'"${cap_commands:-none}"
        to_supervisor "$cap_unit" 'implement-command-cap: split' \
          'Split the implement unit before dispatching another worker' \
          "The implement worker ran $cap_count shell commands, above the $IMPLEMENT_COMMAND_CAP command cap." \
          "$cap_summary" \
          '["Split the implement unit into smaller units before resuming"]'
        set_unit "$cap_unit" "$(hist implement-command-cap "$cap_count/$IMPLEMENT_COMMAND_CAP") | del(.stuck_probe)"
      fi
      echo "[$STAMP] IMPLEMENT-COMMAND-CAP unit=$cap_unit pid=$cap_pid commands=$cap_count cap=$IMPLEMENT_COMMAND_CAP" >> "$A/alerts/events.md"
      say "IMPLEMENT-COMMAND-CAP unit=$cap_unit pid=$cap_pid commands=$cap_count cap=$IMPLEMENT_COMMAND_CAP"
    done < <(jqf -c '.workers[] | select(.harvested != true)' "$WORKERS")
  fi
  offenders=""
  # 消费 f8 的信号：只有 UNHEALTHY 的越阈值信号才点名单元；信号健康/未跑时名单为空，
  # 本拍只做残留探针清理，不碰任何 worker。
  if [[ -s "$scorecard" ]] \
     && [[ "$(jqf -r '[.metrics[] | select(.id=="flow.wip_age_stage_p90_hours")][0].status // ""' "$scorecard")" == UNHEALTHY ]]; then
    signal_active=1
    bound="$(jqf -r '[.metrics[] | select(.id=="flow.wip_age_stage_p90_hours")][0].unhealthy // 12' "$scorecard")"
    if [[ "$bound" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      offenders="$(jqf -r --argjson bound "$bound" '[.flow.wip_age[]? | select((.p90_hours // 0) >= $bound) | .oldest[]?.id] | unique | join(" ")' "$scorecard")"
    fi
  fi
  # 盲区：点名名单只含 wip_age oldest[]（有上限），名单外的 worker 永远不被探测。
  # 把所有日志静默超过 slow_worker_minutes 的活 worker 也并入同一个探测输入，走同一条停止路径。
  local slow_min widened
  slow_min="$(jqf -r '.waste.slow_worker_minutes // 60' <<<"$CFG")"
  widened="$(jqf -r '.workers[] | select(.harvested != true and (.type | test("^(implement|repair|review|rereview|land)$"))) | [.unit, .pid, .log] | @tsv' "$WORKERS" 2>/dev/null | while IFS=$'\t' read -r wunit wpid wlog; do
    [[ "$wpid" =~ ^[0-9]+$ ]] && alive "$wpid" || continue
    mt="$(stat -c %Y "$SUP/$wlog" 2>/dev/null || true)"
    if [[ "$mt" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - mt > slow_min * 60 )); then echo "$wunit"; fi
  done || true)"
  for id in $widened; do
    case " $offenders " in *" $id "*) ;; *) offenders="$offenders $id" ;; esac
  done
  for id in $offenders; do
    named_count=$((named_count + 1))
    w="$(jqf -c --arg unit "$id" '[.workers[] | select(.unit==$unit and .harvested != true)] | sort_by(.started) | last // empty' "$WORKERS")"
    if [[ -z "$w" ]]; then
      no_live_worker=$((no_live_worker + 1))
      continue
    fi
    pid="$(jqf -r .pid <<<"$w")"; wtype="$(jqf -r .type <<<"$w")"
    if ! [[ "$wtype" =~ ^(implement|repair|review|rereview|land)$ ]] || ! alive "$pid"; then
      no_live_worker=$((no_live_worker + 1))
      continue
    fi
    live_count=$((live_count + 1))
    probe="$(unit_field "$id" '.stuck_probe // empty')"
    fp="$(stuck_worker_progress_fp "$w")"
    if [[ -n "$probe" && "$(jqf -r .fp <<<"$probe")" == "$fp" ]]; then
      held=$(( NOW_EPOCH - $(ap_iso_epoch "$(jqf -r .at <<<"$probe")") ))
      if (( held < STUCK_CONFIRM_MINUTES * 60 )); then
        unchanged_window=$((unchanged_window + 1))
        continue
      fi
      unchanged_confirmed=$((unchanged_confirmed + 1))
      stuck_worker_stop "$pid"
      killed_count=$((killed_count + 1))
      jqf --argjson pid "$pid" --arg unit "$id" --arg finished "$STAMP" \
        '(.workers[] |= (if .pid==$pid and .unit==$unit and .harvested != true then (.harvested=true | .finished_at=$finished | .stuck_killed=true) else . end))' \
        "$WORKERS" | write_state "$WORKERS"
      kills=$(( $(unit_retries "$id" stuck-killed) + 1 ))
      if (( kills >= 2 )); then
        # 第 2 次卡住走 #4363（f6）的止损路由：原票经 hold.sh 自动 on-hold（24h）附原因，
        # 单元转 supervisor 裁决（#4369）；裁决后重新给满额度。
        issue="$(unit_field "$id" '.issue // empty')"
        hold_ok=1
        if [[ -n "$issue" ]]; then
          hold_cli="${ZF_ENGINE_DIR:-$ROOT/engine}/hold.sh"
          [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
          if ! bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss \
            --release 'supervisor rules on the stuck stop-loss escalation; requeue or approve refills the budget' \
            --expires 24h --kind stop-loss >/dev/null 2>&1; then
            hold_ok=0
            echo "[$STAMP] STUCK-HOLD-FAILED unit=$id issue=$issue episode=$kills" >> "$A/alerts/events.md"
            say "STUCK-HOLD-FAILED unit=$id issue=$issue episode=$kills"
          else
            gh issue comment "$issue" --body "卡住止损（#4371→#4363）：这张票的单元 $id 第 $kills 次无进展卡住，worker 已停止；自动搁置（on-hold，24h 后未裁决自动恢复），单元转 supervisor 裁决。" >/dev/null 2>&1 || true
          fi
        else
          hold_ok=0
          echo "[$STAMP] STUCK-HOLD-FAILED unit=$id issue=missing episode=$kills" >> "$A/alerts/events.md"
        fi
        if (( hold_ok )); then
          to_supervisor "$id" "stuck stop-loss: episode $kills with no progress; the issue is held on-hold" \
            'Held after the second no-progress stuck episode; supervisor decides rescope, split, or requeue' \
            'the unit was stopped twice with an unchanged progress fingerprint (f8 wip-age signal)' \
            "stuck episodes: $kills, last one no-progress $((held/60))min" \
            '["Requeue another worker round at the same scope"]'
        else
          to_supervisor "$id" "stuck stop-loss: episode $kills with no progress; hold could not be applied" \
            'The unit is parked for supervisor arbitration; apply the issue hold before resuming it' \
            'the unit was stopped twice with an unchanged progress fingerprint (f8 wip-age signal)' \
            "stuck episodes: $kills, last one no-progress $((held/60))min" \
            '["Requeue another worker round at the same scope"]'
        fi
        set_unit "$id" "$(hist stuck-killed "no progress $((held/60))min; episode $kills") | $(hist stuck-stoploss "episode $kills") | del(.stuck_probe)"
        echo "[$STAMP] STUCK-STOPLOSS unit=$id pid=$pid type=$wtype episode=$kills no-progress=$((held/60))min" >> "$A/alerts/events.md"
        say "STUCK-STOPLOSS unit=$id pid=$pid episode=$kills"
      else
        if [[ "$wtype" == land ]]; then next="ready-to-merge"; else next="${wtype}-pending"; fi
        set_unit "$id" "$(hist stuck-killed "no progress $((held/60))min; episode $kills") | .stage=\"$next\" | del(.stuck_probe)"
        echo "[$STAMP] STUCK-KILL unit=$id pid=$pid type=$wtype → $next (f8 wip-age, no progress $((held/60))min)" >> "$A/alerts/events.md"
        say "STUCK-KILL pid=$pid unit=$id type=$wtype → $next"
      fi
    elif [[ -z "$probe" || "$(jqf -r .fp <<<"$probe")" != "$fp" ]]; then
      # 有进展（指纹变了）或首次探测：刷新探针时间戳，长任务因此不会被停。
      if [[ -z "$probe" ]]; then first_seen=$((first_seen + 1)); else progress=$((progress + 1)); fi
      set_unit "$id" ".stuck_probe={at:\"$STAMP\",fp:$(js "$fp")}"
    fi
  done
  # 信号恢复或单元离开超龄名单：清掉旧探针，下一次卡住从新指纹起算。
  for id in $(jqf -r '.units[] | select(.stuck_probe != null) | .id' "$UNITS"); do
    case " $offenders " in *" $id "*) ;; *) set_unit "$id" 'del(.stuck_probe)' ;; esac
  done
  if (( signal_active )) || [[ -n "$widened" ]]; then
    action=no-kill
    (( killed_count == 0 )) || action=kill
    say "STUCK-DECISION named=$named_count live=$live_count fingerprint=first-seen:$first_seen,progress:$progress,unchanged-window:$unchanged_window,unchanged-confirmed:$unchanged_confirmed,no-live-worker:$no_live_worker action=$action killed=$killed_count"
  fi
}
