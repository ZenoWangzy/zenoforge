_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# conclusion_classification_for_state <issue> <state-json> <needs-md>
# Returns the stable class, route, and owner written before a terminal ticket
# becomes visible to the next issue-pipeline sweep.
conclusion_classification_for_state() {
  local n="$1" state="$2" needs_md="${3:-}" target_outcome="${4:-}" started since env_row env_epoch env_event='null' env_signature="" env_reason="" env_scope="" env_at="" ledger row
  local ticket_route=requeue ticket_owner=implement classification_status risk_class level needs_file classified_json
  started="$(jq -r '.run.implement_started_at // empty' <<< "$state")"
  if [ -n "$started" ]; then
    since="$(agent_epoch "$started" 2>/dev/null || echo 0)"
    for ledger in "$ENV_FAULT_DIR"/*.log; do
      [ -f "$ledger" ] || continue
      row="$(awk -F '\t' -v issue="$n" -v since="$since" \
        '$1 >= since && $3 == issue && $2 ~ /^implement(@|$)/ { latest=$0 } END { print latest }' "$ledger")"
      [ -n "$row" ] || continue
      env_epoch="${row%%$'\t'*}"
      [[ "$env_epoch" =~ ^[0-9]+$ ]] || continue
      if [ -z "$env_at" ] || [ "$env_epoch" -gt "$env_at" ]; then
        env_at="$env_epoch"
        env_scope="$(cut -f2 <<< "$row")"
        env_signature="$(cut -f4 <<< "$row")"
        env_reason="$(cut -f5 <<< "$row")"
      fi
    done
    if [ -n "$env_at" ]; then
      env_event="$(jq -cn --arg signature "$env_signature" --arg reason "$env_reason" --arg scope "$env_scope" \
        --arg recorded_at "$(date -u -d "@$env_at" +%Y-%m-%dT%H:%M:%SZ)" \
        '{type:"env-fault",signature:$signature,reason:$reason,scope:$scope,recorded_at:$recorded_at}')"
    fi
  fi

  classification_status="$(triage_classification_status "$STATE_DIR/$n.json")"
  if [ "$classification_status" = measured ]; then
    risk_class="$(jq -r '.risk_class // empty' <<< "$state")"
    level="$(jq -r '.level // empty' <<< "$state")"
    if recut_categorically_oversized "$risk_class" "$level"; then
      ticket_route=recut
      ticket_owner=recut
    fi
  fi

  needs_file="$(jq_arg_file "$needs_md")" || return 1
  # State goes on stdin: issue state files pass 128 KiB, the per-argument limit, and --argjson then
  # failed with "Argument list too long" (2026-10-10: issues 1820/1952/1970/2144 could not conclude).
  if ! classified_json="$(jq -c --argjson env "$env_event" --rawfile needs "$needs_file" --arg outcome "$target_outcome" \
    --arg ticket_route "$ticket_route" --arg ticket_owner "$ticket_owner" '
    (. as $s
     | ($s.run.implement_started_at // $s.requeued_at // "") as $boundary
     | ([ $s.model_policy.retry_note?, $s.model_policy.failure?, ($s.model_policy.failures[]?) ]
        | map(select(type == "object" and (.recorded_at // "") != "" and ($boundary == "" or .recorded_at >= $boundary)))) as $policy_events
     | ($policy_events | sort_by(.recorded_at) | last // {}) as $policy
     | ($s.unit_results.implement // {}) as $unit
     | (if (($unit.result // "") | IN("oom-kill","timeout","watchdog","start-limit-hit"))
        then {type:"unit-result",reason:("systemd Result=" + $unit.result),recorded_at:($unit.recorded_at // "")}
        else {} end) as $unit_fault
     | ([$policy, $unit_fault, $env] | map(select(type == "object" and (.recorded_at // "") != "")) | sort_by(.recorded_at) | last // {}) as $latest
     | ($latest.reason // $needs // $s.last_failure_reason // "") as $reason
     | ($reason | ascii_downcase) as $reason_text
     | (if $latest.type == "env-fault" then $latest.signature
        elif $latest.type == "unit-result" then ($latest.reason | gsub("[^A-Za-z0-9=.-]"; "-"))
        elif $latest.signature == "pipeline-system-delivery-failed" then $latest.signature
        elif $latest.stage == "role-identity" or (($latest.status // 0) == 64 and ($reason_text | test("identity|role"))) then "model-role-identity-rejected"
        elif ($reason_text | test("(high|critical).*(blast radius|impact).*(stop|halt)|(blast radius|impact).*(high|critical).*(stop|halt)")) then "implement-impact-level-stop"
        elif ($reason_text | test("previous (model|implement|policy) unit .*without recording a result|no persisted systemd result")) then "unit-result-not-recorded"
        else "" end) as $signature
     | (if $s.run.disposition == "not-planned" or $s.run.close_as_not_planned == true or $s.run.outcome == "not-planned"
        then {class:"ticket",route:"close-not-planned",owner:"closed",signature:"not-planned",reason:$reason}
        elif $signature == "pipeline-system-delivery-failed"
        then {class:"pipeline-defect",route:"requeue",owner:"supervisor-inbox",signature:$signature,reason:$reason}
        elif $s.pipeline_system.enabled == true
        then {class:"ticket",route:"requeue",owner:"issue-pipeline",signature:"pipeline-system-requeue",reason:$reason}
        elif (($s.run.outcome // $outcome // "") == "" or ($s.run.outcome // $outcome // "") == "unknown")
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"missing-conclusion-outcome",reason:"No terminal outcome was recorded; please confirm the intended result."}
        elif $signature == "model-role-identity-rejected" or $signature == "implement-impact-level-stop" or $signature == "unit-result-not-recorded"
        then {class:"pipeline-defect",route:"requeue",owner:"supervisor-inbox",signature:$signature,reason:$reason}
        elif ($latest.attempt_refunded == true)
          or ($latest.type == "env-fault")
          or ($latest.type == "unit-result")
          or ($reason_text | test("ci runner capacity|ci deadline|merge-lock contention|provider quota|provider outage|network fault|docker hub dns/connect timeout|checkout step failed before project checks|systemd result=(oom-kill|timeout|watchdog|start-limit-hit)"))
        then {class:"infrastructure",route:"requeue",owner:"issue-pipeline",signature:(if ($signature | length) > 0 then $signature else "infrastructure-precondition" end),reason:$reason,scope:($latest.scope // null)}
        elif $s.review_verdict == "INPUT_INCOMPLETE"
          or ($reason_text | test("product decision|input[_ -]+incomplete|missing .*decision|permission stage|risk_class=|level="))
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"product-input-incomplete",reason:$reason}
        elif $s.concluded_blocker_recovery.last_action == "needs-advisor"
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"advisor-route-retry",reason:$reason}
        elif ($s.recut_refused_at // "") != ""
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"recut-refused",reason:$reason}
        else {class:"ticket",route:$ticket_route,owner:$ticket_owner,signature:"ticket-code-or-scope-failure",reason:$reason}
        end)
    )' <<< "$state")"; then
    rm -f -- "$needs_file"
    return 1
  fi
  rm -f -- "$needs_file"
  printf '%s\n' "$classified_json"
}


# conclusion_check_report failed -- plain-language mail fields for a failed mandatory check.
conclusion_check_report() {
  case "$1" in
    failed)
      jq -nc '{what:"本轮必要测试已运行，但没有通过。",impact:"问题还在，用户暂时看不到变化。",action:"测试通过前不能确认改动完成。"}'
      ;;
    *) return 1 ;;
  esac
}


mark_awaiting_release() {
  local n="$1" pr_number="$2" expected_hold="${3:-}" pr_json transition_filter
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "mark_awaiting_release: invalid issue number '$n'" >&2; return 64; }
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || { echo "mark_awaiting_release: invalid PR number '$pr_number' for #$n" >&2; return 64; }
  pr_json="$(jq -cn --arg pr "$pr_number" '$pr')" || return 1
  transition_filter="if .run.outcome == \"merged\" and (.run.evidence.pr_number | tostring) == $pr_json then
    .run.merged_at = (.run.merged_at // .run.evidence.merged_pr.merged_at // (now | todate)) | .deploy_state = (.deploy_state // \"pending\")
    else .run.outcome = \"merged\" | .run.evidence.pr_number = $pr_json
    | if (.run.evidence.merged_pr.number | tostring) != $pr_json then del(.run.evidence.merged_pr) else . end
    | .run.merged_at = (.run.evidence.merged_pr.merged_at // (now | todate)) | .deploy_state = \"pending\" | del(.deployed_sha, .run.evidence.real_user_path, .closed_by_pipeline, .released) end
    | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq) | .hold = null"
  issue_transition "$n" awaiting-release merged-pr "$transition_filter" 0 "" "" 0 "$expected_hold"
}


# conclude_run <n> <outcome> <needs_md> [quota_provider] -- records every
# terminal run result and performs the production-proven close. Refuses
# (prints why, returns 1, writes nothing) unless the record already carries
# the artifact $outcome requires:
#   merged        .run.evidence.pr_number recorded; moves open issue to
#                 awaiting-release / deploy_state=pending, never closes
#   deployed      merged outcome, deploy_state=deployed, deployed SHA, and
#                 real-user-path URL + visible DOM + same-run network proof
#   pr-open       .run.evidence.pr_number, .review_verdict, .ci_outcome all
#                 recorded -- a draft PR exists that a human could merge
#   not-completed state_attempts(n) at CONCLUDE_RUN_ATTEMPT_CAP, a real
#                 implement start since the last requeue/conclusion, and
#                 $needs_md names the missing capability -- not a bare attempt
#                 count. `duplicate` keeps its existing independent terminal
#                 behavior.
agent_owned_issue_ids() {
  local owner="$1" explicit="${2:-}" roster="$AGENT_HOME/night/agents.txt" row
  local pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes lib_dir
  if ! declare -F hand_agent_issue_ids >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)" || return 1
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 1
  fi
  if [[ -e "$roster" && ! -r "$roster" ]]; then return 1; fi
  if [[ -r "$roster" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" && -n "$owned_issues" ]] || continue
      explicit="${explicit:+$explicit }$owned_issues"
    done < "$roster"
  fi
  hand_agent_issue_ids "$owner" "$explicit"
}


# Shared closure evidence for the close path and every outcome auditor.
# Pipeline-system comments must cite their issue-linked main commit; ordinary
# Product closes need release or maintainer evidence; source-only closes require
# a main-reachable docs/test commit. Decision closures remain exceptions.
issue_closure_evidence_valid() {
  local repo_dir="$1" issue="$2" labels="$3" comments_json="$4"
  local founder_login="$5" close_epoch="$6" now_epoch="$7" candidate_comment="${8:-}"
  local state_reason="${9:-}" reference_sha="${10:-}" start end comment_b64 comment allow_legacy_queue=false
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$close_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 2
  if ((close_epoch > 0)); then allow_legacy_queue=true; fi
  if [ -z "$candidate_comment" ] && ! jq -e '
    type == "array" and all(flatten[]?;
      type == "object" and
      ((.body == null) or (.body | type == "string")) and
      ((.created_at == null) or (.created_at | type == "string")) and
      ((.user == null) or ((.user | type) == "object" and ((.user.login == null) or (.user.login | type == "string"))))
    )
  ' <<< "$comments_json" >/dev/null 2>&1; then
    return 2
  fi

  # A not-planned, wontfix or duplicate close delivers nothing, so it needs no delivery commit; pipeline-system
  # issues closed as obsolete (2026-10-03, issue 1352) otherwise stayed "unclassified" forever.
  [[ ",$labels," == *,wontfix,* || ",$labels," == *,duplicate,* || "$state_reason" == NOT_PLANNED ]] && return 0

  if [[ ",$labels," == *,pipeline-system,* ]]; then
    if [ -n "$candidate_comment" ]; then
      pipeline_system_close_comment_valid "$repo_dir" "$issue" "$candidate_comment" "$allow_legacy_queue" "$reference_sha"
      return $?
    fi
    start="$(date -u -d "@$((close_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
    end="$(date -u -d "@$((now_epoch + 600))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
    while IFS= read -r comment_b64; do
      [ -n "$comment_b64" ] || continue
      comment="$(base64 --decode <<< "$comment_b64")" || return 2
      if pipeline_system_close_comment_valid "$repo_dir" "$issue" "$comment" "$allow_legacy_queue" "$reference_sha"; then
        return 0
      fi
    done < <(jq -r --arg start "$start" --arg time_end "$end" '
      flatten[]?
      | select((.created_at // "") >= $start and (.created_at // "") <= $time_end)
      | .body | @base64
    ' <<< "$comments_json") || return 2
    return 1
  fi

  [[ ",$labels," == *,released,* ]] && return 0
  if issue_source_close_comment_valid "$repo_dir" "$issue" "$comments_json" \
    "$founder_login" "$close_epoch" "$reference_sha"; then
    return 0
  else
    local source_status=$?
    [ "$source_status" -ne 2 ] || return 2
  fi

  [ -n "$founder_login" ] || return 1
  start="$(date -u -d "@$((close_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
  end="$(date -u -d "@$((now_epoch + 600))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
  jq -e --arg owner "$founder_login" --arg start "$start" --arg time_end "$end" '
    any(flatten[]?;
      ((.user.login // "" | ascii_downcase) == ($owner | ascii_downcase)) and
      ((.body // "") | test("^维护者(补充)?裁决")) and
      ((.created_at // "") >= $start and (.created_at // "") <= $time_end)
    )
  ' <<< "$comments_json" >/dev/null 2>&1
}


issue_source_close_comment_valid() {
  local repo_dir="$1" issue="$2" comments_json="$3" founder_login="$4" close_epoch="$5" reference_sha="${6:-}"
  local sha commit commit_epoch path paths main_sha valid_paths
  local -a source_shas=()
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$close_epoch" =~ ^[0-9]+$ && -n "$founder_login" ]] || return 1
  mapfile -t source_shas < <(jq -r --arg owner "${founder_login,,}" --arg issue "$issue" '
    flatten[]?
    | select((.user.login // "" | ascii_downcase) == $owner)
    | (.body // "")
    | try capture("<!-- vecta-source-close-evidence issue=" + $issue + " sha=(?<sha>[[:xdigit:]]{40}) -->").sha catch empty
  ' <<< "$comments_json")
  ((${#source_shas[@]} > 0)) || return 1
  # A retrospective marker is safe only when its source was on main before closure.
  main_sha="$(git -C "$repo_dir" rev-parse --verify "${reference_sha:-origin/main}^{commit}" 2>/dev/null)" || return 2
  for sha in "${source_shas[@]}"; do
    commit="$(git -C "$repo_dir" rev-parse --verify "$sha^{commit}" 2>/dev/null)" || continue
    git -C "$repo_dir" merge-base --is-ancestor "$commit" "$main_sha" 2>/dev/null || continue
    commit_epoch="$(git -C "$repo_dir" show -s --format=%ct "$commit" 2>/dev/null)" || return 2
    [[ "$commit_epoch" =~ ^[0-9]+$ ]] || return 2
    ((commit_epoch <= close_epoch)) || continue
    paths="$(git -C "$repo_dir" diff-tree --no-commit-id --name-only -r -m "$commit" 2>/dev/null)" || return 2
    [ -n "$paths" ] || continue
    valid_paths=1
    while IFS= read -r path; do
      case "$path" in
        docs/*|tests/*|*/tests/*|test-support/*|*/test-support/*|*/src/test-helpers/*|*.test.*|*.spec.*|vitest.config.*|jest.config.*|*/vitest.config.*|*/jest.config.*) ;;
        *) valid_paths=0; break ;;
      esac
    done <<< "$paths"
    [ "$valid_paths" = 1 ] && return 0
  done
  return 1
}


