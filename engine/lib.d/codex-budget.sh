_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# codex_tokens_used <transcript text or file> -> the last complete Codex
# usage count, normalized to decimal digits, or empty. Codex prints the
# literal marker on one line and its count on the immediately following line;
# an unrelated number elsewhere in a transcript is not usage. A killed or
# timed-out run normally has no complete pair, so empty is intentional and
# must never be turned into zero by a ledger caller.
codex_tokens_used() {
  local source="$1" text tokens
  if [ -f "$source" ]; then
    text="$(cat "$source" 2>/dev/null || true)"
  else
    text="$source"
  fi
  tokens="$(awk '
    /^[[:space:]]*tokens used[[:space:]]*$/ {
      waiting=1
      next
    }
    waiting {
      if ($0 ~ /^[[:space:]]*[0-9][0-9,]*[[:space:]]*$/) {
        value=$0
        gsub(/[[:space:],]/, "", value)
        last=value
      }
      waiting=0
    }
    END {
      if (last != "") print last
    }
  ' <<< "$text")"
  if [ -n "$tokens" ]; then
    printf '%s\n' "$tokens"
  else
    jq -Rr 'fromjson? | select(.type == "turn.completed") | .usage | [(.input_tokens - ([.cached_input_tokens, 0] | max)), .output_tokens] | map(if . < 0 then 0 else . end) | add' 2>/dev/null <<< "$text" | tail -n 1
  fi
}


