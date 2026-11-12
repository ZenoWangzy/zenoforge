# Sourced by bell.sh. Scheduler.log history scan for the last-seen epoch of a signature class.
# Needs its globals: now, STATE_JSON, A, and bell.sh's to_epoch.

# Superset of every substring scheduler_signature_class matches. The 24h history
# scan greps for these first: a bash read of the whole log per signature line
# (about 2.4 s per 17k lines in a bench) was the suspected cost of #366.
SCHEDULER_SIGNATURE_HINT='jqf error|unbound variable|TICK-TIMEOUT|REFILL-TIMEOUT|refusing to run this tick|slice-failed|advisor provider missing|review-family wait unit=|maintenance deferred streak'

scheduler_history_consider() {
  local line="$1" ts class
  [[ "$line" =~ ^\[([^]]+)\] ]] || return 0
  ts="${BASH_REMATCH[1]}"
  [[ "$ts" > "$SCHEDULER_CUTOFF_STAMP" && ( "$ts" < "$SCHEDULER_EVENT_STAMP" || "$ts" == "$SCHEDULER_EVENT_STAMP" ) ]] || return 0
  class="$(scheduler_signature_class "$line")"
  [[ "$class" == "$SCHEDULER_WANTED_CLASS" ]] || return 0
  if [[ -z "$SCHEDULER_HISTORY_STAMP" || "$ts" > "$SCHEDULER_HISTORY_STAMP" ]]; then
    SCHEDULER_HISTORY_STAMP="$ts"
  fi
}

scheduler_signature_last_seen() {
  local wanted="$1" before_line="$2" event_stamp="$3" file stored_epoch stored_recent=0 latest_epoch=0
  local SCHEDULER_WANTED_CLASS="$wanted" SCHEDULER_EVENT_STAMP="$event_stamp" SCHEDULER_HISTORY_STAMP=""
  SCHEDULER_CUTOFF_STAMP="$(python3 - "$((now - 86400))" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
  stored_epoch="$(jq -r --arg c "$wanted" '.scheduler_signature_seen[$c]//0' <<<"$STATE_JSON")"
  if [[ "$stored_epoch" =~ ^[0-9]+$ ]] && (( now - stored_epoch < 86400 )); then
    stored_recent="$stored_epoch"
  fi
  for file in "$A/scheduler.log.1" "$A/scheduler.log"; do
    [[ -r "$file" ]] || continue
    if [[ "$file" == "$A/scheduler.log" ]]; then
      (( before_line > 1 )) || continue
      while IFS= read -r history_line; do scheduler_history_consider "$history_line"; done \
        < <(sed -n "1,$((before_line - 1))p" "$file" 2>/dev/null | grep -E -- "$SCHEDULER_SIGNATURE_HINT")
    else
      while IFS= read -r history_line; do scheduler_history_consider "$history_line"; done \
        < <(grep -E -- "$SCHEDULER_SIGNATURE_HINT" "$file" 2>/dev/null)
    fi
  done
  if [[ -n "$SCHEDULER_HISTORY_STAMP" ]]; then
    latest_epoch="$(to_epoch "$SCHEDULER_HISTORY_STAMP")"
    [[ "$latest_epoch" =~ ^[0-9]+$ ]] || latest_epoch=0
  fi
  (( stored_recent > latest_epoch )) && latest_epoch="$stored_recent"
  printf '%s\n' "$latest_epoch"
}

