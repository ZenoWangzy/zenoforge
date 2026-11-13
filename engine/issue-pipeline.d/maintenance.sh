# Issue pipeline needs-info and maintenance functions.
# Definitions only; loaded by issue-pipeline.sh.

# Defect 6, 2026-09-13 (#1094): the read side of the ask/read loop (see
# notify.sh's Defect 6 comment for the ask side, run-triage.sh's needs-info
# branch for where a thread id first gets recorded). Pull open needs-info
# threads and still-open threads with an applied default; post each new
# genuine human reply as an issue comment.
#
# The hard boundary: this function may persist thread metadata and processed
# message ids, and may post a comment, but never edits an issue label or calls
# `gh issue edit`, `gh pr merge`, or another GitHub mutation. The existing
# needs-info recovery runs after stage admission and sees the relayed comment
# in the same tick; resulting triage work waits until the next tick. lib.test.sh
# checks this function for those verbs.
#
# Correlates by threadId only, never by parsing "#$n" out of a subject line
# — subjects get edited, forwarded and re-prefixed by mail clients, so a
# state-recorded threadId (Gmail's own opaque id) is the only correlation
# that can't drift. Dedup is by Gmail message id, recorded into each
# issue's own state file (`.processed_gmail_message_ids`) — examined once,
# recorded once, regardless of whether it turned out to be a genuine reply,
# our own outgoing mail, or a message from outside the trust boundary — so
# a reply can never be posted twice across a five-minute tick and this
# function never re-parses the same message on the next one either. A
# fetch failure (network hiccup, a dead credential — see
# check_gmail_credential()) leaves that message id UNrecorded on purpose,
# so it's retried next tick instead of being silently dropped.
read_needs_info_email_replies() {
  local issue_rows issue_row n state needs_info applied_thread thread_id message_ids processed processed_file mid raw parsed \
    from_email auto_submitted issue_marker body login trimmed comment_body question_thread sent_at \
    first_mid first_resource first_sent_at_ms first_raw first_parsed first_body default_option metadata_patch \
    email_stop_at="${ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS:-}"

  if [[ "$email_stop_at" =~ ^[0-9]+$ ]] && (( SECONDS >= email_stop_at )); then
    echo "issue-pipeline: needs-info email poll yielded at its reserved cutoff elapsed_sec=$SECONDS stop_at=$email_stop_at" >&2
    return 0
  fi
  # Only an issue whose state records a Gmail thread can have a reply to read,
  # so the 1000-issue GitHub listing is paid only when such a state file exists.
  grep -qs '"needs_info_thread_id"' "$STATE_DIR"/*.json || return 0
  issue_rows="$(gh issue list --repo "$REPO" --limit 1000 --state open --json number,labels)" || return 0
  while IFS= read -r issue_row; do
    if [[ "$email_stop_at" =~ ^[0-9]+$ ]] && (( SECONDS >= email_stop_at )); then
      echo "issue-pipeline: needs-info email poll yielded at its reserved cutoff elapsed_sec=$SECONDS stop_at=$email_stop_at" >&2
      return 0
    fi
    n="$(jq -r '.number // empty' <<< "$issue_row")"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    state="$(state_read "$n")"
    needs_info="$(jq -r 'any(.labels[]?; .name == "needs-info")' <<< "$issue_row")"
    applied_thread="$(jq -r '.needs_info_default_applied.thread_id // empty' <<< "$state")"
    thread_id="$(jq -r '.needs_info_thread_id // empty' <<< "$state")"
    [ -n "$thread_id" ] || continue
    [ "$needs_info" = true ] || [ "$applied_thread" = "$thread_id" ] || continue
    if [ "$applied_thread" != "$thread_id" ] && is_on_hold "$n"; then continue; fi

    message_ids="$(fetch_gmail_thread_message_ids "$thread_id")"
    [ -n "$message_ids" ] || continue

    question_thread="$(jq -r '.needs_info_question_thread_id // empty' <<< "$state")"
    sent_at="$(jq -r '.needs_info_question_sent_at // empty' <<< "$state")"
    first_mid=""
    first_resource=""
    first_sent_at_ms=""
    first_raw=""
    first_parsed=""
    if [ "$question_thread" != "$thread_id" ] || ! [[ "$sent_at" =~ ^[0-9]+$ ]]; then
      first_mid="${message_ids%%$'\n'*}"
      first_resource="$(fetch_gmail_message_resource_raw "$first_mid")"
      first_raw="$(jq -r '.raw // empty' <<< "$first_resource")"
      if [ -n "$first_raw" ]; then
        first_parsed="$(parse_gmail_message_raw "$first_raw")"
        first_sent_at_ms="$(jq -r '.internal_date_ms // empty' <<< "$first_resource")"
        if [[ "$first_sent_at_ms" =~ ^[0-9]+$ ]]; then
          sent_at=$((first_sent_at_ms / 1000))
        else
          # Gmail normally supplies internalDate; retain RFC822 Date fallback
          # for messages imported without that field.
          sent_at="$(jq -r '.date_epoch // empty' <<< "$first_parsed")"
        fi
        if [[ "$sent_at" =~ ^[0-9]+$ ]]; then
          first_body="$(jq -r '.body // empty' <<< "$first_parsed")"
          default_option="$(needs_info_default_option "$first_body" || true)"
          metadata_patch="$(jq -cn --arg thread "$thread_id" --arg option "$default_option" --argjson sent_at "$sent_at" \
            '{needs_info_question_thread_id:$thread,needs_info_question_sent_at:$sent_at,needs_info_default_option:(if $option == "" then null else $option end)}')"
          state_merge "$n" ". + $metadata_patch" || echo "issue-pipeline: could not record needs-info question date for #$n" >&2
        fi
      fi
    fi

    processed="$(state_read "$n" | jq -c '.processed_gmail_message_ids // []')"
    for mid in $message_ids; do
      if [[ "$email_stop_at" =~ ^[0-9]+$ ]] && (( SECONDS >= email_stop_at )); then
        break
      fi
      gmail_message_id_processed "$mid" "$processed" && continue

      if [ "$mid" = "$first_mid" ] && [ -n "$first_raw" ]; then
        raw="$first_raw"
        parsed="$first_parsed"
      else
        raw="$(fetch_gmail_message_raw "$mid")"
        [ -n "$raw" ] || continue
        parsed="$(parse_gmail_message_raw "$raw")"
        [ -n "$parsed" ] || continue
      fi

      from_email="$(echo "$parsed" | jq -r '.from // empty')"
      auto_submitted="$(echo "$parsed" | jq -r '.auto_submitted // empty')"
      issue_marker="$(echo "$parsed" | jq -r '.issue_marker // empty')"
      body="$(echo "$parsed" | jq -r '.body // empty')"

      if gmail_message_is_human_reply "$from_email" "$auto_submitted" "$issue_marker"; then
        login="$(resolve_login_for_email "$from_email")"
        trimmed="$(trim_quoted_reply "$body")"
        comment_body="> *This reply arrived by email and was relayed here automatically by the the product agent pipeline.* Original sender: @$login. $EMAIL_COMMENT_MARKER

$trimmed"
        guarded_write gh issue comment "$n" --repo "$REPO" --body "$comment_body"
      fi

      processed="$(echo "$processed" | jq -c --arg m "$mid" '. + [$m]')"
    done

    processed_file="$(mktemp)" || return 1
    printf '%s\n' "$processed" > "$processed_file" || { rm -f -- "$processed_file"; return 1; }
    state_merge "$n" '. + {processed_gmail_message_ids: $state_merge_patch[0]}' '' "$processed_file" \
      || { rm -f -- "$processed_file"; return 1; }
    rm -f -- "$processed_file"
  done < <(jq -c '.[]' <<< "$issue_rows")
}

reconcile_needs_info_issues() {
  local n issue_json lane_match_status last_comment_body
  for n in $(gh issue list --repo "$REPO" --limit 1000 --label needs-info --state open --json number -q '.[].number'); do
    is_on_hold "$n" && continue
    if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json number,labels,comments)"; then
      echo "issue-pipeline: could not read #$n labels/comments; leaving needs-info unchanged" >&2
      continue
    fi
    lane_match_status=0
    pipeline_system_issue_matches "$issue_json" || lane_match_status=$?
    case "$lane_match_status" in
      0)
        if stage_unit_active triage "$n" || stage_unit_active advisor "$n"; then continue; fi
        if ! prepare_pipeline_system_issue "$n" "$issue_json" needs-info; then
          echo "issue-pipeline: failed to clean pipeline-system needs-info issue #$n" >&2
        fi
        continue
        ;;
      1) ;;
      *) echo "issue-pipeline: cannot classify #$n; leaving needs-info unchanged" >&2; continue ;;
    esac
    last_comment_body="$(jq -r '.comments[-1].body // ""' <<< "$issue_json")"
    if ! needs_info_timeout_step "$n" "$issue_json" "$(date +%s)"; then
      echo "issue-pipeline: needs-info timeout step failed for #$n; leaving current stage unchanged" >&2
      continue
    fi
    case "$NEEDS_INFO_TIMEOUT_ACTION" in
      advisor-routed|default-applied) continue ;;
    esac
    if [ -n "$last_comment_body" ] && ! comment_is_bot "$last_comment_body"; then
      needs_info_resume_answered_issue "$n" "$issue_json"
    fi
  done
}

maintenance_record_deferred_step() { # section tick; emit one bell signature at the consecutive-tick threshold
  local section="$1" tick="$2" threshold="${MAINTENANCE_DEFERRAL_ALERT_AFTER:-3}"
  local state_file="$AGENT_HOME/night/maintenance-deferral-state.json" previous_tick="" previous_section="" previous_count=0 count runtime_dir stamp signature_written=0
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || threshold=3
  mkdir -p -- "${state_file%/*}" || return 0
  if jq -e 'type == "object" and (.consecutive | type) == "number"' "$state_file" >/dev/null 2>&1; then
    previous_tick="$(jq -r '.last_tick // empty' "$state_file")"
    previous_section="$(jq -r '.section // empty' "$state_file")"
    previous_count="$(jq -r '.consecutive // 0' "$state_file")"
  fi
  if [[ "$previous_tick" == "$tick" && "$previous_section" == "$section" ]]; then
    return 0
  fi
  [[ "$previous_count" =~ ^[0-9]+$ ]] || previous_count=0
  if [[ "$previous_section" == "$section" ]]; then
    count=$((previous_count + 1))
  else
    count=1
  fi
  local next_file="$state_file.tmp.$$"
  jq -cn --arg tick "$tick" --arg section "$section" --argjson count "$count" \
    '{last_tick:$tick,section:$section,consecutive:$count}' > "$next_file" \
    && mv -f -- "$next_file" "$state_file" || { rm -f -- "$next_file"; return 0; }
  if (( count == threshold )); then
    stamp="$(date -u +%FT%TZ)"
    runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${REPO_DIR:+$REPO_DIR/.scratch-supervisor/autopi}}"
    if [[ -n "$runtime_dir" && -d "$runtime_dir" ]]; then
      if printf '[%s] issue-pipeline: maintenance deferred streak section=%s consecutive=%s tick=%s\n' \
        "$stamp" "$section" "$count" "$tick" >> "$runtime_dir/scheduler.log" 2>/dev/null; then
        signature_written=1
      fi
    fi
    if [ "$signature_written" = 1 ]; then
      echo "issue-pipeline: maintenance deferred streak section=$section consecutive=$count tick=$tick; bell incident signature queued" >&2
    else
      echo "issue-pipeline: maintenance deferred streak section=$section consecutive=$count tick=$tick; bell incident signature write failed" >&2
    fi
  fi
}

maintenance_scheduler_log() { # one line for node health; a tick without the runtime dir has no health to feed
  local runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${REPO_DIR:+$REPO_DIR/.scratch-supervisor/autopi}}"
  [[ -n "$runtime_dir" && -d "$runtime_dir" ]] || return 0
  printf '[%s] issue-pipeline: %s\n' "$(date -u +%FT%TZ)" "$1" >> "$runtime_dir/scheduler.log" 2>/dev/null || true
}

maintenance_clear_deferred_step() {
  rm -f -- "$AGENT_HOME/night/maintenance-deferral-state.json" 2>/dev/null || true
}

maintenance_now_epoch_ms() {
  local realtime="${EPOCHREALTIME/./}"
  if [[ "$realtime" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((realtime / 1000))"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

maintenance_set_optional_deadline() { # section cutoff, original GitHub and Gmail deadlines
  local stop_at="$1" original_gh_deadline="$2" original_gmail_deadline="$3" remaining now_ms deadline gmail_deadline
  remaining=$((stop_at - SECONDS))
  (( remaining >= 0 )) || remaining=0
  now_ms="$(maintenance_now_epoch_ms)"
  deadline=$((now_ms + remaining * 1000))
  if [[ "$original_gh_deadline" =~ ^[0-9]+$ ]] && (( original_gh_deadline < deadline )); then
    deadline="$original_gh_deadline"
  fi
  gmail_deadline="$deadline"
  if [[ "$original_gmail_deadline" =~ ^[0-9]+$ ]] && (( original_gmail_deadline < gmail_deadline )); then
    gmail_deadline="$original_gmail_deadline"
  fi
  export ZF_GH_CALL_DEADLINE_EPOCH_MS="$deadline"
  export ZF_GMAIL_CALL_DEADLINE_EPOCH_MS="$gmail_deadline"
}

maintenance_restore_slice_deadline() { # original GitHub and Gmail deadlines
  if [[ -n "$1" ]]; then
    export ZF_GH_CALL_DEADLINE_EPOCH_MS="$1"
  else
    unset ZF_GH_CALL_DEADLINE_EPOCH_MS
  fi
  if [[ -n "$2" ]]; then
    export ZF_GMAIL_CALL_DEADLINE_EPOCH_MS="$2"
  else
    unset ZF_GMAIL_CALL_DEADLINE_EPOCH_MS
  fi
}

maintenance_defer_optional_step() { # section tick resume file cutoff
  local step="$1" tick="$2" resume_file="$3" stop_at="$4"
  [ "$DRY_RUN" = "1" ] || printf '%s\n' "$step" > "$resume_file" || true
  echo "issue-pipeline: maintenance deferred tick=$tick from=$step elapsed_sec=$SECONDS stop_at=$stop_at" >&2
  [ "$DRY_RUN" = "1" ] || maintenance_record_deferred_step "$step" "$tick"
}

maintenance_run_optional_step() { # bounded maintenance work that can yield to required recovery
  case "$1" in
    checks-blocked-sweep)
      if [ "$DRY_RUN" != "1" ] && ! checks_blocked_sweep; then
        echo "issue-pipeline: checks-blocked owner sweep failed; parked tickets remain for the next tick" >&2
      fi
      ;;
    hold-sweep)
      if [ "$DRY_RUN" != "1" ] && ! hold_sweep; then
        echo "issue-pipeline: hold expiry sweep failed; leaving failed holds untouched for next tick" >&2
      fi
      ;;
    supervisor-hold-sweep)
      if [ "$DRY_RUN" != "1" ] && ! supervisor_hold_sweep; then
        echo "issue-pipeline: supervisor hold sweep failed; ownerless tickets remain for next tick" >&2
      fi
      ;;
    closed-state-sweep)
      if [ "$DRY_RUN" != "1" ] && ! sweep_closed_ready_states; then
        echo "issue-pipeline: closed ready-for-agent sweep failed; retrying next tick" >&2
      fi
      ;;
    hand-completion-events)
      if [ "$DRY_RUN" != "1" ] && ! hand_completion_events_run_once "$REPO_DIR"; then
        echo "issue-pipeline: hand completion recovery deferred until next tick" >&2
      fi
      ;;
    founder-outcome-recovery)
      if reconcile_maintainer_outcomes; then
        flush_maintainer_outcome_digest || true
      else
        echo "issue-pipeline: maintainer outcome recovery failed; digest send deferred" >&2
      fi
      ;;
    needs-info-blocker-roots)
      if ! sweep_blocking_issue_roots; then
        echo "issue-pipeline: blocker-root recovery failed; current roots unavailable" >&2
      fi
      [ "${OPEN_ISSUE_BLOCKER_GRAPH_STATUS:-unknown}" = available ] || return 1 # one failed root is its own retry; an unread graph means no root ran
      maintenance_scheduler_log "blocker-root sweep read ok tick=$IMPLEMENT_TICK_ID"
      ;;
    needs-info-unlabeled)
      if ! sweep_unlabeled_issues; then
        echo "issue-pipeline: unlabeled-issue recovery failed; issues remain queued for the next tick" >&2
      fi
      ;;
    needs-info-loop)
      if ! reconcile_needs_info_issues; then
        echo "issue-pipeline: needs-info recovery failed; answers will be retried next tick" >&2
      fi
      ;;
    main-red-bisect)
      # One bounded step of main-red recovery (#4356): flaky rerun,
      # midpoint probes, culprit attribution, revert PR, ticket reopen.
      # Session writes are pipeline state, so this never runs under DRY_RUN.
      # A valid manual PAUSE still permits red discovery at the tick gate,
      # but stops this recovery step (including the delegated release slice).
      if [ "$DRY_RUN" != "1" ] && ! manual_pause_is_valid; then
        MAIN_RED_RUNS_READ=0
        if ! main_red_bisect_sweep; then
          echo "issue-pipeline: main-red bisect step failed; the red session retries next tick" >&2
          return 1
        fi
        [ "$MAIN_RED_RUNS_READ" != 1 ] || maintenance_scheduler_log "main-red read ok tick=$IMPLEMENT_TICK_ID"
      fi
      ;;
    batch-state)
      # 批次 STATE（#4363）→ critical-path / legacy 标签的周期同步；自带每小时节流。
      if [ "$DRY_RUN" != "1" ] && ! sweep_batch_state; then
        echo "issue-pipeline: batch STATE sweep failed; label sync retries next tick" >&2
      fi
      ;;
  esac
}

run_post_dispatch_maintenance() {
  # The 24-hour timing sample measured needs-info-email at 37s p90 and
  # needs-info-recovery at 16s p90. Split a 55s slot into 37s for bounded mail
  # polling and 18s for reopen recovery, plus the existing 15s hard-timeout reserve.
  local budget="${TICK_UNIT_TIMEOUT_SECONDS:-1200}" timeout_reserve="${MAINTENANCE_STEP_RESERVE_SECONDS:-240}"
  local required_slot="${MAINTENANCE_REQUIRED_SLOT_SECONDS:-55}"
  local reopen_slot="${MAINTENANCE_REOPEN_SLOT_SECONDS:-18}" email_slot email_stop_at max_email_stop_at
  local prefix_stop_at suffix_stop_at step_floor failed_step=""
  local resume_file="$AGENT_HOME/night/maintenance-resume" current_step_file="$AGENT_HOME/night/maintenance-current-step" resume="" step i prefix_start=0 suffix_start=0 deferred_step=""
  local resume_suffix=0 original_gh_deadline="${ZF_GH_CALL_DEADLINE_EPOCH_MS:-}"
  local original_gmail_deadline="${ZF_GMAIL_CALL_DEADLINE_EPOCH_MS:-}" original_email_stop_at="${ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS:-}"
  local -a prefix_steps=(checks-blocked-sweep hold-sweep supervisor-hold-sweep hand-completion-events founder-outcome-recovery)
  local -a suffix_steps=(needs-info-unlabeled needs-info-loop closed-state-sweep main-red-bisect batch-state needs-info-blocker-roots) # roots last: it spends all the time it gets and resumes by its own cursor
  [[ "$required_slot" =~ ^[1-9][0-9]*$ ]] || required_slot=55
  [[ "$reopen_slot" =~ ^[1-9][0-9]*$ ]] || reopen_slot=18
  (( required_slot >= 55 )) || required_slot=55
  (( reopen_slot >= 18 )) || reopen_slot=18
  (( reopen_slot < required_slot )) || { required_slot=55; reopen_slot=18; }
  (( required_slot - reopen_slot >= 37 )) || required_slot=$((reopen_slot + 37))
  email_slot=$((required_slot - reopen_slot))
  prefix_stop_at=$((budget - timeout_reserve - required_slot))
  suffix_stop_at=$((budget - timeout_reserve))
  (( prefix_stop_at >= 0 )) || prefix_stop_at=0
  (( suffix_stop_at >= 0 )) || suffix_stop_at=0
  maintenance_resume_cursor "$resume_file" "$current_step_file" resume prefix_start suffix_start resume_suffix prefix_steps suffix_steps

  # A prior suffix cursor means the prefix has already run; still run the
  # required recovery pair before resuming the expensive suffix work.
  if [ "$resume_suffix" != 1 ]; then
    maintenance_set_optional_deadline "$prefix_stop_at" "$original_gh_deadline" "$original_gmail_deadline"
    for ((i = prefix_start; i < ${#prefix_steps[@]}; i++)); do
      step="${prefix_steps[$i]}"
      if [ "$SECONDS" -ge "$prefix_stop_at" ]; then
        maintenance_defer_optional_step "$step" "$IMPLEMENT_TICK_ID" "$resume_file" "$prefix_stop_at"
        deferred_step="$step"
        break
      fi
      maintenance_step_mark "$step"; profile_mark "$step"
      maintenance_run_optional_step "$step"
    done
  fi

  email_stop_at=$((SECONDS + email_slot))
  max_email_stop_at=$((suffix_stop_at - reopen_slot))
  (( email_stop_at <= max_email_stop_at )) || email_stop_at="$max_email_stop_at"
  (( email_stop_at >= SECONDS )) || email_stop_at="$SECONDS"
  maintenance_set_optional_deadline "$email_stop_at" "$original_gh_deadline" "$original_gmail_deadline"
  export ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS="$email_stop_at"
  profile_mark needs-info-email
  if ! read_needs_info_email_replies; then
    echo "issue-pipeline: needs-info email poll failed; replies will be retried next tick" >&2
  fi
  if [ -n "$original_email_stop_at" ]; then
    export ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS="$original_email_stop_at"
  else
    unset ZF_NEEDS_INFO_EMAIL_STOP_AT_SECONDS
  fi
  # Bound the reopened-issue pass to its reserved remainder. Restore the
  # caller's wider deadlines only after this required work has yielded.
  maintenance_set_optional_deadline "$suffix_stop_at" "$original_gh_deadline" "$original_gmail_deadline"
  unset ZF_GMAIL_CALL_DEADLINE_EPOCH_MS
  profile_mark needs-info-recovery
  if ! sweep_reopened_issues; then
    echo "issue-pipeline: reopened-issue recovery failed; issues remain queued for the next tick" >&2
  fi
  maintenance_restore_slice_deadline "$original_gh_deadline" "$original_gmail_deadline"

  if [ -z "$deferred_step" ]; then
    maintenance_set_optional_deadline "$suffix_stop_at" "$original_gh_deadline" "$original_gmail_deadline"
    for ((i = suffix_start; i < ${#suffix_steps[@]}; i++)); do
      step="${suffix_steps[$i]}"
      # A step needs time for one bounded read, or it only meets the deadline and no cursor is left (blocker roots: 12s read, 15s left, 20 hours).
      step_floor=15
      [ "$step" != needs-info-blocker-roots ] || step_floor=40
      if [ "$((SECONDS + step_floor))" -ge "$suffix_stop_at" ]; then
        maintenance_defer_optional_step "$step" "$IMPLEMENT_TICK_ID" "$resume_file" "$suffix_stop_at"
        deferred_step="$step"
        break
      fi
      maintenance_step_mark "$step"; profile_mark "$step"
      if ! maintenance_run_optional_step "$step"; then
        # Rings without the cursor: a resume skips the prefix, so a lasting failure must not hold it.
        failed_step="$step"
        [ "$DRY_RUN" = "1" ] || maintenance_record_deferred_step "$step" "$IMPLEMENT_TICK_ID"
      fi
    done
    maintenance_restore_slice_deadline "$original_gh_deadline" "$original_gmail_deadline"
  fi
  if [ -z "$deferred_step" ] && [ "$DRY_RUN" != "1" ]; then
    rm -f -- "$resume_file" "$current_step_file"
    [ -n "$failed_step" ] || maintenance_clear_deferred_step
  fi
}
