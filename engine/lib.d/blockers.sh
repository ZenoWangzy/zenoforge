blocker_root_fail() {
  [ -n "${BLOCKER_ROOT_FAIL_REASON:-}" ] || BLOCKER_ROOT_FAIL_REASON="$*"
  return 1
}


# Reconcile an open issue that still blocks open work. A completed recut
# parent is an umbrella; move its outgoing edges to its live children. A
# not-completed conclusion gets one automatic exit, chosen from its durable
# reason. Each new conclusion episode gets a fresh attempt budget; a repeated
# conclusion in that episode or after actual recut children escalates once.
reconcile_blocking_issue_root() {
  local issue_json="$1" open_issues_json="$2" n issue_state state owner_state dependents_json has_state_label
  local children_json child child_state dependent dependent_json existing_child_edges recut_status
  local exit_count recut_parent=0 episode reason latest_reason reason_text action reason_class escalated_episode blockers pipeline_system_status=0
  local last_episode last_action delivery_failed_episode retry_failed_route=0 thread_id question thread_json inbox state_labels_json child_list pr_number
  local terminal_candidate conclusion_owned_hold conclusion_json conclusion_class="" conclusion_route="" conclusion_owner="" conclusion_signature conclusion_reason expected_scope comment_marker matching_scope scope_decision risk_class_escalation
  local recut_reason recut_reason_text recut_reason_file recut_reason_json attempts_before_reset reset_record reset_reason reset_reason_file prerequisite_index prerequisite_number prerequisite_state prerequisite_record prerequisite_disqualified prerequisite_state_reason prerequisite_reason_file prerequisite_repeat_status
  local prerequisite_marker prerequisite_title prerequisite_body prerequisite_body_file prerequisite_url prerequisite_json issue_title
  local -a edit_args=() live_children=()

  BLOCKER_ROOT_FAIL_REASON=""
  if ! jq -e 'type == "object" and (.number | type) == "number" and (.blocking.nodes | type) == "array"' \
    <<< "$issue_json" >/dev/null 2>&1; then
    echo "reconcile_blocking_issue_root: invalid issue graph row" >&2
    blocker_root_fail "invalid issue graph row passed to reconcile_blocking_issue_root"
    return 2
  fi
  n="$(jq -r '.number' <<< "$issue_json")"
  issue_state="$(jq -r '.state // empty | ascii_downcase' <<< "$issue_json")"
  [ "$issue_state" = open ] || return 0
  dependents_json="$(jq -c '[.blocking.nodes[] | select((.state | ascii_downcase) == "open") | .number | select(type == "number")]' <<< "$issue_json")" \
    || { blocker_root_fail "could not extract open dependents from the graph row for #$n"; return 2; }
  state="$(state_read "$n")" || { blocker_root_fail "state read failed for #$n"; return 1; }
  # Only these fields: the whole state can pass the 128 KiB per-argument limit.
  owner_state="$(jq -c '{run:{conclusion:{route:.run.conclusion.route,owner:.run.conclusion.owner}},hold:{kind:.hold.kind}}' <<< "$state")" \
    || { blocker_root_fail "state projection failed for #$n"; return 1; }
  terminal_candidate="$(jq -r --argjson owner_state "$owner_state" 'any(.labels[]?; .name == "concluded") or (any(.labels[]?; .name == "on-hold") and (($owner_state.run.conclusion.route // "") == "requeue"))' <<< "$issue_json")"
  # A conclusion hold is this function's own (conclusion_hold, or a backfilled record of one).
  # Any other hold belongs to its holder and hold_sweep: requeueing it here was suppressed by
  # the hold guard and repeated every tick, ~4.5s and a history entry each (2026-09-30).
  conclusion_owned_hold="$(jq -r --argjson owner_state "$owner_state" 'any(.labels[]?; .name == "on-hold")
    and (($owner_state.hold.kind // "") == "conclusion"
      or (($owner_state.hold.kind // "") == "backfill" and ($owner_state.run.conclusion.owner // "") == "issue-pipeline"))' <<< "$issue_json")"
  if ! jq -e 'type == "object" and has("recut_children")' <<< "$state" >/dev/null 2>&1; then
    # The observed silent failure (#2511/#2520, 2026-10-08 07:37-07:38Z): a
    # transient gh api sub_issues failure fails this read closed. The root
    # stays for the next tick by design; the reason must still reach the inbox.
    native_parent_subissues_json "$n" >/dev/null \
      || { blocker_root_fail "native sub-issue read unavailable for #$n"; return 1; }
  fi
  if children_json="$(recut_parent_children_json "$n" "$state")"; then
    reconcile_recut_parent_children "$n" "$children_json" "$open_issues_json" \
      || { blocker_root_fail "recut umbrella reconcile failed for #$n"; return 1; }
    return 0
  else
    recut_status=$?
    [ "$recut_status" -ne 2 ] || { blocker_root_fail "recut evidence read failed (status $recut_status) for #$n"; return 1; }
  fi
  if [ "$conclusion_owned_hold" != true ] && jq -e 'any(.labels[]?; .name == "on-hold")' <<< "$issue_json" >/dev/null; then
    return 0
  fi
  [ "$(jq 'length' <<< "$dependents_json")" -gt 0 ] || [ "$terminal_candidate" = true ] || return 0
  pipeline_system_route_status "$n" "$issue_json" fresh || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      pipeline_system_enabled=true
      if [ "$terminal_candidate" != true ] && [ "$(jq -r '.model_policy.step // empty' <<< "$state")" = conclude ]; then
        return 0
      fi
      if [ "$terminal_candidate" != true ]; then
        pipeline_system_return_to_implement "$n" && return 0
        blocker_root_fail "pipeline-system return-to-implement failed for #$n"
        return 1
      fi
      ;;
    1) pipeline_system_enabled=false ;;
    *)
      echo "reconcile_blocking_issue_root: cannot classify lane for #$n; keeping root unchanged" >&2
      blocker_root_fail "cannot classify pipeline-system lane for #$n"
      return 1
      ;;
  esac

  if [ "$terminal_candidate" = true ]; then
    if [ "$pipeline_system_status" = 0 ]; then
      state_merge "$n" '.pipeline_system.enabled = true' || { blocker_root_fail "pipeline-system state flag write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
    conclusion_class="$(jq -r '.run.conclusion.class // empty' <<< "$state")"
    conclusion_route="$(jq -r '.run.conclusion.route // empty' <<< "$state")"
    conclusion_signature="$(jq -r '.run.conclusion.signature // empty' <<< "$state")"
    risk_class_escalation="$(jq -r '.model_policy.failure.stage == "risk-class"
      and .model_policy.failure.transition == "conclude"
      and .model_policy.failure.early_stop.reason == "same-failure"
      and .model_policy.failure.early_stop.advisor_seen == false' <<< "$state")"
    if [ "$pipeline_system_status" = 0 ] && [ "$conclusion_class" = ticket ] \
      && [ "$risk_class_escalation" = true ]; then
      # The implement gate already recorded the refusal in the persistent
      # model-policy ladder. route_to_advisor holds it for the supervisor
      # instead of opening another implement run.
      state_merge_attempt_transition "$n" '.attempts = 0 | .run.conclusion.signature = "risk-class-refusal"' \
        || { blocker_root_fail "risk-class admission reset failed for #$n"; return 1; }
      route_to_advisor "$n" concluded true "$issue_json" \
        || { blocker_root_fail "risk-class advisor route failed for #$n"; return 1; }
      if state_read "$n" | jq -e '.hold.kind == "pipeline-system-risk-class"' >/dev/null; then
        state_merge "$n" '.run.conclusion.route = "on-hold" | .run.conclusion.owner = "supervisor"' \
          || { blocker_root_fail "risk-class hold write failed for #$n"; return 1; }
      fi
      return 0
    fi
    if [ "$pipeline_system_status" = 0 ] && [ "$conclusion_class" = ticket ] \
      && [ "$conclusion_signature" != pipeline-system-delivery-failed ]; then
      conclusion_json="$(jq -cn --arg reason "$(jq -r '.run.conclusion.reason // .run.needs_md // empty' <<< "$state")" \
        '{class:"ticket",route:"requeue",owner:"issue-pipeline",signature:"pipeline-system-requeue",reason:$reason}')" \
        || { blocker_root_fail "pipeline-system requeue conclusion build failed for #$n"; return 1; }
      state_merge "$n" ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "pipeline-system requeue conclusion write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
      conclusion_route=requeue
    fi
    if [ "$(jq -r '.run.outcome // empty' <<< "$state")" = merged ]; then
      conclusion_json='{"class":"completed","route":"awaiting-release","owner":"release","signature":"merged"}'
      pr_number="$(jq -r '.run.evidence.pr_number // empty' <<< "$state")"
      state_merge "$n" ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "merged conclusion write failed for #$n"; return 1; }
      mark_awaiting_release "$n" "$pr_number" || { blocker_root_fail "awaiting-release mark failed for #$n (pr=$pr_number)"; return 1; }
      return 0
    fi
    if ! [[ "$conclusion_class" =~ ^(infrastructure|pipeline-defect|ticket)$ ]] \
      || ! [[ "$conclusion_route" =~ ^(requeue|recut|needs-info|close-not-planned)$ ]]; then
      conclusion_json="$(conclusion_classification_for_state "$n" "$state" "$(jq -r '.run.needs_md // empty' <<< "$state")")" \
        || { blocker_root_fail "conclusion classification failed for #$n"; return 1; }
      conclusion_class="$(jq -r '.class' <<< "$conclusion_json")"
      conclusion_route="$(jq -r '.route' <<< "$conclusion_json")"
      issue_transition "$n" concluded conclude:reconcile ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "concluded transition failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
    conclusion_owner="$(jq -r '.run.conclusion.owner // empty' <<< "$state")"
    conclusion_signature="$(jq -r '.run.conclusion.signature // "unknown"' <<< "$state")"
    conclusion_reason="$(jq -r '.run.conclusion.reason // .run.needs_md // empty' <<< "$state")"
    if [ "$conclusion_route" = close-not-planned ]; then
      guarded_issue_comment "$n" "$BOT_DISCLAIMER
这项工作已按不计划实施处理。原因：$conclusion_reason" \
        || { blocker_root_fail "close-not-planned comment failed for #$n"; return 1; }
      issue_transition "$n" wontfix close-not-planned '.closed_by_pipeline = true | .run.conclusion.owner = "closed"' \
        || { blocker_root_fail "close-not-planned transition failed for #$n"; return 1; }
      guarded_write gh issue close "$n" --repo "$REPO" \
        || { blocker_root_fail "close-not-planned issue close failed for #$n"; return 1; }
      return 0
    fi
    if [ "$conclusion_class" = pipeline-defect ]; then
      supervisor_inbox_append_once "conclusion-pipeline-defect signature=$conclusion_signature" \
        "conclusion-pipeline-defect signature=$conclusion_signature issue=#$n route=requeue" \
        || { blocker_root_fail "pipeline-defect inbox append failed for #$n"; return 1; }
      if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ] \
        && [ "$conclusion_owner" = supervisor-inbox ]; then
        return 0
      fi
      conclusion_hold "$n" supervisor-inbox || { blocker_root_fail "pipeline-defect hold failed for #$n"; return 1; }
      return 0
    fi
    if [ "$conclusion_route" = requeue ]; then
      expected_scope="$(selection_scope_json <<< "$state")" || expected_scope='[]'
      matching_scope="$(jq -r '.run.conclusion.scope // empty' <<< "$state")"
      scope_decision=clear
      if [ -n "$matching_scope" ]; then
        scope_decision="$(quarantine_decision "$matching_scope")" \
          || { blocker_root_fail "quarantine decision failed for #$n (scope $matching_scope)"; return 1; }
      fi
      if stage_unit_active implement "$n" || [ "$scope_decision" = open ] \
        || ! stage_dispatch_allowed implement "$expected_scope"; then
        if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ] \
          && [ "$conclusion_owner" = issue-pipeline ]; then
          return 0
        fi
        conclusion_hold "$n" issue-pipeline || { blocker_root_fail "conclusion hold failed for #$n"; return 1; }
        return 0
      fi
      [ "$scope_decision" != canary ] || quarantine_mark_canary "$matching_scope" \
        || { blocker_root_fail "canary quarantine mark failed for #$n"; return 1; }
      if [ "$conclusion_owner" = release ]; then
        return 0
      fi
      if [ "$conclusion_class" = infrastructure ]; then
        conclusion_requeue_comment_once "$n" || { blocker_root_fail "infrastructure requeue comment failed for #$n"; return 1; }
      fi
      if [ "$conclusion_owned_hold" = true ]; then
        state_requeue "$n" release-hold hold-requeue \
          || { blocker_root_fail "release-hold requeue failed for #$n"; return 1; }
      else
        state_requeue "$n" "" conclusion-requeue \
          || { blocker_root_fail "conclusion requeue failed for #$n"; return 1; }
      fi
      if [ "$pipeline_system_status" = 0 ]; then
        state_merge "$n" '.run.conclusion.owner = "issue-pipeline"' \
          || { blocker_root_fail "conclusion owner write failed for #$n"; return 1; }
      else
        state_merge "$n" '.run.conclusion.owner = "implement"' \
          || { blocker_root_fail "conclusion owner write failed for #$n"; return 1; }
      fi
      return 0
    fi
    if [ -z "$(jq -r '.run.outcome // empty' <<< "$state")" ]; then
      state_merge "$n" '.run.outcome = "not-completed" | .run.outcome_inferred = true | .run.needs_md = (.run.needs_md // "No terminal outcome was recorded; please confirm the intended result.")' \
        || { blocker_root_fail "outcome inference write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
  fi
  if jq -e 'any(.labels[]?; .name == "concluded")' <<< "$issue_json" >/dev/null; then
    if [ "$(jq -r '.run.outcome // empty' <<< "$state")" != not-completed ]; then
      return 0
    fi
    episode="$(jq -r '.run.concluded_at // "unknown"' <<< "$state")"
    exit_count="$(jq -r '.concluded_blocker_recovery.auto_exits // 0 | if type == "number" then . else 0 end' <<< "$state")"
    last_episode="$(jq -r '.concluded_blocker_recovery.last_episode // empty' <<< "$state")"
    last_action="$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")"
    delivery_failed_episode="$(jq -r '.concluded_blocker_recovery.question_delivery_failed_episode // empty' <<< "$state")"
    # Count exits by conclusion timestamp, not across the issue's lifetime.
    if [ "$exit_count" -ge 1 ] && [ "$last_action" = needs-advisor ] \
      && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null; then
      retry_failed_route=1
    elif jq -e '(.recut_children | type) == "array" and (.recut_children | length) > 0' <<< "$state" >/dev/null \
      || { [ "$exit_count" -ge 1 ] && [ "$last_episode" = "$episode" ]; }; then
        inbox="$AGENT_HOME/supervisor-inbox"
        escalated_episode="$(jq -r '.concluded_blocker_recovery.escalated_episode // empty' <<< "$state")"
        if [ "$escalated_episode" != "$episode" ] && ! grep -Fq "concluded-blocker-recovery issue=#$n " "$inbox" 2>/dev/null; then
          blockers="$(jq -r 'map(tostring) | join(",")' <<< "$dependents_json")" \
            || { blocker_root_fail "dependents extraction failed for #$n escalation"; return 1; }
          supervisor_inbox_append concluded-blocker-recovery \
            "issue=#$n episode=$episode reason=repeat-after-recut blockers=$blockers" \
            || { blocker_root_fail "repeat-conclusion escalation inbox append failed for #$n"; return 1; }
          state_merge "$n" ".concluded_blocker_recovery.supervisor_escalated_at = (now | todate) | .concluded_blocker_recovery.escalated_episode = $(jq -cn --arg episode "$episode" '$episode')" \
            || { blocker_root_fail "repeat-conclusion escalation write failed for #$n"; return 1; }
          echo "issue-pipeline: blocker-root issue=#$n class=repeat action=supervisor-escalation blockers=$blockers" >&2
          BLOCKING_ROOT_GRAPH_CHANGED=1
        fi
        return 0
    fi
  elif [ "$(jq -r '.run.outcome // empty' <<< "$state")" = not-completed ] \
    && [ "$(jq -r '.concluded_blocker_recovery.auto_exits // 0' <<< "$state")" -ge 1 ] \
    && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null \
    && { \
      { jq -e 'any(.labels[]?; .name == "needs-recut")' <<< "$issue_json" >/dev/null \
        && [ "$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")" = needs-recut ]; } \
      || { jq -e 'any(.labels[]?; .name == "needs-advisor")' <<< "$issue_json" >/dev/null \
        && [ "$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")" = needs-advisor ]; } \
    }; then
    episode="$(jq -r '.run.concluded_at // "unknown"' <<< "$state")"
    exit_count="$(jq -r '.concluded_blocker_recovery.auto_exits // 0' <<< "$state")"
    last_episode="$(jq -r '.concluded_blocker_recovery.last_episode // empty' <<< "$state")"
    last_action="$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")"
    delivery_failed_episode="$(jq -r '.concluded_blocker_recovery.question_delivery_failed_episode // empty' <<< "$state")"
    if [ "$last_action" = needs-recut ] && [ "$last_episode" != "$episode" ]; then
      return 0
    fi
    [ "$last_action" = needs-advisor ] && [ "$delivery_failed_episode" = "$episode" ] \
      || retry_failed_route=1
  fi

  if [ "$(jq -r '.run.outcome // empty' <<< "$state")" = not-completed ] \
    && { jq -e 'any(.labels[]?; .name == "concluded")' <<< "$issue_json" >/dev/null \
      || [ "$retry_failed_route" = 1 ]; }; then
    recut_reason="$(jq -r '.recut_refused_reason // empty' <<< "$state")"
    if [ -z "$recut_reason" ] && [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ]; then
      # Legacy refusals predate the durable reason field; recover the latest
      # matching comment once, then keep using the normal state file.
      recut_reason="$(gh issue view "$n" --repo "$REPO" --json comments | jq -r '
        [ .comments[]?.body // ""
          | select(contains("流水线尝试把这张票拆成可独立交付的小票，但没能做到："))
          | split("流水线尝试把这张票拆成可独立交付的小票，但没能做到：")[1]
          | split("\n\n")[0]
          | select(length > 0)
        ] | last // ""
      ')" || { blocker_root_fail "legacy refusal comment read failed for #$n"; return 1; }
      if [ -n "$recut_reason" ]; then
        recut_reason_file="$(jq_arg_file "$recut_reason")" \
          || { blocker_root_fail "legacy refusal reason temp file failed for #$n"; return 1; }
        if ! recut_reason_json="$(jq -cn --rawfile reason "$recut_reason_file" '$reason')"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason json build failed for #$n"
          return 1
        fi
        if ! state_merge "$n" ".recut_refused_reason = $recut_reason_json"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason write failed for #$n"
          return 1
        fi
        if ! state="$(jq --rawfile reason "$recut_reason_file" '.recut_refused_reason = $reason' <<< "$state")"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason merge into local state failed for #$n"
          return 1
        fi
        rm -f -- "$recut_reason_file"
      fi
    fi
    latest_reason="$(jq -r '
      [(.model_policy.failure // null), ((.model_policy.failures // [])[-1] // null), (.model_policy.retry_note // null)]
      | map(select(type == "object" and (.reason // "") != ""))
      | sort_by(.recorded_at // "") | last.reason // empty
    ' <<< "$state")"
    reason="$(jq -r '[.run.needs_md, .last_failure_reason] | map(select(type == "string" and length > 0)) | first // empty' <<< "$state")"
    if [[ "$reason" =~ ^(Implement dispatch reached its 4-attempt cap|Four implement attempts failed|Configured model escalation exhausted) ]] && [ -n "$latest_reason" ]; then
      reason="$latest_reason"
    fi
    [ -n "$reason" ] || reason="$latest_reason"
    reason_text="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')"
    if [[ "$reason_text" =~ previous[[:space:]](model|implement)[[:space:]]unit[[:space:]]ended[[:space:]](without[[:space:]]recording[[:space:]]a[[:space:]]result|with[[:space:]]systemd[[:space:]]result=(oom-kill|timeout|watchdog|start-limit-hit))|previous[[:space:]](model|implement)[[:space:]]unit[[:space:]]has[[:space:]]no[[:space:]]persisted[[:space:]]systemd[[:space:]]result|ci[[:space:]-]+runner[[:space:]]capacity|ci[[:space:]-]+deadline|merge-lock[[:space:]]contention|provider[[:space:]]quota|provider[[:space:]]outage|network[[:space:]]fault|docker[[:space:]]hub[[:space:]]dns/connect[[:space:]]timeout|checkout[[:space:]]step[[:space:]]failed[[:space:]]before[[:space:]]project[[:space:]]checks ]]; then
      reason_class=infrastructure
      action=ready-for-agent
    elif [ "$(jq -r '.review_verdict // empty' <<< "$state")" = INPUT_INCOMPLETE ] \
      || [[ "$reason_text" =~ p[0-3]/l[0-4][[:space:]]path|product[[:space:]]decision|input[_[:space:]-]+incomplete|missing[[:space:]].*decision ]]; then
      reason_class=product-decision
      action=needs-info
    elif [ -n "$reason" ]; then
      reason_class=real-failure
      action=needs-recut
    else
      reason_class=unrecorded-reason
      action=needs-info
    fi

    if [ "$(jq -r '.run.conclusion.class // empty' <<< "$state")" = ticket ]; then
      case "$(jq -r '.run.conclusion.route // empty' <<< "$state")" in
        needs-info) reason_class=product-decision; action=needs-info ;;
        recut) reason_class=real-failure; action=needs-recut ;;
      esac
    fi

    recut_reason_text="$(printf '%s' "$recut_reason" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$recut_reason" ] && [ "$retry_failed_route" != 1 ]; then
      if [[ "$recut_reason_text" =~ (not[[:space:]]found|does[[:space:]]not[[:space:]]exist|no[[:space:]]|未找到|不存在|没有|尚无|缺少) ]] \
        && [[ "$recut_reason_text" =~ (implementation|persistence|storage|finalizer|writer|实现|持久化|存储|原生|事件) ]] \
        && ! [[ "$recut_reason_text" =~ 子票|child|索引|超过|上限|成环|循环 ]]; then
        reason_class=missing-prerequisite
        action=prerequisite
      elif [[ "$recut_reason_text" =~ risk_class=|level=|权限阶段|permission[[:space:]]stage|not.*too[[:space:]]big ]]; then
        reason_class=product-decision
        action=needs-info
      else
        reason_class=unresolved-recut
        action=needs-info
      fi
    elif [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ] && [ "$retry_failed_route" != 1 ]; then
      reason_class=unresolved-recut
      action=needs-info
    fi

    if [ "$retry_failed_route" = 1 ]; then
      if [ "$last_action" = needs-advisor ]; then
        reason_class=product-decision
        action=needs-info
      elif [ "$action" != needs-info ]; then
        return 0
    fi
  fi

  if [ "$action" = prerequisite ]; then
    prerequisite_marker="concluded-root-prerequisite-$n"
    prerequisite_index="$(gh issue list --repo "$REPO" --state all --limit 1000 \
      --search "in:title $prerequisite_marker" --json number,title,body,state,labels,stateReason)" \
      || { blocker_root_fail "prerequisite issue search failed for #$n"; return 1; }
    if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number")' \
      <<< "$prerequisite_index" >/dev/null; then
      echo "reconcile_blocking_issue_root: invalid prerequisite search result for #$n" >&2
      blocker_root_fail "invalid prerequisite search result for #$n"
      return 1
    fi
    prerequisite_number="$(jq -r --arg marker "$prerequisite_marker" \
      '[.[] | select((.title // "") | contains($marker))] | first.number // empty' \
      <<< "$prerequisite_index")"
    prerequisite_state="$(jq -r --argjson number "${prerequisite_number:-0}" \
      '[.[] | select(.number == $number)][0].state // empty | ascii_downcase' \
      <<< "$prerequisite_index")"
    prerequisite_record="$(jq -c --argjson number "${prerequisite_number:-0}" \
      '[.[] | select(.number == $number)][0] // {}' <<< "$prerequisite_index")"
    prerequisite_disqualified="$(jq -r \
      'any(.labels[]?; .name == "duplicate" or .name == "concluded")' \
      <<< "$prerequisite_record")"
    prerequisite_state_reason="$(jq -r '.stateReason // empty' <<< "$prerequisite_record")"
    if [ "$prerequisite_state" = closed ] \
      && { [ "$prerequisite_disqualified" = true ] || [ "$prerequisite_state_reason" = NOT_PLANNED ]; }; then
      reason_class=unresolved-recut
      action=needs-info
    elif [ "$prerequisite_state" = closed ] && [ -n "$prerequisite_number" ]; then
      prerequisite_reason_file="$(jq_arg_file "$recut_reason")" \
        || { blocker_root_fail "prerequisite repeat-check temp file failed for #$n"; return 1; }
      if jq -e --argjson prerequisite "$prerequisite_number" --rawfile reason "$prerequisite_reason_file" '
          .concluded_blocker_recovery.prerequisite_issue == $prerequisite
          and .concluded_blocker_recovery.attempts_reset.reason_class == "missing-prerequisite"
          and .concluded_blocker_recovery.attempts_reset.reason == $reason
          and (.concluded_blocker_recovery.attempts_reset.action == "ready-for-agent"
            or .concluded_blocker_recovery.attempts_reset.action == "prerequisite")
        ' <<< "$state" >/dev/null; then
        reason_class=unresolved-recut
        action=needs-info
      else
        prerequisite_repeat_status=$?
        if [ "$prerequisite_repeat_status" -ne 1 ]; then
          rm -f -- "$prerequisite_reason_file"
          blocker_root_fail "prerequisite repeat-check jq failed (status $prerequisite_repeat_status) for #$n"
          return 1
        fi
      fi
      rm -f -- "$prerequisite_reason_file"
    fi
  fi

  case "$action" in
      ready-for-agent)
        state_requeue "$n" "" conclusion-requeue \
          || { blocker_root_fail "conclusion requeue failed for #$n"; return 1; }
        ;;
      needs-recut)
        route_to_recut "$n" "$issue_json" \
          || { blocker_root_fail "recut route failed for #$n"; return 1; }
        ;;
      prerequisite)
        if [ -z "$prerequisite_number" ]; then
          # A stable issue title makes create retry-safe if linking or state
          # persistence failed after GitHub accepted the first create.
          issue_title="$(jq -r '.title // ("issue #" + (.number|tostring))' <<< "$issue_json")"
          prerequisite_title="前置能力 [$prerequisite_marker]: $issue_title"
          prerequisite_body="## 背景

