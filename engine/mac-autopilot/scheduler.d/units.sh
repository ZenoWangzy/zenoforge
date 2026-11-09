
# PID 存活且确为 codex 进程（防 PID 复用把无关进程当活 worker）。
alive() { ps -p "$1" -o args= 2>/dev/null | grep -Eq 'codex|claude|zcode|zcode-cli|land-pr\.sh|precheck\.sh|cdp-browser-lease\.sh|decision-gate\.mjs'; }

# 退休可逆：终态单元要再次推进时（如直落提交被 MAIN-RED 回退，merge-prep 按 .land_sha 找回 landed
# 单元派修复），把归档行移回热台账。归档行保留（只增不删）；同 id 两处时以热台账为准。
restore_archived_unit() { # id；rc 0 = 该单元现在在热台账里
  local id="$1" row
  jqf -e --arg id "$id" 'any(.units[]; .id == $id)' "$UNITS" >/dev/null 2>&1 && return 0
  row="$(jqf -c --arg id "$id" '[.units[] | select(.id == $id)][0] // empty' "$UNITS_ARCHIVE" 2>/dev/null)" || return 1
  [[ -n "$row" ]] || return 1
  units_update --slurpfile row <(printf '%s' "$row") --arg id "$id" 'if any(.units[]; .id == $id) then . else .units += [$row[0]] end' # slurpfile: a row can exceed the 64KB jqf argv guard
}

# ---------- 终态单元退休：热台账只留会推进的单元 ----------
# 词汇表与 lib.d/dispatch-gates.sh 的 SCHEDULER_UNIT_TERMINAL_STAGES 一致：这些 stage 不再拥有
# 票、没有任何阶段会再推进它们；parked / blocked-external / supervisor-review 等仍可能被裁决、
# 解阻或重排，必须留在热台账。退休只移动台账行，历史读者经 units_history_doc 继续可见。
UNIT_RETIRE_STAGES='["merged","landed","closed","done","wontfix","duplicate"]'

