stuck_worker_disposition() {
  local scorecard="$A/node-health.json" bound offenders id w pid wtype probe fp held kills next issue hold_cli hold_ok cpu_now cpu_then
  local signal_active=0 named_count=0 live_count=0 killed_count=0
  local first_seen=0 progress=0 unchanged_window=0 unchanged_confirmed=0 no_live_worker=0 action
  local cap_worker cap_pid cap_unit cap_log cap_count cap_commands cap_summary cap_workdir cap_issue cap_branch cap_evidence cap_recut_ok cap_stash
  if [[ "$IMPLEMENT_COMMAND_CAP" =~ ^[0-9]+$ ]] && (( IMPLEMENT_COMMAND_CAP > 0 )); then
    while IFS= read -r cap_worker; do
      scheduler_lock_yield_between_units || return 1
      if [[ "${SCHEDULER_LOCK_YIELDED:-false}" == true ]]; then
        cap_pid="$(jqf -r '.pid // empty' <<<"$cap_worker")"; cap_unit="$(jqf -r '.unit // empty' <<<"$cap_worker")"
        cap_worker="$(jqf -c --argjson pid "$cap_pid" --arg unit "$cap_unit" '[.workers[] | select(.pid==$pid and .unit==$unit and .harvested!=true)][0] // empty' "$WORKERS")"
        [[ -n "$cap_worker" ]] || continue
      fi
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
      workers_update --argjson pid "$cap_pid" --arg unit "$cap_unit" --arg finished "$STAMP" \
        --argjson count "$cap_count" --argjson cap "$IMPLEMENT_COMMAND_CAP" \
        '(.workers[] |= (if .pid==$pid and .unit==$unit and .harvested != true then (.harvested=true | .finished_at=$finished | .implement_command_capped={count:$count,cap:$cap}) else . end))'
      cap_issue="$(unit_field "$cap_unit" '.issue // empty')"
      cap_branch="$(unit_field "$cap_unit" '.branch // empty')"
      cap_recut_ok=0
      if [[ -n "$cap_issue" ]]; then
        cap_evidence="$(jq -cn --argjson commands "$cap_count" --argjson limit "$IMPLEMENT_COMMAND_CAP" \
          --arg unit "$cap_unit" --arg branch "$cap_branch" --arg stash "$cap_stash" --arg workdir "$cap_workdir" \
          '{kind:"implement-command-cap",commands:$commands,limit:$limit,unit:$unit,branch:$branch,stash:$stash,workdir:$workdir}')"
        if scheduler_recut_route "$cap_issue" "$cap_evidence"; then
          if scheduler_issue_state "$cap_issue" | jq -e '.state == "needs-recut" or (.state == "on-hold" and (.size_admission | type == "object"))' >/dev/null; then
            cap_recut_ok=1
          fi
        fi
      fi
      if (( cap_recut_ok )); then
        set_unit "$cap_unit" "$(hist_blocked implement-command-cap '' implement-command-cap "$cap_count/$IMPLEMENT_COMMAND_CAP -> needs-recut") | .stage=\"blocked-external\" | .size_recut_pending=true | del(.stuck_probe)"
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
    scheduler_lock_yield_between_units || return 1
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
  # 把日志静默超过 WORKER_IDLE_KILL_MINUTES（默认 30，原为 slow_worker_minutes=60）的活 worker 也并入同一个探测输入，走同一条停止路径。
  local idle_min widened slow_worker wunit wlog mt
  idle_min="${WORKER_IDLE_KILL_MINUTES:-30}"; [[ "$idle_min" =~ ^[1-9][0-9]*$ ]] || idle_min=30
  widened=""
  while IFS= read -r slow_worker; do
    scheduler_lock_yield_between_units || return 1
    if [[ "${SCHEDULER_LOCK_YIELDED:-false}" == true ]]; then
      pid="$(jqf -r '.pid' <<<"$slow_worker")"; unit="$(jqf -r '.unit' <<<"$slow_worker")"
      slow_worker="$(jqf -c --argjson pid "$pid" --arg unit "$unit" '[.workers[] | select(.pid==$pid and .unit==$unit and .harvested!=true)][0] // empty' "$WORKERS")"
      [[ -n "$slow_worker" ]] || continue
    fi
    harvest_worker_alive "$slow_worker" || continue
    wunit="$(jqf -r '.unit' <<<"$slow_worker")"; wlog="$(jqf -r '.log' <<<"$slow_worker")"
    mt="$(stat -c %Y "$SUP/$wlog" 2>/dev/null || true)"
    if [[ "$mt" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - mt > idle_min * 60 )); then widened="${widened}${widened:+ }$wunit"; fi
  done < <(jqf -c '.workers[] | select(.harvested != true and (.type | test("^(implement|repair|review|rereview|land)$")))' "$WORKERS" 2>/dev/null)
  scheduler_lock_yield_between_units || return 1
  for id in $widened; do
    scheduler_lock_yield_between_units || return 1
    case " $offenders " in *" $id "*) ;; *) offenders="$offenders $id" ;; esac
  done
  scheduler_lock_yield_between_units || return 1
  for id in $offenders; do
    scheduler_lock_yield_between_units || return 1
    named_count=$((named_count + 1))
    w="$(jqf -c --arg unit "$id" '[.workers[] | select(.unit==$unit and .harvested != true)] | sort_by(.started) | last // empty' "$WORKERS")"
    if [[ -z "$w" ]]; then
      no_live_worker=$((no_live_worker + 1))
      continue
    fi
    pid="$(jqf -r .pid <<<"$w")"; wtype="$(jqf -r .type <<<"$w")"
    if ! [[ "$wtype" =~ ^(implement|repair|review|rereview|land)$ ]] || ! harvest_worker_alive "$w"; then
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
      cpu_now="$(worker_tree_busy_usec "$pid")"; cpu_then="$(jqf -r '.cpu // empty' <<<"$probe")" # silent but ≥1% CPU or memory stall in the window is working (a child build, or reclaim-throttled at MemoryHigh): keep, re-baseline
      if grep -qxF -- "$id" <<<"$widened" && [[ $cpu_now =~ ^[0-9]+$ && $cpu_then =~ ^[0-9]+$ ]] && (( (cpu_now - cpu_then) * 100 >= held * 1000000 )); then
        set_unit "$id" ".stuck_probe={at:\"$STAMP\",fp:$(js "$fp"),cpu:$cpu_now}"; unchanged_window=$((unchanged_window + 1)); continue
      fi
      unchanged_confirmed=$((unchanged_confirmed + 1))
      stuck_worker_stop "$pid" "$(jqf -r '.process_group // empty' <<<"$w")"
      killed_count=$((killed_count + 1))
      workers_update --argjson pid "$pid" --arg unit "$id" --arg finished "$STAMP" \
        '(.workers[] |= (if .pid==$pid and .unit==$unit and .harvested != true then (.harvested=true | .finished_at=$finished | .stuck_killed=true) else . end))'
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
      cpu_now="$(worker_tree_busy_usec "$pid")"; [[ $cpu_now =~ ^[0-9]+$ ]] || cpu_now=null
      set_unit "$id" ".stuck_probe={at:\"$STAMP\",fp:$(js "$fp"),cpu:$cpu_now}"
    fi
  done
  scheduler_lock_yield_between_units || return 1
  # 信号恢复或单元离开超龄名单：清掉旧探针，下一次卡住从新指纹起算。
  for id in $(jqf -r '.units[] | select(.stuck_probe != null) | .id' "$UNITS"); do
    scheduler_lock_yield_between_units || return 1
    if [[ "${SCHEDULER_LOCK_YIELDED:-false}" == true ]] \
      && ! jqf -e --arg id "$id" 'any(.units[]; .id==$id and .stuck_probe != null)' "$UNITS" >/dev/null; then
      continue
    fi
    case " $offenders " in *" $id "*) ;; *) set_unit "$id" 'del(.stuck_probe)' ;; esac
  done
  scheduler_lock_yield_between_units || return 1
  if (( signal_active )) || [[ -n "$widened" ]]; then
    action=no-kill
    (( killed_count == 0 )) || action=kill
    say "STUCK-DECISION named=$named_count live=$live_count fingerprint=first-seen:$first_seen,progress:$progress,unchanged-window:$unchanged_window,unchanged-confirmed:$unchanged_confirmed,no-live-worker:$no_live_worker action=$action killed=$killed_count"
  fi
}
