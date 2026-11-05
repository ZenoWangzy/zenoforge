
# PID 存活且确为 codex 进程（防 PID 复用把无关进程当活 worker）。
alive() { ps -p "$1" -o args= 2>/dev/null | grep -Eq 'codex|claude|zcode|zcode-cli|land-pr\.sh|precheck\.sh|cdp-browser-lease\.sh|decision-gate\.mjs'; }

set_unit() { # id jq_update_expression（.stage=... 等，可用 | 连接）
  local own_lock=false rc=0 started=$SECONDS elapsed old_stage="" new_stage=""
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    acquire_scheduler_lock_wait || return 1
    own_lock=true
  fi
  [[ "$2" == *".stage"* ]] && old_stage="$(unit_field "$1" '.stage')"
  jqf --arg id "$1" "(.units[] |= (if .id==\$id then ($2) else . end))" "$UNITS" | write_state "$UNITS" || rc=$?
  if [[ "$own_lock" == true ]]; then release_scheduler_lock; fi
  elapsed=$((SECONDS - started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail ledger_write unit=$1 secs=${elapsed}s"
  if (( rc == 0 )) && [[ -n "$old_stage" ]] && declare -F footprint_owner_transition >/dev/null; then
    new_stage="$(unit_field "$1" '.stage')" || new_stage=""
    footprint_owner_transition "$1" "$old_stage" "$new_stage" \
      || say "footprint wait cleanup failed owner=$1 stage=$new_stage"
  fi
  return "$rc"
}
# 终局裁决（cap triage）的落地统一走这里：set_unit 失败时绝不照旧记成功日志（11-03 pr-3575：RULE 的
# jqf rc=5 让整笔更新被丢，没有 history、没有裁决，下一行却仍打 "RULE -> repair-pending"，付费裁决丢失）。
# 失败记 NOT applied，决策文本追加进该单元的报告文件（显式路径或 .supervise_report；都没有时落 alerts），
# 单元留在原 stage，由 cap-triage 的重试标记（supervisor-arbitration-cap）下一拍重试。
cap_set_unit() { # id verb decision-text report-path jq_update_expression
  local id="$1" verb="$2" text="$3" rep="$4" keep
  if set_unit "$id" "$5"; then return 0; fi
  say "cap triage unit=$id: $verb NOT applied (set_unit failed)"
  keep="$rep"
  [[ -n "$keep" ]] || keep="$SUP/$(unit_field "$id" '.supervise_report // empty')"
  if [[ -n "$keep" && "$keep" != "$SUP/" && -d "${keep%/*}" ]]; then
    printf '\n[%s] cap triage unit=%s: %s NOT applied (set_unit failed); decision text kept:\n%s\n' \
      "$STAMP" "$id" "$verb" "$text" >> "$keep"
  else
    echo "[$STAMP] CAP-TRIAGE-DECISION-KEPT unit=$id verb=$verb: $text" >> "$A/alerts/state.md"
  fi
  return 1
}
units_update() { # jq args; transactionally update the unit ledger under the shared scheduler lock
  local own_lock=false rc=0
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    acquire_scheduler_lock_wait || return 1
    own_lock=true
  fi
  jqf "$@" "$UNITS" | write_state "$UNITS" || rc=$?
  if [[ "$own_lock" == true ]]; then release_scheduler_lock; fi
  return "$rc"
}
# A refused or failed parent label write for an issue without a unit would otherwise retry on every refill
# and log each time. Per-issue backoff lives in the ledger's top-level intake_parent_retry map.
intake_parent_retry_waiting() { # issue -> 0 while its next retry time has not come
  local now; now="$(date +%s)"
  jqf -e --arg n "$1" --argjson now "$now" '(.intake_parent_retry[$n].next_at // 0) > $now' "$UNITS" >/dev/null 2>&1
}
intake_parent_retry_failed() { # issue -> prints "<attempt> <delay-secs>" after recording the failure
  local now step; now="$(date +%s)"
  step="$(jqf -r --arg n "$1" '((.intake_parent_retry[$n].fails // 0) + 1) as $k | "\($k) \([300 * pow(2; ([$k - 1, 6] | min)), 21600] | min)"' "$UNITS")" || return 1
  units_update --arg n "$1" --argjson now "$now" --argjson k "${step% *}" --argjson d "${step#* }" \
    '.intake_parent_retry[$n] = {fails: $k, next_at: ($now + $d)}' || return 1
  printf '%s\n' "$step"
}
intake_parent_retry_clear() { # issue
  jqf -e --arg n "$1" '(.intake_parent_retry // {}) | has($n)' "$UNITS" >/dev/null 2>&1 || return 0
  units_update --arg n "$1" 'del(.intake_parent_retry[$n])'
}
unit_field() { jqf -r --arg id "$1" "[.units[] | select(.id==\$id) | ($2 // empty)][0] // empty" "$UNITS"; }
# hold_handoff_waiting outlives its hold when the issue leaves ready-for-agent (tracker, closed) with its episode unconsumed:
# register_new_issues clears the flag only for ready-for-agent rows, so such a unit never dispatches again.
handoff_wait_stale() { # unit id -> 0 after clearing the flag when no issue it waits on still has a live handoff episode
  local id="$1" n live rc
  [[ "$(unit_field "$id" '.hold_handoff_lookup_pending // false')" != true ]] || return 1
  while read -r n; do
    live="$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r 'select(.state == "ready-for-agent" and (.scheduler_handoff.episode // "") != "") | "live"' 2>/dev/null)" && rc=0 || rc=$?
    (( rc == 0 || rc == 64 )) && [[ -z "$live" ]] || return 1 # a live or unreadable state keeps the wait
  done < <(jqf -r --arg id "$id" '.units[] | select(.id == $id) | (.hold_handoff_wait_issues // [])[]' "$UNITS")
  units_update --arg id "$id" '.units |= map(if .id == $id then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end)' || return 1
  say "handoff wait cleared unit=$id: no issue it waited on has a live handoff episode"
}
unit_retries() { # unit stage → 历史里该 stage 出现次数
  jqf -r --arg id "$1" --arg st "$2" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage==$st)] | length' "$UNITS"
}
hist() {
  local entry
  entry="$(jqf -cn --arg stage "$1" --arg result "${2:-}" --arg at "$STAMP" --argjson decision "${3:-null}" \
    '{stage:$stage,result:$result,at:$at} + (if $decision == null then {} else {decision:$decision} end)')"
  echo ".history += [$entry]"
}
decision_entry() { # decision why evidence rejected-json owner -> history decision object
  jqf -cn --arg decision "$1" --arg why "$2" --arg evidence "$3" --argjson rejected "$4" --arg owner "$5" \
    '{decision:$decision,why:$why,evidence:$evidence,rejected:$rejected,owner:$owner}'
}
supervisor_return_stage() { # unit-json [stage-before-supervisor] → pending stage for a RULE decision
  local u="$1" stage="${2:-}"
  [[ -n "$stage" ]] || stage="$(jqf -r '.stage // empty' <<<"$u")"
  case "$stage" in
    implement-pending|repair-pending|review-pending|rereview-pending) printf '%s\n' "$stage" ;;
    implement) printf 'implement-pending\n' ;;
    repair) printf 'repair-pending\n' ;;
    review) printf 'review-pending\n' ;;
    rereview) printf 'rereview-pending\n' ;;
    blocked-external)
      local resume
      resume="$(jqf -r '.blocked_resume_stage // empty' <<<"$u")"
      if [[ "$resume" =~ ^(implement|repair|review|rereview)-pending$ ]]; then printf '%s\n' "$resume"
      elif [[ -n "$(jqf -r '.pr // empty' <<<"$u")" ]]; then printf 'repair-pending\n'
      else printf 'implement-pending\n'; fi ;;
    *)
      if [[ -n "$(jqf -r '.pr // empty' <<<"$u")" ]]; then printf 'repair-pending\n'
      elif [[ -n "$(jqf -r '.task // empty' <<<"$u")" && -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; then printf 'implement-pending\n'
      else printf 'review-pending\n'; fi ;;
  esac
}

to_supervisor() { # id note：升级到 supervisor；cap triage acts after the third entry
  local decision u return_stage
  u="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  return_stage="$(supervisor_return_stage "$u")"
  if [[ -n "${3:-}" ]]; then
    decision="$(decision_entry "$3" "$4" "$5" "$6" scheduler)"
  else
    decision="$(decision_entry 'Hand off to supervisor' "$2" "$2" '["Continue automated handling"]' scheduler)"
  fi
  set_unit "$1" "$(hist supervisor-escalated "$2" "$decision") | .stage=\"supervisor-review\" | .note=$(js "$2") | .supervisor_cap_return_stage=$(js "$return_stage")"
  say "supervisor-review unit=$1: $2"
  cancel_unit_runs "$1" "parked for the supervisor"
  if (( $(supervisor_entries "$1") >= 3 )); then
    if [[ "${SUPERVISOR_CAP_TRIAGE:-true}" == true ]]; then
      say "supervisor cap reached unit=$1: final cap triage queued"
    else
      supervisor_budget_park "$1" "third entry into supervisor-review; arbitration cap is 2 (#4369)"
    fi
  fi
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
  local id="$1" evidence="$2" decision="${3:-null}" reason="${4:-supervisor budget exhausted}" stage="${5:-supervisor-budget-park}" note
  note="$(js "$reason: $evidence")"
  cap_set_unit "$id" park "$reason: $evidence" "" "$(hist "$stage" "$evidence" "$decision") | .stage=\"parked\" | .note=$note" \
    && say "supervisor budget-park unit=$1: $2"
}

SUPERVISOR_CAP_PARK_RESULT_RE='^(third entry into supervisor-review; arbitration cap is 2|arbitration budget exhausted for )'

supervisor_cap_parked_unit() { # unit-json → whether this is a retryable arbitration-cap park (including legacy parks)
  jqf -e --arg cap_park_result_re "$SUPERVISOR_CAP_PARK_RESULT_RE" '
    .stage == "parked" and (
      .parked_reason == "supervisor-arbitration-cap" or
      .parked_reason == "supervisor-cap-triage-reask" or
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
  cap_set_unit "$id" park "$note" "" "$(hist supervisor-cap-triage-park "$evidence" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-arbitration-cap\" | .supervisor_cap_return_stage=$(js "$return_stage") | .note=$(js "$note")" \
    && say "supervisor cap-triage parked unit=$id: $evidence"
}

# 轮数或墙钟止损已用尽且仍没有 PR：交给 recut 拆成可交付的子票。
# 走 lib.sh 唯一的 needs-recut 入口 route_to_recut；有未提交、stash 或未推送改动时不关单元，照旧 park。
supervisor_budget_recut() { # id evidence decision park-reason recut-reason park-stage recut-stage allow-pr-close
  local id="$1" evidence="$2" decision="${3:-null}" park_reason="${4:-supervisor budget exhausted}"
  local recut_reason="${5:-ticket stop-loss reached}" park_stage="${6:-supervisor-budget-park}" recut_stage="${7:-supervisor-budget-recut}"
  local allow_pr_close="${8:-false}" issue pr err note pr_comment pr_state
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  local d
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do # cleanup_tick 删的两个位置；stash 是 ensure_clone 收起的未提交进度
    if [[ -d "$d" ]] && { [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || [[ -n "$(git -C "$d" stash list 2>/dev/null)" ]] \
        || [[ -z "$(git -C "$d" branch -r --contains HEAD 2>/dev/null)" ]]; }; then
      supervisor_budget_park "$id" "$evidence (worktree has unpushed work; not sent to recut)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  done
  [[ "$issue" =~ ^[0-9]+$ ]] || { supervisor_budget_park "$id" "$evidence" "$decision" "$park_reason" "$park_stage"; return 0; }
  if [[ -n "$pr" ]]; then
    if [[ "$allow_pr_close" != true ]]; then
      supervisor_budget_park "$id" "$evidence (unit already has PR #$pr)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
    pr_comment="Cap triage is sending issue #$issue to recut: $evidence"
    tick_prs_changed
    pr_state="$(tick_pr_state "$pr" 2>/dev/null || true)"
    if [[ "$pr_state" == CLOSED || "$pr_state" == MERGED ]]; then
      if ! gh pr comment "$pr" --body "$pr_comment" >/dev/null 2>&1; then
        supervisor_budget_park "$id" "$evidence (could not comment on PR #$pr before recut)" "$decision" "$park_reason" "$park_stage"; return 0
      fi
    elif ! gh pr close "$pr" --comment "$pr_comment" >/dev/null 2>&1; then
      supervisor_budget_park "$id" "$evidence (could not close PR #$pr before recut)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  fi
  if ! err="$(scheduler_route_to_recut "$issue" 2>&1 >/dev/null)"; then
    supervisor_budget_park "$id" "$evidence (recut route failed: ${err:0:200})" "$decision" "$park_reason" "$park_stage"; return 0
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
      set_unit "$id" "$(hist supervisor-park "needs-info transition unavailable for issue #$issue" "$decision") | .stage=\"parked\" | .note=$(js "needs-info question not posted: issue #$issue cannot transition to needs-info")"
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
# 被打回、BLOCK 或转人工的 PR head 不会原样合并：它排队中的 CI 先取消，runner 让给就绪与热修 PR
# （2026-10-20 22:42：112 个排队 job 里 46 个属于评审打回/转人工的单元，热修回迁 CI 排了 2 小时）。
# 热修单元不取消（BLOCK 后会原 head 重评）；之后被批准的 head 由合并车道重跑被取消的 run（ci_red）。
cancel_unit_runs() { # id reason
  local pr branch
  [[ "$(unit_field "$1" '.hotpatch // false')" == true ]] && return 0
  pr="$(unit_field "$1" '.pr // empty')"; [[ "$pr" =~ ^[0-9]+$ ]] || return 0
  branch="$(tick_pr_branch "$pr")"
  cancel_branch_runs "$branch" "$2" || : # Run cancellation is best-effort; listing failures are logged.
}
refresh_live_worker_cache() {
  local w type
  LIVE_WORKER_CACHE_TOTAL=0; LIVE_WORKER_CACHE_TYPES=()
  while IFS= read -r w; do
    harvest_worker_alive "$w" || harvest_worker_in_grace "$w" || continue
    type="$(jqf -r '.type' <<<"$w")"
    LIVE_WORKER_CACHE_TOTAL=$((LIVE_WORKER_CACHE_TOTAL + 1))
    LIVE_WORKER_CACHE_TYPES["$type"]=$((${LIVE_WORKER_CACHE_TYPES[$type]:-0} + 1))
  done < <(jqf -c '.workers[] | select(.harvested != true)' "$WORKERS")
  LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 10))
}
live_by_type() {
  local n=0 type
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) || refresh_live_worker_cache
  for type in "${!LIVE_WORKER_CACHE_TYPES[@]}"; do
    [[ "$type" =~ ^($1)$ ]] && n=$((n + LIVE_WORKER_CACHE_TYPES[$type]))
  done
  echo "$n"
}
live_workers() {
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) || refresh_live_worker_cache
  echo "$LIVE_WORKER_CACHE_TOTAL"
}
