
main_red_post_land_base_from_run() {
  local run="$1" sha title request base parent
  sha="$(jq -r '.head_sha // empty' <<< "$run")" || return 1
  title="$(jq -r '.display_title // empty' <<< "$run")" || return 1
  if [[ "$title" =~ ^Pipeline\ suites\ post-land\ ([0-9a-f]{40})\ ([0-9a-f]{40})$ ]] \
      && [[ "${BASH_REMATCH[1]}" == "$sha" ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$title" =~ ^Pipeline\ suites\ post-land\ ([0-9a-f]{40})\ legacy$ ]] \
      && [[ "${BASH_REMATCH[1]}" == "$sha" ]]; then
    request="$(main_red_direct_landing_request "$sha")" || return 1
    base="$(jq -r '.base_sha // empty' "$request")" || return 1
    parent="$(git -C "$REPO_DIR" rev-parse --verify "${sha}^")" || return 1
    [[ "$base" == "$parent" ]] || return 1
    printf '%s\n' "$base"
    return 0
  fi
  return 1
}


main_red_focused_suite_step_failed() {
  local run_id="$1" attempt="$2" jobs
  [[ "$run_id" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]*$ ]] || return 1
  jobs="$(gh run view "$run_id" --repo "$REPO" --attempt "$attempt" --json jobs -q '.jobs' 2>/dev/null)" || return 1
  jq -e 'type == "array" and any(.[]; .name == "Pipeline suites focused"
    and any(.steps[]?; .name == "Run focused pipeline suites" and .conclusion == "failure"))' \
    <<< "$jobs" >/dev/null 2>&1
}


