
# Failed attempts on one issue: stop retrying THIS leg, hand it to the
# advisor for a fresh episode instead -- a different script, possibly a
# different model/provider, gets a shot before anyone parks.
# 2026-09-12 bug: this added needs-owner but left whatever state label made
# the issue eligible (needs-triage, ready-for-agent, ...) in place, so the
# poller kept re-selecting the same poison-pill issue every tick forever
# (breaking "exactly one state label" too). Strip every other state label in
# the same call.
# 2026-09-15 (maintainer ruling, verbatim: [...]
# ): needs-owner is the same banned human terminal as
# ready-for-human -- a queue nobody is assigned to drain is not a queue. No
# code path in this pipeline may add it any more; a repeated tool/model
# failure routes to needs-advisor instead, same destination
# enforce_autonomy_gate()'s own refusals use. Can't call route_to_advisor()
# (lib.sh) directly here: that helper only ever strips the ONE label named
# in its $2 (default ready-for-agent), but this call site's issue can be
# eligible from any prior state (needs-triage, ready-for-agent, ...) and
# still needs the full ALL_STATE_LABELS strip below to hold "exactly one
# state label" -- so this replicates route_to_advisor's other effect
# (clearing a stale advisor_ruled_at, so a fresh advisor episode is
# actually dispatchable) inline instead of bending that helper's contract.
#
# A provider quota hold suppresses this ticket-local terminal only when this
# same provider caused the current failure.
give_up_on_issue() {
  local n="$1" reason="$2" quota_provider="${3:-}" issue_json="${4:-}" pipeline_system_status=0 readable_reason
  if [ -n "$quota_provider" ] && provider_quota_exhausted "$quota_provider"; then
    echo "give_up_on_issue: refusing #$n -- $quota_provider provider quota hold is open" >&2
    return 1
  fi
  pipeline_system_route_status "$n" "$issue_json" || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      echo "give_up_on_issue: #$n is pipeline-system; returning it to implementation instead of advisor" >&2
      pipeline_system_return_to_implement "$n"
      return $?
      ;;
    1) ;;
    *) echo "give_up_on_issue: #$n -- cannot classify lane; refusing advisor route" >&2; return 1 ;;
  esac
  if advisor_role_disabled; then
    echo "give_up_on_issue: #$n -- advisor role disabled; holding for the maintainer" >&2
    hold_for_missing_advisor "$n"
    return $?
  fi
  local admission=0
  advisor_retry_admission "$n" || admission=$?
  case "$admission" in
    0) ;;
    10) return 0 ;;
    *) return "$admission" ;;
  esac
  # Same guard as route_to_advisor()/route_to_recut() (2026-09-16, V102's
  # third recurrence): do not move the label if the clear itself failed.
  # .pending_advisor_verdict cleared alongside .advisor_ruled_at as of
  # 2026-09-19, same reasoning as route_to_advisor()'s own comment on its
  # twin del() -- this call site starts a fresh advisor episode too (a
  # different leg's repeated failure routing here for "a fresh look"), and
  # a verdict left over from whatever the LAST advisor episode computed
  # must not be eligible for that fresh episode's own resume check to
  # silently reuse. advisor_episode_seq incremented in this SAME call, same
  # day, same reasoning as route_to_advisor()'s own twin addition just
  # above it in this file -- see that function's own comment for the race
  # (a web-advisor-provider job still in flight from the episode THIS call is
  # ending) this closes.
  local transition_filter='del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)'
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$transition_filter" || return 1
  else
    issue_transition "$n" needs-advisor attempts-exhausted "$transition_filter" || return 1
  fi
  guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$reason after $(state_attempts "$n") attempts. Routed to the advisor for a fresh look before another automated attempt."
  readable_reason="$(_maintainer_readable_or_fallback "$reason" "这一轮没能改完，已转给顾问继续判断。")"
  notify_email "$n" "[example] #$n 已转给顾问了" \
    "$readable_reason" \
    "问题还没有解决，顾问会继续判断。" \
    "通常不用管；进展会保留在这条 issue 里。" || true
}