conclude_run() {
  local n="$1" outcome="$2" needs_md="${3:-}" quota_provider="${4:-}" expected_hold="${5:-}" state pr_number pr_head_sha review_verdict ci_outcome attempts acceptor duplicate_of deploy_state deployed_sha real_user_path policy_exhausted implement_episode implement_after_requeue implementation_run pipeline_sha pipeline_close_comment health_target health_detail health_target_json health_detail_json issue_state mandatory_check_status="" check_report_json conclusion_json='null'
  if [ -n "$quota_provider" ] && provider_quota_exhausted "$quota_provider"; then
    echo "conclude_run: refusing outcome=$outcome for #$n -- $quota_provider provider quota hold is open" >&2
    return 1
  fi
  state="$(state_read "$n")"
  case "$outcome" in
    merged)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      if [ -z "$pr_number" ]; then
        echo "conclude_run: refusing outcome=merged for #$n -- no .run.evidence.pr_number recorded" >&2
        return 1
      fi
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      if ! mandatory_check_receipt_ready "$n" "$pr_head_sha"; then
        mandatory_check_status="$(state_read "$n" | jq -r '.run.evidence.mandatory_checks.status // "missing"')"
        echo "conclude_run: refusing outcome=merged for #$n -- mandatory checks are $mandatory_check_status" >&2
        return 1
      fi
      ;;
    deployed)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      deploy_state="$(echo "$state" | jq -r '.deploy_state // empty')"
      deployed_sha="$(echo "$state" | jq -r '.deployed_sha // empty')"
      real_user_path="$(echo "$state" | jq -r '.run.evidence.real_user_path // empty')"
      if [ "$(echo "$state" | jq -r '.run.outcome // empty')" != "merged" ] \
        || [ "$deploy_state" != "deployed" ] || [ -z "$pr_number" ] || [ -z "$deployed_sha" ] \
        || [[ "$real_user_path" != *"URL:"* ]] || [[ "$real_user_path" != *"Visible DOM:"* ]] || [[ "$real_user_path" != *"Same-run network:"* ]]; then
        echo "conclude_run: refusing outcome=deployed for #$n -- merged outcome plus deployed SHA, URL, visible DOM, and same-run network evidence required" >&2
        return 1
      fi
      release_feature_evidence_valid "$n" "$real_user_path" || return 1
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      if ! mandatory_check_receipt_ready "$n" "$pr_head_sha"; then
        mandatory_check_status="$(state_read "$n" | jq -r '.run.evidence.mandatory_checks.status // "missing"')"
        echo "conclude_run: refusing outcome=deployed for #$n -- mandatory checks are $mandatory_check_status" >&2
        return 1
      fi
      ;;
    pr-open)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      review_verdict="$(echo "$state" | jq -r '.run.evidence.review_verdict // empty')"
      ci_outcome="$(echo "$state" | jq -r '.run.evidence.ci_outcome // empty')"
      if [ -z "$pr_number" ] || [ -z "$review_verdict" ] || [ -z "$ci_outcome" ]; then
        echo "conclude_run: refusing outcome=pr-open for #$n -- missing evidence (pr_number=${pr_number:-<empty>} review_verdict=${review_verdict:-<empty>} ci_outcome=${ci_outcome:-<empty>})" >&2
        return 1
      fi
      ;;
    not-completed)
      attempts="$(state_attempts "$n")"
      implement_episode="$(echo "$state" | jq -r '((.model_policy.unit // (if .model_policy.step then "implement" else "" end)) == "implement") or ((.requeued_at // "") != "")')"
      policy_exhausted="$(echo "$state" | jq -r '(. as $s | (if ($s.model_policy.unit // (if $s.model_policy.step then "implement" else "" end)) == "implement" then [$s.requeued_at // "", $s.run.concluded_at // "", $s.run.previous_concluded_at // ""] else [$s.requeued_at // "", $s.run.previous_concluded_at // ""] end | max) as $boundary | $s.model_policy.step == "conclude" and (($s.model_policy.failure.reason // "") != "") and (($s.model_policy.failure.recorded_at // "") > $boundary))')"
      implement_after_requeue="$(echo "$state" | jq -r '(. as $s | ([$s.requeued_at // "", $s.run.concluded_at // "", $s.run.previous_concluded_at // ""] | max) as $boundary | ($s.run.implement_started_at // "") as $started | ($started != "" and ($boundary == "" or $started >= $boundary)))')"
      # At the cap no new implement can start (only a requeue resets attempts), so demanding one after the
      # last conclusion livelocked hold-expired issues: issues 1758/1820/1952/1970/2144 sat 5 days re-refused every tick.
      if { [ "$implement_episode" = true ] && [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] \
          && { [ "$attempts" -eq 0 ] || [ "$implement_after_requeue" != true ]; }; } \
        || { [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] && [ "$policy_exhausted" != true ]; } \
        || [ -z "$needs_md" ]; then
        echo "conclude_run: refusing outcome=not-completed for #$n -- attempts=$attempts (cap $CONCLUDE_RUN_ATTEMPT_CAP), needs_md=${needs_md:+set}${needs_md:-<empty>}" >&2
        return 1
      fi
      ;;
    # 2026-09-16 (batch advisor sweep, run-advisor-batch.sh): a ticket the
    # advisor rules a duplicate of another, SURVIVING ticket has its own
    # work done by the survivor -- an ordinary conclusion through this same
    # terminal, not a new one and not a park. .run.evidence.duplicate_of
    # (the survivor's issue number) is the evidence this outcome requires,
    # same shape as `merged` requiring .run.evidence.pr_number: the caller
    # writes it before calling this, this only verifies it is there.
    duplicate)
      duplicate_of="$(echo "$state" | jq -r '.run.evidence.duplicate_of // empty')"
      if [ -z "$duplicate_of" ] || [ -z "$needs_md" ]; then
        echo "conclude_run: refusing outcome=duplicate for #$n -- duplicate_of=${duplicate_of:-<empty>}, needs_md=${needs_md:+set}${needs_md:-<empty>}" >&2
        return 1
      fi
      ;;
    pipeline-system)
      pipeline_sha="$(echo "$state" | jq -r '.pipeline_system.commit_sha // empty')"
      if [ "$(echo "$state" | jq -r '.pipeline_system.enabled // false')" != true ] \
        || ! [[ "$pipeline_sha" =~ ^[0-9a-f]{40,64}$ ]] \
        || ! git -C "$REPO_DIR" merge-base --is-ancestor "$pipeline_sha" HEAD; then
        echo "conclude_run: refusing outcome=pipeline-system for #$n -- pipeline-system commit is not recorded in live checkout" >&2
        return 1
      fi
      pipeline_close_comment="$BOT_DISCLAIMER
