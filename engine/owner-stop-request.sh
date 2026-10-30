#!/usr/bin/env bash
set -euo pipefail
umask 077

manifest="${1:-}"
log_file="${2:-}"
unit="${3:-}"
requested_caller="${4:-}"
requested_stop_reason="${5:-}"

if [ -z "$manifest" ] || [ ! -r "$manifest" ]; then
  printf '%s owner-stop-request caller=UNKNOWN reason=manifest-unavailable unit=%s pid=UNKNOWN pid_start_ticks=UNKNOWN\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${unit:-UNKNOWN}" >&2
  exit 1
fi

exec {lock_fd}>"$manifest.stop-request.lock"
flock -x "$lock_fd"

if jq -e '.stop_request | type == "object"' "$manifest" >/dev/null 2>&1; then
  exit 0
fi

unit="${unit:-$(jq -r '.unit_name // empty' "$manifest")}"
existing_reason="$(jq -r '.stop_reason // empty' "$manifest")"
if [ -n "$existing_reason" ]; then
  caller=supervisor
  stop_reason="$existing_reason"
  requested_at="$(jq -r '.stop_requested_at // empty' "$manifest")"
elif [ -n "$requested_caller" ] && [ -n "$requested_stop_reason" ]; then
  caller="$requested_caller"
  stop_reason="$requested_stop_reason"
  requested_at=""
else
  status="$(jq -r '.status // empty' "$manifest")"
  case "$status" in launching|running) ;; *) exit 0 ;; esac
  result=""
  [ -z "$unit" ] || result="$(systemctl --user show "$unit" -p Result --value 2>/dev/null || true)"
  if [ "$result" = timeout ]; then
    caller=systemd
    stop_reason=runtime-max-sec
  else
    caller=UNKNOWN
    stop_reason=external-systemd-stop
  fi
  requested_at=""
fi

[[ "$caller" =~ ^[A-Za-z0-9_.-]+$ && "$stop_reason" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo 'owner-stop-request: invalid caller or reason' >&2
  exit 2
}
[[ "$unit" =~ ^[A-Za-z0-9_.@:-]+$ ]] || unit=UNKNOWN
[ -n "$requested_at" ] || requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pid="$(jq -r '.pid // empty' "$manifest")"
ticks="$(jq -r '.pid_start_ticks // empty' "$manifest")"
tmp="$manifest.stop-request.tmp.$$"
jq --arg caller "$caller" --arg reason "$stop_reason" --arg now "$requested_at" \
  --arg unit "$unit" --arg pid "$pid" --arg ticks "$ticks" \
  '.stop_reason = $reason | .stop_requested_at = $now | .stop_request = {
    caller:$caller, reason:$reason, requested_at:$now, unit_name:$unit,
    pid:(if ($pid | test("^[1-9][0-9]*$")) then ($pid | tonumber) else null end),
    pid_start_ticks:(if ($ticks | test("^[0-9]+$")) then $ticks else null end)
  }' "$manifest" > "$tmp"
mv -- "$tmp" "$manifest"

event="$requested_at owner-stop-request caller=$caller reason=$stop_reason unit=$unit pid=${pid:-UNKNOWN} pid_start_ticks=${ticks:-UNKNOWN}"
[ -z "$log_file" ] || printf '%s\n' "$event" >> "$log_file" 2>/dev/null || true
printf '%s\n' "$event"