父票：#$n

拆分记录显示，父票进入 guarded implement 前缺少以下能力：

$recut_reason

## 验收条件

- 在父票要求的真实路径中实现上述缺失能力，不以模拟入口代替生产调用方。
- 加入最小正向与拒绝/持久化回读测试，覆盖父票已有的租户、身份、撤权和幂等边界。
- 父票解除本依赖后可直接消费此能力；不把未实现部分写成已完成。"
          prerequisite_body_file="$(jq_arg_file "$prerequisite_body")" \
            || { blocker_root_fail "prerequisite body temp file failed for #$n"; return 1; }
          if [ "${DRY_RUN:-0}" = 1 ]; then
            guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement --label needs-triage --parent "$n" || {
                rm -f -- "$prerequisite_body_file"
                blocker_root_fail "prerequisite issue create failed for #$n (dry-run)"
                return 1
              }
            rm -f -- "$prerequisite_body_file"
            echo "issue-pipeline: blocker-root issue=#$n class=missing-prerequisite action=prerequisite (dry-run)" >&2
            return 0
          fi
          if [ "$(roadmap_switch_value)" = true ]; then
            prerequisite_url="$(guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement)" || prerequisite_url=""
          else
            prerequisite_url="$(guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement --label needs-triage --parent "$n")" || prerequisite_url=""
          fi
          if [ -z "$prerequisite_url" ]; then
            rm -f -- "$prerequisite_body_file"
            blocker_root_fail "prerequisite issue create failed for #$n"
            return 1
          fi
          rm -f -- "$prerequisite_body_file"
          prerequisite_number="${prerequisite_url##*/}"
          [[ "$prerequisite_number" =~ ^[0-9]+$ ]] || {
            echo "reconcile_blocking_issue_root: prerequisite issue create returned no issue number for #$n" >&2
            blocker_root_fail "prerequisite issue create returned no issue number for #$n (got '${prerequisite_number:-empty}')"
            return 1
          }
          if [ "$(roadmap_switch_value)" = true ]; then
            prerequisite_json="$(jq -cn --argjson number "$prerequisite_number" --arg title "$prerequisite_title" \
              --arg body "$prerequisite_body" '{number:$number,title:$title,body:$body,state:"OPEN",labels:[{name:"enhancement"}]}')" \
              || { blocker_root_fail "prerequisite roadmap intake JSON failed for #$n"; return 1; }
            issue_transition "$prerequisite_number" needs-triage prerequisite-created . 0 "$prerequisite_json" "$n" \
              || { blocker_root_fail "prerequisite roadmap placement or triage label failed for #$n"; return 1; }
          fi
          prerequisite_state=open
        fi
        if [ "$prerequisite_state" = closed ]; then
          action=ready-for-agent
          state_requeue "$n" "" conclusion-requeue \
            ".concluded_blocker_recovery.prerequisite_issue = $prerequisite_number" \
            || { blocker_root_fail "prerequisite-closed requeue failed for #$n"; return 1; }
        else
          guarded_write gh issue edit "$n" --repo "$REPO" --add-blocked-by "$prerequisite_number" \
            || { blocker_root_fail "prerequisite blocking-edge write failed for #$n -> #$prerequisite_number"; return 1; }
          issue_transition "$n" ready-for-agent conclusion-requeue \
            ".concluded_blocker_recovery.prerequisite_issue = $prerequisite_number" \
            || { blocker_root_fail "prerequisite requeue transition failed for #$n"; return 1; }
        fi
        ;;
      needs-info)
        if [ -n "$recut_reason" ]; then
          question="拆分未能继续：${recut_reason}。请明确可接受的产品范围或权限阶段；流水线会按回复继续。"
        elif [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ]; then
          question="拆分拒绝原因无法从记录中恢复。请说明可接受的产品范围或所需前置能力；流水线会按回复继续。"
        else
          question="这项任务的产品预期还需要补充。请回复预期的用户操作、系统应产生的结果，以及没有更多细节时可接受的默认行为；流水线会收到回复后继续。"
        fi
        thread_id="$(jq -r 'if .needs_info_origin == "concluded-blocker-recovery" then .needs_info_thread_id // empty else empty end' <<< "$state")"
        if [ -z "$thread_id" ] && [ "$delivery_failed_episode" != "$episode" ]; then
          thread_id="$(notify_reporter_question "$n" "[example] #$n 需要确认产品预期" "$question")" || true
        fi
        if [ -n "$thread_id" ]; then
          thread_json="$(jq -cn --arg thread "$thread_id" '$thread')"
          issue_transition "$n" needs-info blocker-recovery-needs-info \
            ".needs_info_origin = \"concluded-blocker-recovery\" | .needs_info_thread_id = $thread_json | del(.concluded_blocker_recovery.question_delivery_failed_episode)" \
            || { blocker_root_fail "needs-info transition failed for #$n"; return 1; }
          guarded_issue_comment "$n" "$BOT_DISCLAIMER
