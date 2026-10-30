#!/usr/bin/env bash

# Sourceable helpers plus the six-hour maintainer health-mail digest.
if ! declare -F agent_epoch >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/lib.sh"
fi
# The comms formatter (maintainer timezone) is needed even when the caller already
# loaded lib.sh; tests that stub agent_epoch skip lib.sh, so load it directly.
if ! declare -F maintainer_local_time >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/comms-format.sh"
fi
# Post-land breakage MTTR feeds the efficiency block of the six-hour digest.
if ! declare -F post_land_mttr_summary >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/post-land-mttr.sh"
fi
maintainer_health_mail_slot_key() {
  local now="$1" interval
  interval="$(maintainer_health_mail_digest_interval_seconds)" || return 1
  [[ "$now" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ ]] || return 1
  date -u -d "@$((now / interval * interval))" +%Y%m%dT%HZ
}

maintainer_health_mail_digest_interval_seconds() {
  local state_dir
  state_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/state"
  jq -er '.digest_interval_seconds | select(type == "number" and . > 0 and . == floor)' \
    "$state_dir/founder-health-mail.json"
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
  local lock_fd tmp
  [[ -n "$key" && "$kind" =~ ^(outage|wrong-business-numbers|decision|team-blocker)$ && -n "$text" && "$now" =~ ^[0-9]+$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq --arg key "$key" --arg kind "$kind" --arg text "$text" --arg issue "$issue" --argjson now "$now" '
    (.important_items //= {}) | (.reported_items //= {})
    | if (.important_items[$key] // null) == null then
        .important_items[$key]={kind:$kind,text:$text,issue:$issue,opened_at:$now,last_reminded_at:$now,status:"open"}
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
  # Routine mail follows its configured interval; no successful send for seven hours is stuck.
  slow_after=$((interval + 300))
  stuck_after=25200
  if (( age >= stuck_after )); then printf 'STUCK\n'
  elif (( age >= slow_after )); then printf 'SLOW\n'
  else printf 'OK\n'; fi
}

maintainer_health_mail_claim_digest() {
  local ledger="$1" slot="$2" now="$3" events="${4:-[]}" interval lock_fd current last_sent_at tmp
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  interval="$(maintainer_health_mail_digest_interval_seconds)" || return 1
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || return 1
  jq -e 'type == "array" and all(.[]; (.key|type)=="string" and (.created_at|type)=="number")' <<< "$events" >/dev/null || return 1
  [ "$(jq -r 'length' <<< "$events")" -gt 0 ] || { printf 'no-change\n'; return 0; }
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  current="$(jq -r '.last_digest_slot' "$ledger")" || return 1
  last_sent_at="$(jq -r '.last_sent_at' "$ledger")" || return 1
  if (( last_sent_at > 0 && now - last_sent_at < interval )); then
    maintainer_health_mail_unlock "$lock_fd"
    printf 'cooldown\n'
    return 0
  fi
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

# Incident lifecycle shares the maintainer-mail ledger and lock. Reserving each
# send before Gmail prevents a lost response or overlapping tick from sending
# the same incident update twice.
maintainer_health_mail_incident_open() {
  local ledger="$1" issue="$2" subject="$3" what="$4" impact="$5" action="$6" promised="$7" now="$8" urgent="${9:-0}"
  local lock_fd existing tmp send_status important_kind incident_key what_file
  [[ "$issue" =~ ^[0-9]+$ && "$promised" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$urgent" =~ ^[01]$ ]] || return 1
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  existing="$(jq -r --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last | .status // empty' "$ledger")" || return 1
  if [ -n "$existing" ]; then
    if [ "$existing" = open ]; then
      what_file="$(jq_arg_file "$what")" || return 1
      tmp="$(mktemp "${ledger}.XXXXXX")" || { rm -f -- "$what_file"; return 1; }
      jq --argjson issue "$issue" --rawfile what "$what_file" --arg impact "$impact" --arg action "$action" --argjson urgent "$urgent" \
        '.incidents |= map(if .issue == $issue and .status == "open" then .what=$what | .impact=$impact | .action=$action | .urgent=((.urgent // false) or $urgent) else . end)' \
        "$ledger" > "$tmp" || { rm -f -- "$what_file" "$tmp"; return 1; }
      rm -f -- "$what_file"
      mv -f -- "$tmp" "$ledger" || { rm -f -- "$tmp"; return 1; }
    fi
    maintainer_health_mail_unlock "$lock_fd"
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
    if notify_maintainer_incident "$issue" "$subject" "$what" "$impact" "$action" "$promised" >/dev/null; then
      send_status=sent
    else
      send_status=failed
    fi
    maintainer_health_mail_incident_mark_mail_result "$ledger" "$issue" initial "$send_status" "$now" || return 1
  else
    maintainer_health_mail_record_event "$ledger" "$incident_key:opened" '事项变化' \
      "${subject}：$what 用户影响：$impact 当前处理：$action" "$now" incident >/dev/null || return 1
  fi
  printf 'opened\n'
}

maintainer_health_mail_incident_request_resolution() {
  local ledger="$1" issue="$2" kind="$3" reason="$4" now="$5" reference="${6:-}"
  local lock_fd status requested tmp reason_file
  [[ "$issue" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  [[ "$kind" == release || "$kind" == supervisor ]] || return 1
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
  local ledger="$1" now="$2" only_issue="${3:-}" issue lock_fd eligible tmp event kind reason subject what impact action immediate send_status incident_key
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
    # Before urgent existed, every incident was mailed immediately.
    jq --argjson issue "$issue" --argjson now "$now" \
      '.incidents |= map(if .issue == $issue and .status == "open" then .status="resolved" | .resolved_at=$now | .resolution_mail_status=(if .urgent == true or .initial_mail_status == "sent" or (has("urgent") | not) then "reserved" else "queued" end) else . end)' \
      "$ledger" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$ledger" || return 1
    event="$(jq -c --argjson issue "$issue" '[.incidents[]? | select(.issue == $issue)] | last' "$ledger")" || return 1
    maintainer_health_mail_unlock "$lock_fd"

    kind="$(jq -r '.resolution_kind' <<< "$event")"
    reason="$(jq -r '.resolution_reason' <<< "$event")"
    immediate="$(jq -r '.resolution_mail_status == "reserved"' <<< "$event")"
    incident_key="incident:$issue:$(jq -r '.opened_at' <<< "$event")"
    subject='线上服务已恢复'
    what="$reason"
    action='恢复确认已完成，无需处理。'
    if [ "$kind" = supervisor ] && [[ "$reason" == *误报* ]]; then
      impact='这是误报，不是用户可见的服务中断；生产服务一直正常，没有影响用户。'
    else
      impact='生产服务现已恢复，用户可以继续正常使用。'
    fi
    maintainer_health_mail_resolve_important "$ledger" "$incident_key" "$now" '事项变化' '' || return 1
    if [ "$immediate" = true ]; then
      if notify_maintainer_resolution "$issue" "$subject" "$what" "$impact" "$action" >/dev/null; then
        send_status=sent
      else
        send_status=failed
      fi
      # The outage end is itself reported immediately; persist its key before
      # returning so a later digest cannot repeat it after a restart.
      maintainer_health_mail_mark_reported "$ledger" "$incident_key:resolved" "$now" || return 1
      maintainer_health_mail_incident_mark_mail_result "$ledger" "$issue" resolution "$send_status" "$now" || return 1
    else
      maintainer_health_mail_record_event "$ledger" "$incident_key:resolved" '事项变化' \
        "生产服务状态已确认：$reason" "$now" incident >/dev/null || return 1
    fi
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

maintainer_health_mail_collect_reminders() {
  local ledger="$1" home="$2" now="$3" row key kind issue state_file state text opened last hours event_key lock_fd tmp node earliest_key reminder_for
  local -a items=()
  mapfile -t items < <(jq -c '(.important_items // {}) | to_entries[] | select(.value.status == "open")' "$ledger")
  for row in "${items[@]}"; do
    key="$(jq -r '.key' <<< "$row")"
    kind="$(jq -r '.value.kind' <<< "$row")"
    issue="$(jq -r '.value.issue // empty' <<< "$row")"
    text="$(jq -r '.value.text' <<< "$row")"
    if [ "$kind" = team-blocker ] && [[ "$key" =~ ^node-important:([^:]+):[0-9]+$ ]]; then
      node="${BASH_REMATCH[1]}"
      earliest_key="$(jq -r --arg node "$node" '
        [.important_items // {} | to_entries[] | select(.value.status == "open")
          | select(.key | test("^node-important:" + $node + ":[0-9]+$"))]
        | sort_by(.value.opened_at // 0) | .[0].key // empty
      ' "$ledger")" || return 1
      [ "$key" = "$earliest_key" ] || continue
    fi
    if [ "$kind" = decision ] && [[ "$issue" =~ ^[0-9]+$ ]]; then
      state_file="$home/state/$issue.json"
      if [ -r "$state_file" ]; then
        state="$(jq -r '.state // empty' "$state_file" 2>/dev/null || true)"
        if [ -n "$state" ] && [ "$state" != needs-info ]; then
          maintainer_health_mail_resolve_important "$ledger" "$key" "$now" '决定更新' "已收到你的答复：$text" || return 1
          continue
        fi
      fi
    fi
    exec {lock_fd}>"$ledger.lock" || return 1
    flock -x "$lock_fd" || return 1
    row="$(jq -c --arg key "$key" '.important_items[$key] // empty' "$ledger")" || return 1
    if [ -z "$row" ] || [ "$(jq -r '.status' <<< "$row")" != open ]; then
      maintainer_health_mail_unlock "$lock_fd"
      continue
    fi
    opened="$(jq -r '.opened_at' <<< "$row")"
    last="$(jq -r '.last_reminded_at // .opened_at' <<< "$row")"
    [[ "$opened" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || { maintainer_health_mail_unlock "$lock_fd"; continue; }
    (( now - last >= 14400 )) || { maintainer_health_mail_unlock "$lock_fd"; continue; }
    reminder_for="$key"
    if [ "$kind" = team-blocker ] && [[ "$key" =~ ^node-important:([^:]+):([0-9]+)$ ]]; then
      node="${BASH_REMATCH[1]}"
      opened="${BASH_REMATCH[2]}"
      text="$(maintainer_health_mail_anomaly_sentence "$node" open "$opened" "$now")" || return 1
    else
      hours=$(( (now - opened) / 3600 ))
      (( hours < 0 )) && hours=0
      text="仍在处理：${text}（已持续 ${hours} 小时）"
    fi
    event_key="reminder:$key:$now"
    tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
    if ! jq --arg key "$key" --arg event_key "$event_key" --arg text "$text" --arg reminder_for "$reminder_for" \
      --argjson now "$now" '
      (.pending_events //= {}) | .important_items[$key].last_reminded_at=$now
      | if (.reported_items // {}) | has($event_key) then . else
          .pending_events[$event_key]={key:$event_key,section:"仍在处理",text:$text,kind:"reminder",highlight:false,reminder_for:$reminder_for,created_at:$now}
        end
    ' "$ledger" > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    mv -f -- "$tmp" "$ledger" || return 1
    maintainer_health_mail_unlock "$lock_fd"
  done
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
  [ -d "$home/state" ] || { printf 'null\n'; return 0; }
  shopt -s nullglob
  state_files=("$home"/state/*.json)
  shopt -u nullglob
  ((${#state_files[@]})) || { printf '{"complete":true,"deployments":[]}\n'; return 0; }
  jq -cn '
    [inputs as $state
      | (input_filename | split("/")[-1] | rtrimstr(".json")) as $issue
      | select($issue | test("^[0-9]+$"))
      | select($state.deploy_state == "deployed" and ($state.deployed_sha // "") != "")
      | ($state.deployed_at // $state.run.deployed_at // $state.run.evidence.production_evidence_at // "") as $stamp
      | ($stamp | try fromdateiso8601 catch null) as $at
      | {issue:$issue,at:$at}] as $deployed
    | {complete:all($deployed[]; .at != null),deployments:[$deployed[] | select(.at != null) | {issue,at}]}
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
    | gsub("GitHub"; "代码平台")
    | if test("[一-龥]") and (test("[A-Za-z]") | not) then .[0:20] else "功能改进" end
  '
}

maintainer_health_mail_scrub_text() {
  printf '%s' "$1" | jq -Rr '
    gsub("#[[:space:]]*[0-9]+"; "")
    | gsub("[[:xdigit:]]{7,}"; "")
    | gsub("(?i)channel[[:space:]]+gateway"; "渠道网关")
    | gsub("(?i)agent"; "员工助手")
    | gsub("(?i)mcp"; "工具连接")
    | gsub("(?i)implement"; "开发")
    | gsub("(?i)canary"; "验证")
    | gsub("(?i)quarantine"; "暂缓")
    | gsub("(?i)rulings"; "规则核验")
    | gsub("(?i)health[[:space:]_-]*node"; "运行状态")
    | gsub("(?i)health"; "运行状态")
    | gsub("(?i)slots?"; "时段")
    | gsub("(?i)owners?"; "负责人")
    | gsub("(?i)pipeline"; "交付流程")
    | gsub("(?i)postsubmit"; "上线检查")
    | gsub("(?i)deploy"; "上线")
    | gsub("(?i)build"; "构建")
    | gsub("(?i)merge"; "合入")
    | gsub("(?i)advisor"; "业务评审")
    | gsub("(?i)node"; "环节")
    | gsub("[[:space:]]+"; " ")
  '
}

maintainer_health_mail_acceptance_events() {
  local ledger="$1" home="$2" now="$3" snapshot
  snapshot="$home/state/ticket-stage-status.json"
  local current_file catalog_file title_file current_ids previous_ids catalog titles title lines count key lock_fd tmp
  [ -r "$snapshot" ] || return 0
  current_file="$(mktemp)" || return 1
  catalog_file="$(mktemp)" || { rm -f -- "$current_file"; return 1; }
  title_file="$(mktemp)" || { rm -f -- "$current_file" "$catalog_file"; return 1; }
  if ! jq -c '[.tickets | to_entries[]? | select(.value.stage == "awaiting-release") | .key] | sort' "$snapshot" > "$current_file"; then
    rm -f -- "$current_file" "$catalog_file" "$title_file"
    return 1
  fi
  current_ids="$(cat "$current_file")" || return 1
  previous_ids="$(jq -c '.acceptance_snapshot.issues // []' "$ledger")" || return 1
  [ "$current_ids" != "$previous_ids" ] || { rm -f -- "$current_file" "$catalog_file" "$title_file"; return 0; }
  catalog="$(maintainer_health_mail_issue_catalog "$current_ids")" || { rm -f -- "$current_file" "$catalog_file" "$title_file"; return 0; }
  printf '%s\n' "$catalog" > "$catalog_file"
  if ! jq -nr --slurpfile ids "$current_file" --slurpfile issues "$catalog_file" '
    ($ids[0] | map({key:.,value:true}) | from_entries) as $wanted
    | $issues[0][]
    | select($wanted[.number|tostring] == true)
    | select(all(.labels[]?.name; . != "pipeline-system"))
    | select(.title | test("[一-龥]"))
    | .title | gsub("[\r\n]"; " ")
  ' > "$title_file"; then
    rm -f -- "$current_file" "$catalog_file" "$title_file"
    return 1
  fi
  titles=()
  while IFS= read -r title; do
    titles+=("$(maintainer_health_mail_plain_title "$title")")
  done < "$title_file"
  count="${#titles[@]}"
  if (( count > 0 )); then
    lines="$(printf '%s\n' "${titles[@]:0:5}" | sed 's/^/- /')"
    if (( count > 5 )); then lines+=$'\n'"等$((count - 5))项"; fi
    key="acceptance:$now"
    maintainer_health_mail_record_event "$ledger" "$key" '待验收' "$lines" "$now" acceptance >/dev/null || return 1
  fi
  exec {lock_fd}>"$ledger.lock" || return 1
  flock -x "$lock_fd" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  if ! jq --slurpfile acceptance "$current_file" --slurpfile time <(printf '%s\n' "$now") \
    '.acceptance_snapshot={issues:$acceptance[0],updated_at:($time[0]|tonumber)}' "$ledger" > "$tmp"; then
    rm -f -- "$tmp" "$current_file" "$catalog_file" "$title_file"
    maintainer_health_mail_unlock "$lock_fd"
    return 1
  fi
  mv -f -- "$tmp" "$ledger" || { maintainer_health_mail_unlock "$lock_fd"; return 1; }
  maintainer_health_mail_unlock "$lock_fd"
  rm -f -- "$current_file" "$catalog_file" "$title_file"
}

maintainer_health_mail_active_implements() {
  local units
  units="$(timeout 10 systemctl --user list-units 'zf-implement-*' --state=running --plain --no-legend 2>/dev/null)" || return 1
  awk '$1 ~ /^zf-implement-[0-9]+\.service$/ { n++ } END { print n+0 }' <<< "$units"
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

maintainer_health_mail_metrics_json() {
  local home="$1" mode="$2" anchor="$3" as_of="$4" work="${5:-}" current_start current_end previous_start previous_end week_start week_end earliest interval
  local periods_file work_file activity_json
  local -a metric_files=()
  if [ "$mode" = hourly ]; then
    interval="$(maintainer_health_mail_digest_interval_seconds)" || return 1
    current_end="$as_of"
    current_start=$((current_end - interval))
    previous_start=$((current_start - interval))
    previous_end="$current_start"
    week_start=$((current_start - 86400))
    week_end=$((current_end - 86400))
  else
    current_start="$(date -u -d "$anchor 00:00:00" +%s)" || return 1
    current_end="$(date -u -d "$anchor +1 day 00:00:00" +%s)" || return 1
    previous_start="$(date -u -d "$anchor -1 day 00:00:00" +%s)" || return 1
    previous_end="$current_start"
    week_start="$(date -u -d "$anchor -7 days 00:00:00" +%s)" || return 1
    week_end="$(date -u -d "$anchor -6 days 00:00:00" +%s)" || return 1
  fi
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

maintainer_health_mail_pipeline_efficiency_block() {
  local home="$1" period="$2" anchor="$3" script_dir report now_iso
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  if [ "$period" = hourly ]; then
    now_iso="$(date -u -d "@$anchor" +%Y-%m-%dT%H:%M:%SZ)" || return 1
    if ! report="$(node "$script_dir/efficiency-regression.mjs" summary --home "$home" --now "$now_iso" 2>/dev/null)"; then
      printf '**流水线效率**\n- 最慢环节：统计样本待补。\n- 最慢检查：统计样本待补。'
      return 0
    fi
    jq -r '
      def duration($seconds):
        if $seconds == null then "样本待补"
        elif $seconds >= 3600 then ((($seconds / 3600 * 10 | round) / 10) | tostring) + "小时"
        elif $seconds >= 60 then ((($seconds / 60 * 10 | round) / 10) | tostring) + "分钟"
        else (($seconds|round)|tostring) + "秒" end;
      def hours($value):
        if $value == null then "数据待补" else (((($value * 10) | round) / 10) | tostring) + "小时/天" end;
      def coverage($value):
        if $value == null then "覆盖待补" else (((($value * 100) | round) | tostring) + "%") end;
      def change($current; $previous):
        if $current == null then "本期数据待补"
        elif $previous == null then "数据待补"
        elif $current == $previous then "持平"
        elif $previous <= 0 then (if $current > $previous then "增加" + duration($current - $previous) else "缩短" + duration($previous - $current) end)
        elif $current > $previous then "增加" + (((($current - $previous) / $previous * 100) | round) | tostring) + "%"
        else "缩短" + (((($previous - $current) / $previous * 100) | round) | tostring) + "%" end;
      (.current_24h.metrics // {}) as $current
      | (.previous_24h.metrics // {}) as $previous
      | (.weekly_delivery // {}) as $delivery
      | (.weekly_time_sinks.special_waits // {}) as $waits
      | ([
          {label:"排队到开始开发",value:$current.queue_to_implement_seconds,old:$previous.queue_to_implement_seconds},
          {label:"开发到合入",value:$current.implement_to_merge_seconds,old:$previous.implement_to_merge_seconds},
          {label:"合入到上线",value:$current.merge_to_release_seconds,old:$previous.merge_to_release_seconds}
        ] | map(select(.value != null)) | max_by(.value) // null) as $stage
      | ([
          {label:"自动化检查排队",value:$current.ci_queue_seconds,old:$previous.ci_queue_seconds},
          {label:"自动化检查运行",value:$current.ci_run_seconds,old:$previous.ci_run_seconds}
        ] | map(select(.value != null)) | max_by(.value) // null) as $check
      | "**流水线效率**\n"
        + (if $stage == null then "- 最慢环节：本期样本待补。"
           else "- 最慢环节：\($stage.label)，均值 \(duration($stage.value))；前一日\(change($stage.value;$stage.old))。" end)
        + "\n"
        + (if $check == null then "- 最慢检查：本期样本待补。"
           else "- 最慢检查：\($check.label)，均值 \(duration($check.value))；前一日\(change($check.value;$check.old))。" end)
        + "\n- 近7天从工单提出到真实上线：\(duration($delivery.open_to_released.median_seconds))；样本 \($delivery.open_to_released.samples // 0)/\($delivery.product_release_count // 0)，覆盖 \(coverage($delivery.open_to_released.coverage))。"
        + "\n- 五阶段事项小时/天（覆盖率）：实现 \(hours($delivery.stages.implementation.issue_hours_per_day)) \(coverage($delivery.stages.implementation.coverage))；检查 \(hours($delivery.stages.checks.issue_hours_per_day)) \(coverage($delivery.stages.checks.coverage))；合并 \(hours($delivery.stages.merge.issue_hours_per_day)) \(coverage($delivery.stages.merge.coverage))；构建/滚动 \(hours($delivery.stages.build_roll.issue_hours_per_day)) \(coverage($delivery.stages.build_roll.coverage))；生产验收 \(hours($delivery.stages.production_proof.issue_hours_per_day)) \(coverage($delivery.stages.production_proof.coverage))。"
        + "\n- 独立耗时：顾问等待 \(hours($waits.advisor_issue_hours_per_day))；暂缓 \(hours($waits.hold_issue_hours_per_day))；容器阶段等待 \(hours($waits.container_issue_hours_per_day))；检查执行机时间 \(duration($delivery.ci_runner_seconds))，容器化检查任务执行时间 \(duration($delivery.testcontainers_job_runner_seconds))（执行机时间不计入事项等待）。"
        + (if $delivery.window.complete == true then "" else "\n- 历史覆盖不足7天：上线前阶段时间戳无法恢复；未使用标签或关闭时间回填。" end)
    ' <<< "$report"
    return $?
  fi
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

maintainer_health_mail_pressure_snapshot() {
  local load5 cpu_psi memory_psi
  load5="$(awk '{print $2}' /proc/loadavg 2>/dev/null || true)"
  cpu_psi="$(awk '$1 == "some" { for (i=2;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/^avg10=/,"",$i); print $i; exit } }' /proc/pressure/cpu 2>/dev/null || true)"
  memory_psi="$(awk '$1 == "some" { for (i=2;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/^avg10=/,"",$i); print $i; exit } }' /proc/pressure/memory 2>/dev/null || true)"
  jq -cn --arg load5 "$load5" --arg cpu "$cpu_psi" --arg memory "$memory_psi" '
    def number: if test("^[0-9]+([.][0-9]+)?$") then tonumber else null end;
    {cpu_load_5m:($load5|number),cpu_psi_avg10:($cpu|number),memory_psi_avg10:($memory|number)}'
}

maintainer_health_mail_maintainer_efficiency_block() {
  local home="$1" now="$2" ledger="$3" script_dir now_iso summary pressure snapshot previous result repo_root mttr since
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  now_iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  summary="$(node "$script_dir/efficiency-regression.mjs" summary --home "$home" --now "$now_iso")" || return 1
  pressure="$(maintainer_health_mail_pressure_snapshot)" || return 1
  # Post-land breakage MTTR covers the fixes that landed since the last
  # successful digest, so each completed breakage is reported exactly once.
  repo_root="$(cd -- "$script_dir/../.." && pwd -P)" || return 1
  since="$(jq -r 'if .last_sent_at > 0 then .last_sent_at else .started_at end' "$ledger")" || return 1
  mttr="$(post_land_mttr_summary "$repo_root" "$since" "$now")" \
    || mttr='{"summary":{"count":0},"bounds":{"meaning":""}}'
  snapshot="$(jq -cn --argjson summary "$summary" --argjson pressure "$pressure" --argjson mttr "$mttr" '
    {captured_at:$summary.sampled_at,
     landed_prs_24h:($summary.current_24h.metrics.merged_prs // null),
     lead_time_7d_seconds:($summary.weekly_delivery.open_to_released.median_seconds // null),
     release_lag_24h_seconds:($summary.current_24h.metrics.merge_to_release_seconds // null),
     tokens_24h:($summary.current_24h.metrics.tokens // null),
     tokens_per_released_issue:($summary.current_24h.metrics.tokens_per_released_issue // null),
     cpu_load_5m:$pressure.cpu_load_5m,cpu_psi_avg10:$pressure.cpu_psi_avg10,
     memory_psi_avg10:$pressure.memory_psi_avg10,
     post_land_breakage_count:($mttr.summary.count // 0),
     post_land_mttr_median_seconds:($mttr.summary.total_median_seconds // null)}')" || return 1
  previous="$(jq -c '.last_sent_efficiency // null' "$ledger")" || return 1
  result="$(jq -cn --argjson current "$snapshot" --argjson previous "$previous" --argjson mttr "$mttr" '
    def duration($seconds):
      if $seconds == null then "待核实"
      elif $seconds >= 3600 then (((($seconds / 3600 * 10) | round) / 10) | tostring) + "小时"
      elif $seconds >= 60 then (((($seconds / 60 * 10) | round) / 10) | tostring) + "分钟"
      else (($seconds | round) | tostring) + "秒" end;
    def value($number;$kind;$unit):
      if $kind == "duration" then duration($number)
      elif $kind == "decimal" then (((($number * 100) | round) / 100) | tostring) + $unit
      else (($number | round) | tostring) + $unit end;
    def change($number;$old;$kind;$unit):
      if $kind == "duration" then
        (if $number < $old then "缩短" else "延长" end) + duration((($number - $old) | if . < 0 then -. else . end))
      elif $kind == "decimal" then
        (if $number < $old then "降低" else "升高" end) + value((($number - $old) | if . < 0 then -. else . end);$kind;$unit)
      else
        (if $number < $old then "减少" else "增加" end) + value((($number - $old) | if . < 0 then -. else . end);$kind;$unit)
      end;
    [
      {label:"近24小时落地合并请求",key:"landed_prs_24h",kind:"count",unit:"项"},
      {label:"近7天提出至上线中位时长",key:"lead_time_7d_seconds",kind:"duration",unit:""},
      {label:"近24小时合并至上线中位时长",key:"release_lag_24h_seconds",kind:"duration",unit:""},
      {label:"近24小时模型令牌消耗",key:"tokens_24h",kind:"count",unit:"枚"},
      {label:"每项上线改进平均令牌消耗",key:"tokens_per_released_issue",kind:"count",unit:"枚"},
      {label:"处理器5分钟负载",key:"cpu_load_5m",kind:"decimal",unit:""},
      {label:"处理器压力均值",key:"cpu_psi_avg10",kind:"decimal",unit:"%"},
      {label:"内存压力均值",key:"memory_psi_avg10",kind:"decimal",unit:"%"}
    ] as $metrics
    | [$metrics[] as $metric
       | $current[$metric.key] as $number
       | $previous[$metric.key] as $old
       | select($number != null)
       | select($previous == null or $old == null or $number != $old)
       | {label:$metric.label,value:value($number;$metric.kind;$metric.unit),baseline:
           (if $previous == null then "首次基线"
            elif $old == null then "开始记录"
            else "较上一封" + change($number;$old;$metric.kind;$metric.unit) end)}] as $changes
    | ($changes + (if (($mttr.summary.count // 0) > 0) then [{
        label:"落地后损坏恢复",
        value:("本期\($mttr.summary.count)起：发现中位\(duration($mttr.summary.detect_median_seconds))、修复中位\(duration($mttr.summary.fix_median_seconds))、总恢复中位\(duration($mttr.summary.total_median_seconds))，最长\(duration($mttr.summary.total_max_seconds))"),
        baseline:("标准：\($mttr.bounds.meaning)；超线\($mttr.summary.over_standard // 0)起")}]
      else [] end)) as $changes
    | {count:($changes|length),body:(if ($changes|length) == 0 then ""
        else "**效率变化**\n" + ($changes | map("- " + .label + "：" + .value + "；" + .baseline + "。") | join("\n")) end)}')" || return 1
  jq -cn --argjson efficiency "$result" --argjson snapshot "$snapshot" \
    '$efficiency + {snapshot:$snapshot}'
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
    if $render_mode[0] == "hourly" then
      "效率对比（本期：近1小时；环比：前1小时；同比：上周同一时段）\n"
      + "| 指标 | 本期 | 环比 | 同比 |\n| --- | ---: | --- | --- |\n"
      + row("上线的改进项数";"launched";"项";"上线记录待核实") + "\n"
      + row("关闭的事项";"closed";"项";"关闭记录待核实") + "\n"
      + row("新增事项";"created";"项";"新增记录待核实") + "\n"
      + row("积压增减";"backlog";"项";"积压数据待核实") + "\n"
      + row("平均从提出到上线";"average_hours";"小时";"上线记录待核实") + "\n"
      + "| 正在做/排队 | " + work_value + " | "
      + work_change + " | " + work_change + " |"
    else
      "效率对比（本期：报告日；环比：前一日；同比：上周同日）\n"
      + "| 指标 | 本期 | 环比 | 同比 |\n| --- | ---: | --- | --- |\n"
      + row("上线的改进项数";"launched";"项";"上线记录待核实") + "\n"
      + row("关闭的事项";"closed";"项";"关闭记录待核实") + "\n"
      + row("新增事项";"created";"项";"新增记录待核实") + "\n"
      + row("积压增减";"backlog";"项";"积压数据待核实") + "\n"
      + row("平均从提出到上线";"average_hours";"小时";"上线记录待核实") + "\n"
      + "| 正在做/排队 | " + work_value + " | "
      + work_change + " | " + work_change + " |"
    end
  ' <<< "$data"
  status=$?
  rm -f -- "$mode_file"
  return "$status"
}

maintainer_health_mail_collect_state_events() {
  local ledger="$1" home="$2" now="$3" since known candidates catalog catalog_map metadata row issue key kind title labels at highlight text display_title local_time state_file candidate_json issue_summary
  local -a state_files=() candidate_rows=() candidate_batches=() unreadable_issues=() summary_issues=()
  since="$(jq -r 'if .last_sent_at > 0 then .last_sent_at else .started_at end' "$ledger")" || return 1
  [[ "$since" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  shopt -s nullglob
  state_files=("$home"/state/*.json)
  shopt -u nullglob
  ((${#state_files[@]})) || return 0
  known="$(jq -c '{reported:(.reported_items // {}),pending:(.pending_events // {})}' "$ledger")" || return 1
  # One damaged issue state must not abort the rest of this digest.
  for state_file in "${state_files[@]}"; do
    issue="${state_file##*/}"
    issue="${issue%.json}"
    [[ "$issue" =~ ^[0-9]+$ ]] || continue
    candidate_json="$(jq -cn --arg issue "$issue" --argjson since "$since" --argjson now "$now" --argjson known "$known" '
      (try [inputs] catch null) as $states
      | if ($states | type) != "array" or ($states | length) != 1 or ($states[0] | type) != "object" then
          {unreadable:true}
        else
          $states[0] as $s
          | ($s.run // {}) as $run
          | [
              (if $run.outcome == "merged" and (($run.evidence.pr_number // "") | tostring | test("^[1-9][0-9]*$")) then
                (($run.merged_at // "") | try fromdateiso8601 catch -1) as $at
                | if $at > $since and $at <= $now then {kind:"release",issue:$issue,pr:($run.evidence.pr_number|tostring),at:$at,key:("release:"+$issue+":"+($run.evidence.pr_number|tostring)+":"+($at|tostring))} else empty end
               else empty end),
              (if $s.deploy_state == "deployed" and ($s.deployed_sha // "") != "" then
                (($s.deployed_at // $run.deployed_at // $run.evidence.production_evidence_at // "") | try fromdateiso8601 catch -1) as $at
                | if $at > $since and $at <= $now then {kind:"deploy",issue:$issue,sha:$s.deployed_sha,at:$at,key:("deploy:"+$issue+":"+$s.deployed_sha)} else empty end
               else empty end),
              (if $s.state == "concluded" and $s.closed_by_pipeline == true then
                (($run.concluded_at // "") | try fromdateiso8601 catch -1) as $at
                | if $at > $since and $at <= $now then {kind:"closed",issue:$issue,at:$at,key:("closed:"+$issue+":"+($run.concluded_at|tostring))} else empty end
               else empty end)
            ]
          | map(. as $candidate | select(($known.reported | has($candidate.key) | not) and ($known.pending | has($candidate.key) | not)))
        end
    ' "$state_file")" || return 1
    if [[ "$candidate_json" == \{* ]]; then
      unreadable_issues+=("$issue")
    else
      candidate_batches+=("$candidate_json")
    fi
  done
  candidates="$(printf '%s\n' "${candidate_batches[@]}" | jq -cs 'add // []')" || return 1
  if ((${#unreadable_issues[@]})); then
    for issue in "${unreadable_issues[@]}"; do
      AGENT_HOME="$home" supervisor_inbox_append_once "maintainer-health-mail-unreadable-state:$issue" \
        "maintainer-health-mail-unreadable-state issue=$issue state/$issue.json unreadable; maintainer digest omitted this issue's events" || return 1
    done
    summary_issues=("${unreadable_issues[@]:0:5}")
    issue_summary="$(IFS=,; printf '%s' "${summary_issues[*]}")"
    ((${#unreadable_issues[@]} <= 5)) || issue_summary+=",..."
    printf 'maintainer health mail: partial-state-scan unreadable=%s issues=%s\n' \
      "${#unreadable_issues[@]}" "$issue_summary" >&2
  fi
  [ "$(jq -r 'length' <<< "$candidates")" -gt 0 ] || return 0
  local issue_ids
  issue_ids="$(jq -c '[.[].issue | tonumber] | unique' <<< "$candidates")" || return 1
  catalog="$(maintainer_health_mail_issue_catalog "$issue_ids")" || {
    printf 'maintainer health mail: issue catalog lookup failed\n' >&2
    return 1
  }
  catalog_map="$(jq -c 'map({key:(.number|tostring),value:.}) | from_entries' <<< "$catalog")" || return 1
  mapfile -t candidate_rows < <(jq -c '.[]' <<< "$candidates")
  for row in "${candidate_rows[@]}"; do
    issue="$(jq -r '.issue' <<< "$row")"
    key="$(jq -r '.key' <<< "$row")"
    kind="$(jq -r '.kind' <<< "$row")"
    at="$(jq -r '.at' <<< "$row")"
    metadata="$(jq -c --arg issue "$issue" '.[$issue] // empty' <<< "$catalog_map")" || return 1
    [ -n "$metadata" ] || { printf 'maintainer health mail: issue catalog lookup failed\n' >&2; return 1; }
    labels=",$(jq -r '[.labels[]?.name // ""] | join(",")' <<< "$metadata"),"
    [[ "$labels" == *,pipeline-system,* ]] && continue
    title="$(jq -r '.title' <<< "$metadata" | tr '\n\r' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ | $//g')"
    [[ -n "$title" ]] || return 1
    display_title="$(maintainer_health_mail_plain_title "$title")" || return 1
    case "$kind" in
      release)
        text="待上线：${display_title}。"
        maintainer_health_mail_record_event "$ledger" "$key" '发布进度' "$text" "$now" release >/dev/null || return 1
        ;;
      deploy)
        local_time="$(maintainer_local_time "$at")" || return 1
        text="现在可以使用「${display_title}」；$local_time 上线的版本。"
        maintainer_health_mail_record_event "$ledger" "$key" '发布进度' "$text" "$now" deploy >/dev/null || return 1
        ;;
      closed)
        highlight=false
        if [[ "$labels" == *,focus,* || "$labels" == *,priority:top,* ]]; then highlight=true; fi
        maintainer_health_mail_record_event "$ledger" "$key" '事项完成' "修好了：${display_title}。" "$now" closed "$highlight" >/dev/null || return 1
        ;;
    esac
  done
}

maintainer_health_mail_collect_outcomes() {
  local ledger="$1" home="$2" now="$3" activity since activity_rows issue_ids row issue sha outcome at key local_time deployed_at deployed_epoch catalog metadata title display_title catalog_map=''
  activity="$home/night/founder-health-outcomes.jsonl"
  [ -r "$activity" ] || return 0
  since="$(jq -r 'if .last_sent_at > 0 then .last_sent_at else .started_at end' "$ledger")" || return 1
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  activity_rows="$(jq -cs --argjson since "$since" --argjson now "$now" '
    [ .[]
      | . as $row
      | ($row.issue // "" | tostring) as $issue
      | ($row.sent_at // "" | try fromdateiso8601 catch empty) as $at
      | select($issue | test("^[1-9][0-9]*$"))
      | select(($row.deployed_sha // "") != "" and ($at | type) == "number" and $at > $since and $at <= $now)
      | select((($row.outcome // "") | type) == "string")
      | select($row.outcome | test("^[一-龥]"))
      | $row
    ]
  ' "$activity")" || return 1
  [ "$(jq -r 'length' <<< "$activity_rows")" -gt 0 ] || return 0
  issue_ids="$(jq -c '[.[].issue | tonumber] | unique' <<< "$activity_rows")" || return 1
  catalog="$(maintainer_health_mail_issue_catalog "$issue_ids")" || return 1
  catalog_map="$(jq -c 'map({key:(.number|tostring),value:.}) | from_entries' <<< "$catalog")" || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    issue="$(jq -r '.issue // empty' <<< "$row")"
    sha="$(jq -r '.deployed_sha // empty' <<< "$row")"
    outcome="$(jq -r '.outcome // empty' <<< "$row")"
    at="$(jq -r '.sent_at // empty | try fromdateiso8601 catch empty' <<< "$row")"
    [[ "$issue" =~ ^[0-9]+$ && -n "$sha" && "$at" =~ ^[0-9]+$ && "$at" -gt "$since" && "$at" -le "$now" ]] || continue
    maintainer_health_mail_safe_outcome "$outcome" || continue
    key="deploy:$issue:$sha"
    metadata="$(jq -c --arg issue "$issue" '.[$issue] // empty' <<< "$catalog_map")" || return 1
    title="$(jq -r '.title // empty' <<< "${metadata:-null}")" || return 1
    display_title="$(maintainer_health_mail_plain_title "$title")" || return 1
    # Keep an existing readable outcome when the issue title is not readable.
    if [ -n "$title" ] && [ -z "$(maintainer_health_mail_event_rejection_reason '发布进度' "$title")" ]; then
      outcome="现在可以使用「${display_title}」"
    else
      outcome="$(maintainer_health_mail_scrub_text "$outcome")" || return 1
      case "$outcome" in
        现在可以*|修好了*) ;;
        *) outcome="现在可以：$outcome" ;;
      esac
    fi
    deployed_at="$(maintainer_health_mail_deployed_at "$home" "$issue")" || return 1
    deployed_epoch=''
    if [ -n "$deployed_at" ]; then deployed_epoch="$(agent_epoch -u "$deployed_at" 2>/dev/null || true)"; fi
    if [[ "$deployed_epoch" =~ ^[0-9]+$ ]]; then
      local_time="$(maintainer_health_mail_date_time "$deployed_epoch")" || return 1
      outcome="${outcome}；$local_time 上线的版本。"
    else
      outcome="${outcome}；上线时间待核实。"
    fi
    maintainer_health_mail_record_event "$ledger" "$key" '发布进度' "$outcome" "$at" deploy >/dev/null || return 1
  done < <(jq -c '.[]' <<< "$activity_rows")
}

maintainer_health_mail_safe_outcome() {
  local text="$1" internal="${MAINTAINER_BODY_INTERNAL_PATTERN:-流水线|节点|运维|健康检查|advisor|pipeline|deploy|build|merge|pull request}"
  [[ "$text" =~ [一-龥] ]] || return 1
  grep -iEq "$internal" <<< "$text" && return 1
  grep -Eq '[A-Z][A-Z0-9_]{2,}|(^|[[:space:]])/[^[:space:]]+|[[:xdigit:]]{10,}|^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+|[[:alnum:]_.-]+=[^[:space:]]*' <<< "$text" && return 1
  return 0
}

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
  incident_file="${AGENT_INCIDENT_GUARDS_FILE:-$repo_root/engine/state/incident-guards.json}"
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
      "$incident_file")" || return 1
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
  local wakes_by_kind_json='{}' kind
  for kind in "${!wakes_by_kind[@]}"; do
    wakes_by_kind_json="$(jq -cn --argjson old "$wakes_by_kind_json" --arg kind "$kind" --argjson count "${wakes_by_kind[$kind]}" '$old + {($kind):$count}')" || return 1
  done
  jq -cSn --arg date "$day" --argjson calls "$calls" --argjson tokens "$tokens" \
    --argjson released_issues "$released" --argjson tokens_per_released_issue "$tokens_per_release" \
    --argjson deploys "$deploys" --argjson wakeups_24h "$wakeups_24h" --argjson wakeups_day "$wakeups_day" \
    --argjson wakes_by_kind "$wakes_by_kind_json" --argjson recurrence_tracking "$recurrence_tracking" \
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
      wake_tracking:$wake_tracking,wakeups_24h:$wakeups_24h,wakeups_day:$wakeups_day,wakes_by_kind:$wakes_by_kind,
      recurrence_tracking:$recurrence_tracking,recurrences_day:$recurrences_day,
      recurrences_7d:$recurrences_7d,recurrence_categories:$recurrence_categories,
      implement_runs:$implement_runs,implement_result_count:$implement_result_count,
      implement_successes:$implement_successes,implement_success_rate:$implement_success_rate,
      oldest_queue_age_minutes:$oldest_queue_age,repeat_failures:$repeat_failures,false_freezes:$false_freezes,
      alert_tracking:$alert_tracking,alert_classes:$alert_classes}'
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
  # A plain count, no class ids: ids like ticket-progress tripped the maintainer-mail internal-word filter and
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

maintainer_health_mail_date_time() {
  [[ "$1" =~ ^[0-9]{10,}$ ]] && (( $1 >= 946684800 )) || { printf '时间待核实'; return 0; }
  maintainer_local_time "$1"
}

maintainer_health_mail_elapsed() {
  local since="$1" now="$2" seconds minutes
  [[ "$since" =~ ^[0-9]{10,}$ && "$now" =~ ^[0-9]+$ ]] && (( since >= 946684800 )) || { printf '持续时间待核实'; return 0; }
  seconds=$((now - since))
  (( seconds < 0 )) && seconds=0
  minutes=$((seconds / 60))
  if (( minutes < 60 )); then printf '约%d分钟' "$minutes"
  else printf '约%d小时' "$((minutes / 60))"; fi
}

maintainer_health_mail_anomaly_sentence() {
  local node="$1" action="$2" since="$3" now="$4" when elapsed shown_since
  if [[ "$since" =~ ^[0-9]{10,}$ && "$now" =~ ^[0-9]+$ ]] && (( since >= 946684800 && since <= now )); then
    shown_since=$((since / 60 * 60))
    when="自$(maintainer_health_mail_date_time "$shown_since")起"
    elapsed="$(maintainer_health_mail_elapsed "$shown_since" "$now")"
  else
    when='开始时间暂无数据'
    elapsed=''
  fi
  if [ "$action" = recovery ]; then
    case "$node" in
      implement) printf '已恢复：GitHub 连接已恢复，开发已继续。' ;;
      egress) printf '已恢复：网络连接已恢复，交付已继续。' ;;
      merge) printf '已恢复：合入检查已恢复，团队可以继续提交变更。' ;;
      postsubmit|build|deploy) printf '已恢复：上线检查已恢复，版本继续验证。' ;;
      advisor) printf '已恢复：业务评审已恢复，评审继续。' ;;
      rulings) printf '已恢复：规则检查已恢复，处理继续。' ;;
      *) printf '已恢复：处理已恢复，工作继续。' ;;
    esac
    return 0
  fi
  case "$node" in
    implement) printf '开发暂停，%s%s：连接 GitHub 的网络时断时续，网络恢复后自动继续。' "$when" "${elapsed:+$elapsed}" ;;
    egress) printf '网络连接不稳定，%s%s；恢复后交付继续。' "$when" "${elapsed:+$elapsed}" ;;
    merge) printf '变更合入暂停，%s%s：部分检查未通过，安排处理后继续。' "$when" "${elapsed:+$elapsed}" ;;
    postsubmit) printf '上线验证暂停，%s%s：主干检查结果异常，修复后继续验证。' "$when" "${elapsed:+$elapsed}" ;;
    build) printf '版本构建暂停，%s%s：上线前检查尚未通过，修复后继续。' "$when" "${elapsed:+$elapsed}" ;;
    deploy) printf '版本上线暂停，%s%s：生产验证未完成，检查通过后继续。' "$when" "${elapsed:+$elapsed}" ;;
    advisor) printf '业务评审暂停，%s%s：评审服务暂不可用，恢复后自动继续。' "$when" "${elapsed:+$elapsed}" ;;
    rulings) printf '规则检查暂停，%s%s：检查未完成，修复后继续。' "$when" "${elapsed:+$elapsed}" ;;
    *) printf '团队工作暂停，%s%s：检查未完成，修复后继续。' "$when" "${elapsed:+$elapsed}" ;;
  esac
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
  runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${ZF_MAC_AUTOPILOT_RUNTIME_DIR:-$user_home/.scratch-supervisor/autopi}}"
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
  result="$(jq -r '[.metrics[] | select(.status == "UNHEALTHY") | (.desc // "调度指标异常")] | .[:5] | if length == 0 then "未发现超出健康线的调度指标" else "超出健康线的调度指标：" + join("；") end' "$scorecard")" || return 1
  printf '%s' "$result"
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

maintainer_health_mail_event_rejection_reason() {
  local section="$1" text="$2"
  text="$(maintainer_health_mail_scrub_text "$text")" || return 1
  if ! looks_like_maintainer_readable "$text" 0; then
    printf 'body-language\n'
    return 0
  fi
  maintainer_mail_rejection_reason health '工作进展简报' \
    "$(printf '**结论：** 本次有 1 项新变化。\n\n**%s**\n%s\n' "$section" "$text")"
}

maintainer_health_mail_filter_events() {
  local events="$1" home="$2" now="${3:-$(date +%s)}" event key section text reason accepted='[]'
  local -a rows=()
  mapfile -t rows < <(jq -c '.[]' <<< "$events")
  for event in "${rows[@]}"; do
    key="$(jq -r '.key' <<< "$event")" || return 1
    section="$(jq -r '.section' <<< "$event")" || return 1
    text="$(jq -r '.text' <<< "$event")" || return 1
    reason="$(maintainer_health_mail_event_rejection_reason "$section" "$text")" || return 1
    if [ -n "$reason" ]; then
      printf 'maintainer health mail: dropped key=%s reason=%s\n' "$key" "$reason" >&2
      AGENT_HOME="$home" supervisor_inbox_append_once "maintainer-mail-item-rejected:$key" \
        "maintainer-mail-item-rejected key=$key reason=$reason 不可读条目已隔离，其他邮件内容继续发送" || return 1
      maintainer_health_mail_mark_reported "$home/night/founder-health-mail.json" "$key" "$now" "$reason" || return 1
      continue
    fi
    accepted="$(jq -c --argjson event "$event" '. + [$event]' <<< "$accepted")" || return 1
  done
  printf '%s\n' "$accepted"
}

maintainer_health_mail_normalize_events() {
  local events="$1" now="$2" row key node opened section text normalized
  local -a nodes=()
  mapfile -t nodes < <(jq -r '
    [.[] | (try ((.key // "") | capture("^node:(?<node>[^:]+):alert:(?<since>[0-9]+)$").node) catch null),
      (try ((.reminder_for // "") | capture("^node-important:(?<node>[^:]+):(?<since>[0-9]+)$").node) catch null)]
    | map(select(type == "string")) | unique[]
  ' <<< "$events")
  normalized="$events"
  for node in "${nodes[@]}"; do
    row="$(jq -c --arg node "$node" '
      [.[] as $event
        | ($event.key // "") as $key
        | ($event.reminder_for // "") as $reminder
        | (if ($key | test("^node:" + $node + ":alert:[0-9]+$"))
           then ($key | capture("^node:" + $node + ":alert:(?<since>[0-9]+)$").since)
           elif ($reminder | test("^node-important:" + $node + ":[0-9]+$"))
           then ($reminder | capture("^node-important:" + $node + ":(?<since>[0-9]+)$").since)
           else null end) as $since
        | select($since != null) | {event:$event,since:($since|tonumber)}]
      | sort_by(if .since > 0 then [0,.since] else [1,0] end) | .[0] // null
    ' <<< "$normalized")" || return 1
    [ "$row" != null ] || continue
    opened="$(jq -r '.since' <<< "$row")"
    section=处理变化
    if jq -e --arg node "$node" 'any(.[]; ((.reminder_for // "") | startswith("node-important:" + $node + ":")))' \
      <<< "$normalized" >/dev/null; then section=仍在处理; fi
    text="$(maintainer_health_mail_anomaly_sentence "$node" open "$opened" "$now")" || return 1
    normalized="$(jq -c --arg node "$node" --arg section "$section" --arg text "$text" --argjson opened "$opened" '
      [.[] | select(((.key // "") | test("^node:" + $node + ":alert:")) | not)
        | select(((.reminder_for // "") | startswith("node-important:" + $node + ":")) | not)]
      + [{key:("normalized-open:" + $node),section:$section,text:$text,kind:"node",created_at:$opened,reminder_for:"",highlight:false}]
    ' <<< "$normalized")" || return 1
  done
  normalized="$(jq -c --argjson now "$now" '
    map(if (.kind == "reminder" and ((.reminder_for // "") | startswith("node-important:") | not))
      then .text |= (gsub("（已持续[[:space:]]*[0-9]+[[:space:]]*小时）"; "")
        | gsub("^[[:space:]]*仍在处理[：:][[:space:]]*"; ""))
      else . end)
    | sort_by([.section,.created_at,.key])
  ' <<< "$normalized")" || return 1
  printf '%s\n' "$normalized"
}

maintainer_health_mail_build_body() {
  local events="$1" efficiency="${2:-}" launch_reason="${3:-没有新版本通过上线验证}" work_reason="${4:-}" pipeline_efficiency="${5:-}" now="${6:-$(date +%s)}" count closed highlights rest live_lines
  count="$(jq -r '[.[] | select(.kind != "efficiency")] | length' <<< "$events")" || return 1
  count=$((count + ${MAINTAINER_HEALTH_MAIL_EFFICIENCY_CHANGE_COUNT:-0}))
  (( count > 0 )) || return 1
  events="$(maintainer_health_mail_normalize_events "$events" "$now")" || return 1
  events="$(jq '
    map(. as $event | .text |= (gsub("^[[:space:]]*" + ($event.section // "") + "[：:][[:space:]]*"; "")
      | gsub("^[[:space:]]*-[[:space:]]*" + ($event.section // "") + "[：:][[:space:]]*"; "")
      | gsub("#[[:space:]]*[0-9]+"; "")
      | gsub("[[:xdigit:]]{7,}"; "")
      | gsub("(?i)implement"; "开发")
      | gsub("(?i)canary"; "验证")
      | gsub("(?i)quarantine"; "暂缓")
      | gsub("(?i)rulings"; "规则核验")
      | gsub("(?i)health[[:space:]_-]*node"; "运行状态")
      | gsub("(?i)health"; "运行状态")
      | gsub("(?i)slots?"; "时段")
      | gsub("(?i)owners?"; "负责人")
      | gsub("(?i)pipeline"; "交付流程")
      | gsub("(?i)postsubmit"; "上线检查")
      | gsub("(?i)deploy"; "上线")
      | gsub("(?i)build"; "构建")
      | gsub("(?i)merge"; "合入")
      | gsub("(?i)advisor"; "业务评审")
      | gsub("(?i)node"; "环节")))
  ' <<< "$events")" || return 1
  events="$(jq '
    map(if ((.kind == "release" or .section == "发布进度") and (.text | test("[A-Za-z]")))
      then .text = "待上线：这项改进的上线准备尚未完成。" else . end)
  ' <<< "$events")" || return 1
  closed="$(jq -r '[.[] | select(.kind == "closed")] | length' <<< "$events")" || return 1
  count="$(jq -r '[.[] | select(.kind != "efficiency")] | length' <<< "$events")" || return 1
  count=$((count + ${MAINTAINER_HEALTH_MAIL_EFFICIENCY_CHANGE_COUNT:-0}))
  highlights="$(jq -r '[.[] | select(.kind == "closed" and .highlight == true) | .text] | .[] | "- " + .' <<< "$events")" || return 1
  live_lines="$(jq -r '[.[] | select(.kind == "deploy") | .text] | .[] | "- " + .' <<< "$events")" || return 1
  rest="$(jq -r '
    [.[] | select(.kind != "closed" and .kind != "deploy" and .kind != "efficiency")] | sort_by([.section,.created_at,.key]) | group_by(.section)
    | map("**" + .[0].section + "**\n" + (map(if .section == "今日汇总" or .section == "待验收" then .text else "- " + (.text|gsub("\n";"\n  ")) end) | join("\n")))
    | join("\n\n")
  ' <<< "$events")" || return 1
  {
    if [ -n "$efficiency" ]; then printf '%s\n\n' "$efficiency"; fi
    printf '**结论：** 本次有 %s 项新变化。\n' "$count"
    printf '%s\n' "$(maintainer_timezone_note)"
    printf '\n**上线情况：**\n'
    if [ -n "$live_lines" ]; then printf '%s\n' "$live_lines"
    else printf '最近六小时没有上线：%s。\n' "$launch_reason"; fi
    [ -z "$pipeline_efficiency" ] || printf '\n%s\n' "$pipeline_efficiency"
    [ -z "$work_reason" ] || printf '\n%s\n' "$work_reason"
    if (( closed > 0 )); then
      printf '\n**事项完成：** %s 项\n' "$closed"
      [ -z "$highlights" ] || printf '%s\n' "$highlights"
    fi
    [ -z "$rest" ] || printf '\n%s\n' "$rest"
  }
}

maintainer_health_mail_output_contract() {
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
    if "1月1日" in text or "1970" in text:
        errors.add("epoch-date")
    if re.search(r"#[0-9]+", text):
        errors.add("issue-id")
    if re.search(r"(?<![A-Za-z0-9])[0-9a-fA-F]{7,}(?![A-Za-z0-9])", text):
        errors.add("commit-id")
    if set(re.findall(r"[A-Za-z]+", text)) - {"GitHub"}:
        errors.add("ascii-text")
    section = None
    for line in text.splitlines():
        header = re.fullmatch(r"\*\*(.+?)\*\*", line.strip())
        if header:
            section = header.group(1).rstrip("：:")
            continue
        if section and re.match(r"^\s*(?:-\s*)?" + re.escape(section) + r"[：:]", line):
            errors.add("duplicate-prefix")
        if re.search(r"仍在处理[：:]\s*仍在处理[：:]", line):
            errors.add("duplicate-prefix")

    # Times in the body are maintainer-local (comms-format.sh maintainer_local_time);
    # validate them in the same profile timezone so DST days agree.
    tz = ZoneInfo(os.environ["ZF_MAINTAINER_TZ"])
    now_dt = datetime.fromtimestamp(now, tz)
    for match in re.finditer(r"自(\d{1,2})月(\d{1,2})日\s+(\d{2}):(\d{2})起(约\d+(?:小时|分钟))", text):
        month, day, hour, minute = map(int, match.groups()[:4])
        try:
            start = datetime(now_dt.year, month, day, hour, minute, tzinfo=tz)
            if start > now_dt + timedelta(minutes=1):
                start = datetime(now_dt.year - 1, month, day, hour, minute, tzinfo=tz)
            seconds = int((now_dt - start).total_seconds())
            if seconds < -60:
                errors.add("future-duration")
                continue
            minutes = max(seconds, 0) // 60
            expected = f"约{minutes}分钟" if minutes < 60 else f"约{minutes // 60}小时"
            if expected != match.group(5):
                errors.add("duration-mismatch")
        except ValueError:
            errors.add("invalid-duration-start")

    reason = re.compile(r"(?:缺少[^，；。]{1,16}(?:数据|样本)|[^，；。]{1,18}(?:待核实|待补|待统计|无样本|没有事项)|本期无.{1,12}事项|工作数量仅展示当前)")
    # Every comparison table owns its own row count; the mail can contain both schemas.
    table_expected_rows = None
    table_row_count = 0
    table_headers = {
        "| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |": 8,
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

if len(sys.argv) > 2 and sys.argv[2] == "isolate-lines":
    import json
    kept, rejected = [], []
    section, in_table, table_context = "", False, ""
    for line in text.splitlines():
        header = re.fullmatch(r"\*\*(.+?)\*\*", line.strip())
        table_header = bool(re.match(r"^\|\s*指标\s*\|", line.strip()))
        context = section + "\n" + line if section else line
        if table_header:
            if line.strip() in ("| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |", "| 指标 | 本期 | 环比 | 同比 |"):
                table_context = line.strip()
                context = line
            else:
                table_context = "| 指标 | 本期 | 环比 | 同比 |" if any(value in line for value in ("本期", "环比", "同比")) else "| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |"
                context = table_context + "\n" + line
        elif in_table and line.strip().startswith("|"):
            context = (table_context or "| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |") + "\n" + line
        errors = validate(context) - {"metric-table-incomplete"}
        if errors:
            rejected.append({"key":"output-line:" + line, "reason":",".join(sorted(errors))})
            if table_header:
                kept.append(table_context)
            elif in_table and line.strip().startswith("|"):
                kept.append("| 统计项目 | 数据待核实 | 数据待核实 | 数据待核实 |")
        else:
            kept.append(line)
        if header:
            section = line if not errors else ""
        if table_header:
            in_table = True
        elif in_table and line.strip() and not line.strip().startswith("|"):
            in_table = False
            table_context = ""
    print(json.dumps({"body":"\n".join(kept), "rejected":rejected}, ensure_ascii=False))
else:
    errors = validate(text)
    if errors:
        print(",".join(sorted(errors)))
        raise SystemExit(1)
' "$now" "${3:-validate}"
}

maintainer_health_mail_contract_inbox() {
  local home="$1" reason="$2"
  AGENT_HOME="$home" supervisor_inbox_append_once "maintainer-mail-output-contract:$reason" \
    "maintainer-mail-output-contract status=failed rules=$reason"
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
        AGENT_HOME="$home" supervisor_inbox_append_once "maintainer-mail-item-rejected:$key" \
          "maintainer-mail-item-rejected key=$key reason=$reason 不可读行已隔离，其他邮件内容继续发送" || return 1
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

maintainer_health_mail_tick() {
  local home="$1" now="${2:-$(date +%s)}" ledger
  local slot last_slot last_sent_at interval body events event_count efficiency efficiency_report efficiency_change_count launch_reason work_data active queued work_reason
  ledger="$home/night/founder-health-mail.json"
  maintainer_health_mail_ensure_ledger "$ledger" "$now" || return 1
  maintainer_health_mail_incident_tick "$ledger" "$now" || return 1
  maintainer_health_mail_collect_outcomes "$ledger" "$home" "$now" || return 1
  maintainer_health_mail_collect_state_events "$ledger" "$home" "$now" || return 1
  maintainer_health_mail_acceptance_events "$ledger" "$home" "$now" || return 1

  maintainer_health_mail_collect_reminders "$ledger" "$home" "$now" || return 1
  slot="$(maintainer_health_mail_slot_key "$now")" || return 1
  last_slot="$(jq -r '.last_digest_slot' "$ledger")" || return 1
  [ "$slot" != "$last_slot" ] || return 0
  events="$(jq -c '[.pending_events // {} | to_entries[] | .value] | sort_by([.section,.created_at,.key])' "$ledger")" || return 1
  events="$(maintainer_health_mail_filter_events "$events" "$home" "$now")" || return 1
  event_count="$(jq -r 'length' <<< "$events")" || return 1
  interval="$(maintainer_health_mail_digest_interval_seconds)" || return 1
  last_sent_at="$(jq -r '.last_sent_at' "$ledger")" || return 1
  if (( last_sent_at > 0 && now - last_sent_at < interval )); then return 0; fi
  work_data="$(maintainer_health_mail_work_counts "$home" "$now")" || work_data='{"active":null,"queued":null}'
  active="$(jq -r '.active // "null"' <<< "$work_data")" || active=null
  queued="$(jq -r '.queued // "null"' <<< "$work_data")" || queued=null
  efficiency_report="$(maintainer_health_mail_maintainer_efficiency_block "$home" "$now" "$ledger")" || return 1
  efficiency="$(jq -r '.body' <<< "$efficiency_report")" || return 1
  efficiency_change_count="$(jq -r '.count' <<< "$efficiency_report")" || return 1
  MAINTAINER_HEALTH_MAIL_EFFICIENCY_SNAPSHOT="$(jq -c '.snapshot' <<< "$efficiency_report")" || return 1
  MAINTAINER_HEALTH_MAIL_EFFICIENCY_CHANGE_COUNT="$efficiency_change_count"
  event_count="$(jq -r '[.[] | select(.kind != "efficiency")] | length' <<< "$events")" || return 1
  (( event_count > 0 || efficiency_change_count > 0 )) || return 0
  if (( efficiency_change_count > 0 )) \
    && ! jq -e 'any(.[]; .kind == "efficiency")' <<< "$events" >/dev/null; then
    events="$(jq -cn --argjson events "$events" --arg key "efficiency:$now" --argjson now "$now" \
      '$events + [{key:$key,section:"效率变化",text:"效率指标有新的变化。",kind:"efficiency",highlight:false,created_at:$now}]')" || return 1
  fi
  launch_reason="$(maintainer_health_mail_no_launch_reason)"
  work_reason="$(maintainer_health_mail_no_work_reason "$active" "$queued")"
  body="$(maintainer_health_mail_build_body "$events" "$efficiency" "$launch_reason" "$work_reason" '' "$now")" || return 1
  maintainer_health_mail_deliver "$ledger" "$now" "$slot" '工作进展简报' "$body" "$events"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
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
        printf 'usage: %s queue-event <key> <section> <text> [epoch] | track-decision <issue-number> <subject> [epoch]\n' "$0" >&2
        exit 2
      }
      maintainer_health_mail_record_event "$ledger" "$key" "$section" "$text" "$now"
      ;;
    track-decision)
      issue="${2:-}"
      subject="${3:-}"
      now="${4:-$(date +%s)}"
      [[ "$issue" =~ ^[0-9]+$ && -n "$subject" && "$now" =~ ^[0-9]+$ ]] || {
        printf 'usage: %s track-decision <issue-number> <subject> [epoch]\n' "$0" >&2
        exit 2
      }
      maintainer_health_mail_track_important "$ledger" "decision:$issue:$subject" decision "$subject" "$issue" "$now"
      ;;
    *)
      printf 'usage: %s status [epoch] | credential-status | tick | resolve-incident <issue-number> <reason> | queue-event <key> <section> <text> [epoch] | track-decision <issue-number> <subject> [epoch]\n' "$0" >&2
      exit 2
      ;;
  esac
fi
