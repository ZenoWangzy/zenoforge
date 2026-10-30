issue_verdict_snapshot_guard() {
  local n="$1" snapshot_json="${2:-}" current_json current_state snapshot_state current_labels snapshot_labels
  ISSUE_VERDICT_GUARD_REASON=""
  if ! current_json="$(gh issue view "$n" --repo "$REPO" --json state,labels 2>/dev/null)"; then
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  fi
  current_state="$(jq -r '.state // empty | ascii_downcase' <<< "$current_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  }
  case "$current_state" in
    closed) ISSUE_VERDICT_GUARD_REASON="issue is closed"; return 1 ;;
    open) ;;
    *) ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"; return 2 ;;
  esac
  [ -n "$snapshot_json" ] || return 0

  snapshot_state="$(jq -r '.state // empty | ascii_downcase' <<< "$snapshot_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify snapshot issue state and labels"
    return 2
  }
  if [ "$snapshot_state" != open ]; then
    ISSUE_VERDICT_GUARD_REASON="snapshot issue was not open"
    return 1
  fi
  if [ "$current_state" != "$snapshot_state" ]; then
    ISSUE_VERDICT_GUARD_REASON="issue state changed since snapshot"
    return 1
  fi
  current_labels="$(jq -c '.labels | map(.name) | sort' <<< "$current_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  }
  snapshot_labels="$(jq -c '.labels | map(.name) | sort' <<< "$snapshot_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify snapshot issue state and labels"
    return 2
  }
  if [ "$current_labels" != "$snapshot_labels" ]; then
    ISSUE_VERDICT_GUARD_REASON="issue labels changed since snapshot"
    return 1
  fi
  return 0
}


