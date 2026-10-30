
# Keep failure text stable across issue-number and whitespace changes while
# preserving meaningful differences in the classified reason.
model_policy_normalize_failure_reason() {
  failure_fingerprint "$1"
}


# Record one model-unit failure or transient retry note.
# `evidence` is bounded before persistence; it can contain untrusted logs.
model_policy_record_failure() {
  local n="$1" step="$2" stage="$3" reason="$4" evidence="$5" status="${6:-1}" remove_label="${7:-ready-for-agent}" unit="${8:-}" refund_attempt="${9:-0}" snapshot_json="${10:-}"
  local next stored_step role identity reason_file evidence_file normalized_reason_file failure_patch retry_patch reason_json evidence_json state provider_outage provider_kind pipeline_system_enabled pipeline_system_status=0 open_pr_status=0 loop_limit loop_breaker_advisor=0
  local prior_failure prior_stage prior_reason prior_evidence prior_transition prior_streak previous_normalized_reason normalized_reason same_failure=0 same_streak=0 advisor_seen=false diff_summary="" failure_worktree="" early_stop_json=null prior_reason_argfile current_reason_argfile normalized_reason_argfile diff_summary_argfile
  unit="${unit:-$(state_read "$n" | jq -r '.model_policy.unit // "implement"')}"
  # SIGTERM from systemd stop/shutdown is an interrupted dispatch, not model failure.
  if [ "$unit" = implement ] && [ "$status" = 143 ]; then refund_attempt=1; fi
  state="$(state_read "$n")"
  advisor_seen="$(jq -r '((.model_policy.advisor_decision // "") | tostring | length) > 0' <<< "$state")"
  pipeline_system_enabled="$(jq -r '.pipeline_system.enabled // false' <<< "$state")"
  provider_outage="$(jq -r '.model_policy.active.provider_outage // false' <<< "$state")"
  provider_kind="$(jq -r '.model_policy.active.provider_outage_kind // "transport"' <<< "$state")"
  if [ "${MODEL_CALL_ENVIRONMENTAL_FAILURE:-0}" = 1 ]; then
    provider_outage=true
    provider_kind="${MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND:-agent-tool-exit-127}"
  fi
  if [ "$(jq -r '.model_policy.active.config_fault // false' <<< "$state")" = true ]; then
    state_merge "$n" '.model_policy.retry_note = {reason:"model configuration fault; waiting for role configuration change",recorded_at:(now|todate)} | del(.model_policy.active)' || return 1
    echo "model_policy: #$n $step configuration fault at $stage; kept rung until role configuration changes" >&2
    return 0
  fi
  loop_limit="$(jq -er '.hand_loop_breaker.work_no_progress_limit | select(type == "number" and . > 0)' "$MODEL_POLICY_DEFAULT")" || return 1
  if [ "$provider_outage" = true ]; then
    case "$provider_kind" in
      codex-binary-missing)
        reason="Codex agent binary unavailable; retry the current rung"
        evidence="${MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL:-Codex invocation could not start}"
        ;;
      agent-tool-exit-127)
        reason="Agent tool exited 127; retry the current rung"
        evidence="${MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL:-agent tool could not start}"
        ;;
      *)
        reason="Codex provider outage ($provider_kind); retry the current rung"
        evidence="Codex transport failure; provider output redacted"
        ;;
    esac
    refund_attempt=1
  fi
  if [ "${#evidence}" -gt 12000 ]; then evidence="${evidence: -12000}"; fi
  [[ "$refund_attempt" == 0 || "$refund_attempt" == 1 ]] || return 64
  if [ "$status" = 124 ] || [ "$provider_outage" = true ] || [ "$refund_attempt" = 1 ]; then
    if [ "$unit" = implement ]; then
      record_implement_failure "$n" "$reason" "$evidence" "$status" "$stage" 1 || return 1
    fi
    reason_file="$(jq_arg_file "$reason")"
    evidence_file="$(jq_arg_file "$evidence")"
    retry_patch="$(jq -nc --arg unit "$unit" --arg step "$step" --arg stage "$stage" \
      --argjson status "$status" --argjson refunded "$refund_attempt" --rawfile reason "$reason_file" --rawfile evidence "$evidence_file" \
      '{unit:$unit,step:$step,stage:$stage,status:$status,attempt_refunded:($refunded == 1),reason:$reason,evidence:$evidence,recorded_at:(now|todate)}')"
    reason_json="$(jq -n --rawfile value "$reason_file" '$value')"
    evidence_json="$(jq -n --rawfile value "$evidence_file" '$value')"
    rm -f -- "$reason_file" "$evidence_file"
    state_merge_attempt_transition "$n" ".model_policy = (.model_policy // {}) | .model_policy.retry_note = $retry_patch | .model_policy.failure |= (if type == \"object\" then .same_failure_streak = 0 else . end) | .last_failure_reason = $reason_json | .last_failure_tail = $evidence_json | .same_failure_streak = 0 | .attempts = (if $refund_attempt == 1 and (.attempts // 0) > 0 then .attempts - 1 else (.attempts // 0) end) | del(.model_policy.active)" \
      || return 1
    if [ "$provider_kind" = codex-binary-missing ] || [ "$provider_kind" = agent-tool-exit-127 ]; then
      echo "model_policy: #$n $step hit $provider_kind at $stage; kept the rung and refunded attempt" >&2
    elif [ "$provider_outage" = true ]; then
      echo "model_policy: #$n $step hit Codex provider outage at $stage; kept the rung and recorded retry note" >&2
    elif [ "$refund_attempt" = 1 ]; then
      echo "model_policy: #$n $step recorded infrastructure retry at $stage: $reason; refunded attempt and kept the rung" >&2
    else
      echo "model_policy: #$n $step recorded transient retry at $stage: $reason; kept the rung" >&2
    fi
    return 0
  fi
  if [ "$unit" = implement ]; then
    record_implement_failure "$n" "$reason" "$evidence" "$status" "$stage" || return 1
  fi
  prior_failure="$(jq -c '.model_policy.failure // {}' <<< "$state")"
  prior_stage="$(jq -r '.stage // ""' <<< "$prior_failure")"
  prior_reason="$(jq -r '.reason // ""' <<< "$prior_failure")"
  prior_transition="$(jq -r '.transition // ""' <<< "$prior_failure")"
  prior_streak="$(jq -r 'if (.same_failure_streak | type) == "number" then .same_failure_streak else 1 end' <<< "$prior_failure")"
  normalized_reason="$(model_policy_normalize_failure_reason "$reason")"
  previous_normalized_reason="$(model_policy_normalize_failure_reason "$(jq -r '.normalized_reason // .reason // ""' <<< "$prior_failure")")"
  if [ "$unit" = implement ] && [ "$(jq -r '.unit // ""' <<< "$prior_failure")" = implement ] \
    && [ "$prior_streak" -gt 0 ] && [ -n "$prior_reason" ] \
    && [ "$prior_stage" = "$stage" ] && [ "$previous_normalized_reason" = "$normalized_reason" ]; then
    same_streak=$((prior_streak + 1))
    if ((same_streak >= loop_limit)); then same_failure=1; fi
  else
    same_streak=1
  fi
  if [ "$same_failure" = 1 ]; then
    if [ "$pipeline_system_enabled" = true ] && [ "$advisor_seen" = false ]; then
      next=advisor
    elif [ "$pipeline_system_enabled" = true ] || { [ "$prior_transition" = advisor ] && [ "$advisor_seen" = true ]; }; then
      next=conclude
    else
      next=advisor
    fi
    prior_evidence="$(jq -r '.evidence // ""' <<< "$prior_failure")"
    if [ "${#prior_evidence}" -gt 2500 ]; then prior_evidence="${prior_evidence: -2500}"; fi
    if [ "${#evidence}" -gt 2500 ]; then evidence="${evidence: -2500}"; fi
    failure_worktree="${WT:-${ZF_WORKTREE_ROOT:-${HOME:-}/wt}/issue-$n}"
    if [ -d "$failure_worktree" ]; then
      diff_summary="$(git -C "$failure_worktree" diff --stat origin/main...HEAD 2>/dev/null || true)"
      if [ -z "$diff_summary" ]; then
        diff_summary="$(git -C "$failure_worktree" show --stat --format= -1 2>/dev/null || true)"
      fi
    fi
    diff_summary="${diff_summary:-No Git diff summary available.}"
    evidence="$(printf 'Repeated classified failure at %s.\n\nPrevious failure: %s\n%s\n\nCurrent failure: %s\n%s\n\nDiff summary:\n%s' \
      "$stage" "$prior_reason" "$prior_evidence" "$reason" "$evidence" "$diff_summary")"
    prior_reason_argfile="$(jq_arg_file "$prior_reason")" || return 1
    current_reason_argfile="$(jq_arg_file "$reason")" || { rm -f -- "$prior_reason_argfile"; return 1; }
    normalized_reason_argfile="$(jq_arg_file "$normalized_reason")" || { rm -f -- "$prior_reason_argfile" "$current_reason_argfile"; return 1; }
    diff_summary_argfile="$(jq_arg_file "$diff_summary")" || { rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile"; return 1; }
    if ! early_stop_json="$(jq -nc --arg stage "$stage" --arg prior_stage "$prior_stage" \
      --arg decision "$next" --argjson streak "$same_streak" --argjson advisor_seen "$advisor_seen" \
      --rawfile normalized_reason "$normalized_reason_argfile" --rawfile prior_reason "$prior_reason_argfile" \
      --rawfile reason "$current_reason_argfile" --rawfile diff_summary "$diff_summary_argfile" \
      '{reason:"same-failure",stage:$stage,normalized_reason:$normalized_reason,streak:$streak,decision:$decision,advisor_seen:$advisor_seen,previous_failure:{stage:$prior_stage,reason:$prior_reason},current_failure:{stage:$stage,reason:$reason},diff_summary:$diff_summary,recorded_at:(now|todate)}')"; then
      rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile" "$diff_summary_argfile"
      return 1
    fi
    rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile" "$diff_summary_argfile"
    if [ "${#evidence}" -gt 12000 ]; then evidence="${evidence: -12000}"; fi
  else
    case "$unit:$step:$stage" in
      triage:work:*|recut:work:*|implement:work:blast-radius|implement:work:risk-class|implement:work:merge-risk-class|implement:work:merge-gate)
        next=advisor
        ;;
      implement:work:*) next=work ;;
      *) next="$(model_policy transition "$step" on_failure)" || return 1 ;;
    esac
  fi
  # Advisor role disabled (the generic default): skip that step. One work retry, then conclude.
  if [ "$next" = advisor ] && advisor_role_disabled; then
    if [ "$step" = work_retry ] || [ "$same_failure" = 1 ]; then next=conclude; else next=work_retry; fi
  fi
  if [ "$next" = advisor ] || [ "$step" = work_retry ] || [ "$pipeline_system_enabled" = true ]; then
    pipeline_system_route_status "$n" || pipeline_system_status=$?
    case "$pipeline_system_status" in
      0) pipeline_system_enabled=true ;;
      1) pipeline_system_enabled=false ;;
      *) echo "model_policy: #$n -- cannot classify lane; refusing advisor transition" >&2; return 1 ;;
    esac
  fi
  if [ "$pipeline_system_enabled" = true ] && [ "$next" = advisor ]; then
    if [ "$unit" = implement ]; then
      if [ "$step" = work_retry ]; then
        next=conclude
      elif [ "$same_failure" = 1 ] && [ "$step" = work ] \
        && [ "$advisor_seen" = false ]; then
        # V437 keeps ordinary routes fenced; this marker admits only the bounded repeated-failure episode.
        loop_breaker_advisor=1
      elif [ "$same_failure" = 1 ]; then next=conclude
      else next=work_retry
      fi
    else
      pipeline_system_return_to_implement "$n" "$remove_label"
      return $?
    fi
  fi
  if [ "$unit" = implement ] && [ "$step" = work ] && [ "$next" = work ] \
    && [ "$pipeline_system_enabled" != true ]; then
    issue_own_open_agent_pr "$n" || open_pr_status=$?
    case "$open_pr_status" in
      0) next=pr-lane ;;
      2) next=wait ;;
    esac
  fi
  # 2026-10-07, issues #2694/#2721 (#2097 the day before): a work failure on
  # a product ticket that already carries its own open agent PR must not open
  # a new advisor episode. The advisor is the admission oracle; a ticket with
  # its own PR was already admitted into the implement lane, so the episode's
  # outcome is decided in advance -- re-admission, or misclassified -> recut
  # -> recut-refused, either way back to ready-for-agent -- and the next
  # repair failure starts the same episode again. Two locally-correct writers
  # (this ladder's route_to_advisor() and run-advisor-batch.sh's
  # apply_one_ruling()) then flip one ticket until loop_break_check() freezes
  # it with a green PR mid-lane. Keep the failure in the PR lane instead:
  # blocking-pr-recovery owns repair dispatches (bounded by the attempts
  # cap), the merge sweeper owns the green finish. A repeated identical
  # failure still concludes through the same-failure early stop, so this
  # Admission gates are separate from work failures: blast-radius, risk-class,
  # merge-risk-class, and merge-gate decide whether the change may enter or
  # merge; only the advisor can answer them, even when the issue already owns
  # an open PR.
  if [ "$next" = advisor ] && [ "$pipeline_system_enabled" != true ]; then
    case "$stage" in
      blast-radius|risk-class|merge-risk-class|merge-gate) ;;
      *)
        issue_own_open_agent_pr "$n" || open_pr_status=$?
        case "$open_pr_status" in
          0)
            if [ "$same_failure" = 1 ]; then next=conclude; else next=pr-lane; fi
            ;;
          2) next=wait ;;
        esac
        ;;
    esac
  fi
  if [ "$same_failure" = 1 ]; then
    early_stop_json="$(jq -c --arg decision "$next" '.decision = $decision' <<< "$early_stop_json")"
  fi
  stored_step="$next"
  # pr-lane keeps the ladder on its current step, like wait: the ticket never
  # left the work queue, so the next dispatch must not find step=advisor and
  # route instead of running (dispatch_policy_unit's advisor branch).
  case "$next" in wait|pr-lane) stored_step="$step" ;; esac
  role="$(model_policy step-role "$step")" || return 1
  identity="$(model_policy identity "$role")" || return 1
  reason_file="$(jq_arg_file "$reason")"
  evidence_file="$(jq_arg_file "$evidence")"
  normalized_reason_file="$(jq_arg_file "$normalized_reason")"
  failure_patch="$(jq -n --arg unit "$unit" --arg step "$stored_step" --arg transition "$next" --arg failed_step "$step" \
    --arg role "$role" --arg identity "$identity" --arg stage "$stage" \
    --argjson status "$status" --argjson same_streak "$same_streak" --argjson early_stop "$early_stop_json" \
    --rawfile normalized_reason "$normalized_reason_file" --rawfile reason "$reason_file" --rawfile evidence "$evidence_file" \
    '{unit: $unit, step: $step, resume_stage: $unit, failure: ({unit: $unit, step: $failed_step, transition: $transition, role: $role, identity: $identity, stage: $stage, status: $status, reason: $reason, normalized_reason: $normalized_reason, same_failure_streak: $same_streak, evidence: $evidence, recorded_at: (now | todate)} + (if $early_stop == null then {} else {early_stop: $early_stop} end))}')"
  rm -f -- "$reason_file" "$evidence_file" "$normalized_reason_file"
  state_merge "$n" ".model_policy = (.model_policy // {}) + $failure_patch | .model_policy.failures = ((.model_policy.failures // []) + [.model_policy.failure]) | del(.model_policy.active)" || return 1
  if [ "$same_failure" = 1 ]; then
    printf 'implement-early-stop issue=#%s reason=same-failure streak=%s decision=%s stage=%s\n' "$n" "$same_streak" "$next" "$stage" >&2
  fi
  case "$next" in
    work)
      echo "model_policy: #$n $step failed at $stage; requeueing on work role" >&2
      ;;
    work_retry)
      echo "model_policy: #$n $step failed at $stage; retrying once on work role" >&2
      ;;
    advisor)
      if [ "$loop_breaker_advisor" = 1 ]; then
        route_to_advisor "$n" "$remove_label" true "$snapshot_json" hand-loop-breaker || return 1
      else
        route_to_advisor "$n" "$remove_label" true "$snapshot_json" || return 1
      fi
      if [ "$ISSUE_VERDICT_GUARD_SKIPPED" = "1" ]; then
        echo "model_policy: #$n $step failed at $stage; closed or changed issue skipped advisor route" >&2
      else
        echo "model_policy: #$n $step failed at $stage; routed run evidence to web-advisor-provider advisor batch" >&2
      fi
      ;;
    conclude)
      if [ "$unit" = implement ] && [ "$step" = work_retry ] && [ "$advisor_seen" = true ]; then
        local episode hold_status=0
        episode="$(state_read "$n" | jq -r '.model_policy.failure.recorded_at // "unknown"')"
        hold_issue "$n" --holder hand-loop-breaker --expires 168h --kind hand-loop-breaker \
          --release "supervisor reviews the recorded failure and explicitly requeues" || hold_status=$?
        if [ "$hold_status" = 0 ]; then
          supervisor_inbox_append_once "hand-loop-breaker issue=#$n episode=$episode" \
            "hand-loop-breaker issue=#$n action=parked role=work stage=$stage reason=$reason evidence=$evidence" || return 1
        else
          supervisor_inbox_append_once "hand-loop-breaker issue=#$n episode=$episode" \
            "hand-loop-breaker issue=#$n action=park-failed-conclude role=work stage=$stage reason=$reason evidence=$evidence" || true
          record_run_decision "$n" model-policy \
            "Hand loop breaker could not apply hold after the advisor retry; concluding to prevent another automatic work dispatch" 1 || true
          conclude_run "$n" not-completed \
            "Hand loop breaker could not apply hold after the advisor retry. Failure evidence is stored in model_policy.failure." || return 1
          return 0
        fi
        record_run_decision "$n" model-policy \
          "Advisor-guided work retry repeated the same failure; parked for supervisor review" 1 || true
        echo "model_policy: #$n repeated the same failure after advisor-guided retry; parked for supervisor review" >&2
        return 0
      fi
      if [ "$same_failure" = 1 ]; then
        record_run_decision "$n" model-policy "Stopped early after the same classified failure repeated at $stage: $reason" 1
      else
        record_run_decision "$n" model-policy "Configured model escalation exhausted after $stage: $reason" 1
      fi
      if [ "$pipeline_system_enabled" = true ] && [ "$unit" = implement ]; then
        local episode
        episode="$(state_read "$n" | jq -r '.model_policy.failure.recorded_at // "unknown"')"
        supervisor_inbox_append_once \
          "pipeline-system-model-policy issue=#$n episode=$episode" \
          "pipeline-system-model-policy issue=#$n episode=$episode action=concluded stage=$stage reason=$reason" || return 1
      fi
      if [ "$same_failure" = 1 ]; then
        conclude_run "$n" not-completed "Stopped early after the same classified failure repeated at $stage (streak $same_streak): $reason. Both failures and the diff summary are stored in model_policy.failure.early_stop." || return 1
      else
        conclude_run "$n" not-completed "Configured model escalation exhausted after $stage. Failure evidence is stored in model_policy.failure." || return 1
      fi
      ;;
    wait)
      echo "model_policy: #$n routing evidence unavailable; state remains at $step for next tick" >&2
      ;;
    pr-lane)
      echo "model_policy: #$n $step failed at $stage with the issue's own PR still open; staying in the PR repair/final-check lane -- no new advisor episode, no label move" >&2
      ;;
    *)
      echo "model_policy: unrecognized failure transition; issue #$n remains held" >&2
      return 1
      ;;
  esac
}


