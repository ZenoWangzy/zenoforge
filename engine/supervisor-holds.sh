# Shared supervisor-hold owner detection and sweep.
# Sourced by lib.sh after common agent paths and state helpers are available.

supervisor_hold_landing_rows() {
  local requests="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests"
  local -a files=()
  [[ -d "$requests" ]] || return 0
  [[ -r "$requests" && -x "$requests" ]] || return 2
  mapfile -t files < <(compgen -G "$requests/*.json" || true)
  ((${#files[@]})) || return 0
  jq -sr '
    .[] | select((.state | IN("queued", "running", "direct-pending-push"))
      and (.ticket | type == "string" and test("^[0-9]{20}$"))
      and (.owner | type == "string" and test("^[A-Za-z0-9_.-]+$"))) as $request
    | (((($request.owned_issues // "") | tostring | split(" "))
        + [($request.owner // "" | if test("^hand-[1-9][0-9]*$") then sub("^hand-";"") else "" end)]) | unique)[]
    | select(test("^[1-9][0-9]*$"))
    | [., (if $request.state == "queued" then "queued" else "running" end), $request.ticket, $request.owner] | @tsv
  ' "${files[@]}"
}

supervisor_hold_owner_state() {
  local n="$1" hold_kind="${2:-}" owner_name="hand-$1" night="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  local roster="$night/agents.txt" blocked="$night/blocked-hand-agents.json"
  local dependency row pid name start_ticks owned_issues issue_ids hand_wt codex_pid status lib_dir gh_error_file
  local pr_number checks checks_status outcome
  local landing_rows landing_record landing_state landing_ticket landing_owner
  SUPERVISOR_HOLD_OWNER_STATE=none
  SUPERVISOR_HOLD_OWNER_DETAIL="no queued, running, or live worktree owner"
  SUPERVISOR_HOLD_OWNER_TRANSIENT_IO=0

  # An exited hand transfers ownership to the detached lander until its request finishes.
  if [[ "${SUPERVISOR_HOLD_LANDING_CACHE_READY:-0}" == 1 ]]; then
    landing_record="${SUPERVISOR_HOLD_LANDING_BY_ISSUE[$n]:-}"
    status="${SUPERVISOR_HOLD_LANDING_CACHE_STATUS:-0}"
  else
    status=0
    landing_rows="$(supervisor_hold_landing_rows)" || status=$?
    landing_record="$(awk -F '\t' -v n="$n" '$1 == n {sub(/^[^\t]*\t/, ""); print; exit}' <<< "$landing_rows")"
  fi
  if (( status != 0 )); then
    SUPERVISOR_HOLD_OWNER_STATE=unknown
    SUPERVISOR_HOLD_OWNER_DETAIL="landing request registry unreadable"
    return 2
  fi
  if [[ -n "$landing_record" ]]; then
    IFS=$'\t' read -r landing_state landing_ticket landing_owner <<< "$landing_record"
    SUPERVISOR_HOLD_OWNER_STATE="$landing_state"
    SUPERVISOR_HOLD_OWNER_DETAIL="land-queue ticket=$landing_ticket owner=$landing_owner state=$landing_state"
    return 0
  fi

  if [ -z "$hold_kind" ]; then
    hold_kind="$(state_read "$n" 2>/dev/null | jq -r '.hold.kind // empty' 2>/dev/null || true)"
  fi

  # A hand that exited BLOCKED-ON still owns its ticket while the dependency
  # remains unresolved. 2026-10-08: hand-2680 was re-queued every tick while
  # blocked on issue 2873, and each run exited blocked again.
  if [ -e "$blocked" ]; then
    if [ "${SUPERVISOR_HOLD_BLOCKED_CACHE_READY:-0}" = 1 ]; then
      if [ "${SUPERVISOR_HOLD_BLOCKED_CACHE_INVALID:-0}" = 1 ]; then
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="blocked hand registry unreadable"
        return 2
      fi
      dependency="${SUPERVISOR_HOLD_BLOCKED_BY_ISSUE[$n]:-}"
    else
      dependency="$(jq -r --arg name "$owner_name" --arg n "$n" '
        [.[] | select(.name == $name or (((.owned_issues // "") | tostring | split(" ")) | index($n)))]
        | if length == 0 then "" else (.[0].dependency // "an unresolved dependency") end' "$blocked" 2>/dev/null)" || {
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="blocked hand registry unreadable"
        return 2
      }
    fi
    if [ -n "$dependency" ]; then
      if [ "$hold_kind" != blocked-on-resolution ]; then
        SUPERVISOR_HOLD_OWNER_STATE=blocked
        SUPERVISOR_HOLD_OWNER_DETAIL="blocked on $dependency in blocked-hand-agents.json"
        return 0
      fi
    fi
  fi

  if [ -e "$roster" ] && [ ! -r "$roster" ]; then
    SUPERVISOR_HOLD_OWNER_STATE=unknown
    SUPERVISOR_HOLD_OWNER_DETAIL="running-agent roster unreadable"
    return 2
  fi
  if [ -r "$roster" ]; then
    if ! declare -F hand_agent_pid_live >/dev/null || ! declare -F hand_agent_issue_ids >/dev/null; then
      lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
      source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
    fi
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name _model _effort _worktree _brief _report _log _attempt _started_at _role start_ticks owned_issues _owned_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      issue_ids="$(hand_agent_issue_ids "$name" "${owned_issues:-}")" || {
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="invalid owned-issue roster row for $name"
        return 2
      }
      [[ " $issue_ids " == *" $n "* ]] || continue
      if ! [[ "$pid" =~ ^[1-9][0-9]*$ && "${start_ticks:-}" =~ ^[0-9]+$ ]]; then
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="missing live-process identity for issue owner $name"
        return 2
      fi
      if hand_agent_pid_live "$pid" "${start_ticks:-}"; then
        SUPERVISOR_HOLD_OWNER_STATE=running
        SUPERVISOR_HOLD_OWNER_DETAIL="running in agents.txt as $name"
        return 0
      fi
    done < "$roster"
  fi

  hand_wt="${ZF_WORKTREE_ROOT:-$HOME/wt}/$owner_name"
  if ! declare -F hand_agent_worktree_pid >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
  fi
  case "${SUPERVISOR_HOLD_WORKTREE_SNAPSHOT_STATE:-0}" in
    1)
      if [[ -n "${SUPERVISOR_HOLD_LIVE_WORKTREES[$hand_wt]:-}" ]]; then
        SUPERVISOR_HOLD_OWNER_STATE=running
        SUPERVISOR_HOLD_OWNER_DETAIL="live Codex process on $hand_wt"
        return 0
      fi
      ;;
    2)
      SUPERVISOR_HOLD_OWNER_STATE=unknown
      SUPERVISOR_HOLD_OWNER_DETAIL="live worktree process snapshot unavailable"
      return 2
      ;;
    *)
      if codex_pid="$(hand_agent_worktree_pid "$hand_wt")"; then
        SUPERVISOR_HOLD_OWNER_STATE=running
        SUPERVISOR_HOLD_OWNER_DETAIL="live Codex process $codex_pid on $hand_wt"
        return 0
      fi
      ;;
  esac

  case "$hold_kind" in
    external-deliverable|ops-acceptance-after-release)
      if has_open_blocker "$n"; then
        if [ "${OPEN_BLOCKER_QUERY_FAILED:-0}" = 1 ]; then
          SUPERVISOR_HOLD_OWNER_STATE=unknown
          SUPERVISOR_HOLD_OWNER_DETAIL="native blocker state unreadable"
          return 2
        fi
        SUPERVISOR_HOLD_OWNER_STATE=blocked
        SUPERVISOR_HOLD_OWNER_DETAIL="blocked by open issue ${OPEN_BLOCKER_IDS:-unknown}"
        return 0
      fi
      ;;
  esac
  case "$hold_kind" in
    guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution|label-churn|repeat-cap)
      if [ "${SUPERVISOR_HOLD_PR_CACHE_READY:-0}" = 1 ]; then
        pr_number="${SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE[$n]:-}"
        if [ -n "$pr_number" ] && [ "${SUPERVISOR_HOLD_PR_PENDING_BY_ISSUE[$n]:-0}" = 1 ]; then
          SUPERVISOR_HOLD_OWNER_STATE=waiting
          SUPERVISOR_HOLD_OWNER_DETAIL="open PR #$pr_number has pending checks"
        fi
        return 0
      fi
      gh_error_file="$(mktemp)" || {
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="open PR state error file unavailable for held issue #$n"
        return 2
      }
      if open_prs="$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state open --json number,headRefName 2>"$gh_error_file")"; then
        rm -f -- "$gh_error_file"
      else
        supervisor_hand_read_failure_is_transient "$gh_error_file" && SUPERVISOR_HOLD_OWNER_TRANSIENT_IO=1
        rm -f -- "$gh_error_file"
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="open PR state unreadable for held issue #$n"
        return 2
      fi
      if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number" and (.headRefName | type) == "string")' \
        <<< "$open_prs" >/dev/null 2>&1; then
        SUPERVISOR_HOLD_OWNER_STATE=unknown
        SUPERVISOR_HOLD_OWNER_DETAIL="open PR response invalid for held issue #$n"
        return 2
      fi
      open_pr="$(jq -c --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)] | if length == 1 then .[0] else empty end' <<< "$open_prs")" || return 2
      if [ -n "$open_pr" ]; then
        pr_number="$(jq -r '.number' <<< "$open_pr")"
        gh_error_file="$(mktemp)" || {
          SUPERVISOR_HOLD_OWNER_STATE=unknown
          SUPERVISOR_HOLD_OWNER_DETAIL="PR check error file unavailable for held issue #$n"
          return 2
        }
        checks_status=0
        checks="$(gh pr checks "$pr_number" --repo "$REPO" --json name,bucket,link 2>"$gh_error_file")" || checks_status=$?
        if { [ "$checks_status" != 0 ] && [ "$checks_status" != 1 ] && [ "$checks_status" != 8 ]; } \
          || ! jq -e 'type == "array" and all(.[]; (.name | type)=="string" and (.bucket | type)=="string")' <<< "$checks" >/dev/null 2>&1; then
          supervisor_hand_read_failure_is_transient "$gh_error_file" && SUPERVISOR_HOLD_OWNER_TRANSIENT_IO=1
          rm -f -- "$gh_error_file"
          SUPERVISOR_HOLD_OWNER_STATE=unknown
          SUPERVISOR_HOLD_OWNER_DETAIL="PR check state unreadable for held issue #$n"
          return 2
        fi
        rm -f -- "$gh_error_file"
        outcome="$(pr_checks_outcome "$checks" 2>/dev/null || echo unknown)"
        if [ "$outcome" = pending ]; then
          SUPERVISOR_HOLD_OWNER_STATE=waiting
          SUPERVISOR_HOLD_OWNER_DETAIL="open PR #$pr_number has pending checks"
          return 0
        fi
      fi
      ;;
  esac
  return 0
}

supervisor_holds_snapshot() {
  local numbers="$1" now_epoch="${2:-$(date -u +%s)}" n state_json hold_json holder kind created_at created_epoch age_json owner_state
  local expires_at expiry_epoch release_condition pr_snapshot_json state_index_json="${4:-}" hold_state_rows="" hold_state_row hold_state_issue pr_checks_b64 pr_checks_json pr_check_outcome pr_number dependency_issue
  local worktree_rows worktree_path
  local night="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" blocked_file cache_issue cache_value
  local blocked_row blocked_issue blocked_dependency
  local hold_cache_ready=0 hold_cache_value recovery valid_record hold_state_json_b64
  local SUPERVISOR_HOLD_WORKTREE_SNAPSHOT_STATE=0
  local landing_rows landing_issue landing_record
  local SUPERVISOR_HOLD_LANDING_CACHE_READY=1 SUPERVISOR_HOLD_LANDING_CACHE_STATUS=0
  local -A SUPERVISOR_HOLD_LANDING_BY_ISSUE=()
  local -A SUPERVISOR_HOLD_LIVE_WORKTREES=()
  landing_rows="$(supervisor_hold_landing_rows)" || SUPERVISOR_HOLD_LANDING_CACHE_STATUS=$?
  while IFS=$'\t' read -r landing_issue landing_record; do
    [[ -n "$landing_issue" ]] || continue
    SUPERVISOR_HOLD_LANDING_BY_ISSUE["$landing_issue"]="$landing_record"
  done <<< "$landing_rows"
  local -a pr_cache_rows=() hold_cache_rows=() hold_output_fields=() blocked_cache_rows=()
  declare -gA SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE=()
  declare -gA SUPERVISOR_HOLD_PR_PENDING_BY_ISSUE=()
  declare -gA SUPERVISOR_HOLD_PR_CHECKS_OUTCOME_BY_ISSUE=()
  declare -gA SUPERVISOR_HOLD_BLOCKED_BY_ISSUE=()
  declare -A hold_state_cache=()
  SUPERVISOR_HOLD_PR_CACHE_READY=0
  SUPERVISOR_HOLD_BLOCKED_CACHE_READY=0
  SUPERVISOR_HOLD_BLOCKED_CACHE_INVALID=0
  blocked_file="$night/blocked-hand-agents.json"
  if [ -e "$blocked_file" ]; then
    if jq -e 'type == "array"' "$blocked_file" >/dev/null 2>&1; then
      SUPERVISOR_HOLD_BLOCKED_CACHE_READY=1
      mapfile -t blocked_cache_rows < <(jq -r '
        .[] as $entry
        | ((($entry.owned_issues // "") | tostring | split(" "))
           + [($entry.name // "" | if test("^hand-[1-9][0-9]*$") then sub("^hand-";"") else "" end)])[]
        | select(test("^[1-9][0-9]*$"))
        | [., (($entry.dependency // "an unresolved dependency") | tostring | gsub("[\\t\\r\\n]"; " "))] | @tsv
      ' "$blocked_file")
      for blocked_row in "${blocked_cache_rows[@]}"; do
        IFS=$'\t' read -r blocked_issue blocked_dependency <<< "$blocked_row"
        [ -n "${SUPERVISOR_HOLD_BLOCKED_BY_ISSUE[$blocked_issue]:-}" ] \
          || SUPERVISOR_HOLD_BLOCKED_BY_ISSUE["$blocked_issue"]="$blocked_dependency"
      done
    else
      SUPERVISOR_HOLD_BLOCKED_CACHE_INVALID=1
    fi
  fi
  pr_snapshot_json="${3:-${SUPERVISOR_HOLD_OPEN_PRS_JSON:-}}"
  if [[ -n "$pr_snapshot_json" ]]; then
    pr_snapshot_json="$(pr_latest_check_rows "$pr_snapshot_json" 2>/dev/null)" || pr_snapshot_json=""
  fi
  if [[ -n "$state_index_json" ]] \
    && jq -e 'type == "object" and (.holds | type) == "object"' <<< "$state_index_json" >/dev/null 2>&1; then
    hold_cache_ready=1
    mapfile -t hold_cache_rows < <(jq -r '
      .holds | to_entries[]
      | [.key, (if (.value | type) == "object" then (.value | tojson | @base64) else "INVALID" end)] | @tsv
    ' <<< "$state_index_json")
    for hold_state_row in "${hold_cache_rows[@]}"; do
      IFS=$'\t' read -r hold_state_issue hold_state_json_b64 <<< "$hold_state_row"
      if [[ "$hold_state_json_b64" == INVALID ]]; then
        hold_state_cache["$hold_state_issue"]=INVALID
      else
        hold_state_cache["$hold_state_issue"]="$hold_state_json_b64"
      fi
    done
  fi
  if [[ -n "$pr_snapshot_json" ]] && jq -e 'type == "array" and all(.[]; (.number | type) == "number" and (.headRefName | type) == "string")' \
    <<< "$pr_snapshot_json" >/dev/null 2>&1; then
    SUPERVISOR_HOLD_PR_CACHE_READY=1
    mapfile -t pr_cache_rows < <(jq -r '
      [.[] | select(.headRefName | test("^agent/issue-[1-9][0-9]*$"))
        | {issue:(.headRefName | sub("^agent/issue-";"")), number,
           pending:any((.statusCheckRollup // [])[];
             if .__typename == "CheckRun" then .status != "COMPLETED"
             elif .__typename == "StatusContext" then .state == "PENDING" or .state == "EXPECTED" else false end),
           checks:(.statusCheckRollup // [])}]
      | group_by(.issue)[]
      | if length == 1 then [.[0].issue, (.[0].number|tostring), (.[0].pending|tostring), (.[0].checks|tojson|@base64)] | @tsv
        else [.[0].issue, "", "0", ""] | @tsv end
    ' <<< "$pr_snapshot_json")
    for row in "${pr_cache_rows[@]}"; do
      IFS=$'\t' read -r n pr_number outcome pr_checks_b64 <<< "$row"
      [ -z "$pr_number" ] || SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE["$n"]="$pr_number"
      [ "$outcome" != true ] || SUPERVISOR_HOLD_PR_PENDING_BY_ISSUE["$n"]=1
      if [[ -n "$pr_number" && -n "$pr_checks_b64" ]]; then
        pr_checks_json="$(base64 --decode <<< "$pr_checks_b64" | jq -c '
          map(if .__typename == "CheckRun" then
                {name:(.name // ""),link:(.detailsUrl // ""),started_at:(.startedAt // .completedAt // null),bucket:(if .status != "COMPLETED" then "pending" elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" then "pass" else "fail" end)}
              elif .__typename == "StatusContext" then
                {name:(.context // .name // ""),link:(.targetUrl // ""),started_at:(.createdAt // null),bucket:(if .state == "SUCCESS" then "pass" elif .state == "PENDING" or .state == "EXPECTED" then "pending" else "fail" end)}
              else {name:(.name // .context // ""),bucket:"fail"} end)')" || pr_checks_json='[]'
        pr_check_outcome="$(pr_checks_outcome "$pr_checks_json" 2>/dev/null || printf fail)"
        SUPERVISOR_HOLD_PR_CHECKS_OUTCOME_BY_ISSUE["$n"]="$pr_check_outcome"
      fi
    done
  fi
  while IFS= read -r n; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    recovery=""
    if ((hold_cache_ready)); then
      hold_cache_value="${hold_state_cache[$n]:-INVALID}"
      if [ "$hold_cache_value" = INVALID ]; then
        hold_output_fields+=("$n" unknown null ownerless unknown "run hold.sh --restore ISSUE; see docs/agents/hold-recovery.md" '{}')
        continue
      fi
      hold_json="$(base64 --decode <<< "$hold_cache_value" 2>/dev/null || true)"
    else
      state_json="$(state_read "$n" 2>/dev/null || true)"
      hold_json="$(jq -c 'if type == "object" and (.hold | type) == "object" then .hold else empty end' \
        <<< "$state_json" 2>/dev/null || true)"
    fi
    if ! jq -e 'type == "object"' <<< "$hold_json" >/dev/null 2>&1; then
      hold_output_fields+=("$n" unknown null ownerless unknown "run hold.sh --restore ISSUE; see docs/agents/hold-recovery.md" '{}')
      continue
    fi
    holder="$(jq -r 'if (.holder | type) == "string" and (.holder | length) > 0 then .holder else "missing" end' <<< "$hold_json")"
    kind="$(jq -r '.kind // "unknown"' <<< "$hold_json")"
    created_at="$(jq -r '.created_at // empty' <<< "$hold_json")"
    expires_at="$(jq -r '.expires_at // empty' <<< "$hold_json")"
    release_condition="$(jq -r '.release_condition // empty' <<< "$hold_json")"
    [ -n "$holder" ] || holder=missing
    [ -n "$kind" ] || kind=unknown
      age_json=null
      valid_record=0
      if jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1 \
        && hold_durable_record_valid "$hold_json"; then
        valid_record=1
        if [ -n "$created_at" ] \
          && created_epoch="$(agent_epoch -u "$created_at" 2>/dev/null)" \
          && [[ "$created_epoch" =~ ^[0-9]+$ ]] && (( created_epoch <= now_epoch )); then
          age_json="$((now_epoch - created_epoch))"
        fi
      fi
      if [ "$valid_record" != 1 ]; then
        owner_state=ownerless
        recovery="run hold.sh --restore ISSUE; see docs/agents/hold-recovery.md"
      else
        if [ "$SUPERVISOR_HOLD_WORKTREE_SNAPSHOT_STATE" = 0 ]; then
          if declare -F hand_codex_worktrees >/dev/null \
            && worktree_rows="$(hand_codex_worktrees "${ZF_WORKTREE_ROOT:-$HOME/wt}")"; then
            SUPERVISOR_HOLD_WORKTREE_SNAPSHOT_STATE=1
            while IFS= read -r worktree_path; do
              [[ -n "$worktree_path" ]] || continue
              SUPERVISOR_HOLD_LIVE_WORKTREES["$worktree_path"]=1
            done <<< "$worktree_rows"
          else
            SUPERVISOR_HOLD_WORKTREE_SNAPSHOT_STATE=2
          fi
        fi
        if supervisor_hold_owner_state "$n" "$kind"; then owner_state="$SUPERVISOR_HOLD_OWNER_STATE"
        else owner_state=unknown; fi
      fi
      expiry_epoch=""
      if [ "$owner_state" != ownerless ] && [ -n "$expires_at" ] && [ "$holder" != unknown ]; then
        expiry_epoch="$(agent_epoch -u "$expires_at" 2>/dev/null || true)"
        if ! [[ "$expiry_epoch" =~ ^[0-9]+$ ]]; then
          owner_state=unknown
        elif (( expiry_epoch <= now_epoch )); then
          owner_state=none
        fi
      fi
      if [ "$owner_state" = none ] && [ -n "$release_condition" ] \
        && [[ "$expiry_epoch" =~ ^[0-9]+$ ]] && (( expiry_epoch > now_epoch )); then
        case "$kind" in
          await-recurrence|manual|no-production-caller|no-reachable-path|production-access) owner_state=waiting ;;
          dependency)
            if [[ "$holder" =~ ^issue-([1-9][0-9]*)$ ]]; then
              dependency_issue="${BASH_REMATCH[1]}"
              if jq -e --argjson dependency "$dependency_issue" 'any(.[]; .number == $dependency)' \
                <<< "${impl_blocker_graph_json:-[]}" >/dev/null 2>&1; then
                owner_state=waiting
              fi
            elif [[ "$holder" =~ ^hand-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
              owner_state=waiting
            fi
            ;;
          conclusion|implement-evidence)
            if [ "$holder" = supervisor-inbox ]; then owner_state=waiting; fi
            ;;
          awaiting-pr)
            pr_number="${SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE[$n]:-}"
            pr_check_outcome="${SUPERVISOR_HOLD_PR_CHECKS_OUTCOME_BY_ISSUE[$n]:-fail}"
            if [[ "$holder" == "pr-$pr_number" && -n "$pr_number" ]] \
              && [[ "$pr_check_outcome" == pass || "$pr_check_outcome" == pending ]]; then
              owner_state=waiting
            fi
            ;;
        esac
      fi
      hold_output_fields+=("$n" "$kind" "$age_json" "$owner_state" "$holder" "${recovery:-}" "$hold_json")
  done <<< "$numbers"
  if ((${#hold_output_fields[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\0' "${hold_output_fields[@]}" | python3 -c '
import json
import sys

fields = sys.stdin.buffer.read().split(b"\0")
if fields and fields[-1] == b"":
    fields.pop()
if len(fields) % 7:
    sys.exit(1)
rows = []
for offset in range(0, len(fields), 7):
    issue, kind, age, owner, holder, recovery, hold = (part.decode("utf-8") for part in fields[offset:offset + 7])
    row = {"issue": int(issue), "kind": kind,
                 "age_seconds": None if age == "null" else int(age),
                 "owner": owner, "holder": holder,
                 "recovery": recovery or None}
    if sys.argv[1] == "1":
        row["hold"] = json.loads(hold)
    rows.append(row)
print(json.dumps(rows, separators=(",", ":")))
' "${5:-0}"
}

supervisor_hold_alert_once() {
  local n="$1" kind="$2" age="$3" reason="$4" hold_json hold_change key
  hold_json="$(state_read "$n" 2>/dev/null || true)"
  hold_change="$(jq -cS '.hold // {}' <<< "$hold_json" 2>/dev/null | sha256sum | cut -c1-16)"
  [ -n "$hold_change" ] || hold_change=unknown
  key="supervisor-hold-without-owner:$n:$kind:$hold_change:$reason"
  supervisor_inbox_append_once "$key" \
    "supervisor-hold-without-owner issue=#$n kind=$kind age=${age}s $reason"
}

supervisor_hold_record_merged_resolution() {
  local n="$1" kind="$2" pr_number="$3" night="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" temp
  temp="$(mktemp "$night/.supervisor-holds-sweep.XXXXXX")" || return 1
  if ! printf '%s\tissue=#%s kind=%s merged-pr=#%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$n" "$kind" "$pr_number" > "$temp" || ! mv -f -- "$temp" "$night/supervisor-holds-sweep.latest"; then
    rm -f -- "$temp"
    return 1
  fi
}

supervisor_hold_sweep() {
  local numbers="${1:-}" held_json rows now_epoch n kind age owner_state issue_json state_json hold_json hold_b64 prs pr_json pr_number open_prs checks outcome
  local open_count failure=0
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  if ! held_json="$(gh issue list --repo "$REPO" --state open --label on-hold --limit 1000 \
    --json number,title,body,state,labels,comments 2>/dev/null)"; then
    echo "supervisor_hold_sweep: issue snapshot read failed at gh issue list; holds left unchanged" >&2
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number"
      and (.state | ascii_downcase) == "open" and (.title | type) == "string"
      and (.labels | type) == "array" and any(.labels[]?; .name == "on-hold")
      and (.comments | type) == "array")' <<< "$held_json" >/dev/null 2>&1; then
    echo "supervisor_hold_sweep: issue snapshot invalid at gh issue list; holds left unchanged" >&2
    return 1
  fi
  if [ -z "$numbers" ]; then
    numbers="$(jq -r '.[].number' <<< "$held_json")" || return 1
  fi
  now_epoch="$(date -u +%s)" || return 1
  rows="$(supervisor_holds_snapshot "$numbers" "$now_epoch" "" "" 1)" || return 1
  while IFS=$'\t' read -r n kind age owner_state holder hold_b64; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    # BLOCKED-ON holds need a verifier; aging assigns ownership without clearing the hold.
    [ "$holder" = supervisor ] \
      || { [ "$holder" = supervisor-inbox ] && [[ "$kind" == external-deliverable || "$kind" == blocked-on-resolution ]]; } \
      || [ "$kind" = pipeline-system-fastlane ] \
      || { [ "$holder" = "hand-$n" ] && [ "$kind" = hand-dispatch ]; } || continue
    case "$owner_state" in
      queued|running|worktree-live|waiting)
        if [[ "$kind" == external-deliverable || "$kind" == ops-acceptance-after-release ]] \
          && ! state_read "$n" | jq -e --arg owner "hand-$n" \
            '.hold.holder == "supervisor" and .hold.hand_owner == $owner and .hold.durable_record == true' >/dev/null 2>&1; then
          hold_assign_hand_owner "$n" "hand-$n" || { failure=1; continue; }
        fi
        continue
        ;;
    esac
    if [ "$owner_state" = unknown ]; then
      supervisor_hold_alert_once "$n" "$kind" unknown "owner state unreadable; left unchanged" || failure=1
      failure=1
      continue
    fi
    if ! [[ "$age" =~ ^[0-9]+$ ]]; then
      supervisor_hold_alert_once "$n" "$kind" unknown "hold age unreadable; left unchanged" || failure=1
      failure=1
      continue
    fi
    [[ "$kind" == external-deliverable || "$kind" == ops-acceptance-after-release || "$kind" == pipeline-system-fastlane ]] \
      || (( age > 1800 )) || continue

    hold_json="$(base64 --decode <<< "$hold_b64")" || { failure=1; continue; }
    state_json="$(state_read "$n" 2>/dev/null || true)"
    if ! jq -e --argjson expected "$hold_json" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' \
      <<< "$state_json" >/dev/null 2>&1; then continue; fi
    issue_json="$(jq -c --argjson issue "$n" '[.[] | select(.number == $issue)] | .[0] // empty' \
      <<< "$held_json" 2>/dev/null || true)"
    [ -n "$issue_json" ] || continue
    if ! supervisor_hold_owner_state "$n"; then
      supervisor_hold_alert_once "$n" "$kind" "$age" "owner became unreadable; left unchanged" || failure=1
      failure=1
      continue
    fi
    [ "$SUPERVISOR_HOLD_OWNER_STATE" = none ] || continue

    case "$kind" in
      external-deliverable|ops-acceptance-after-release|pipeline-system-fastlane)
        scheduler_requeue_issue "$n" "supervisor hold $kind has no live owner" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
        ;;
      guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution)
        prs="$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state merged \
          --json number,headRefName,baseRefName,state,mergedAt 2>/dev/null)" || {
          supervisor_hold_alert_once "$n" "$kind" "$age" "merged PR query failed" || failure=1
          failure=1
          continue
        }
        if ! jq -e 'type == "array"' <<< "$prs" >/dev/null 2>&1; then
          supervisor_hold_alert_once "$n" "$kind" "$age" "merged PR response invalid" || failure=1
          failure=1
          continue
        fi
        pr_json="$(jq -c --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch and .state == "MERGED" and .baseRefName == "main" and (.mergedAt // "") != "")] | sort_by(.mergedAt) | last // empty' <<< "$prs")"
        if [ -n "$pr_json" ]; then
          pr_number="$(jq -r '.number' <<< "$pr_json")"
          # conclude_merged_run releases the hold itself; a requeue here would
          # stamp requeued_at after the merge and make the deploy close stale.
          if conclude_merged_run "$n" "$pr_number" "" "$hold_json"; then
            supervisor_hold_record_merged_resolution "$n" "$kind" "$pr_number" || {
              supervisor_hold_alert_once "$n" "$kind" "$age" "merged PR #$pr_number concluded but HEALTH detail could not be saved" || failure=1
              failure=1
            }
            echo "supervisor_hold_sweep: concluded #$n from merged PR #$pr_number" >&2
          else
            supervisor_hold_alert_once "$n" "$kind" "$age" "merged PR #$pr_number conclusion failed" || failure=1
            failure=1
          fi
          continue
        fi

        open_prs="$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state open \
          --json number,headRefName,mergeable,mergeStateStatus,isDraft,updatedAt 2>/dev/null)" || {
          supervisor_hold_alert_once "$n" "$kind" "$age" "open PR query failed" || failure=1
          failure=1
          continue
        }
        if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number")' <<< "$open_prs" >/dev/null 2>&1; then
          supervisor_hold_alert_once "$n" "$kind" "$age" "open PR response invalid" || failure=1
          failure=1
          continue
        fi
        open_count="$(jq --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)] | length' <<< "$open_prs")"
        if [ "$open_count" -eq 1 ]; then
          pr_json="$(jq -c --arg branch "agent/issue-$n" '.[] | select(.headRefName == $branch)' <<< "$open_prs")"
          pr_number="$(jq -r '.number' <<< "$pr_json")"
          checks="$(gh pr checks "$pr_number" --repo "$REPO" --json name,bucket,link 2>/dev/null || true)"
          outcome="$(pr_checks_outcome "$checks" 2>/dev/null || echo unknown)"
          if [ "$outcome" = fail ] && main_fix_forward_carried_exception_for_pr "$pr_number"; then
            outcome=carried-hotpatch
          fi
          if { [ "$outcome" = pass ] || [ "$outcome" = carried-hotpatch ]; } && pr_mergeability_is_safe "$pr_json"; then
            if state_requeue "$n" release-hold "" . "$hold_json" \
              && merge_agent_pr "$n" "$pr_number" "" 1 0 \
              && conclude_merged_run "$n" "$pr_number"; then
              if [ "$outcome" = pass ]; then
                echo "supervisor_hold_sweep: merged #$n from green PR #$pr_number" >&2
              else
                echo "supervisor_hold_sweep: merged #$n from approved carried hotpatch PR #$pr_number with a shared main failure" >&2
              fi
              continue
            fi
            supervisor_hold_alert_once "$n" "$kind" "$age" "PR #$pr_number did not pass the shared merge gate" || failure=1
            failure=1
            continue
          fi
          # CI already owns the next transition while required checks are pending.
          if [ "$outcome" = pending ]; then
            echo "supervisor_hold_sweep: #$n waiting for PR #$pr_number checks" >&2
            continue
          fi
        elif [ "$open_count" -gt 1 ]; then
          supervisor_hold_alert_once "$n" "$kind" "$age" "multiple open PRs matched agent/issue-$n; left unchanged" || failure=1
          failure=1
          continue
        fi
        scheduler_requeue_issue "$n" "supervisor hold $kind has no live owner" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
        ;;
      await-recurrence|no-production-caller|production-access)
        ;;
      *)
        supervisor_hold_alert_once "$n" "$kind" "$age" "unknown hold kind; left unchanged" || failure=1
        ;;
    esac
  done < <(jq -r '.[] | [.issue, .kind, (.age_seconds // "unknown"), .owner, .holder, (.hold | @base64)] | @tsv' <<< "$rows")
  [ "$failure" -eq 0 ]
}