route_to_advisor() {
  local n="$1" remove_label="${2:-ready-for-agent}" snapshot_json="${4:-}" pipeline_loop_breaker="${5:-}"
  local convergence_attempt current_attempt skip_label_write=0
  local lane_state pipeline_system_status=0
  ISSUE_VERDICT_GUARD_SKIPPED=0
  if ! issue_verdict_snapshot_guard "$n" "$snapshot_json"; then
    ISSUE_VERDICT_GUARD_SKIPPED=1
    echo "route_to_advisor: #$n -- $ISSUE_VERDICT_GUARD_REASON; skipping stale route" >&2
    return 0
  fi
  lane_state="$(state_read "$n")"
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$lane_state" >/dev/null 2>&1; then
    echo "route_to_advisor: #$n -- tracker parent; retiring stale advisor state and labels" >&2
    retire_tracker_parent "$n" || return 1
    return 0
  fi
  pipeline_system_route_status "$n" "$snapshot_json" || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      if [ "$pipeline_loop_breaker" = hand-loop-breaker ]; then
        if ! jq -e --argjson limit "$(jq -er '.hand_loop_breaker.work_no_progress_limit' "$MODEL_POLICY_DEFAULT")" '
          .model_policy.step == "advisor"
          and .model_policy.failure.unit == "implement"
          and (.model_policy.failure.step == "work" or .model_policy.failure.step == "work_retry")
          and .model_policy.failure.transition == "advisor"
          and .model_policy.failure.same_failure_streak >= $limit
          and (.model_policy.advisor_decision // "" | length) == 0
        ' <<< "$lane_state" >/dev/null 2>&1; then
          echo "route_to_advisor: #$n -- loop-breaker advisor request failed its persisted-state guard" >&2
          return 1
        fi
        state_merge "$n" '.hand_loop_breaker.advisor_pending = true' || return 1
      else
        if ! jq -e '.model_policy.failure.stage == "risk-class"
          and .model_policy.failure.early_stop.reason == "same-failure"
          and .model_policy.failure.early_stop.advisor_seen == false' <<< "$lane_state" >/dev/null 2>&1; then
          pipeline_system_return_to_implement "$n" "$remove_label"
          return $?
        fi
        # Pipeline-system issues use this existing hold for ordinary risk refusals.
        hold_issue "$n" --holder supervisor --expires 168h --kind pipeline-system-risk-class \
          --release "repeated P2/L4 risk-class refusal: supervisor sets guarded admission (guarded + required_test_paths) or hand-dispatches" \
          --remove-label "$remove_label" || return 1
        supervisor_inbox_append_once "pipeline-system-risk-class:$n" \
          "pipeline-system issue $n held for supervisor: repeated P2/L4 risk-class refusal needs a guarded-admission decision" || return 1
        return 0
      fi
      ;;
    1) ;;
    *) echo "route_to_advisor: #$n -- cannot classify lane; refusing advisor route" >&2; return 1 ;;
  esac
  # A merged ticket awaiting deployment still belongs to the release leg.
  # Moving only its local state to needs-advisor strands that leg while the
  # awaiting-release label remains (production #1140 after migration 42501).
  if jq -e '.state == "awaiting-release" and .deploy_state == "pending" and .run.outcome == "merged"' \
    <<< "$lane_state" >/dev/null; then
    echo "route_to_advisor: #$n -- merged deploy pending; retaining awaiting-release" >&2
    return 0
  fi
  if advisor_role_disabled; then
    echo "route_to_advisor: #$n -- advisor role disabled; holding for the maintainer" >&2
    hold_for_missing_advisor "$n" "$remove_label"
    return $?
  fi
  if jq -e '.advisor_convergence_pass == true' <<< "$lane_state" >/dev/null 2>&1; then
    convergence_attempt="$(jq -r '.advisor_convergence_pass_attempt // .attempts // 0' <<< "$lane_state")"
    current_attempt="$(jq -r '.attempts // 0' <<< "$lane_state")"
    if ! [[ "$convergence_attempt" =~ ^[0-9]+$ && "$current_attempt" =~ ^[0-9]+$ ]]; then
      echo "route_to_advisor: #$n -- cannot verify whether the one implement pass ran; refusing advisor route" >&2
      return 1
    fi
    if (( current_attempt > convergence_attempt )); then
      echo "route_to_advisor: #$n -- repeated advisor ruling received its one implement pass; routing failed pass to needs-recut" >&2
      route_to_recut "$n"
      return $?
    fi
    echo "route_to_advisor: #$n -- repeated advisor ruling still awaits its one implement pass; keeping the implement route" >&2
    return 0
  fi
  local admission=0
  advisor_retry_admission "$n" || admission=$?
  case "$admission" in
    0) ;;
    10) return 0 ;;
    *) return "$admission" ;;
  esac
  if [ "$remove_label" != needs-advisor ]; then
    loop_break_check "$n" "$remove_label" needs-advisor
    [ "$LOOP_BREAK_ESCALATED" = 1 ] && return 0
  else
    skip_label_write=1
  fi
  # 2026-09-19 addition: also clear .pending_advisor_verdict here, same
  # episode-boundary reasoning as .advisor_ruled_at just above. run-advisor.sh
  # now persists a computed verdict to this field BEFORE attempting its own
  # GitHub side-effects (comment/label/notify), specifically so an
  # interrupted apply can resume on the NEXT tick without paying for a
  # second model call -- see that script's own header comment on the
  # resume check for the live defect this closes. That resume check is
  # scoped to "did the ticket's own content change", which only protects
  # against staleness WITHIN one episode; it has no way to know a NEW
  # episode has begun (a second NOT_READY verdict, a second footprint miss,
  # ...) if the ticket's title/body/comments happen to read identically to
  # the last episode's. route_to_advisor() is the one write path for
  # starting that new episode (see this function's own header comment) --
  # exactly where a leftover verdict from the PRIOR episode must stop being
  # eligible to resume, the same way a leftover advisor_ruled_at must stop
  # blocking dispatch.
  #
  # 2026-09-19 SECOND addition, same day: also increment advisor_episode_seq
  # -- the episode-sequence guard advisor_persist_pending()/advisor_resume_
  # check() (engine/advisor-core.sh) read. The del() just above only
  # protects a resume check that compares TICKET CONTENT; it has no power
  # over a reasoning pass that is still physically in flight (a web-advisor-provider-
  # advisor job dispatched by the PRIOR episode, still polling) when this
  # function starts a new one -- that stale pass could otherwise finish
  # later and get persisted/applied as if it belonged to the episode this
  # call just opened. advisor_episode_seq is a plain incrementing counter,
  # not a hash/fingerprint of anything (the project hash ban) -- it
  # only ever answers "is this the same episode", nothing about content.
  local transition_filter='del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq, .advisor_admission_measure_only) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)'
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$transition_filter"
  else
    issue_transition "$n" needs-advisor advisor-route "$transition_filter" "$skip_label_write"
  fi
}