model_policy_begin_unit() {
  local n="$1" unit="$2" queue_label="${3:-}" current initial unit_json patch filter step attempts
  case "$unit" in triage|recut|implement) ;; *) echo "model_policy: unsupported issue unit '$unit'" >&2; return 64 ;; esac
  current="$(state_read "$n" | jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)')"
  if [ "$current" = "$unit" ]; then
    step="$(state_read "$n" | jq -r '.model_policy.step // empty')"
    if [ "$step" = conclude ]; then
      attempts="$(state_attempts "$n")"
      if [ "$queue_label" = ready-for-agent ] || [ "$attempts" = 0 ]; then
        # The ticket is back in an admission queue, so this conclude belongs
        # to its prior episode. Archive it, clear its failure, then let the
        # existing unit initializer start at the configured initial step.
        state_merge "$n" '.model_policy.history = ((.model_policy.history // []) + [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,completed_at:(now|todate),requeued:true}]) | .model_policy |= del(.unit,.step,.active,.failure,.advisor_decision,.resume_stage,.failures)' || return 1
        current=""
      fi
    fi
  fi
  [ "$current" != "$unit" ] || return 0
  initial="$(model_policy initial-step)" || return 1
  unit_json="$(jq -nc --arg unit "$unit" '$unit')"
  patch="$(jq -nc --arg unit "$unit" --arg step "$initial" '{unit:$unit,step:$step}')"
  filter=".model_policy = (.model_policy // {}) | if (.model_policy.unit // \"\") != $unit_json then .model_policy.history = ((.model_policy.history // []) + (if (.model_policy.unit // \"\") == \"\" then [] else [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,completed_at:(now|todate)}] end)) | .model_policy |= del(.active,.failure,.advisor_decision,.resume_stage) | .model_policy += $patch else . end"
  filter="${filter//\$unit_json/$unit_json}"
  filter="${filter//\$patch/$patch}"
  state_merge "$n" "$filter"
}