流水线系统改动已进入 live checkout。

Commit: $pipeline_sha

$needs_md

这张票已经关闭。如果验证下来还是不对，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。"
      if ! issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system '[]' \
        "${REPO%%/*}" 0 "$(date +%s)" "$pipeline_close_comment"; then
        echo "conclude_run: refusing outcome=pipeline-system for #$n -- close comment must cite its issue-linked commit reachable from origin/main" >&2
        return 1
      fi
      issue_state="$(gh issue view "$n" --repo "$REPO" --json state -q .state)" || return 1
      ;;
    *)
      echo "conclude_run: unknown outcome '$outcome' for #$n -- refusing" >&2
      return 1
      ;;
  esac

  if [ "$outcome" = "not-completed" ]; then
    mandatory_check_status="$(echo "$state" | jq -r '.run.evidence.mandatory_checks.status // empty')"
    implementation_run="$(echo "$state" | jq -r '((.model_policy.unit // "") == "implement") or (.run.evidence.mandatory_checks != null)')"
    [ "$implement_after_requeue" = true ] && implementation_run=true
    if [ -z "$mandatory_check_status" ] && [ "$implementation_run" = true ]; then
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      record_mandatory_check_receipt "$n" missing "$pr_head_sha" "No mandatory-check receipt was recorded."
      mandatory_check_status=missing
      state="$(state_read "$n")"
    fi
    conclusion_json="$(conclusion_classification_for_state "$n" "$state" "$needs_md" "$outcome")" || return 1
    conclusion_json="$(jq -c --arg status "$mandatory_check_status" '.mandatory_checks_status = $status' <<< "$conclusion_json")" || return 1
  fi

  web_advisor_provider_clear_job_state "$n" || return 1
  local outcome_json needs_json needs_md_file label
  outcome_json="$(jq -n --arg o "$outcome" '$o')"
  needs_md_file="$(jq_arg_file "$needs_md")"
  needs_json="$(jq -n --rawfile m "$needs_md_file" '$m')"
  rm -f "$needs_md_file"
  # The old rule solved a real wait-forever problem: no human reply may block
  # a completed pipeline run. The replacement keeps that property but makes
  # production evidence, not merge, the mechanical completion condition.
  if [ "$outcome" = "merged" ]; then
    state_merge "$n" ".run.needs_md = $needs_json" || return 1
    mark_awaiting_release "$n" "$pr_number" "$expected_hold" || return 1
    local merged_comment_marker="<!-- vecta-merged-outcome issue=$n pr=$pr_number -->" merged_comments_json
    if [ "${AGENT_DRY_RUN:-0}" != 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
      merged_comments_json="$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate --slurp)" || {
        echo "conclude_run: cannot inspect merged-outcome comments for #$n; leaving merge reconciliation retryable" >&2
        return 1
      }
      if ! jq -e 'type == "array" and all(flatten[]?; type == "object" and (.body | type == "string"))' \
        <<< "$merged_comments_json" >/dev/null 2>&1; then
        echo "conclude_run: merged-outcome comments have invalid shape for #$n; leaving merge reconciliation retryable" >&2
        return 1
      fi
    else
      merged_comments_json='[]'
    fi
    # The exact-PR text check recognizes handoff comments posted before the marker existed.
    if ! jq -e --arg marker "$merged_comment_marker" --arg pr "PR #$pr_number" --arg disclaimer "$BOT_DISCLAIMER" '
      any(flatten[]?.body; contains($marker) or (startswith($disclaimer) and contains("这张票的实现已合并") and test("(^|[^0-9])" + $pr + "([^0-9]|$)")))
    ' <<< "$merged_comments_json" >/dev/null 2>&1; then
      needs_md+=$'\n\n'"$merged_comment_marker"
      guarded_issue_comment "$n" "$BOT_DISCLAIMER
这张票的实现已合并，正在等待生产部署及同一次真实用户路径的 URL、可见 DOM 和网络交换证据。$needs_md" || return 1
    fi
    return 0
  fi

  if [ "$outcome" = "deployed" ]; then
    # `record_deploy_evidence` writes the proof before this point. Keep that
    # state durable if a GitHub mutation retries; only mark concluded after
    # the actual close succeeds. The pending marker lets the scheduler rebuild
    # the mail outbox if queueing later fails.
    state_merge "$n" '.maintainer_outcome_pending = true' || return 1
    local transition_filter='del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | .released = true | .closed_by_pipeline = true | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
    issue_transition "$n" concluded conclude:deployed "$transition_filter" || return 1
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
这张票已部署，并已记录同一次真实用户路径的 URL、可见 DOM 和网络交换证据。$needs_md

这张票已经关闭。如果之后验证发现仍有问题，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。" || return 1
    guarded_write gh issue close "$n" --repo "$REPO" || return 1
    if queue_maintainer_outcome "$n" "$deployed_sha"; then
      if ! state_merge "$n" 'del(.maintainer_outcome_pending)'; then
        echo "conclude_run: queued production outcome for #$n, but retry marker could not be cleared" >&2
      fi
    else
      echo "conclude_run: deployed outcome for #$n is recorded for digest retry" >&2
    fi
    return 0
  fi

  if [ "$outcome" = "pipeline-system" ]; then
    local comment_posted comment_epoch comment_since comments_json evidence_status
    comment_posted="$(echo "$state" | jq -r '.pipeline_system.close_comment_posted_at // empty')"
    if [ -z "$comment_posted" ]; then
      guarded_issue_comment "$n" "$pipeline_close_comment" || return 1
      state_merge "$n" '.pipeline_system.close_comment_posted_at = (now | todate)' || return 1
    else
      comment_epoch="$(agent_epoch "$comment_posted" 2>/dev/null || true)"
      [[ "$comment_epoch" =~ ^[0-9]+$ ]] || return 1
      comment_since="$(date -u -d "@$((comment_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
      comments_json="$(gh api "repos/$REPO/issues/$n/comments?since=$comment_since&per_page=100" --paginate --slurp)" || return 1
      if issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system \
        "$comments_json" "${REPO%%/*}" "$comment_epoch" "$(date +%s)"; then
        :
      else
        evidence_status=$?
        [ "$evidence_status" -eq 1 ] || return 1
        guarded_issue_comment "$n" "$pipeline_close_comment" || return 1
        state_merge "$n" '.pipeline_system.close_comment_posted_at = (now | todate)' || return 1
      fi
    fi
    local transition_filter=".run.outcome = $outcome_json | .run.needs_md = $needs_json | del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | .closed_by_pipeline = true | .pipeline_system.delivery_state = \"concluded\" | del(.pipeline_system.health_target, .pipeline_system.health_status, .pipeline_system.health_check_sha, .pipeline_system.health_checked_at, .pipeline_system.health_detail, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)"
    if [ -n "$expected_hold" ]; then
      (
        local f fd current
        f="$(state_file "$n")" || exit 1
        exec {fd}>"$f.lock" && flock -x "$fd" || exit 1
        current="$(state_read "$n")" || exit 1
        jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$current" >/dev/null || exit 1
        if [ "$issue_state" != "CLOSED" ]; then guarded_write gh issue close "$n" --repo "$REPO" || exit 1; fi
        issue_transition "$n" concluded conclude:pipeline-system "$transition_filter" 0 "" "" 0 "$expected_hold" __issue_transition_lock_held
      ) || return 1
    else
      if [ "$issue_state" != "CLOSED" ]; then guarded_write gh issue close "$n" --repo "$REPO" || return 1; fi
      issue_transition "$n" concluded conclude:pipeline-system "$transition_filter" || return 1
    fi
    return 0
  fi

  # Failed and draft outcomes remain immediate conclusions. They never wait
  # for a deploy that will not exist.
  local conclusion_filter=""
  [ "$outcome" != "not-completed" ] || conclusion_filter=" | .run.conclusion = $conclusion_json"
  local transition_filter=".run.outcome = $outcome_json | .run.needs_md = $needs_json$conclusion_filter | del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)"
  local close_now=0
  [ "$outcome" = "duplicate" ] && close_now=1
  if [ "$outcome" = duplicate ]; then
    issue_transition "$n" concluded conclude:duplicate "$transition_filter" || return 1
  else
    issue_transition "$n" concluded "conclude:$outcome" "$transition_filter" || return 1
  fi
  local close_note=""
  [ "$close_now" = "1" ] && close_note="

这张票已经关闭。如果验证下来还是不对，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。"
  local outcome_note="这张票的这一轮无人值守处理结束了（结果：${outcome}）。"
  case "$mandatory_check_status" in
    blocked) outcome_note="这一轮处理结束：必要测试被运行环境阻断，没有运行完成。" ;;
    missing) outcome_note="这一轮处理结束：没有可核对的必要测试记录，不能按通过处理。" ;;
    deferred) outcome_note="这一轮处理结束：必要测试交给了合并请求检查，尚无同一代码版本的绿色结果。" ;;
    failed) outcome_note="这一轮处理结束：必要测试运行了，但没有通过。" ;;
  esac
  [ "$outcome" = "pipeline-system" ] && outcome_note="流水线系统改动已进入 live checkout。"
  guarded_issue_comment "$n" "$BOT_DISCLAIMER