# Preserve the existing answer transition for both an actual reporter reply
# and a timeout that applies a default. State and label move through the same
# seam as section (a) has always used.
needs_info_resume_answered_issue() {
  local n="$1" issue_json="$2"
  if [ "$(state_read "$n" | jq -r '.needs_info_origin // empty')" = advisor ]; then
    route_to_advisor "$n" needs-info false "$issue_json"
  else
    issue_transition "$n" needs-triage needs-info-answered
  fi
}


# Extract only explicit choices/defaults from the emailed question. The
# standard email footer says replies may accept defaults, but that footer by
# itself does not turn an open question into a decision.
needs_info_default_option() {
  local body="$1" line
  while IFS= read -r line; do
    case "$line" in
      '> 如果都同意上面写的默认处理方式，直接回复这封邮件说一声'*|https://github.com/*) break ;;
      *'建议：'*|*'建议:'*|*'默认：'*|*'默认:'*|*'按默认处理'*|*'按默认执行'*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done <<< "$body"
  return 1
}


needs_info_human_reply_after() {
  local issue_json="$1" sent_at="$2" sent_at_iso comment comment_at comment_body
  sent_at_iso="$(date -u -d "@$sent_at" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  while IFS= read -r comment; do
    comment_at="$(jq -r '.createdAt // empty' <<< "$comment")"
    [[ -n "$comment_at" && ( "$comment_at" > "$sent_at_iso" || "$comment_at" = "$sent_at_iso" ) ]] || continue
    comment_body="$(jq -r '.body // empty' <<< "$comment")"
    comment_is_bot "$comment_body" && continue
    return 0
  done < <(jq -c '.comments[]?' <<< "$issue_json")
  return 1
}


