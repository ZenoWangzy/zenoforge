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

ledger="$tmp/night/maintainer-health-mail.json"
mkdir -p "$(dirname -- "$ledger")"
maintainer_health_mail_ensure_ledger "$ledger" 1000
maintainer_health_mail_incident_open "$ledger" 1221 '线上服务尚未恢复' \
  '生产发布后的检查未通过，自动恢复也没有成功。' \
  '用户目前看到：部分线上功能可能暂时不可用，恢复尚未确认。' \
  '我们正在：优先恢复服务并确认结果。' 15400 1000 1 >/dev/null
assert_eq 'production outage is mailed immediately and recorded' \
  '1221|线上服务尚未恢复|open|15400|sent|true' \
  "$(jq -r '.incidents[0] | [.issue,.subject,.status,.next_update_at,.initial_mail_status,.urgent] | join("|")' "$ledger")"
maintainer_health_mail_incident_open "$ledger" 1221 '线上服务尚未恢复' \
  '生产发布后的检查未通过，自动恢复也没有成功。' \
  '用户目前看到：部分线上功能可能暂时不可用，恢复尚未确认。' \
  '我们正在：优先恢复服务并确认结果。' 15400 1000 1 >/dev/null
assert_eq 'restarting release does not resend urgent outage mail' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

maintainer_health_mail_incident_tick "$ledger" 1599 >/dev/null
maintainer_health_mail_incident_tick "$ledger" 1600 >/dev/null
maintainer_health_mail_incident_tick "$ledger" 15400 >/dev/null
assert_eq 'ordinary incident ticks do not send repeat updates' '1' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
maintainer_health_mail_incident_release_accepted "$ledger" 1221 \
  '0123456789abcdef' 15401 >/dev/null
assert_eq 'urgent outage recovery sends immediately and closes incident' \
  'resolved|release|sent|0123456789abcdef' \
  "$(jq -r '.incidents[0] | [.status,.resolution_kind,.resolution_mail_status,.resolution_ref] | join("|")' "$ledger")"
assert_eq 'outage recovery is sent once' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
maintainer_health_mail_incident_tick "$ledger" 15400 >/dev/null
assert_eq 'repeated resolution tick sends nothing twice' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"

false_alarm_ledger="$tmp/night/false-alarm.json"
maintainer_health_mail_ensure_ledger "$false_alarm_ledger" 2000
maintainer_health_mail_incident_open "$false_alarm_ledger" 1222 '线上服务尚未恢复' \
  '验收检查没有通过。' '用户目前看到：生产服务正常。' \
  '我们正在：核实告警原因。' 16400 2000 0 >/dev/null
maintainer_health_mail_incident_mark_resolved "$false_alarm_ledger" 1222 \
  '误报：生产服务一直正常，没有影响用户。' 2100 >/dev/null
maintainer_health_mail_incident_tick "$false_alarm_ledger" 2100 >/dev/null
assert_eq 'false alarm resolution queues without immediate maintainer mail' '2' "$(wc -l < "$MAIL_EVENTS" | tr -d '[:space:]')"
assert_eq 'false alarm resolution is durable for the routine digest' \
  'resolved|supervisor|queued|2' \
  "$(jq -r '.incidents[0] | [.status,.resolution_kind,.resolution_mail_status] | join("|")' "$false_alarm_ledger")|$(jq -r '.pending_events | length' "$false_alarm_ledger")"
assert_contains 'false alarm resolution remains maintainer-readable' \
  '生产服务状态已确认：误报：生产服务一直正常，没有影响用户。' \
  "$(jq -r '.pending_events["incident:1222:2000:resolved"].text' "$false_alarm_ledger")"

# Recovery closes an already mailed lifecycle, even for ledgers predating urgent.
for classification in legacy mailed queued; do
  recovery_ledger="$tmp/$classification.json"
  jq -n --arg classification "$classification" '
    {started_at:1000,last_sent_at:2000,last_digest_slot:"recent",nodes:{},incidents:[
      ({issue:1230,opened_at:1000,status:"open"} +
        if $classification == "legacy" then {}
        elif $classification == "mailed" then {urgent:false,initial_mail_status:"sent"}
        else {urgent:false,initial_mail_status:"queued"} end)
    ]}' > "$recovery_ledger"
  before="$(wc -l < "$MAIL_EVENTS")"
  expected=$((before + 1))
  [[ "$classification" != queued ]] || expected="$before"
  maintainer_health_mail_incident_release_accepted "$recovery_ledger" 1230 accepted-sha 2001
  assert_eq "$classification recovery respects prior incident notification" "$expected" "$(wc -l < "$MAIL_EVENTS")"
  assert_eq "$classification recovery preserves routine cooldown" 2000 "$(jq -r '.last_sent_at' "$recovery_ledger")"
  maintainer_health_mail_incident_tick "$recovery_ledger" 2002
  assert_eq "$classification recovery sends at most once" "$expected" "$(wc -l < "$MAIL_EVENTS")"
done

[[ "$FAILED" == 0 ]] || exit 1