main_red_step_session() { # sha run_json run_history ; advances one session by one step
  local red_sha="$1" run="$2"
  local red_run_id session status green_sha red_created history lo hi count mid verdict culprit issue
  history="$3"
  local subject subject_json attempts age issue_pr pr_state subject_issue direct_request revert_sha direct_request_status focused_base focused_head direct_base direct_landed focused_update baseline_verdict baseline_attempts baseline_age red_run_attempt
  local workflow
  workflow="$(jq -r '.red_workflow // "ci.yml"' 2>/dev/null <<< "$run")"
  case "$workflow" in ci.yml|pipeline-suites.yml) ;; *) return 0 ;; esac
  red_run_id="$(jq -r '.id // empty' <<< "$run")"
  session="$(main_red_session_read "$red_sha" 2>/dev/null || true)"
  if [ -z "$session" ]; then
    # First red at this SHA: rerun the failed jobs once. A rerun already in
    # flight removes the run from the completed list, so the next completed
    # sighting of this SHA is the rerun's own verdict.
    if ! guarded_write gh run rerun "$red_run_id" --failed --repo "$REPO"; then
      echo "main-red-bisect: same-SHA rerun request failed for run $red_run_id; retrying next tick" >&2
      return 0
    fi
    red_created="$(jq -r '.created_at // empty' <<< "$run")"
    focused_base="$(main_red_post_land_base_from_run "$run" 2>/dev/null || true)"
    focused_update=""
    if [[ "$workflow" == pipeline-suites.yml && "$focused_base" =~ ^[0-9a-f]{40}$ ]]; then
      focused_update=" | .focused_base_sha = \"$focused_base\" | .focused_head_sha = \"$red_sha\""
      green_sha=""
    else
      green_sha="$(jq -r --arg red_created "$red_created" --arg workflow "$workflow" '
        [.workflow_runs[]?
          | select(.red_workflow == $workflow and .status == "completed" and .conclusion == "success"
            and .created_at <= $red_created
            and ($workflow != "pipeline-suites.yml"
              or ((((.display_title // "") | startswith("Pipeline suites post-land ")) | not))))]
        | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
        | last | .head_sha // empty' <<< "$history" 2>/dev/null)" || green_sha=""
    fi
    if ! main_red_session_write "$red_sha" rerun-requested \
      ".red_run_id = \"${red_run_id}\" | .green_sha = \"${green_sha:-}\" | .red_workflow = \"$workflow\"$focused_update"; then
      echo "main-red-bisect: could not open a session for $red_sha" >&2
      return 0
    fi
    main_red_log "red ${red_sha:0:12} run=$red_run_id: same-SHA rerun requested (flaky check)"
    return 0
  fi
  status="$(jq -r '.status' <<< "$session")"
  case "$status" in
    rerun-requested)
      # Reached only while the latest completed verdict is still this red:
      # the rerun finished red, so the window is deterministic. (A rerun
      # that goes green leaves the latest verdict green and is closed as
      # flaky by the sweep's own pass below, never here.) A missing or
      # non-ancestor baseline cannot anchor a bisect.
      green_sha="$(jq -r '.green_sha // empty' <<< "$session")"
      focused_base="$(jq -r '.focused_base_sha // empty' <<< "$session")"
      focused_head="$(jq -r '.focused_head_sha // empty' <<< "$session")"
      if [[ "$workflow" == pipeline-suites.yml && ! "$focused_head" =~ ^[0-9a-f]{40}$ ]]; then
        focused_head="__full__"
      fi
      if [[ "$workflow" == pipeline-suites.yml && "$focused_base" =~ ^[0-9a-f]{40}$ \
          && "$focused_head" =~ ^[0-9a-f]{40}$ ]]; then
        baseline_verdict="$(main_red_probe_verdict "$focused_base" "$workflow" "$focused_head")" || return 0
        case "$baseline_verdict" in
          success)
            green_sha="$focused_base"
            main_red_session_write "$red_sha" bisecting \
              ".green_sha = \"$focused_base\" | .lo = \"$focused_base\" | .hi = \"$red_sha\" | .probe = null" || return 0
            main_red_log "red ${red_sha:0:12}: mapped suite is green at pre-land ${focused_base:0:12}; bisecting same suite set"
            return 0
            ;;
          failure)
            main_red_session_write "$red_sha" unattributed || return 0
            main_red_supervisor_event "$red_sha" "status=unattributed reason=preland-mapped-suites-red base=${focused_base:0:12} run=$red_run_id"
            return 0
            ;;
          pending)
            return 0
            ;;
          none)
            baseline_attempts="$(jq -r '.baseline_probe_attempts // 0' <<< "$session")"
            baseline_age=$(( $(date +%s) - $(stat -c %Y "$(main_red_session_file "$red_sha")" 2>/dev/null || echo 0) ))
            if [[ ! "$baseline_attempts" =~ ^[0-9]+$ ]] || [ "$baseline_attempts" -ge "$MAIN_RED_PROBE_DISPATCH_ATTEMPTS" ]; then
              main_red_session_write "$red_sha" unattributed || return 0
              main_red_supervisor_event "$red_sha" "status=unattributed reason=preland-baseline-dispatch-exhausted base=${focused_base:0:12}"
            elif [ "$baseline_attempts" -eq 0 ] || [ "$baseline_age" -ge "$MAIN_RED_PROBE_RETRY_DELAY_SECONDS" ]; then
              main_red_session_write "$red_sha" rerun-requested \
                ".baseline_probe_attempts = (($baseline_attempts // 0) + 1)" || return 0
              if ! main_red_dispatch_probe "$focused_base" "$red_sha" "$workflow" "$focused_base" "$focused_head"; then
                echo "main-red-bisect: pre-land mapped-suite baseline dispatch failed for ${focused_base:0:12} (attempt $((baseline_attempts + 1))/$MAIN_RED_PROBE_DISPATCH_ATTEMPTS)" >&2
              fi
            fi
            return 0
            ;;
        esac
      fi
      if ! [[ "$green_sha" =~ ^[0-9a-f]{40}$ ]] \
        || ! git -C "$REPO_DIR" merge-base --is-ancestor "$green_sha" "$red_sha" 2>/dev/null; then
        main_red_session_write "$red_sha" unattributed || return 0
        main_red_supervisor_event "$red_sha" "status=unattributed reason=no-green-baseline run=$red_run_id"
        return 0
      fi
      if [[ "$green_sha" == "$red_sha" ]]; then
        main_red_session_write "$red_sha" unattributed || return 0
        main_red_supervisor_event "$red_sha" "status=unattributed reason=green-and-red-verdicts-share-sha run=$red_run_id"
        return 0
      fi
      main_red_session_write "$red_sha" bisecting \
        ".lo = \"$green_sha\" | .hi = \"$red_sha\" | .probe = null" || return 0
      main_red_log "red ${red_sha:0:12}: rerun stayed red; bisecting ${green_sha:0:12}..${red_sha:0:12}"
      return 0
      ;;
    bisecting)
      green_sha="$(jq -r '.green_sha // empty' <<< "$session")"
      workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$session")"
      focused_base="$(jq -r '.focused_base_sha // empty' <<< "$session")"
      focused_head="$(jq -r '.focused_head_sha // empty' <<< "$session")"
      lo="$(jq -r '.lo // .green_sha // empty' <<< "$session")"
      hi="$(jq -r '.hi // .red_sha // empty' <<< "$session")"
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "$green_sha" "$red_sha" 2>/dev/null \
        || ! git -C "$REPO_DIR" rev-parse -q --verify "${lo}^{commit}" >/dev/null 2>&1 \
        || ! git -C "$REPO_DIR" rev-parse -q --verify "${hi}^{commit}" >/dev/null 2>&1; then
        return 0
      fi
      count="$(git -C "$REPO_DIR" rev-list --count "$lo..$hi" 2>/dev/null)" || return 0
      if [ "$count" -le 1 ]; then
        main_red_session_write "$red_sha" culprit-found ".culprit = \"${hi}\" | del(.probe)"
        main_red_log "red ${red_sha:0:12}: bisect named culprit ${hi:0:12}"
        return 0
      fi
      mid="$(git -C "$REPO_DIR" rev-list --reverse "$lo..$hi" 2>/dev/null | sed -n "$(( (count + 1) / 2 ))p")"
      [[ "$mid" =~ ^[0-9a-f]{40}$ ]] || return 0
      if [ "$(jq -r '.probe.sha // empty' <<< "$session")" != "$mid" ]; then
        verdict="$(main_red_probe_verdict "$mid" "$workflow" "$focused_head")" || return 0
        case "$verdict" in
          success)
            main_red_session_write "$red_sha" bisecting ".lo = \"$mid\" | .probe = null" || return 0
            main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} green (reused verdict); window shrinks"
            return 0
            ;;
          failure)
            main_red_session_write "$red_sha" bisecting ".hi = \"$mid\" | .probe = null" || return 0
            main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} red (reused verdict); window shrinks"
            return 0
            ;;
          pending)
            main_red_session_write "$red_sha" bisecting ".probe = {sha:\"$mid\",attempts:0}" || return 0
            return 0
            ;;
          none)
            attempts="$(jq -r '.probe.attempts // 0' <<< "$session")"
            main_red_session_write "$red_sha" bisecting ".probe = {sha:\"$mid\",attempts:0}" || return 0
            ;;
        esac
        session="$(main_red_session_read "$red_sha" 2>/dev/null || true)"
      fi
      # A probe is either newly recorded or already in flight for this mid.
      attempts="$(jq -r '.probe.attempts // 0' <<< "$session")"
      verdict="$(main_red_probe_verdict "$mid" "$workflow" "$focused_head")" || return 0
      case "$verdict" in
        success)
          main_red_session_write "$red_sha" bisecting ".lo = \"$mid\" | .probe = null" || return 0
          main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} green; window shrinks"
          ;;
        failure)
          main_red_session_write "$red_sha" bisecting ".hi = \"$mid\" | .probe = null" || return 0
          main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} red; window shrinks"
          ;;
        pending)
          ;;
        none)
          age=$(( $(date +%s) - $(stat -c %Y "$(main_red_session_file "$red_sha")" 2>/dev/null || echo 0) ))
          if [ "$attempts" -ge "$MAIN_RED_PROBE_DISPATCH_ATTEMPTS" ]; then
            main_red_session_write "$red_sha" unattributed || return 0
            main_red_supervisor_event "$red_sha" "status=unattributed reason=probe-dispatch-exhausted mid=${mid:0:12}"
          elif [ "$attempts" -eq 0 ] || [ "$age" -ge "$MAIN_RED_PROBE_RETRY_DELAY_SECONDS" ]; then
            main_red_session_write "$red_sha" bisecting ".probe.attempts = (($attempts // 0) + 1)" || return 0
            if ! main_red_dispatch_probe "$mid" "$red_sha" "$workflow" "$focused_base" "$focused_head"; then
              echo "main-red-bisect: midpoint dispatch failed for $mid (attempt $((attempts + 1))/$MAIN_RED_PROBE_DISPATCH_ATTEMPTS)" >&2
            fi
          fi
          ;;
      esac
      ;;
    culprit-found)
      culprit="$(jq -r '.culprit // empty' <<< "$session")"
      [[ "$culprit" =~ ^[0-9a-f]{40}$ ]] || return 0
      if git -C "$REPO_DIR" log origin/main --format=%H --grep="This reverts commit ${culprit}." 2>/dev/null | grep -q .; then
        main_red_session_write "$red_sha" reverted
        main_red_log "red ${red_sha:0:12}: culprit ${culprit:0:12} already reverted on main"
        return 0
      fi
      subject="$(git -C "$REPO_DIR" log -1 --format=%s "$culprit" 2>/dev/null)" || return 0
      subject_issue=""
      [[ "$subject" =~ ^fix\(#([0-9]+)\): ]] && subject_issue="${BASH_REMATCH[1]}"
      direct_request=""
      direct_request_status=1
      if [[ "$workflow" == pipeline-suites.yml ]]; then
        if direct_request="$(main_red_direct_landing_request "$culprit" 2>/dev/null)"; then
          direct_request_status=0
        else
          direct_request_status=$?
        fi
      fi
      if [[ "$direct_request_status" -eq 2 ]]; then
        main_red_session_write "$red_sha" unattributed
        main_red_supervisor_event "$red_sha" "status=unattributed reason=direct-landing-range-ambiguous culprit=${culprit:0:12}"
        return 0
      elif [[ -n "$direct_request" ]]; then
        issue="$(main_red_direct_landing_issue "$direct_request" 2>/dev/null || true)"
        if [[ ! "$issue" =~ ^[1-9][0-9]*$ || ( -n "$subject_issue" && "$subject_issue" != "$issue" ) ]]; then
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" "status=unattributed reason=direct-landing-owner-ambiguous culprit=${culprit:0:12} request=$(basename "$direct_request")"
          return 0
        fi
        focused_base="$(main_red_post_land_base_from_run "$run" 2>/dev/null || true)"
        direct_base="$(jq -r '.base_sha // empty' "$direct_request")"
        direct_landed="$(jq -r '.landed_sha // empty' "$direct_request")"
        if [[ ! "$focused_base" =~ ^[0-9a-f]{40}$ || "$focused_base" != "$direct_base" \
            || "$direct_landed" != "$red_sha" ]]; then
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" \
            "status=unattributed reason=direct-main-revert-requires-matching-focused-range culprit=${culprit:0:12} request=$(basename "$direct_request")"
          return 0
        fi
        red_run_attempt="$(jq -r '.run_attempt // empty' <<< "$run")"
        if ! main_red_focused_suite_step_failed "$red_run_id" "$red_run_attempt"; then
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" \
            "status=unattributed reason=focused-suite-test-step-failure-unconfirmed culprit=${culprit:0:12} run=$red_run_id attempt=$red_run_attempt"
          return 0
        fi
      else
        if [[ ! "$subject_issue" =~ ^[1-9][0-9]*$ ]]; then
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" "status=unattributed reason=no-owner-issue culprit=${culprit:0:12} subject=\"$subject\""
          return 0
        fi
        issue="$subject_issue"
      fi
      subject_json="$(jq -cn --arg value "$subject" '$value')" || return 0
      attempts="$(jq -r '.revert_attempts // 0' <<< "$session")"
      if [ "$attempts" -ge "$MAIN_RED_REVERT_ATTEMPTS" ]; then
        main_red_session_write "$red_sha" unattributed
        main_red_supervisor_event "$red_sha" "status=unattributed reason=revert-pr-failed culprit=${culprit:0:12} issue=$issue"
        return 0
      fi
      main_red_session_write "$red_sha" culprit-found '.revert_attempts = ((.revert_attempts // 0) + 1)'
      if [[ -n "$direct_request" ]]; then
        if ! revert_sha="$(main_red_open_direct_revert "$issue" "$culprit" "$red_sha" "$red_run_id")" \
            || ! [[ "$revert_sha" =~ ^[0-9a-f]{40}$ ]]; then
          echo "main-red-bisect: direct-main revert for ${culprit:0:12} could not be completed (attempt $((attempts + 1))/$MAIN_RED_REVERT_ATTEMPTS)" >&2
          return 0
        fi
        main_red_session_write "$red_sha" revert-open \
          ".issue = $issue | .revert_sha = \"$revert_sha\" | .culprit_subject = $subject_json" || return 0
        if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "direct-main commit $revert_sha"; then
          main_red_session_write "$red_sha" reverted '.ticket_reopened = true' || return 0
          main_red_supervisor_event "$red_sha" \
            "status=reverted workflow=$workflow culprit=${culprit:0:12} issue=$issue revert=${revert_sha:0:12} run=$red_run_id"
          main_red_log "red ${red_sha:0:12}: direct-main revert ${revert_sha:0:12} landed for culprit ${culprit:0:12}; ticket #$issue reopened"
        else
          echo "main-red-bisect: direct revert landed as ${revert_sha:0:12}, but ticket #$issue handoff will retry next tick" >&2
        fi
        return 0
      fi
      if ! issue_pr="$(main_red_open_revert_pr "$issue" "$culprit" "$red_sha" "$red_run_id")" \
        || ! [[ "$issue_pr" =~ ^[0-9]+$ ]]; then
        echo "main-red-bisect: revert PR for ${culprit:0:12} could not be opened (attempt $((attempts + 1))/$MAIN_RED_REVERT_ATTEMPTS)" >&2
        return 0
      fi
      main_red_session_write "$red_sha" revert-open ".issue = $issue | .revert_pr = $issue_pr | .culprit_subject = $subject_json"
      if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "PR #$issue_pr"; then
        main_red_session_write "$red_sha" revert-open '.ticket_reopened = true'
      else
        echo "main-red-bisect: ticket #$issue reopen/comment failed; retrying next tick" >&2
      fi
      main_red_log "red ${red_sha:0:12}: culprit ${culprit:0:12} (issue #$issue) -> revert PR #$issue_pr; ticket reopened"
      ;;
    revert-open)
      issue="$(jq -r '.issue // empty' <<< "$session")"
      culprit="$(jq -r '.culprit // empty' <<< "$session")"
      revert_sha="$(jq -r '.revert_sha // empty' <<< "$session")"
      if [[ "$revert_sha" =~ ^[0-9a-f]{40}$ ]]; then
        git_fetch_bounded "$REPO_DIR" main >/dev/null 2>&1 || return 0
        if ! git -C "$REPO_DIR" merge-base --is-ancestor "$revert_sha" origin/main 2>/dev/null \
            || ! git -C "$REPO_DIR" show -s --format=%B "$revert_sha" 2>/dev/null \
              | grep -Fxq "This reverts commit $culprit."; then
          return 0
        fi
        if [ "$(jq -r '.ticket_reopened // false' <<< "$session")" != true ] \
            && [[ "$issue" =~ ^[0-9]+$ && "$culprit" =~ ^[0-9a-f]{40}$ ]]; then
          if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "direct-main commit $revert_sha"; then
            main_red_session_write "$red_sha" reverted '.ticket_reopened = true' || return 0
            main_red_supervisor_event "$red_sha" \
              "status=reverted workflow=$workflow culprit=${culprit:0:12} issue=$issue revert=${revert_sha:0:12} run=$red_run_id"
            main_red_log "red ${red_sha:0:12}: direct-main revert ${revert_sha:0:12} confirmed; ticket #$issue reopened"
          fi
        fi
        return 0
      fi
      if [ "$(jq -r '.ticket_reopened // false' <<< "$session")" != true ] \
        && [[ "$issue" =~ ^[0-9]+$ && "$culprit" =~ ^[0-9a-f]{40}$ ]]; then
        if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "PR #$(jq -r '.revert_pr // empty' <<< "$session")"; then
          main_red_session_write "$red_sha" revert-open '.ticket_reopened = true'
        fi
      fi
      issue_pr="$(jq -r '.revert_pr // empty' <<< "$session")"
      [[ "$issue_pr" =~ ^[0-9]+$ ]] || return 0
      pr_state="$(gh pr view "$issue_pr" --repo "$REPO" --json state -q .state 2>/dev/null)" || return 0
      case "$pr_state" in
        MERGED)
          main_red_session_write "$red_sha" reverted
          main_red_log "red ${red_sha:0:12}: revert PR #$issue_pr merged; existing Postsubmit merge gate remains authoritative"
          ;;
        CLOSED)
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" "status=unattributed reason=revert-pr-closed-unmerged pr=$issue_pr"
          ;;
      esac
      ;;
    reverted|flaky|unattributed)
      # Terminal records; a later green Postsubmit clears the existing
      # ci.yml merge gate.
      ;;
  esac
}