# zcode_tokens_used <stream text or file> -> the raw token total (input side plus output)
# of the last {"type":"result"} line's usage, or empty. One result line closes one zcode
# invocation, so its counters are that run's own total, not a cumulative snapshot. Cache
# reads and cache creation are input-side tokens and count toward the total, matching
# usage_reader.Usage.raw for the Anthropic-style counters.
zcode_tokens_used() {
  local source="$1" text
  if [ -f "$source" ]; then
    text="$(cat "$source" 2>/dev/null || true)"
  else
    text="$source"
  fi
  jq -Rr 'fromjson? | select(.type == "result") | .usage // empty
    | [(.input_tokens // 0), (.cache_read_input_tokens // 0), (.cache_creation_input_tokens // 0), (.output_tokens // 0)] | add' \
    2>/dev/null <<< "$text" | tail -n 1
}


_codex_budget_proc_start_ticks() {
  local line rest ticks
  [ -r "/proc/$1/stat" ] || return 1
  IFS= read -r line < "/proc/$1/stat" || return 1
  rest="${line##*) }"
  ticks="$(awk '{print $20}' <<< "$rest")"
  [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ticks"
}


_codex_budget_reservation_live() {
  local pid="$1" ticks="$2" expires="$3" now="$4" current_ticks
  if [ "$pid" = 0 ]; then
    [[ "$expires" =~ ^[0-9]+$ ]] && (( now < expires ))
    return
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current_ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
  [ "$current_ticks" = "$ticks" ]
}


_codex_budget_actual_usage() {
  local now="$1" file production_identity
  file="$(spend_file_for_day "$now")"
  production_identity="$(model_policy identity production 2>/dev/null || true)"
  awk -F '\t' -v production_identity="$production_identity" '
    $3 ~ /^codex:/ && $6 ~ /^[0-9]+$/ {
      total += $6
      if ($2 == "production" || $3 == production_identity) production += $6
      else work += $6
    }
    END { printf "%.0f\t%.0f\t%.0f\n", total, work, production }
  ' "$file" 2>/dev/null || printf '0\t0\t0\n'
}


_codex_budget_reservation_usage() {
  local now="$1" exclude_id="${2:-}" id role tokens pid ticks expires
  local work=0 production=0
  if [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ]; then
    while IFS=$'\t' read -r id role tokens pid ticks expires; do
      [ -n "$id" ] && [ "$id" != "$exclude_id" ] || continue
      [[ "$tokens" =~ ^[0-9]+$ ]] || continue
      _codex_budget_reservation_live "$pid" "$ticks" "$expires" "$now" || continue
      case "$role" in
        work) work=$((work + tokens)) ;;
        production) production=$((production + tokens)) ;;
      esac
    done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  fi
  printf '%s\t%s\n' "$work" "$production"
}


_codex_budget_valid_config() {
  [[ "$CODEX_DAILY_TOKEN_BUDGET" =~ ^[1-9][0-9]*$ \
    && "$CODEX_PRODUCTION_TOKEN_RESERVE" =~ ^[0-9]+$ \
    && "$CODEX_PRODUCTION_TOKEN_RESERVE" -lt "$CODEX_DAILY_TOKEN_BUDGET" \
    && "$CODEX_BUDGET_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ \
    && "$CODEX_PRODUCTION_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ \
    && "$CODEX_HAND_DISPATCH_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ ]]
}


# codex_budget_status [now] -> verdict, actual used/limit, UTC-day projection,
# per-role totals, active reservations, and last account reset in TSV order.
codex_budget_status() {
  local now="${1:-$(date +%s)}" usage used work production reservations reserved
  local elapsed midnight projected verdict reset=unknown marker until production_reserve
  [[ "$now" =~ ^[0-9]+$ ]] && _codex_budget_valid_config || return 2
  usage="$(_codex_budget_actual_usage "$now")"
  IFS=$'\t' read -r used work production <<< "$usage"
  reservations="$(_codex_budget_reservation_usage "$now")"
  IFS=$'\t' read -r work_reserved production_reserved <<< "$reservations"
  reserved=$((work_reserved + production_reserved))
  midnight="$(date -u -d "$(date -u -d "@$now" +%F) 00:00:00" +%s)" || return 2
  elapsed=$((now - midnight))
  (( elapsed > 0 )) || elapsed=1
  projected="$(awk -v used="$used" -v elapsed="$elapsed" 'BEGIN { printf "%.0f", used * 86400 / elapsed }')"
  if (( used >= CODEX_DAILY_TOKEN_BUDGET )); then
    verdict=BROKEN
  elif (( used * 10 >= CODEX_DAILY_TOKEN_BUDGET * 7 )); then
    verdict=SLOW
  else
    verdict=OK
  fi
  marker="$(_quota_marker_file codex 2>/dev/null || true)"
  if [ -n "$marker" ] && [ -r "$marker" ]; then
    until="$(cat "$marker" 2>/dev/null || true)"
    if [[ "$until" =~ ^[0-9]+$ ]]; then reset="$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$verdict" "$used" "$CODEX_DAILY_TOKEN_BUDGET" "$projected" \
    "$work" "$production" "$reserved" "$reset"
}


# codex_budget_reserve <work|production> <id> [tokens] [provisional=0]
# Provisional leases expire after 15 minutes unless the launched child adopts.
codex_budget_reserve() {
  local role="$1" id="$2" tokens="${3:-}" provisional="${4:-0}" now="${5:-$(date +%s)}" model_identity="${6:-}"
  local usage used work production reservations work_reserved production_reserved total_reserved work_limit
  local pid ticks expires tmp lock_fd until marker traffic_monitor
  [[ "$role" = work || "$role" = production ]] || return 2
  [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  [[ "$now" =~ ^[0-9]+$ ]] && _codex_budget_valid_config || return 2
  if [ -z "$model_identity" ]; then model_identity="$(model_policy identity "$role")" || return 2; fi
  [[ "$model_identity" == codex:* ]] || return 2
  if codex_model_capacity_held "$model_identity" "$now"; then
    echo "codex budget: model capacity hold active for $model_identity" >&2
    return 75
  fi
  traffic_monitor="$(zf_host_ops_file scripts/agent/network-traffic.py "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")/network-traffic.py")"
  if [[ "$role" == work && -r "$traffic_monitor" ]]; then
    python3 -B "$traffic_monitor" admit --home "$AGENT_HOME" || return $?
  fi
  if [ -z "$tokens" ]; then
    if [ "$role" = production ]; then tokens="$CODEX_PRODUCTION_RESERVATION_TOKENS"; else tokens="$CODEX_BUDGET_RESERVATION_TOKENS"; fi
  fi
  [[ "$tokens" =~ ^[1-9][0-9]*$ ]] || return 2
  if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    codex_probe_ok || return 75
    codex_provider_recovery_probe_if_due "$model_identity" || return 75
  fi
  mkdir -p "$AGENT_HOME/locks" "$CODEX_BUDGET_DIR" || return 2
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  if provider_quota_exhausted codex; then
    marker="$(_quota_marker_file codex)"
    until="$(cat "$marker" 2>/dev/null || true)"
    echo "codex budget: provider quota hold active until $(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" >&2
    unlock_fd "$lock_fd"
    return 75
  fi
  usage="$(_codex_budget_actual_usage "$now")"
  IFS=$'\t' read -r used work production <<< "$usage"
  reservations="$(_codex_budget_reservation_usage "$now" "$id")"
  IFS=$'\t' read -r work_reserved production_reserved <<< "$reservations"
  total_reserved=$((work_reserved + production_reserved))
  work_limit=$((CODEX_DAILY_TOKEN_BUDGET - CODEX_PRODUCTION_TOKEN_RESERVE))
  if { [ "$role" = work ] && (( work + work_reserved + tokens > work_limit )); } \
    || (( used + total_reserved + tokens > CODEX_DAILY_TOKEN_BUDGET )); then
    echo "codex budget: refusing $role dispatch; used=$used/$CODEX_DAILY_TOKEN_BUDGET work=$work/$work_limit reserved=$total_reserved request=$tokens" >&2
    unlock_fd "$lock_fd"
    return 75
  fi
  if [ "$provisional" = 1 ]; then
    pid=0; ticks=0; expires=$((now + 900))
  else
    pid="$$"
    ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
    [[ "$ticks" =~ ^[0-9]+$ ]] || { unlock_fd "$lock_fd"; return 2; }
    expires=0
  fi
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  if [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ]; then
    while IFS=$'\t' read -r existing_id existing_role existing_tokens existing_pid existing_ticks existing_expires; do
      [ -n "$existing_id" ] && [ "$existing_id" != "$id" ] || continue
      _codex_budget_reservation_live "$existing_pid" "$existing_ticks" "$existing_expires" "$now" \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$existing_id" "$existing_role" "$existing_tokens" "$existing_pid" "$existing_ticks" "$existing_expires" >> "$tmp"
    done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$role" "$tokens" "$pid" "$ticks" "$expires" >> "$tmp"
  mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE" || { rm -f -- "$tmp"; unlock_fd "$lock_fd"; return 2; }
  unlock_fd "$lock_fd"
}


codex_budget_adopt() {
  local id="$1" pid="${2:-$$}" now="${3:-$(date +%s)}" ticks tmp lock_fd found=0
  [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$pid" =~ ^[1-9][0-9]*$ && "$now" =~ ^[0-9]+$ ]] || return 2
  ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
  [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
  [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ] || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  while IFS=$'\t' read -r existing_id role tokens old_pid old_ticks expires; do
    [ -n "$existing_id" ] || continue
    if [ "$existing_id" = "$id" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t0\n' "$id" "$role" "$tokens" "$pid" "$ticks" >> "$tmp"
      found=1
    else
      _codex_budget_reservation_live "$old_pid" "$old_ticks" "$expires" "$now" \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$existing_id" "$role" "$tokens" "$old_pid" "$old_ticks" "$expires" >> "$tmp"
    fi
  done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  if [ "$found" -eq 1 ]; then mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE"; else rm -f -- "$tmp"; fi
  unlock_fd "$lock_fd"
  [ "$found" -eq 1 ]
}


codex_budget_release() {
  local id="${1:-}" tmp lock_fd
  [ -n "$id" ] || return 0
  [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ] || return 0
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  awk -F '\t' -v id="$id" '$1 != id' "$CODEX_BUDGET_RESERVATIONS_FILE" > "$tmp" \
    && mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE" || { rm -f -- "$tmp"; unlock_fd "$lock_fd"; return 2; }
  unlock_fd "$lock_fd"
}

# Model capacity is scoped to the selected Codex model; provider-wide
# markers remain for quota, authentication, and transport outages.
codex_model_capacity_marker_file() {
  local value="$1" model
  case "$value" in codex:*) value="${value#codex:}" ;; esac
  model="${value%%:*}"
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s.model-%s.capacity\n' "$CODEX_EXHAUSTED_MARKER_FILE" "$model"
}

codex_model_capacity_held() {
  local marker until now="${2:-$(date +%s)}"
  marker="$(codex_model_capacity_marker_file "$1")" || return 1
  [ -r "$marker" ] || return 1
  until="$(cat "$marker" 2>/dev/null || true)"
  [[ "$until" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  (( now < until ))
}

codex_model_capacity_hold() {
  local marker until="${2:-$(( $(date +%s) + CODEX_PROVIDER_BACKOFF_SECONDS ))}" tmp
  [[ "$until" =~ ^[0-9]+$ ]] || return 2
  marker="$(codex_model_capacity_marker_file "$1")" || return 1
  mkdir -p "${marker%/*}" || return 1
  tmp="$marker.tmp.$$"
  printf '%s\n' "$until" > "$tmp" && mv -f -- "$tmp" "$marker"
}

# _quota_marker_file <provider> -- codex|web-advisor-provider|zcode -> that provider's
# marker path above. A lookup, not string interpolation (`$AGENT_HOME/$1-...`),
# so a typo'd or unknown provider name fails loudly (empty stdout, nonzero
# status) instead of silently minting a THIRD marker path nothing reads.
_quota_marker_file() {
  case "$1" in
    codex) printf '%s\n' "$CODEX_EXHAUSTED_MARKER_FILE" ;;
    web-advisor-provider) printf '%s\n' "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ;;
    zcode) printf '%s\n' "$ZCODE_EXHAUSTED_MARKER_FILE" ;;
    *) return 1 ;;
  esac
}


# parse_quota_reset_epoch <refusal_text> -- best-effort epoch seconds for a
# reset deadline STATED INSIDE the refusal, or nothing (status 1) if none
# was found or it did not parse.
#   Codex:  "...try again at Sep 19th, 2026 1:10 AM."
# A 26-hour wall against a fixed 30-minute backoff means dozens of re-probes
# that each cost nothing (the hold still works) but still burn a tick --
# parsing the stated deadline turns that into one hold that expires exactly
# when the provider says it will.
#
# Fails SAFE in both directions on purpose: the caller (note_provider_quota_
# exhausted, below) only trusts a parsed epoch that is still in the future;
# anything else -- no match, `date -d` rejecting the extracted text, a
# TZ database miss, a parsed time already in the past -- falls back to
# PREMIUM_QUOTA_BACKOFF_SECONDS instead of "no hold". A wrong SHORT guess
# just re-probes a bit early (the refund/re-detect loop below is unharmed by
# that); this function must never produce a wrong LONG guess that jams a
# provider closed past its real reset, which is why it only ever returns a
# value it parsed from the text, never a guessed/derived one.
parse_quota_reset_epoch() {
  local text="$1" when epoch
  # Codex shape: strip the ordinal suffix (1st/2nd/3rd/4th/...) -- `date -d`
  # rejects it but parses everything else unchanged.
  when="$(grep -oiE 'try again at ([A-Za-z]+ [0-9]{1,2}(st|nd|rd|th)?, [0-9]{4} )?[0-9]{1,2}:[0-9]{2} ?[AaPp][Mm]' <<< "$text" \
    | head -n1 | sed -E 's/^try again at //I; s/([0-9]+)(st|nd|rd|th)/\1/')"
  if [ -n "$when" ]; then
    epoch="$(agent_epoch "$when" 2>/dev/null || true)"
    [ -n "$epoch" ] && { echo "$epoch"; return 0; }
  fi
  return 1
}


# provider_quota_exhausted <codex|web-advisor-provider> -> exit 0 while that provider's
# recorded hold is still in force. Expiry only permits a probe; it is not
# proof the provider recovered, so the outage notification state stays until
# an actual non-refused call reports success below.
provider_quota_exhausted() {
  local provider="$1" marker until now
  marker="$(_quota_marker_file "$provider")" || return 1
  [ -f "$marker" ] || return 1
  until="$(cat "$marker" 2>/dev/null || true)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}


provider_quota_provider_for_model() {
  case "$1" in
    codex|codex:*) echo codex ;;
    web:*) echo web-advisor-provider ;;
    zcode|zcode:*) echo zcode ;;
    *) return 1 ;;
  esac
}