${outcome_note}$needs_md$close_note" || return 1
  if [ "$close_now" = "1" ]; then
    guarded_write gh issue close "$n" --repo "$REPO" || return 1
    state_merge "$n" '.closed_by_pipeline = true | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)' || return 1
    return 0
  fi

  local failure_reason report_what report_impact report_action
  case "$mandatory_check_status" in
    blocked|missing|deferred)
      # The issue comment above carries this. No mail: the maintainer contract refused every attempt
      # (8 contract-rejected sends by 2026-10-04), and each refusal flipped mail-credential BROKEN.
      return 0
      ;;
    failed)
      check_report_json="$(conclusion_check_report "$mandatory_check_status")" || return 1
      report_what="$(jq -r '.what' <<< "$check_report_json")"
      report_impact="$(jq -r '.impact' <<< "$check_report_json")"
      report_action="$(jq -r '.action' <<< "$check_report_json")"
      notify_email_reporter "$n" "[example] 这一轮未能完成" \
        "$report_what" "$report_impact" "$report_action" || true
      return 0
      ;;
  esac
  failure_reason="$(recorded_failure_reason_from_state "$state")"
  [ -n "$failure_reason" ] || failure_reason="$needs_md"
  report_what="$(_maintainer_readable_or_fallback "$failure_reason" "这一轮没能改完，先停下了。")"
  notify_email_reporter "$n" "[example] 这一轮未能完成" \
    "$report_what" \
    "问题还在，用户暂时看不到变化。" \
    "不用现在操作；处理原因已记录在问题进展中。" || true
  return 0
}


