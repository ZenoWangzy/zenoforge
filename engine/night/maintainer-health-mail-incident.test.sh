#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/maintainer-health-mail.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
MAIL_EVENTS="$tmp/mail-events.jsonl"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$label" "$expected" "$actual"
    FAILED=1
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (missing [%s])\n' "$label" "$needle"
    FAILED=1
  fi
}

FAILED=0
record_mail() {
  jq -cn --arg issue "$1" --arg subject "$2" --arg what "$3" --arg impact "$4" \
    --arg action "$5" --arg kind "$6" --arg next_update "${7:-}" \
    '{issue:$issue,subject:$subject,what:$what,impact:$impact,action:$action,kind:$kind,next_update:$next_update}' \
    >> "$MAIL_EVENTS"
  printf 'fixture-message-id\n'
}
notify_maintainer_incident() { record_mail "$1" "$2" "$3" "$4" "$5" incident "$6"; }
notify_maintainer_resolution() { record_mail "$1" "$2" "$3" "$4" "$5" resolution; }

required_functions=(
  maintainer_health_mail_incident_open
  maintainer_health_mail_incident_tick
  maintainer_health_mail_incident_request_resolution
  maintainer_health_mail_incident_mark_resolved
  maintainer_health_mail_incident_release_accepted
)
missing=0
for function_name in "${required_functions[@]}"; do
  declare -F "$function_name" >/dev/null || missing=1
done
if [[ "$missing" == 1 ]]; then
  printf 'not ok - incident mail creates durable entry with issue and promised update\n'
  printf 'not ok - promised time sends one update and advances next update\n'
  printf 'not ok - accepted release sends one resolution and closes incident\n'
  printf 'not ok - supervisor resolves false alarm with no user-facing outage stated\n'
  printf 'not ok - release wrapper connects accepted ticket to incident resolution\n'
  exit 1
fi

ledger="$tmp/night/founder-health-mail.json"
incident_fixture_seed="$(printf '%s' "$tmp/incident-fixtures" | cksum | awk '{print 100000 + ($1 % 800000)}')"
production_incident_issue="$incident_fixture_seed"
false_alarm_issue=$((incident_fixture_seed + 1))
recovery_issue=$((incident_fixture_seed + 2))
mkdir -p "$(dirname -- "$ledger")"
maintainer_health_mail_ensure_ledger "$ledger" 1000
maintainer_health_mail_incident_open "$ledger" "$production_incident_issue" '线上服务尚未恢复' \
  '生产发布后的检查未通过，自动恢复也没有成功。' \
  '用户目前看到：部分线上功能可能暂时不可用，恢复尚未确认。' \
  '我们正在：优先恢复服务并确认结果。' 15400 1000 1 >/dev/null
assert_eq 'production outage is mailed immediately and recorded' \
  "$production_incident_issue|线上服务尚未恢复|open|15400|sent|true" \
  "$(jq -r '.incidents[0] | [.issue,.subject,.status,.next_update_at,.initial_mail_status,.urgent] | join("|")' "$ledger")"
maintainer_health_mail_incident_open "$ledger" "$production_incident_issue" '线上服务尚未恢复' \
  '生产发布后的检查未通过，自动恢复也没有成功。' \
  '用户目前看到：部分线上功能可能暂时不可用，恢复尚未确认。' \
  '我们正在：优先恢复服务并确认结果。' 15400 1000 1 >/dev/null
assert_eq 'restarting release does not resend urgent outage mail' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

maintainer_health_mail_incident_tick "$ledger" 1599 >/dev/null
maintainer_health_mail_incident_tick "$ledger" 1600 >/dev/null
maintainer_health_mail_incident_tick "$ledger" 15400 >/dev/null
assert_eq 'ordinary incident ticks do not send repeat updates' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
maintainer_health_mail_incident_release_accepted "$ledger" "$production_incident_issue" \
  '0123456789abcdef' 15401 >/dev/null
assert_eq 'urgent outage recovery closes the incident for the daily report' \
  'resolved|release|queued|0123456789abcdef' \
  "$(jq -r '.incidents[0] | [.status,.resolution_kind,.resolution_mail_status,.resolution_ref] | join("|")' "$ledger")"
assert_eq 'recovery does not send an immediate second mail' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
maintainer_health_mail_incident_tick "$ledger" 15400 >/dev/null
assert_eq 'repeated resolution tick sends nothing' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

false_alarm_ledger="$tmp/night/false-alarm.json"
maintainer_health_mail_ensure_ledger "$false_alarm_ledger" 2000
maintainer_health_mail_incident_open "$false_alarm_ledger" "$false_alarm_issue" '线上服务尚未恢复' \
  '验收检查没有通过。' '用户目前看到：生产服务正常。' \
  '我们正在：核实告警原因。' 16400 2000 0 >/dev/null
maintainer_health_mail_incident_mark_resolved "$false_alarm_ledger" "$false_alarm_issue" \
  '误报：生产服务一直正常，没有影响用户。' 2100 >/dev/null
