
# add_issue_blocked_by <issue> <blocker> -- create the native GitHub
# blocked-by edge $issue <- $blocker through the guarded write path. Moved
# here from run-implement.sh's implement_add_blocked_by (01dca99f4) so the
# hand-agent exit path issues the exact same write. Idempotent: reads the
# blocker's database id, skips when the edge already exists, POSTs once
# otherwise, so a retry after a transient failure never duplicates the edge.
add_issue_blocked_by() {
  local issue="$1" blocker="$2" issue_json blocker_id dependencies endpoint
  endpoint="repos/$REPO/issues/$issue/dependencies/blocked_by"
  issue_json="$(gh api "repos/$REPO/issues/$blocker")" || return 1
  blocker_id="$(jq -er '.id | numbers | select(. > 0 and . == floor)' <<< "$issue_json")" || return 1
  dependencies="$(gh api "$endpoint")" || return 1
  jq -e 'type == "array"' <<< "$dependencies" >/dev/null 2>&1 || return 1
  if jq -e --argjson id "$blocker_id" --argjson number "$blocker" \
    'any(.[]; .id == $id or .number == $number)' <<< "$dependencies" >/dev/null 2>&1; then
    return 0
  fi
  guarded_write gh api --method POST "$endpoint" -F "issue_id=$blocker_id"
}


# hand_report_blocked_on_dependency <name> <report-file> <owned-issues>
# A hand agent tied to issue N (run-recut.sh's guarded flow queues them as
# hand-<N>) ends a blocked run by writing `STATUS: BLOCKED-ON issue M` as the
# report's first line and exiting. Nothing repo-side acted on that report
# (2026-10-07: hand-1914 ended BLOCKED-ON issue 1131; the issue stayed on-hold
# until the supervisor added the native dependency by hand and ran
# state_requeue 1914 release-hold). worktree-lifecycle.sh watch calls this at
# agent exit, before dropping the roster row. Open blocker: add the native
# blocked-by edge, post one comment naming the blocker and the report's
# reason line, then state_requeue N release-hold so the open-blocker
# gate holds N exactly until M merges. Closed or unreadable blocker: leave N
# held and route one line to the supervisor inbox (same terminal-blocker rule
# as implement, 01dca99f4). Never fails the caller: every branch returns 0.
hand_report_blocked_on_dependency() {
  local name="$1" report="$2" owned="${3:-}" header dependency blocker issue
  local state_json blocker_issue blocker_state reason_line marker_filter
  [ -f "$report" ] || return 0
  case "$name$owned" in *$'\t'*|*$'\n'*) return 0 ;; esac
  header="$(sed -n '1p' "$report" 2>/dev/null || true)"
  dependency=""
  case "$header" in
    'STATUS: BLOCKED-ON issue '*) dependency="${header#STATUS: BLOCKED-ON issue }" ;;
    'STATUS: BLOCKED-ON #'*) dependency="${header#STATUS: BLOCKED-ON #}" ;;
    *) return 0 ;;
  esac
  blocker="$(awk '{print $1}' <<< "$dependency")"
  [[ "$blocker" =~ ^[1-9][0-9]*$ ]] || return 0
  issue=""
  if [[ "$owned" =~ ^([1-9][0-9]*)([[:space:]]|$) ]]; then issue="${BASH_REMATCH[1]}"; fi
  if [ -z "$issue" ] && [[ "$name" =~ ^hand-([1-9][0-9]*)$ ]]; then issue="${BASH_REMATCH[1]}"; fi
  [ -n "$issue" ] || return 0
  [ "$issue" != "$blocker" ] || return 0
  state_json="$(state_read "$issue" 2>/dev/null || true)"
  if [ "$(jq -r '.hand_blocked_on.blocker // ""' <<< "$state_json" 2>/dev/null)" = "$blocker" ]; then
    return 0
  fi
  reason_line="$(awk 'NR > 1 && NF { print; exit }' "$report" 2>/dev/null | tr '\r\t' '  ' | cut -c1-200)"
  if ! blocker_issue="$(gh issue view "$blocker" --repo "$REPO" --json state,stateReason,closedAt 2>/dev/null)"; then
    supervisor_inbox_append_once \
      "hand-blocked-on-terminal issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-terminal issue=#$issue agent=$name blocker=#$blocker unreadable: #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route unreadable blocker #$blocker to supervisor inbox" >&2
    return 0
  fi
  blocker_state="$(jq -r '.state // empty | ascii_downcase' <<< "$blocker_issue" 2>/dev/null)" || blocker_state=""
  if [ "$blocker_state" != open ]; then
    supervisor_inbox_append_once \
      "hand-blocked-on-terminal issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-terminal issue=#$issue agent=$name blocker=#$blocker state=${blocker_state:-unknown}: #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route closed blocker #$blocker to supervisor inbox" >&2
    return 0
  fi
  if ! add_issue_blocked_by "$issue" "$blocker"; then
    supervisor_inbox_append_once \
      "hand-blocked-on-write-failed issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-write-failed issue=#$issue agent=$name blocker=#$blocker: native dependency write failed; #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route failed dependency write #$blocker to supervisor inbox" >&2
    return 0
  fi
  # Record the marker before comment/requeue so a re-run for the same blocker
  # can never duplicate the comment.
  marker_filter=".hand_blocked_on = {blocker: $blocker, agent: $(jq -Rn --arg agent "$name" '$agent'), recorded_at: (now | todate)}"
  state_merge "$issue" "$marker_filter" >/dev/null 2>&1 || true
  guarded_issue_comment "$issue" "$BOT_DISCLAIMER
