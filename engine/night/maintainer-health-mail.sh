#!/usr/bin/env bash

# Sourceable helpers plus the once-a-day owner report mail.
# The report goes out at 08:00 Beijing time (the timer fires at 00:00 UTC); the
# only other mail this ledger sends is the immediate short outage mail, which
# the incident path below keeps. Every number in the report comes from the
# engine's own records; a figure those records cannot give is left out of the
# mail, never invented.
# In a deployed engine, load the unit prefix before resolving it; a plain checkout has no deploy.env.
if [[ -f "$(dirname -- "${BASH_SOURCE[0]}")/../deploy.env" ]]; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/config.sh"
fi
# Same setting lib.sh resolves; tests that stub agent_epoch skip lib.sh.
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"
if ! declare -F agent_epoch >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/lib.sh"
fi
# The comms formatter (maintainer timezone) is needed even when the caller already
# loaded lib.sh; tests that stub agent_epoch skip lib.sh, so load it directly.
if ! declare -F maintainer_local_time >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/comms-format.sh"
fi
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/owner-report-render.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/owner-report-ladder.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/owner-report-compare.sh"

# One report per Beijing day; 08:00 Beijing is 00:00 UTC, so the slot is the
# UTC day and the report date is the Beijing date.
maintainer_health_mail_slot_key() {
  local now="$1"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  date -u -d "@$((now / 86400 * 86400))" +%Y%m%d
}

maintainer_health_mail_digest_interval_seconds() {
  printf '86400\n'
}

maintainer_health_mail_ensure_ledger() {
  local ledger="$1" now="${2:-$(date +%s)}" tmp
  mkdir -p "$(dirname "$ledger")" || return 1
  if [ -e "$ledger" ]; then
    jq -e 'type == "object" and (.started_at|type=="number") and (.last_sent_at|type=="number") and (.nodes|type=="object") and ((.incidents // [])|type=="array")' "$ledger" >/dev/null 2>&1
    return $?
  fi
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! (umask 077; jq -n --argjson now "$now" \
    '{started_at:$now,last_sent_at:0,last_digest_slot:"",nodes:{},incidents:[],pending_events:{},reported_items:{},important_items:{}}' > "$tmp"); then
    rm -f "$tmp"
    return 1
  fi
  # A concurrent initializer may already have claimed or sent this hour.
  # Publish only when absent; never replace that worker's durable ledger.
  if ! ln -- "$tmp" "$ledger" 2>/dev/null; then
    rm -f -- "$tmp"
    [ -e "$ledger" ] || return 1
    maintainer_health_mail_ensure_ledger "$ledger" "$now"
    return $?
  fi
  rm -f -- "$tmp"
}

maintainer_health_mail_unlock() {
  local lock_fd="$1"
  flock -u "$lock_fd" 2>/dev/null || true
  exec {lock_fd}>&-
}