# The hold stays a single bare epoch marker, because dispatch readers already
# consume that interface. This sibling marker records that the provider
# outage is active; it survives an expired deadline until a real successful
# provider call confirms recovery.
provider_quota_alert_marker_file() {
  local marker
  marker="$(_quota_marker_file "$1")" || return 1
  printf '%s.alerted\n' "$marker"
}


provider_quota_lock_file() {
  case "$1" in
    codex|web-advisor-provider|zcode) printf '%s/locks/provider-quota-%s.lock\n' "$AGENT_HOME" "$1" ;;
    *) return 1 ;;
  esac
}


provider_quota_write_until() {
  local provider="$1" until="$2" marker tmp
  marker="$(_quota_marker_file "$provider")" || return 1
  tmp="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$until" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$marker"
}


# provider_quota_recovered <codex|web-advisor-provider> -- call only after a real,
# non-refused provider result. The lock serializes the local outage marker
# transition, so concurrent successful units record recovery once.
provider_quota_recovered() {
  local provider="$1" marker alert_marker lock_file lock_fd recovered=0
  marker="$(_quota_marker_file "$provider")" || return 1
  alert_marker="$(provider_quota_alert_marker_file "$provider")" || return 1
  lock_file="$(provider_quota_lock_file "$provider")" || return 1
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  if [ -f "$alert_marker" ]; then
    rm -f "$marker" "$alert_marker"
    recovered=1
    echo "provider_quota_recovered: $provider dispatch resumed" >&2
  fi
  unlock_fd "$lock_fd"
  [ "$recovered" = "1" ]
}