# release_feature_evidence_valid <n> <evidence> -- require evidence to name an
# exercised feature surface; photo tickets require the actual attachment path.
release_feature_evidence_valid() {
  local n="$1" evidence="$2" state brief surface surface_matches=0 token cjk photo_bytes i
  RELEASE_SURFACE_UNCOVERED=0
  state="$(state_read "$n")"
  if ! grep -Eq '^Feature surface: .{8,}$' <<< "$evidence"; then
    echo "release evidence: refusing #$n -- feature surface is unnamed" >&2
    return 1
  fi
  brief="$(jq -r '[(.title // ""),(.brief_md // "")] | join("\n")' <<< "$state" | tr '[:upper:]' '[:lower:]')"
  surface="$(sed -n 's/^Feature surface: //p' <<< "$evidence" | tr '[:upper:]' '[:lower:]' | head -n1)"
  # ponytail: token overlap is a cheap surface matcher; replace with explicit feature IDs if ticket metadata gains them.
  if [ -n "$brief" ] && [[ ! "$brief" =~ (photo|image|multimodal|attachment|图片|照片|多模态|附件) ]]; then
    while IFS= read -r token; do
      case "$token" in
        about|across|after|again|agent|allow|and|any|apply|based|before|between|build|change|changed|check|client|code|could|create|critical|data|default|design|detail|during|each|enable|every|example|existing|feature|file|first|flow|from|function|generic|image|include|input|issue|must|need|new|only|other|path|please|product|production|release|request|required|result|same|send|service|should|show|state|support|system|test|tests|through|ticket|under|user|using|value|when|with|work|works|worker|write) continue ;;
      esac
      if [[ "$surface" == *"$token"* ]]; then surface_matches=1; break; fi
    done < <(grep -Eio '[[:alpha:]][[:alnum:]_-]{4,}' <<< "$brief" | sort -u || true)
    if [ "$surface_matches" != 1 ]; then
      while IFS= read -r cjk; do
        for ((i = 0; i + 1 < ${#cjk}; i++)); do
          token="${cjk:i:2}"
          if [[ "$surface" == *"$token"* ]]; then surface_matches=1; break 2; fi
        done
      done < <(grep -Eo '[一-龥]{2,}' <<< "$brief" || true)
    fi
    if [ "$surface_matches" != 1 ]; then
      # 2026-09-24 ruling: a feature the automated acceptance cannot exercise
      # closes at deploy and the reporter reopens it if broken. Refusing here
      # reran the full production E2E every tick (issue 1211). Photo tickets
      # below still need the real photo path.
      RELEASE_SURFACE_UNCOVERED=1
      echo "release evidence: #$n feature surface is not exercised by the automated acceptance; closing at deploy per the 2026-09-24 ruling" >&2
    fi
  fi
  if [[ "$brief" =~ (photo|image|multimodal|attachment|图片|照片|多模态|附件) ]]; then
    photo_bytes="$(sed -nE 's/^Photo attachment: ([0-9]+) bytes$/\1/p' <<< "$evidence" | head -n1)"
    if [[ "$evidence" != *"Feature surface: photo attachment send through /chat/"* ]] \
      || ! [[ "$photo_bytes" =~ ^[0-9]+$ ]] || (( photo_bytes < 250000 || photo_bytes > 500000 )) \
      || ! grep -Eq '^Photo upload: POST /chat/api/v1/files/ -> [23][0-9]{2} \(finished\)$' <<< "$evidence" \
      || ! grep -Eq '^Photo completion: POST /chat/api/chat/completions -> [23][0-9]{2} \(finished\)$' <<< "$evidence" \
      || ! grep -Eq '^Visible assistant reply: yes \([1-9][0-9]* chars\)$' <<< "$evidence"; then
      echo "release evidence: refusing #$n -- photo/attachment feature needs a 250-500 KB upload, successful chat completion, and visible assistant reply" >&2
      return 1
    fi
  fi
  return 0
}


# Close-contract refusals depend on ticket revision; acceptance depends on SHA.
release_close_state_revision() {
  jq -c '[.state, .requeued_at, .run.implement_started_at, .run.concluded_at,
    .run.previous_concluded_at, .run.evidence.pr_number, .run.evidence.merged_pr,
    .run.evidence.mandatory_checks.status, .run.evidence.mandatory_checks.head_sha]'
}


release_close_refusal_seen() {
  local n="$1" sha="$2" state revision
  [[ "$n" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[a-f0-9]{40,64}$ ]] || return 64
  state="$(state_read "$n")" || return 2
  jq -e 'type == "object" and ((.release_close_refusals // {}) | type == "object")' \
    <<< "$state" >/dev/null 2>&1 || return 2
  revision="$(release_close_state_revision <<< "$state")" || return 2
  jq -e --arg sha "$sha" --argjson revision "$revision" '
    .release_close_contract_refusal_revision == $revision
    or ((.release_close_refusals[$sha] // "") | . != "" and . != "close-contract-failed")
  ' <<< "$state" >/dev/null 2>&1
}


release_close_refusal_record() {
  local n="$1" sha="$2" reason="$3" state sha_json reason_json reason_file revision
  [[ "$n" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[a-f0-9]{40,64}$ && -n "$reason" ]] || return 64
  state="$(state_read "$n")" || return 2
  jq -e 'type == "object" and ((.release_close_refusals // {}) | type == "object")' \
    <<< "$state" >/dev/null 2>&1 || return 2
  if [ "$reason" = close-contract-failed ]; then
    revision="$(release_close_state_revision <<< "$state")" || return 2
    state_merge "$n" ".release_close_contract_refusal_revision = $revision"
    return $?
  fi
  sha_json="$(jq -Rn --arg value "$sha" '$value')" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
  rm -f -- "$reason_file"
  state_merge "$n" ".release_close_refusals = ((.release_close_refusals // {}) + {($sha_json): $reason_json})"
}


release_close_refusal_comment_once() {
  local n="$1" reason="$2" body="$3" state last_reason comments_json prior_reason reason_json reason_file
  state="$(state_read "$n")" || return 1
  last_reason="$(jq -r '.release_close_last_comment_reason // empty' <<< "$state")" || return 1
  if [ -z "$last_reason" ]; then
    if comments_json="$(gh issue view "$n" --repo "$REPO" --json comments -q .comments 2>/dev/null)"; then
      prior_reason="$(jq -r \
        --arg evidence "this ticket's acceptance evidence did not satisfy its close contract" \
        --arg preparation "ticket-specific close preparation failed" \
        --arg close "this ticket's close contract failed" \
        'if type == "array" then ([.[] | (.body? // "") | if contains($evidence) then "acceptance-evidence-rejected" elif contains($preparation) then "close-preparation-failed" elif contains($close) then "close-contract-failed" else empty end] | last // "") else "" end' \
        <<< "$comments_json")" || return 1
      if [ "$prior_reason" = "$reason" ]; then
        reason_file="$(jq_arg_file "$reason")" || return 1
        reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
        rm -f -- "$reason_file"
        state_merge "$n" ".release_close_last_comment_reason = $reason_json" || return 1
        echo "run-release: suppressing repeated close-refusal comment for #$n (reason=$reason)" >&2
        return 0
      fi
    else
      echo "run-release: suppressing close-refusal comment for #$n -- previous comments are unreadable" >&2
      return 0
    fi
  elif [ "$last_reason" = "$reason" ]; then
    echo "run-release: suppressing repeated close-refusal comment for #$n (reason=$reason)" >&2
    return 0
  fi
  if ! guarded_issue_comment "$n" "$body"; then
    echo "run-release: close-refusal comment failed for #$n" >&2
    return 0
  fi
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
  rm -f -- "$reason_file"
  state_merge "$n" ".release_close_last_comment_reason = $reason_json"
}


release_close_refusal_note() {
  local n="$1" sha="$2" reason="$3" body="$4"
  release_close_refusal_record "$n" "$sha" "$reason" || return 1
  release_close_refusal_comment_once "$n" "$reason" "$body"
}


# record_deploy_evidence <n> <sha> <real-user-path-evidence> -- stores the
# evidence `run-release.sh` extracted from one authenticated browser run.
# `conclude_run deployed` verifies this exact record before closing, so a
# deploy/readback alone can never take the close path.
record_deploy_evidence() {
  local n="$1" deployed_sha="$2" evidence="$3" state pr_number outcome deploy_state evidence_file evidence_json sha_json
  state="$(state_read "$n")"
  pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
  outcome="$(echo "$state" | jq -r '.run.outcome // empty')"
  deploy_state="$(echo "$state" | jq -r '.deploy_state // empty')"
  # Empty deploy_state is the one-way migration shape from the former
  # close-at-merge record: it already proves a merge, but predates this
  # handoff field. New merges always arrive here as pending.
  if [ -z "$pr_number" ] || [ "$outcome" != "merged" ] \
    || { [ -n "$deploy_state" ] && [ "$deploy_state" != "pending" ] && [ "$deploy_state" != "deployed" ]; }; then
    echo "record_deploy_evidence: refusing #$n -- merged outcome with empty/pending deploy_state required (pr_number=${pr_number:-<empty>} outcome=${outcome:-<empty>} deploy_state=${deploy_state:-<empty>})" >&2
    return 1
  fi
  if [ -z "$deployed_sha" ] || [[ "$evidence" != *"URL:"* ]] || [[ "$evidence" != *"Visible DOM:"* ]] || [[ "$evidence" != *"Same-run network:"* ]]; then
    echo "record_deploy_evidence: refusing #$n -- production proof requires deployed SHA plus URL, visible DOM, and same-run network evidence" >&2
    return 1
  fi
  release_feature_evidence_valid "$n" "$evidence" || return 1
  evidence_file="$(jq_arg_file "$evidence")"
  evidence_json="$(jq -n --rawfile e "$evidence_file" '$e')"
  rm -f "$evidence_file"
  sha_json="$(jq -n --arg sha "$deployed_sha" '$sha')"
  state_merge "$n" ".run.evidence.production_evidence_at = (if .deployed_sha == $sha_json then (.run.evidence.production_evidence_at // (now | todate)) else (now | todate) end) | .run.evidence.production_evidence_attempt = (if .deployed_sha == $sha_json then (.run.evidence.production_evidence_attempt // (.attempts // 0)) else (.attempts // 0) end) | .deploy_state = \"deployed\" | .deployed_sha = $sha_json | .run.evidence.real_user_path = $evidence_json" || return $?
  efficiency_metrics_sync_issue_lifecycle "$n"
}


# record_mandatory_check_receipt <issue> <status> <head-sha> <summary>
# Status is replaced for each checked head; replaying the same receipt keeps
# its original timestamp and any later exact-head CI evidence.
record_mandatory_check_receipt() {
  local n="$1" status="$2" head_sha="$3" summary="${4:-}" receipt_json status_json head_json summary_json filter
  case "$status" in passed|deferred|blocked|failed|missing) ;; *) return 2 ;; esac
  if [ -n "$head_sha" ] && ! [[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]]; then return 2; fi
  receipt_json="$(jq -nc --arg status "$status" --arg head_sha "$head_sha" --arg summary "$summary" \
    '{status:$status,head_sha:$head_sha,summary:$summary}')" || return 1
  status_json="$(jq -Rn --arg value "$status" '$value')" || return 1
  head_json="$(jq -Rn --arg value "$head_sha" '$value')" || return 1
  summary_json="$(jq -Rn --arg value "$summary" '$value')" || return 1
  filter="if (.run.evidence.mandatory_checks.status == $status_json and .run.evidence.mandatory_checks.head_sha == $head_json and .run.evidence.mandatory_checks.summary == $summary_json) then . else .run.evidence.mandatory_checks = ($receipt_json + {recorded_at:(now|todate)}) | del(.run.evidence.ci_outcome,.run.evidence.ci_head_sha) end"
  state_merge "$n" "$filter"
}


# mandatory_check_receipt_ready <issue> <expected-head-sha>
# Fails only when the receipt for this exact head says blocked or failed.
mandatory_check_receipt_ready() {
  local n="$1" expected_sha="$2" state status receipt_sha
  state="$(state_read "$n")" || return 1
  status="$(jq -r '.run.evidence.mandatory_checks.status // empty' <<< "$state")"
  receipt_sha="$(jq -r '.run.evidence.mandatory_checks.head_sha // empty' <<< "$state")"
  # Only a run's own claim that this exact head's checks were blocked or failed stops the
  # terminal. Hand PRs, PRs opened before receipts existed, and heads pushed after the
  # receipt carry none, and the merge gate already required exact-head CI; requiring a
  # receipt refused every in-flight PR and every awaiting-release ticket (2026-10-04).
  [ -n "$status" ] && [ "$receipt_sha" = "$expected_sha" ] || return 0
  case "$status" in
    blocked|failed) return 1 ;;
    *) return 0 ;;
  esac
}