maintainer_health_mail_record_event() {
  local ledger="$1" key="$2" section="$3" text="$4" now="${5:-$(date +%s)}" kind="${6:-event}" highlight="${7:-false}" reminder_for="${8:-}"
  local lock_fd tmp result
  [[ -n "$key" && -n "$section" && "$now" =~ ^[0-9]+$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  result="$(jq -r --arg key "$key" '
    if ((.reported_items // {}) | has($key)) then "reported"
    elif ((.pending_events // {}) | has($key)) then "existing"
    else "new" end' "$ledger")" || return 1
  if [ "$result" != new ]; then
    maintainer_health_mail_unlock "$lock_fd"
    printf '%s\n' "$result"
    return 0
  fi
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg key "$key" --arg section "$section" --arg text "$text" --arg kind "$kind" --arg reminder_for "$reminder_for" \
    --argjson now "$now" --argjson highlight "$highlight" \
    '(.pending_events //= {}) | .pending_events[$key]={key:$key,section:$section,text:$text,kind:$kind,highlight:$highlight,reminder_for:$reminder_for,created_at:$now}' \
    "$ledger" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$ledger" || return 1
  maintainer_health_mail_unlock "$lock_fd"
  printf 'queued\n'
}

maintainer_health_mail_track_important() {
  local ledger="$1" key="$2" kind="$3" text="$4" issue="${5:-}" now="${6:-$(date +%s)}"
  local question="${7:-}" recommendation="${8:-}" lock_fd tmp
  [[ -n "$key" && "$kind" =~ ^(outage|wrong-business-numbers|decision|team-blocker)$ && -n "$text" && "$now" =~ ^[0-9]+$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg key "$key" --arg kind "$kind" --arg text "$text" --arg issue "$issue" \
    --arg question "$question" --arg recommendation "$recommendation" --argjson now "$now" '
    (.important_items //= {}) | (.reported_items //= {})
    | if (.important_items[$key] // null) == null then
        .important_items[$key]=({kind:$kind,text:$text,issue:$issue,opened_at:$now,last_reminded_at:$now,status:"open"}
          + (if $kind == "decision" and $question != "" and $recommendation != ""
             then {question:$question,recommendation:$recommendation} else {} end))
      else . end
    | .reported_items[$key]=$now
  ' "$ledger" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$ledger" || return 1
  maintainer_health_mail_unlock "$lock_fd"
}

maintainer_health_mail_mark_reported() {
  local ledger="$1" key="$2" now="$3" reason="${4:-}" lock_fd tmp reason_file
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  reason_file="$(jq_arg_file "$reason")" || { rm -f -- "$tmp"; maintainer_health_mail_unlock "$lock_fd"; return 1; }
  if ! jq --arg key "$key" --rawfile reason "$reason_file" --argjson now "$now" '
    (.reported_items //= {}) | .reported_items[$key]=$now
    | if $reason != "" then
        (.rejected_events //= {})
        | .rejected_events[$key]={event:(.pending_events[$key] // null),reason:$reason,rejected_at:$now}
        | del(.pending_events[$key])
      else . end
  ' "$ledger" > "$tmp"; then
    rm -f -- "$tmp" "$reason_file"
    maintainer_health_mail_unlock "$lock_fd"
    return 1
  fi
  rm -f -- "$reason_file"
  mv -f -- "$tmp" "$ledger" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"
}

maintainer_health_mail_resolve_important() {
  local ledger="$1" key="$2" now="$3" section="${4:-事项更新}" text="${5:-}"
  local lock_fd tmp
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg key "$key" --arg section "$section" --arg text "$text" --argjson now "$now" '
    (.important_items //= {}) | (.pending_events //= {})
    | if .important_items[$key] != null then .important_items[$key].status="resolved" | .important_items[$key].resolved_at=$now else . end
    | .pending_events |= with_entries(select(.value.reminder_for != $key))
    | if $text == "" then . else
        (.pending_events //= {}) | .pending_events["resolved:" + $key + ":" + ($now|tostring)]={key:("resolved:" + $key + ":" + ($now|tostring)),section:$section,text:$text,kind:"event",highlight:false,created_at:$now}
      end
  ' "$ledger" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$ledger" || return 1
  maintainer_health_mail_unlock "$lock_fd"
}

maintainer_health_mail_node_status() {
  local ledger="$1" now="$2" last age interval slow_after stuck_after
  last="$(jq -r 'if .last_sent_at > 0 then .last_sent_at else .started_at end' "$ledger" 2>/dev/null)" || {
    printf 'UNKNOWN\n'
    return 0
  }
  [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf 'UNKNOWN\n'; return 0; }
  interval="$(maintainer_health_mail_digest_interval_seconds)" || { printf 'UNKNOWN\n'; return 0; }
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || { printf 'UNKNOWN\n'; return 0; }
  age=$((now - last))
  (( age < 0 )) && age=0
  # Routine mail is daily; no successful send for a day plus five minutes is
  # slow, and an hour past that is stuck.
  slow_after=$((interval + 300))
  stuck_after=$((interval + 3600))
  if (( age >= stuck_after )); then printf 'STUCK\n'
  elif (( age >= slow_after )); then printf 'SLOW\n'
  else printf 'OK\n'; fi
}

maintainer_health_mail_claim_digest() {
  local ledger="$1" slot="$2" now="$3" events="${4:-[]}" lock_fd current tmp
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  jq -e 'type == "array" and all(.[]; (.key|type)=="string" and (.created_at|type)=="number")' <<< "$events" >/dev/null || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  current="$(jq -r '.last_digest_slot' "$ledger")" || return 1
  if [ "$current" = "$slot" ]; then
    maintainer_health_mail_unlock "$lock_fd"
    printf 'duplicate\n'
    return 0
  fi
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg slot "$slot" --argjson now "$now" --argjson events "$events" '
    ($events | map(.key)) as $keys | (.pending_events //= {}) | (.reported_items //= {})
    | reduce $keys[] as $key (.;
        .reported_items[$key]=$now | del(.pending_events[$key]))
    | .last_digest_slot=$slot | .last_digest_attempted_at=$now | .last_digest_claim={slot:$slot,events:$events}
  ' "$ledger" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$ledger" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"
  printf 'reserved\n'
}

maintainer_health_mail_release_digest() {
  local ledger="$1" slot="$2" lock_fd current tmp
  maintainer_health_mail_ensure_ledger "$ledger" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  current="$(jq -r '.last_digest_slot' "$ledger")" || return 1
  if [ "$current" != "$slot" ]; then
    maintainer_health_mail_unlock "$lock_fd"
    printf 'unchanged\n'
    return 0
  fi
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg slot "$slot" '
    if .last_digest_slot != $slot then . else
      (.last_digest_claim.events // []) as $events | (.pending_events //= {}) | (.reported_items //= {})
      | reduce $events[] as $event (.;
          .pending_events[$event.key] = (.pending_events[$event.key] // $event)
          | del(.reported_items[$event.key]))
      | .last_digest_slot="" | del(.last_digest_claim)
    end
  ' \
    "$ledger" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$ledger" || return 1
  maintainer_health_mail_unlock "$lock_fd"
  printf 'released\n'
}

maintainer_health_mail_mark_sent() {
  local ledger="$1" now="$2" lock_fd tmp efficiency_snapshot="${MAINTAINER_HEALTH_MAIL_EFFICIENCY_SNAPSHOT:-null}"
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  if ! jq --argjson now "$now" --argjson efficiency "$efficiency_snapshot" '
    (.last_digest_claim.events // []) as $events
    | reduce $events[] as $event (.;
        if $event.kind == "reminder" and ($event.reminder_for // "") != "" then
          .important_items[$event.reminder_for].last_reminded_at=$now
        else . end)
    | if ($efficiency | type) == "object" then .last_sent_efficiency=$efficiency else . end
    | .last_sent_at=$now | del(.last_digest_claim)
  ' "$ledger" > "$tmp"; then
    rm -f "$tmp"
    maintainer_health_mail_unlock "$lock_fd"
    return 1
  fi
  mv -f "$tmp" "$ledger" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"
}

# Incidents share the owner-mail ledger; sends are reserved first to prevent
# duplicates. A confirmed production outage gets the immediate short mail.
maintainer_health_mail_incident_open() {
  local ledger="$1" issue="$2" subject="$3" what="$4" impact="$5" action="$6" promised="$7" now="$8" urgent="${9:-0}"
  local lock_fd existing tmp initial_status retry_initial=0 important_kind incident_key what_file
  [[ "$issue" =~ ^[0-9]+$ && "$promised" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$urgent" =~ ^[01]$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  existing="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .status // empty' "$ledger")" || return 1
  if [ -n "$existing" ]; then
    if [ "$existing" = open ]; then
      initial_status="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .initial_mail_status // "queued"' "$ledger")" || return 1
      if [ "$urgent" = 1 ] && { [ "$initial_status" = queued ] || [ "$initial_status" = failed-safe ]; }; then
        retry_initial=1
      fi
      what_file="$(jq_arg_file "$what")" || return 1
      tmp="$(mktemp "${ledger}.XXXXXX")" || { rm -f -- "$what_file"; return 1; }
      jq --argjson issue "$issue" --rawfile what "$what_file" --arg impact "$impact" --arg action "$action" --argjson urgent "$urgent" \
        --argjson retry "$retry_initial" \
        '.incidents |= map(if .issue == $issue and .status == "open" then .what=$what | .impact=$impact | .action=$action | .urgent=((.urgent // false) or $urgent) | if $retry then .initial_mail_status="reserved" else . end else . end)' \
        "$ledger" > "$tmp" || { rm -f -- "$what_file" "$tmp"; return 1; }
      rm -f -- "$what_file"
      mv -f -- "$tmp" "$ledger" || { rm -f -- "$tmp"; return 1; }
    fi
    maintainer_health_mail_unlock "$lock_fd"
    if [ "$existing" = open ] && [ "$retry_initial" = 1 ]; then
      maintainer_health_mail_incident_send_initial "$ledger" "$issue" "$subject" "$what" "$impact" "$action" "$promised" "$now"
      return $?
    fi
    printf 'existing\n'
    return 0
  fi
  what_file="$(jq_arg_file "$what")" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || { rm -f -- "$what_file"; return 1; }
  if ! jq --argjson issue "$issue" --arg subject "$subject" --rawfile what "$what_file" \
    --arg impact "$impact" --arg action "$action" --argjson promised "$promised" --argjson now "$now" \
    --argjson urgent "$urgent" \
    '(.incidents //= []) | .incidents += [{issue:$issue,subject:$subject,what:$what,impact:$impact,action:$action,current_state:"恢复尚未确认，正在恢复服务",opened_at:$now,promised_update_at:$promised,next_update_at:$promised,status:"open",urgent:($urgent == 1),update_count:0,initial_mail_status:(if $urgent then "reserved" else "queued" end)}]' \
    "$ledger" > "$tmp"; then
    rm -f -- "$what_file" "$tmp"
    return 1
  fi
  rm -f -- "$what_file"
  mv -f -- "$tmp" "$ledger" || { rm -f -- "$tmp"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"

  incident_key="incident:$issue:$now"
  important_kind=''
  if [ "$urgent" = 1 ]; then
    important_kind=outage
  elif grep -Eiq '业务数字错误|数据错误|金额(有误|错误)|数量(有误|错误)|库存(有误|错误)|wrong business numbers|incorrect totals|wrong totals' <<< "$what $impact"; then
    important_kind=wrong-business-numbers
  fi
  if [ -n "$important_kind" ]; then
    maintainer_health_mail_track_important "$ledger" "$incident_key" "$important_kind" "$subject" "$issue" "$now" || return 1
  fi
  if [ "$urgent" = 1 ]; then
    maintainer_health_mail_incident_send_initial "$ledger" "$issue" "$subject" "$what" "$impact" "$action" "$promised" "$now" || return 1
  fi
  printf 'opened\n'
}

maintainer_health_mail_incident_send_initial() {
  local ledger="$1" issue="$2" subject="$3" what="$4" impact="$5" action="$6" promised="$7" now="$8"
  local status retry_safe=0
  NOTIFY_LAST_SEND_RETRY_SAFE=1
  if notify_maintainer_incident "$issue" "$subject" "$what" "$impact" "$action" "$promised" >/dev/null; then
    status=sent
  elif [ "${NOTIFY_LAST_SEND_RETRY_SAFE:-0}" = 1 ]; then
    status=failed-safe
    retry_safe=1
  else
    status=uncertain
  fi
  maintainer_health_mail_incident_mark_mail_result "$ledger" "$issue" initial "$status" "$now" || return 1
  [ "$retry_safe" = 0 ]
}

maintainer_health_mail_incident_request_resolution() {
  local ledger="$1" issue="$2" kind="$3" reason="$4" now="$5" reference="${6:-}"
  local lock_fd status requested tmp reason_file
  [[ "$issue" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  [[ "$kind" == release || "$kind" == supervisor || "$kind" == availability ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  status="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .status // empty' "$ledger")" || return 1
  requested="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .resolution_requested_at // empty' "$ledger")" || return 1
  if [ "$status" != open ] || [ -n "$requested" ]; then
    maintainer_health_mail_unlock "$lock_fd"
    printf 'unchanged\n'
    return 0
  fi
  reason_file="$(jq_arg_file "$reason")" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || { rm -f -- "$reason_file"; return 1; }
  jq --argjson issue "$issue" --arg kind "$kind" --rawfile reason "$reason_file" --arg reference "$reference" --argjson now "$now" \
    '.incidents |= map(if .issue == $issue and .status == "open" then .resolution_kind=$kind | .resolution_reason=$reason | .resolution_ref=$reference | .resolution_requested_at=$now else . end)' \
    "$ledger" > "$tmp" || { rm -f -- "$reason_file" "$tmp"; return 1; }
  rm -f -- "$reason_file"
  mv -f -- "$tmp" "$ledger" || { rm -f -- "$tmp"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"
  printf 'requested\n'
}

maintainer_health_mail_incident_mark_resolved() {
  maintainer_health_mail_incident_request_resolution "$1" "$2" supervisor "$3" "$4"
}

maintainer_health_mail_incident_mark_mail_result() {
  local ledger="$1" issue="$2" kind="$3" status="$4" now="$5"
  local lock_fd tmp
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  case "$kind" in
    initial)
      jq --argjson issue "$issue" --arg status "$status" --argjson now "$now" \
        '.incidents |= map(if .issue == $issue then .initial_mail_status=$status | .initial_mail_attempted_at=$now else . end)' "$ledger" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
    update)
      jq --argjson issue "$issue" --arg status "$status" --argjson now "$now" \
        '.incidents |= map(if .issue == $issue then .last_update_mail_status=$status | .last_update_attempted_at=$now else . end)' "$ledger" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
    resolution)
      jq --argjson issue "$issue" --arg status "$status" --argjson now "$now" \
        '.incidents |= map(if .issue == $issue then .resolution_mail_status=$status | .resolution_mail_attempted_at=$now else . end)' "$ledger" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
    *) rm -f -- "$tmp"; return 2 ;;
  esac
  mv -f -- "$tmp" "$ledger" || return 1
  maintainer_health_mail_unlock "$lock_fd"
}

maintainer_health_mail_incident_tick() {
  local ledger="$1" now="$2" only_issue="${3:-}" issue lock_fd eligible tmp opened_at incident_key
  local -a pending=()
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1

  mapfile -t pending < <(jq -r --arg only "$only_issue" \
    '.incidents[]? | select(.status == "open" and (.resolution_requested_at // 0) > 0 and ($only == "" or (.issue|tostring) == $only)) | .issue' "$ledger")
  for issue in "${pending[@]}"; do
    exec {lock_fd}>"$ledger.lock" || return 1
    flock -x "$lock_fd" || return 1
    eligible="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | (.status == "open" and (.resolution_requested_at // 0) > 0 and ((.resolution_mail_status // "") != "reserved")) // false' "$ledger")" || return 1
    if [ "$eligible" != true ]; then
      maintainer_health_mail_unlock "$lock_fd"
      continue
    fi
    tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
    jq --argjson issue "$issue" --argjson now "$now" \
      '.incidents |= map(if .issue == $issue and .status == "open" then .status="resolved" | .resolved_at=$now | .resolution_mail_status="queued" else . end)' \
      "$ledger" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ledger" || return 1
    opened_at="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .opened_at' "$ledger")" || return 1
    maintainer_health_mail_unlock "$lock_fd"

    incident_key="incident:$issue:$opened_at"
    maintainer_health_mail_resolve_important "$ledger" "$incident_key" "$now" '事项变化' '' || return 1
  done
}

maintainer_health_mail_incident_release_accepted() {
  local ledger="$1" issue="$2" deployed_sha="$3" now="$4"
  maintainer_health_mail_incident_request_resolution "$ledger" "$issue" release \
    "生产服务已通过发布验收，恢复确认完成。" "$now" "$deployed_sha" >/dev/null || return 1
  maintainer_health_mail_incident_tick "$ledger" "$now" "$issue"
}

maintainer_health_mail_incidents_release_accepted() {
  local ledger="$1" deployed_sha="$2" now="$3" issues issue
  local -a open_issues=()
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  issues="$(jq -r '.incidents[]? | select(.status == "open") | .issue' "$ledger")" || return 1
  mapfile -t open_issues <<< "$issues"
  for issue in "${open_issues[@]}"; do
    [ -n "$issue" ] || continue
    maintainer_health_mail_incident_request_resolution "$ledger" "$issue" release \
      "生产服务已通过发布验收，恢复确认完成。" "$now" "$deployed_sha" >/dev/null || return 1
  done
  maintainer_health_mail_incident_tick "$ledger" "$now"
}

maintainer_health_mail_incidents_production_recovered() {
  local ledger="$1" now="$2" issues issue
  local -a open_issues=()
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  issues="$(jq -r '.incidents[]? | select(.status == "open" and .urgent == true) | .issue' "$ledger")" || return 1
  mapfile -t open_issues <<< "$issues"
  for issue in "${open_issues[@]}"; do
    [ -n "$issue" ] || continue
    maintainer_health_mail_incident_request_resolution "$ledger" "$issue" availability \
      '自动巡检确认全部主要服务已经恢复。' "$now" >/dev/null || return 1
  done
  maintainer_health_mail_incident_tick "$ledger" "$now"
}

maintainer_health_mail_issue_catalog() {
  local issue_numbers="${1:-[]}" repo owner name query response issue
  local -a numbers=()
  jq -e 'type == "array" and all(.[]; ((type == "number" and . > 0) or (type == "string" and test("^[1-9][0-9]*$"))))' \
    <<< "$issue_numbers" >/dev/null || return 1
  mapfile -t numbers < <(jq -r 'map(tostring) | unique[]' <<< "$issue_numbers")
  ((${#numbers[@]})) || { printf '[]\n'; return 0; }
  repo="$REPO"
  owner="${repo%%/*}"
  name="${repo#*/}"
  [[ "$owner" != "$name" && -n "$owner" && -n "$name" ]] || return 1
  query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'
  for issue in "${numbers[@]}"; do
    query+=" issue_${issue}: issue(number: ${issue}) { number title state createdAt closedAt labels(first: 100) { nodes { name } } }"
  done
  query+=' } }'
  response="$(timeout 20 gh api graphql -F owner="$owner" -F name="$name" -f query="$query" 2>/dev/null)" || return 1
  jq -e --argjson ids "$issue_numbers" '
    .data.repository as $repository
    | ($ids | map(tostring) | unique) as $wanted
    | ($repository | type == "object") and all($wanted[];
        ($repository["issue_" + .] | type == "object")
        and ($repository["issue_" + .].number | tostring) == .)
  ' <<< "$response" >/dev/null || return 1
  jq -c --argjson ids "$issue_numbers" '
    .data.repository as $repository
    | [$ids | map(tostring) | unique[] as $id
       | $repository["issue_" + $id]
       | {number,title,state,createdAt,closedAt,labels:[.labels.nodes[]? | {name}]}]
  ' <<< "$response"
}

maintainer_health_mail_deployment_catalog() {
  local home="$1"
  local -a state_files=()
  [ -d "$home/state" ] && [ -r "$home/state" ] && [ -x "$home/state" ] || { printf 'null\n'; return 0; }
  shopt -s nullglob
  state_files=("$home"/state/*.json)
  shopt -u nullglob
  ((${#state_files[@]})) || { printf 'null\n'; return 0; }
  jq -cn '
    [inputs as $state
      | (input_filename | split("/")[-1] | rtrimstr(".json")) as $issue
      | select($issue | test("^[0-9]+$"))
      | {issue:$issue,state:$state}] as $records
    | if ($records | length) == 0 then null
      else
        [$records[] as $record | $record.state as $state
          | select($state.pipeline_system.enabled != true and $state.run.outcome != "pipeline-system")
          | select($state.deploy_state == "deployed" and ($state.deployed_sha // "") != "")
          | ($state.deployed_at // $state.run.deployed_at // $state.run.evidence.production_evidence_at // "") as $stamp
          | ($stamp | try fromdateiso8601 catch null) as $at
          | {issue:$record.issue,at:$at}] as $deployed
        | {complete:all($deployed[]; .at != null),deployments:[$deployed[] | select(.at != null) | {issue,at}]}
      end
  ' "${state_files[@]}"
}

maintainer_health_mail_deployed_at() {
  local home="$1" issue="$2" state_file
  [[ "$issue" =~ ^[0-9]+$ ]] || return 0
  state_file="$home/state/$issue.json"
  [ -r "$state_file" ] || return 0
  jq -r '.deployed_at // .run.deployed_at // .run.evidence.production_evidence_at // empty' "$state_file" 2>/dev/null || true
}

maintainer_health_mail_plain_title() {
  local title
  title="$(maintainer_health_mail_scrub_text "$1")" || return 1
  printf '%s' "$title" | jq -Rr '
    gsub("[[:space:]]+"; " ")
    | gsub("^[[:space:][:punct:]]+|[[:space:][:punct:]]+$"; "")
    | if test("[一-龥]") and (test("[A-Za-z]") | not) then .[0:20] else "功能改进" end
  '
}

maintainer_health_mail_scrub_text() {
  printf '%s' "$1" | jq -Rr '
    gsub("#[[:space:]]*[0-9]+"; "")
    | gsub("[[:xdigit:]]{7,}"; "")
    | gsub("[[:space:]]+"; " ")
    | if test("[一-龥]") and (test("[A-Za-z]") | not) then . else "" end
  '
}

maintainer_health_mail_active_implements() {
  local units
  units="$(timeout 10 systemctl --user list-units "${UNIT_PREFIX_TRANSIENT}-implement-*" --state=running --plain --no-legend 2>/dev/null)" || return 1
  awk "\$1 ~ /^${UNIT_PREFIX_TRANSIENT}-implement-[0-9]+\\.service\$/ { n++ } END { print n+0 }" <<< "$units"
}

maintainer_health_mail_work_counts() {
  local home="$1" now="$2" units=null ready_json ready=''
  units="$(maintainer_health_mail_active_implements)" || units=null
  if ready_json="$(timeout 30 gh issue list --repo "$REPO" --state open --label ready-for-agent --limit 1000 --json number,labels 2>/dev/null)" \
    && jq -e 'type == "array" and length < 1000 and all(.[]; (.number|type)=="number" and (.labels|type)=="array")' <<< "$ready_json" >/dev/null 2>&1; then
    ready="$(jq '[.[] | select(all(.labels[]?.name; . != "pipeline-system" and . != "on-hold" and . != "needs-owner" and . != "needs-advisor" and . != "needs-triage" and . != "concluded"))] | length' <<< "$ready_json")"
  fi
  [[ "$ready" =~ ^[0-9]+$ ]] || ready=null
  printf '{"active":%s,"queued":%s}\n' "$units" "$ready"
}

# --- Owner report: facts --------------------------------------------------------

maintainer_health_mail_report_day() { # <epoch> -> MM-DD, Beijing time
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 946684800 )) || return 1
  TZ=Asia/Shanghai date -d "@$1" +%m-%d
}

# Scheduler runtime files (node-health) live in the checkout.
maintainer_health_mail_runtime_dir() {
  local home="$1" user_home
  user_home="${home%/.zenoforge}"
  [ "$user_home" != "$home" ] || user_home="$home"
  printf '%s\n' "${MAC_AUTOPILOT_RUNTIME_DIR:-${ZF_MAC_AUTOPILOT_RUNTIME_DIR:-${MAC_AUTOPILOT_ROOT:-$user_home/checkout}/.scratch-supervisor/autopi}}"
}

# maintainer_health_mail_last_deploy
# Epoch of the earliest GitHub production Deployment record for the sha production
# runs now, from the one definition in mac-autopilot/release_age.py (its command-line
# entry prints "<time> <sha>"). Prints nothing when the read fails or the output is
# not a time, so the caller drops the figure instead of showing a stale one. The
# release train log is not read: its RELEASED lines go stale on a hand release.
maintainer_health_mail_last_deploy() {
  local script out at
  script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/mac-autopilot/release_age.py"
  out="$(timeout 90 python3 "$script" 2>/dev/null)" || return 0
  at="${out%% *}"
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 0
  date -u -d "$at" +%s 2>/dev/null || true
}

# maintainer_health_mail_watch_episodes <home> <since> <until> <now>
# Production-failure episodes: head-watch's PROD-DB-TIMEOUT alerts in
# logs/head-watch.alerts. Alerts less than 30 minutes apart are one episode,
# counted at its first alert. {period: episodes starting in [since, until),
# alerting: episodes whose last alert is under 30 minutes old at now,
# hours_since_last: whole hours from the newest alert to now, classes: distinct
# signatures among the alerts of the episodes starting in the period}. A signature
# is the alert's first word plus its message with digits removed; it is only
# compared, never printed, and classes is null if any such alert has no message.
# A pause in alerts is not evidence that an episode closed. Null when the log is unreadable.
maintainer_health_mail_watch_episodes() {
  local home="$1" since="$2" until="$3" now="$4"
  local file="$home/logs/head-watch.alerts"
  [ -r "$file" ] || { printf 'null\n'; return 0; }
  python3 - "$file" "$since" "$until" "$now" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

path, since, until, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
GAP = 30 * 60
pattern = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) PROD-DB-TIMEOUT(?: (\S.*))?$")
stamps = []
signatures = {}
try:
    with open(path, encoding="utf-8", errors="replace") as source:
        for line in source:
            match = pattern.match(line)
            if not match:
                continue
            try:
                at = int(datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
            except ValueError:
                continue
            stamps.append(at)
            message = (match.group(2) or "").rstrip()
            signatures.setdefault(at, []).append((message.split()[0], re.sub(r"[0-9]+", "#", message)) if message else None)
except OSError:
    print("null")
    raise SystemExit(0)
episodes = []
for at in sorted(stamps):
    if episodes and at - episodes[-1][1] < GAP:
        episodes[-1][1] = at
    else:
        episodes.append([at, at])
shown = [signature for first, last in episodes if since <= first < until
         for at in signatures if first <= at <= last for signature in signatures[at]]
print(json.dumps({"period": sum(since <= first < until for first, _ in episodes),
                  "classes": None if None in shown else len(set(shown)),
                  "alerting": sum(last + GAP > now for _, last in episodes),
                  "hours_since_last": (now - stamps[-1]) // 3600 if stamps else None}, separators=(",", ":")))
PY
}

# maintainer_health_mail_spend_facts <home> <start> <end>
# What the spend log recorded in [start, end): tokens from the rows that carry a
# token count, dollars from the rows that carry a price. The two kinds of rows are
# different meters (a row has one or the other), so each sum is exact for its own
# meter and the two are never added. Null when the log is missing or unreadable.
maintainer_health_mail_spend_facts() {
  local home="$1" start="$2" end="$3"
  python3 - "$home" "$start" "$end" <<'PY'
import glob
import json
import os
import sys
from datetime import datetime, timezone

home, start_raw, end_raw = sys.argv[1:]
start, end = int(start_raw), int(end_raw)
first_day = datetime.fromtimestamp(start, timezone.utc).strftime("%Y-%m-%d")
last_day = datetime.fromtimestamp(max(start, end - 1), timezone.utc).strftime("%Y-%m-%d")
paths = sorted(path for path in glob.glob(os.path.join(home, "spend", "????-??-??.log"))
               if first_day <= os.path.basename(path)[:10] <= last_day)
tokens, money, rows = 0, 0.0, 0
try:
    for path in paths:
        with open(path, encoding="utf-8") as source:
            for line in source:
                fields = line.rstrip("\r\n").split("\t")
                if not fields[0].isdigit() or not start <= int(fields[0]) < end:
                    continue
                rows += 1
                if len(fields) > 5 and fields[5].isdigit():
                    tokens += int(fields[5])
                try:
                    price = float(fields[4]) if len(fields) > 4 else 0.0
                except ValueError:
                    price = 0.0
                if 0 <= price < float("inf"):
                    money += price
except OSError:
    rows = 0
print(json.dumps({"tokens": tokens, "money_usd": round(money, 2)} if rows else None, separators=(",", ":")))
PY
}

# maintainer_health_mail_quality_facts <ledger> <home> <start> <end> <repo_root>
maintainer_health_mail_quality_facts() {
  local ledger="$1" home="$2" start="$3" end="$4" repo_root="$5"
  local incidents incidents_open open_subjects rollbacks git_dir watch
  incidents="$(jq -c --argjson start "$start" --argjson end "$end" '
    (.incidents // []) as $rows
    | if any($rows[]; (.opened_at | type) != "number") then null
      else [$rows[] | select(.opened_at < $end and ((.resolved_at // $end) >= $start))] | length end
  ' "$ledger" 2>/dev/null || printf 'null')"
  open_subjects="$(jq -c '[.incidents[]? | select(.status == "open") | .subject]' "$ledger" 2>/dev/null || printf 'null')"
  incidents_open=null
  [ "$open_subjects" = null ] || incidents_open="$(jq 'length' <<< "$open_subjects")"
  rollbacks=null
  if [ -n "$repo_root" ] && git_dir="$(git -C "$repo_root" rev-parse --verify origin/main 2>/dev/null)"; then
    if rollbacks="$(git -C "$repo_root" log "$git_dir" --since="@${start}" --until="@${end}" \
      --fixed-strings --grep='This reverts commit' --format=%H 2>/dev/null)"; then
      rollbacks="$(printf '%s' "$rollbacks" | wc -l | tr -d '[:space:]')"
    else
      rollbacks=null
    fi
  fi
  # Production incidents: ledger incidents plus head-watch PROD-DB-TIMEOUT episodes (see maintainer_health_mail_watch_episodes).
  watch="$(maintainer_health_mail_watch_episodes "$home" "$start" "$end" "$end")" || watch='null'
  jq -cn --argjson incidents "$incidents" --argjson incidents_open "$incidents_open" --argjson open_subjects "$open_subjects" \
    --argjson rollbacks "$rollbacks" --argjson watch "$watch" '
    {incidents_period:(if $incidents == null or $watch == null then null else $incidents + $watch.period end),
     incidents_open:(if $incidents_open == null or $watch == null then null
       elif $watch.period == 0 then $incidents_open
       elif $watch.alerting > 0 then $incidents_open + $watch.alerting
       else null end),
     watch_hours_since_last:(if $watch == null then null else $watch.hours_since_last end),
     alert_classes:(if $watch == null or $incidents != 0 then null else $watch.classes end),
     open_subjects:$open_subjects,
     rollbacks:$rollbacks}'
}

# maintainer_health_mail_decision_facts <ledger>
maintainer_health_mail_decision_detail() {
  python3 - "$1" <<'PY'
import json
import re
import sys

lines = sys.argv[1].splitlines()
question = next((line[len("问题："):].strip() for line in lines if line.startswith("问题：")), "")
letter = next((match.group(1) for line in lines
               if (match := re.match(r"^建议：([ABC])$", line))), "")
option = next((line for line in lines if letter and line.startswith(letter + "）")), "")
recommendation = ""
if letter and option:
    detail = option[len(letter) + 1:].strip()
    detail = re.split(r"[；;]影响：", detail, maxsplit=1)[0].strip()
    ordinal = {"A": "第一项", "B": "第二项", "C": "第三项"}[letter]
    recommendation = f"建议：选择{ordinal}，{detail}"
if not re.search(r"[一-龥]", question) or re.search(r"[A-Za-z]", question):
    question = ""
if not re.search(r"[一-龥]", recommendation) or re.search(r"[A-Za-z]", recommendation):
    recommendation = ""
print(json.dumps({"question": question[:120], "recommendation": recommendation[:160]}, ensure_ascii=False))
PY
}

maintainer_health_mail_decision_facts() {
  jq -c '
    [(.important_items // {}) | to_entries[]
      | select(.value.status == "open" and .value.kind == "decision") | .value] as $rows
    | {items:[$rows[] | select((.question // "") != "" and (.recommendation // "") != "")
        | {question:.question,recommendation:.recommendation}],
       total:($rows | length),
       incomplete:([$rows[] | select((.question // "") == "" or (.recommendation // "") == "")] | length)}
  ' "$1" 2>/dev/null || printf '{"items":[],"total":null,"incomplete":0}'
}

# maintainer_health_mail_daily_facts <home> <ledger> <now> <repo_root>
# Everything the owner report shows, as one JSON object. A collector that
# cannot read its source leaves null, and the renderer drops that figure.
maintainer_health_mail_daily_facts() {
  local home="$1" ledger="$2" now="$3" repo_root="$4"
  local start=$((now - 86400)) output deploy_at spend spend_prev quality decisions day reason stations facts compare
  output="$(maintainer_health_mail_ladder_facts "$home" "$now")" || output=null
  deploy_at="$(maintainer_health_mail_last_deploy)" || deploy_at=null
  [[ "$deploy_at" =~ ^[0-9]+$ ]] || deploy_at=null
  spend="$(maintainer_health_mail_spend_facts "$home" "$start" "$now")" || spend=null
  spend_prev="$(maintainer_health_mail_spend_facts "$home" "$((start - 86400))" "$start")" || spend_prev=null
  quality="$(maintainer_health_mail_quality_facts "$ledger" "$home" "$start" "$now" "$repo_root")" || quality='{}'
  decisions="$(maintainer_health_mail_decision_facts "$ledger")" || decisions='{"items":[],"total":null,"incomplete":0}'
  day="$(maintainer_health_mail_report_day "$now")" || return 1
  reason="$(maintainer_health_mail_conclusion_facts "$output" "$quality")"
  stations="$(owner_report_station_facts "$home" "$now")" || stations=null
  facts="$(jq -cn --arg day "$day" --rawfile reason <(printf '%s' "$reason") --argjson now "$now" \
    --argjson output "$output" --argjson deploy_at "$deploy_at" --argjson spend "$spend" --argjson spend_prev "$spend_prev" \
    --argjson quality "$quality" --argjson decisions "$decisions" --argjson stations "$stations" \
    '{report_day:$day,conclusion:{reason:$reason},window:{end:$now},
      output:$output,last_deploy_at:$deploy_at,
      spend:{day:$spend,prev_day:$spend_prev},quality:$quality,decisions:$decisions,stations:$stations}')" || return 1
  # A failed comparison leaves the report without those lines, never with a guessed one.
  compare="$(owner_report_compare "$facts" "$home" "$now" "$repo_root")" || compare=null
  jq -c --argjson compare "$compare" '.compare=$compare' <<< "$facts"
}

# maintainer_health_mail_conclusion_facts <output> <quality>
# One sentence that leads with output (做完, 正式上线, 等上线) and then says one
# thing about production alerts. A part whose figure is unread is left out.
maintainer_health_mail_conclusion_facts() {
  jq -r '
    . as $c | ($c.output) as $o | ($c.quality) as $q
    | [ (if $o.finished.day != null then "做完 \($o.finished.day) 个" else empty end),
        (if $o.shipped.day != null then "正式上线 \($o.shipped.day) 个" else empty end),
        (if $o.stock.now != null then "等上线 \($o.stock.now) 个" else empty end) ] as $out
    | (if ($q.incidents_period // 0) > 0 then "\($q.incidents_period) 次告警"
       elif $q.incidents_period == 0 then "没有告警" else "" end) as $incident
    | [($out | join("、")), $incident] | map(select(. != "")) | join("；")
    | if . == "" then "今天的产出记录读取失败" else . end
  ' <<< "$(jq -cn --argjson output "$1" --argjson quality "$2" '{output:$output,quality:$quality}')"
}

maintainer_health_mail_date_time() {
  [[ "$1" =~ ^[0-9]{10,}$ ]] && (( $1 >= 946684800 )) || { printf '时间待核实'; return 0; }
  maintainer_local_time "$1"
}

maintainer_health_mail_release_lines() {
  local home="$1" start="$2" end="$3" deployments complete period_file issues_file rows issue_ids issue title at local_time
  deployments="$(maintainer_health_mail_deployment_catalog "$home")" || return 1
  if [ "$deployments" = null ]; then
    printf -- '- 上线记录待核实，无法确认本期上线内容。\n'
    return 0
  fi
  complete="$(jq -r '.complete' <<< "$deployments")" || return 1
  if [ "$complete" != true ]; then
    printf -- '- 上线时间待核实，无法确认本期上线内容。\n'
  fi
  period_file="$(mktemp)" || return 1
  printf '{"start":%s,"end":%s}\n' "$start" "$end" > "$period_file"
  deployments="$(jq -cn --argjson period "$(cat "$period_file")" --argjson releases "$deployments" \
    '[$releases.deployments[] | select(.at >= $period.start and .at < $period.end)]')" || { rm -f -- "$period_file"; return 1; }
  rm -f -- "$period_file"
  [ "$(jq -r 'length' <<< "$deployments")" -gt 0 ] || return 0
  issue_ids="$(jq -c '[.[].issue | tonumber] | unique' <<< "$deployments")" || return 1
  issues_file="$(mktemp)" || return 1
  if ! maintainer_health_mail_issue_catalog "$issue_ids" > "$issues_file"; then
    while IFS=$'\t' read -r issue at; do
      local_time="$(maintainer_health_mail_date_time "$at")" || { rm -f -- "$issues_file"; return 1; }
      printf -- '- 已确认一项改进于%s上线；事项名称待核实。\n' "$local_time"
    done < <(jq -nr --argjson releases "$deployments" '$releases[] | [.issue,.at] | @tsv')
    rm -f -- "$issues_file"
    return 0
  fi
  rows="$(jq -nr --slurpfile issues "$issues_file" --argjson releases "$deployments" '
    $releases[] as $release
    | ([$issues[0][] | select((.number|tostring) == $release.issue)][0] // null) as $issue
    | select($issue == null or (all($issue.labels[]?.name; . != "pipeline-system")))
    | [$release.issue, ($issue.title // ""), $release.at] | @tsv
  ' 2>/dev/null)" || { rm -f -- "$issues_file"; return 1; }
  while IFS=$'\t' read -r issue title at; do
    [ -n "$issue" ] || continue
    if [ -n "$title" ]; then title="现在可以使用「$(maintainer_health_mail_plain_title "$title")」"
    else title='已确认一项改进；事项名称待核实。'; fi
    local_time="$(maintainer_health_mail_date_time "$at")" || { rm -f -- "$issues_file"; return 1; }
    printf -- '- %s；%s 上线的版本。\n' "$title" "$local_time"
  done <<< "$rows"
  rm -f -- "$issues_file"
}

maintainer_health_mail_no_launch_reason() {
  printf '没有新版本通过上线验证'
}

maintainer_health_mail_no_work_reason() {
  local active="${1:-null}" queued="${2:-null}"
  [[ "$active" =~ ^[0-9]+$ ]] && (( active == 0 )) || return 0
  case "$queued" in
    0) printf '当前无人处理：没有符合条件的待办事项。' ;;
    ''|null) printf '当前无人处理：待领取队列状态待核实。' ;;
    *[!0-9]*) printf '当前无人处理：待领取队列状态待核实。' ;;
    *) printf '当前无人处理：仍有待领取事项在队列中。' ;;
  esac
}

maintainer_health_mail_current_anomalies() {
  local home="$1" now="$2" user_home runtime_dir scorecard generated sampled_epoch age result
  user_home="${home%/.zenoforge}"
  [ "$user_home" != "$home" ] || user_home="$home"
  runtime_dir="$(maintainer_health_mail_runtime_dir "$home")"
  scorecard="$runtime_dir/node-health.json"
  [ -r "$scorecard" ] || { printf '调度评分样本待补'; return 0; }
  generated="$(jq -r '.generated // empty' "$scorecard" 2>/dev/null || true)"
  sampled_epoch="$(agent_epoch -u "$generated" 2>/dev/null || true)"
  if ! [[ "$sampled_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then
    printf '调度评分样本待补'
    return 0
  fi
  age=$((now - sampled_epoch))
  if (( age < 0 || age > 43200 )) || ! jq -e '.metrics | type == "array"' "$scorecard" >/dev/null 2>&1; then
    printf '调度评分样本待补'
    return 0
  fi
  # The scorecard's desc is English for some metrics; the mail shows the Chinese label by metric id instead.
  # A desc with no Latin letters is already Chinese and passes through. Unknown English metrics fall back to the generic label.
  local labels='{"merge.green_to_merge_max_min":"最后一项必需检查通过到合入的最长等待（分钟，近24小时）","delivery.merged_not_live":"已合入但未上线的产品提交数","merge.conflict_repairs_per_day":"近24小时合并冲突后由修复接手的次数","ci.red_after_approve_pct":"批准后持续集成又失败的比例","scheduler.tick_gap_p50":"调度两拍间隔中位数（秒）","scheduler.merge_pass_gap_min":"合并车道距上次运行的分钟数（有待合并单时）","release.hours_waiting":"当前发布批次已等待小时数","workorders.over_standard":"超出花费上限的未结工单数","delivery.issue_to_accept_p50_30d_hours":"近30天从提出到验收的中位时长（小时）","delivery.issue_to_accept_p95_30d_hours":"近30天从提出到验收的第95百分位时长（小时）","delivery.unlinked_units_30d":"近30天已验收单元缺少关联记录的数量","delivery.unlinked_incidents_30d":"近30天生产事故和告警未关联已验收单元的数量","flow.merge_rate_per_hour":"近24小时每小时合入数（目标6.5）","flow.wip_age_stage_p90_hours":"各环节未完成单元的第90百分位等待时长（小时）","flow.wait_stage_p90_hours":"等待前置单元或搁置的第90百分位时长（小时）","flow.slot_idle_hours":"修复或复审工人空闲而队列有任务的小时数","flow.main_red_hours":"窗口内主线变红的小时数","flow.in_out_imbalance":"窗口内进入与合入落地单元数的差额","release.hours_since_release":"距上次生产变更的小时数"}'
  result="$(jq -r --argjson labels "$labels" '[.metrics[] | select(.status == "UNHEALTHY") | (.desc // "") as $d | if ($d == "" or ($d | test("[A-Za-z]"))) then ($labels[.id // ""] // "调度指标异常") else $d end] | .[:5] | if length == 0 then "未发现超出健康线的调度指标" else "超出健康线的调度指标：" + join("；") end' "$scorecard")" || return 1
  printf '%s' "$result"
}

maintainer_health_mail_contract_inbox() {
  local home="$1" reason="$2"
  AGENT_HOME="$home" supervisor_inbox_append_once "founder-mail-output-contract:$reason" \
    "founder-mail-output-contract status=failed rules=$reason"
}

maintainer_health_mail_deliver() {
  local ledger="$1" now="$2" slot="$3" subject="$4" body="$5" events="$6" claim home contract_errors isolated row key reason
  home="${ledger%/night/founder-health-mail.json}"
  if ! contract_errors="$(maintainer_health_mail_output_contract "$body" "$now")"; then
    isolated="$(maintainer_health_mail_output_contract "$body" "$now" isolate-lines)" || return 1
    while IFS= read -r row; do
      key="$(jq -r '.key' <<< "$row")" || return 1
      reason="$(jq -r '.reason' <<< "$row")" || return 1
      if ! jq -e --arg key "$key" '(.reported_items // {}) | has($key)' "$ledger" >/dev/null; then
        AGENT_HOME="$home" supervisor_inbox_append_once "founder-mail-item-rejected:$key" \
          "founder-mail-item-rejected key=$key reason=$reason 不可读行已隔离，其他邮件内容继续发送" || return 1
        maintainer_health_mail_mark_reported "$ledger" "$key" "$now" "$reason" || return 1
      fi
    done < <(jq -c '.rejected[]' <<< "$isolated")
    body="$(jq -r '.body' <<< "$isolated")" || return 1
    if ! contract_errors="$(maintainer_health_mail_output_contract "$body" "$now")"; then
      maintainer_health_mail_contract_inbox "$home" "${contract_errors:-validator-failed}" || return 1
      return 1
    fi
  fi
  claim="$(maintainer_health_mail_claim_digest "$ledger" "$slot" "$now" "$events")" || return 1
  [ "$claim" = reserved ] || return 0
  if notify_maintainer_health "$subject" "$body"; then
    maintainer_health_mail_mark_sent "$ledger" "$now"
    return $?
  fi
  if [ "${NOTIFY_LAST_SEND_RETRY_SAFE:-0}" = 1 ]; then
    maintainer_health_mail_release_digest "$ledger" "$slot" >/dev/null || return 1
  fi
  return 1
}

maintainer_health_mail_tick() {
  local home="$1" now="${2:-$(date +%s)}" ledger
  local slot last_slot events repo_root facts subject body stored
  ledger="$home/night/founder-health-mail.json"
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  maintainer_health_mail_incident_tick "$ledger" "$now" || return 1
  # A tick killed after claiming its slot (timeout) leaves the slot reserved and the events marked reported: release stale claims.
  if jq -e --argjson now "$now" '.last_digest_claim != null and ($now - .last_digest_attempted_at > 900)' "$ledger" >/dev/null; then
    maintainer_health_mail_release_digest "$ledger" "$(jq -r '.last_digest_slot' "$ledger")" >/dev/null || return 1
  fi
  slot="$(maintainer_health_mail_slot_key "$now")" || return 1
  last_slot="$(jq -r '.last_digest_slot' "$ledger")" || return 1
  [ "$slot" != "$last_slot" ] || return 0
  # Daytime only: a tick outside the window (a late timer, a reboot) skips the day instead of mailing in the evening.
  if ! owner_report_in_send_window "$now"; then
    printf 'owner report: outside the daytime send window, skipped\n'
    return 0
  fi
  # The daily report consumes every queued change notice: its sections are
  # computed from the primary records, so the notices are marked reported here
  # and never repeat in a later report.
  events="$(jq -c '[.pending_events // {} | to_entries[] | .value] | sort_by([.section,.created_at,.key])' "$ledger")" || return 1
  repo_root="${ZF_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
  facts="$(maintainer_health_mail_daily_facts "$home" "$ledger" "$now" "$repo_root")" || return 1
  subject="$(maintainer_health_mail_subject "$facts")" || return 1
  body="$(maintainer_health_mail_build_body "$facts")" || return 1
  stored="$(owner_report_snapshot_write "$facts" "$home" "$now")" || stored=failed
  case "$stored" in stored|exists) ;; *) printf 'owner report: snapshot not stored: %s\n' "$stored" >&2 ;; esac
  maintainer_health_mail_deliver "$ledger" "$now" "$slot" "$subject" "$body" "$events"
}


# --- Perf-report helpers ---------------------------------------------------------
# The helpers below feed engine/night/daily-perf-report.sh (its own daily file
# and supervisor notes). They are not part of the owner mail.

maintainer_health_mail_alert_stats() {
  local agent_dir="$1" end_epoch="$2" repo_root="$3" end_iso since_iso day offset
  local transition_file="$agent_dir/state/ticket-transitions.jsonl"
  local -a alert_files=()
  local alert_filter
  end_iso="$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  since_iso="$(date -u -d "@$((end_epoch - 172800))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  for offset in 0 1 2; do
    day="$(date -u -d "@$((end_epoch - offset * 86400))" +%Y-%m-%d)" || return 1
    [ -r "$agent_dir/logs/supervisor-alerts-$day.jsonl" ] && alert_files+=("$agent_dir/logs/supervisor-alerts-$day.jsonl")
  done
  [ -r "$transition_file" ] || transition_file=/dev/null
  if ((${#alert_files[@]} == 0)); then
    printf '{"tracking":false,"classes":[]}\n'
    return 0
  fi
  alert_filter='
        def acted($alert; $rows):
          any(($alert.targets // [])[];
            . as $target |
            if $target.type == "issue" then
              (any($changes[]?; .issue == ($target.id | tonumber) and .from_stage != .to_stage
                and .ts > $alert.at and .ts <= (($alert.at | fromdateiso8601) + 86400 | todateiso8601)))
              or any($commits[]?; .at > ($alert.at | fromdateiso8601)
                and .at <= (($alert.at | fromdateiso8601) + 86400)
                and (.subject | test("(^|[^0-9])#?" + $target.id + "([^0-9]|$)|issue[[:space:]#]+" + $target.id + "([^0-9]|$)"; "i")))
            elif $target.type == "node" and ($alert.state // "") != "" then
              any($rows[]; .at > $alert.at
                and .at <= (($alert.at | fromdateiso8601) + 86400 | todateiso8601)
                and (.state // "") != "" and .state != $alert.state
                and any((.targets // [])[]; .type == "node" and .id == $target.id))
            else false end);
        . as $rows
        | [ $rows[] | select(.decision == "wake" and ((.targets // []) | length > 0)
            and .at >= $since and (.at | fromdateiso8601) <= ($now - 86400))
            | . as $alert | {kind,acted:acted($alert; $rows)} ] as $mature
        | [ $rows[] | select(.at >= ($now - 86400 | todateiso8601) and .at <= ($now | todateiso8601)) ] as $recent
        | (([$mature[].kind] + [$recent[].kind]) | unique) as $kinds
        | {tracking:any($rows[]; .at >= $since and .at <= ($now|todateiso8601)),classes:[ $kinds[] as $kind
            | [$mature[] | select(.kind == $kind)] as $measured
            | [$recent[] | select(.kind == $kind and .decision != "wake")] as $demoted
            | (if ($measured|length) > 0 then ([$measured[] | select(.acted)]|length) / ($measured|length) else null end) as $rate
            | {kind:$kind,demoted_count:($demoted|length),sample_count:($measured|length),action_rate:$rate,
               low_action:($kind != "node-stuck-30min" and ($measured|length) >= 5 and $rate < 0.1)} ]}'
  if git -C "$repo_root" show-ref --verify --quiet refs/remotes/origin/main; then
    cat -- "${alert_files[@]}" | jq -Rc 'fromjson? | select(type == "object")' |
      jq -s --argjson now "$end_epoch" --slurpfile changes "$transition_file" --arg since "$since_iso" \
        --slurpfile commits <(git -C "$repo_root" log --since="$since_iso" --until="$end_iso" \
          --format='%ct%x09%s' origin/main 2>/dev/null | jq -Rc 'split("\t") as $row | ($row[0] | tonumber?) as $at | select($at != null) | {at:$at,subject:$row[1]}') \
        "$alert_filter"
  else
    cat -- "${alert_files[@]}" | jq -Rc 'fromjson? | select(type == "object")' |
      jq -s --argjson now "$end_epoch" --slurpfile changes "$transition_file" --arg since "$since_iso" \
        --argjson commits '[]' "$alert_filter"
  fi
}

maintainer_health_mail_measure() {
  local agent_dir="$1" day="$2" end_epoch="$3" repo_root="${4:-}"
  local start_epoch end_iso start_iso wake_since_iso week_start end_stamp
  local spend_file incident_file wake_file spend_facts incident_facts wake_facts alert_facts
  local calls=0 tokens=0 released=0 deploys=0 wakeups_24h=null wakeups_day=null tokens_per_release=null
  local wake_tracking=false
  local recurrence_tracking=false recurrences_day=0 recurrences_7d=0 recurrence_categories='[]'
    local implement_runs=0 implement_result_count=0 implement_successes=0 implement_success_rate=null
  local repeat_failures=0 oldest_queue_age=null false_freezes=0 alert_tracking=false alert_classes='[]'
  local file stamp key value issue state_facts
  local -A wakes_by_kind=() deployed_issues=()
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$end_epoch" =~ ^[0-9]+$ ]] || return 1
  start_epoch="$(date -u -d "$day 00:00:00" +%s)" || return 1
  end_iso="$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  start_iso="$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  wake_since_iso="$(date -u -d "@$((end_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  week_start="$(date -u -d "$day 6 days ago" +%Y-%m-%d)" || return 1
  end_stamp="$(date -u -d "@$end_epoch" +%Y%m%dT%H%M%SZ)" || return 1
  if [ -z "$repo_root" ]; then
    repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 1
  fi
  spend_file="$agent_dir/spend/$day.log"
  incident_file="${AGENT_INCIDENT_GUARDS_FILE:-}"
  if [[ -z "$incident_file" ]]; then
    incident_file="$(zf_config_file state/incident-guards.json 2>/dev/null || true)"
    [[ -n "$incident_file" ]] || incident_file="$repo_root/${ZF_PACK_REL:-engine}/state/incident-guards.json"
  fi
  wake_file="$agent_dir/logs/supervisor-wakes.log"
  if [ -r "$spend_file" ]; then
    spend_facts="$(awk -F '\t' -v start="$start_epoch" -v end="$end_epoch" \
      '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end { calls++; if ($6 ~ /^[0-9]+$/) tokens += $6 } END { printf "%d\t%.0f\n", calls, tokens }' \
      "$spend_file")" || return 1
    IFS=$'\t' read -r calls tokens <<< "$spend_facts"
  fi
  # 2026-10-05: three jq processes per state file (855 files) took ~20 s at load 27;
  # one jq over every file takes under a second.
  local -a state_files=("$agent_dir"/state/*.json)
  if [ -f "${state_files[0]}" ]; then
    state_facts="$(jq -nr --arg day "$day" --arg since "$wake_since_iso" --arg time_end "$end_iso" '
      reduce inputs as $s ([0,0,0,0];
        .[0] += (try (if $s.released == true and $s.closed_by_pipeline == true
            and ($s.run.concluded_at // "") >= ($day + "T00:00:00Z") and ($s.run.concluded_at // "") <= $time_end
          then 1 else 0 end) catch 0)
        | (try ($s.unit_results.implement as $unit
            | if (($unit.result // "") != "" and ($unit.recorded_at // "") >= $since and ($unit.recorded_at // "") <= $time_end)
              then [1, (if $unit.result == "success" and (($unit.exit_status|tostring) == "0") then 1 else 0 end)]
              else [0,0] end) catch [0,0]) as $u
        | .[1] += $u[0] | .[2] += $u[1]
        | .[3] += (try ([$s.model_policy.failure?, $s.model_policy.retry_note?, ($s.model_policy.failures[]?)]
            | map(select(type == "object" and (.same_failure_streak // 0) >= 1
              and (.recorded_at // "") >= $since and (.recorded_at // "") <= $time_end))
            | unique_by(.recorded_at) | length) catch 0))
      | @tsv' "${state_files[@]}")" || return 1
    IFS=$'\t' read -r released implement_result_count implement_successes repeat_failures <<< "$state_facts"
  fi
  if (( implement_result_count > 0 )); then
    implement_success_rate="$(jq -nr --argjson success "$implement_successes" --argjson count "$implement_result_count" '$success / $count')" || return 1
  fi
  for file in "$agent_dir"/logs/implement-*.log; do
    [ -f "$file" ] || continue
    [[ "${file##*/}" =~ ^implement-[0-9]+-([0-9]{8}T[0-9]{6}Z)\.log$ ]] || continue
    stamp="${BASH_REMATCH[1]}"
    stamp="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"
    [[ "$stamp" > "$wake_since_iso" && "$stamp" < "$end_iso" ]] && implement_runs=$((implement_runs + 1))
  done
  if [ -r "$agent_dir/state/ticket-stage-status.json" ]; then
    oldest_queue_age="$(jq -r --argjson now "$end_epoch" '
      (.sampled_at | fromdateiso8601) as $sampled
      | if $sampled > $now or ($now - $sampled) > 14400 then null
        else ([.tickets[]? | select(.stage == "ready-for-agent" and (.stage_age_minutes|type) == "number")
          | .stage_age_minutes + (($now - $sampled) / 60 | floor)] | max // null) end' \
      "$agent_dir/state/ticket-stage-status.json" 2>/dev/null || printf 'null')" || return 1
  fi
  if [ -r "$agent_dir/state/ticket-transitions.jsonl" ]; then
    false_freezes="$(jq -sr --arg since "$wake_since_iso" --arg time_end "$end_iso" '
      . as $events
      | [ $events[] | select(.kind == "park" and .to_stage == "on-hold" and .ts >= $since and .ts <= $time_end) as $park
        | select(any($events[]; .issue == $park.issue and .from_stage == "on-hold" and .ts > $park.ts
          and .ts <= (($park.ts | fromdateiso8601) + 86400 | todateiso8601))) ] | length' \
      "$agent_dir/state/ticket-transitions.jsonl" 2>/dev/null || printf '0')" || return 1
  fi
  alert_facts="$(maintainer_health_mail_alert_stats "$agent_dir" "$end_epoch" "$repo_root")" || return 1
  alert_tracking="$(jq -r '.tracking' <<< "$alert_facts")" || return 1
  alert_classes="$(jq -c '.classes' <<< "$alert_facts")" || return 1
  if (( released > 0 )); then
    tokens_per_release="$(jq -nr --argjson tokens "$tokens" --argjson issues "$released" '($tokens / $issues) | round')" || return 1
  fi
  for file in "$agent_dir"/logs/release-e2e-*-"${day//-/}"T*.log; do
    [ -f "$file" ] || continue
    [[ "${file##*/}" =~ ^release-e2e-([0-9]+)-([0-9]{8}T[0-9]{6}Z)\..+\.log$ ]] || continue
    issue="${BASH_REMATCH[1]}"
    stamp="${BASH_REMATCH[2]}"
    [[ "$stamp" > "$end_stamp" ]] && continue
    deployed_issues["$issue"]=1
  done
  deploys="${#deployed_issues[@]}"
  if [ -r "$incident_file" ]; then
    incident_facts="$(jq -ce --arg day "$day" --arg week_start "$week_start" '
      .incidents as $rows |
      {tracking:any($rows[]; has("recurs_of")),
       day_count:([$rows[] | select(has("recurs_of") and .date == $day)] | length),
       week_count:([$rows[] | select(has("recurs_of") and (.date // "") >= $week_start and (.date // "") <= $day)] | length),
       week_categories:([$rows[] | select(has("recurs_of") and (.date // "") >= $week_start and (.date // "") <= $day) | (.class // "未分类")] | unique | sort)}' \
      < <(if [[ -n "${AGENT_INCIDENT_GUARDS_FILE:-}" ]]; then zf_incident_guards_read "$incident_file"; else python3 -B "$(dirname -- "${BASH_SOURCE[0]}")/../mac-autopilot/config_paths.py" --incident-guards "$incident_file"; fi))" || return 1
    recurrence_tracking="$(jq -r '.tracking' <<< "$incident_facts")" || return 1
    recurrences_day="$(jq -r '.day_count' <<< "$incident_facts")" || return 1
    recurrences_7d="$(jq -r '.week_count' <<< "$incident_facts")" || return 1
    recurrence_categories="$(jq -c '.week_categories' <<< "$incident_facts")" || return 1
  fi
  if [ -r "$wake_file" ]; then
    wake_tracking=true
    wake_facts="$(awk -v day_start="$start_iso" -v since="$wake_since_iso" -v end="$end_iso" '
      $1 >= since && $1 <= end { wakeups++ }
      $1 >= day_start && $1 <= end { today++; kind=$2; if (kind ~ /^[[:alnum:]_.-]+$/) kinds[kind]++ }
      END { printf "TOTAL\t%d\t%d\n", wakeups, today; for (kind in kinds) printf "%s\t%d\n", kind, kinds[kind] }
    ' "$wake_file")" || return 1
    while IFS=$'\t' read -r key value extra; do
      case "$key" in
        TOTAL) wakeups_24h="${value:-0}"; wakeups_day="${extra:-0}" ;;
        *) [[ "$value" =~ ^[0-9]+$ ]] && wakes_by_kind["$key"]="$value" ;;
      esac
    done <<< "$wake_facts"
  fi
  local wakes_by_kind_file wakes_by_kind_object kind output_rc
  wakes_by_kind_file="$(mktemp)" || return 1
  for kind in "${!wakes_by_kind[@]}"; do
    jq -cn --arg kind "$kind" --argjson count "${wakes_by_kind[$kind]}" '{($kind):$count}' >> "$wakes_by_kind_file" \
      || { rm -f -- "$wakes_by_kind_file"; return 1; }
  done
  wakes_by_kind_object="$(mktemp)" || { rm -f -- "$wakes_by_kind_file"; return 1; }
  jq -s 'add // {}' "$wakes_by_kind_file" > "$wakes_by_kind_object" \
    || { rm -f -- "$wakes_by_kind_file" "$wakes_by_kind_object"; return 1; }
  if jq -cSn --arg date "$day" --argjson calls "$calls" --argjson tokens "$tokens" \
    --argjson released_issues "$released" --argjson tokens_per_released_issue "$tokens_per_release" \
    --argjson deploys "$deploys" --argjson wakeups_24h "$wakeups_24h" --argjson wakeups_day "$wakeups_day" \
    --slurpfile wakes_by_kind "$wakes_by_kind_object" --argjson recurrence_tracking "$recurrence_tracking" \
    --argjson recurrences_day "$recurrences_day" --argjson recurrences_7d "$recurrences_7d" \
    --argjson recurrence_categories "$recurrence_categories" \
    --argjson wake_tracking "$wake_tracking" \
    --argjson implement_runs "$implement_runs" --argjson implement_result_count "$implement_result_count" \
    --argjson implement_successes "$implement_successes" --argjson implement_success_rate "$implement_success_rate" \
    --argjson oldest_queue_age "$oldest_queue_age" --argjson repeat_failures "$repeat_failures" \
    --argjson false_freezes "$false_freezes" --argjson alert_tracking "$alert_tracking" \
    --argjson alert_classes "$alert_classes" \
    '{date:$date,calls:$calls,tokens:$tokens,released_issues:$released_issues,
      tokens_per_released_issue:$tokens_per_released_issue,deploys:$deploys,
      wake_tracking:$wake_tracking,wakeups_24h:$wakeups_24h,wakeups_day:$wakeups_day,wakes_by_kind:$wakes_by_kind[0],
      recurrence_tracking:$recurrence_tracking,recurrences_day:$recurrences_day,
      recurrences_7d:$recurrences_7d,recurrence_categories:$recurrence_categories,
      implement_runs:$implement_runs,implement_result_count:$implement_result_count,
      implement_successes:$implement_successes,implement_success_rate:$implement_success_rate,
      oldest_queue_age_minutes:$oldest_queue_age,repeat_failures:$repeat_failures,false_freezes:$false_freezes,
      alert_tracking:$alert_tracking,alert_classes:$alert_classes}'; then
    output_rc=0
  else
    output_rc=$?
  fi
  rm -f -- "$wakes_by_kind_file" "$wakes_by_kind_object"
  return "$output_rc"
}

maintainer_health_mail_metric_lines() {
  local agent_dir="$1" now="$2" day measure recurrences avg wakeups success_rate queue_age alert_lines policy_file policy_tmp
  day="$(date -u -d "@$now" +%Y-%m-%d)" || return 1
  measure="$(maintainer_health_mail_measure "$agent_dir" "$day" "$now")" || return 1
  recurrences="$(jq -r 'if .recurrence_tracking then "\(.recurrences_7d)次" else "待统计" end' <<< "$measure")" || return 1
  avg="$(jq -r '.tokens_per_released_issue // "待统计"' <<< "$measure")" || return 1
  wakeups="$(jq -r 'if .wake_tracking then (.wakeups_24h|tostring) else "待统计" end' <<< "$measure")" || return 1
  success_rate="$(jq -r 'if .implement_success_rate == null then "待统计" else "\((.implement_success_rate * 100|round))%（\(.implement_successes)/\(.implement_result_count) 个终态结果）" end' <<< "$measure")" || return 1
  queue_age="$(jq -r 'if .oldest_queue_age_minutes == null then "待统计" else "\(.oldest_queue_age_minutes)分钟" end' <<< "$measure")" || return 1
  # A plain count, no class ids: ids like ticket-progress tripped the founder-mail internal-word filter and
  # the 2026-10-04 00Z and 08Z digests were refused.
  alert_lines="$(jq -r '[.alert_classes[] | select(.demoted_count > 0 or .low_action)]
    | if length == 0 then "" else
        "\(length)类，共\(map(.demoted_count) | add)次"
        + (map(select(.low_action)) | if length > 0 then "；其中\(length)类几乎没有带来处理动作，已列为待修" else "" end)
      end' <<< "$measure")" || return 1
  printf '本周同类问题复发：%s\n' "$recurrences"
  if [ "$wakeups" = 待统计 ]; then
    printf '过去24小时自动唤醒监督程序：待统计\n'
  else
    printf '过去24小时自动唤醒监督程序：%s次\n' "$wakeups"
  fi
  printf '今日每张交付票平均消耗模型令牌：%s\n' "$avg"
  printf '今日部署：%s次\n' "$(jq -r '.deploys' <<< "$measure")"
  printf '过去24小时 implement运行：%s次；终态结果成功率：%s\n' "$(jq -r '.implement_runs' <<< "$measure")" "$success_rate"
  printf '当前最长待处理队列年龄：%s；重复失败：%s次；24小时内解除的冻结：%s次（疑似误冻）\n' \
    "$queue_age" "$(jq -r '.repeat_failures' <<< "$measure")" "$(jq -r '.false_freezes' <<< "$measure")"
  printf '过去24小时被压下的内部提醒：%s\n' "${alert_lines:-无}"
  if [ "$(jq -r '.alert_tracking' <<< "$measure")" = true ]; then
    policy_file="$agent_dir/night/supervisor-alert-policy.json"
    mkdir -p "$agent_dir/night" || return 1
    policy_tmp="$(mktemp "${policy_file}.XXXXXX")" || return 1
    if ! jq -n --arg date "$day" --argjson classes "$(jq -c '[.alert_classes[] | select(.low_action) | .kind] | unique' <<< "$measure")" \
      '{date:$date,demoted_classes:$classes}' > "$policy_tmp"; then
      rm -f -- "$policy_tmp"
      return 1
    fi
    mv -f -- "$policy_tmp" "$policy_file" || { rm -f -- "$policy_tmp"; return 1; }
  fi
}

maintainer_health_mail_metrics_json() {
  local home="$1" mode="$2" anchor="$3" as_of="$4" work="${5:-}" current_start current_end previous_start previous_end week_start week_end earliest interval
  local current_day_end
  local periods_file work_file activity_json
  local -a metric_files=()
  interval="$(maintainer_health_mail_digest_interval_seconds)" || return 1
  current_start="$(date -u -d "$anchor 00:00:00" +%s)" || return 1
  current_day_end="$(date -u -d "$anchor +1 day 00:00:00" +%s)" || return 1
  current_end="$current_day_end"
  (( as_of < current_end )) && current_end="$as_of"
  previous_start="$(date -u -d "$anchor -1 day 00:00:00" +%s)" || return 1
  previous_end="$current_start"
  week_start="$(date -u -d "$anchor -7 days 00:00:00" +%s)" || return 1
  week_end="$(date -u -d "$anchor -6 days 00:00:00" +%s)" || return 1
  periods_file="$(mktemp)" || return 1
  work_file="$(mktemp)" || { rm -f -- "$periods_file"; return 1; }
  printf '{"current":{"start":%s,"end":%s},"previous":{"start":%s,"end":%s},"week":{"start":%s,"end":%s}}\n' \
    "$current_start" "$current_end" "$previous_start" "$previous_end" "$week_start" "$week_end" > "$periods_file"
  if [ -z "$work" ]; then work="$(maintainer_health_mail_work_counts "$home" "$as_of")" || work='{"active":null,"queued":null}'; fi
  printf '%s\n' "$work" > "$work_file"
  shopt -s nullglob
  metric_files=("$home"/metrics/efficiency-????-??.jsonl)
  shopt -u nullglob
  if ((${#metric_files[@]})); then
    activity_json="$(jq -sc --slurpfile periods "$periods_file" --slurpfile work "$work_file" '
      def epoch: try fromdateiso8601 catch null;
      def record_epoch: (.ts // .sampled_at // "") | try fromdateiso8601 catch null;
      def within($window): . as $row | ($row | record_epoch) as $at
        | ($at != null and $at >= $window.start and $at < $window.end);
      def events($rows; $type; $window): [$rows[] | select(.record_type == "event" and .event_type == $type and within($window))]
        | unique_by(.event_id // ([.event_type,.issue,.ts] | map(tostring) | join("|")));
      def stats($rows; $window):
        events($rows; "ticket-created"; $window) as $created_rows
        | events($rows; "github-closed"; $window) as $closed_rows
        | events($rows; "ticket-released"; $window) as $released_rows
        | ([$released_rows[] as $release
            | ($release | record_epoch) as $release_at
            | ([$rows[] | select(.record_type == "event" and .event_type == "ticket-created"
                and (.issue|tostring) == ($release.issue|tostring)
                and ((. | record_epoch) != null) and ((. | record_epoch) <= $release_at))]
               | min_by(.ts) // null) as $created
            | if $created == null then null else ($release_at - ($created | record_epoch)) / 3600 end]) as $lead_times
        | [$lead_times[] | select(type == "number")] as $known_lead_times
        | {launched:($released_rows|length),created:($created_rows|length),closed:($closed_rows|length),
           backlog:(($created_rows|length)-($closed_rows|length)),
           average_hours:(if ($known_lead_times|length)==0 then null
             else (($known_lead_times|add)/($known_lead_times|length)*10|round)/10 end),
           average_hours_reason:(if ($released_rows|length)==0 then "本期无上线事项"
             elif ($known_lead_times|length)==0 then "提出记录待核实" else "" end)};
      (flatten | map(select(type == "object"))) as $all_rows
      | ($periods[0]) as $p | ($work[0]) as $w
      | {current:stats($all_rows;$p.current),previous:stats($all_rows;$p.previous),week:stats($all_rows;$p.week),
         work:{active:$w.active,queued:$w.queued},periods:$p}
    ' "${metric_files[@]}")" || { rm -f -- "$periods_file" "$work_file"; return 1; }
  else
    activity_json='{"current":{"launched":null,"created":null,"closed":null,"backlog":null,"average_hours":null,"average_hours_reason":"上线记录待核实"},"previous":{"launched":null,"created":null,"closed":null,"backlog":null,"average_hours":null,"average_hours_reason":"上线记录待核实"},"week":{"launched":null,"created":null,"closed":null,"backlog":null,"average_hours":null,"average_hours_reason":"上线记录待核实"},"work":{"active":null,"queued":null}}'
  fi
  printf '%s\n' "$activity_json"
  rm -f -- "$periods_file" "$work_file"
}

maintainer_health_mail_efficiency_block() {
  local home="$1" mode="$2" anchor="$3" now="$4" work="${5:-}" data
  if [ -z "$work" ]; then work="$(maintainer_health_mail_work_counts "$home" "$now")" || work='{"active":null,"queued":null}'; fi
  data="$(maintainer_health_mail_metrics_json "$home" "$mode" "$anchor" "$now" "$work")" || return 1
  maintainer_health_mail_render_efficiency "$data" "$mode"
}

maintainer_health_mail_render_efficiency() {
  local data="$1" mode="$2" mode_file status
  mode_file="$(mktemp)" || return 1
  printf '"%s"\n' "$mode" > "$mode_file"
  jq -r --slurpfile render_mode "$mode_file" '
    def value($n; $unit; $reason): if $n == null then $reason else ($n|tostring) + $unit end;
    def change($current; $old; $unit; $reason):
      if $current == null then $reason
      elif $old == null then "缺少对比数据"
      elif $old <= 0 then ($current - $old) as $delta
        | (if $delta > 0 then "+" else "" end) + ($delta|tostring) + $unit
      else (($current - $old) / $old * 100 | round) as $percent
        | (if $percent > 0 then "↑" elif $percent < 0 then "↓" else "→" end)
          + (($percent|if . < 0 then -. else . end)|tostring) + "%（上期" + ($old|tostring) + $unit + "）"
      end;
    def row($label; $key; $unit; $reason):
      "| " + $label + " | " + value(.current[$key];$unit;(.current[$key + "_reason"] // $reason)) + " | "
      + change(.current[$key];.previous[$key];$unit;(.current[$key + "_reason"] // $reason)) + " | "
      + change(.current[$key];.week[$key];$unit;(.current[$key + "_reason"] // $reason)) + " |";
    def work_value: if .work.active == null or .work.queued == null then "工作数量待核实"
      else (.work.active|tostring) + "/" + (.work.queued|tostring) + "项" end;
    def work_change: if .work.active == null or .work.queued == null then "工作数量待核实" else "工作数量仅展示当前" end;
    "效率对比（本期：报告日；环比：前一日；同比：上周同日）\n"
    + "| 指标 | 本期 | 环比 | 同比 |\n| --- | ---: | --- | --- |\n"
    + row("上线的改进项数";"launched";"项";"上线记录待核实") + "\n"
    + row("关闭的事项";"closed";"项";"关闭记录待核实") + "\n"
    + row("新增事项";"created";"项";"新增记录待核实") + "\n"
    + row("积压增减";"backlog";"项";"积压数据待核实") + "\n"
    + row("平均从提出到上线";"average_hours";"小时";"上线记录待核实") + "\n"
    + "| 正在做/排队 | " + work_value + " | "
    + work_change + " | " + work_change + " |"
  ' <<< "$data"
  status=$?
  rm -f -- "$mode_file"
  return "$status"
}

maintainer_health_mail_pipeline_efficiency_block() {
  local home="$1" period="$2" anchor="$3" script_dir report now_iso
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  if ! report="$(node "$script_dir/efficiency-regression.mjs" daily --home "$home" --day "$anchor" --read-only 2>/dev/null)"; then
    printf '**流水线效率**\n- 最慢环节：统计样本待补。\n- 最慢检查：统计样本待补。'
    return 0
  fi
  jq -r '
    def duration($seconds):
      if $seconds == null then "样本待补"
      else (($seconds / 3600 * 10 | round) / 10) as $hours
        | if $hours >= 1 then "\($hours)小时"
          else ((($seconds / 60 * 10 | round) / 10) | tostring) + "分钟" end
      end;
    def change($current; $previous):
      if $previous == null then "缺少前期样本"
      elif $current == $previous then "持平"
      elif $previous == 0 then (if $current > $previous then "增加" + duration($current - $previous) else "缩短" + duration($previous - $current) end)
      elif $current > $previous then
        "增加" + (((($current - $previous) / ($previous|abs) * 100) | round) | tostring) + "%"
      else
        "缩短" + (((($previous - $current) / ($previous|abs) * 100) | round) | tostring) + "%"
      end;
    (.slowest_nodes // [] | .[0] // null) as $stage
    | (.slowest_checks // [] | .[0] // null) as $check
    | "**流水线效率**\n"
      + (if $stage == null then "- 最慢环节：本期无环节样本。"
         else "- 最慢环节：\($stage.label)，均值 \(duration($stage.mean_seconds))；前一日 "
           + change($stage.mean_seconds;$stage.comparison.previous_mean_seconds)
           + "；上周 " + change($stage.mean_seconds;$stage.comparison.seven_day_mean_seconds) + "。" end)
      + "\n"
      + (if $check == null then "- 最慢检查：本期无检查样本。"
         else ($check.slowest_metric // "run") as $metric
           | $check[$metric] as $measure
           | "- 最慢检查：\($check.label)\(if $metric == "queue" then "排队" else "运行" end)，均值 \(duration($measure.mean_seconds))；前一日 "
             + change($measure.mean_seconds;$measure.comparison.previous_mean_seconds)
             + "；上周 " + change($measure.mean_seconds;$measure.comparison.seven_day_mean_seconds) + "。" end)
  ' <<< "$report"
}

# The generic plain-report validator the daily perf report file is checked
# against. The owner mail has its own contract above; this one keeps the
# perf-report file's checks unchanged (dates, ids, tables).
maintainer_health_mail_report_contract() {
  local body="$1" now="$2" maintainer_tz
  maintainer_tz="$(maintainer_timezone)" || { printf 'comms-profile-unreadable'; return 1; }
  printf '%s' "$body" | ZF_MAINTAINER_TZ="$maintainer_tz" python3 -c '
import os
import re
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

text = sys.stdin.read()
try:
    now = int(sys.argv[1])
except (IndexError, ValueError):
    print("invalid-clock")
    raise SystemExit(1)
def validate(text):
    errors = set()
    if re.search(r"(?<![0-9])1月1日", text) or "1970" in text:
        errors.add("epoch-date")
    if re.search(r"#[0-9]+", text):
        errors.add("issue-id")
    if re.search(r"(?<![A-Za-z0-9])[0-9a-fA-F]{7,}(?![A-Za-z0-9])", text):
        errors.add("commit-id")
    if set(re.findall(r"[A-Za-z]+", text)) - {"GitHub"}:
        errors.add("ascii-text")
    reason = re.compile(r"(?:缺少[^，；。]{1,16}(?:数据|样本)|[^，；。]{1,18}(?:待核实|待补|待统计|无样本|没有事项)|本期无.{1,12}事项|工作数量仅展示当前)")
    table_expected_rows = None
    table_row_count = 0
    table_headers = {
        "| 指标 | 本期 | 环比 | 同比 |": 6,
    }
    in_table = False
    for line in text.splitlines():
        if line.strip() in table_headers:
            if in_table and table_expected_rows is not None and table_row_count != table_expected_rows:
                errors.add("metric-table-incomplete")
            in_table = True
            table_expected_rows = table_headers[line.strip()]
            table_row_count = 0
            continue
        if re.match(r"^\s*\|\s*指标\s*\|", line):
            if in_table and table_expected_rows is not None and table_row_count != table_expected_rows:
                errors.add("metric-table-incomplete")
            errors.add("metric-table-header")
            in_table = False
            table_expected_rows = None
            table_row_count = 0
            continue
        if in_table and line.strip().startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if cells and set(cells[0]) <= {"-", ":"}:
                continue
            if len(cells) == 4:
                table_row_count += 1
                rows = [cells[1:]]
            else:
                errors.add("metric-table-shape")
                rows = []
            for row in rows:
                for cell in row:
                    if not cell or "暂无数据" in cell:
                        errors.add("metric-cell-empty")
                    if not re.search(r"\d", cell) and not reason.fullmatch(cell):
                        errors.add("metric-cell-unexplained")
        elif in_table and line.strip():
            if table_expected_rows is not None and table_row_count != table_expected_rows:
                errors.add("metric-table-incomplete")
            in_table = False
            table_expected_rows = None
            table_row_count = 0
    if in_table and table_expected_rows is not None and table_row_count != table_expected_rows:
        errors.add("metric-table-incomplete")
    return errors

errors = validate(text)
if errors:
    print(",".join(sorted(errors)))
    raise SystemExit(1)
' "$now"
}

# Prints credential verdict. Probe output is discarded; only allowlisted
# failure classes reach the maintainer mail ledger.
maintainer_health_mail_credential_status() {
  local home="$1"
  local log="$home/logs/notify.log" last_strict gcloud_bin gws_bin
  local gcloud_status=unavailable gws_status=unavailable stderr_file last_sent=0
  local primary_status=UNKNOWN primary_detail='reason=probe-unavailable'
  last_strict="$(awk -F '\t' '
    function field(prefix, i) { for (i=2; i<=NF; i++) if (index($i, prefix)==1) return substr($i, length(prefix)+1); return "" }
    {
      mode=field("mode="); result=field("result="); key=field("recipients=") SUBSEP field("subject=") SUBSEP field("issue=")
      if (mode == "strict" && (result == "failed" || result == "sent")) { latest=result; reason=field("reason=") }
      else if (mode == "" && result == "strict") pending[key]=1
      else if (mode == "" && pending[key] && (result == "failed" || result == "sent")) {
        latest=result; reason=field("reason="); delete pending[key]
      }
    }
    END { if (latest == "failed") print (reason == "" ? "unknown" : reason); else if (latest == "sent") print "sent" }
  ' "$log" 2>/dev/null || true)"
  if [ "$last_strict" = sent ]; then
    last_strict=""
    last_sent=1
  fi
  if [ -n "$last_strict" ]; then
    case "$last_strict" in credential-expired|transport|contract-rejected|no-recipients|none|unknown) ;; *) last_strict=unknown ;; esac
  fi
  if [ -n "$last_strict" ]; then
    primary_status=BROKEN
    primary_detail="reason=last-strict-maintainer-send-failed cause=$last_strict"
  else
    gcloud_bin="${ZF_GCLOUD_BIN:-gcloud}"
    if command -v "$gcloud_bin" >/dev/null 2>&1; then
      stderr_file="$(mktemp)" || { printf 'UNKNOWN reason=probe-unavailable\n'; return 0; }
      if timeout 1 "$gcloud_bin" auth application-default print-access-token >/dev/null 2>"$stderr_file"; then
        gcloud_status=ok
      elif grep -Fq 'invalid_grant' "$stderr_file"; then
        gcloud_status=expired
      fi
      rm -f -- "$stderr_file"
    fi
    gws_bin="${ZF_GWS_BIN:-gws}"
    if command -v "$gws_bin" >/dev/null 2>&1; then
      stderr_file="$(mktemp)" || { printf 'UNKNOWN reason=probe-unavailable\n'; return 0; }
      if timeout 1 "$gws_bin" gmail users getProfile --params '{"userId":"me"}' >"$stderr_file" 2>&1; then
        gws_status=ok
      elif grep -Eiq 'HTTP[[:space:]]+401|Unauthorized|(^|[^0-9])401([^0-9]|$)' "$stderr_file"; then
        gws_status=unauthorized
      fi
      rm -f -- "$stderr_file"
    fi
    if [ "$gcloud_status" = expired ]; then
      primary_status=BROKEN
      primary_detail='reason=credential-expired'
    elif [ "$gws_status" = unauthorized ]; then
      primary_status=BROKEN
      primary_detail='reason=gws-401'
    elif [ "$gcloud_status" = ok ] && [ "$gws_status" = ok ]; then
      primary_status=OK
      primary_detail='reason=credential-probes-ok'
    elif [ "$last_sent" = 1 ]; then
      # The probes take 5-11 s against their 1 s cap under load, so they
      # rarely answer; the last real maintainer send is the stronger evidence.
      primary_status=OK
      primary_detail='reason=last-strict-maintainer-send-ok'
    fi
  fi
  printf '%s %s\n' "$primary_status" "$primary_detail"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/config.sh"
  NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  ledger="$NIGHT/founder-health-mail.json"
  command="${1:-}"
  case "$command" in
    status)
      now="${2:-$(date +%s)}"
      if ! maintainer_health_mail_ensure_ledger "$ledger" "$now"; then
        printf 'UNKNOWN mail-ledger-unreadable\n'
        exit 0
      fi
      printf '%s no-successful-mail-age-minutes=%s\n' \
        "$(maintainer_health_mail_node_status "$ledger" "$now")" \
        "$(( (now - $(jq -r 'if .last_sent_at > 0 then .last_sent_at else .started_at end' "$ledger")) / 60 ))"
      ;;
    credential-status)
      maintainer_health_mail_credential_status "$AGENT_HOME"
      ;;
    tick)
      export AGENT_HOME ZF_NIGHT_DIR="$NIGHT"
      DRY_RUN="${DRY_RUN:-0}"
      source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/notify.sh"
      maintainer_health_mail_tick "$AGENT_HOME"
      ;;
    resolve-incident)
      issue="${2:-}"
      reason="${3:-}"
      [[ "$issue" =~ ^[0-9]+$ && -n "$reason" ]] || {
        printf 'usage: %s resolve-incident <issue-number> <plain-language-reason>\n' "$0" >&2
        exit 2
      }
      export REPO AGENT_HOME ZF_NIGHT_DIR="$NIGHT"
      DRY_RUN="${DRY_RUN:-0}"
      source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/notify.sh"
      now="$(date +%s)"
      maintainer_health_mail_incident_mark_resolved "$ledger" "$issue" "$reason" "$now" >/dev/null
      maintainer_health_mail_incident_tick "$ledger" "$now" "$issue"
      ;;
    queue-event)
      key="${2:-}"
      section="${3:-}"
      text="${4:-}"
      now="${5:-$(date +%s)}"
      [[ -n "$key" && -n "$section" && -n "$text" && "$now" =~ ^[0-9]+$ ]] || {
        printf 'usage: %s queue-event <key> <section> <text> [epoch] | track-decision <issue-number> <subject> <decision-mail-body> [epoch]\n' "$0" >&2
        exit 2
      }
      maintainer_health_mail_record_event "$ledger" "$key" "$section" "$text" "$now"
      ;;
    track-decision)
      issue="${2:-}"
      subject="${3:-}"
      body="${4:-}"
      now="${5:-$(date +%s)}"
      [[ "$issue" =~ ^[0-9]+$ && -n "$subject" && "$now" =~ ^[0-9]+$ ]] || {
        printf 'usage: %s track-decision <issue-number> <subject> <decision-mail-body> [epoch]\n' "$0" >&2
        exit 2
      }
      decision_detail="$(maintainer_health_mail_decision_detail "$body")"
      question="$(jq -r '.question' <<< "$decision_detail")"
      recommendation="$(jq -r '.recommendation' <<< "$decision_detail")"
      maintainer_health_mail_track_important "$ledger" "decision:$issue:$subject" decision "$subject" \
        "$issue" "$now" "$question" "$recommendation"
      ;;
    render)
      # Same facts and text as the mail, printed only: nothing is sent or written.
      now="${2:-$(date +%s)}"
      repo_root="${ZF_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
      facts="$(maintainer_health_mail_daily_facts "$AGENT_HOME" "$ledger" "$now" "$repo_root")" || exit 1
      printf '%s\n\n%s\n' "$(maintainer_health_mail_subject "$facts")" "$(maintainer_health_mail_build_body "$facts")"
      ;;
    material) owner_report_material "$AGENT_HOME" "$ledger" "${2:-$(date +%s)}" ;;  # read-only, like render
    backfill-snapshots) owner_report_backfill_cli "$AGENT_HOME" "$ledger" "${2:-7}" "${3:-}" ;;  # writes only the snapshot dir
    *)
      printf 'usage: %s status [epoch] | render [epoch] | material [epoch] | backfill-snapshots [days] [anchor-epoch] | credential-status | tick | resolve-incident <issue-number> <reason> | queue-event <key> <section> <text> [epoch] | track-decision <issue-number> <subject> <decision-mail-body> [epoch]\n' "$0" >&2
      exit 2
      ;;
  esac
fi