model_policy_mark_started() {
  local n="$1" unit="$2" implement_marker="" implement_sha="" implement_sha_json=null
  if [ "$unit" = implement ]; then
    if [ "$#" -ge 3 ]; then
      implement_sha="$3"
    else
      implement_sha="$(git -C "${REPO_DIR:-.}" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [[ "$implement_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
      implement_sha_json="$(jq -nc --arg sha "$implement_sha" '$sha')"
    fi
    implement_marker=" | if .run.implement_started_attempt == (.attempts // 0) then
      .run.implement_started_at = (.run.implement_started_at // (now | todate))
      | if $implement_sha_json != null then .run.implement_started_sha = (.run.implement_started_sha // $implement_sha_json) else . end
      else .run.implement_started_at = (now | todate)
      | if $implement_sha_json != null then .run.implement_started_sha = $implement_sha_json else del(.run.implement_started_sha) end
      | .run.evidence |= del(.implementation_ended_at,.implementation_head_sha,.implementation_attempt,
        .review_ready_at,.reviewed_head_sha,.review_attempt,.ci_started_at,.ci_completed_at,.ci_green_at,
        .ci_head_sha,.ci_jobs,.ci_attempt)
      end | .run.implement_started_attempt = (.attempts // 0)"
  fi
  state_merge "$n" "if .model_policy.unit == \"$unit\" and .model_policy.active.unit == \"$unit\" then .model_policy.active.model_started = true | .model_policy.active.model_started_at = (now | todate)$implement_marker else . end" || return $?
  [ "$unit" != implement ] || efficiency_metrics_sync_issue_lifecycle "$n"
}


model_policy_complete_unit() {
  local n="$1" unit="$2"
  state_merge "$n" "if .model_policy.unit == \"$unit\" then .model_policy.history = ((.model_policy.history // []) + [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,retry_note:.model_policy.retry_note,completed_at:(now|todate)}]) | .model_policy |= del(.unit,.step,.active,.failure,.advisor_decision,.resume_stage,.retry_note) else . end"
}