$question" || { blocker_root_fail "needs-info comment failed for #$n"; return 1; }
          action=needs-info
        else
          # A rejected or otherwise undelivered question cannot leave a ticket
          # waiting for a reply nobody received. Send it to the advisor batch.
          if [ "$delivery_failed_episode" != "$episode" ]; then
            state_merge "$n" ".concluded_blocker_recovery.question_delivery_failed_episode = $(jq -cn --arg episode "$episode" '$episode')" \
              || { blocker_root_fail "question-delivery-failed episode write failed for #$n"; return 1; }
          fi
          if jq -e 'any(.labels[]?; .name == "needs-advisor")' <<< "$issue_json" >/dev/null; then
            issue_transition "$n" needs-advisor blocker-recovery-advisor \
              || { blocker_root_fail "advisor transition failed for #$n"; return 1; }
          else
            # This is a new conclusion episode with its own budget; the
            # advisor admission must not see the spent implement attempts and
            # refuse (issue 1943 stopped every root sweep for 15h, 2026-10-03).
            state_merge_attempt_transition "$n" '.attempts = 0' \
              || { blocker_root_fail "advisor admission reset failed for #$n"; return 1; }
            route_to_advisor "$n" concluded true "$issue_json" \
              || { blocker_root_fail "advisor route failed for #$n"; return 1; }
          fi
          action=needs-advisor
        fi
        ;;
    esac
    if [ "$conclusion_class" = ticket ]; then
      case "$action" in
        ready-for-agent)
          conclusion_route=requeue
          conclusion_owner=implement
          [ "$pipeline_system_status" != 0 ] || conclusion_owner=issue-pipeline
          ;;
        needs-recut) conclusion_route=recut; conclusion_owner=recut ;;
        prerequisite) conclusion_route=requeue; conclusion_owner=issue-pipeline ;;
        needs-info) conclusion_route=needs-info; conclusion_owner=reporter ;;
        needs-advisor) conclusion_route=needs-info; conclusion_owner=advisor ;;
      esac
      state_merge "$n" ".run.conclusion.route = $(jq -cn --arg route "$conclusion_route" '$route') | .run.conclusion.owner = $(jq -cn --arg owner "$conclusion_owner" '$owner')" \
        || { blocker_root_fail "conclusion route write failed for #$n"; return 1; }
    fi
    attempts_before_reset="$(jq -r '.attempts // 0 | if type == "number" then . else 0 end' <<< "$state")"
    reset_reason="${recut_reason:-$reason}"
    reset_reason_file="$(jq_arg_file "$reset_reason")" \
      || { blocker_root_fail "attempt-reset reason temp file failed for #$n"; return 1; }
    if ! reset_record="$(jq -cn --argjson from "$attempts_before_reset" --arg reason_class "$reason_class" \
      --arg action "$action" --rawfile reason "$reset_reason_file" --arg episode "$episode" \
      '{from:$from,to:0,reason_class:$reason_class,action:$action,reason:$reason,episode:$episode,at:(now|todate)}')"; then
      rm -f -- "$reset_reason_file"
      blocker_root_fail "attempt-reset record build failed for #$n"
      return 1
    fi
    rm -f -- "$reset_reason_file"
    if [ "$retry_failed_route" = 1 ]; then
      state_merge_attempt_transition "$n" ".attempts = 0 | .concluded_blocker_recovery.attempts_reset = $reset_record | .concluded_blocker_recovery.last_action = $(jq -cn --arg action "$action" '$action')" \
        || { blocker_root_fail "attempt-reset write failed for #$n (retry route)"; return 1; }
    else
      state_merge_attempt_transition "$n" ".attempts = 0 | .concluded_blocker_recovery.attempts_reset = $reset_record | .concluded_blocker_recovery.auto_exits = (if (.concluded_blocker_recovery.last_episode // \"\") == $(jq -cn --arg episode "$episode" '$episode') then (.concluded_blocker_recovery.auto_exits // 0) else ((.concluded_blocker_recovery.auto_exits // 0) + 1) end) | .concluded_blocker_recovery.last_episode = $(jq -cn --arg episode "$episode" '$episode') | .concluded_blocker_recovery.last_action = $(jq -cn --arg action "$action" '$action')" \
        || { blocker_root_fail "attempt-reset write failed for #$n"; return 1; }
    fi
    echo "issue-pipeline: blocker-root issue=#$n class=$reason_class action=$action blockers=$(jq -r 'map(tostring)|join(",")' <<< "$dependents_json")" >&2
    BLOCKING_ROOT_GRAPH_CHANGED=1
    return 0
  fi

  return 0
}


