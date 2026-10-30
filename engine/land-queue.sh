#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# The engine this script belongs to, as the caller named it (logical path, like config.sh): the default for ZF_ENGINE_LIVE.
QUEUE_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh" # deploy.env: a clean environment (the landing unit) still sees the deployment's home and unit prefix
AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
# Same setting lib.sh resolves; this script sources lib.sh only on demand.
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"
QUEUE_DIR="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}"
REQUEST_DIR="$QUEUE_DIR/requests"
QUEUE_HEALTH_SUMMARY="$QUEUE_DIR/health-summary.tsv"
source "$SCRIPT_DIR/delivery-metrics.sh" || echo 'land-queue: telemetry helper unavailable' >&2
# One durable request is one item; children are launched from current disk code.
if [[ -r "$SCRIPT_DIR/runtime-reload.sh" ]]; then
  source "$SCRIPT_DIR/runtime-reload.sh"
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    agent_reload_init "$0" "$@"
    agent_reload_restore
  fi
fi
QUEUE_MAIN_FETCH_ATTEMPTS="${ZF_LAND_QUEUE_MAIN_FETCH_ATTEMPTS:-1}"
QUEUE_MAIN_FETCH_BACKOFF_SECONDS="${ZF_LAND_QUEUE_MAIN_FETCH_BACKOFF_SECONDS:-60}"
QUEUE_TRANSIENT_ALERT_SECONDS="${ZF_LAND_QUEUE_TRANSIENT_ALERT_SECONDS:-300}"
QUEUE_TRANSIENT_BACKOFF_SECONDS="${ZF_LAND_QUEUE_TRANSIENT_BACKOFF_SECONDS:-180}"
QUEUE_TRANSIENT_MAX_ATTEMPTS="${ZF_LAND_QUEUE_TRANSIENT_MAX_ATTEMPTS:-3}"
QUEUE_LIB_LOAD_ERROR_REPORTED=0

queue_source_lib() {
  local lib="${1:-$SCRIPT_DIR/lib.sh}"
  if [[ "${ZF_AGENT_TEST_MODE:-0}" == 1 &&
    "${ZF_LAND_QUEUE_TEST_PRELOADED_LIB:-}" == "$lib" ]] &&
    declare -F agent_transport_is_transient >/dev/null; then
    return 0
  fi
  if source "$lib" 2>/dev/null; then return 0; fi
  if [[ "$QUEUE_LIB_LOAD_ERROR_REPORTED" != 1 ]]; then
    echo 'land-queue: failed to load lib.sh; refusing operation' >&2
    QUEUE_LIB_LOAD_ERROR_REPORTED=1
  fi
  return 1
}

queue_owner_issue_ids() {
  local lib="${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/lib.sh"
  [[ -r "$lib" ]] || lib="$SCRIPT_DIR/lib.sh"
  queue_source_lib "$lib" || return 1
  agent_owned_issue_ids "$1" "${2:-}"
}

queue_update_request() {
  local request="$1" state="$2" reason="${3:-}" bounded_reason landed_sha="${4:-}" batch_owner="${5:-}" pr_number="${6:-}" now_override="${7:-}" findings="${8:-[]}" now tmp
  local metrics_attempt_id="" metrics_pid="$BASHPID"
  if [[ "$state" == running ]]; then metrics_attempt_id="$(delivery_metrics_writer_id "$metrics_pid")" || true; fi
  bounded_reason="${reason:0:240}"
  if [[ "$now_override" =~ ^[0-9]+$ ]]; then now="$now_override"; else now="$(date +%s)"; fi
  tmp="$(mktemp "${request}.XXXXXX")" || return 1
  if ! jq --arg state "$state" --arg reason "$bounded_reason" --arg sha "$landed_sha" \
    --arg owner "$batch_owner" --arg pr "$pr_number" \
    --argjson findings "$findings" \
    --argjson now "$now" --arg metrics_attempt_id "$metrics_attempt_id" '
      .state=$state | .updated_epoch=$now
      | if $state == "running" then (.started_epoch=$now | del(.retry_after_epoch)
          | if $metrics_attempt_id != "" then .metrics_attempt_id=$metrics_attempt_id else del(.metrics_attempt_id) end)
        elif ($state == "landed" or $state == "failed" or $state == "cancelled" or $state == "pr-opened") then .finished_epoch=$now
        else . end
      | if $state == "landed" and (.enqueued_epoch|type) == "number" then .enqueue_to_main_seconds=($now - .enqueued_epoch) else . end
      | if $reason != "" then .reason=$reason else . end
      | if $state == "failed" then .findings=$findings else . end
      | if $sha != "" then .landed_sha=$sha else . end
      | if $owner != "" then .batch_owner=$owner
        elif ($state == "queued" or $state == "landed" or $state == "failed" or $state == "cancelled" or $state == "pr-opened") then del(.batch_owner)
        else . end
      | if $pr != "" then .pr=($pr|tonumber) else . end
    ' "$request" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod --reference="$request" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$request" || return 1
  case "$state" in
    landed) delivery_metrics_observe source-landed "$request" || true ;;
    failed|cancelled|pr-opened) delivery_metrics_observe land-terminal "$request" || true ;;
  esac
  queue_refresh_health_summary || echo 'land-queue: could not refresh HEALTH summary after request update' >&2
}

queue_post_land_record() {
  local action="$1" ticket="$2" request outcome failure_stage tmp report landed_sha status
  [[ "$ticket" =~ ^[0-9]{20}$ ]] || return 2
  request="$REQUEST_DIR/$ticket.json"
  [[ -r "$request" ]] || return 0
  case "$action" in
    result)
      [[ "$#" == 3 || "$#" == 4 ]] || return 2
      outcome="$3"
      failure_stage="${4:-}"
      [[ "$outcome" =~ ^(green|flaky|pre-existing|culprit-reverted|culprit-not-reverted|inconclusive)$ ]] || return 2
      [[ -z "$failure_stage" || "$failure_stage" =~ ^[a-z][a-z0-9-]*$ ]] || return 2
      tmp="$(mktemp "${request}.XXXXXX")" || return 1
      jq --arg outcome "$outcome" --arg failure_stage "$failure_stage" --argjson at "$(date +%s)" \
        '.post_land_verdict={outcome:$outcome,at:$at}
         | if $failure_stage == "" then . else .post_land_verdict.failure_stage=$failure_stage end
         | .post_land_conclusion_pending=true' \
        "$request" > "$tmp" || {
        rm -f -- "$tmp"
        return 1
      }
      ;;
    *) return 2 ;;
  esac
  chmod --reference="$request" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$request"
  if [[ "$action" == result ]] && [[ "$(jq -r '.state // empty' "$request")" == landed ]]; then
    queue_source_lib || return 1
    queue_report_landing_complete "$request" "LANDED $ticket $(jq -r '.landed_sha' "$request") outcome=$outcome" || return 1
    if jq -e '.hand_owner_handoff == "queued" or .hand_owner_handoff == "pending-exit"' "$request" >/dev/null; then
      tmp="$(mktemp "${request}.XXXXXX")" || return 1
      jq '.post_land_conclusion_recorded=true | .post_land_conclusion_action="continuation"
        | del(.post_land_conclusion_pending,.post_land_conclusion_deferred)' "$request" > "$tmp" \
        && mv -f -- "$tmp" "$request" || { rm -f -- "$tmp"; return 1; }
      queue_refresh_health_summary
      return $?
    fi
    if pipeline_system_finish_direct_landing "$request" "$outcome"; then
      tmp="$(mktemp "${request}.XXXXXX")" || return 1
      jq '.post_land_conclusion_recorded=true | del(.post_land_conclusion_pending, .post_land_conclusion_deferred, .post_land_conclusion_exit_checked, .post_land_conclusion_error)' \
        "$request" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      chmod --reference="$request" "$tmp" 2>/dev/null || true
      mv -f -- "$tmp" "$request"
      queue_refresh_health_summary || echo 'land-queue: could not refresh HEALTH summary after issue conclusion' >&2
    else
      status=$?
      if [[ "$status" == 2 ]]; then
        tmp="$(mktemp "${request}.XXXXXX")" || return 1
        jq '.post_land_conclusion_deferred=true' "$request" > "$tmp" || { rm -f -- "$tmp"; return 1; }
        chmod --reference="$request" "$tmp" 2>/dev/null || true
        mv -f -- "$tmp" "$request"
        echo "land-queue: issue conclusion deferred until hand exit owner=$(jq -r '.owner' "$request") ticket=$ticket" >&2
      else
        echo "land-queue: issue conclusion pending for owner=$(jq -r '.owner' "$request") ticket=$ticket outcome=$outcome" >&2
        queue_refresh_health_summary || true
        return 1
      fi
    fi
  fi
  if [[ "$action" == result ]] && jq -e '.direct_landing == true' "$request" >/dev/null 2>&1; then
    landed_sha="$(jq -r '.landed_sha' "$request")"
    queue_report_landing_complete "$request" "LANDED $ticket $landed_sha outcome=$outcome" || return 1
  fi
  queue_refresh_health_summary || echo 'land-queue: could not refresh HEALTH summary after post-land update' >&2
}

