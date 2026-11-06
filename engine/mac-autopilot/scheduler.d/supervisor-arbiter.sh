# ---------- f12（#4369）：supervisor-review 的自动裁决 ----------
# 普通升级按冻结记录交给配置的 arbiter profile，最多两轮；触顶后再跑一轮 CLOSE/RECUT/RULE/FOUNDER cap triage。
supervisor_arbiter_input() { # unit-json [cap-triage] → frozen record JSON
  local u="$1" cap_triage="${2:-false}" report_name report_body report_at truncated=false
  report_name="$(jqf -r '.review_report // empty' <<<"$u")"
  report_body=""
  if [[ -n "$report_name" && -s "$SUP/$report_name" ]]; then
    report_body="$(head -c 8000 "$SUP/$report_name")"
    (( $(wc -c < "$SUP/$report_name") > 8000 )) && truncated=true
  fi
  report_at="$(jqf -r '[(.history // [])[] | select(((.stage // .event // .ev // "") | test("^review"))) | .at] | last // empty' <<<"$u")"
  jqf -c --arg asof "$STAMP" --arg report "$report_name" --arg report_at "$report_at" --arg body "$report_body" \
    --argjson truncated "$truncated" --argjson cap_triage "$([[ "$cap_triage" == true ]] && echo true || echo false)" '
    {
      asOf: $asof,
      unitId: .id,
      capTriage: $cap_triage,
      unitContext: {issue: .issue, pr: .pr, title: .title, task: .task, note: .note, rulings: '"$(cto_rulings_norm)"'},
      escalationReason: (
        ([(.history // [])[] | select(.stage == "supervisor-escalated" or .stage == "supervisor-review")] | last) as $e
        | {at: ($e.at // $asof), stage: ($e.stage // "supervisor-escalated"),
           reason: ($e.result // .note // "unknown escalation reason"), isExplicitEscalation: true}
      ),
      unitHistory: [(.history // [])[] | {stage: (.stage // .event // .ev // ""), at, result: (.result // .note // "")}],
      reviewFindings: (if ($body | length) > 0
        then {available: true, reportAt: $report_at, reportFile: $report, report: $body, truncated: $truncated}
        else {available: false, reportFile: $report, report: "", truncated: false} end),
      ciEvidence: [(.history // [])[] | select(((.stage // .event // .ev // "") | test("^ci-")) or (.stage // .event // .ev // "") == "merge-reverted") | {stage: (.stage // .event // .ev // ""), at, result: (.result // .note // "")}],
      handoff: {worktree: .handoff_worktree, worktreeSha: .handoff_worktree_sha, rescuedRef: .handoff_start_ref, rescuedSha: .handoff_start_sha}
    }' <<<"$u"
}

dispatch_supervisor_arbiters() { # supervisor-review 单元各派一个裁决 worker；在途上限 SUPERVISOR_ARBITER_MAX，两轮上限
  [[ "$SUPERVISOR_ARBITER" == true ]] || return 0
  local prompt_file cap_contract_file
  prompt_file="$(sched_config_file prompts/supervisor-arbiter.md)"
  [[ -r "$prompt_file" ]] || return 0
  # 终局裁决的动词契约由引擎自带文件保证（不走 sched_config_file）：目标配置可以把六动作 prompt
  # 覆盖成没有 cap-triage 段的旧版，但盖不掉这里追加的四个动词，任何 arbiter profile 都拿到同一契约。
  cap_contract_file="${ZF_ENGINE_DIR:-$ROOT/engine}/prompts/supervisor-cap-triage.md"
  local u id report log q pid w pid_file converted=0 cap_triaged=0 arbi_runs entries in_flight arbiter_input judge_input judge_output judge_answer judge_confidence judge_ready judge_rollout_ready event_id judge_metadata cap_triage is_swept return_stage cap_reasks cap_reask_notice
  local -a launcher=() worker_command=()
  local over_stop=false arbiter_profile="$SUPERVISOR_ARBITER_PROFILE" arbiter_effort=""
  if codex_week_stopped && ! codex_credits_open arbiter; then over_stop=true; fi
  in_flight="$(jqf -r '[.workers[] | select(.type=="supervise" and .harvested != true)] | length' "$WORKERS")"
  (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    id="$(jqf -r .id <<<"$u")"
    jqf -e --arg id "$id" 'any(.workers[]; .type=="supervise" and .harvested != true and .unit==$id)' "$WORKERS" >/dev/null && continue
    if [[ "$(jqf -r '.parked_reason // empty' <<<"$u")" == supervisor-cap-exhausted ]]; then
      [[ "$(supervisor_arbiter_mark "$u")" != "$(jqf -r '.cap_exhausted_mark // empty' <<<"$u")" ]] || continue
      set_unit "$id" '.parked_reason="supervisor-arbitration-cap" | del(.supervisor_cap_retry, .cap_exhausted_mark, .unpark_condition)'
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
    fi
    supervisor_arbiter_over_daily_max "$u" && continue
    supervisor_arbiter_no_change_hold "$u" && continue
    is_swept=false
    if [[ "$(jqf -r '.stage // empty' <<<"$u")" == parked ]]; then
      [[ "${SUPERVISOR_CAP_TRIAGE:-true}" == true ]] || continue
      supervisor_recut_refused_hold "$u" && continue
      supervisor_cap_parked_unit "$u" || continue
      is_swept=true
    fi
    arbi_runs="$(jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage=="supervisor-arbiter-round") | .key] | max // -1) as $r | [$h[$r+1:][] | select(.stage=="supervisor-arbiter")] | length' <<<"$u")"
    entries="$(supervisor_entries "$id")"
    cap_triage=false
    if (( arbi_runs >= 2 || entries >= 3 )); then
      if [[ "${SUPERVISOR_CAP_TRIAGE:-true}" == true ]]; then
        cap_triage=true
        (( cap_triaged < SUPERVISOR_CAP_TRIAGE_PER_TICK )) || { say "supervisor cap triage capped at $SUPERVISOR_CAP_TRIAGE_PER_TICK this tick"; continue; }
      else
        # Compatibility switch: preserve the previous capped park behavior.
        [[ "$is_swept" == false ]] || continue
        (( converted < SUPERVISOR_NEEDS_INFO_PER_TICK )) || { say "supervisor budget park capped at $SUPERVISOR_NEEDS_INFO_PER_TICK this tick"; return 0; }
        supervisor_budget_park "$id" "arbitration budget exhausted for $id (runs=$arbi_runs entries=$entries)" && converted=$((converted + 1))
        continue
      fi
    elif [[ "$is_swept" == true ]]; then
      # A legacy cap park may have a cleared round marker or incomplete history;
      # it still receives one final cap-triage run because its park reason is authoritative.
      cap_triage=true
      (( cap_triaged < SUPERVISOR_CAP_TRIAGE_PER_TICK )) || { say "supervisor cap triage capped at $SUPERVISOR_CAP_TRIAGE_PER_TICK this tick"; continue; }
    fi
    (( $(live_workers) < MAX )) || { say "supervisor arbitration pending unit=$id: worker capacity full"; return 0; }
    arbiter_profile="$SUPERVISOR_ARBITER_PROFILE"
    if [[ "$over_stop" == true ]]; then
      # Weekly Codex stop: the arbiter runs on the hand-claude role. No Claude share or a Claude hold defers the unit to a later tick.
      if [[ "$(jqf -r '.models.implement_share.claude // 0' <<<"$CFG")" != 0 ]] && pick_claude_implementer; then
        arbiter_profile="$PICK_MODEL"; arbiter_effort="$PICK_EFFORT"
      else
        say "supervisor arbitration pending unit=$id: weekly Codex stop and Claude unavailable"
        continue
      fi
    fi
    if [[ "$cap_triage" == true && ! -r "$cap_contract_file" ]]; then
      # 没有引擎契约就不派终局裁决：派出去的 prompt 只有（可能被覆盖的）六动作契约，
      # 格式 miss 会直接 park 单元（incident-pstack-root-cause-2026-11-03）。
      echo "[$STAMP] cap-triage unit=$id skipped: engine cap-triage contract missing at $cap_contract_file" >> "$A/alerts/events.md"
      say "supervisor cap triage unit=$id: engine contract missing; not dispatched"
      continue
    fi
    if [[ "$is_swept" == true ]]; then
      return_stage="$(jqf -r '.supervisor_cap_return_stage // empty' <<<"$u")"
      [[ -n "$return_stage" ]] || return_stage="$(supervisor_return_stage "$u")"
      set_unit "$id" ".stage=\"supervisor-review\" | .supervisor_cap_return_stage=$(js "$return_stage") | .supervisor_cap_from_parked=true | if .parked_reason==\"supervisor-cap-founder\" then .supervisor_cap_retry=\"pending\" else . end | del(.parked_reason)"
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
    elif [[ -z "$(jqf -r '.supervisor_cap_return_stage // empty' <<<"$u")" ]]; then
      return_stage="$(supervisor_return_stage "$u")"
      set_unit "$id" ".supervisor_cap_return_stage=$(js "$return_stage")"
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
    fi
    event_id="f12:$id:entry-$entries"
    arbiter_input="$(supervisor_arbiter_input "$u" "$cap_triage")"
    judge_input="$(jqf -c --arg event_id "$event_id" '. + {event_id:$event_id,currentDecision:null}' <<<"$arbiter_input")"
    judge_output=""
    if [[ "$cap_triage" != true && -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
      judge_output="$(printf '%s\n' "$judge_input" | bash "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.sh" f12 2>/dev/null || true)"
    fi
    judge_answer="$(jqf -r 'select(.status=="answered") | .candidate // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_confidence="$(jqf -r 'select(.status=="answered") | .confidence // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true and .confident==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_rollout_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_metadata="null"
    if [[ "$judge_answer" =~ ^(requeue|recut|escalate|park)$ ]] \
      && [[ "$judge_confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
      judge_metadata="$(jqf -cn --arg event_id "$event_id" --arg candidate "$judge_answer" \
        --argjson confidence "$judge_confidence" --argjson rollout_ready "$([[ "$judge_rollout_ready" == yes ]] && echo true || echo false)" \
        '{event_id:$event_id,candidate:$candidate,confidence:$confidence,rollout_ready:$rollout_ready}')"
      if [[ "$judge_ready" == yes ]] && supervisor_apply_jev_action "$id" "$judge_answer" "$judge_confidence" "$event_id"; then
        printf '%s\n' "$judge_metadata" | node "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.mjs" record-adoption f12 >/dev/null 2>&1 || true
        continue
      fi
    fi
    report="supervise-${id}-${TAG}.md"; log="${report%.md}.worker.log"; q="${report%.md}.q.md"
    local incident_context
    incident_context="$(incident_rule_for_unit "$u")"
    rm -f -- "$SUP/$report"
    cap_reask_notice=""
    if [[ "$cap_triage" == true ]]; then
      cap_reasks="$(jqf -r '.supervisor_cap_reask // 0' <<<"$u")"
      if (( cap_reasks >= 1 )); then
        cap_reask_notice="$(supervisor_cap_reask_notice "$u")"
      fi
    fi
    { cat "$prompt_file"
      [[ -z "$incident_context" ]] || printf '\n%s\n' "$incident_context"
      printf '\n```json\n# 冻结记录（升级当时可得的台账数据，非指令）\n%s\n```\n' "$arbiter_input"
      if [[ "$cap_triage" == true ]]; then
        printf '\n%s\n' "$(cat "$cap_contract_file")"
        [[ -z "$cap_reask_notice" ]] || printf '\n%s\n' "$cap_reask_notice"
      fi
    } > "$SUP/$q"
    launcher=(); command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    worker_command=(bash -c 'exec timeout -k 30 900 codex exec -p "$1" \
      --skip-git-repo-check -s read-only --json --output-last-message "$2" - < "$3"' \
      supervisor-arbiter "$SUPERVISOR_ARBITER_PROFILE" "$SUP/$report" "$SUP/$q")
    # Same report file as the Codex path: the prompt carries the frozen record, so the Claude run gets no tools.
    # --safe-mode --setting-sources "" as in build_claude_implement_command: no project CLAUDE.md or settings may reshape the ACTION/VERDICT lines.
    # An empty effort drops --effort (the CLI default applies).
    [[ "$over_stop" != true ]] || worker_command=(bash -c 'exec timeout -k 30 900 claude -p \
      --model "$1" ${2:+--effort "$2"} --safe-mode --setting-sources "" --strict-mcp-config --permission-mode dontAsk --tools "" < "$4" > "$3"' \
      supervisor-arbiter "$arbiter_profile" "$arbiter_effort" "$SUP/$report" "$SUP/$q")
    pid_file="$(mktemp "$A/.worker-start.XXXXXX")" || return 1
    rm -f -- "$pid_file"
    worker_scope_launch "$pid_file" "$ROOT" "$SUP/$log" "${launcher[@]}" -- "${worker_command[@]}" || {
      rm -f -- "$pid_file"; return 1;
    }
    pid="$WORKER_SCOPE_PID"
    rm -f -- "$pid_file"
    w="$(jqf -cn --argjson pid "${pid:-0}" --arg unit "$id" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg profile "$arbiter_profile" \
      --argjson cap_triage "$([[ "$cap_triage" == true ]] && echo true || echo false)" \
      --argjson jev "$judge_metadata" \
      '{pid:$pid,unit:$unit,type:"supervise",log:$log,report:$report,started:$at,model:("profile:"+$profile),cap_triage:$cap_triage,jev:$jev}')"
    jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" "$(hist supervisor-arbiter "dispatched to profile $arbiter_profile") | .supervise_report=$(js "$report") | .hard_escalated=true"
    say "supervisor arbitration dispatched pid=$pid unit=$id profile=$arbiter_profile"
    [[ "$over_stop" == true ]] || codex_credits_log arbiter "$id"
    in_flight=$((in_flight + 1))
    [[ "$cap_triage" == true ]] && cap_triaged=$((cap_triaged + 1))
    (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  done < <(jqf -c --arg cap_park_result_re "$SUPERVISOR_CAP_PARK_RESULT_RE" '.units[] | select((.stage=="supervisor-review" or .stage=="parked") and (.hold_handoff_waiting // false) == false and (.supervisor_owned // false) == false and (.stage!="parked" or .parked_reason=="supervisor-arbitration-cap" or .parked_reason=="supervisor-cap-triage-reask" or .parked_reason=="recut-refused-unpushed" or .parked_reason=="supervisor-cap-founder" or .parked_reason=="supervisor-cap-exhausted" or any((.history // [])[]?; .stage=="supervisor-budget-park" and ((.result // "") | test($cap_park_result_re))) or .stage=="supervisor-cap-triage-park"))' "$UNITS")
}

supervisor_action_of() { # report-path → 唯一 ACTION 行的动作名；无法判定返回 1
  local found
  found="$(grep -hoE '^[[:space:]]*ACTION:[[:space:]]*(requeue|approve|park|close|reroute|needs-info)[[:space:]]*$' "$1" 2>/dev/null \
    | tr -d '[:space:]' | sed 's/^ACTION://' | sort -u)"
  [[ -n "$found" && "$(grep -c . <<<"$found")" == 1 ]] || return 1
  printf '%s' "$found"
}

supervisor_section_of() { # report-path section（如 GUIDANCE）→ 冒号后同行内容 + 后续行，到下一节为止
  awk -v p="$2" '
    BEGIN { prefix = p ":" }
    index($0, prefix) == 1 { line = substr($0, length(prefix) + 1); sub(/^[[:space:]]+/, "", line); if (line != "") print line; f = 1; next }
    f && /^(ACTION|REASON|EVIDENCE|REJECTED|GUIDANCE|QUESTION):/ {exit}
    f {print}' "$1" 2>/dev/null
}

supervisor_requeue_rereview() { # unit-json → true when the latest unchanged reviewed head has no actionable review or a confirmed no-push repair
  jqf -e '
    (.history // []) as $history
    | (.review_findings // []) as $records
    | ([$history | to_entries[] | select(.value.stage | startswith("review-"))] | last // null) as $review
    | if $review == null or $review.value.stage != "review-request-changes" then false
      else
        ([$history | to_entries[]
          | select(.key <= $review.key and .value.stage == "review-request-changes")] | length) as $round
        | ([$records[] | select(.round == $round)] | last // null) as $findings
        | ($review.value.result // "") as $review_sha
        | ((.reviewed_sha // "") == $review_sha
           and ($review_sha | test("^[0-9a-f]{40}$"))
           and ((.reviewed_pr_head // "") | test("^[0-9a-f]{40}$"))) as $reviewed_pair
        | ($findings != null and $findings.block == "ok"
           and ($findings.findings | type) == "array"
           and ([$findings.findings[] | select(.status == "open" and (.severity == "P0" or .severity == "P1"))] | length) == 0) as $no_actionable
        | ([$history | to_entries[]
          | select(.key > $review.key and (.value.stage == "repair-delivered" or .value.stage == "self-fix-delivered"))] | last // null) as $delivery
        | ([$history | to_entries[]
          | select(.key > $review.key and .value.stage == "repair-no-push")] | last // null) as $no_push
        | (if $no_push == null then ""
           else try ($no_push.value.result | capture("^head (?<sha>[0-9a-f]{40}) unchanged after repair$").sha) catch ""
           end) as $no_push_sha
        | ([$history | to_entries[] | select(.key > $review.key and .value.stage == "write-start")] | last // null) as $latest_write
        | $reviewed_pair and (
            ($no_actionable and $latest_write == null)
            or ($delivery != null and $no_push != null and $no_push.key > $delivery.key
                and $no_push_sha == $review_sha
                and ($latest_write == null or $latest_write.key < $no_push.key))
          )
      end
  ' <<<"$1" >/dev/null 2>&1
}

supervisor_requeue_unit() { # id action guidance decision —— requeue/reroute 落地：选一个工作环节放回去
  local id="$1" action="$2" guidance="$3" decision="$4" u target extra="" issue issue_json issue_state issue_reason issue_repo="${REPO:-${ZF_REPO:-}}"
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  if jqf -e 'any((.history // [])[]?; (.stage | test("^review")) or .stage == "repair-delivered" or .stage == "delivered")' <<<"$u" >/dev/null \
     && { [[ "$(jqf -r '.pr // empty' <<<"$u")" =~ ^[0-9]+$ ]] \
       || { [[ "$(jqf -r '.lane // empty' <<<"$u")" == direct-main ]] && [[ -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; } }; then
    if supervisor_requeue_rereview "$u"; then
      target="rereview-pending"
      extra=' | .reviewed_sha=null | .reviewed_pr_head=null | .repair_hint=null'
    else
      target="repair-pending"
      extra=" | .repair_hint=$(js "$guidance")"
    fi
  elif [[ -n "$(jqf -r '.task // empty' <<<"$u")" && -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; then
    target="implement-pending"
    extra=" | .task += ($(js "

supervisor 裁决（${action}）后重排：$guidance"))"
  else
    # 没有可放回的工作环节：搁置并留原因，不猜。
    set_unit "$id" "$(hist supervisor-park "requeue target missing: no review history and no task/branch" "$decision") | .stage=\"parked\" | .note=$(js "requeue had no work stage to return to")"
    say "supervisor arbitration unit=$id: $action has no work stage -> parked"
    return 0
  fi
  if [[ "$action" == reroute ]]; then
    extra=" | del(.blocked_on)$extra"
    [[ "$target" == rereview-pending ]] || extra=" | .reviewed_sha=null | .reviewed_pr_head=null$extra"
  fi
  issue="$(jqf -r '.issue // empty' <<<"$u")"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    [[ -n "$issue_repo" ]] || { say "supervisor arbitration unit=$id: repository is unavailable for issue #$issue requeue"; return 1; }
    issue_json="$(gh issue view "$issue" --repo "$issue_repo" --json number,title,body,state,labels 2>/dev/null)" \
      || { say "supervisor arbitration unit=$id: issue #$issue could not be refreshed for requeue; leaving the unit at supervisor-review"; return 1; }
    issue_state="$(scheduler_issue_state "$issue")" \
      || { say "supervisor arbitration unit=$id: issue #$issue state is unreadable for requeue; leaving the unit at supervisor-review"; return 1; }
    if [[ "$(jqf -r '.state // empty' <<<"$issue_state")" == on-hold ]]; then
      [[ "$(jqf -r '.hold.holder // empty' <<<"$issue_state")" == scheduler-stop-loss ]] \
        || { say "supervisor arbitration unit=$id: issue #$issue has a non-stop-loss hold; leaving the unit at supervisor-review"; return 1; }
      issue_reason=hold-requeue
    else
      issue_reason=supervisor-requeue
    fi
    if ! scheduler_issue_transition "$issue" ready-for-agent "$issue_reason" . 0 "$issue_json"; then
      say "supervisor arbitration unit=$id: issue #$issue could not be requeued to ready-for-agent; leaving the unit at supervisor-review"
      return 1
    fi
  fi
  set_unit "$id" "$(hist "supervisor-$action" "$guidance" "$decision") | .stage=\"$target\"$extra"
  say "supervisor arbitration unit=$id: $action -> $target"
}

reconcile_size_recuts() {
  local u id issue state hold_note reconcile_note
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    state="$(scheduler_issue_state "$issue")" || continue
    if jqf -e '.state == "tracker" or (.state == "released" and (has("recut_children") or .tracker_parent == true)) or (.state == "concluded" and .run.outcome == "duplicate" and .closed_by_pipeline == true)' <<<"$state" >/dev/null; then
      set_unit "$id" "$(hist size-recut-completed "issue #$issue became a tracker or a closed duplicate") | .stage=\"closed\" | .note=null | del(.size_recut_pending)"
      say "unit $id recut completed; parent is a tracker or closed duplicate"
    elif jqf -e '.state == "on-hold" or .hold != null' <<<"$state" >/dev/null; then
      hold_note="issue #$issue recut is on hold"
      if [[ "$(jqf -r '.note // ""' <<<"$u")" != "$hold_note" ]]; then
        set_unit "$id" "$(hist size-recut-held "$hold_note") | .stage=\"parked\" | .note=$(js "$hold_note")"
      fi
    elif jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null; then
      # Refusal, advisor recovery, and release-hold all requeue through the
      # shared issue state machine. Resume the existing unit, not a duplicate.
      set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation") | .stage=\"implement-pending\" | .note=null | del(.size_recut_pending)"
    elif jqf -e '.state == "needs-recut" and (has("recut_children") or has("recut_refused_at"))' <<<"$state" >/dev/null; then
      # A label-write failure can leave a completed marker in the active
      # queue, whose prefilter will never dispatch it again. Park until the
      # issue state and label are reconciled; automated unit requeue alone
      # would allow the parent to race its already-created children.
      reconcile_note="issue #$issue needs state/label reconciliation before this unit can resume"
      if ! scheduler_size_recut_active "$issue" && [[ "$(jqf -r '.note // ""' <<<"$u")" != "$reconcile_note" ]]; then
        set_unit "$id" "$(hist size-recut-reconcile "issue #$issue has a completed marker but remains needs-recut") | .stage=\"parked\" | .note=$(js "$reconcile_note")"
        echo "[$STAMP] size-recut issue=#$issue action=parked reason=state-label-reconciliation-required" >> "$A/alerts/events.md"
        say "unit $id parked for issue #$issue recut state/label reconciliation"
      fi
    fi
  done < <(jqf -c '.units[] | select((.stage=="blocked-external" or .stage=="parked") and .size_recut_pending==true)' "$UNITS")
}

supervisor_apply_action() { # id action report-path —— 六动作落地，决定/理由/证据/否掉选项写进单元
  local id="$1" action="$2" rep="$3" reason rejected evidence decision guidance question u reviewed_sha reviewed_pr_head pr
  reason="$(supervisor_section_of "$rep" REASON | head -c 2000)"
  rejected="$(jqf -cn --arg text "$(supervisor_section_of "$rep" REJECTED | head -c 1000)" '[$text]')"
  evidence="supervisor arbitration report $(basename "$rep")"
  decision="$(decision_entry "Supervisor arbitration: $action" "${reason:-action $action}" "$evidence" "$rejected" supervisor)"
  case "$action" in
    requeue|reroute)
      guidance="$(supervisor_section_of "$rep" GUIDANCE | head -c 4000)"
      [[ -n "${guidance//[[:space:]]/}" ]] || guidance="$reason"
      supervisor_requeue_unit "$id" "$action" "$guidance" "$decision" ;;
    approve)
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
      # f11 基线实测 2 次危险 approve（记录里有 main-red/回滚证据仍 approve）：确定性挡板，不靠 prompt 自律。
      if jqf -e '(.handoff_worktree_sha != null and .handoff_worktree_applied != true) or (.handoff_start_sha != null and .handoff_start_applied != true) or (.handoff_integration_sha != null and .handoff_delivery_verified_sha == null)' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: preserved handoff work has not been transferred" "$decision") | .stage=\"parked\" | .note=$(js "approve refused: preserved handoff work has not been transferred")"
        say "supervisor arbitration unit=$id: approve refused until the handoff is transferred -> parked"
      elif [[ "$(jqf -r '.main_red // false' <<<"$u")" == true ]] \
         || jqf -e '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage=="review-approve") | .key] | max // -1) as $i | any($h[($i + 1):][]; .stage == "merge-reverted")' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: record shows main-red or post-approval revert evidence" "$decision") | .stage=\"parked\" | .note=$(js "approve refused by the main-red/revert guard")"
        say "supervisor arbitration unit=$id: approve refused by the main-red/revert guard -> parked"
      else
        reviewed_sha="$(jqf -r '.reviewed_sha // empty' <<<"$u")"; reviewed_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
        if [[ "$reviewed_sha" =~ $SHA_RE && "$reviewed_pr_head" =~ $SHA_RE ]]; then
          set_unit "$id" "$(hist supervisor-approve "$reviewed_sha" "$decision") | .approved_sha=$(js "$reviewed_sha") | .ready_since=(.ready_since // $NOW_EPOCH) | .stage=\"ready-to-merge\""
          post_approved_status "$id" "$reviewed_pr_head"
          say "supervisor arbitration unit=$id: approve -> ready-to-merge at $reviewed_sha"
        else
          # 没有已评审的 head 对：不盲批，交给一次完整评审绑定 head 后再合并。
          set_unit "$id" "$(hist supervisor-approve "no reviewed head pair; routed to a fresh review" "$decision") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
          say "supervisor arbitration unit=$id: approve without a reviewed head -> fresh review"
        fi
      fi ;;
    park)
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$(js "${reason:-parked by supervisor arbitration}")"
      say "supervisor arbitration unit=$id: park" ;;
    close)
      pr="$(unit_field "$id" '.pr // empty')"
      if [[ "$pr" =~ ^[0-9]+$ ]]; then
        tick_prs_changed
        gh pr close "$pr" --comment "Autopilot supervisor arbitration: ${reason:-the unit outcome is resolved elsewhere}" >/dev/null 2>&1 \
          || say "supervisor arbitration unit=$id: could not close PR #$pr"
      fi
      set_unit "$id" "$(hist supervisor-close "$reason" "$decision") | .stage=\"closed\""
      say "supervisor arbitration unit=$id: close" ;;
    needs-info)
      question="$(supervisor_section_of "$rep" QUESTION | head -c 1000)"
      [[ -n "${question//[[:space:]]/}" ]] || question="$reason"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
  esac
}

supervisor_cap_field_line() { # report field → exactly one single-line value
  awk -v key="$2" '
    BEGIN { prefix = key ":"; count = 0 }
    index($0, prefix) == 1 {
      value = substr($0, length(prefix) + 1)
      sub(/^[[:space:]]+/, "", value)
      count++
    }
    END { if (count != 1) exit 1; print value }
  ' "$1" 2>/dev/null
}

supervisor_cap_verdict_of() { # report-path → exactly one final CLOSE/RECUT/RULE/FOUNDER verdict
  local report="$1" verdict last reason evidence question question_count
  [[ -s "$report" ]] || return 1
  [[ "$(grep -c '^VERDICT:' "$report" 2>/dev/null || true)" == 1 ]] || return 1
  verdict="$(grep -E '^VERDICT: (CLOSE|RECUT|RULE|FOUNDER)$' "$report" | sed 's/^VERDICT: //')"
  [[ "$verdict" =~ ^(CLOSE|RECUT|RULE|FOUNDER)$ ]] || return 1
  reason="$(supervisor_cap_field_line "$report" REASON)" || return 1
  evidence="$(supervisor_cap_field_line "$report" EVIDENCE)" || return 1
  [[ -n "${reason//[[:space:]]/}" && -n "${evidence//[[:space:]]/}" ]] || return 1
  question_count="$(grep -c '^QUESTION:' "$report" 2>/dev/null || true)"
  if [[ "$verdict" == FOUNDER ]]; then
    [[ "$question_count" == 1 ]] || return 1
    question="$(supervisor_cap_field_line "$report" QUESTION)" || return 1
    supervisor_founder_question_names_fact "$question" || return 1
  else
    [[ "$question_count" == 0 ]] || return 1
  fi
  last="$(awk 'NF { line = $0 } END { print line }' "$report")"
  [[ "$last" == "VERDICT: $verdict" ]] || return 1
  printf '%s\n' "$verdict"
}

supervisor_cap_second_rule() { # id reason evidence decision retry-state → another cap gets one retry, then a terminal park; neither asks the founder
  local id="$1" reason="$2" evidence="$3" decision="$4" retry="$5"
  if [[ "$retry" == spent ]]; then
    supervisor_cap_exhausted "$id" "$reason" "$decision"
  else
    set_unit "$id" '.supervisor_cap_retry="pending"'
    supervisor_cap_triage_park "$id" "second cap after an earlier RULE: $reason; evidence: $evidence" "$decision"
  fi
}

supervisor_cap_exhausted() { # id reason decision → terminal park with its unpark condition and one line to head
  local id="$1" reason="$2" decision="$3" u mark condition note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  mark="$(supervisor_arbiter_mark "$u")"
  condition="a new PR head, issue state or supervisor ruling"
  note="capped again after its one retry: $reason; unpark on $condition"
  cap_set_unit "$id" park "$note" "" "$(hist supervisor-cap-exhausted "$reason" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-cap-exhausted\" | .unpark_condition=$(js "$condition") | .cap_exhausted_mark=$(js "$mark") | .note=$(js "$note")" \
    && say "supervisor cap triage unit=$id: parked, retry spent"
  ( source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "cap-exhausted:$id:$mark" "cap-exhausted unit=$id: $note" ) \
    || say "supervisor cap triage unit=$id: cap-exhausted alert not delivered"
}

supervisor_cap_founder() { # id reason evidence report-path → one owner question in the supervisor inbox; the verdict parser proved the QUESTION
  local id="$1" reason="$2" evidence="$3" rep="$4" u issue question message decision inbox_status=0
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  question="$(supervisor_cap_field_line "$rep" QUESTION)"
  issue="$(jqf -r '.issue // empty' <<<"$u")"
  message="cap-triage-founder unit=$id${issue:+ issue=#$issue} question=$question reason=$reason evidence=$evidence"
  decision="$(decision_entry 'Supervisor cap triage: FOUNDER' "$reason" "$evidence" '[]' supervisor)"
  ( REPO_DIR="$ROOT"; source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "cap-triage-founder:$id" "$message" ) || inbox_status=$?
  if (( inbox_status != 0 )); then
    say "supervisor cap triage unit=$id: supervisor inbox helper failed rc=$inbox_status lib=$SCHEDULER_AGENT_LIB agent=$AGENT_HOME"
    supervisor_cap_triage_park "$id" "could not post founder question: $question" "$decision"
    say "supervisor cap triage unit=$id: founder question not posted; retained for retry"
    return 0
  fi
  cap_set_unit "$id" FOUNDER "founder decision required: $reason; question: $question" "$rep" "$(hist supervisor-cap-founder "$question" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-cap-founder\" | .note=$(js "founder decision required: $reason") | .supervisor_cap_question=$(js "$question")" \
    && say "supervisor cap triage unit=$id: FOUNDER question posted"
}

supervisor_apply_cap_verdict() { # id report-path verdict → cap-triage action
  local id="$1" rep="$2" verdict="$3" reason evidence decision issue pr state comment u cap_rules return_stage ruling retry
  reason="$(supervisor_cap_field_line "$rep" REASON)"
  evidence="$(supervisor_cap_field_line "$rep" EVIDENCE)"
  decision="$(decision_entry "Supervisor cap triage: $verdict" "$reason" "$evidence" '[]' supervisor)"
  retry="$(unit_field "$id" '.supervisor_cap_retry // empty')"
  case "$verdict" in
    CLOSE)
      issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
      comment="Cap triage closed this unit: $reason Evidence: $evidence"
      if [[ "$issue" =~ ^[0-9]+$ ]]; then
        gh issue close "$issue" --comment "$comment" >/dev/null 2>&1 || say "supervisor cap triage unit=$id: could not close issue #$issue"
      fi
      if [[ "$pr" =~ ^[0-9]+$ ]]; then
        state="$(tick_pr_state "$pr" 2>/dev/null || true)"
        if [[ "$state" != CLOSED && "$state" != MERGED ]]; then
          tick_prs_changed
          gh pr close "$pr" --comment "$comment" >/dev/null 2>&1 || say "supervisor cap triage unit=$id: could not close PR #$pr"
        fi
      fi
      cap_set_unit "$id" CLOSE "Cap triage closed this unit: $reason Evidence: $evidence" "$rep" "$(hist supervisor-cap-close "$reason" "$decision") | .stage=\"closed\" | .note=$(js "$reason") | del(.parked_reason)" \
        && say "supervisor cap triage unit=$id: CLOSE" ;;
    RECUT)
      supervisor_budget_recut "$id" "cap triage: $reason; evidence: $evidence" "$decision" \
        "cap triage could not complete the recut route" "supervisor cap triage recut: $reason" \
        supervisor-cap-triage-park supervisor-cap-triage-recut true ;;
    RULE)
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
      cap_rules="$(jqf -r '[(.history // [])[] | select(.stage=="supervisor-cap-rule")] | length' <<<"$u")"
      if (( cap_rules >= 1 )) && [[ "$retry" != pending ]]; then
        supervisor_cap_second_rule "$id" "$reason" "$evidence" "$decision" "$retry"
        return 0
      fi
      [[ "$retry" != pending ]] || set_unit "$id" '.supervisor_cap_retry="spent"'
      return_stage="$(jqf -r '.supervisor_cap_return_stage // empty' <<<"$u")"
      [[ -n "$return_stage" ]] || return_stage="$(supervisor_return_stage "$u")"
      ruling="Supervisor cap ruling: $reason Evidence: $evidence"
      cap_set_unit "$id" RULE "$ruling" "$rep" "$(hist supervisor-cap-rule "$reason" "$decision") | $(hist supervisor-arbiter-round "cap triage ruling applied: $reason" "$decision") | .cto_rulings=($(cto_rulings_norm) + [$(js "$ruling")]) | .stage=$(js "$return_stage") | .supervisor_cap_return_stage=$(js "$return_stage") | del(.parked_reason,.note,.supervisor_cap_from_parked)" \
        && say "supervisor cap triage unit=$id: RULE -> $return_stage" ;;
    FOUNDER)
      if [[ "$retry" == spent ]]; then
        supervisor_cap_exhausted "$id" "$reason" "$decision"
      else
        supervisor_cap_founder "$id" "$reason" "$evidence" "$rep"
      fi ;;
    *) return 1 ;;
  esac
}

supervisor_cap_triage_failed() { # id detail → retryable cap park
  local id="$1" detail="$2" decision
  decision="$(decision_entry 'Retry supervisor cap triage' "$detail" "$detail" '[]' scheduler)"
  cap_set_unit "$id" park "$detail" "" "$(hist supervisor-cap-triage-invalid "$detail" "$decision")" || :
  supervisor_cap_triage_park "$id" "$detail" "$decision"
}

supervisor_cap_reask_notice() { # unit-json → 复问段：引用上一次无效答案并重述四个允许动词
  local u="$1" prev
  prev="$(jqf -r '.supervisor_cap_invalid_answers[0] // ""' <<<"$u")"
  printf '## Re-ask: your previous cap-triage answer used a verb that is not allowed here\n\nYour previous answer to this final cap triage did not end in one valid verdict. It began with: "%s"\n\nThe six normal-arbitration actions — requeue, approve, park, close, reroute,\nneeds-info — and their ACTION line do not apply to a final cap triage. Answer\nagain now, choosing exactly one of the four allowed verdicts, and make the\nfinal non-blank line of your reply exactly one of:\n\nVERDICT: CLOSE\nVERDICT: RECUT\nVERDICT: RULE\nVERDICT: FOUNDER\n' "$prev"
}

supervisor_cap_triage_reask_or_park() { # id report-path → 一次复问；第二次无效答案才真正 park
  local id="$1" rep="$2" u reasks first excerpt detail decision note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  reasks="$(jqf -r '.supervisor_cap_reask // 0' <<<"$u")"
  excerpt="$(head -c 200 "$rep" | tr '\n' ' ')"
  detail="invalid final cap triage report $(basename "$rep"): $excerpt"
  if (( reasks < 1 )); then
    decision="$(decision_entry 'Re-ask one invalid cap triage answer' 'the answer was not one of the four allowed verdicts CLOSE/RECUT/RULE/FOUNDER; the re-ask restates them' "$detail" '[]' scheduler)"
    cap_set_unit "$id" reask "$detail" "$rep" "$(hist supervisor-cap-triage-reask "$detail" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-cap-triage-reask\" | .supervisor_cap_reask=1 | .supervisor_cap_invalid_answers=[$(js "$excerpt")] | .note=$(js "cap triage answer invalid once; one re-ask restates the allowed verdicts")" \
      && say "supervisor cap triage unit=$id: invalid answer; one re-ask will restate the allowed verdicts"
  else
    first="$(jqf -r '.supervisor_cap_invalid_answers[0] // empty' <<<"$u")"
    note="two invalid cap triage answers, neither ended in one of CLOSE/RECUT/RULE/FOUNDER; first answer: ${first:-unknown}; re-ask answer: $excerpt"
    decision="$(decision_entry 'Park after two invalid cap triage answers' "$note" "$detail" '[]' scheduler)"
    cap_set_unit "$id" park "$note" "$rep" "$(hist supervisor-cap-triage-invalid-final "$note" "$decision") | .stage=\"parked\" | .parked_reason=\"supervisor-cap-triage-invalid\" | .note=$(js "$note") | del(.supervisor_cap_reask, .supervisor_cap_invalid_answers)" \
      && say "supervisor cap triage unit=$id: parked after two invalid answers"
  fi
}

supervisor_apply_jev_action() { # id action confidence event-id → mature, confident Jev decision
  local id="$1" action="$2" confidence="$3" event_id="$4" u reason evidence decision question note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  reason="Jev selected $action with confidence $confidence after the shadow sample"
  evidence="jev-latest f12 event=$event_id"
  decision="$(decision_entry "TypeSafe Jev: $action" "$reason" "$evidence" '[]' typesafe)"
  case "$action" in
    requeue) supervisor_requeue_unit "$id" requeue "$reason" "$decision" ;;
    recut) supervisor_budget_recut "$id" "$reason (jev-latest f12 event=$event_id)" "$decision" \
      "Jev recut deferred" "Jev arbitration recut" supervisor-park supervisor-jev-recut ;;
    escalate)
      question="$(supervisor_needs_info_question "$u")"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
    park)
      note="$(js "$reason")"
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$note"
      say "supervisor arbitration unit=$id: Jev park" ;;
    *) return 1 ;;
  esac
}

supervisor_record_jev_comparison() { # worker-json terra-action → shadow comparison
  local worker="$1" action="$2" jev event_id candidate confidence rollout_ready baseline input
  jev="$(jqf -c '.jev // empty' <<<"$worker")"
  [[ -n "$jev" && "$jev" != null ]] || return 0
  event_id="$(jqf -r '.event_id // empty' <<<"$jev")"
  candidate="$(jqf -r '.candidate // empty' <<<"$jev")"
  confidence="$(jqf -r '.confidence // empty' <<<"$jev")"
  rollout_ready="$(jqf -r '.rollout_ready == true' <<<"$jev")"
  [[ -n "$event_id" && -n "$candidate" && "$confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || return 0
  case "$action" in
    requeue|reroute) baseline=requeue ;;
    needs-info) baseline=escalate ;;
    park) baseline=park ;;
    *) baseline="other:$action" ;;
  esac
  input="$(jqf -cn --arg event_id "$event_id" --arg candidate "$candidate" --arg current "$baseline" \
    --argjson confidence "$confidence" --argjson force_shadow "$([[ "$rollout_ready" == true ]] && echo false || echo true)" \
    '{event_id:$event_id,candidate:$candidate,currentDecision:$current,confidence:$confidence,force_shadow:$force_shadow}')"
  printf '%s\n' "$input" | node "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.mjs" record f12 >/dev/null 2>&1 || true
}

harvest_supervisor_arbiter() { # worker JSON: harvest regular arbitration or final cap-triage report
  local w="$1" unit pid report log action stream tk session_id cap_triage decided=false
  unit="$(jqf -r .unit <<<"$w")"; pid="$(jqf -r .pid <<<"$w")"; report="$(jqf -r .report <<<"$w")"; log="$SUP/$(jqf -r .log <<<"$w")"
  cap_triage="$(jqf -r '.cap_triage // false' <<<"$w")"
  stream="$(python3 "$USAGE_READER" codex-stream "$log" 2>/dev/null || true)"
  tk="$(jqf -r '.fresh // empty' <<<"$stream")"
  [[ "$tk" =~ ^[0-9]+$ ]] && set_unit "$unit" ".tokens = ((.tokens // 0) + $tk)"
  session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
  python3 "$USAGE_READER" codex-ingest "$log" "$session_id" "$(jqf -r .started <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
  if [[ "$cap_triage" == true ]]; then
    if [[ ! -s "$SUP/$report" ]]; then
      supervisor_cap_triage_failed "$unit" "final cap triage worker produced no report $report"
      say "supervisor cap triage unit=$unit: worker produced no report"
    elif action="$(supervisor_cap_verdict_of "$SUP/$report")"; then
      say "supervisor cap triage unit=$unit verdict=$action"
      decided=true
      set_unit "$unit" "del(.supervisor_cap_reask, .supervisor_cap_invalid_answers)"
      supervisor_apply_cap_verdict "$unit" "$SUP/$report" "$action"
    else
      supervisor_cap_triage_reask_or_park "$unit" "$SUP/$report"
      say "supervisor cap triage unit=$unit: report did not end in one valid verdict"
    fi
  elif [[ ! -s "$SUP/$report" ]]; then
    set_unit "$unit" "$(hist supervisor-arbiter-no-output "$(tail -c 200 "$log" 2>/dev/null | tr '\n' ' ')")"
    say "supervisor arbitration unit=$unit: worker produced no report"
  else
    if action="$(supervisor_action_of "$SUP/$report")"; then
      say "supervisor arbitration unit=$unit action=$action"
      decided=true
      supervisor_record_jev_comparison "$w" "$action"
      supervisor_apply_action "$unit" "$action" "$SUP/$report"
    else
      set_unit "$unit" "$(hist supervisor-arbiter-invalid "$(head -c 200 "$SUP/$report" | tr '\n' ' ')")"
      say "supervisor arbitration unit=$unit: no single ACTION line in $report"
    fi
  fi
  # A run with no answer decided nothing: only a decision holds the next run.
  [[ "$decided" != true ]] || supervisor_arbiter_record_left "$unit"
  jqf --argjson pid "$pid" --arg finished "$STAMP" \
    '(.workers[] |= (if .pid==$pid and .type=="supervise" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
}