# note_provider_quota_exhausted <codex|web-advisor-provider> <issue|""> [refusal_text] --
# record the outage for that provider, and give back the attempt this
# ticket was charged at dispatch. A quota window is not the ticket's
# failure and must not count toward its give-up budget. $refusal_text, when
# given, is tried through parse_quota_reset_epoch() first; any failure to
# extract or parse it falls back to the fixed PREMIUM_QUOTA_BACKOFF_SECONDS
# (see that parser's own comment for why the fallback direction matters).
note_provider_quota_exhausted() {
  local provider="$1" n="${2:-}" refusal_text="${3:-}" normalized_refusal marker alert_marker lock_file lock_fd until parsed now reset_at
  marker="$(_quota_marker_file "$provider")" || { echo "note_provider_quota_exhausted: unknown provider '$provider'" >&2; return 1; }
  alert_marker="$(provider_quota_alert_marker_file "$provider")" || return 1
  lock_file="$(provider_quota_lock_file "$provider")" || return 1
  parsed=""
  [ -n "$refusal_text" ] && parsed="$(parse_quota_reset_epoch "$refusal_text" 2>/dev/null || true)"
  now="$(date +%s)"
  if [ -n "$parsed" ] && [ "$parsed" -gt "$now" ] 2>/dev/null; then
    until="$parsed"
  else
    until=$(( now + PREMIUM_QUOTA_BACKOFF_SECONDS ))
  fi
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  provider_quota_write_until "$provider" "$until" || {
    unlock_fd "$lock_fd"
    return 1
  }
  normalized_refusal="$(codex_usage_limit_text_for_matching "$refusal_text")"
  if [ "$provider" = codex ] && grep -qiE "you've hit your usage limit" <<< "$normalized_refusal"; then
    reset_at="$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    record_env_fault env:codex-usage-limit infrastructure "${n:-0}" \
      "Codex account usage limit; reset=$reset_at" "" "$now" 0 || {
      unlock_fd "$lock_fd"
      return 1
    }
  fi
  if [ ! -f "$alert_marker" ]; then
    printf '%s\n' "$until" > "$alert_marker"
    echo "note_provider_quota_exhausted: $provider unavailable until $(date -d "@$until" '+%Y-%m-%d %H:%M:%S %Z')" >&2
  fi
  unlock_fd "$lock_fd"
  echo "note_provider_quota_exhausted: $provider refused on quota -- holding $provider dispatch until $(date -d "@$until" '+%H:%M:%S') and not charging this attempt" >&2
  [ -n "$n" ] && state_unbump_attempts "$n"
  return 0
}