queue_refresh_health_summary() {
  local now files rows kind depth=0 active_epoch=0 last_failure=none ticket stamp age
  local post_land_depth=0 post_land_ticket=none post_land_epoch=0 tmp
  now="$(date +%s)"
  shopt -s nullglob
  files=("$REQUEST_DIR"/*.json)
  shopt -u nullglob
  if ((${#files[@]} > 0)); then
    rows="$(jq -sr '
      ([ .[] | select(.state == "queued" or .state == "running") ] as $active
      | ([ .[] | select(.state == "failed") ] | sort_by(.finished_epoch // .updated_epoch // 0) | last) as $failed
      | ["summary", ($active|length), (if ($active|length)==0 then 0 else ([ $active[].enqueued_epoch // 0 ]|min) end),
          (if $failed == null then "none" else ($failed.ticket + ":" + (($failed.reason // "") | gsub("[\\r\\n\\t]";" ") | .[0:120])) end)] | @tsv),
      (.[] | select(.state == "landed" and ((.post_land_verdict? == null) or (.post_land_conclusion_pending? == true)))
        | ["post", .ticket, (.finished_epoch // .updated_epoch // .enqueued_epoch // 0)] | @tsv)
    ' "${files[@]}")" || return 1
    while IFS=$'\t' read -r kind a b c; do
      if [[ "$kind" == summary ]]; then
        depth="$a"; active_epoch="$b"; last_failure="$c"
        continue
      fi
      [[ "$kind" == post ]] || continue
      ticket="$a"; stamp="$b"
      [[ "$ticket" =~ ^[0-9]{20}$ && "$stamp" =~ ^[0-9]+$ ]] || continue
      [[ -r "$QUEUE_DIR/results/$ticket/range" ]] || continue
      age=$((now - stamp))
      if ((post_land_depth == 0 || age > now - post_land_epoch)); then
        post_land_ticket="$ticket"
        post_land_epoch="$stamp"
      fi
      post_land_depth=$((post_land_depth + 1))
    done <<< "$rows"
  fi
  mkdir -p -- "$QUEUE_DIR"
  tmp="$(mktemp "$QUEUE_HEALTH_SUMMARY.XXXXXX")" || return 1
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$depth" "$active_epoch" "$post_land_depth" "$post_land_ticket" "$post_land_epoch" "$last_failure" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$QUEUE_HEALTH_SUMMARY"
}

queue_report_event() {
  local report="$1" event="$2" footer
  [[ -n "$event" ]] || return 0
  [[ -n "$report" && -f "$report" && -w "$report" ]] || return 1
  footer="$(awk '/^STATUS: / { status=$0 } END { if (status != "") print status }' "$report")"
  if grep -Fqx -- "$event" "$report" 2>/dev/null; then
    [[ -z "$footer" || "$(tail -n 1 "$report")" == "$footer" ]] && return 0
    printf '\n%s\n' "$footer" >> "$report"
  elif [[ -n "$footer" ]]; then
    printf '\n%s\n%s\n' "$event" "$footer" >> "$report"
  else
    printf '\n%s\n' "$event" >> "$report"
  fi
}

queue_report_status() {
  local report="$1" status="$2" event="${3:-}" tmp had_content=0 first_status
  first_status="$(sed -n '1p' "$report" 2>/dev/null || true)"
  case "$first_status" in
    'STATUS: DONE'|'STATUS: DONE '*|'STATUS: LANDED'|'STATUS: LANDED '*|'STATUS: FOLLOWUP('*|'STATUS: BLOCKED-ON '*|'STATUS: NEEDS-DECISION'|'STATUS: NEEDS-DECISION '*|'STATUS: FAILED'|'STATUS: FAILED '*)
      case "$status" in
        'STATUS: BLOCKED-ON '*|'STATUS: CANCELLED'|'STATUS: FAILED'|'STATUS: FAILED '*) ;;
        *) queue_report_event "$report" "$event"; return $? ;;
      esac
      ;;
  esac
  tmp="$(mktemp "${report}.XXXXXX")" || return 1
  if [[ -s "$report" ]]; then
    had_content=1
    awk -v status="$status" '
      { if (NR == 1) $0 = status; lines[NR] = $0 }
      END {
        last = NR
        while (last > 1 && lines[last] == "") last--
        if (last > 1 && lines[last] ~ /^STATUS: /) last--
        for (i = 1; i <= last; i++) print lines[i]
      }
    ' "$report" > "$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  else
    printf '%s\n' "$status" > "$tmp"
  fi
  if [[ -n "$event" ]]; then
    printf '\n%s\n%s\n' "$event" "$status" >> "$tmp"
  elif ((had_content)); then
    printf '\n%s\n' "$status" >> "$tmp"
  fi
  chmod --reference="$report" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$report"
}

queue_hand_report_terminal() {
  local report="$1" header=""
  [[ ! -r "$report" ]] || IFS= read -r header < "$report" || true
  [[ "$header" =~ ^STATUS:\ (DONE|LANDED|FOLLOWUP\() ]]
}

queue_hand_pending_addendum() {
  local owner="$1" report="$2" NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  # Same unresolved-marker rule as the queue writer/exit callback; acknowledged markers do not resume.
  source "$SCRIPT_DIR/night/hand-exit-handoff.sh"
  hand_addendum_pending_for_report "$owner" "$report"
}

queue_report_landing_complete() (
  local request="$1" event="$2" report owner repo metadata brief role priority tier heading remaining=0 live state tmp registry snapshot_pid current_pid
  local night="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" marker marker_line addendum_fd
  report="$(jq -r '.report // empty' "$request")"
  owner="$(jq -r '.owner' "$request")"
  mkdir -p -- "$night"
  exec {completion_fd}>"$request.owner.lock"
  flock -x "$completion_fd" || return 1
  state="$(jq -r '.hand_owner_handoff // empty' "$request")"
  case "$state" in queued|done|superseded) queue_report_event "$report" "$event"; return $? ;; esac
  marker="$night/$owner.pending-addenda"
  marker_line="LANDING-CONTINUATION $(jq -r '.ticket' "$request")"
  if [[ "$state" == pending-exit ]] && ! grep -Fqx -- "$marker_line" "$marker" 2>/dev/null; then
    # The exit callback cleared this marker only after accepting the resume.
    tmp="$(mktemp "$request.XXXXXX")" || return 1
    jq '.hand_owner_handoff="queued"' "$request" > "$tmp" && mv -f -- "$tmp" "$request" || return 1
    queue_report_event "$report" "$event"
    return $?
  fi
  if queue_hand_report_terminal "$report"; then
    if queue_hand_pending_addendum "$owner" "$report"; then
      remaining=1
    else
      # Historical brief headings/continuation declarations cannot reopen a finished owner.
      # Keep FOLLOWUP and LANDED reports intact, rather than replacing their result with DONE.
      queue_report_event "$report" "$event" || return 1
      tmp="$(mktemp "$request.XXXXXX")" || return 1
      jq '.hand_owner_handoff="done"' "$request" > "$tmp" \
        && mv -f -- "$tmp" "$request" || { rm -f -- "$tmp"; return 1; }
      return 0
    fi
  elif queue_hand_pending_addendum "$owner" "$report"; then
    remaining=1
  fi
  repo="$(jq -r '.owner_worktree // .worktree // empty' "$request")"
  metadata="$(queue_hand_owner_resume_metadata "$owner" "$repo" "$report")" || return 1
  if [[ "$metadata" == null ]]; then
    # A hand can publish from a retry worktree while its durable owner keeps the original tree.
    registry="$night/hand-registry/$owner.json"
    repo="$(jq -r --arg report "$report" 'select(.report == $report) | .worktree // empty' \
      "$registry" 2>/dev/null || true)"
    [[ -z "$repo" ]] || metadata="$(queue_hand_owner_resume_metadata "$owner" "$repo" "$report")" || return 1
    [[ -n "$repo" ]] || repo="$(jq -r '.owner_worktree // .worktree // empty' "$request")"
  fi
  if [[ "$metadata" == null ]]; then metadata="$(jq -c '.hand_owner_resume // null' "$request")"; fi
  snapshot_pid="$(jq -r '.hand_owner_resume.pid // empty' "$request")"
  current_pid="$(jq -r '.pid // empty' <<< "$metadata")"
  if [[ -n "$snapshot_pid" && -n "$current_pid" && "$snapshot_pid" != "$current_pid" ]]; then
    # A newer dispatch already owns the remaining work; old landings cannot complete its report.
    tmp="$(mktemp "$request.XXXXXX")" || return 1
    jq '.hand_owner_handoff="superseded"' "$request" > "$tmp" && mv -f -- "$tmp" "$request" || return 1
    queue_report_event "$report" "$event"
    return $?
  fi
  brief="$(jq -r '.brief // empty' <<< "$metadata")"
  if [[ -n "$brief" && -r "$brief" ]]; then
    while IFS= read -r heading; do
      if ! grep -Fq -- "$heading" "$report"; then remaining=1; break; fi
    done < <(grep '^## Addendum ' "$brief" || true)
  fi
  # Only explicit continuation declarations count; a generic final reread instruction does not.
  if grep -Eiq '^(Incremental continuation required|CONTINUATION: required|RESUME-AFTER-LANDING: required)' \
      "$report" "${brief:-/dev/null}" 2>/dev/null; then remaining=1; fi
  if ((remaining)); then
    [[ -n "$repo" && -r "$brief" ]] || return 1
    role="$(jq -r '.role // "work"' <<< "$metadata")"
    priority="$(jq -r '.priority // ""' <<< "$metadata")"
    tier="$(jq -r '.tier // ""' <<< "$metadata")"
    # The existing exit callback retains a live owner's tree and delivers this marker after exit.
    exec {addendum_fd}>>"$night/$owner.addenda.lock" || return 1
    flock -x "$addendum_fd" || return 1
    grep -Fqx -- "$marker_line" "$marker" 2>/dev/null || printf '%s\n' "$marker_line" >> "$marker"
    flock -u "$addendum_fd"
    exec {addendum_fd}>&-
    source "$SCRIPT_DIR/hand-codex-liveness.sh"
    live="$(hand_codex_worktrees "$(dirname -- "$repo")/")" || return 1
    if grep -Fqx -- "$repo" <<< "$live"; then
      state=pending-exit
    else
      ENQUEUE_ROLE="$role" ENQUEUE_PRIORITY="$priority" ENQUEUE_TIER="$tier" \
        ENQUEUE_REPORT="$report" ENQUEUE_ISSUES="$(jq -r '.owned_issues // ""' "$request")" \
        ENQUEUE_NODES="$(jq -r '.owned_nodes // ""' <<< "$metadata")" \
        bash "$SCRIPT_DIR/night/brief-addendum.sh" --agent-exited "$owner" "$repo" "$brief" "$report" || return 1
      state=queued
    fi
    queue_report_status "$report" 'STATUS: IN_PROGRESS' "$event" || return 1
  elif [[ "$metadata" != null || -z "$(jq -r '.owned_issues // ""' "$request")" ]]; then
    state=done
    queue_report_status "$report" 'STATUS: DONE' "$event" || return 1
  else
    # Non-hand issue conclusions retain their existing post-land verification gate.
    queue_report_event "$report" "$event"
    return $?
  fi
  registry="$night/hand-registry/$owner.json"
  if [[ -r "$registry" ]]; then
    tmp="$(mktemp "$registry.XXXXXX")" || return 1
    jq --arg state "$state" '.landing_status=(if $state == "done" then "DONE" else $state end)' \
      "$registry" > "$tmp" && mv -f -- "$tmp" "$registry" || { rm -f -- "$tmp"; return 1; }
  fi
  tmp="$(mktemp "$request.XXXXXX")" || return 1
  jq --arg state "$state" '.hand_owner_handoff=$state' "$request" > "$tmp" \
    && mv -f -- "$tmp" "$request" || { rm -f -- "$tmp"; return 1; }
)

queue_hand_lock_is_stale() {
  local reason="$1" owner_pid owner_ticks unit unit_state unit_main_pid stat_line rest current_ticks
  [[ "$reason" =~ ^hand-agent:owner_pid=([1-9][0-9]*)[[:space:]]owner_start_ticks=([0-9]+)[[:space:]]unit=(${UNIT_PREFIX_TRANSIENT}-hand-[[:alnum:]_.-]+)$ ]] || return 1
  owner_pid="${BASH_REMATCH[1]}"
  owner_ticks="${BASH_REMATCH[2]}"
  unit="${BASH_REMATCH[3]}"
  unit_state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null)" || return 1
  unit_main_pid="$(systemctl --user show "$unit" --property=MainPID --value 2>/dev/null)" || return 1
  [[ "$unit_state" == inactive && "$unit_main_pid" == 0 ]] || return 1
  if [[ -e "/proc/$owner_pid/stat" ]]; then
    IFS= read -r stat_line < "/proc/$owner_pid/stat" || return 1
    rest="${stat_line##*) }"
    current_ticks="$(awk '{print $20}' <<< "$rest")"
    [[ "$current_ticks" =~ ^[0-9]+$ && "$current_ticks" != "$owner_ticks" ]] || return 1
  fi
}

queue_worktree_lock_matches() {
  local repo="$1" expected="$2" line found=0 locked=0 reason="" records
  records="$(git -C "$repo" worktree list --porcelain)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        [[ "$found" == 1 ]] && break
        if [[ "${line#worktree }" == "$repo" ]]; then found=1; else found=0; fi
        ;;
      'locked'*)
        if [[ "$found" == 1 ]]; then locked=1; reason="${line#locked}"; reason="${reason# }"; fi
        ;;
    esac
  done <<< "$records"
  [[ "$found" == 1 && "$locked" == 1 && "$reason" == "$expected" ]]
}

queue_worktree_state() {
  local repo="$1" ticket="$2" owner="$3" line in_tree=0 primary=0 found=0 first=1 locked=0 reason="" unit="${UNIT_PREFIX_TRANSIENT}-land-direct-main-$2" stat_line rest owner_ticks
  local records
  records="$(git -C "$repo" worktree list --porcelain)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [[ "$found" == 1 ]]; then break; fi
        in_tree=1
        if ((first)); then
          [[ "${line#worktree }" == "$repo" ]] && primary=1
          first=0
        fi
        if [[ "${line#worktree }" == "$repo" ]]; then found=1; else found=0; fi
        ;;
      'locked'*)
        if [[ "$found" == 1 ]]; then locked=1; reason="${line#locked}"; reason="${reason# }"; fi
        ;;
      '') in_tree=0 ;;
    esac
  done <<< "$records"
  [[ "$found" == 1 ]] || { echo "land-queue: worktree not registered: $repo" >&2; return 1; }
  LAND_QUEUE_LOCK_CREATED=0
  ((primary)) && return 0
  if ((locked)); then
    [[ "$reason" == land-direct-main:* ]] && return 0
    queue_hand_lock_is_stale "$reason" || {
      echo "land-queue: worktree already locked: $reason" >&2
      return 1
    }
    queue_worktree_lock_matches "$repo" "$reason" || {
      echo "land-queue: worktree lock changed during stale hand-agent check; refusing: $repo" >&2
      return 1
    }
    git -C "$repo" worktree unlock "$repo" || {
      echo "land-queue: could not release stale hand-agent lock: $repo" >&2
      return 1
    }
  fi
  IFS= read -r stat_line < "/proc/$BASHPID/stat" || return 1
  rest="${stat_line##*) }"
  owner_ticks="$(awk '{print $20}' <<< "$rest")"
  [[ "$owner_ticks" =~ ^[0-9]+$ ]] || return 1
  git -C "$repo" worktree lock \
    --reason "land-direct-main:ticket=$ticket owner=$owner owner_pid=$BASHPID owner_start_ticks=$owner_ticks unit=$unit" \
    "$repo" || return 1
  LAND_QUEUE_LOCK_CREATED=1
}

queue_unlock_worktree() {
  local repo="$1" line in_tree=0 found=0 locked=0 reason="" records
  records="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [[ "$found" == 1 ]]; then break; fi
        in_tree=1
        if [[ "${line#worktree }" == "$repo" ]]; then found=1; else found=0; fi
        ;;
      'locked'*)
        if [[ "$found" == 1 ]]; then locked=1; reason="${line#locked}"; reason="${reason# }"; fi
        ;;
      '') in_tree=0 ;;
    esac
  done <<< "$records"
  if [[ "$found" == 1 && "$locked" == 1 && "$reason" == land-direct-main:* ]]; then
    git -C "$repo" worktree unlock "$repo"
  fi
}

queue_start_unit() {
  local request="$1" ticket repo owner report package unit working_dir
  local egress_proxy_env="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}/state/egress-proxy.env"
  if [[ -r "$egress_proxy_env" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$egress_proxy_env"
    set +a
  fi
  local proxy_url="${ZF_EGRESS_PROXY:-${https_proxy:-}}" proxy_bypass='127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8'
  [[ -n "$proxy_url" ]] || { echo 'land-queue: egress proxy config is missing' >&2; return 2; }
  local -a retry_env=()
  IFS=$'\x1f' read -r ticket repo owner report package < <(
    jq -r '[.ticket, .worktree, .owner, .report, .plan_package] | join("\u001f")' "$request"
  )
  [[ "$ticket" =~ ^[0-9]{20}$ && "$owner" =~ ^[[:alnum:]_.-]+$ ]] || return 2
  unit="${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket"
  if systemctl --user is-active --quiet "$unit"; then return 0; fi
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  if [[ -d "$repo" ]]; then
    working_dir="$repo"
  else
    working_dir="$(git -C "$AGENT_HOME/checkout" rev-parse --show-toplevel 2>/dev/null)" || return 1
  fi
  [[ "${ZF_LAND_QUEUE_MAIN_FETCH_ATTEMPTS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_QUEUE_MAIN_FETCH_ATTEMPTS=$ZF_LAND_QUEUE_MAIN_FETCH_ATTEMPTS")
  [[ "${ZF_LAND_QUEUE_MAIN_FETCH_BACKOFF_SECONDS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_QUEUE_MAIN_FETCH_BACKOFF_SECONDS=$ZF_LAND_QUEUE_MAIN_FETCH_BACKOFF_SECONDS")
  [[ "${ZF_LAND_QUEUE_TRANSIENT_ALERT_SECONDS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_QUEUE_TRANSIENT_ALERT_SECONDS=$ZF_LAND_QUEUE_TRANSIENT_ALERT_SECONDS")
  [[ "${ZF_LAND_QUEUE_TRANSIENT_MAX_ATTEMPTS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_QUEUE_TRANSIENT_MAX_ATTEMPTS=$ZF_LAND_QUEUE_TRANSIENT_MAX_ATTEMPTS")
  [[ "${ZF_LAND_QUEUE_TRANSIENT_BACKOFF_SECONDS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_QUEUE_TRANSIENT_BACKOFF_SECONDS=$ZF_LAND_QUEUE_TRANSIENT_BACKOFF_SECONDS")
  retry_env+=(-E "ZF_LAND_QUEUE_TICKET=$ticket")
  [[ "${ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS+x}" ]] && \
    retry_env+=(-E "ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS=$ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS")
  [[ "${ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS+x}" ]] && \
    retry_env+=(-E "ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS=$ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS")
  if systemd-run --user --unit="$unit" --collect --no-block --quiet \
    --property="WorkingDirectory=$working_dir" --property="EnvironmentFile=$AGENT_HOME/env" \
    -E "AGENT_HOME=$AGENT_HOME" -E "ZF_REPO_DIR=$repo" -E "REPO_DIR=$repo" \
    -E "ZF_LAND_QUEUE_DIR=$QUEUE_DIR" -E "ZF_AGENT_NAME=$owner" \
    -E "ZF_AGENT_REPORT=$report" -E "PLAN_PACKAGE=$package" -E "PATH=$PATH" \
    -E "http_proxy=$proxy_url" -E "https_proxy=$proxy_url" \
    -E "HTTP_PROXY=$proxy_url" -E "HTTPS_PROXY=$proxy_url" \
    -E "all_proxy=$proxy_url" -E "ALL_PROXY=$proxy_url" \
    -E "no_proxy=$proxy_bypass" -E "NO_PROXY=$proxy_bypass" \
    -E "NODE_USE_ENV_PROXY=1" \
    "${retry_env[@]}" \
    -- bash "${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/land-queue.sh" run "$request"; then
    return 0
  fi
  systemctl --user is-active --quiet "$unit"
}

queue_hand_owner_resume_metadata() {
  local owner="$1" repo="$2" report="$3" roster="$AGENT_HOME/night/agents.txt" row selected=""
  local pid name model effort worktree brief_path agent_report log attempt started_at role start_ticks owned_issues owned_nodes
  local registry="$AGENT_HOME/night/hand-registry/$owner.json" metadata
  metadata="$(jq -ce --arg repo "$repo" --arg report "$report" \
    'select(.worktree == $repo and .report == $report)' "$registry" 2>/dev/null || true)"
  if [[ -n "$metadata" ]]; then printf '%s\n' "$metadata"; return 0; fi
  [ -r "$roster" ] || { printf 'null\n'; return 0; }
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ "$row" == *$'\t'* ]] || continue
    IFS=$'\x1f' read -r pid name model effort worktree brief_path agent_report log attempt started_at role start_ticks owned_issues owned_nodes \
      <<< "${row//$'\t'/$'\x1f'}"
    [[ "$name" == "$owner" && "$worktree" == "$repo" && "$agent_report" == "$report" ]] || continue
    selected="$row"
  done < "$roster"
  [[ -n "$selected" ]] || { printf 'null\n'; return 0; }
  IFS=$'\x1f' read -r pid name model effort worktree brief_path agent_report log attempt started_at role start_ticks owned_issues owned_nodes \
    <<< "${selected//$'\t'/$'\x1f'}"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[0-9]+$ && "$start_ticks" =~ ^[0-9]+$ && "$role" =~ ^[a-z][a-z0-9-]*$ ]] \
    || { printf 'null\n'; return 0; }
  jq -cn --argjson pid "$pid" --arg role "$role" --arg brief "$brief_path" --arg log "$log" \
    --argjson attempt "$attempt" --arg start_ticks "$start_ticks" --arg owned_issues "$owned_issues" \
    --arg owned_nodes "$owned_nodes" \
    '{pid:$pid,role:$role,brief:$brief,log:$log,attempt:$attempt,start_ticks:$start_ticks,owned_issues:$owned_issues,owned_nodes:$owned_nodes}'
}

queue_enqueue() {
  local repo="$1" owner="$2" report="$3" branch head subject package request ticket counter tmp report_backup hand_owner_resume live_checkout owner_issues
  repo="$(git -C "$repo" rev-parse --show-toplevel)" || return 1
  repo="$(realpath -- "$repo")"
  live_checkout="$(realpath -m -- "$AGENT_HOME/checkout")"
  [[ "$repo" != "$live_checkout" ]] || { echo "land-queue: refusing live pipeline checkout: $repo" >&2; return 2; }
  branch="$(git -C "$repo" branch --show-current)"
  [[ -n "$branch" && "$branch" != main ]] || { echo "land-queue: run from a named topic branch" >&2; return 2; }
  [[ "$owner" =~ ^[[:alnum:]_.-]+$ ]] || { echo "land-queue: invalid owner name" >&2; return 2; }
  [[ "$report" == /* && "$report" != *$'\t'* && "$report" != *$'\n'* ]] \
    || { echo "land-queue: report path must be absolute and single-line" >&2; return 2; }
  [[ -f "$report" && -r "$report" && -w "$report" ]] || { echo "land-queue: report must exist and be writable: $report" >&2; return 2; }
  [[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ]] \
    || { echo "land-queue: commit or remove worktree changes before enqueue" >&2; return 2; }
  if ! (cd -- "$repo" && node scripts/branch-delivery-policy.mjs --check-direct-main-lane); then
    return 2
  fi
  head="$(git -C "$repo" rev-parse --verify HEAD^{commit})" || return 1
  subject="$(git -C "$repo" show -s --format=%s "$head")"
  [[ "$subject" == '[skip ci]'* ]] || { echo "land-queue: HEAD subject must start with [skip ci]" >&2; return 2; }
  package="$(git -C "$repo" show -s --format=%B "$head" | sed -n 's/^Plan-Package: //p')"
  [[ "$package" =~ ^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*$ ]] || { echo "land-queue: HEAD needs a Plan-Package trailer" >&2; return 2; }
  if [[ -n "${PLAN_PACKAGE:-}" && "$PLAN_PACKAGE" != "$package" ]]; then
    echo "land-queue: Plan-Package trailer '$package' does not match PLAN_PACKAGE '$PLAN_PACKAGE'" >&2
    return 2
  fi
  owner_issues="$(queue_owner_issue_ids "$owner" "${ZF_AGENT_ISSUES:-${HAND_ISSUES:-}}")" || return 1

  mkdir -p -- "$REQUEST_DIR" || return 1
  exec {allocator_fd}>"$QUEUE_DIR/allocator.lock" || return 1
  flock -x "$allocator_fd" || { exec {allocator_fd}>&-; return 1; }
  counter=0
  [[ -r "$QUEUE_DIR/next" ]] && read -r counter < "$QUEUE_DIR/next" || true
  [[ "$counter" =~ ^[0-9]+$ ]] || { flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  ticket=$((10#$counter + 1))
  printf -v ticket '%020d' "$ticket"
  tmp="$(mktemp "$QUEUE_DIR/.request.XXXXXX")" || { flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  hand_owner_resume="$(queue_hand_owner_resume_metadata "$owner" "$repo" "$report")" || {
    rm -f -- "$tmp"; flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1;
  }
  jq -n --arg ticket "$ticket" --arg owner "$owner" --arg worktree "$repo" \
    --arg branch "$branch" --arg head "$head" --arg report "$report" --arg package "$package" \
    --arg owned_issues "$owner_issues" \
    --argjson hand_owner_resume "$hand_owner_resume" \
    --argjson now "$(date +%s)" \
    '{ticket:$ticket,owner:$owner,owned_issues:$owned_issues,worktree:$worktree,branch:$branch,head_sha:$head,report:$report,plan_package:$package,enqueued_epoch:$now,updated_epoch:$now,state:"queued"} | if $hand_owner_resume == null then . else .hand_owner_resume=$hand_owner_resume end' > "$tmp" \
    || { rm -f -- "$tmp"; flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  request="$REQUEST_DIR/$ticket.json"
  mv -- "$tmp" "$request" || { rm -f -- "$tmp"; flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  printf '%s\n' "$((10#$ticket))" > "$QUEUE_DIR/.next.$BASHPID"
  mv -f -- "$QUEUE_DIR/.next.$BASHPID" "$QUEUE_DIR/next"
  flock -u "$allocator_fd"
  exec {allocator_fd}>&-

  queue_worktree_state "$repo" "$ticket" "$owner" || { rm -f -- "$request"; return 1; }
  report_backup="$(mktemp "${report}.backup.XXXXXX")" || { queue_unlock_worktree "$repo"; rm -f -- "$request"; return 1; }
  cp -- "$report" "$report_backup"
  queue_report_status "$report" "STATUS: LANDING-QUEUED $ticket" || {
    cp -- "$report_backup" "$report"; rm -f -- "$report_backup" "$request"; queue_unlock_worktree "$repo"; return 1;
  }
  queue_refresh_health_summary || return 1
  # Setup rollback above deletes the request. Observe only the retained accepted
  # request, before startup so a launch failure still records enqueue + cancel.
  delivery_metrics_observe land-enqueued "$request" || true
  if ! queue_start_unit "$request"; then
    cp -- "$report_backup" "$report"
    rm -f -- "$report_backup"
    queue_update_request "$request" cancelled 'systemd-run failed' || true
    queue_unlock_worktree "$repo" || true
    echo "land-queue: failed to start ${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket" >&2
    return 1
  fi
  rm -f -- "$report_backup"
  printf 'LANDING-QUEUED %s %s\n' "$ticket" "$head"
}

queue_direct_reserve() {
  local repo="$1" owner="$2" base="$3" head="$4" lander_pid="$5" lander_ticks="$6"
  local ticket request existing counter tmp report now existing_pid existing_ticks existing_state owner_issues
  local -a existing_requests=()
  repo="$(realpath -- "$(git -C "$repo" rev-parse --show-toplevel)")" || return 1
  [[ "$owner" =~ ^[[:alnum:]_.-]+$ && "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ &&
     "$lander_pid" =~ ^[1-9][0-9]*$ && "$lander_ticks" =~ ^[0-9]+$ ]] || return 2
  owner_issues="$(queue_owner_issue_ids "$owner" "${ZF_AGENT_ISSUES:-${HAND_ISSUES:-}}")" || return 1
  mkdir -p -- "$REQUEST_DIR" "$QUEUE_DIR/logs" || return 1
  exec {allocator_fd}>"$QUEUE_DIR/allocator.lock" || return 1
  flock -x "$allocator_fd" || { exec {allocator_fd}>&-; return 1; }
  shopt -s nullglob
  existing_requests=("$REQUEST_DIR"/*.json)
  shopt -u nullglob
  for existing in "${existing_requests[@]}"; do
    if jq -e --arg base "$base" --arg head "$head" \
        '.direct_landing == true and .base_sha == $base and .head_sha == $head and .state != "cancelled"' \
        "$existing" >/dev/null 2>&1; then
      ticket="$(jq -r '.ticket' "$existing")"
      existing_state="$(jq -r '.state' "$existing")"
      existing_pid="$(jq -r '.lander_pid // 0' "$existing")"
      existing_ticks="$(jq -r '.lander_start_ticks // 0' "$existing")"
      if [[ "$existing_state" == direct-pending-push ]] && \
          ! queue_lander_process_matches "$existing_pid" "$existing_ticks"; then
        now="$(date +%s)"
        tmp="$(mktemp "${existing}.XXXXXX")" || { flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
        if ! jq --argjson pid "$lander_pid" --argjson ticks "$lander_ticks" --argjson now "$now" \
            '.lander_pid=$pid | .lander_start_ticks=$ticks | .updated_epoch=$now' "$existing" > "$tmp"; then
          rm -f -- "$tmp"
          flock -u "$allocator_fd"; exec {allocator_fd}>&-
          return 1
        fi
        chmod --reference="$existing" "$tmp" 2>/dev/null || true
        if ! mv -f -- "$tmp" "$existing"; then
          rm -f -- "$tmp"
          flock -u "$allocator_fd"; exec {allocator_fd}>&-
          return 1
        fi
      fi
      flock -u "$allocator_fd"
      exec {allocator_fd}>&-
      printf '%s\n' "$ticket"
      return 0
    fi
  done
  counter=0
  [[ -r "$QUEUE_DIR/next" ]] && read -r counter < "$QUEUE_DIR/next" || true
  [[ "$counter" =~ ^[0-9]+$ ]] || { flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  ticket=$((10#$counter + 1))
  printf -v ticket '%020d' "$ticket"
  now="$(date +%s)"
  request="$REQUEST_DIR/$ticket.json"
  report="$QUEUE_DIR/logs/direct-$ticket.report"
  printf 'STATUS: LANDING\nDirect-main landing %s..%s\n' "$base" "$head" > "$report" || {
    flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1;
  }
  tmp="$(mktemp "$QUEUE_DIR/.request.XXXXXX")" || { rm -f -- "$report"; flock -u "$allocator_fd"; exec {allocator_fd}>&-; return 1; }
  if ! jq -n --arg ticket "$ticket" --arg owner "$owner" --arg repo "$repo" --arg branch "$(git -C "$repo" branch --show-current)" \
      --arg base "$base" --arg head "$head" --arg report "$report" --argjson now "$now" \
      --arg owned_issues "$owner_issues" \
      --argjson lander_pid "$lander_pid" --argjson lander_ticks "$lander_ticks" \
      '{ticket:$ticket,owner:$owner,owned_issues:$owned_issues,worktree:$repo,post_land_repo:$repo,branch:$branch,head_sha:$head,base_sha:$base,landed_sha:$head,
        report:$report,plan_package:"direct-main",direct_landing:true,lander_pid:$lander_pid,lander_start_ticks:$lander_ticks,
        enqueued_epoch:$now,updated_epoch:$now,state:"direct-pending-push"}' > "$tmp"; then
    rm -f -- "$tmp" "$report"
    flock -u "$allocator_fd"; exec {allocator_fd}>&-
    return 1
  fi
  if ! mv -- "$tmp" "$request" || ! printf '%s\n' "$((10#$ticket))" > "$QUEUE_DIR/.next.$BASHPID" || \
      ! mv -f -- "$QUEUE_DIR/.next.$BASHPID" "$QUEUE_DIR/next"; then
    rm -f -- "$tmp" "$QUEUE_DIR/.next.$BASHPID" "$report"
    flock -u "$allocator_fd"; exec {allocator_fd}>&-
    return 1
  fi
  flock -u "$allocator_fd"
  exec {allocator_fd}>&-
  delivery_metrics_observe land-enqueued "$request" || true
  printf '%s\n' "$ticket"
}

queue_direct_landed() {
  local ticket="$1" base="$2" head="$3" request result_dir range_tmp request_tmp state now report enqueued_epoch duration event
  [[ "$ticket" =~ ^[0-9]{20}$ && "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 2
  request="$REQUEST_DIR/$ticket.json"
  jq -e --arg base "$base" --arg head "$head" \
    '.direct_landing == true and .base_sha == $base and .head_sha == $head' "$request" >/dev/null 2>&1 || return 2
  state="$(jq -r '.state' "$request")"
  [[ "$state" == direct-pending-push || "$state" == landed ]] || return 2
  if [[ "$state" == landed ]] && jq -e '.post_land_verdict? != null' "$request" >/dev/null 2>&1; then return 0; fi
  result_dir="$QUEUE_DIR/results/$ticket"
  mkdir -p -- "$result_dir" || return 1
  range_tmp="$(mktemp "$result_dir/.range.XXXXXX")" || return 1
  printf '%s %s\n' "$base" "$head" > "$range_tmp" && mv -f -- "$range_tmp" "$result_dir/range" || {
    rm -f -- "$range_tmp"; return 1;
  }
  now="$(date +%s)"
  request_tmp="$(mktemp "${request}.XXXXXX")" || return 1
  jq --argjson now "$now" --arg head "$head" \
    '.state="landed" | .landed_sha=$head | .finished_epoch=$now | .updated_epoch=$now | if (.enqueued_epoch|type) == "number" then .enqueue_to_main_seconds=($now - .enqueued_epoch) else . end' "$request" > "$request_tmp" || {
    rm -f -- "$request_tmp"; return 1;
  }
  chmod --reference="$request" "$request_tmp" 2>/dev/null || true
  mv -f -- "$request_tmp" "$request" || return 1
  delivery_metrics_observe source-landed "$request" || true
  report="$(jq -r '.report' "$request")"
  enqueued_epoch="$(jq -r '.enqueued_epoch // empty' "$request")"
  duration=""
  [[ "$enqueued_epoch" =~ ^[0-9]+$ ]] && duration=" enqueue_to_main_seconds=$((now - enqueued_epoch))"
  event="LANDED $ticket $head$duration"
  queue_report_status "$report" 'STATUS: POST-LAND-VERIFYING' "$event" || return 1
  queue_conclude_landed "$request"
  queue_refresh_health_summary || echo 'land-queue: could not refresh HEALTH summary after direct landing' >&2
}

queue_direct_cancel() {
  local ticket="$1" reason="$2" request report
  [[ "$ticket" =~ ^[0-9]{20}$ ]] || return 2
  request="$REQUEST_DIR/$ticket.json"
  jq -e '.direct_landing == true and .state == "direct-pending-push"' "$request" >/dev/null 2>&1 || return 0
  queue_update_request "$request" cancelled "$reason" || return 1
  report="$(jq -r '.report' "$request")"
  queue_report_status "$report" 'STATUS: CANCELLED' "$reason"
}

queue_isolate_request() {
  local request="$1" source_repo branch head ticket repo tmp name email
  [[ "$(jq -r '.owner_worktree // empty' "$request")" == '' ]] || return 0
  source_repo="$(jq -r '.worktree' "$request")"
  local object_repo="$source_repo"
  [[ -d "$object_repo" ]] || object_repo="$AGENT_HOME/checkout"
  branch="$(jq -r '.branch' "$request")"
  head="$(jq -r '.head_sha' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  [[ "$ticket" =~ ^[0-9]{20}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  repo="$QUEUE_DIR/worktrees/$ticket"
  mkdir -p -- "$QUEUE_DIR/worktrees" || return 1
  # The producer may already be editing its next unit. Only the captured commit enters this tree.
  if [[ ! -d "$repo" ]]; then
    git -C "$object_repo" worktree add --quiet --no-track -b "land-queue/$ticket" "$repo" "$head" || return 1
  fi
  # Resume an interrupted migration only when its private tree still matches the captured commit.
  [[ "$(git -C "$repo" branch --show-current)" == "land-queue/$ticket" &&
     "$(git -C "$repo" rev-parse HEAD)" == "$head" &&
     -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ]] || return 1
  if [[ "$(git -C "$object_repo" config --bool extensions.worktreeConfig 2>/dev/null || true)" == true ]]; then
    name="$(git -C "$object_repo" config user.name)" || return 1
    email="$(git -C "$object_repo" config user.email)" || return 1
    git -C "$repo" config --worktree user.name "$name" || return 1
    git -C "$repo" config --worktree user.email "$email" || return 1
  fi
  tmp="$(mktemp "${request}.XXXXXX")" || return 1
  if ! jq --arg source "$source_repo" --arg branch "$branch" --arg repo "$repo" --arg ticket "$ticket" \
    '.owner_worktree=$source | .owner_branch=$branch | .worktree=$repo | .branch=("land-queue/"+$ticket)' \
    "$request" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod --reference="$request" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$request" || return 1
  queue_worktree_state "$repo" "$ticket" "$(jq -r '.owner' "$request")" || return 1
  queue_unlock_worktree "$source_repo"
}

queue_recover_interrupted_rebase() {
  local request="$1" repo branch ticket expected_head git_dir rebase_dir rebase_state head_name
  repo="$(jq -r '.worktree' "$request")"
  branch="$(jq -r '.branch' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  expected_head="$(jq -r '.head_sha' "$request")"
  # Only the ticket's private snapshot is recoverable; owner worktrees stay fail-closed.
  [[ "$repo" == "$QUEUE_DIR/worktrees/$ticket" && "$branch" == "land-queue/$ticket" ]] || return 0
  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  rebase_dir=""
  for rebase_state in rebase-merge rebase-apply; do
    if [[ -d "$git_dir/$rebase_state" ]]; then
      if [[ -n "$rebase_dir" ]]; then
        QUEUE_SNAPSHOT_ERROR='multiple interrupted Git rebase states in queued worktree'
        return 1
      fi
      rebase_dir="$git_dir/$rebase_state"
    fi
  done
  [[ -n "$rebase_dir" ]] || return 0
  head_name="$(cat "$rebase_dir/head-name" 2>/dev/null || true)"
  if [[ "$head_name" != "refs/heads/$branch" || ! "$expected_head" =~ ^[0-9a-f]{40}$ ]] || \
      ! git -C "$repo" cat-file -e "$expected_head^{commit}" 2>/dev/null; then
    QUEUE_SNAPSHOT_ERROR="interrupted rebase does not match queued snapshot: branch=$branch head-name=$head_name"
    return 1
  fi
  if ! git -C "$repo" rebase --abort; then
    QUEUE_SNAPSHOT_ERROR="could not abort interrupted rebase: branch=$branch"
    return 1
  fi
  if [[ "$(git -C "$repo" branch --show-current 2>/dev/null || true)" != "$branch" ]]; then
    QUEUE_SNAPSHOT_ERROR="interrupted rebase did not restore queued branch: branch=$branch"
    return 1
  fi
  if [[ "$(git -C "$repo" rev-parse --verify HEAD^{commit} 2>/dev/null || true)" != "$expected_head" ]] && \
      ! git -C "$repo" reset --hard "$expected_head"; then
    QUEUE_SNAPSHOT_ERROR="could not restore captured queued head: branch=$branch head=$expected_head"
    return 1
  fi
  echo "land-queue: recovered interrupted rebase from captured snapshot ticket=$ticket"
}

queue_request_snapshot_valid() {
  local request="$1" repo branch expected_head current_branch current_head dirty
  QUEUE_SNAPSHOT_ERROR=""
  repo="$(jq -r '.worktree' "$request")"
  branch="$(jq -r '.branch' "$request")"
  expected_head="$(jq -r '.head_sha' "$request")"
  if [[ ! -d "$repo" ]] && ! queue_restore_worktree "$request"; then return 1; fi
  if ! queue_recover_interrupted_rebase "$request"; then return 1; fi
  current_branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  current_head="$(git -C "$repo" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  if [[ "$current_branch" != "$branch" || "$current_head" != "$expected_head" ]]; then
    QUEUE_SNAPSHOT_ERROR="queued snapshot changed: branch=$current_branch head=$current_head"
    return 1
  fi
  dirty="$(git -C "$repo" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    QUEUE_SNAPSHOT_ERROR='queued worktree is dirty'
    return 1
  fi
}

queue_restore_worktree() {
  local request="$1" repo branch expected_head owner ticket source_repo branch_head
  repo="$(jq -r '.worktree' "$request")"
  branch="$(jq -r '.branch' "$request")"
  expected_head="$(jq -r '.head_sha' "$request")"
  owner="$(jq -r '.owner' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  source_repo="$(git -C "$AGENT_HOME/checkout" rev-parse --show-toplevel 2>/dev/null)" || {
    QUEUE_SNAPSHOT_ERROR='pipeline checkout unavailable to restore missing worktree'
    return 1
  }
  branch_head="$(git -C "$source_repo" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null || true)"
  if [[ -z "$branch_head" ]]; then
    QUEUE_SNAPSHOT_ERROR="queued branch no longer exists: branch=$branch"
    return 1
  fi
  if [[ "$branch_head" != "$expected_head" ]]; then
    QUEUE_SNAPSHOT_ERROR="queued branch moved: branch=$branch expected=$expected_head actual=$branch_head"
    return 1
  fi
  mkdir -p -- "$(dirname -- "$repo")" || {
    QUEUE_SNAPSHOT_ERROR="could not create parent for missing worktree: $repo"
    return 1
  }
  if ! git -C "$source_repo" worktree add --force --force --quiet "$repo" "$branch"; then
    QUEUE_SNAPSHOT_ERROR="could not recreate missing worktree from branch=$branch"
    return 1
  fi
  if ! queue_worktree_state "$repo" "$ticket" "$owner"; then
    QUEUE_SNAPSHOT_ERROR="could not lock recreated worktree: branch=$branch"
    return 1
  fi
}

queue_fetch_main() (
  queue_source_lib || return 1
  ZF_GIT_FETCH_TRANSIENT_RETRIES=0 git_fetch_bounded "$1" main
)

queue_fetch_main_with_retry() {
  local repo="$1" attempts attempt delay output status
  QUEUE_MAIN_FETCH_ATTEMPT_COUNT=0
  QUEUE_MAIN_FETCH_LAST_TRANSIENT=0
  QUEUE_MAIN_FETCH_LAST_ERROR=""
  [[ "$QUEUE_MAIN_FETCH_ATTEMPTS" =~ ^[1-9][0-9]*$ &&
    "$QUEUE_MAIN_FETCH_BACKOFF_SECONDS" =~ ^[0-9]+$ ]] || return 2
  attempts=$((10#$QUEUE_MAIN_FETCH_ATTEMPTS))
  delay=$((10#$QUEUE_MAIN_FETCH_BACKOFF_SECONDS))
  queue_source_lib || {
    QUEUE_MAIN_FETCH_LAST_ERROR='land-queue: failed to load lib.sh; refusing operation'
    return 1
  }
  output="$(mktemp)" || return 2
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    QUEUE_MAIN_FETCH_ATTEMPT_COUNT="$attempt"
    if queue_fetch_main "$repo" > "$output" 2>&1 &&
      git -C "$repo" rev-parse --verify origin/main^{commit} >/dev/null 2>&1; then
      cat "$output"; rm -f -- "$output"
      return 0
    else
      status=$?
    fi
    QUEUE_MAIN_FETCH_LAST_ERROR="$(cat "$output")"
    cat "$output" >&2
    if [[ "$status" == 124 || "$status" == 137 ]] || agent_fetch_failure_is_transient "$QUEUE_MAIN_FETCH_LAST_ERROR"; then
      QUEUE_MAIN_FETCH_LAST_TRANSIENT=1
    else
      QUEUE_MAIN_FETCH_LAST_TRANSIENT=0
      rm -f -- "$output"
      return "$status"
    fi
    if ((attempt < attempts)); then
      ((delay == 0)) || sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  rm -f -- "$output"
  return 1
}

queue_main_unavailable() {
  queue_retry_transient_lander_failure "$1" "origin/main unavailable after $2 attempts: ${QUEUE_MAIN_FETCH_LAST_ERROR:-no stderr}" ""
}

queue_run_lander() {
  local repo="$1" package="$2" output_file="$3" owner_issues
  owner_issues="$(jq -r '.owned_issues // ""' "$request")"
  shift 3
  if (cd -- "$repo" && AGENT_HOME="$AGENT_HOME" ZF_REPO_DIR="$repo" REPO_DIR="$repo" \
      ZF_LAND_RESULT_DIR="${result_dir:-}" \
      ZF_LAND_QUEUE_DIRECT=1 PLAN_PACKAGE="$package" ZF_AGENT_NAME="${ZF_AGENT_NAME:-${owner:-land-queue}}" \
      ZF_AGENT_ISSUES="$owner_issues" \
      ZF_AGENT_REPORT="${ZF_AGENT_REPORT:-${report:-}}" \
      bash "${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/land-direct-main.sh" "$@") >> "$output_file" 2>&1; then
    return 0
  else
    return $?
  fi
}

queue_log_reason() {
  awk 'NF {
    line=$0; gsub(/[\r\t]/, " ", line)
    if (rebase_apply == "" && match(line, /^error: could not apply [[:xdigit:]]+/))
      rebase_apply=substr(line, 8, RLENGTH - 7)
    if (line ~ /^land-direct-main: rebase conflict([; ]|$)/) rebase_conflict=1
    if (line ~ /^Push preflight passed: /) { hit=""; summary=""; timeout_summary="" }
    else if (line ~ /^land-direct-main: preflight failed / && line ~ /status=timed-out/) timeout_summary=line
    else if (line ~ /^Preflight command failed: / || line ~ /^land-direct-main: preflight failed /) summary=line
    else if (line ~ /(^|[[:space:]])(Error:|ERROR|not ok|DRIFT|BLOCKED-ON|[Ff]ailed|refus)/) hit=line
  }
  END {
    if (rebase_conflict && rebase_apply != "") line="rebase conflict: " rebase_apply
    else if (rebase_conflict) line="rebase conflict"
    else if (timeout_summary != "") line=timeout_summary
    else if (hit != "") line=hit
    else if (summary != "") line=summary
    sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
    print substr(line,1,240)
  }' "$1" 2>/dev/null
}

queue_log_findings() {
  awk '{
    for (i = 1; i <= NF; i++) {
      token = $i
      if (match(token, /^[^[:space:]]+\.[[:alnum:]]+:[0-9]+/)) {
        location = substr(token, RSTART, RLENGTH)
        if (!seen[location]++) print location
        break
      }
    }
  }' "$1" 2>/dev/null
}

queue_complete_request() {
  local request="$1" landed_sha="$2" outcome="${3:-}" report repo ticket owner event now enqueued_epoch duration
  report="$(jq -r '.report' "$request")"
  repo="$(jq -r '.worktree' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  owner="$(jq -r '.owner' "$request")"
  now="$(date +%s)"
  enqueued_epoch="$(jq -r '.enqueued_epoch // empty' "$request")"
  duration=""
  [[ "$enqueued_epoch" =~ ^[0-9]+$ ]] && duration=" enqueue_to_main_seconds=$((now - enqueued_epoch))"
  if [[ -n "$outcome" ]]; then event="LANDED $ticket $landed_sha $outcome$duration"; else event="LANDED $ticket $landed_sha$duration"; fi
  queue_unlock_worktree "$repo" || true
  queue_update_request "$request" landed "$outcome" "$landed_sha" "" "" "$now" || return 1
  queue_clear_conflict_resume_state "$owner" || return 1
  queue_report_landing_complete "$request" "$event" || return 1
}

queue_clear_conflict_resume_state() {
  local owner="$1" state_file lock_file lock_fd
  [[ "$owner" =~ ^[[:alnum:]_.-]+$ ]] || return 0
  state_file="$AGENT_HOME/night/land-queue/conflict-resumes/$owner.json"
  [[ -e "$state_file" ]] || return 0
  mkdir -p -- "$AGENT_HOME/locks" || return 1
  lock_file="$AGENT_HOME/locks/land-queue-conflict-$owner.lock"
  exec {lock_fd}>"$lock_file" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  rm -f -- "$state_file" || return 1
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
}

# The lander pushes after the fast blocking checks. Pipeline suites on the landed head are the
# post-merge verification (a red head reaches the main-red repair flow), so the queue only records
# the conclusion for the owner; there is no local verifier.
queue_conclude_landed() {
  local request="$1" ticket
  ticket="$(jq -r '.ticket' "$request")"
  [[ "$ticket" =~ ^[0-9]{20}$ ]] || return 0
  rm -rf -- "$QUEUE_DIR/results/$ticket"
  jq -e '.post_land_verdict? == null' "$request" >/dev/null 2>&1 || return 0
  queue_post_land_record result "$ticket" inconclusive verification-retired \
    || echo "land-queue: landing conclusion pending ticket=$ticket" >&2
}

queue_lander_process_matches() {
  local pid="$1" expected_ticks="$2" stat_line rest current_ticks
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_ticks" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
  IFS= read -r stat_line < "/proc/$pid/stat" || return 1
  rest="${stat_line##*) }"
  current_ticks="$(awk '{print $20}' <<< "$rest")"
  [[ "$current_ticks" == "$expected_ticks" ]]
}

queue_recover_direct_pending() {
  local request pid ticks repo base head main ticket errors=0 recovery_fd scan_pid scan_ticks
  local -a requests=("$@")
  for request in "${requests[@]}"; do
    jq -e '.direct_landing == true and .state == "direct-pending-push"' "$request" >/dev/null 2>&1 || continue
    pid="$(jq -r '.lander_pid' "$request")"
    ticks="$(jq -r '.lander_start_ticks' "$request")"
    queue_lander_process_matches "$pid" "$ticks" && continue
    scan_pid="$pid"
    scan_ticks="$ticks"
    repo="$(jq -r '.worktree' "$request")"
    [[ -d "$repo" ]] || repo="$AGENT_HOME/checkout"
    base="$(jq -r '.base_sha' "$request")"
    head="$(jq -r '.head_sha' "$request")"
    ticket="$(jq -r '.ticket' "$request")"
    if [[ ! -d "$repo" ]] || ! queue_fetch_main "$repo"; then
      errors=$((errors + 1))
      continue
    fi
    main="$(git -C "$repo" rev-parse --verify origin/main^{commit} 2>/dev/null || true)"
    exec {recovery_fd}>"$QUEUE_DIR/allocator.lock" || { errors=$((errors + 1)); continue; }
    if ! flock -x "$recovery_fd"; then
      exec {recovery_fd}>&-
      errors=$((errors + 1))
      continue
    fi
    pid="$(jq -r '.lander_pid // 0' "$request")"
    ticks="$(jq -r '.lander_start_ticks // 0' "$request")"
    if [[ "$pid" != "$scan_pid" || "$ticks" != "$scan_ticks" ]] || \
        ! jq -e --arg pid "$scan_pid" --arg ticks "$scan_ticks" \
        '.direct_landing == true and .state == "direct-pending-push" and (.lander_pid|tostring) == $pid and (.lander_start_ticks|tostring) == $ticks' \
        "$request" >/dev/null 2>&1 || queue_lander_process_matches "$pid" "$ticks"; then
      flock -u "$recovery_fd"
      exec {recovery_fd}>&-
      continue
    fi
    if [[ "$main" =~ ^[0-9a-f]{40}$ ]] && git -C "$repo" merge-base --is-ancestor "$head" "$main" 2>/dev/null; then
      queue_direct_landed "$ticket" "$base" "$head" || errors=$((errors + 1))
    else
      queue_direct_cancel "$ticket" 'interrupted before push reached origin/main' || errors=$((errors + 1))
    fi
    flock -u "$recovery_fd"
    exec {recovery_fd}>&-
  done
  printf '%s\n' "$errors"
}

queue_recover_landed_push() {
  local request="$1" result_dir ticket range_base range_head extra repo main landed_sha
  QUEUE_RECOVERED_LANDED=0
  ticket="$(jq -r '.ticket' "$request")"
  result_dir="$QUEUE_DIR/results/$ticket"
  [[ -r "$result_dir/range" ]] || return 0
  if ! read -r range_base range_head extra < "$result_dir/range" || \
      [[ ! "$range_base" =~ ^[0-9a-f]{40}$ || ! "$range_head" =~ ^[0-9a-f]{40}$ || -n "$extra" ]]; then
    return 0
  fi
  repo="$(jq -r '.worktree' "$request")"
  [[ -d "$repo" ]] || repo="$AGENT_HOME/checkout"
  [[ -d "$repo" ]] || return 0
  queue_fetch_main "$repo" || return 0
  main="$(git -C "$repo" rev-parse --verify origin/main^{commit} 2>/dev/null || true)"
  [[ "$main" =~ ^[0-9a-f]{40}$ ]] || return 0
  git -C "$repo" merge-base --is-ancestor "$range_head" "$main" 2>/dev/null || return 0
  landed_sha="$range_head"
  queue_complete_request "$request" "$landed_sha" 'lander exited after push; verification recovered' || return 1
  QUEUE_RECOVERED_LANDED=1
}

queue_register_dead_hand_owner() {
  local request="$1" owner report repo ticket metadata pid role brief log attempt start_ticks owned_issues owned_nodes
  local dependency="${2:-}" force="${3:-false}" current_metadata
  owner="$(jq -r '.owner' "$request")"
  report="$(jq -r '.report' "$request")"
  repo="$(jq -r '.owner_worktree // .worktree' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  if [[ "$(jq -r '.state' "$request")" != failed && "$force" != true ]] &&
      queue_hand_report_terminal "$report" && ! queue_hand_pending_addendum "$owner" "$report"; then
    return 0
  fi
  metadata="$(jq -c '.hand_owner_resume // empty' "$request")"
  current_metadata="$(queue_hand_owner_resume_metadata "$owner" "$repo" "$report")" || return 1
  metadata="$(jq -cn --argjson snapshot "${metadata:-null}" --argjson current "$current_metadata" \
    'if $snapshot == null and $current == null then null else ($snapshot // {}) + ($current // {}) end')" || return 1
  [[ "$metadata" != null ]] || { [[ "$force" != true ]] && return 0; return 1; }
  jq -e 'type == "object"' <<< "$metadata" >/dev/null 2>&1 || return 1
  pid="$(jq -r '.pid // empty' <<< "$metadata")"
  role="$(jq -r '.role // empty' <<< "$metadata")"
  brief="$(jq -r '.brief // empty' <<< "$metadata")"
  log="$(jq -r '.log // empty' <<< "$metadata")"
  attempt="$(jq -r '.attempt // 0' <<< "$metadata")"
  start_ticks="$(jq -r '.start_ticks // empty' <<< "$metadata")"
  owned_issues="$(jq -r '.owned_issues // empty' <<< "$metadata")"
  owned_nodes="$(jq -r '.owned_nodes // empty' <<< "$metadata")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[0-9]+$ && "$start_ticks" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$dependency" ]] || dependency="landing-failed $ticket"
  if [[ "$force" == true && ! -d "$repo" ]]; then
    queue_restore_worktree "$request" || return 1
    queue_unlock_worktree "$repo" || true
  fi
  source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
  [[ "$force" == true ]] || { hand_agent_pid_live "$pid" "$start_ticks" && return 0; }
  ZF_NIGHT_DIR="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" \
    blocked_hand_agent_upsert "$pid" "$owner" "$role" "$repo" "$brief" "$report" "$log" \
      "$attempt" "$dependency" "$start_ticks" "$owned_issues" "$owned_nodes" true
}

queue_conflict_paths() {
  local repo="$1" log="$2" paths
  paths="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [[ -n "$paths" ]]; then
    printf '%s\n' "$paths"
    return 0
  fi
  awk '/^CONFLICT \([^)]*\):/ {
    line = $0
    sub(/^CONFLICT \([^)]*\):[[:space:]]*/, "", line)
    if (sub(/^Merge conflict in /, "", line)) { print line; next }
    sub(/[[:space:]]+(deleted|modified|added|renamed) in .*/, "", line)
    sub(/[[:space:]]+and[[:space:]].*$/, "", line)
    if (line != "") print line
  }' "$log" 2>/dev/null | sort -u
}