# Read both main validation workflows for recovery. A direct-main [skip ci]
# commit can run Pipeline suites without creating a newer ci.yml/Postsubmit run.
main_red_completed_runs() {
  local postsubmit suites
  postsubmit="$(ci_main_completed_push_runs ci.yml)" || return 1
  suites="$(ci_main_completed_push_runs pipeline-suites.yml)" || return 1
  jq -cn --argjson postsubmit "$postsubmit" --argjson suites "$suites" '
    {workflow_runs:
      ([$postsubmit.workflow_runs[]? | . + {red_workflow:"ci.yml"}]
       + [$suites.workflow_runs[]? | . + {red_workflow:"pipeline-suites.yml"}])}'
}


main_red_latest_failed_run() {
  jq -ce '
    [.workflow_runs[]?
      | select(.status == "completed"
        and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped")]
    | sort_by(.red_workflow)
    | group_by(.red_workflow)
    | map(sort_by([.created_at // "", .id // 0, .run_attempt // 0]) | last)
    | map(select(.conclusion == "failure"))
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
    | last // empty' <<< "$1" 2>/dev/null
}


# While manually paused, discover a main red and wake the supervisor without
# creating a session or starting the rerun/bisect/revert state machine.
main_red_paused_discovery() {
  local runs run sha workflow run_id
  runs="$(main_red_completed_runs)" || return 1
  run="$(main_red_latest_failed_run "$runs")" || return 0
  sha="$(jq -r '.head_sha // empty' <<< "$run")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$run")"
  run_id="$(jq -r '.id // empty' <<< "$run")"
  supervisor_inbox_append_once "main-red-paused:$workflow:$sha" \
    "main-red-bisect red=${sha:0:12} status=paused workflow=$workflow run=$run_id"
}


# The tick's maintenance entry point: if the latest completed main validation
# run is red, advance that red's session by one bounded step;
# then close any rerun-requested session whose same-SHA rerun went green
# (that red was flaky and the latest verdict is green again, so the step
# path above can no longer see it).
main_red_bisect_sweep() {
  local runs run verdict sha session_file session red_sha rerun_verdict workflow focused_head recovery_status
  if [ "${MAIN_CI_RED_RECONCILIATION_DONE:-0}" = 1 ]; then
    [ "${MAIN_CI_RED_RECOVERY_HELD:-0}" != 1 ] || return 0
  elif ZF_REPO_DIR="$REPO_DIR" bash "${ZF_ENGINE_DIR:-$REPO_DIR/engine}/night/main-ci-recovery.sh" reconcile-red; then
    :
  else
    recovery_status=$?
    case "$recovery_status" in
      10|11) return 0 ;;
      *)
        echo "main-red-bisect: main-CI quarantine reconciliation held (exit $recovery_status); retrying next tick" >&2
        return 0
        ;;
    esac
  fi
  if ! runs="$(main_red_completed_runs)"; then
    echo "main-red-bisect: could not read the completed main verdict list" >&2
    return 0
  fi
  if run="$(main_red_latest_failed_run "$runs")" && [ -n "$run" ]; then
    verdict="$(jq -r '.conclusion // empty' 2>/dev/null <<< "$run")"
    sha="$(jq -r '.head_sha // empty' 2>/dev/null <<< "$run")"
    if [ "$verdict" = failure ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      # Sessions compare commits; the red SHA must be present locally.
      git_fetch_bounded "$REPO_DIR" main >/dev/null 2>&1 || true
      if ! git -C "$REPO_DIR" rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1; then
        echo "main-red-bisect: red SHA $sha is not present after fetch; retrying next tick" >&2
        return 0
      fi
      main_red_step_session "$sha" "$run" "$runs"
    fi
  fi
  [ -d "$MAIN_RED_DIR" ] || return 0
  while IFS= read -r session_file; do
    [ -n "$session_file" ] || continue
    session="$(main_red_session_read_for_file "$session_file" 2>/dev/null || true)"
    [ "$(jq -r '.status // empty' <<< "$session" 2>/dev/null)" = rerun-requested ] || continue
    red_sha="$(jq -r '.red_sha // empty' <<< "$session")"
    [[ "$red_sha" =~ ^[0-9a-f]{40}$ ]] || continue
    workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$session")"
    focused_head="$(jq -r '.focused_head_sha // empty' <<< "$session")"
    if [[ "$workflow" == pipeline-suites.yml && ! "$focused_head" =~ ^[0-9a-f]{40}$ ]]; then
      focused_head="__full__"
    elif [[ "$workflow" == pipeline-suites.yml && "$focused_head" == "$red_sha" ]]; then
      focused_head="__rerun__"
    fi
    rerun_verdict="$(main_red_probe_verdict "$red_sha" "$workflow" "$focused_head")" || continue
    if [ "$rerun_verdict" = success ]; then
      main_red_session_write "$red_sha" flaky
      main_red_log "red ${red_sha:0:12}: same-SHA rerun went green; recorded flaky, no revert"
    fi
  done < <(printf '%s\n' "$MAIN_RED_DIR"/*.json)
  return 0
}