# needs_info_timeout_step <issue-number> <issue-json> <now-epoch>
# The caller has already read the Gmail thread and seeded its first-message
# date/default into state. This function owns one timeout decision and leaves
# the same reply transition available to later ticks if a write fails.
needs_info_timeout_step() {
  local n="$1" issue_json="$2" now="$3" state thread_id sent_at default_option age days marker
  local applied_thread marker_exists at decision_patch comment_body
  NEEDS_INFO_TIMEOUT_ACTION=unchanged
  jq -e '.labels | any(.name == "needs-info")' <<< "$issue_json" >/dev/null 2>&1 || return 0

  state="$(state_read "$n")" || return 1
  thread_id="$(jq -r '.needs_info_thread_id // empty' <<< "$state")"
  [ -n "$thread_id" ] || return 0
  applied_thread="$(jq -r '.needs_info_default_applied.thread_id // empty' <<< "$state")"
  if [ "$applied_thread" = "$thread_id" ]; then
    needs_info_resume_answered_issue "$n" "$issue_json" || return 1
    NEEDS_INFO_TIMEOUT_ACTION=default-applied
    return 0
  fi

  sent_at="$(jq -r '.needs_info_question_sent_at // empty' <<< "$state")"
  [[ "$now" =~ ^[0-9]+$ && "$sent_at" =~ ^[0-9]+$ && "$NEEDS_INFO_QUESTION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || return 0
  age=$((now - sent_at))
  (( age >= NEEDS_INFO_QUESTION_TIMEOUT_SECONDS )) || return 0
  needs_info_human_reply_after "$issue_json" "$sent_at" && return 0

  default_option="$(jq -r '.needs_info_default_option // empty' <<< "$state")"
  if [ -z "$default_option" ]; then
    route_to_advisor "$n" needs-info false "$issue_json" || return 1
    NEEDS_INFO_TIMEOUT_ACTION=advisor-routed
    return 0
  fi

  marker="<!-- vecta-needs-info-default issue=$n thread=$thread_id -->"
  if jq -e --arg marker "$marker" 'any(.comments[]?; ((.body // "") | contains($marker)))' \
    <<< "$issue_json" >/dev/null 2>&1; then
    marker_exists=1
  else
    marker_exists=0
  fi
  if [ "$marker_exists" = 0 ]; then
    days=$((age / 86400))
    comment_body="$BOT_DISCLAIMER
这个问题已等待${days}天仍未收到回复，因此按问题中写明的默认处理继续：
> $default_option
之后如果你回复更正，流水线仍会读取并把回复贴到问题评论。
$marker"
    guarded_write gh issue comment "$n" --repo "$REPO" --body "$comment_body" || return 1
  fi

  at="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  decision_patch="$(jq -cn --arg at "$at" --arg option "$default_option" --arg thread "$thread_id" \
    '{needs_info_default_applied:{at:$at,option:$option,thread_id:$thread}}')" || return 1
  state_merge "$n" ". + $decision_patch" || return 1
  needs_info_resume_answered_issue "$n" "$issue_json" || return 1
  NEEDS_INFO_TIMEOUT_ACTION=default-applied
}


# issue_own_open_agent_pr <n> -- 0 if issue owns an open implement PR, 1 if
# none exists, 2 if GitHub could not answer. Read GitHub, not local state: the
# run that opened a PR can die before pr_number reaches state, so state-only
# checks miss orphaned PRs. Callers must keep the current route on status 2.
issue_own_open_agent_pr() {
  local n="$1" rows
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  rows="$(gh pr list --repo "$REPO" --state open --limit 1 --head "agent/issue-$n" --json number 2>/dev/null)" || return 2
  jq -e 'type == "array"' <<< "$rows" >/dev/null 2>&1 || return 2
  [ -n "$(jq -r '.[0].number // empty' <<< "$rows" 2>/dev/null)" ]
}


# 0: a new episode is allowed; 10: a bounded conclusion was recorded.
# Routing, re-dispatch and process restart never reset the persisted budget.
# An UNREADABLE attempt count is not an admission decision: this gate only
# refuses when the persisted count is a known number at or above the cap.
# When state is malformed, admission steps aside loudly and lets the
# caller's own guards fire -- state_merge will fail there and abort with a
# distinguishing message (lib.test.sh "the abort is loud"), instead of this
# gate short-circuiting the route into a silent return that moved nothing
# and explained nothing (PR #1355 CI, first run).
advisor_retry_admission() {
  local n="$1" attempts state policy_unit policy_step failure_reason
  state="$(state_read "$n")"
  policy_unit="$(jq -r '.model_policy.unit // empty' <<< "$state")"
  policy_step="$(jq -r '.model_policy.step // empty' <<< "$state")"
  # A model failure has already advanced its unit to the advisor step before
  # route_to_advisor() reaches this gate. The persistent ladder owns its
  # bound; legacy attempt counts must not conclude a policy-managed unit.
  if [ -n "$policy_unit" ] && [ "$policy_step" = advisor ]; then return 0; fi
  attempts="$(state_attempts "$n")" || {
    echo "advisor admission: cannot read attempt state for #$n -- standing aside; the caller's state guards will fail loudly if state is broken" >&2
    return 0
  }
  case "$attempts" in
    ''|*[!0-9]*)
      echo "advisor admission: invalid attempt state for #$n -- standing aside; the caller's state guards will fail loudly if state is broken" >&2
      return 0 ;;
  esac
  [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] && return 0
  record_run_decision "$n" wrapper "Advisor retry admission exhausted after $attempts attempts" 1 || return 1
  failure_reason="$(recorded_failure_reason_from_state "$state")"
  [ -n "$failure_reason" ] || failure_reason="No further advisor episode was admitted after $attempts attempts. The preceding failure requires a changed input, capability or environment; routing cannot reset the retry budget."
  conclude_run "$n" not-completed "$failure_reason" || return 1
  return 10
}