queue_auto_resume_hand_rebase_conflict() (
  local request="$1" reason="$2" event="$3" findings="$4" log="$5"
  local owner ticket report repo role metadata state_dir state_file lock_file lock_fd first_ticket stored_attempt
  local paths candidate_head main_head base_head path commits commits_line addendum helper_output state_tmp attempt now
  [[ "$reason" =~ rebase.*conflict|conflict.*rebase ]] || return 1
  ticket="$(jq -r '.ticket' "$request")"
  owner="$(jq -r '.owner' "$request")"
  report="$(jq -r '.report' "$request")"
  repo="$(jq -r '.worktree' "$request")"
  metadata="$(jq -c '.hand_owner_resume // empty' "$request")"
  [[ -n "$metadata" && "$metadata" != null && "$owner" =~ ^[[:alnum:]_.-]+$ ]] || return 1
  role="$(jq -r '.role // empty' <<< "$metadata")"
  [[ "$role" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
  attempt="$(jq -r '.attempt // 0' <<< "$metadata")"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0

  state_dir="$AGENT_HOME/night/land-queue/conflict-resumes"
  state_file="$state_dir/$owner.json"
  lock_file="$AGENT_HOME/locks/land-queue-conflict-$owner.lock"
  mkdir -p -- "$state_dir" "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$lock_file" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }

  if [[ -r "$state_file" ]]; then
    first_ticket="$(jq -r '.ticket // empty' "$state_file" 2>/dev/null || true)"
    if [[ ! "$first_ticket" =~ ^[0-9]{20}$ ]]; then
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return 1
    fi
    if [[ "$first_ticket" != "$ticket" ]]; then
      stored_attempt="$(jq -r '.attempt // 0' "$state_file" 2>/dev/null || echo 0)"
      [[ "$stored_attempt" =~ ^[0-9]+$ ]] || stored_attempt=0
      if ((attempt <= stored_attempt)); then
        event+=$'\nAUTO-RESUME already scheduled; waiting for owner attempt greater than '
        event+="$stored_attempt"
        queue_report_status "$report" 'STATUS: IN_PROGRESS' "$event" || return 1
        queue_update_request "$request" failed "$reason" "" "" "" "$findings" || return 1
        flock -u "$lock_fd" || true
        exec {lock_fd}>&-
        return 0
      fi
      event+=$'\nREPEATED-REBASE-CONFLICT first_ticket='
      event+="$first_ticket repeat_ticket=$ticket"
      queue_report_status "$report" "STATUS: BLOCKED-ON landing-failed $ticket" "$event" || return 1
      queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
      queue_source_lib || return 1
      supervisor_inbox_append_once "landing-rebase-conflict-repeat:$owner" \
        "landing-rebase-conflict-repeat owner=$owner first_ticket=$first_ticket repeat_ticket=$ticket" || return 1
      queue_register_dead_hand_owner "$request" || return 1
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return 0
    fi
    event+=$'\nAUTO-RESUME already scheduled for landing ticket='
    event+="$ticket"
    queue_report_status "$report" 'STATUS: IN_PROGRESS' "$event" || return 1
    queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi

  paths="$(queue_conflict_paths "$repo" "$log")"
  candidate_head="$(jq -r '.head_sha // empty' "$request")"
  main_head="$(git -C "$repo" rev-parse --verify 'origin/main^{commit}' 2>/dev/null || true)"
  base_head=""
  if [[ "$candidate_head" =~ ^[0-9a-f]{40}$ && "$main_head" =~ ^[0-9a-f]{40}$ ]]; then
    base_head="$(git -C "$repo" merge-base "$candidate_head" "$main_head" 2>/dev/null || true)"
  fi
  mkdir -p -- "$QUEUE_DIR/logs" || return 1
  addendum="$(mktemp "$QUEUE_DIR/logs/.conflict-resume-$ticket.XXXXXX")" || return 1
  helper_output="$(mktemp "$QUEUE_DIR/logs/.conflict-resume-output-$ticket.XXXXXX")" || {
    rm -f -- "$addendum"
    return 1
  }
  {
    printf 'Landing ticket: %s\nCandidate HEAD: %s\norigin/main: %s\n' \
      "$ticket" "${candidate_head:-unknown}" "${main_head:-unknown}"
    printf 'Conflicting files:\n'
    if [[ -n "$paths" ]]; then
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf -- '- %s\n' "$path"
        if [[ -n "$base_head" ]]; then
          commits="$(git -C "$repo" log --format='%h %s' "$base_head..$main_head" -- "$path" 2>/dev/null || true)"
          if [[ -n "$commits" ]]; then
            printf '  origin/main commits touching this path since owner base:\n'
            while IFS= read -r commits_line; do printf '  - %s\n' "$commits_line"; done <<< "$commits"
          fi
        fi
      done <<< "$paths"
    else
      printf -- '- Paths unavailable; inspect %s\n' "$log"
    fi
    printf '\nResolve this conflict in the owner worktree. Rebase onto current origin/main and preserve both intents.\n'
    printf 'Run focused suites for the conflicting files, then node scripts/branch-delivery-preflight.mjs --mode commit.\n'
    printf 'Commit the repair, run bash engine/land-direct-main.sh --enqueue, and continue the owner brief.\n'
  } > "$addendum" || {
    rm -f -- "$addendum" "$helper_output"
    return 1
  }
  if ! bash "${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/night/brief-addendum.sh" "$owner" "$addendum" "$role" \
      > "$helper_output" 2>&1; then
    [[ -n "$log" ]] && cat "$helper_output" >> "$log"
    rm -f -- "$addendum" "$helper_output"
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 1
  fi
  [[ -n "$log" ]] && cat "$helper_output" >> "$log"
  rm -f -- "$addendum" "$helper_output"
  now="$(date +%s)"
  state_tmp="$(mktemp "$state_file.XXXXXX")" || return 1
  if ! jq -n --arg owner "$owner" --arg ticket "$ticket" --argjson attempt "$attempt" --argjson now "$now" \
      '{owner:$owner,ticket:$ticket,attempt:$attempt,created_epoch:$now}' > "$state_tmp" || ! mv -f -- "$state_tmp" "$state_file"; then
    rm -f -- "$state_tmp"
    queue_source_lib || return 1
    supervisor_inbox_append_once "landing-conflict-resume-state-failed:$owner:$ticket" \
      "landing-conflict-resume-state-failed owner=$owner ticket=$ticket; addendum scheduled but recurrence state could not be saved" || return 1
    event+=$'\nAUTO-RESUME scheduled for rebase-conflict landing ticket='
    event+="$ticket"
    queue_report_status "$report" 'STATUS: IN_PROGRESS' "$event" || return 1
    queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi
  event+=$'\nAUTO-RESUME scheduled for rebase-conflict landing ticket='
  event+="$ticket"
  queue_report_status "$report" 'STATUS: IN_PROGRESS' "$event" || return 1
  queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return 0
)

queue_failure() {
  local request="$1" reason="$2" log="${3:-}" owner report ticket repo findings='[]' finding_text event
  ticket="$(jq -r '.ticket' "$request")"
  owner="$(jq -r '.owner' "$request")"
  report="$(jq -r '.report' "$request")"
  repo="$(jq -r '.worktree' "$request")"
  reason="$(printf '%s' "$reason" | tr '\r\n\t' '   ' | cut -c1-240)"
  [[ -n "$reason" ]] || reason='landing unit failed'
  if [[ -r "$log" ]]; then
    findings="$(queue_log_findings "$log" | jq -Rsc 'split("\n") | map(select(length > 0))')" || findings='[]'
  fi
  event="LANDING-FAILED $ticket $reason"
  if jq -e 'length > 0' <<< "$findings" >/dev/null; then
    finding_text="$(jq -r '.[] | "- " + .' <<< "$findings")"
    event+=$'\nFindings (file:line):\n'"$finding_text"
  fi
  local snapshot_pid current_pid owner_repo
  snapshot_pid="$(jq -r '.hand_owner_resume.pid // empty' "$request")"
  owner_repo="$(jq -r '.owner_worktree // .worktree' "$request")"
  current_pid="$(queue_hand_owner_resume_metadata "$owner" "$owner_repo" "$report" | jq -r '.pid // empty')" || return 1
  if [[ -n "$snapshot_pid" && -n "$current_pid" && "$snapshot_pid" != "$current_pid" ]]; then
    queue_report_event "$report" "$event" || return 1
    queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
    if queue_source_lib; then
      supervisor_inbox_append landing-failed "owner=$owner ticket=$ticket reason=$reason newer_dispatch_pid=$current_pid" || return 1
    fi
    return 0
  fi
  if queue_auto_resume_hand_rebase_conflict "$request" "$reason" "$event" "$findings" "$log"; then
    return 0
  fi
  queue_report_status "$report" "STATUS: BLOCKED-ON landing-failed $ticket" "$event" || return 1
  export AGENT_HOME
  if queue_source_lib; then
    supervisor_inbox_append landing-failed "owner=$owner ticket=$ticket reason=$reason" || return 1
  fi
  queue_update_request "$request" failed "$reason" "" "" "" "" "$findings" || return 1
  local registry="$AGENT_HOME/night/hand-registry/$owner.json" registry_tmp
  if [[ -r "$registry" ]]; then
    registry_tmp="$(mktemp "$registry.XXXXXX")" || return 1
    jq --arg status "BLOCKED-ON landing-failed $ticket" '.landing_status=$status' "$registry" > "$registry_tmp" \
      && mv -f -- "$registry_tmp" "$registry" || { rm -f -- "$registry_tmp"; return 1; }
  fi
  queue_register_dead_hand_owner "$request" || {
    printf 'land-queue: failed to register exited hand owner=%s ticket=%s\n' "$owner" "$ticket" >&2
    return 1
  }
  # Keep the worktree lock. The night tick resumes this owner in the same tree.
}

queue_lander_failure_is_transient() {
  local request="$1" log="$2" outcome
  [[ -r "$log" ]] || return 1
  # This is the FIFO lock sequence, not the land-queue ticket. Log belongs to one request.
  outcome="$(grep -E '^land-direct-main: lock-released ticket=[0-9]+ hold_ms=[0-9]+ outcome=' "$log" | tail -1)"
  if [[ -n "$outcome" ]]; then
    if [[ ! "$outcome" =~ outcome=(fetch-failed|fetch-after-push-failed|push-failed)$ ]]; then
      [[ "$outcome" == *'outcome=exit' ]] && \
        grep -Fq 'land-direct-main: could not fetch origin/main before preflight' "$log" || return 1
    fi
  else
    grep -Fq 'land-direct-main: could not fetch origin/main before preflight' "$log" || return 1
  fi
  queue_source_lib || return 1
  agent_transport_is_transient "$(cat "$log")" || agent_ref_update_race_is_transient "$(cat "$log")" || \
    grep -q '^git fetch: timed out after ' "$log"
}

queue_retry_transient_lander_failure() {
  local request="$1" reason="$2" log="$3" ticket report previous attempts delay now retry_after tmp reason_file first head repo
  [[ "$QUEUE_TRANSIENT_ALERT_SECONDS" =~ ^[0-9]+$ &&
    "$QUEUE_TRANSIENT_BACKOFF_SECONDS" =~ ^[0-9]+$ &&
    "$QUEUE_TRANSIENT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || return 2
  ticket="$(jq -r '.ticket' "$request")"
  report="$(jq -r '.report' "$request")"
  repo="$(jq -r '.worktree' "$request")"
  head="$(git -C "$repo" rev-parse --verify HEAD^{commit})" || return 2
  previous="$(jq -r '.transient_failure_attempts // 0' "$request")"
  [[ "$previous" =~ ^[0-9]+$ ]] || previous=0
  attempts=$((10#$previous + 1))
  reason="$(printf '%s' "$reason" | tr '\r\n\t' '   ' | cut -c1-200)"
  [[ -n "$reason" ]] || reason='transient GitHub transport failure'
  case "$attempts" in
    1) delay=$((10#$QUEUE_TRANSIENT_BACKOFF_SECONDS)) ;;
    2) delay=$((10#$QUEUE_TRANSIENT_BACKOFF_SECONDS * 2)) ;;
    3) delay=$((10#$QUEUE_TRANSIENT_BACKOFF_SECONDS * 5)) ;;
    *) delay=$((10#$QUEUE_TRANSIENT_BACKOFF_SECONDS * 10)) ;;
  esac
  ((delay <= 600)) || delay=600
  now="$(date +%s)"
  first="$(jq -r '.transient_failure_first_epoch // empty' "$request")"
  [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
  queue_source_lib || return 2
  if ((attempts >= 10#$QUEUE_TRANSIENT_MAX_ATTEMPTS)); then
    tmp="$(mktemp "${request}.XXXXXX")" || return 2
    jq --argjson attempts "$attempts" --argjson first "$first" --argjson elapsed "$((now - first))" \
      '.transient_failure_attempts=$attempts | .transient_failure_first_epoch=$first
       | .transient_failure_elapsed_seconds=$elapsed | del(.retry_after_epoch)' "$request" > "$tmp" \
      && mv -f -- "$tmp" "$request" || { rm -f -- "$tmp"; return 2; }
    printf 'land-queue: transient-exhausted ticket=%s attempts=%s elapsed_s=%s reason=%s\n' \
      "$ticket" "$attempts" "$((now - first))" "$reason" >&2
    queue_failure "$request" "transient-exhausted attempts=$attempts elapsed_s=$((now - first)): $reason" "$log" || return 2
    return 1
  fi
  retry_after=$((now + delay))
  reason_file="$(jq_arg_file "$reason")" || return 2
  tmp="$(mktemp "${request}.XXXXXX")" || { rm -f -- "$reason_file"; return 2; }
  if ! jq --rawfile reason "$reason_file" --arg head "$head" --argjson now "$now" --argjson attempts "$attempts" \
      --argjson first "$first" --argjson retry_after "$retry_after" \
      '.state="queued" | .updated_epoch=$now | .reason=$reason | .head_sha=$head
       | .transient_failure_attempts=$attempts | .transient_failure_first_epoch=$first
       | .retry_after_epoch=$retry_after | del(.finished_epoch,.findings)' \
      "$request" > "$tmp"; then
    rm -f -- "$tmp" "$reason_file"
    return 2
  fi
  rm -f -- "$reason_file"
  chmod --reference="$request" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$request" || return 2
  queue_report_status "$report" "STATUS: LANDING-QUEUED $ticket" \
    "LANDING-RETRY $ticket attempt=$attempts/$QUEUE_TRANSIENT_MAX_ATTEMPTS backoff_s=$delay elapsed_s=$((now - first)) retry_after=$retry_after reason=$reason" || return 2
  # A transport outage alerts once while retries remain; only exhausted requests become terminal.
  if ((now - first >= 10#$QUEUE_TRANSIENT_ALERT_SECONDS)); then
    supervisor_inbox_append_once landing-queue-transport-outage \
      "landing-queue-transport-outage queue=land-direct-main retries=queued since=$first reason=$reason" || return 2
  fi
  queue_refresh_health_summary || echo 'land-queue: could not refresh HEALTH summary after transient retry' >&2
  printf 'land-queue: requeued transient landing ticket=%s attempt=%s/%s backoff_s=%s elapsed_s=%s retry_after=%s\n' \
    "$ticket" "$attempts" "$QUEUE_TRANSIENT_MAX_ATTEMPTS" "$delay" "$((now - first))" "$retry_after"
}

# Explicit recovery of the lander's completed rebase, never an arbitrary moved snapshot.
queue_requeue_completed_rebase() (
  local request="$1" owner="$2" episode="$3" original="$4" request_fd ticket repo branch head baseline
  local registry pid ticks log reflog locked reason lock_pid unit_state unit_pid patches tmp now live source_repo
  [[ -r "$request" && "$owner" =~ ^hand-[a-zA-Z0-9_.-]+$ && "$episode" =~ ^[0-9]+$ && "$original" =~ ^[0-9a-f]{40}$ ]] || return 2
  exec {request_fd}>"$request.lock" || return 1
  flock -n "$request_fd" || return 1
  ticket="$(jq -r '.ticket' "$request")"
  [[ "$ticket" =~ ^[0-9]{20}$ && "$request" == "$REQUEST_DIR/$ticket.json" ]] || return 2
  jq -e --arg owner "$owner" --arg episode "$episode" --arg head "$original" \
    '.state == "failed" and .owner == $owner and .head_sha == $head
     and .hand_owner_resume.name == $owner
     and (.hand_owner_resume.provider_episode | tostring) == $episode' "$request" >/dev/null || return 2
  repo="$(jq -r '.worktree' "$request")"
  branch="$(jq -r '.branch' "$request")"
  [[ "$repo" == "$QUEUE_DIR/worktrees/$ticket" && "$branch" == "land-queue/$ticket" ]] || return 2
  registry="$AGENT_HOME/night/hand-registry/$owner.json"
  jq -e --slurpfile request "$request" \
    '.name == $request[0].owner and .provider_episode == $request[0].hand_owner_resume.provider_episode
     and .pid == $request[0].hand_owner_resume.pid
     and .start_ticks == $request[0].hand_owner_resume.start_ticks
     and .worktree == $request[0].owner_worktree' "$registry" >/dev/null || return 2
  pid="$(jq -r '.pid' "$registry")"
  ticks="$(jq -r '.start_ticks' "$registry")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[0-9]+$ && ! -e "/proc/$pid" ]] || return 2
  unit_state="$(systemctl --user show "${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket" --property=ActiveState --value)" || return 2
  unit_pid="$(systemctl --user show "${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket" --property=MainPID --value)" || return 2
  [[ "$unit_state" == inactive && "$unit_pid" == 0 ]] || return 2
  source_repo="$(jq -r '.owner_worktree' "$request")"
  source "$SCRIPT_DIR/hand-codex-liveness.sh" || return 2
  live="$(hand_codex_worktrees /)" || return 2
  if grep -Fqx -- "$source_repo" <<< "$live" || grep -Fqx -- "$repo" <<< "$live"; then return 2; fi
  head="$(git -C "$repo" rev-parse HEAD)" || return 2
  [[ "$head" != "$original" && "$(git -C "$repo" branch --show-current)" == "$branch" &&
     -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ]] || return 2
  [[ "$(jq -r '.reason' "$request")" == "queued snapshot changed: branch=$branch head=$head" ]] || return 2
  locked="$(git -C "$repo" rev-parse --git-path locked)" || return 2
  [[ "$locked" == /* ]] || locked="$repo/$locked"
  reason="$(cat "$locked")" || return 2
  [[ "$reason" =~ ^land-direct-main:ticket=([0-9]{20})[[:space:]]owner=([a-zA-Z0-9_.-]+)[[:space:]]owner_pid=([1-9][0-9]*)[[:space:]]owner_start_ticks=[0-9]+[[:space:]]unit=(${UNIT_PREFIX_TRANSIENT}-land-direct-main-[0-9]{20})$ ]] || return 2
  [[ "${BASH_REMATCH[1]}" == "$ticket" && "${BASH_REMATCH[2]}" == "$owner" && "${BASH_REMATCH[4]}" == "${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket" ]] || return 2
  lock_pid="${BASH_REMATCH[3]}"
  [[ ! -e "/proc/$lock_pid" ]] || return 2
  log="$QUEUE_DIR/logs/$ticket.log"
  baseline="$(sed -n "s/^land-direct-main: preflight baseline-sha=\([0-9a-f]\{40\}\) head=$head$/\1/p" "$log")" || return 2
  [[ "$baseline" =~ ^[0-9a-f]{40}$ ]] || return 2
  reflog="$(git -C "$repo" reflog show -n 2 --format='%H %gs' "$branch")" || return 2
  # shortcut: one captured commit and one completed rebase; require separate attribution before supporting longer histories.
  [[ "$(head -n 1 <<< "$reflog")" == "$head rebase (finish): refs/heads/$branch onto $baseline" &&
     "$(tail -n 1 <<< "$reflog")" == "$original branch: Created from $original" ]] || return 2
  [[ "$(git -C "$repo" rev-parse "$head^")" == "$baseline" ]] || return 2
  patches="$(git -C "$repo" cherry "$head" "$original")" || return 2
  [[ "$patches" == "- $original" ]] || return 2
  (cd "$repo" && node scripts/branch-delivery-policy.mjs --check-direct-main-lane) || return 2
  now="$(date +%s)"
  tmp="$(mktemp "${request}.XXXXXX")" || return 1
  jq --arg head "$head" --arg original "$original" --arg baseline "$baseline" --arg episode "$episode" --argjson now "$now" \
    '.completed_rebase_recovery={original_head:$original,original_failure:.reason,baseline:$baseline,episode:$episode,at:$now}
     | .state="queued" | .head_sha=$head | .updated_epoch=$now
     | .reason="operator verified completed own rebase" | del(.finished_epoch,.findings,.retry_after_epoch)' \
    "$request" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$request" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$request" || return 1
  queue_report_status "$(jq -r '.report' "$request")" "STATUS: LANDING-QUEUED $ticket" \
    "LANDING-RECOVERED $ticket completed-own-rebase original=$original head=$head baseline=$baseline episode=$episode"
)

# Explicit operator recovery for tickets failed by older consumers. Never reset a moved branch.
queue_requeue_failed_transient() {
  local request="$1" defer="${2:-600}" request_fd ticket repo head original patches tmp
  [[ "$defer" =~ ^[0-9]+$ && -r "$request" ]] || return 2
  exec {request_fd}>"$request.lock" || return 1
  flock -n "$request_fd" || return 1
  [[ "$(jq -r '.state' "$request")" == failed ]] || return 0
  ticket="$(jq -r '.ticket' "$request")"
  queue_lander_failure_is_transient "$request" "$QUEUE_DIR/logs/$ticket.log" || return 2
  repo="$(jq -r '.worktree' "$request")"
  original="$(jq -r '.head_sha' "$request")"
  head="$(git -C "$repo" rev-parse --verify HEAD^{commit})" || return 2
  # A successful rebase changes SHA. All original patches must still exist in current HEAD.
  if [[ "$head" != "$original" ]]; then
    patches="$(git -C "$repo" cherry "$head" "$original")" || return 2
    if grep -q '^+' <<< "$patches"; then
      echo "land-queue: cannot recover changed snapshot ticket=$ticket" >&2
      return 2
    fi
  fi
  [[ "$(git -C "$repo" branch --show-current)" == "$(jq -r '.branch' "$request")" &&
     -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ]] || return 2
  (cd "$repo" && node scripts/branch-delivery-policy.mjs --check-direct-main-lane) || return 2
  queue_worktree_state "$repo" "$ticket" "$(jq -r '.owner' "$request")" || return 1
  QUEUE_TRANSIENT_BACKOFF_SECONDS="$defer" queue_retry_transient_lander_failure "$request" 'operator restored transient failure from older consumer' "" || return 1
  tmp="$(mktemp "${request}.XXXXXX")" || return 1
  jq --arg original "$original" --argjson defer "$defer" \
    '.transient_recovery_original_head=$original | .retry_after_epoch=(.updated_epoch + $defer)' "$request" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$request" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$request"
}

queue_pr_refusal_fail() {
  local reason="$1" tmp="${2:-}"
  QUEUE_PR_FAILURE_REASON="$reason"
  [[ -z "$tmp" ]] || rm -rf -- "$tmp"
  printf 'land-queue: lane-refusal PR fallback failed: %s\n' "$reason" >&2
  return 1
}

queue_open_pr_after_lane_refusal() {
  local request="$1" repo="$2" branch="$3" report="$4" package="$5"
  local base tmp sequence_editor message_editor existing_pr remote_line remote_sha lease head_package title url pr body
  QUEUE_PR_FAILURE_REASON=""
  QUEUE_PR_NUMBER=""
  [[ "$(git -C "$repo" branch --show-current 2>/dev/null || true)" == "$branch" ]] \
    || { QUEUE_PR_FAILURE_REASON='worktree branch changed'; return 1; }
  branch="$(jq -r '.owner_branch // .branch' "$request")"
  [[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ]] \
    || { QUEUE_PR_FAILURE_REASON='worktree has uncommitted changes'; return 1; }
  base="$(git -C "$repo" rev-parse --verify 'origin/main^{commit}' 2>/dev/null)" \
    || { QUEUE_PR_FAILURE_REASON='origin/main is unavailable'; return 1; }
  git -C "$repo" merge-base --is-ancestor "$base" HEAD \
    || { QUEUE_PR_FAILURE_REASON='origin/main is not an ancestor of the branch'; return 1; }

  export ZF_REPO_DIR="$repo" REPO_DIR="$repo"
  queue_source_lib || { QUEUE_PR_FAILURE_REASON='could not load guarded_write'; return 1; }
  existing_pr="$(gh pr list --repo "$REPO" --state open --head "$branch" --json number --jq '.[0].number // empty')" \
    || { QUEUE_PR_FAILURE_REASON='could not query existing branch PR'; return 1; }
  [[ -z "$existing_pr" || "$existing_pr" =~ ^[0-9]+$ ]] \
    || { QUEUE_PR_FAILURE_REASON='existing branch PR number is invalid'; return 1; }

  tmp="$(mktemp -d "$QUEUE_DIR/pr-fallback.XXXXXX")" \
    || { QUEUE_PR_FAILURE_REASON='could not create temporary PR workspace'; return 1; }
  sequence_editor="$tmp/sequence-editor"
  message_editor="$tmp/message-editor"
  cat > "$sequence_editor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
todo="$1"
tmp="${todo}.land-queue"
awk '
  /^pick [0-9a-f]+ / {
    subject=$0
    sub(/^pick [0-9a-f]+ /, "", subject)
    if (subject == "[skip ci] fold merged lesson fragments" || subject == "fold merged lesson fragments" ||
        subject == "[skip ci] assign merged lesson IDs" || subject == "assign merged lesson IDs") {
      sub(/^pick /, "drop ")
    } else if (subject ~ /^\[skip ci\] /) {
      sub(/^pick /, "reword ")
    }
  }
  { print }
' "$todo" > "$tmp"
mv -- "$tmp" "$todo"
EOF
  cat > "$message_editor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
message="$1"
tmp="${message}.land-queue"
sed '1s/^\[skip ci\] //' "$message" > "$tmp"
mv -- "$tmp" "$message"
EOF
  chmod +x "$sequence_editor" "$message_editor" \
    || { queue_pr_refusal_fail 'could not prepare commit rewrite' "$tmp"; return 1; }
  if ! GIT_SEQUENCE_EDITOR="$sequence_editor" GIT_EDITOR="$message_editor" \
      git -C "$repo" rebase -i --rebase-merges --onto "$base" "$base"; then
    queue_pr_refusal_fail 'could not rewrite branch commits' "$tmp"
    return 1
  fi
  if git -C "$repo" log --format=%s "$base..HEAD" | grep -Fq '[skip ci]'; then
    queue_pr_refusal_fail 'a skip-ci annotation remains in a PR commit subject' "$tmp"
    return 1
  fi
  if git -C "$repo" log --format=%s "$base..HEAD" | grep -Eq '^(fold merged lesson fragments|assign merged lesson IDs)$'; then
    queue_pr_refusal_fail 'a landing-only commit remains on the PR branch' "$tmp"
    return 1
  fi
  [[ "$(git -C "$repo" rev-list --count "$base..HEAD")" -gt 0 ]] \
    || { queue_pr_refusal_fail 'no hand commits remain for the PR' "$tmp"; return 1; }

  head_package="$(git -C "$repo" show -s --format='%(trailers:key=Plan-Package,valueonly)' HEAD | sed -n '1p')"
  if [[ "$head_package" != "$package" ]]; then
    git -C "$repo" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' \
      commit --amend --no-edit --trailer "Plan-Package: $package" >/dev/null \
      || { queue_pr_refusal_fail 'could not preserve Plan-Package trailer' "$tmp"; return 1; }
  fi
  title="$(git -C "$repo" log --reverse --format=%s "$base..HEAD" | sed -n '1p')"
  [[ -n "$title" ]] || { queue_pr_refusal_fail 'could not read first PR commit subject' "$tmp"; return 1; }
  remote_line="$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch")" \
    || { queue_pr_refusal_fail 'could not read remote branch before force-with-lease push' "$tmp"; return 1; }
  remote_sha="${remote_line%%$'\t'*}"
  if [[ -n "$remote_sha" && ! "$remote_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    queue_pr_refusal_fail 'remote branch SHA is invalid' "$tmp"
    return 1
  fi
  lease="refs/heads/$branch:$remote_sha"
  if ! guarded_write git -C "$repo" push "--force-with-lease=$lease" origin "HEAD:refs/heads/$branch"; then
    queue_pr_refusal_fail 'force-with-lease branch push failed' "$tmp"
    return 1
  fi

  body="$tmp/pr-body.md"
  printf '%s\n\nlane refusal: opened as PR by land-queue\n\nPlan-Package: %s\n' "$report" "$package" \
    | scrub_closing_keywords > "$body" \
    || { queue_pr_refusal_fail 'could not write PR body' "$tmp"; return 1; }
  if [[ -n "$existing_pr" ]]; then
    pr="$existing_pr"
    if ! guarded_write gh pr edit "$pr" --repo "$REPO" --title "$title" --body-file "$body"; then
      queue_pr_refusal_fail 'could not update existing branch PR' "$tmp"
      return 1
    fi
  else
    url="$(guarded_write gh pr create --repo "$REPO" --base main --head "$branch" \
      --title "$title" --body-file "$body")" \
      || { queue_pr_refusal_fail 'gh pr create failed' "$tmp"; return 1; }
    pr="${url##*/}"
    [[ "$pr" =~ ^[0-9]+$ ]] \
      || { queue_pr_refusal_fail 'gh pr create returned no PR number' "$tmp"; return 1; }
  fi
  rm -rf -- "$tmp"
  queue_report_status "$report" 'STATUS: DONE' "PR-OPENED #$pr $branch" \
    || { QUEUE_PR_FAILURE_REASON='could not update owner report'; return 1; }
  queue_update_request "$request" pr-opened 'lane refusal: opened as PR by land-queue' '' '' "$pr" \
    || { QUEUE_PR_FAILURE_REASON='could not record opened PR'; return 1; }
  queue_unlock_worktree "$repo" || true
  QUEUE_PR_NUMBER="$pr"
}

queue_run() {
  local request="$1" repo owner report package log status reason landed_sha ticket branch request_fd expected_head current_head main_head result_dir retry_after now range_base range_head range_extra transient_failure=0
  local snapshot_owner_pid current_owner_pid owner_repo
  [[ -f "$request" ]] || { echo "land-queue: request not found: $request" >&2; return 2; }
  jq -e 'type=="object" and (.ticket|type=="string") and (.owner|type=="string") and (.branch|type=="string") and (.head_sha|type=="string") and (.worktree|type=="string") and (.report|type=="string") and (.plan_package|type=="string")' "$request" >/dev/null \
    || { echo "land-queue: invalid request: $request" >&2; return 2; }
  exec {request_fd}>"$request.lock" || return 1
  flock -n "$request_fd" || return 0
  [[ "$(jq -r '.state // "invalid"' "$request")" == queued ]] || return 0
  retry_after="$(jq -r '.retry_after_epoch // 0' "$request")"
  [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=0
  now="$(date +%s)"
  if ((retry_after > now)); then
    printf 'land-queue: retry deferred ticket=%s retry_after=%s\n' "$(jq -r '.ticket' "$request")" "$retry_after"
    return 0
  fi

  # Legacy requests are migrated too; their producer may have moved on since enqueue.
  if ! queue_isolate_request "$request"; then
    queue_failure "$request" 'could not isolate landing snapshot'
    return 1
  fi
  repo="$(jq -r '.worktree' "$request")"
  owner="$(jq -r '.owner' "$request")"
  report="$(jq -r '.report' "$request")"
  package="$(jq -r '.plan_package' "$request")"
  ticket="$(jq -r '.ticket' "$request")"
  branch="$(jq -r '.branch' "$request")"
  queue_update_request "$request" running || return 1
  snapshot_owner_pid="$(jq -r '.hand_owner_resume.pid // empty' "$request")"
  owner_repo="$(jq -r '.owner_worktree // .worktree' "$request")"
  current_owner_pid="$(queue_hand_owner_resume_metadata "$owner" "$owner_repo" "$report" | jq -r '.pid // empty')" || return 1
  if [[ -z "$snapshot_owner_pid" || -z "$current_owner_pid" || "$snapshot_owner_pid" == "$current_owner_pid" ]]; then
    queue_report_status "$report" 'STATUS: LANDING' || return 1
  fi
  if ! queue_request_snapshot_valid "$request"; then
    queue_failure "$request" "$QUEUE_SNAPSHOT_ERROR"
    return 1
  fi
  if ! queue_fetch_main_with_retry "$repo"; then
    if [[ "$QUEUE_MAIN_FETCH_LAST_TRANSIENT" == 1 ]]; then
      queue_main_unavailable "$request" "$QUEUE_MAIN_FETCH_ATTEMPT_COUNT" || \
        echo 'land-queue: could not record origin/main outage recovery' >&2
    else
      queue_failure "$request" "origin/main fetch refused: ${QUEUE_MAIN_FETCH_LAST_ERROR:-missing origin/main ref}" "" || return 1
    fi
    return 1
  fi

  result_dir="$QUEUE_DIR/results/$ticket"
  if [[ -r "$result_dir/range" ]]; then
    if read -r range_base range_head range_extra < "$result_dir/range" && \
        [[ "$range_base" =~ ^[0-9a-f]{40}$ && "$range_head" =~ ^[0-9a-f]{40}$ && -z "$range_extra" ]] && \
        git -C "$repo" merge-base --is-ancestor "$range_head" origin/main 2>/dev/null; then
      queue_complete_request "$request" "$range_head" 'retry recovered prior push on origin/main' || return 1
      queue_conclude_landed "$request"
      return 0
    fi
    rm -rf -- "$result_dir"
  fi

  mkdir -p -- "$QUEUE_DIR/logs" || return 1
  log="$QUEUE_DIR/logs/$ticket.log"
  result_dir="$QUEUE_DIR/results/$ticket"
  mkdir -p -- "$result_dir" || return 1
  : > "$log" || return 1
  if ZF_LAND_QUEUE_TICKET="$ticket" queue_run_lander "$repo" "$package" "$log"; then
    landed_sha="$(git -C "$repo" rev-parse --verify HEAD^{commit})" || return 1
    queue_complete_request "$request" "$landed_sha"
    printf 'land-queue: landed ticket=%s sha=%s\n' "$ticket" "$landed_sha"
    queue_conclude_landed "$request"
    return 0
  else
    status=$?
  fi

  # Classify the lander's result before a verification fetch can add unrelated transport errors.
  reason="$(queue_log_reason "$log")"
  [[ -n "$reason" ]] || reason="land-direct-main exit=$status"
  if queue_lander_failure_is_transient "$request" "$log"; then transient_failure=1; fi
  expected_head="$(jq -r '.head_sha' "$request")"
  if queue_fetch_main_with_retry "$repo" >> "$log" 2>&1; then
    current_head="$(git -C "$repo" rev-parse --verify HEAD^{commit})" || return 1
    main_head="$(git -C "$repo" rev-parse --verify origin/main^{commit})" || return 1
    # A rebased landing whose push is main's tip has current == main; the
    # lander's own "pushed" line tells that apart from a tree reset to main
    # (landing 267 pushed, then failed a post-push dispatch and read as failed).
    if git -C "$repo" merge-base --is-ancestor "$expected_head" "$main_head" || {
      { [[ "$current_head" != "$main_head" ]] || grep -Fqx "land-direct-main: pushed $branch to main" "$log"; } \
        && git -C "$repo" merge-base --is-ancestor "$current_head" "$main_head"
    }; then
      landed_sha="$current_head"
      queue_complete_request "$request" "$landed_sha" 'lander exited after push; verified on origin/main'
      printf 'land-queue: landed ticket=%s sha=%s (verified after lander exit %s)\n' "$ticket" "$landed_sha" "$status"
      queue_conclude_landed "$request"
      return 0
    fi
  else
    if ((transient_failure)); then
      queue_retry_transient_lander_failure "$request" "$reason" "$log"
      return $?
    fi
    queue_failure "$request" "${reason:-land-direct-main exit=$status}" "$log"
    return "$status"
  fi

  if [[ "$reason" == 'land-direct-main: preflight did not select a direct-main flow; paths outside the pipeline/docs lane go through a PR' ]]; then
    if queue_open_pr_after_lane_refusal "$request" "$repo" "$branch" "$report" "$package"; then
      rm -rf -- "$result_dir"
      return 0
    fi
    reason="lane refusal PR fallback failed: ${QUEUE_PR_FAILURE_REASON:-unknown fallback error}"
  fi
  if ((transient_failure)); then
    rm -rf -- "$result_dir"
    queue_retry_transient_lander_failure "$request" "$reason" "$log"
    return $?
  fi
  rm -rf -- "$result_dir"
  queue_failure "$request" "$reason" "$log"
  return "$status"
}

queue_finish_deferred_owner() {
  local owner="$1" request outcome status tmp jq_filter
  local -a requests=()
  [[ "$owner" =~ ^[[:alnum:]_.-]+$ ]] || return 2
  [[ -d "$REQUEST_DIR" ]] || return 0
  queue_source_lib || return 1
  shopt -s nullglob
  requests=("$REQUEST_DIR"/*.json)
  shopt -u nullglob
  for request in "${requests[@]}"; do
    jq -e --arg owner "$owner" '
      .state == "landed" and .owner == $owner and
      .post_land_conclusion_pending == true and .post_land_conclusion_deferred == true and
      .post_land_conclusion_exit_checked != true
    ' "$request" >/dev/null 2>&1 || continue
    outcome="$(jq -r '.post_land_verdict.outcome // empty' "$request")"
    if pipeline_system_finish_direct_landing "$request" "$outcome" exit; then
      jq_filter='.post_land_conclusion_recorded=true | del(.post_land_conclusion_pending, .post_land_conclusion_deferred, .post_land_conclusion_exit_checked, .post_land_conclusion_error)'
    else
      status=$?
      if [[ "$status" == 2 ]]; then
        jq_filter='.post_land_conclusion_exit_checked=true'
      else
        return 1
      fi
    fi
    tmp="$(mktemp "${request}.XXXXXX")" || return 1
    jq "$jq_filter" "$request" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod --reference="$request" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$request" || return 1
  done
  queue_refresh_health_summary || return 1
}

queue_recover_pending_conclusions() {
  local request ticket outcome failure_stage errors=0
  local -a requests=("$@")
  for request in "${requests[@]}"; do
    jq -e '.state == "landed" and .post_land_verdict? != null and .lesson_metadata_fix_forward.owner_queued != true and
      .post_land_conclusion_deferred != true and
      ((.post_land_conclusion_pending? == true) or (.post_land_conclusion_recorded? != true))' \
      "$request" >/dev/null 2>&1 || continue
    ticket="$(jq -r '.ticket // empty' "$request")"
    outcome="$(jq -r '.post_land_verdict.outcome // empty' "$request")"
    failure_stage="$(jq -r '.post_land_verdict.failure_stage // empty' "$request")"
    if [[ ! "$ticket" =~ ^[0-9]{20}$ ]] || ! queue_post_land_record result "$ticket" "$outcome" "$failure_stage"; then
      errors=$((errors + 1))
    fi
  done
  printf '%s\n' "$errors"
}

queue_recovery_progress() {
  printf 'land-queue-recovery: at=%s stage=%s started=%s errors=%s\n' "$EPOCHREALTIME" "$1" "$2" "$3" >&2
}

queue_recover() {
  local request state unit ticket result_dir range_base range_head range_extra retry_after now started=0 errors=0 direct_errors conclusion_errors
  local boot_epoch boot_age boot_recovery=0 recovery_active=0 active_units=""
  queue_recovery_progress scan "$started" "$errors"
  boot_epoch="$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)"
  boot_age=$(( $(date +%s) - boot_epoch ))
  (( boot_age >= 0 && boot_age < 900 )) && boot_recovery=1
  local -a requests=()
  mkdir -p -- "$REQUEST_DIR" || return 1
  if [[ ! -r "$QUEUE_HEALTH_SUMMARY" ]] && ! queue_refresh_health_summary; then
    errors=$((errors + 1))
  fi
  now="$(date +%s)"
  local rows kind path phase retry_index
  local -a files=() retries=() queued=() verifiers=() running=() owners=() direct=() conclusions=()
  shopt -s nullglob
  files=("$REQUEST_DIR"/*.json)
  shopt -u nullglob
  if ((${#files[@]})); then
    # One parser reads history; only work-bearing records reach shell recovery.
    # Corrupt and empty files are independent errors, including files without trailing newlines.
    active_units="$(systemctl --user list-units "${UNIT_PREFIX_TRANSIENT}-land-direct-main-*" --state=active,activating --no-legend --plain --no-pager 2>/dev/null)" || active_units=unknown
    rows="$(python3 - "$now" "$QUEUE_DIR" "$active_units" "${files[@]}" <<'PYSCAN'
import json, pathlib, re, sys
now = int(sys.argv[1])
queue = pathlib.Path(sys.argv[2])
active = {line.split()[0].removesuffix('.service') for line in sys.argv[3].splitlines() if line.split()}
def valid_range(ticket, path):
    try:
        parts = (queue / 'results' / ticket / 'range').read_text().split()
    except OSError:
        return False
    if len(parts) != 2 or not all(re.fullmatch(r'[0-9a-f]{40}', part) for part in parts):
        print('error\t' + path)
        return False
    return True

for path in sys.argv[4:]:
    try:
        with open(path) as source:
            row = json.load(source)
    except (OSError, ValueError):
        row = None
    if (not isinstance(row, dict) or not isinstance(row.get('ticket'), str)
            or not re.fullmatch(r'[0-9]{20}', row['ticket']) or not isinstance(row.get('state'), str)):
        print('error\t' + path)
        continue
    state = row['state']
    if state == 'queued':
        retry = str(row.get('retry_after_epoch', 0))
        retry = int(retry) if retry.isascii() and retry.isdigit() else 0
        if retry <= now:
            print(('retry' if retry > 0 else 'queued') + '\t' + path)
    elif state == 'running':
        print('running\t' + path)
    elif state == 'direct-pending-push' and row.get('direct_landing') is True:
        print('direct\t' + path)
    elif state == 'landed':
        post_land = row.get('post_land_verdict')
        if post_land is None and valid_range(row['ticket'], path):
            print('verify\t' + path)
        fix_forward = row.get('lesson_metadata_fix_forward') or {}
        if (post_land is not None and fix_forward.get('owner_queued') is not True
                and row.get('post_land_conclusion_deferred') is not True
                and (row.get('post_land_conclusion_pending') is True or row.get('post_land_conclusion_recorded') is not True)):
            print('conclusion\t' + path)
        if row.get('hand_owner_handoff') not in ('done', 'queued', 'superseded'):
            print('owner\t' + path)
PYSCAN
    )" || return 1
    while IFS=$'\t' read -r kind path; do
      case "$kind" in
        retry) retries+=("$path") ;; queued) queued+=("$path") ;; verify) verifiers+=("$path") ;;
        running) running+=("$path") ;; owner) owners+=("$path") ;;
        direct) direct+=("$path") ;; conclusion) conclusions+=("$path") ;;
        error) errors=$((errors + 1)) ;;
      esac
    done <<< "$rows"
  fi
  queue_recovery_progress scan-complete "$started" "$errors"
  # Due retries are newest-first; fresh queued tickets retain their FIFO order and boot cap.
  for ((retry_index = ${#retries[@]} - 1; retry_index >= 0; retry_index--)); do
    requests+=("${retries[$retry_index]}")
  done
  retries=("${requests[@]}" "${queued[@]}")
  requests=("${retries[@]}" "${verifiers[@]}" "${running[@]}")
  if (( boot_recovery == 1 )); then
    [[ "$active_units" != *${UNIT_PREFIX_TRANSIENT}-land-direct-main-* ]] || recovery_active=1
    for request in "${requests[@]}"; do
      ticket="$(jq -r '.ticket // empty' "$request")"
      [[ "$ticket" =~ ^[0-9]{20}$ ]] || continue
      if systemctl --user is-active --quiet "${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket"; then recovery_active=1; break; fi
    done
  fi
  for phase in retries verifiers running; do
    queue_recovery_progress "$phase" "$started" "$errors"
    local -n phase_requests="$phase"
    for request in "${phase_requests[@]}"; do
      # shortcut: one recovery worker during boot; normal ticks drain the backlog after 15 minutes.
      (( boot_recovery == 0 || started + recovery_active < 1 )) || continue
      IFS=$'\t' read -r state ticket < <(jq -r '[.state, .ticket] | @tsv' "$request")
      [[ "$ticket" =~ ^[0-9]{20}$ ]] || { errors=$((errors + 1)); continue; }
      if [[ "$state" == landed ]]; then
        queue_conclude_landed "$request"
        continue
      fi
      [[ "$state" == queued || "$state" == running ]] || continue
      if [[ "$state" == queued ]]; then
        retry_after="$(jq -r '.retry_after_epoch // 0' "$request")"
        [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=0
        ((retry_after <= now)) || continue
      fi
      unit="${UNIT_PREFIX_TRANSIENT}-land-direct-main-$ticket"
      if systemctl --user is-active --quiet "$unit"; then continue; fi
      if [[ "$state" == running ]]; then
        if queue_recover_landed_push "$request"; then
          if [[ "$QUEUE_RECOVERED_LANDED" == 1 ]]; then
            queue_conclude_landed "$request"
            continue
          fi
        else
          errors=$((errors + 1))
          continue
        fi
        queue_update_request "$request" queued 'worker was inactive; queue recovery requeued request' || {
          errors=$((errors + 1))
          continue
        }
      fi
      if queue_start_unit "$request"; then
        started=$((started + 1))
      else
        errors=$((errors + 1))
      fi
    done
  done
  queue_recovery_progress direct "$started" "$errors"
  direct_errors="$(queue_recover_direct_pending "${direct[@]}")" || direct_errors=1
  [[ "$direct_errors" =~ ^[0-9]+$ ]] || direct_errors=1
  errors=$((errors + direct_errors))
  # Interrupted pushes can become landed after the snapshot. Recover only that changed cohort.
  for request in "${direct[@]}"; do
    jq -e '.state == "landed" and .post_land_verdict? == null' "$request" >/dev/null 2>&1 || continue
    owners+=("$request")
    (( boot_recovery == 0 || started + recovery_active < 1 )) || continue
    queue_conclude_landed "$request"
  done
  queue_recovery_progress conclusions "$started" "$errors"
  conclusion_errors="$(queue_recover_pending_conclusions "${conclusions[@]}")" || conclusion_errors=1
  [[ "$conclusion_errors" =~ ^[0-9]+$ ]] || conclusion_errors=1
  errors=$((errors + conclusion_errors))
  queue_recovery_progress owners "$started" "$errors"
  for request in "${owners[@]}"; do
    IFS=$'\t' read -r state ticket range_head < <(jq -r '[.state, .ticket, .landed_sha] | @tsv' "$request")
    [[ "$state" == landed ]] || continue
    if ! queue_report_landing_complete "$request" "LANDED $ticket $range_head"; then
      printf 'land-queue: owner handoff failed ticket=%s\n' "$ticket" >&2
      errors=$((errors + 1))
    fi
  done
  queue_recovery_progress complete "$started" "$errors"
  printf 'started=%s errors=%s\n' "$started" "$errors"
  ((errors == 0))
}

queue_health() {
  local now depth active_epoch post_land_depth post_land_ticket post_land_epoch last_failure
  local oldest_age=0 post_land_oldest_age=0
  [[ -r "$QUEUE_HEALTH_SUMMARY" ]] || return 1
  IFS=$'\t' read -r depth active_epoch post_land_depth post_land_ticket post_land_epoch last_failure < "$QUEUE_HEALTH_SUMMARY" || return 1
  [[ "$depth" =~ ^[0-9]+$ && "$active_epoch" =~ ^[0-9]+$ && "$post_land_depth" =~ ^[0-9]+$ &&
     "$post_land_ticket" =~ ^([0-9]{20}|none)$ && "$post_land_epoch" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  if ((active_epoch > 0)); then oldest_age=$((now - active_epoch)); ((oldest_age >= 0)) || oldest_age=0; fi
  if ((post_land_epoch > 0)); then post_land_oldest_age=$((now - post_land_epoch)); ((post_land_oldest_age >= 0)) || post_land_oldest_age=0; fi
  printf 'depth=%s oldest_age_seconds=%s post_land_depth=%s post_land_oldest_ticket=%s post_land_oldest_age_seconds=%s last_failure=%s\n' \
    "$depth" "$oldest_age" "$post_land_depth" "$post_land_ticket" "$post_land_oldest_age" "$last_failure"
}

queue_main() {
    AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
    QUEUE_DIR="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}"
    REQUEST_DIR="$QUEUE_DIR/requests"
    QUEUE_HEALTH_SUMMARY="$QUEUE_DIR/health-summary.tsv"
    QUEUE_MAIN_FETCH_ATTEMPTS="${ZF_LAND_QUEUE_MAIN_FETCH_ATTEMPTS:-1}"
    QUEUE_MAIN_FETCH_BACKOFF_SECONDS="${ZF_LAND_QUEUE_MAIN_FETCH_BACKOFF_SECONDS:-60}"
    QUEUE_TRANSIENT_ALERT_SECONDS="${ZF_LAND_QUEUE_TRANSIENT_ALERT_SECONDS:-300}"
    QUEUE_TRANSIENT_BACKOFF_SECONDS="${ZF_LAND_QUEUE_TRANSIENT_BACKOFF_SECONDS:-180}"
    QUEUE_TRANSIENT_MAX_ATTEMPTS="${ZF_LAND_QUEUE_TRANSIENT_MAX_ATTEMPTS:-3}"
    QUEUE_LIB_LOAD_ERROR_REPORTED=0

  case "${1:-}" in
    requeue-completed-rebase)
      (($# == 5)) || { echo "usage: $0 requeue-completed-rebase REQUEST OWNER EPISODE ORIGINAL_HEAD" >&2; exit 2; }
      queue_requeue_completed_rebase "$2" "$3" "$4" "$5"
      ;;
    requeue-failed-transient)
      (( $# == 2 || $# == 3 )) || { echo "usage: $0 requeue-failed-transient REQUEST [DEFER_SECONDS]" >&2; exit 2; }
      queue_requeue_failed_transient "$2" "${3:-600}"
      ;;
    direct-reserve)
      (($# == 7)) || { echo "usage: $0 direct-reserve REPO OWNER BASE_SHA HEAD_SHA LANDER_PID LANDER_START_TICKS" >&2; exit 2; }
      queue_direct_reserve "$2" "$3" "$4" "$5" "$6" "$7"
      ;;
    direct-landed)
      (($# == 4)) || { echo "usage: $0 direct-landed TICKET BASE_SHA HEAD_SHA" >&2; exit 2; }
      queue_direct_landed "$2" "$3" "$4"
      ;;
    enqueue)
      (($# == 4)) || { echo "usage: $0 enqueue REPO OWNER REPORT | run REQUEST | health" >&2; exit 2; }
      queue_enqueue "$2" "$3" "$4"
      ;;
    run)
      (($# == 2)) || { echo "usage: $0 run REQUEST" >&2; exit 2; }
      queue_run "$2"
      ;;
    recover)
      (($# == 1)) || { echo "usage: $0 recover" >&2; exit 2; }
      queue_recover
      ;;
    health)
      (($# == 1)) || { echo "usage: $0 health" >&2; exit 2; }
      queue_health
      ;;
    refresh-health)
      (($# == 1)) || { echo "usage: $0 refresh-health" >&2; exit 2; }
      queue_refresh_health_summary
      ;;
    post-land-result)
      (($# == 3 || $# == 4)) || { echo "usage: $0 post-land-result TICKET OUTCOME [FAILURE_STAGE]" >&2; exit 2; }
      queue_post_land_record result "$2" "$3" "${4:-}"
      ;;
    finish-deferred-owner)
      (($# == 2)) || { echo "usage: $0 finish-deferred-owner OWNER" >&2; exit 2; }
      queue_finish_deferred_owner "$2"
      ;;
    *) echo "usage: $0 enqueue REPO OWNER REPORT | run REQUEST | recover | health" >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  queue_main "$@"
fi