Hand agent $name ended \`STATUS: BLOCKED-ON issue #$blocker\` with no landed diff.
${reason_line:-(no reason line in the report)}
Native blocked-by dependency #$blocker added; #$issue re-enters the queue once #$blocker merges." \
    || echo "hand-blocked-on: could not post BLOCKED-ON comment on #$issue" >&2
  if ! state_requeue "$issue" release-hold; then
    supervisor_inbox_append_once \
      "hand-blocked-on-requeue-failed issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-requeue-failed issue=#$issue agent=$name blocker=#$blocker: dependency and comment recorded, but release-hold requeue failed" \
      || echo "hand-blocked-on: could not route failed requeue of #$issue to supervisor inbox" >&2
    return 0
  fi
  echo "hand-blocked-on: #$issue recorded as blocked by #$blocker (agent $name); requeued with release-hold" >&2
  return 0
}


# hand_report_followup_dependencies <name> <report> <owned-issues> <pid>
#   <role> <worktree> <brief> <log> <attempt> <start-ticks> <owned-nodes>
# A final FOLLOWUP list can name other issues or PRs. Link each open issue
# blocker to every open issue owned by the hand. Keep a blocked owner record
# until every listed dependency closes so fastlane sees a real owner and the
# same hand resumes with its retained worktree.
hand_report_followup_dependencies() {
  local name="$1" report="$2" owned="${3:-}" pid="${4:-}" role="${5:-}"
  local worktree="${6:-}" brief="${7:-}" log="${8:-}" attempt="${9:-0}"
  local start_ticks="${10:-}" owned_nodes="${11:-}" header listed_ids owned_ids issue_json issue_state
  local pr_json pr_state refs ref_issue_json ref_state issue blocker primary dependency token
  local -a owned_issues=() open_owned_issues=() listed=() issue_blockers=() pr_blockers=()
  local -A owned_set=() issue_seen=() pr_seen=()
  [ -f "$report" ] || return 0
  header="$(sed -n '1p' "$report" 2>/dev/null || true)"
  [[ "$header" =~ ^STATUS:\ FOLLOWUP\(([1-9][0-9]*(,[[:space:]]*[1-9][0-9]*)*)\)$ ]] || return 0
  listed_ids="${BASH_REMATCH[1]}"
  owned_ids="$(agent_owned_issue_ids "$name" "$owned" 2>/dev/null)" || return 0
  [ -n "$owned_ids" ] || return 0
  read -r -a owned_issues <<< "$owned_ids"
  primary="${owned_issues[0]}"
  for issue in "${owned_issues[@]}"; do owned_set["$issue"]=1; done

  # Only open owned issues need new dependency edges or requeueing.
  for issue in "${owned_issues[@]}"; do
    issue_json="$(gh api "repos/$REPO/issues/$issue" 2>/dev/null)" || {
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$issue" \
        "hand-followup-dependency-read issue=#$issue agent=$name: could not read owned issue state; left its hold unchanged" || true
      return 0
    }
    if ! jq -e --argjson n "$issue" 'type == "object" and .number == $n and ((.state // "" | ascii_downcase) | IN("open", "closed"))' \
      <<< "$issue_json" >/dev/null 2>&1; then
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$issue" \
        "hand-followup-dependency-read issue=#$issue agent=$name: owned issue state response invalid; left its hold unchanged" || true
      return 0
    fi
    issue_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
    [ "$issue_state" = open ] && open_owned_issues+=("$issue")
  done
  ((${#open_owned_issues[@]} > 0)) || return 0

  listed="${listed_ids//,/ }"
  read -r -a listed <<< "$listed"
  for blocker in "${listed[@]}"; do
    [ -z "${owned_set[$blocker]:-}" ] || continue
    issue_json="$(gh api "repos/$REPO/issues/$blocker" 2>/dev/null)" || {
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$primary blocker=#$blocker" \
        "hand-followup-dependency-read issue=#$primary agent=$name blocker=#$blocker: could not classify FOLLOWUP dependency; left its hold unchanged" || true
      return 0
    }
    if ! jq -e --argjson n "$blocker" 'type == "object" and .number == $n
      and ((.state // "" | ascii_downcase) | IN("open", "closed"))
      and (if has("pull_request") then (.pull_request | type == "object") else true end)' \
      <<< "$issue_json" >/dev/null 2>&1; then
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$primary blocker=#$blocker" \
        "hand-followup-dependency-read issue=#$primary agent=$name blocker=#$blocker: invalid FOLLOWUP dependency response; left its hold unchanged" || true
      return 0
    fi
    issue_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
    if jq -e 'has("pull_request") and (.pull_request | type == "object")' <<< "$issue_json" >/dev/null 2>&1; then
      pr_json="$(gh pr view "$blocker" --repo "$REPO" --json state,closingIssuesReferences 2>/dev/null)" || {
        supervisor_inbox_append_once "hand-followup-pr-read issue=#$primary pr=#$blocker" \
          "hand-followup-pr-read issue=#$primary agent=$name pr=#$blocker: could not read closing issues; left its hold unchanged" || true
        return 0
      }
      if ! jq -e 'type == "object" and ((.state // "" | ascii_downcase) | IN("open", "closed"))
        and ((.closingIssuesReferences // []) | type == "array" and all(.[]; (.number | type) == "number" and .number > 0))' \
        <<< "$pr_json" >/dev/null 2>&1; then
        supervisor_inbox_append_once "hand-followup-pr-read issue=#$primary pr=#$blocker" \
          "hand-followup-pr-read issue=#$primary agent=$name pr=#$blocker: invalid closing-issues response; left its hold unchanged" || true
        return 0
      fi
      pr_state="$(jq -r '.state | ascii_downcase' <<< "$pr_json")"
      refs="$(jq -r '(.closingIssuesReferences // []) | .[].number' <<< "$pr_json")"
      if [ -z "$refs" ]; then
        if [ "$pr_state" = open ] && [ -z "${pr_seen[$blocker]:-}" ]; then
          pr_seen["$blocker"]=1
          pr_blockers+=("$blocker")
        fi
        continue
      fi
      while IFS= read -r ref; do
        [[ "$ref" =~ ^[1-9][0-9]*$ ]] || continue
        [ -z "${owned_set[$ref]:-}" ] || continue
        ref_issue_json="$(gh api "repos/$REPO/issues/$ref" 2>/dev/null)" || {
          supervisor_inbox_append_once "hand-followup-pr-issue-read issue=#$primary pr=#$blocker blocker=#$ref" \
            "hand-followup-pr-issue-read issue=#$primary agent=$name pr=#$blocker blocker=#$ref: could not read closing issue; left its hold unchanged" || true
          return 0
        }
        if ! jq -e --argjson n "$ref" 'type == "object" and .number == $n
          and ((.state // "" | ascii_downcase) | IN("open", "closed"))' <<< "$ref_issue_json" >/dev/null 2>&1; then
          supervisor_inbox_append_once "hand-followup-pr-issue-read issue=#$primary pr=#$blocker blocker=#$ref" \
            "hand-followup-pr-issue-read issue=#$primary agent=$name pr=#$blocker blocker=#$ref: invalid closing issue response; left its hold unchanged" || true
          return 0
        fi
        ref_state="$(jq -r '.state | ascii_downcase' <<< "$ref_issue_json")"
        if [ "$ref_state" = open ] && [ -z "${issue_seen[$ref]:-}" ]; then
          issue_seen["$ref"]=1
          issue_blockers+=("$ref")
        fi
      done <<< "$refs"
    elif [ "$issue_state" = open ] && [ -z "${issue_seen[$blocker]:-}" ]; then
      issue_seen["$blocker"]=1
      issue_blockers+=("$blocker")
    fi
  done

  ((${#issue_blockers[@]} + ${#pr_blockers[@]} > 0)) || return 0
  for issue in "${open_owned_issues[@]}"; do
    for blocker in "${issue_blockers[@]}"; do
      if ! add_issue_blocked_by "$issue" "$blocker"; then
        supervisor_inbox_append_once "hand-followup-dependency-write issue=#$issue blocker=#$blocker" \
          "hand-followup-dependency-write issue=#$issue agent=$name blocker=#$blocker: native dependency write failed; left its hold unchanged" || true
        return 0
      fi
    done
  done

  dependency=followup
  for blocker in "${issue_blockers[@]}"; do dependency+=" issue:$blocker"; done
  for blocker in "${pr_blockers[@]}"; do dependency+=" pr:$blocker"; done
  if ! blocked_hand_agent_upsert "$pid" "$name" "$role" "$worktree" "$brief" "$report" "$log" \
    "$attempt" "$dependency" "$start_ticks" "$owned_ids" "$owned_nodes"; then
    supervisor_inbox_append_once "hand-followup-owner-write issue=#$primary" \
      "hand-followup-owner-write issue=#$primary agent=$name dependency=$dependency: blocked owner record failed; left its hold unchanged" || true
    return 0
  fi
  for issue in "${open_owned_issues[@]}"; do
    if ! state_requeue "$issue" release-hold; then
      supervisor_inbox_append_once "hand-followup-requeue issue=#$issue" \
        "hand-followup-requeue issue=#$issue agent=$name dependency=$dependency: dependency recorded, but issue requeue failed" || true
      return 0
    fi
  done
  echo "hand-followup: $name owns ${open_owned_issues[*]}, blocked by $dependency" >&2
  return 0
}