# A sandbox signature is not a real check blocker when the pipeline runs
# unsandboxed. Keep this list shared by intake and parked-ticket recovery.
checks_blocked_line_is_sandbox_signature() {
  local line="${1,,}"
  [[ "$line" == *"blocked by the sandbox policy"* ]] && return 0
  [[ "$line" == *"operation not permitted"* && "$line" == *"user bus"* ]] && return 0
  [[ "$line" == *"gh"* && "$line" == *"disabled by execution policy"* ]] && return 0
  [[ "$line" == *"read-only file system"* ]] && return 0
  [[ "$line" == *"tsx"* && "$line" == *"pipe"* && "$line" == *"eperm"* ]] && return 0
  return 1
}


checks_blocked_summary_is_sandbox_only() {
  local line found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    found=1
    checks_blocked_line_is_sandbox_signature "$line" || return 1
  done <<< "$1"
  [ "$found" -eq 1 ]
}


checks_blocked_escalate_repeat() {
  local n="$1" head_sha="$2" summary="$3" state auto_head escalated_head head_json
  state="$(state_read "$n")" || return 1
  auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state")" || return 1
  escalated_head="$(jq -r '.checks_blocked.escalated_head_sha // empty' <<< "$state")" || return 1
  [ "$auto_head" = "$head_sha" ] && [ "$escalated_head" != "$head_sha" ] || return 0
  supervisor_inbox_append_once "checks-blocked-repeat issue=#$n head=$head_sha" \
    "checks-blocked-repeat issue=#$n head=$head_sha action=review-required-checks checks=$summary" || return 1
  head_json="$(jq -Rn --arg value "$head_sha" '$value')" || return 1
  state_merge "$n" ".checks_blocked = ((.checks_blocked // {}) + {escalated_head_sha:$head_json,escalated_at:(now|todate)})"
}