maintainer_health_mail_incident_tick "$false_alarm_ledger" 2100 >/dev/null
assert_eq 'false alarm resolution queues without immediate maintainer mail' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
assert_eq 'false alarm resolution is durable for the daily report' \
  'resolved|supervisor|queued' \
  "$(jq -r '.incidents[0] | [.status,.resolution_kind,.resolution_mail_status] | join("|")' "$false_alarm_ledger")"
assert_contains 'false alarm resolution reason stays on record' \
  '误报：生产服务一直正常，没有影响用户。' \
  "$(jq -r '.incidents[0].resolution_reason' "$false_alarm_ledger")"

# Recovery closes an already mailed lifecycle, even for ledgers predating urgent.
for classification in legacy mailed queued; do
  recovery_ledger="$tmp/$classification.json"
  jq -n --arg classification "$classification" --arg issue "$recovery_issue" '
    {started_at:1000,last_sent_at:2000,last_digest_slot:"recent",nodes:{},incidents:[
      ({issue:$issue,opened_at:1000,status:"open"} +
        if $classification == "legacy" then {}
        elif $classification == "mailed" then {urgent:false,initial_mail_status:"sent"}
        else {urgent:false,initial_mail_status:"queued"} end)
    ]}' > "$recovery_ledger"
  before="$(wc -l < "$MAIL_EVENTS")"
  expected="$before"
  maintainer_health_mail_incident_release_accepted "$recovery_ledger" "$recovery_issue" accepted-sha 2001
  assert_eq "$classification recovery sends no immediate mail" "$expected" "$(wc -l < "$MAIL_EVENTS")"
  assert_eq "$classification recovery leaves daily report timestamp alone" 2000 "$(jq -r '.last_sent_at' "$recovery_ledger")"
  maintainer_health_mail_incident_tick "$recovery_ledger" 2002
  assert_eq "$classification recovery sends at most once" "$expected" "$(wc -l < "$MAIL_EVENTS")"
done

# A failure before the Gmail request is known safe to retry. Once a request
# may have reached Gmail, retain the one-attempt guard to avoid duplicate mail.
retry_issue="$((incident_fixture_seed + 3))"
retry_ledger="$tmp/retry-safe.json"
maintainer_health_mail_ensure_ledger "$retry_ledger" 3000
notify_maintainer_incident() {
  if [[ "${INCIDENT_MAIL_MODE:-success}" == safe-failure ]]; then
    NOTIFY_LAST_SEND_RETRY_SAFE=1
    return 1
  fi
  if [[ "${INCIDENT_MAIL_MODE:-success}" == uncertain-failure ]]; then
    NOTIFY_LAST_SEND_RETRY_SAFE=0
    return 1
  fi
  record_mail "$1" "$2" "$3" "$4" "$5" incident "$6"
}
INCIDENT_MAIL_MODE=safe-failure
if maintainer_health_mail_incident_open "$retry_ledger" "$retry_issue" '线上服务尚未恢复' \
  '服务暂时不可用。' '用户暂时无法使用。' '正在恢复服务。' 4000 3000 1 >/dev/null; then
  echo 'not ok - safe urgent-mail failure was reported as sent' >&2
  exit 1
fi
assert_eq 'safe initial-send failure remains marked for retry' 'failed-safe' \
  "$(jq -r '.incidents[0].initial_mail_status' "$retry_ledger")"
INCIDENT_MAIL_MODE=success
maintainer_health_mail_incident_open "$retry_ledger" "$retry_issue" '线上服务尚未恢复' \
  '服务暂时不可用。' '用户暂时无法使用。' '正在恢复服务。' 4000 3001 1 >/dev/null
assert_eq 'a repeated outage alert retries a safe failure exactly once' 'sent' \
  "$(jq -r '.incidents[0].initial_mail_status' "$retry_ledger")"
assert_eq 'the safe retry sends one immediate message' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
maintainer_health_mail_incident_open "$retry_ledger" "$retry_issue" '线上服务尚未恢复' \
  '服务暂时不可用。' '用户暂时无法使用。' '正在恢复服务。' 4000 3002 1 >/dev/null
assert_eq 'the successful retry is not sent again' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

uncertain_issue="$((incident_fixture_seed + 4))"
uncertain_ledger="$tmp/uncertain-send.json"
maintainer_health_mail_ensure_ledger "$uncertain_ledger" 5000
INCIDENT_MAIL_MODE=uncertain-failure
maintainer_health_mail_incident_open "$uncertain_ledger" "$uncertain_issue" '线上服务尚未恢复' \
  '服务暂时不可用。' '用户暂时无法使用。' '正在恢复服务。' 6000 5000 1 >/dev/null
assert_eq 'an uncertain result is recorded without a duplicate retry' 'uncertain' \
  "$(jq -r '.incidents[0].initial_mail_status' "$uncertain_ledger")"
maintainer_health_mail_incident_open "$uncertain_ledger" "$uncertain_issue" '线上服务尚未恢复' \
  '服务暂时不可用。' '用户暂时无法使用。' '正在恢复服务。' 6000 5001 1 >/dev/null
assert_eq 'an uncertain initial request is attempted only once' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

[[ "$FAILED" == 0 ]] || exit 1
