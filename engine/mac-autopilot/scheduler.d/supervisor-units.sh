# Supervisor unit arbitration and escalation helpers.

supervisor_requeue_repair_route() { # unit-json guidance → target<TAB>jq update for a supervisor repair requeue
  local u="$1" route="" head="" target=repair-pending extra
  extra=" | .repair_hint=$(js "$2")"
  read -r route head <<<"$(no_finding_repair_route "$u")" || true
  case "$route" in
    ready-to-merge) target=ready-to-merge; extra=" | .approved_sha=$(js "$head") | .repair_hint=null" ;;
    review-pending) target=review-pending; extra=' | .reviewed_sha=null | .reviewed_pr_head=null | .repair_hint=null' ;;
  esac
  printf '%s\t%s\n' "$target" "$extra"
}

supervisor_return_stage() { # unit-json [stage-before-supervisor] → pending stage for a RULE decision
  local u="$1" stage="${2:-}"
  [[ -n "$stage" ]] || stage="$(jqf -r '.stage // empty' <<<"$u")"
  if [[ -n "$(jqf -r '.handoff_integration_sha // empty' <<<"$u")" && -z "$(jqf -r '.handoff_delivery_verified_sha // empty' <<<"$u")" && "$(jqf -r '.pr // empty' <<<"$u")" =~ ^[0-9]+$ ]]; then printf 'repair-pending\n'; return 0; fi
  case "$stage" in
    implement-pending|repair-pending|review-pending|rereview-pending) printf '%s\n' "$stage" ;;
    implement|repair|review|rereview) printf '%s-pending\n' "$stage" ;;
    blocked-external)
      local resume
      resume="$(jqf -r '.blocked_resume_stage // empty' <<<"$u")"
      if [[ "$resume" =~ ^(implement|repair|review|rereview)-pending$ ]]; then printf '%s\n' "$resume"
      elif last_review_blocked "$u"; then printf 'review-pending\n'
      elif [[ -n "$(jqf -r '.pr // empty' <<<"$u")" ]]; then printf 'repair-pending\n'
      else printf 'implement-pending\n'; fi ;;
    *)
      if last_review_blocked "$u"; then printf 'review-pending\n'
      elif [[ -n "$(jqf -r '.pr // empty' <<<"$u")" ]]; then printf 'repair-pending\n'
      elif [[ -n "$(jqf -r '.task // empty' <<<"$u")" && -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; then printf 'implement-pending\n'
      else printf 'review-pending\n'; fi ;;
  esac
}

# #4369：supervisor-review 不再等人。第 1、2 次升级派一个裁决 worker（terra，见 dispatch_supervisor_arbiters）；
# 用尽后 needs-info 是唯一回到人的出口。entries 数两种历史标记：to_supervisor 的 supervisor-escalated
# 与合并车道门禁直接写的 supervisor-review（2288/2315 一带）。
# 人工交接（"handed to <session> ..."）不是失败，不计数：10-28 解除 PAUSE 后它们让 4 个单元直接触顶转 needs-info。
supervisor_entries() { # id → 该单元进入 supervisor-review 的历史次数
  jqf -r --arg id "$1" '[.units[] | select(.id==$id) | (.history // []) | (to_entries | map(select(.value.stage=="supervisor-arbiter-round") | .key) | max // -1) as $r | .[$r+1:][] | select((.stage=="supervisor-escalated" or .stage=="supervisor-review") and ((.result // "") | startswith("handed to ") | not))] | length' "$UNITS"
}

supervisor_needs_info_question() { # unit-json → 没有裁决报告时的模板澄清问题
  local reasons
  reasons="$(jqf -r '[(.history // [])[] | select(.stage=="supervisor-escalated" or .stage=="supervisor-review") | .result // empty] | .[-3:] | map(select(length > 0)) | join("；")' <<<"$1" | head -c 600)"
  printf '工作单元 %s 多次升级到工厂 supervisor 后仍无法自动裁决（最近原因：%s）。请给出一个决定：按什么方向继续、搁置，还是关闭？' \
    "$(jqf -r .id <<<"$1")" "${reasons:-记录里没有升级原因}"
}

# 预算用尽是流程问题，不是需求问题：10-28 解除 PAUSE 后它向维护者发了 6 个「继续、搁置还是关闭」的通用问题，
# 每个都由 agent 自己就能定（已合入、有待修 P1、交接人不在）。只有裁决 worker 判定的 needs-info 才问人。
supervisor_budget_park() { # id evidence → parked，留给 supervisor，不发评论
  local id="$1" evidence="$2" decision="${3:-null}" reason="${4:-supervisor budget exhausted}" stage="${5:-supervisor-budget-park}" note parked_as=supervisor-budget unpark='a supervisor decision'
  note="$(js "$reason: $evidence")"
  [[ "$evidence" != 'ticket stop-loss'* ]] || { parked_as=ticket-stop-loss; unpark='the issue changes or the ticket budget is raised'; }
  cap_set_unit "$id" park "$reason: $evidence" "" "$(hist "$stage" "$evidence" "$decision") | .stage=\"parked\" | .note=$note | $(park_fields "$parked_as" "$unpark")" \
    && say "supervisor budget-park unit=$1: $2"
}

# RECUT cannot finish over unpushed work, so triaging the same head again only spends a run: 148 of 625 dispatches on 11-06.
supervisor_recut_refuse() { # id evidence decision worktree [resume-work]
  local id="$1" evidence="$2" decision="$3" wt="$4" resume_work="${5:-false}" head note u resumed runs
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  note="RECUT refused: unpushed work at ${head:0:12}. Unparks when that head changes or the worktree is gone."
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  resumed="$(jqf -r '.recut_refused_resume_head // empty' <<<"$u")"
  runs="$(jqf -r '[.history[]? | select(.stage=="supervisor-arbiter")] | length' <<<"$u")"
  if [[ "$resume_work" == true && "$resumed" != "$head" && "$runs" =~ ^[0-9]+$ ]] \
    && (( runs < SUPERVISOR_ARBITER_UNIT_CAP )); then
    supervisor_recut_refused_resume "$id" "$head" "$evidence" "$decision"
    return $?
  fi
  cap_set_unit "$id" park "$note $evidence" "" "$(hist supervisor-recut-refused "$evidence" "$decision") | .stage=\"parked\" | .parked_reason=\"recut-refused-unpushed\" | .unpark_condition=\"the unit head changes\" | .recut_refused_head=$(js "$head") | .recut_refused_verdict=\"RECUT\" | .note=$(js "$note $evidence")" \
    || return 1
  say "supervisor recut refused unit=$id head=${head:0:12}: unpushed work"
}

supervisor_recut_refused_resume() { # id head evidence [decision] → let the existing worker publish the work before another RECUT
  local id="$1" head="$2" evidence="$3" decision="${4:-null}" u pr stage hint note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  pr="$(jqf -r '.pr // empty' <<<"$u")"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    stage=repair-pending
    hint="Preserve the existing unpushed work, commit and push the new head, then retry the refused RECUT."
  else
    stage=implement-pending
    hint="Preserve the existing unpushed work, finish and push it, then retry the refused RECUT."
  fi
  note="RECUT refused because existing work at ${head:0:12} is unpushed. Resume it and publish the resulting head before another RECUT attempt. $evidence"
  cap_set_unit "$id" "resume existing work" "$note" "" \
    "$(hist supervisor-recut-refused "$evidence" "$decision") | $(hist supervisor-recut-resume "$head") | .stage=$(js "$stage") | .note=$(js "$note") | .recut_refused_head=$(js "$head") | .recut_refused_verdict=\"RECUT\" | .recut_refused_resume_head=$(js "$head") | .repair_hint=$(js "$hint") | del(.parked_reason,.unpark_condition)" \
    || return 1
  say "supervisor recut refusal unit=$id head=${head:0:12}: resumed $stage to publish existing work"
}

supervisor_recut_refused_hold() { # unit-json → 0 while the refused head is unchanged; resume it once while arbitration budget remains
  local id refused d resumed
  [[ "$(jqf -r '.parked_reason // empty' <<<"$1")" == recut-refused-unpushed ]] || return 1
  id="$(jqf -r .id <<<"$1")"; refused="$(jqf -r '.recut_refused_head // empty' <<<"$1")"
  resumed="$(jqf -r '.recut_refused_resume_head // empty' <<<"$1")"
  [[ -n "$refused" ]] || return 1
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do
    [[ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" == "$refused" ]] || continue
    if [[ "$resumed" != "$refused" ]] && (( "$(jqf -r '[.history[]? | select(.stage=="supervisor-arbiter")] | length' <<<"$1")" < SUPERVISOR_ARBITER_UNIT_CAP )); then
      supervisor_recut_refused_resume "$id" "$refused" "legacy RECUT refusal has unchanged unpushed work" || return 1
    fi
    return 0
  done
  return 1
}

# A stop for any verdict: no unit may spend more than this many arbitration runs in 24h.
# 触顶不再是「停一天、只告警」：调用方（dispatch_supervisor_arbiters）当拍转 supervisor_cap_default，
# 这个单元的仲裁就此结束；这里只留计数与日内触顶标记，不通知 founder。默认 unit_cap(4) < daily_max(6) 时终身上限先触发，
# 本上限只保护把 unit_cap 配得比 daily_max_per_unit 大的部署。
supervisor_arbiter_over_daily_max() { # unit-json → 0 at the ceiling; one marker per unit and day
  local id count day
  count="$(jqf -r --argjson since "$(($(date +%s) - 86400))" '[(.history // [])[] | select(.stage == "supervisor-arbiter")
    | select((((.at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0) >= $since)] | length' <<<"$1")"
  (( count >= SUPERVISOR_ARBITER_DAILY_MAX )) || return 1
  id="$(jqf -r .id <<<"$1")"; day="${STAMP%%T*}"
  [[ "$(jqf -r '.arbiter_daily_max_alerted // empty' <<<"$1")" != "$day" ]] || return 0
  set_unit "$id" ".arbiter_daily_max_alerted=$(js "$day")"
  return 0
}

# 终身仲裁上限（supervisor_arbiter.unit_cap，默认 4）：按整份历史数 supervisor-arbiter 事件。
# supervisor-arbiter-round 轮标记会清零两轮预算的计数（RULE 重排后单元反复触顶回到 cap triage：
# 7 天里 345 次 supervisor-cap-triage-park、221 次 supervisor-cap-founder），所以这里是终身计数，不看轮标记。
supervisor_arbiter_lifetime_runs() { # unit-json → supervisor-arbiter 事件数
  jqf -r '[(.history // [])[] | select(.stage == "supervisor-arbiter")] | length' <<<"$1"
}

# 触顶默认决定：不派模型、不去 founder、不等人，也绝不自己关 issue 或 PR（head 2026-11-07：
# 看运行次数不能关掉真实缺陷）。分支：
# a. issue 已关闭/结论/进发布/成 tracker，或工作已在别处合入 → 既有 obsolete 词汇只关单元；
# b. 最近一次有效终局裁决是 RECUT，或该单元从未走过 recut → 既有 recut 路线一次，不关 PR：单元有 PR 时改为停车；
# c. 其余 → 停车，只记录原因。
# on-hold 的 issue 不给默认决定：hold 结束后下一拍再判；issue 状态读不出来也不判。派发仍被硬上限挡住。
# 每个停留只执行一次：历史里已有 supervisor-cap-default 且单元不在 supervisor-review（默认决定之后才重新进入）就直接返回。
supervisor_cap_default_issue() { # unit-json → linked issue, canonical id/branch, or PR issue number
  local issue id branch pr
  issue="$(jqf -r '.issue // empty' <<<"$1")"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] && { printf '%s\n' "$issue"; return 0; }
  id="$(jqf -r '.id // empty' <<<"$1")"
  if [[ "$id" =~ ^issue-([1-9][0-9]*)(-|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  branch="$(jqf -r '.branch // empty' <<<"$1")"
  if [[ "$branch" =~ ^agent/(auto-)?issue-([1-9][0-9]*)(-|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"; return 0
  fi
  return 1
}

supervisor_cap_default() { # id unit-json [lifetime|daily|repeat|stop-loss] [budget] → 0 当该单元已有、刚得到或暂不该有默认决定
  local id="$1" u="$2" trigger="${3:-lifetime}" issue pr raw state="" pr_state="" delivered=false verdict recut_done branch reason decision limit_reason tag="supervisor cap default" current_issue current_pr current_stage
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$u" && "$u" != null ]] || return 1
  # stop-loss：止损遇到同一失败（stop_loss_same_failure）不派 arbiter，用止损自己的 park/recut 阶段：cap-triage-park 会被 arbiter 清扫成一次模型 cap triage。
  local park_stage=supervisor-cap-triage-park recut_stage=supervisor-cap-triage-recut
  [[ "$trigger" != stop-loss ]] || { park_stage=supervisor-budget-park; recut_stage=supervisor-budget-recut; }
  # repeat：同一原因的第二次仲裁（supervisor_repeat_arbitration）走同一条路线，但不占「每单元一次」的终身默认决定，
  # 也不追加 supervisor-cap-default 事件；路线自己的事件（recut/park/obsolete）以 "supervisor repeat guard:" 开头，供 supervisor.repeat_guard_24h 计数。
  [[ "$trigger" == repeat ]] && tag="supervisor repeat guard"
  # A default always leaves the unit parked or closed, so a capped unit found at supervisor-review that already has one re-entered after it
  # (CI, stop-loss, hold lift): it gets the route again. Skipping it left it with no arbiter run and no exit (row 150, issue-4879).
  local reentered=false
  [[ "$trigger" =~ ^(lifetime|daily)$ && "$(jqf -r '.stage // empty' <<<"$u")" == supervisor-review ]] && reentered=true
  # A stop-loss park that was requeued by its timed retry (.stop_loss_timed_requeue) gets one more default decision: the second same failure parks again.
  [[ "$trigger" == repeat || "$reentered" == true ]] || { jqf -e --argjson limit "$([[ "$trigger" == stop-loss ]] && [[ "$(jqf -r '.stop_loss_timed_requeue // empty' <<<"$u")" == true ]] && echo 2 || echo 1)" \
    '[(.history // [])[]? | select(.stage == "supervisor-cap-default")] | length >= $limit' <<<"$u" >/dev/null && return 0; }
  issue="$(supervisor_cap_default_issue "$u" || true)"; pr="$(jqf -r '.pr // empty' <<<"$u")"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    raw="$(scheduler_issue_state "$issue" 2>/dev/null)" || return 1
    state="$(jqf -r '.state // empty' <<<"$raw")" || return 1
  fi
  [[ "$state" != on-hold ]] || return 0
  if [[ "$trigger" == daily ]]; then
    limit_reason="24-hour arbitration ceiling ($SUPERVISOR_ARBITER_DAILY_MAX dispatches) reached"
  elif [[ "$trigger" == repeat ]]; then
    limit_reason="the same escalation reason came back with no delivery, approval, merge or new PR head since the last arbitration"
  elif [[ "$trigger" == stop-loss ]]; then
    limit_reason="stop-loss same failure (${4:-budget reached}): the failure in front of the unit repeats an earlier round, and an arbiter requeue delivered 0 of 4 in that case"
  else
    limit_reason="arbitration cap ($SUPERVISOR_ARBITER_UNIT_CAP lifetime dispatches) reached"
  fi
  decision="$(decision_entry "${tag^}" "unit $id: $limit_reason" "supervisor-arbiter history events" '[]' scheduler)"
  [[ "$state" =~ ^(closed|awaiting-release|released|concluded|tracker)$ ]] && delivered=true
  # merge-reverted 在 merged 之后意味着交付已被撤回：那不是「已交付」，不进分支 a。
  [[ "$(jqf -r '[(.history // [])[] | select(.stage == "merged" or .stage == "landed" or .stage == "merge-reverted") | .stage] | last // ""' <<<"$u")" =~ ^(merged|landed)$ ]] && delivered=true
  if [[ "$delivered" != true && "$pr" =~ ^[0-9]+$ ]]; then
    pr_state="$(tick_pr_state "$pr" 2>/dev/null || true)"
    [[ "$pr_state" == MERGED ]] && delivered=true
  fi
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$u" && "$u" != null ]] || return 1
  current_issue="$(supervisor_cap_default_issue "$u" || true)"
  current_pr="$(jqf -r '.pr // empty' <<<"$u")"
  [[ "$current_issue" == "$issue" && "$current_pr" == "$pr" ]] || return 1
  if [[ "$trigger" =~ ^(lifetime|daily|repeat)$ ]]; then
    current_stage="$(jqf -r '.stage // empty' <<<"$u")"
    [[ "$current_stage" == supervisor-review || "$current_stage" == parked ]] || return 0
  fi
  delivered=false
  [[ "$state" =~ ^(closed|awaiting-release|released|concluded|tracker)$ ]] && delivered=true
  [[ "$(jqf -r '[(.history // [])[] | select(.stage == "merged" or .stage == "landed" or .stage == "merge-reverted") | .stage] | last // ""' <<<"$u")" =~ ^(merged|landed)$ ]] && delivered=true
  if [[ "$delivered" != true && "$pr_state" == MERGED ]]; then delivered=true; fi
  verdict="$(jqf -r '.supervisor_cap_verdict // .recut_refused_verdict // ""' <<<"$u")" || verdict=""
  recut_done="$(jqf -r 'any((.history // [])[]?; .stage == "supervisor-budget-recut" or .stage == "supervisor-cap-triage-recut") or .recut_routed == true' <<<"$u")"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]] \
    && jqf -e '(.hold.kind == "guarded-recut-repeat") or ((try (.recut_refused_at | fromdateiso8601) catch 0) >= now - 604800)' <<<"$raw" >/dev/null; then
    recut_done=true
  fi
  if [[ "$delivered" == true ]]; then
    branch=obsolete
    reason="issue state ${state:-unknown} or the work is already merged elsewhere"
    [[ "$trigger" != repeat ]] || reason="$tag: $reason"
    cap_set_unit "$id" obsolete "$reason" "" "$(hist obsolete "$reason") | .stage=\"closed\" | .note=$(js "obsolete: $reason") | del(.parked_reason)" || return 1
  elif [[ "$verdict" == RECUT || "$recut_done" != true ]]; then
    reason="$limit_reason; recut the unit once"
    supervisor_budget_recut "$id" "$tag: $reason" "$decision" \
      "$tag could not complete the recut route" "$tag recut" \
      "$park_stage" "$recut_stage" false || return 1
    branch=park
    [[ "$(unit_field "$id" '.stage')" != closed ]] || branch=recut
  else
    branch=park
    reason="$limit_reason; recut already tried and last cap verdict (${verdict:-none}) did not converge"
    supervisor_budget_park "$id" "$tag: $reason" "$decision" \
      "$tag stopped arbitration" "$park_stage" || return 1
  fi
  [[ "$trigger" != repeat ]] || { say "supervisor repeat guard unit=$id branch=$branch"; return 0; }
  cap_set_unit "$id" supervisor-cap-default "branch=$branch: $reason" "" \
    "$(hist supervisor-cap-default "branch=$branch: $reason" "$decision")" || return 1
  say "supervisor cap default unit=$id branch=$branch trigger=$trigger"
}

supervisor_arbiter_mark() { # unit-json → what must differ before another run: head, issue state, ruling count
  local issue state=""
  issue="$(jqf -r '.issue // empty' <<<"$1")"
  [[ -z "$issue" ]] || state="$(scheduler_issue_state "$issue" 2>/dev/null | jqf -r '.state // empty')" || state=""
  jqf -r --arg state "$state" "[(.reviewed_pr_head // .reviewed_sha // \"\"), \$state, ($(cto_rulings_norm) | length | tostring)] | join(\"|\")" <<<"$1"
}

supervisor_arbiter_no_change_hold() { # unit-json → 0 when a past run left it here and nothing changed: another run would repeat that one
  local id mark u
  id="$(jqf -r .id <<<"$1")"
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$u" && "$(jqf -r '.stage // empty' <<<"$u")" == supervisor-review ]] || return 1
  [[ -n "$(jqf -r '.arbiter_left_mark // empty' <<<"$u")" ]] || return 1
  mark="$(supervisor_arbiter_mark "$u")"
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$u" && "$(jqf -r '.stage // empty' <<<"$u")" == supervisor-review ]] || return 1
  [[ "$mark" == "$(jqf -r .arbiter_left_mark <<<"$u")" ]] || return 1
  # Applied decisions write supervisor-* history; a trailing dispatch alone never applied one.
  if jqf -e '((.history // [])[-1].stage // "") == "supervisor-arbiter"' <<<"$u" >/dev/null; then
    set_unit "$id" 'del(.arbiter_left_mark)'
    say "supervisor arbitration retry unit=$id: last history entry is dispatch only"
    return 1
  fi
  say "supervisor arbitration held unit=$id: no head, state or ruling change since its last run"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "arbiter-no-change:$id:$mark" \
    "arbiter-no-change unit=$id: its last run left it at supervisor-review; held until head, state or ruling changes") \
    || say "arbitration hold unit=$id: escalation not delivered"
  return 0
}

# 0 when this escalation has the same reason (digits and SHAs normalised) as the one the unit's previous arbiter run answered, and
# none of the progress events came between that run and now: another run would only repeat that requeue (29 of 93 dispatches on 11-07).
supervisor_repeat_arbitration() { # unit-json → 0 for a repeat
  jqf -e --arg progress "$SUPERVISOR_PROGRESS_RE" '
    def st: .stage // .event // .ev // "";
    def norm: (. // "") | tostring | gsub("\\b(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\\b"; "N") | gsub("[0-9]+"; "N") | gsub("\\s+"; " ");
    (.history // []) as $h
    | [$h | to_entries[] | select(.value | st | IN("supervisor-escalated", "supervisor-review")) | .key] as $es
    | ([$h | to_entries[] | select(.value | st == "supervisor-arbiter") | .key] | last) as $p
    | ($es | last) as $e
    | if $e == null or $p == null or $p > $e then false
      else ([$es[] | select(. < $p)] | last) as $pe
        | ($h[$e].result | norm) as $r
        | $pe != null and $r != "" and ($h[$pe].result | norm) == $r
          and all($h[$p + 1:][]; (st | test($progress)) | not)
      end' <<<"$1" >/dev/null
}

supervisor_arbiter_record_left() { # unit: only a decision that left it here holds it; a unit a later stop returns here runs again
  local u
  u="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  if [[ "$(jqf -r '.stage // empty' <<<"$u")" == supervisor-review ]]; then
    set_unit "$1" ".arbiter_left_mark=$(js "$(supervisor_arbiter_mark "$u")")"
  else
    set_unit "$1" 'del(.arbiter_left_mark)'
  fi
}

supervisor_founder_question_names_fact() { # question text
  [[ -n "${1//[[:space:]]/}" && "$1" == *[?？]* ]] || return 1
  ! grep -Eiq "$SUPERVISOR_FOUNDER_GENERIC_RE" <<<"$1"
}

supervisor_cap_parked_unit() { # unit-json → whether this is a retryable arbitration-cap park (including legacy parks)
  if [[ "$(jqf -r '.stage + "|" + (.parked_reason // "")' <<<"$1")" == parked\|supervisor-cap-founder ]]; then
    [[ -z "$(jqf -r '.supervisor_cap_retry // empty' <<<"$1")" ]] || return 1
    ! supervisor_founder_question_names_fact "$(jqf -r '.supervisor_cap_question // ""' <<<"$1")"
    return
  fi
  jqf -e --arg cap_park_result_re "$SUPERVISOR_CAP_PARK_RESULT_RE" '
    .stage == "parked" and .parked_reason != "supervisor-cap-exhausted" and (
      .parked_reason == "supervisor-arbitration-cap" or
      .parked_reason == "supervisor-cap-triage-reask" or
      .parked_reason == "recut-refused-unpushed" or
      .parked_reason == "repair-breaker" or
      any((.history // [])[]?; .stage == "supervisor-budget-park" and
        ((.result // "") | test($cap_park_result_re))) or
      any((.history // [])[]?; .stage == "supervisor-cap-triage-park")
    )
  ' <<<"$1" >/dev/null
}

supervisor_cap_triage_park() { # id evidence → durable retry marker swept by the cap-triage dispatcher
  local id="$1" evidence="$2" decision="$3" return_stage u note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  return_stage="$(jqf -r '.supervisor_cap_return_stage // empty' <<<"$u")"
  [[ -n "$return_stage" ]] || return_stage="$(supervisor_return_stage "$u")"
  note="supervisor arbitration cap triage pending: $evidence"
  cap_set_unit "$id" park "$note" "" "$(hist supervisor-cap-triage-park "$evidence" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-arbitration-cap\" | .unpark_condition=\"a cap triage verdict\" | .supervisor_cap_return_stage=$(js "$return_stage") | .note=$(js "$note")" \
    && say "supervisor cap-triage parked unit=$id: $evidence"
}

# 轮数或墙钟止损已用尽且仍没有 PR：交给 recut 拆成可交付的子票。
# 走 lib.sh 唯一的 needs-recut 入口 route_to_recut；cap triage 遇到未推送改动时先让原单元继续提交，触顶默认仍停放。
supervisor_budget_recut() { # id evidence decision park-reason recut-reason park-stage recut-stage allow-pr-close dead-park-salvage
  local id="$1" evidence="$2" decision="${3:-null}" park_reason="${4:-supervisor budget exhausted}"
  local recut_reason="${5:-ticket stop-loss reached}" park_stage="${6:-supervisor-budget-park}" recut_stage="${7:-supervisor-budget-recut}"
  local allow_pr_close="${8:-false}" dead_park_salvage="${9:-false}" issue pr err note pr_comment pr_state issue_state salvage_refs salvage_error salvage_refs_all=""
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  local d
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do # cleanup_tick 删的两个位置；stash 是 ensure_clone 收起的未提交进度
    if [[ -d "$d" && "$dead_park_salvage" == true && "$park_stage" == supervisor-budget-park && "$recut_stage" == supervisor-budget-recut ]]; then
      err="$(git -C "$d" fetch -q --prune origin 2>&1)" || { supervisor_budget_park "$id" "$evidence (worktree origin ref refresh failed: ${err:0:200})" "$decision" "$park_reason" "$park_stage"; return 0; }
    fi
    if [[ -d "$d" ]] && { [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || [[ -n "$(git -C "$d" stash list 2>/dev/null)" ]] \
        || [[ -z "$(git -C "$d" branch -r --contains HEAD 2>/dev/null)" ]]; }; then
      if [[ "$park_stage" == supervisor-cap-triage-park ]]; then
        supervisor_recut_refuse "$id" "$evidence" "$decision" "$d" "$allow_pr_close"; return 0
      fi
      if [[ "$dead_park_salvage" == true && "$park_stage" == supervisor-budget-park && "$recut_stage" == supervisor-budget-recut ]]; then
        [[ -z "$salvage_refs_all" ]] || sleep 1
        if salvage_refs="$(dead_park_salvage_worktree "$id" "$d" 2>&1)"; then
          salvage_refs_all="${salvage_refs_all:+$salvage_refs_all,}$salvage_refs"
          continue
        fi
        salvage_error="${salvage_refs//$'\n'/ }"
        supervisor_budget_park "$id" "$evidence (worktree has unpushed work; salvage push failed: ${salvage_error:0:200})" "$decision" "$park_reason" "$park_stage"; return 0
      fi
      supervisor_budget_park "$id" "$evidence (worktree has unpushed work; not sent to recut)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  done
  [[ -z "$salvage_refs_all" ]] || dead_park_salvage_notice "$id" "$salvage_refs_all"
  [[ "$issue" =~ ^[0-9]+$ ]] || { supervisor_budget_park "$id" "$evidence" "$decision" "$park_reason" "$park_stage"; return 0; }
  if [[ -n "$pr" && "$allow_pr_close" != true ]]; then
    supervisor_budget_park "$id" "$evidence (unit already has PR #$pr)" "$decision" "$park_reason" "$park_stage"; return 0
  fi
  # Route first: a refused route must leave the PR open, or the slice has no owner. Once this unit's route created children, a close retry must bypass the permanent guard (#1167/#4840).
  if [[ "$(unit_field "$id" '.recut_routed // empty')" == true ]] \
      && issue_state="$(scheduler_issue_state "$issue" 2>/dev/null)" \
      && jqf -e 'type == "object" and has("recut_children")' <<<"$issue_state" >/dev/null 2>&1; then
    :
  elif ! err="$(scheduler_route_to_recut "$issue" 2>&1 >/dev/null)"; then
    if [[ "$park_stage" == supervisor-cap-triage-park && ( "$err" == *'rate limit'* || "$err" == *'Resource limits'* ) ]]; then set_unit "$id" '.supervisor_cap_retry="pending"' || return 1; say "supervisor cap triage unit=$id: recut route rate-limited; stays at supervisor-review for a retry"; return 0; fi; supervisor_budget_park "$id" "$evidence (recut route failed: ${err:0:200})" "$decision" "$park_reason" "$park_stage"; return 0
  fi
  closed_unit_issue_route "$id" || { supervisor_budget_park "$id" "$evidence (tracker label reconciliation failed)" "$decision" "$park_reason" "$park_stage"; return 0; }
  if [[ -n "$pr" ]]; then
    set_unit "$id" '.recut_routed=true' || return 1
    pr_comment="Cap triage is sending issue #$issue to recut: $evidence"
    tick_prs_changed
    pr_state="$(tick_pr_state "$pr" 2>/dev/null || true)"
    if [[ "$pr_state" == CLOSED || "$pr_state" == MERGED ]]; then
      if ! gh pr comment "$pr" --body "$pr_comment" >/dev/null 2>&1; then
        supervisor_budget_park "$id" "$evidence (could not comment on PR #$pr after recut route)" "$decision" "$park_reason" "$park_stage"; return 0
      fi
    elif ! gh pr close "$pr" --comment "$pr_comment" >/dev/null 2>&1; then
      supervisor_budget_park "$id" "$evidence (could not close PR #$pr after recut route)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  fi
  if [[ -n "$pr" ]]; then
    note="$(js "$recut_reason; PR #$pr closed and issue #$issue sent to recut: $evidence")"
  else
    note="$(js "$recut_reason without a PR; issue #$issue sent to recut: $evidence")"
  fi
  cap_set_unit "$id" recut "$recut_reason: $evidence" "" "$(hist "$recut_stage" "$evidence" "$decision") | .stage=\"closed\" | .note=$note" \
    && say "supervisor budget-recut unit=$id issue=#$issue: $evidence"
}

supervisor_needs_info() { # id question evidence —— needs-info：给提需求的人发一个澄清问题并打标签（唯一回到人的出口）
  local id="$1" question="$2" evidence="$3" issue pr decision posted=no
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  if [[ "$issue" =~ ^[0-9]+$ ]]; then
    if ! scheduler_issue_transition_allowed "$issue" needs-info supervisor-needs-info; then
      decision="$(decision_entry 'Needs-info transition unavailable' "issue #$issue cannot transition to needs-info from its current state" "$evidence" '["Post the question without the needs-info label"]' supervisor)"
      set_unit "$id" "$(hist supervisor-park "needs-info transition unavailable for issue #$issue" "$decision") | .stage=\"parked\" | .note=$(js "needs-info question not posted: issue #$issue cannot transition to needs-info") | $(park_fields needs-info-unavailable 'the issue can move to needs-info')"
      say "supervisor needs-info unit=$id not posted=issue #$issue transition unavailable"
      return 0
    fi
    if gh issue comment "$issue" --body "工厂 supervisor 需要澄清：$question" >/dev/null 2>&1; then
      if ! scheduler_issue_transition "$issue" needs-info supervisor-needs-info; then
        posted="issue #$issue (question posted; needs-info transition failed)"
      else
        posted="issue #$issue"
      fi
    fi
  elif [[ "$pr" =~ ^[0-9]+$ ]] && gh pr comment "$pr" --body "工厂 supervisor 需要澄清：$question" >/dev/null 2>&1; then
    posted="PR #$pr"
  fi
  [[ "$posted" != no ]] || echo "[$STAMP] NEEDS-INFO-UNDELIVERED unit=$id no reachable issue/PR, question not posted: $question" >> "$A/alerts/state.md"
  decision="$(decision_entry 'Ask the requester one clarifying question' "$question" "$evidence" '["Escalate again without asking", "Arbitrate without the missing fact"]' supervisor)"
  set_unit "$id" "$(hist supervisor-needs-info "$question" "$decision") | .stage=\"needs-human\" | .note=$(js "needs-info: $question")"
  say "supervisor needs-info unit=$id posted=$posted"
}