# codex_quota_exhausted -- thin, signature-preserving wrapper over the generic
# provider_quota_exhausted above; $CODEX_EXHAUSTED_MARKER_FILE keeps meaning
# exactly what it always meant.
codex_quota_exhausted() {
  local identity="${1:-}"
  if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    codex_probe_ok || return 0
    identity="${identity:-$(model_policy identity work)}" || return 0
    codex_provider_recovery_probe_if_due "$identity" || return 0
  fi
  provider_quota_exhausted codex
}

# note_codex_provider_outage <issue|session:key> <kind> <caller> <model> [now] --
# keep issue retries local; capacity holds its model, shared outages trip the
# Codex-wide circuit after three distinct issues in the observed window.
note_codex_provider_outage() {
  local n="$1" kind="$2" caller="$3" model="$4" now="${5:-$(date +%s)}"
  local until_epoch timestamp retry_json kind_json lock_file lock_fd tmp distinct seen_until
  [[ "$n" =~ ^[1-9][0-9]*$ || "$n" == session:* ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  until_epoch=$((now + CODEX_PROVIDER_BACKOFF_SECONDS))
  record_env_fault env:provider-outage infrastructure "$n" \
    "Codex provider outage kind=$kind caller=$caller model=$model" "" "$now" 0 || true
  timestamp="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  retry_json="$(jq -cn --arg issue "$n" --arg kind "$kind" --arg caller "$caller" \
    --arg model "$model" --arg timestamp "$timestamp" --argjson until "$until_epoch" \
    '{reason:("Codex provider outage (" + $kind + ")"),issue:$issue,provider:"codex",model:$model,caller:$caller,timestamp:$timestamp,until_epoch:$until}')" || return 1
  kind_json="$(jq -cn --arg kind "$kind" '$kind')" || return 1
  if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    state_merge "$n" ".model_policy = (.model_policy // {}) | .model_policy.active = (.model_policy.active // {}) | .model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = $kind_json | .model_failure_backoff = $retry_json" || return 1
  fi

  if [ "$kind" = provider-capacity ]; then
    if codex_model_capacity_hold "$model" "$until_epoch"; then
      echo "note_codex_provider_outage: model capacity hold opened for $model" >&2
    fi
    return 0
  fi

  # Issue egress failures share their own circuit; standalone sessions need a retry deadline.
  [ "$kind" != network-egress ] || [[ "$n" == session:* ]] || return 0

  mkdir -p "$AGENT_HOME/locks"
  lock_file="$(provider_quota_lock_file codex)" || return 1
  exec {lock_fd}>"$lock_file" || return 1
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 1; }
  tmp="$(mktemp "${CODEX_PROVIDER_FAILURE_EVENTS_FILE}.tmp.XXXXXX")" || { unlock_fd "$lock_fd"; return 1; }
  if [ -f "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" ]; then
    awk -F '\t' -v cutoff="$((now - CODEX_PROVIDER_FAILURE_WINDOW_SECONDS))" \
      '$1 ~ /^[0-9]+$/ && $1 >= cutoff && ($2 ~ /^[1-9][0-9]*$/ || $2 ~ /^session:/) { print }' \
      "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" > "$tmp" || { rm -f "$tmp"; unlock_fd "$lock_fd"; return 1; }
  fi
  mv -f "$tmp" "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" || { rm -f "$tmp"; unlock_fd "$lock_fd"; return 1; }
  if ! awk -F '\t' -v issue="$n" '$2 == issue { found=1 } END { exit found ? 0 : 1 }' "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"; then
    printf '%s\t%s\t%s\n' "$now" "$n" "$kind" >> "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" || { unlock_fd "$lock_fd"; return 1; }
  fi
  distinct="$(awk -F '\t' -v cutoff="$((now - CODEX_PROVIDER_FAILURE_WINDOW_SECONDS))" \
    '$1 ~ /^[0-9]+$/ && $1 >= cutoff && ($2 ~ /^[1-9][0-9]*$/ || $2 ~ /^session:/) { issues[$2]=1 } END { for (issue in issues) count++; print count+0 }' \
    "$CODEX_PROVIDER_FAILURE_EVENTS_FILE")"
  if [ "$distinct" -ge "$CODEX_PROVIDER_FAILURE_THRESHOLD" ]; then
    seen_until="$(cat "$CODEX_EXHAUSTED_MARKER_FILE" 2>/dev/null || true)"
    if ! [[ "$seen_until" =~ ^[0-9]+$ ]] || [ "$seen_until" -le "$now" ]; then
      provider_quota_write_until codex "$until_epoch" || { unlock_fd "$lock_fd"; return 1; }
    fi
    if [ ! -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
      printf '%s\n' "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" || { unlock_fd "$lock_fd"; return 1; }
      rm -f "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
      supervisor_inbox_append codex-provider-outage \
        "circuit=open distinct_issues=$distinct window=$CODEX_PROVIDER_FAILURE_WINDOW_SECONDS""s backoff=$CODEX_PROVIDER_BACKOFF_SECONDS""s" || { unlock_fd "$lock_fd"; return 1; }
      echo "note_codex_provider_outage: circuit opened after $distinct distinct issues; Codex held for ${CODEX_PROVIDER_BACKOFF_SECONDS}s before bare probe" >&2
    elif ! provider_quota_exhausted codex; then
      provider_quota_write_until codex "$until_epoch" || { unlock_fd "$lock_fd"; return 1; }
    fi
  fi
  unlock_fd "$lock_fd"
}


# Run a tiny read-only Codex call every 90s during an outage. No issue prompt
# or ticket context crosses this probe; only a completed response clears hold.
codex_provider_recovery_probe_if_due() {
  local identity="$1" spec model effort now due lock_file lock_fd probe_out probe_log status=0 kind="" timestamp service_tier issue probe_succeeded=0 timeout_seconds
  local -a service_tier_args=()
  [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] || return 0
  # An actual quota refusal must never be cleared by an availability probe.
  if [ -e "$CODEX_EXHAUSTED_MARKER_FILE.alerted" ] && provider_quota_exhausted codex; then return 1; fi
  case "$identity" in codex:*) spec="${identity#codex:}" ;; *) return 0 ;; esac
  [[ "$spec" == *:* ]] || return 1
  model="${spec%:*}"
  effort="${spec##*:}"
  [ -n "$model" ] && [ -n "$effort" ] || return 1
  timeout_seconds="${CODEX_JSON_TIMEOUT_SECONDS:-2700}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
  service_tier="$(model_policy tier "$identity")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  mkdir -p "$AGENT_HOME/locks"
  lock_file="$(provider_quota_lock_file codex)" || return 1
  exec {lock_fd}>"$lock_file" || return 1
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 1; }
  if [ ! -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    unlock_fd "$lock_fd"
    return 0
  fi
  if [ -e "$CODEX_EXHAUSTED_MARKER_FILE.alerted" ] && provider_quota_exhausted codex; then
    unlock_fd "$lock_fd"
    return 1
  fi
  now="$(date +%s)"
  due="$(cat "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" 2>/dev/null || true)"
  # Empty legacy latches probe immediately instead of inheriting the old thirty-minute deadline.
  if [[ "$due" =~ ^[0-9]+$ ]] && [ "$now" -lt "$due" ]; then
    unlock_fd "$lock_fd"
    return 1
  fi
  probe_out="$(mktemp)" || { unlock_fd "$lock_fd"; return 1; }
  probe_log="$(mktemp)" || { rm -f "$probe_out"; unlock_fd "$lock_fd"; return 1; }
  pipeline_execution_run timeout "${timeout_seconds}s" env -u GH_TOKEN -u GITHUB_TOKEN codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$REPO_DIR" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort=low "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$probe_out" - \
    <<< 'Reply with exactly: OK.' > "$probe_log" 2>&1 || status=$?
  now="$(date +%s)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$status" -eq 0 ] && [ -s "$probe_out" ]; then
    probe_succeeded=1
  elif [ "$status" -eq 124 ]; then
    rm -f "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    echo "codex_provider_recovery_probe_if_due: bare probe timed out; recovery latch cleared without extending provider hold" >&2
    return 0
  else
    kind="$(premium_call_provider_outage_kind "$(cat "$probe_log" 2>/dev/null || true)" || true)"
    if [ -z "$kind" ] && grep -qiE '401 Unauthorized|Incorrect API key|invalid_api_key' "$probe_log"; then
      kind="authentication/configuration"
    fi
    if [ "$kind" = provider-capacity ]; then
      codex_model_capacity_hold "$model" "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" || {
        rm -f "$probe_out" "$probe_log"
        unlock_fd "$lock_fd"
        return 1
      }
      probe_succeeded=1
    fi
  fi
  if [ "$probe_succeeded" = 1 ]; then
    # Clear only outage backoffs proven older than this successful probe; preserve other failure holds.
    while read -r issue; do
      state_merge "$issue" "if .model_failure_backoff.provider == \"codex\" and (.model_failure_backoff.reason // \"\" | startswith(\"Codex provider outage (\")) and (.model_failure_backoff.timestamp // \"\") <= \"$timestamp\" then del(.model_failure_backoff) else . end" || {
        rm -f "$probe_out" "$probe_log"; unlock_fd "$lock_fd"; return 1;
      }
    done < <(awk -F '\t' '$2 ~ /^[1-9][0-9]*$/ { issues[$2]=1 } END { for (issue in issues) print issue }' "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" 2>/dev/null)
    rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_EXHAUSTED_MARKER_FILE.alerted" \
      "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
    : > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    if [ "$kind" = provider-capacity ]; then
      echo "codex_provider_recovery_probe_if_due: provider responded; model capacity held for $model, provider hold cleared" >&2
    else
      echo "codex_provider_recovery_probe_if_due: bare Codex probe passed; provider hold cleared" >&2
    fi
    return 0
  fi
  kind="${kind:-probe-unclassified}"
  printf '%s\n' "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" || {
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    return 1
  }
  provider_quota_write_until codex "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" || {
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    return 1
  }
  if [ "$kind" = "authentication/configuration" ] || [ "$kind" = "probe-unclassified" ]; then
    if [ ! -e "$CODEX_PROVIDER_PROBE_NOTICE_FILE" ]; then
      supervisor_inbox_append codex-provider-recovery-probe \
        "failed kind=$kind; dispatch remains held" || { rm -f "$probe_out" "$probe_log"; unlock_fd "$lock_fd"; return 1; }
      : > "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
    fi
  fi
  rm -f "$probe_out" "$probe_log"
  unlock_fd "$lock_fd"
  echo "codex_provider_recovery_probe_if_due: bare probe failed kind=$kind status=$status; dispatch held for ${CODEX_PROVIDER_BACKOFF_SECONDS}s" >&2
  return 1
}