# Rebuild the mail outbox from deployed issue state before each digest flush.
# The marker is written before GitHub close; failed queue writes stay retryable.
reconcile_maintainer_outcomes() {
  local state_file issue_num deployed_sha pending_files grep_status=0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  # One jq per state file cost 164 s per tick over 1829 files (2026-10-08);
  # only files that mention the marker can be pending.
  pending_files="$(grep -lF maintainer_outcome_pending -- "$AGENT_HOME"/state/*.json 2>/dev/null)" || grep_status=$?
  if [ "$grep_status" -gt 1 ] && [ -n "$(compgen -G "$AGENT_HOME/state/*.json")" ]; then
    echo "reconcile_maintainer_outcomes: cannot scan state files; digest send deferred" >&2
    return 1
  fi
  while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    deployed_sha="$(jq -r 'if .maintainer_outcome_pending == true then .deployed_sha // error("pending outcome has no deployed SHA") else empty end' "$state_file" 2>/dev/null)" || {
      echo "reconcile_maintainer_outcomes: cannot read $state_file; digest send deferred" >&2
      return 1
    }
    [ -n "$deployed_sha" ] || continue
    issue_num="${state_file##*/}"
    issue_num="${issue_num%.json}"
    if ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
      echo "reconcile_maintainer_outcomes: invalid issue state filename $state_file" >&2
      return 1
    fi
    if ! queue_maintainer_outcome "$issue_num" "$deployed_sha"; then
      echo "reconcile_maintainer_outcomes: could not queue deployed outcome for #$issue_num; digest send deferred" >&2
      return 1
    fi
    if ! state_merge "$issue_num" 'del(.maintainer_outcome_pending)'; then
      echo "reconcile_maintainer_outcomes: queued #$issue_num but could not clear retry marker; digest send deferred" >&2
      return 1
    fi
  done <<< "$pending_files"
}