# Return top terminal blockers and number of ready tickets held by each.
issue_blocker_root_summary() {
  local open_issues_json="$1" label="${2:-ready-for-agent}"
  jq -r --arg lane_label "$label" '
    def roots($graph; $issue; $seen):
      if ($seen | index($issue)) != null then [$issue]
      elif $graph[$issue] == null then [$issue]
      else
        [$graph[$issue].blockedBy.nodes[]? | select((.state | ascii_downcase) == "open") | (.number | tostring)] as $parents
        | if ($parents | length) == 0 then [$issue]
          else [$parents[] as $parent | roots($graph; $parent; $seen + [$issue])[]] | unique
          end
      end;
    . as $issues
    | ($issues | map({key:(.number | tostring),value:.}) | from_entries) as $graph
    | [$issues[] as $ticket
       | select(any($ticket.labels[]?; .name == $lane_label))
       | select(any($ticket.blockedBy.nodes[]?; (.state | ascii_downcase) == "open"))
       | roots($graph; ($ticket.number | tostring); [])[] as $root
       | {root:$root,ticket:$ticket.number}]
    | group_by(.root)
    | map({root:.[0].root,title:($graph[.[0].root].title // ""),count:length})
    | sort_by([-.count, (.root | tonumber)])[:5]
    | map("#\(.root)\(if .title == "" then "" else " \(.title | gsub("[\\t\\r\\n]"; " "))" end):\(.count)") | join(",")
  ' <<< "$open_issues_json"
}

sweep_blocking_issue_roots() {
  local pass graph_json issue_json n state_file_path has_open_dependents sweep_failed=0
  local snapshot_only="${1:-}"
  local cursor_file="$AGENT_HOME/blocker-root-sweep.cursor" cursor=0 last_done=""
  local roots_done=0 roots_total=0
  local sweep_deadline=$((SECONDS + BLOCKER_ROOT_SWEEP_BUDGET_SECONDS))
  OPEN_ISSUE_BLOCKER_GRAPH_JSON='[]'
  OPEN_ISSUE_BLOCKER_GRAPH_STATUS=unknown
  cursor="$(cat "$cursor_file" 2>/dev/null || true)"
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
  for pass in 1 2; do
    if ! graph_json="$(gh issue list --repo "$REPO" --state open --limit 1000 \
      --json number,title,state,labels,author,blockedBy,blocking)"; then
      echo "sweep_blocking_issue_roots: open issue dependency graph unreadable" >&2
      return 1
    fi
    if ! jq -e 'type == "array" and all(.[]; type == "object" and (.number | type) == "number")' \
      <<< "$graph_json" >/dev/null; then
      echo "sweep_blocking_issue_roots: open issue dependency graph malformed" >&2
      return 1
    fi
    OPEN_ISSUE_BLOCKER_GRAPH_JSON="$graph_json"
    OPEN_ISSUE_BLOCKER_GRAPH_STATUS=available
    [ "$snapshot_only" != "--snapshot-only" ] || return 0
    roots_total="$(jq '[.[] | select((.state | ascii_downcase) == "open")] | length' <<< "$graph_json")"
    roots_done=0
    BLOCKING_ROOT_GRAPH_CHANGED=0
    while IFS= read -r issue_json; do
      [ -n "$issue_json" ] || continue
      if [ "$SECONDS" -ge "$sweep_deadline" ]; then
        [ -z "$last_done" ] || printf '%s\n' "$last_done" > "$cursor_file"
        echo "sweep_blocking_issue_roots: budget ${BLOCKER_ROOT_SWEEP_BUDGET_SECONDS}s spent; resuming after #${last_done:-$cursor} next tick" >&2
        return "$sweep_failed"
      fi
      n="$(jq -r '.number' <<< "$issue_json")"
      has_open_dependents=0
      jq -e 'any(.blocking.nodes[]?; (.state | ascii_downcase) == "open")' <<< "$issue_json" >/dev/null && has_open_dependents=1
      if [ "$has_open_dependents" = 0 ]; then
        state_file_path="$(state_file "$n")"
        if { [ ! -r "$state_file_path" ] || ! jq -e '
          ((.recut_children | type) == "array" and (.recut_children | length) > 0)
          or .native_subissue_parent == true
        ' "$state_file_path" >/dev/null 2>&1; } \
          && ! jq -e 'any(.labels[]?; .name == "concluded" or .name == "on-hold")' <<< "$issue_json" >/dev/null; then
          last_done="$n"
          roots_done=$((roots_done + 1))
          continue
        fi
      fi
      if ! gh_tick_attempt_timeout_sec >/dev/null; then
        printf '%s\n' "${last_done:-$cursor}" > "$cursor_file"
        echo "blocker-root sweep: tick gh deadline exhausted after ${roots_done}/${roots_total} roots; resuming at #${n} next tick" >&2
        return "$sweep_failed"
      fi
      # One root that fails must not starve every root after it.
      if ! reconcile_blocking_issue_root "$issue_json" "$graph_json"; then
        sweep_failed=1
        supervisor_inbox_append_once "blocker-root-failed issue=#$n" \
          "blocker-root-failed issue=#$n reason=${BLOCKER_ROOT_FAIL_REASON:-reconcile_blocking_issue_root exited non-zero without recording a reason}; the sweep continued with the remaining roots" || true
      fi
      last_done="$n"
      roots_done=$((roots_done + 1))
    done < <(jq -c --argjson cursor "$cursor" '[.[] | select((.state | ascii_downcase) == "open")] | sort_by(.number)
      | (map(select(.number > $cursor)) + map(select(.number <= $cursor)))[]' <<< "$graph_json")
    rm -f "$cursor_file"
    cursor=0
    [ "$BLOCKING_ROOT_GRAPH_CHANGED" = 1 ] || break
  done
  return "$sweep_failed"
}


merged_blocker_labels_json() {
  jq -cn --args '$ARGS.positional' "${MERGED_BLOCKER_LABELS[@]}"
}


has_merged_blocker_label_name() {
  local label_names_json="$1" merged_labels_json
  merged_labels_json="$(merged_blocker_labels_json)" || return 1
  jq -e --argjson merged_labels "$merged_labels_json" \
    'any(.[]; . as $label | $merged_labels | index($label) != null)' \
    <<< "$label_names_json" >/dev/null 2>&1
}


open_blocker_ids_from_rest_json() {
  local blockers_json="$1" merged_labels_json
  merged_labels_json="$(merged_blocker_labels_json)" || return 1
  jq -r --argjson merged_labels "$merged_labels_json" '
    [.[] | select(.state == "open")
     | select((any(.labels[]?.name; . as $label | $merged_labels | index($label) != null)) | not)
     | .number
    ] | join(", ")
  ' <<< "$blockers_json"
}


# The live REST fallback: one `gh api` call per issue when the batch snapshot
# is unavailable or incomplete. Fails CLOSED (returns
# 0/blocked) on ANY failure -- a missing/erroring dependencies endpoint (the
# feature could be unavailable, or a transient gh/network hiccup) must not
# silently wave through an issue whose real blocker state is unknown. This
# used to fail open on the reasoning that getting it wrong in the permissive
# direction "costs at most one burned implement attempt" -- that argument is
# rejected: issue #1163 carries 13 open blockers, and one transient API
# failure landing on top of one hand-applied `ready-for-agent` label was
# enough for this function to wave it straight through, starting an
# implement dispatch to build against contracts that thirteen prerequisite
# tickets have not delivered. That is not "one burned attempt," it is
# building on an undelivered foundation.
#
# Failing closed here is still safe for the caller: it leaves the issue
# ready-for-agent, records this gate and either blocker IDs or read failure in
# the existing tick ledger, then retries next tick. A permanent unreadable
# dependency state therefore becomes visible rather than turning into a
# permissive dispatch.
has_open_blocker() {
  local n="$1" blockers_json
  OPEN_BLOCKER_IDS=""
  OPEN_BLOCKER_QUERY_FAILED=0
  if [ "$OPEN_BLOCKER_SNAPSHOT_ACTIVE" = 1 ]; then
    case "${OPEN_BLOCKER_SNAPSHOT_STATE[$n]:-fallback}" in
      blocked)
        OPEN_BLOCKER_IDS="${OPEN_BLOCKER_SNAPSHOT_IDS[$n]:-}"
        return 0
        ;;
      clear) return 1 ;;
    esac
  fi
  if ! blockers_json="$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null)"; then
    OPEN_BLOCKER_QUERY_FAILED=1
    return 0
  fi
  OPEN_BLOCKER_IDS="$(open_blocker_ids_from_rest_json "$blockers_json" 2>/dev/null || true)"
  [ -n "$OPEN_BLOCKER_IDS" ]
}


prose_blocker_references() {
  sed -e 's#/#\n#g' -e 's#;#\n#g' -e 's#；#\n#g' -e 's#。#\n#g' \
    | grep -iE 'blocked[[:space:]-]+by|depends[[:space:]]+on|dependent[[:space:]]+on|prerequisite|pre-requisite|prereq|blocking|blocks|requires|前置|依赖|阻塞' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -nu || true
}


# has_open_prose_blocker <issue> <title/body/brief text> -- check explicit
# prose prerequisites that are not linked in GitHub's native dependency graph.
has_open_prose_blocker() {
  local n="$1" text="${2:-}" references blocker blocker_state blocker_view label_names_json query_failed=0
  local -a blocked_ids=()
  OPEN_BLOCKER_IDS=""
  OPEN_BLOCKER_QUERY_FAILED=0
  # Split clauses first so a keyword binds only the issue in its own clause: issue 2681's
  # "#2568（建档出口依赖）/ #2493 B1（…本票先收口…）" blocked on #2493 (2026-10-08).
  references="$(prose_blocker_references <<< "$text")"
  for blocker in $references; do
    [ "$blocker" = "$n" ] && continue
    if ! [[ "$blocker" =~ ^[0-9]+$ ]]; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    blocker_view="${PROSE_BLOCKER_VIEW_CACHE[$blocker]:-}"
    if [ "$PROSE_BLOCKER_SNAPSHOT_ACTIVE" != 1 ] || [ -z "$blocker_view" ]; then
      blocker_view="$(gh issue view "$blocker" --repo "$REPO" --json state,labels \
        -q '{state: .state, labels: [.labels[].name]}' 2>/dev/null)" || blocker_view='!unavailable!'
      [ "$PROSE_BLOCKER_SNAPSHOT_ACTIVE" != 1 ] || PROSE_BLOCKER_VIEW_CACHE[$blocker]="$blocker_view"
    fi
    if [ "$blocker_view" = '!unavailable!' ]; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    if ! blocker_state="$(jq -r '.state // empty' <<< "$blocker_view" 2>/dev/null)"; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    case "$blocker_state" in
      OPEN|open)
        if ! label_names_json="$(jq -c '.labels // []' <<< "$blocker_view" 2>/dev/null)"; then
          query_failed=1
          blocked_ids+=("$blocker")
        elif ! has_merged_blocker_label_name "$label_names_json"; then
          blocked_ids+=("$blocker")
        fi
        ;;
      # A prose dependency may name a pull request; gh reports a merged one as MERGED (2026-10-03: issues
      # 1598 and 1607 sat 31 hours behind merged PRs 1567 and 1605, treated as unreadable).
      CLOSED|closed|MERGED|merged) ;;
      *) query_failed=1; blocked_ids+=("$blocker") ;;
    esac
  done
  for blocker in "${blocked_ids[@]}"; do
    OPEN_BLOCKER_IDS="${OPEN_BLOCKER_IDS:+$OPEN_BLOCKER_IDS, }$blocker"
  done
  OPEN_BLOCKER_QUERY_FAILED="$query_failed"
  [ "$query_failed" -eq 1 ] || [ "${#blocked_ids[@]}" -gt 0 ]
}