# Each tick owns parked checks-blocked issues: release recovered blockers or
# retry once after the bound, then let record_implement_blocked_checks escalate repeats.
checks_blocked_sweep() {
  local numbers n state status head_sha summary recorded_at recorded_epoch auto_head repeat_head escalated_head
  local now should_requeue failure=0 head_json summary_json
  numbers="$(gh issue list --repo "$REPO" --limit 1000 --label checks-blocked --state open --json number --jq '.[].number')" || return 1
  now="$(date +%s)" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    state="$(state_read "$n")" || { failure=1; continue; }
    status="$(jq -r '.run.evidence.mandatory_checks.status // empty' <<< "$state")" || { failure=1; continue; }
    [ "$status" = blocked ] || continue
    head_sha="$(jq -r '.run.evidence.mandatory_checks.head_sha // empty' <<< "$state")" || { failure=1; continue; }
    [ -n "$head_sha" ] || continue
    summary="$(jq -r '.run.evidence.mandatory_checks.summary // empty' <<< "$state")" || { failure=1; continue; }
    auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    repeat_head="$(jq -r '.checks_blocked.repeat_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    escalated_head="$(jq -r '.checks_blocked.escalated_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    if [ "$repeat_head" = "$head_sha" ] && [ "$escalated_head" != "$head_sha" ]; then
      checks_blocked_escalate_repeat "$n" "$head_sha" "$summary" || failure=1
      continue
    fi
    [ "$auto_head" != "$head_sha" ] || continue

    should_requeue=0
    if [ "$CODEX_SANDBOX_MODE" = danger-full-access ] && checks_blocked_summary_is_sandbox_only "$summary"; then
      should_requeue=1
    else
      recorded_at="$(jq -r '.run.evidence.mandatory_checks.recorded_at // empty' <<< "$state")" || { failure=1; continue; }
      recorded_epoch="$(agent_epoch "$recorded_at" 2>/dev/null || echo 0)"
      [[ "$recorded_epoch" =~ ^[0-9]+$ ]] || recorded_epoch=0
      if (( recorded_epoch > 0 && now - recorded_epoch >= CHECKS_BLOCKED_MAX_AGE_SECONDS )); then
        should_requeue=1
      fi
    fi
    [ "$should_requeue" -eq 1 ] || continue
    is_on_hold "$n" && continue
    if ! state_requeue "$n"; then
      echo "checks_blocked_sweep: could not requeue #$n" >&2
      failure=1
      continue
    fi
    head_json="$(jq -Rn --arg value "$head_sha" '$value')" || { failure=1; continue; }
    summary_json="$(jq -Rn --arg value "$summary" '$value')" || { failure=1; continue; }
    if ! state_merge "$n" ".checks_blocked = ((.checks_blocked // {}) + {auto_requeued_head_sha:$head_json,auto_requeued_summary:$summary_json,auto_requeued_at:(now|todate)})"; then
      echo "checks_blocked_sweep: #$n requeued but could not record head guard" >&2
      failure=1
    fi
  done <<< "$numbers"
  [ "$failure" -eq 0 ]
}


# record_implement_blocked_checks <issue> <worktree> <model-log>
# Returns 1 when no actionable marker remains; otherwise parks the issue and
# escalates a second block on the same auto-requeued head.
record_implement_blocked_checks() {
  local n="$1" worktree="$2" log_file="$3" summary head_sha state_before auto_head repeat_head repeat_filter="" line filtered_summary="" failure_json transition_filter
  [ -r "$log_file" ] || return 2
  # 2026-10-05: issues 2146, 2184, 2388 and 2465 sat in checks-blocked over checks the sandbox cannot run but
  # the wrapper runs outside it anyway: check-rulings.sh (push preflight), git diff --check, the commit
  # itself, and changed scripts/**/*.test.{sh,mjs} suites (run_package_gates reruns them).
  # git fetch/rebase/pull/push (2151, 2159, 2164: read-only .git in the sandbox) belong to the wrapper too.
  # Later the same day 1243 and 1267 (tsx pipe EPERM in `pnpm --filter X test`), 1703, 2186, 2351
  # and 2491 (graph CLIs), and 1857, 1941, 1989, 2257, 2358 and 2543 (docker, gh, curl, browser,
  # E2E) sat there too: the package gates rerun build/test/typecheck outside the sandbox, graph
  # tools are advisory, and PR CI and the release step own the rest.
  summary="$(awk '
    /^BLOCKED-CHECKS:/ && /check-rulings\.sh|git diff --check|git commit|git (fetch|rebase|pull|push)|(scripts|engine)\/[^ ]*\.test\.(sh|mjs)/ { next }
    /^BLOCKED-CHECKS:/ && /pnpm (--filter [^ ]+ )?(run )?(test|build|typecheck)([^:a-z]|$)/ { next }
    /^BLOCKED-CHECKS:/ && /gitnexus/ { next }
    /^BLOCKED-CHECKS:/ && /docker|ssh |curl |wget |`gh |E2E|浏览器|browser/ { next }
    /^BLOCKED-CHECKS:[[:space:]]*[^[:space:]]/ && count < 10 {
      line = $0
      sub(/^BLOCKED-CHECKS:[[:space:]]*/, "", line)
      printf "%s%s", count++ ? "\n" : "", substr(line, 1, 500)
    }
  ' "$log_file")" || return 2
  if [ "$CODEX_SANDBOX_MODE" = danger-full-access ]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      checks_blocked_line_is_sandbox_signature "$line" && continue
      filtered_summary="${filtered_summary:+$filtered_summary$'\n'}$line"
    done <<< "$summary"
    summary="$filtered_summary"
  fi
  [ -n "$summary" ] || return 1
  head_sha="$(git -C "$worktree" rev-parse HEAD)" || return 2
  state_before="$(state_read "$n")" || return 2
  auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state_before")" || return 2
  repeat_head="$(jq -r '.checks_blocked.repeat_head_sha // empty' <<< "$state_before")" || return 2
  [ "$auto_head" != "$head_sha" ] || repeat_filter=" | .checks_blocked = ((.checks_blocked // {}) + {repeat_head_sha:$(jq -Rn --arg value "$head_sha" '$value')})"
  record_mandatory_check_receipt "$n" blocked "$head_sha" "$summary" || return 2
  # The blocked run is an implement failure like any other: record it where
  # requeue carries it into .model_policy.history, so the blind-rerun gate
  # sees issue 2695's four identical blocks instead of four fresh starts.
  failure_json="$(jq -cn --arg reason "$summary" --arg head "$head_sha" \
    '{unit:"implement",step:"work",stage:"checks-blocked",status:1,reason:$reason,head_sha:$head,recorded_at:(now|todate)}')" || return 2
  transition_filter=".run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.outcome = \"checks-blocked\" | .model_policy = (.model_policy // {}) | .model_policy.failure = $failure_json | .model_policy.failures = ((.model_policy.failures // []) + [$failure_json]) | del(.run.concluded_at,.run.needs_md,.run.conclusion,.closed_by_pipeline,.released)$repeat_filter"
  issue_transition "$n" checks-blocked required-checks-blocked "$transition_filter" || return 2
  if [ "$auto_head" = "$head_sha" ] && [ "$repeat_head" != "$head_sha" ]; then
    checks_blocked_escalate_repeat "$n" "$head_sha" "$summary" || return 2
  fi
  echo "implement checks blocked for issue $n; issue remains open as checks-blocked" >&2
}