# 需要历史（终态）记录的读者用这个合并视图：活台账 + 归档，按 id 去重。同一 id 同时出现在
# 两处（退休两步写之间崩溃的窗口）时以 units.json 的行较新为准（reduce 后写覆盖，活台账行排在后面）。
units_history_doc() { _units_history_view doc; }
# 逐候选查找只需 id/issue/branch/pr/stage/episode：读这份小索引，不必每次解析整份合并台账。
units_history_index() { _units_history_view index; }
# 合并视图缓存：键为两个文件的 mtime(ns)+大小，任一文件被写就换键重建；所以一拍内的几十次查找只付一次合并。
_units_history_view() { # doc|index
  local kind="$1" key dir f g proj='{units: [.units[] | {id, issue, branch, pr, stage, hold_handoff_episode, merge_sha, land_sha}]}'
  if [[ ! -s "$UNITS_ARCHIVE" ]]; then
    if [[ "$kind" == doc ]]; then cat "$UNITS"; else jqf "$proj" "$UNITS"; fi
    return
  fi
  key="$(stat -c '%i %y %s' "$UNITS" "$UNITS_ARCHIVE" 2>/dev/null | tr -c 'A-Za-z0-9\n' _ | tr -d '\n')"
  dir="${UNITS_ARCHIVE%/*}"; f="$dir/.units-history-$kind.$key.json"
  if [[ -n "$key" && -s "$f" ]]; then cat "$f" && return; fi
  if [[ "$kind" == doc ]]; then
    jqf -s --slurpfile arch "$UNITS_ARCHIVE" '
      reduce (($arch[0].units // []) + (.[0].units // []))[] as $u ({}; .[$u.id] = $u)
      | [.[]] | {units: .}' "$UNITS" 2>/dev/null > "$f.$$" || {
      rm -f "$f.$$"; say "units history: could not merge $UNITS_ARCHIVE; readers see the hot ledger only"; cat "$UNITS"; return
    }
  else
    _units_history_view doc | jqf "$proj" > "$f.$$" || { rm -f "$f.$$"; _units_history_view doc; return; }
  fi
  cat "$f.$$" # before the rename: a concurrent reader's sweep can delete $f, and an empty read looks like an unknown unit
  if [[ -n "$key" ]] && mv -f "$f.$$" "$f"; then
    for g in "$dir"/.units-history-"$kind".*.json "$dir"/.units-history-"$kind".*.json.*; do
      [[ "$g" == "$f" || -n "$(find "$g" -mmin -5 -name '*.json.*' 2>/dev/null)" ]] || rm -f "$g"
    done
  else
    rm -f "$f.$$"
  fi
}

# Rollback, before any revert of retirement: the old engine reads units.json only. Run under the scheduler lock.
unretire_all_units() {
  [[ -s "$UNITS_ARCHIVE" ]] || return 0
  units_update --slurpfile arch "$UNITS_ARCHIVE" '.units += ([.units[].id] as $hot | $arch[0].units | map(select(.id as $id | $hot | index($id) | not)))'
}

# 终态退休（每慢拍一次，持有调度锁）：把 terminal stage 且没有在途本地依赖的单元移进
# units-archive.json。先归档后删除——两步之间崩溃最多让同一 id 短暂同时存在于两处（合并视图与
# 归档写都按 id 幂等，重跑收敛），绝不丢行；write_state 对 units.json 的删除守卫也只放行已在
# 归档里的 id。排除：eval 还在 pending/running（dispatch_prompt_evals 按热台账派发、收割要写回）、
# main-red 尚未回填 resolved_main_sha/at（supersede 回填写热台账）、还有未收割 worker 记录
# （eval/supervise worker 会在单元终态后仍收割写账）。
retire_terminal_units() {
  local ids_file rows n archive_n
  [[ "${UNIT_RETIRE_DISABLED:-}" != true ]] || return 0 # 测试开关：scheduler.test.sh 整拍用例断言终态行留在 units.json；退休由 unit-retire.test.sh 覆盖
  [[ -f "$UNITS_ARCHIVE" ]] || printf '{"units":[]}\n' > "$UNITS_ARCHIVE"
  jqf -e 'type=="object" and (.units|type)=="array"' "$UNITS_ARCHIVE" >/dev/null 2>&1 \
    || { say "unit retire: archive unreadable; terminal units kept in ledger"; return 0; }
  ids_file="$(mktemp)" || return 1
  jqf -c --slurpfile workers "$WORKERS" --argjson terminal "$UNIT_RETIRE_STAGES" '
    ([.units[] | select(.stage as $s | $terminal | index($s) != null)
       | select((.eval_gate.status // "") | IN("pending","running") | not)
       | select((.hold_handoff_waiting // false) | not)
       | select(.awaiting_release_pending == null)
       | select(.advisor_pid == null and .self_check_pid == null and .precheck_pid == null)
       | select((.main_red == true
           and (((.resolved_main_sha // "") == "") or ((.resolved_main_at // "") == ""))) | not)
       | .id]) as $retirable
    | [($workers[0].workers[]? | select(.harvested != true) | .unit)] as $busy
    | [$retirable[] | select(. as $id | $busy | index($id) | not)] | unique' "$UNITS" > "$ids_file" \
    || { rm -f -- "$ids_file"; say "unit retire: ledger read failed; nothing retired"; return 0; }
  n="$(jqf -r 'length' "$ids_file")"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
    if jqf --slurpfile ids "$ids_file" --slurpfile live "$UNITS" '
        ($live[0].units | map(select(.id as $id | $ids[0] | index($id) != null))) as $incoming
        | ($incoming | map(.id)) as $in_ids
        | .units = ((.units | map(select(.id as $id | $in_ids | index($id) == null))) + $incoming)
      ' "$UNITS_ARCHIVE" | write_state "$UNITS_ARCHIVE"; then
      if units_update --slurpfile ids "$ids_file" '.units |= map(select(.id as $id | $ids[0] | index($id) | not))'; then
        archive_n="$(jqf -r '.units | length' "$UNITS_ARCHIVE")"
        say "unit retire: moved $n terminal unit(s) to the archive; ledger=$(jqf '.units | length' "$UNITS") archive=$archive_n"
      else
        say "unit retire: archive updated but ledger trim failed; ids stay duplicated until the next pass"
      fi
    else
      say "unit retire: archive write failed; terminal units kept in ledger"
    fi
  fi
  rm -f -- "$ids_file"
  return 0
}

set_unit() { # id jq_update_expression（.stage=... 等，可用 | 连接）
  [[ "${SET_UNIT_QUEUE:-0}" != 1 ]] || { dep_q_enqueue "$@"; return 0; } # release_dependency_blocks batches its writes, see dep_q_flush
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
  local own_lock=false rc=0 new
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    acquire_scheduler_lock_wait || return 1
    own_lock=true
  fi
  # A no-op update skips the write: intake's consumed handoff rows made three per row, and each rewrite renewed the
  # ledger's mtime (dropping the history view cache) and ran write_state's validation (128-146 s for 24 rows).
  new="$(mktemp "$UNITS.noop.XXXXXX")" || rc=1
  if (( rc == 0 )); then
    jqf "$@" "$UNITS" > "$new" || rc=$?
    if (( rc == 0 )) && ! cmp -s "$new" "$UNITS"; then write_state "$UNITS" < "$new" || rc=$?; fi
    rm -f -- "$new"
  fi
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
# A parent check that could not answer (rc 2) backs off like a failed label write; the third failed check parks the
# issue for triage instead of deferring it every tick.
intake_parent_unverified() { # issue, check rc, issue JSON, check reason
  local n="$1" rc="$2" json="$3" reason="${4:-}" retry_step attempts parent_step
  parent_step="$(sed -n 's/^parent-check-failure step=//p' <<<"$reason" | head -n 1)"
  [[ -n "$parent_step" ]] || parent_step=unknown
  retry_step="$(intake_parent_retry_failed "$n")" || retry_step="? ?"
  attempts="${retry_step% *}"
  if [[ "$attempts" =~ ^[0-9]+$ ]] && (( attempts >= 3 )); then
    if scheduler_issue_transition "$n" needs-triage "intake-parent:unverified-after-$attempts" . 0 "$json"; then
      say "intake issue #$n -> needs-triage (parent status unverified after $attempts attempts, rc=$rc, step=$parent_step)"
      intake_parent_retry_clear "$n"
    else
      say "intake issue #$n held: parent status unverified (rc=$rc, step=$parent_step); needs-triage update failed (attempt $attempts)"
    fi
  else
    say "intake issue #$n deferred: could not verify parent status rc=$rc step=$parent_step"
  fi
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
  # A recut or park event names the attempt before it: the unit's latest write-start (null before any launch).
  case "$1" in
    *recut*|*park*) echo ".history += [$entry + {attempt: ((.history // []) | map(select(.stage == \"write-start\")) | last | .attempt // null)}]" ;;
    *) echo ".history += [$entry]" ;;
  esac
}
decision_entry() { # decision why evidence rejected-json owner -> history decision object
  jqf -cn --arg decision "$1" --arg why "$2" --arg evidence "$3" --argjson rejected "$4" --arg owner "$5" \
    '{decision:$decision,why:$why,evidence:$evidence,rejected:$rejected,owner:$owner}'
}
# An INPUT_INCOMPLETE review judged nothing about the code: the way back is a review, never a commit repair (pr-5650 spent 822k tokens on 3 repairs of an unchanged head).
last_review_blocked() { # unit-json → 0 when the latest review verdict in its history is review-block
  jqf -e '[(.history // [])[] | select(.stage | IN("review-approve", "review-request-changes", "review-block"))] | last.stage == "review-block"' <<<"$1" >/dev/null 2>&1
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

# A park with no reason has no exit, so every writer goes through this. A named predecessor outranks the reason: its delivery is what releases the unit.
park_fields() { # reason unpark-condition → jq update
  printf '.parked_reason=(if (.blocked_on | type) == "number" then "waiting-predecessor" else %s end) | .unpark_condition=(if (.blocked_on | type) == "number" then "#\\(.blocked_on) delivered" else %s end)' "$(js "$1")" "$(js "$2")"
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
  local id="$1" evidence="$2" decision="${3:-null}" reason="${4:-supervisor budget exhausted}" stage="${5:-supervisor-budget-park}" note parked_as=supervisor-budget unpark='a supervisor decision'
  note="$(js "$reason: $evidence")"
  [[ "$evidence" != 'ticket stop-loss'* ]] || { parked_as=ticket-stop-loss; unpark='the issue changes or the ticket budget is raised'; }
  cap_set_unit "$id" park "$reason: $evidence" "" "$(hist "$stage" "$evidence" "$decision") | .stage=\"parked\" | .note=$note | $(park_fields "$parked_as" "$unpark")" \
    && say "supervisor budget-park unit=$1: $2"
}

SUPERVISOR_CAP_PARK_RESULT_RE='^(third entry into supervisor-review; arbitration cap is 2|arbitration budget exhausted for )'

# RECUT cannot finish over unpushed work, so triaging the same head again only spends a run: 148 of 625 dispatches on 11-06.
supervisor_recut_refuse() { # id evidence decision worktree [notify-supervisor]
  local id="$1" evidence="$2" decision="$3" wt="$4" notify_supervisor="${5:-true}" head note key
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  note="RECUT refused: unpushed work at ${head:0:12}. Unparks when that head changes or the worktree is gone."
  cap_set_unit "$id" park "$note $evidence" "" "$(hist supervisor-recut-refused "$evidence" "$decision") | .stage=\"parked\" | .parked_reason=\"recut-refused-unpushed\" | .unpark_condition=\"the unit head changes\" | .recut_refused_head=$(js "$head") | .recut_refused_verdict=\"RECUT\" | .note=$(js "$note $evidence")" \
    || return 1
  say "supervisor recut refused unit=$id head=${head:0:12}: unpushed work"
  [[ "$notify_supervisor" == true ]] || return 0
  key="recut-refused:$id:$head"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "$key" "recut-refused unit=$id: $note") \
    || say "recut refused unit=$id: escalation not delivered"
}

supervisor_recut_refused_hold() { # unit-json → 0 while the refused head is still what its worktree holds
  local id refused d
  [[ "$(jqf -r '.parked_reason // empty' <<<"$1")" == recut-refused-unpushed ]] || return 1
  id="$(jqf -r .id <<<"$1")"; refused="$(jqf -r '.recut_refused_head // empty' <<<"$1")"
  [[ -n "$refused" ]] || return 1
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do
    [[ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" != "$refused" ]] || return 0
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
  local id="$1" u="$2" trigger="${3:-lifetime}" issue pr raw state="" delivered=false verdict recut_done branch reason decision limit_reason tag="supervisor cap default"
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
    [[ "$(tick_pr_state "$pr" 2>/dev/null || true)" == MERGED ]] && delivered=true
  fi
  verdict="$(jqf -r '.supervisor_cap_verdict // .recut_refused_verdict // ""' <<<"$u")" || verdict=""
  recut_done="$(jqf -r 'any((.history // [])[]?; .stage == "supervisor-budget-recut" or .stage == "supervisor-cap-triage-recut") or .recut_routed == true' <<<"$u")"
  if [[ "$delivered" == true ]]; then
    branch=obsolete
    reason="issue state ${state:-unknown} or the work is already merged elsewhere"
    [[ "$trigger" != repeat ]] || reason="$tag: $reason"
    cap_set_unit "$id" obsolete "$reason" "" "$(hist obsolete "$reason") | .stage=\"closed\" | .note=$(js "obsolete: $reason") | del(.parked_reason)" || return 1
  elif [[ "$verdict" == RECUT || "$recut_done" != true ]]; then
    reason="$limit_reason; recut the unit once"
    supervisor_budget_recut "$id" "$tag: $reason" "$decision" \
      "$tag could not complete the recut route" "$tag recut" \
      "$park_stage" "$recut_stage" false false || return 1
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
  local id mark
  [[ "$(jqf -r '.stage // empty' <<<"$1")" == supervisor-review ]] || return 1
  [[ -n "$(jqf -r '.arbiter_left_mark // empty' <<<"$1")" ]] || return 1
  mark="$(supervisor_arbiter_mark "$1")"
  [[ "$mark" == "$(jqf -r .arbiter_left_mark <<<"$1")" ]] || return 1
  id="$(jqf -r .id <<<"$1")"
  say "supervisor arbitration held unit=$id: no head, state or ruling change since its last run"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "arbiter-no-change:$id:$mark" \
    "arbiter-no-change unit=$id: its last run left it at supervisor-review; held until head, state or ruling changes") \
    || say "arbitration hold unit=$id: escalation not delivered"
  return 0
}

# Progress between two arbitrations: a delivery, an approval, ready-to-merge, a merge or a new PR head. Anything else (a requeue,
# a stop-loss, a red check, a blocked-on) leaves the unit where the last arbiter found it.
SUPERVISOR_PROGRESS_RE='^(repair-delivered|self-fix-delivered|delivered|implement-push-recovered|pr-opened|review-approve|supervisor-approve|ci-ready|land-issued|merge-issued|merged|pr-merged|landed)$'

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

# A question to the founder must name a fact only the owner has. Text that only
# reports that the engine could not decide is an engine fault, not a question.
SUPERVISOR_FOUNDER_GENERIC_RE='could not (be )?(decided?|resolved?)|cannot (be )?decided?|decide automatically|automatically decide|无法(自动)?裁决'

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
# 走 lib.sh 唯一的 needs-recut 入口 route_to_recut；有未提交、stash 或未推送改动时不关单元，照旧 park。
supervisor_budget_recut() { # id evidence decision park-reason recut-reason park-stage recut-stage allow-pr-close notify-refusal
  local id="$1" evidence="$2" decision="${3:-null}" park_reason="${4:-supervisor budget exhausted}"
  local recut_reason="${5:-ticket stop-loss reached}" park_stage="${6:-supervisor-budget-park}" recut_stage="${7:-supervisor-budget-recut}"
  local allow_pr_close="${8:-false}" notify_refusal="${9:-true}" issue pr err note pr_comment pr_state
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  local d
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do # cleanup_tick 删的两个位置；stash 是 ensure_clone 收起的未提交进度
    if [[ -d "$d" ]] && { [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || [[ -n "$(git -C "$d" stash list 2>/dev/null)" ]] \
        || [[ -z "$(git -C "$d" branch -r --contains HEAD 2>/dev/null)" ]]; }; then
      if [[ "$park_stage" == supervisor-cap-triage-park ]]; then
        supervisor_recut_refuse "$id" "$evidence" "$decision" "$d" "$notify_refusal"; return 0
      fi
      supervisor_budget_park "$id" "$evidence (worktree has unpushed work; not sent to recut)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  done
  [[ "$issue" =~ ^[0-9]+$ ]] || { supervisor_budget_park "$id" "$evidence" "$decision" "$park_reason" "$park_stage"; return 0; }
  if [[ -n "$pr" && "$allow_pr_close" != true ]]; then
    supervisor_budget_park "$id" "$evidence (unit already has PR #$pr)" "$decision" "$park_reason" "$park_stage"; return 0
  fi
  # Route first: a refused route must leave the PR open, or the slice has no owner (#1167 and #4840 lost theirs this way).
  # A retry after a failed close has already routed; the route guard would refuse it and strand the PR. An older split's recut_children proves nothing here.
  if [[ "$(unit_field "$id" '.recut_routed // empty')" != true ]] && ! err="$(scheduler_route_to_recut "$issue" 2>&1 >/dev/null)"; then
    supervisor_budget_park "$id" "$evidence (recut route failed: ${err:0:200})" "$decision" "$park_reason" "$park_stage"; return 0
  fi
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

# Row 131: three parks had no exit a machine could meet (cap default, repair breaker, budget park; 21 units, the oldest 229 h on 11-09).
# Each takes the existing budget-recut route once per 24h, read from its own dead-park-exit event; a unit that parks again in a class gets another recut, never a requeue.
# Left alone: session-owned (PR label) and supervisor_owned units, and every other park reason (on-hold, recut-refused, token hard park, arbiter-owned cap triage).
DEAD_PARK_EXIT_PER_TICK="${DEAD_PARK_EXIT_PER_TICK:-3}"
dead_park_exit() {
  local prs id class n=0
  prs="$(tick_prs)" || return 0 # without the census a session-owned label cannot be read
  while IFS=$'\t' read -r id class; do
    (( n < DEAD_PARK_EXIT_PER_TICK )) || break
    n=$((n + 1))
    set_unit "$id" "$(hist dead-park-exit "$class park has no automatic exit; sent to recut")" || continue
    say "dead park exit unit=$id class=$class"
    supervisor_budget_recut "$id" "dead park exit ($class)" null "dead park exit could not complete the recut route" "dead park exit recut" \
      supervisor-budget-park supervisor-budget-recut true false
  done < <(jqf -r --slurpfile census <(printf '%s' "$prs") --arg owned "$SESSION_OWNED_LABEL" --arg re "$SUPERVISOR_CAP_PARK_RESULT_RE" \
    --argjson since "$(($(date +%s) - 86400))" '
    [$census[0][] | select(any(.labels[]?; .name == $owned)) | .number] as $claimed
    | .units[]
    | (.history // []) as $h
    | ($h | map(select(.stage != "supervisor-cap-default")) | last // {}) as $l
    | select(.stage == "parked" and (.supervisor_owned // false) == false and (.hold_handoff_waiting // false) == false
        and ((.pr | type) != "number" or (.pr as $p | $claimed | index($p)) == null)
        and all($h[]; .stage != "dead-park-exit" or (((.at // "") | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // 0)) < $since)))
    | (if .parked_reason == "repair-breaker" and $l.stage == "repair-breaker" then "repair-breaker"
       elif (.parked_reason | IN("supervisor-budget", "ticket-stop-loss")) and ($l.stage | IN("supervisor-budget-park", "supervisor-cap-triage-park")) then
         (if any($h[]; .stage == "supervisor-cap-default") then "cap-default"
          elif $l.stage == "supervisor-budget-park" and (($l.result // "") | test($re) | not) then "budget-park"
          else empty end)
       else empty end) as $class
    | [.id, $class] | @tsv' "$UNITS")
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