# Shared post-merge bookkeeping for the implement leg and the orphan-PR
# sweeper. A pipeline-system PR already present in the live checkout can close
# through its own evidence path; other merges enter the release handoff.
conclude_merged_run() {
  local n="$1" pr_number="$2" merge_detail="${3:-}" expected_hold="${4:-}" merged_row merge_sha state pipeline_enabled merge_sha_json close_comment evidence_status
  if [ -n "$expected_hold" ]; then
    state="$(state_read "$n")" || return 1
    jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null || return 1
  fi
  if ! merged_row="$(merged_pr_main_row "$pr_number" "$n")"; then
    echo "conclude_merged_run: refusing PR #$pr_number for #$n -- only merged PRs targeting main can enter awaiting-release" >&2
    return 1
  fi
  merge_sha="${merged_row#*$'\t'}"
  state="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null; then return 1; fi
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$state" >/dev/null 2>&1; then
    echo "conclude_merged_run: #$n is tracker parent; recorded PR #$pr_number merge $merge_sha without changing aggregate or release state" >&2
    return 0
  fi
  merge_detail="${merge_detail:-PR #$pr_number auto-merged (squash). Waiting on Postsubmit validate before release.}"
  record_run_decision "$n" wrapper "Merged PR #$pr_number (squash)" 0
  state="$(state_read "$n")" || return 1
  pipeline_enabled="$(jq -r '.pipeline_system.enabled // false' <<< "$state")" || return 1
  if [ "$pipeline_enabled" = true ] && git -C "$REPO_DIR" merge-base --is-ancestor "$merge_sha" HEAD; then
    merge_sha_json="$(jq -n --arg sha "$merge_sha" '$sha')" || return 1
    state_merge "$n" ".pipeline_system.commit_sha = $merge_sha_json" || return 1
    close_comment="$BOT_DISCLAIMER
流水线系统改动已进入 live checkout。

Commit: $merge_sha

$merge_detail

这张票已经关闭。"
    if issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system '[]' \
      "${REPO%%/*}" 0 "$(date +%s)" "$close_comment"; then
      conclude_run "$n" pipeline-system "PR #$pr_number merged as $merge_sha" "" "$expected_hold"
      return $?
    else
      evidence_status=$?
    fi
    [ "$evidence_status" -eq 1 ] || return "$evidence_status"
    echo "conclude_merged_run: pipeline-system close evidence refused for #$n; falling back to merged" >&2
  fi
  conclude_run "$n" merged "$merge_detail" "" "$expected_hold"
}
