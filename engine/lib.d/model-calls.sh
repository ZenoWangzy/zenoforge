
# model_timeout_for_attempt <base_minutes> [issue] -- a wall-clock kill means
# the next attempt needs more room, not a refunded attempt. Keep escalation
# bounded to one step: a later timeout gets the same larger budget instead of
# multiplying forever.
model_timeout_for_attempt() {
  local base="${1:-}" n="${2:-${N:-}}" failure
  case "$base" in
    ''|*[!0-9]*) printf '%s\n' "$base"; return 0 ;;
  esac
  [ -n "$n" ] || { printf '%s\n' "$base"; return 0; }
  failure="$(state_read "$n" | jq -r '.last_failure_kind // empty' 2>/dev/null || true)"
  if [ "$failure" = "timeout" ]; then
    printf '%s\n' "$((base * 2))"
  else
    printf '%s\n' "$base"
  fi
}

issue_model_failure_backoff_remaining() {
  local n="$1" now="${2:-$(date +%s)}" until_epoch
  until_epoch="$(state_read "$n" | jq -r '.model_failure_backoff.until_epoch // 0' 2>/dev/null || echo 0)"
  [[ "$until_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf '0\n'; return; }
  if [ "$until_epoch" -gt "$now" ]; then printf '%s\n' "$((until_epoch - now))"; else printf '0\n'; fi
}


model_failure_backoff_summary() {
  local now="${1:-$(date +%s)}" f n remaining detail summary="" preselection_output preselection_ready=0
  local -a files=() candidates=()
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    files+=("$f")
  done

  if [ "${#files[@]}" -gt 0 ] && preselection_output="$(mktemp 2>/dev/null)"; then
    if python3 - "${files[@]}" >"$preselection_output" 2>/dev/null <<'PYTHON'
import json
import os
import sys

try:
    for path in sys.argv[1:]:
        try:
            with open(path, "r", encoding="utf-8") as state_file:
                state = json.load(state_file)
        except (json.JSONDecodeError, UnicodeDecodeError, RecursionError, ValueError):
            # Let the existing jq path decide how malformed or unsupported JSON behaves.
            include = True
        else:
            include = isinstance(state, dict) and "model_failure_backoff" in state
        if include:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
except OSError:
    sys.exit(1)
PYTHON
    then
      preselection_ready=1
      while IFS= read -r -d '' f; do candidates+=("$f"); done < "$preselection_output"
    fi
    rm -f -- "$preselection_output"
  fi

  if [ "$preselection_ready" -eq 1 ]; then
    files=("${candidates[@]}")
  fi

  for f in "${files[@]}"; do
    n="${f##*/}"; n="${n%.json}"
    remaining="$(issue_model_failure_backoff_remaining "$n" "$now")"
    [ "$remaining" -gt 0 ] || continue
    detail="$(state_read "$n" | jq -r --arg issue "#$n" --argjson remaining "$remaining" \
      '(.model_failure_backoff // {}) | "\($issue) \(.provider // "unknown")/\(.model // "unknown") caller=\(.caller // "unknown") remaining=\($remaining)s"' 2>/dev/null || true)"
    [ -n "$detail" ] && summary="${summary:+$summary; }$detail"
  done
  printf '%s\n' "$summary"
}


manual_pause_is_valid() {
  local timestamp
  [ -s "$PAUSE_FILE" ] || return 1
  jq -e '
    type == "object" and .caller == "operator" and
    ([.reason, .issue, .provider, .model, .timestamp] | all(type == "string" and length > 0)) and
    (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$PAUSE_FILE" >/dev/null 2>&1 || return 1
  timestamp="$(jq -r .timestamp "$PAUSE_FILE" 2>/dev/null)" || return 1
  agent_epoch -u "$timestamp" >/dev/null 2>&1
}


model_call_exit_class() {
  local status="${1:-}"
  [[ "$status" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  case "$status" in
    0) printf 'success\n' ;;
    124) printf 'wall_clock_timeout\n' ;;
    *)
      if ((10#$status >= 129 && 10#$status <= 192)); then
        printf 'signal_termination\n'
      else
        printf 'application_exit\n'
      fi
      ;;
  esac
}


model_call_signal_name() {
  local status="${1:-0}" number name
  number=$((10#$status - 128))
  name="$(kill -l "$number" 2>/dev/null || true)"
  case "$name" in
    '') name="SIG$number" ;;
    SIG*) ;;
    *) name="SIG$name" ;;
  esac
  printf '%s\n' "$name"
}


model_call_capture_termination_source() {
  local unit="${UNIT_PREFIX_TRANSIENT}-implement-${1:-unknown}.service" output=""
  MODEL_CALL_TERMINATION_SOURCE=unknown
  MODEL_CALL_TERMINATION_EVIDENCE=unknown
  if ! command -v systemctl >/dev/null 2>&1; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-unavailable"
    return 0
  fi
  if ! output="$(systemctl --user show "$unit" -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus 2>/dev/null)"; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-query-failed unit=$unit"
    return 0
  fi
  output="${output//$'\n'/;}"
  if [ -z "$output" ]; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-query-empty unit=$unit"
    return 0
  fi
  MODEL_CALL_TERMINATION_EVIDENCE="$output"
  if [[ "$output" == *ActiveState=failed* ]]; then
    case "$output" in
      *Result=oom-kill*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=oom-kill" ;;
      *Result=signal*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=signal" ;;
      *Result=timeout*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=timeout" ;;
    esac
  fi
}


model_call_failure_record() {
  local issue="$1" stage="$2" caller="$3" provider="$4" model="$5" status="$6"
  local exit_class="$7" termination_source="$8" termination_evidence="$9"
  local log_path="${10}" transcript_empty="${11}" timestamp record
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$status" =~ ^[0-9]+$ && "$status" != 0 ]] || return 0
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  record="$(jq -cn --arg issue "$issue" --arg stage "$stage" --arg caller "$caller" \
    --arg provider "$provider" --arg model "$model" --arg timestamp "$timestamp" \
    --arg status "$status" --arg exit_class "$exit_class" \
    --arg termination_source "$termination_source" --arg termination_evidence "$termination_evidence" \
    --arg log_path "$log_path" --arg transcript_empty "$transcript_empty" \
    '{issue:$issue,stage:$stage,caller:$caller,provider:$provider,model:$model,timestamp:$timestamp,exit_status:(try ($status|tonumber) catch null),termination_class:$exit_class,termination_source:$termination_source,termination_evidence:$termination_evidence,log_path:$log_path,transcript_empty:($transcript_empty == "true")}')" || return 1
  state_merge "$issue" ".last_model_call_failure = $record"
}


pause_for_backoff() {
  agent_pipeline_write_guard pause_for_backoff "$AGENT_HOME" || return 1
  # `${5-codex}` preserves an explicit empty provider: an unsupported
  # identity must not borrow another provider's quota state.
  local n="${1:-}" call_output="${2:-}" status="${3:-}" pause_nonquota="${4:-1}" provider="${5-codex}"
  local model="${6:-unknown}" caller="${7:-unknown}" timeout_detail timeout_stage reason reason_file now timestamp until_epoch backoff_json provider_kind="" role fault_detail fault_signature
  local log_path="${8:-}" termination_class="${9:-}" termination_source="${10:-}" termination_evidence="${11:-}"
  local transcript_empty="${12:-false}" stage="${13:-}" exit_status_json=null
  BACKOFF_QUOTA_PROVIDER=""
  MODEL_CALL_ENVIRONMENTAL_FAILURE=0
  MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=""
  MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL=""
  [ -n "$stage" ] || stage="${caller##*:}"
  [ -n "$stage" ] || stage=unknown
  [ -n "$termination_class" ] || termination_class="$(model_call_exit_class "$status")"
  if [ -z "$termination_source" ]; then
    if [ "$termination_class" = signal_termination ]; then termination_source=unknown; else termination_source=not_applicable; fi
  fi
  if [[ "$status" =~ ^[0-9]+$ ]]; then exit_status_json="$status"; fi
  if [ -n "$log_path" ]; then
    model_call_failure_record "$n" "$stage" "$caller" "$provider" "$model" "$status" \
      "$termination_class" "$termination_source" "$termination_evidence" "$log_path" "$transcript_empty" || return 1
  fi
  if [ "$status" = "124" ]; then
    timeout_detail="$(printf '%s\n' "$call_output" | grep -Eo '[^[:cntrl:]]*timed out after [0-9]+s \(elapsed [0-9]+s\)' | tail -n 1 || true)"
    [ -n "$timeout_detail" ] || timeout_detail="premium call timed out with exit 124; configured limit and elapsed time were not supplied by caller"
    timeout_stage="${GH_ENV_FAULT_STAGE:-premium-call}"
    echo "pause_for_backoff: $timeout_detail -- recorded as env:network-timeout; no PAUSE or quota alert" >&2
    record_env_fault env:network-timeout "$timeout_stage" "${n:-0}" "$timeout_detail" "" "" 0
    [ -n "$n" ] && state_merge "$n" '.last_failure_kind = "timeout"' || true
    return 0
  fi
  if model_call_missing_agent_binary "$call_output" "$status" "$provider" "$model"; then
    if [ "$provider" = codex ] || grep -qi 'codex' <<< "$call_output"; then
      MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=codex-binary-missing
      fault_signature=env:codex-binary-missing
    else
      MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=agent-tool-exit-127
      fault_signature=env:agent-tool-exit-127
    fi
    MODEL_CALL_ENVIRONMENTAL_FAILURE=1
    fault_detail="$(printf '%s' "$call_output" | tr '\r\n\t' '   ' | cut -c1-1000)"
    MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL="$fault_detail"
    record_codex_runtime_fault "$fault_signature" "$stage" "${n:-0}" "$fault_detail" || return 1
    if [[ "$n" =~ ^[1-9][0-9]*$ ]] \
      && state_read "$n" | jq -e '.model_policy.active | type == "object"' >/dev/null 2>&1; then
      if [ "$MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND" = codex-binary-missing ]; then
        state_merge "$n" '.model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = "codex-binary-missing"' || return 1
      else
        state_merge "$n" '.model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = "agent-tool-exit-127"' || return 1
      fi
    fi
    echo "pause_for_backoff: $MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND at $caller; kept stage and refunded through model-policy retry" >&2
    return 0
  fi
  if [ "$termination_class" != signal_termination ] && [ "$provider" = codex ] \
    && codex_config_fast_failure "$call_output"; then
    record_codex_config_fault "$n" "$stage" "$call_output"
    return $?
  fi
  if [ "$termination_class" != signal_termination ] && [ "$provider" = "codex" ] && [ -n "$call_output" ] \
    && [ "$status" != "0" ]; then
    provider_kind="$(premium_call_provider_outage_kind "$call_output" || true)"
  fi
  if [ "$termination_class" != signal_termination ] && model_call_is_configuration_error "$call_output" "${status:-1}" \
    && [ "$(model_call_failure_kind "$call_output" "${status:-1}")" = execution ] \
    && [ "$provider_kind" != websocket-401 ]; then
    if [ "$provider" = web-advisor-provider ]; then
      role=advisor
    else
      role="$(state_read "$n" | jq -r '.model_policy.active.role // "work"')"
    fi
    record_model_config_fault "$n" "${caller#*:}" "$role" "$model" "$call_output" || return 1
    return 0
  fi
  if [ -n "$provider_kind" ]; then
    note_codex_provider_outage "$n" "$provider_kind" "$caller" "$model" || return 1
    echo "pause_for_backoff: Codex provider outage ($provider_kind); issue #${n:-unknown} kept on current rung for retry" >&2
    return 0
  fi
  if [ "$termination_class" != signal_termination ] && [ -n "$provider" ] && [ -n "$call_output" ] && premium_call_is_quota_refused "$call_output" "$status"; then
    [ -n "$n" ] && state_merge "$n" 'del(.last_failure_kind)' || true
    note_provider_quota_exhausted "$provider" "$n" "$call_output"
    BACKOFF_QUOTA_PROVIDER="$provider"
    return $?
  fi
  if [ "$termination_class" != signal_termination ] && [ -n "$call_output" ] && [ "$(model_call_failure_kind "$call_output" "${status:-1}")" = transient ]; then
    case "$provider" in
      codex) note_codex_provider_outage "$n" transport "$caller" "$model"; return $? ;;
      web-advisor-provider)
        note_provider_quota_exhausted web-advisor-provider "$n" "$call_output"
        BACKOFF_QUOTA_PROVIDER=web-advisor-provider
        return $? ;;
      # A transient zcode failure holds the zcode review lane for one backoff
      # window (same shape as web-advisor-provider above), which is exactly the signal
      # review_identity_available() reads to fall the next review back to the
      # implementer's own provider.
      zcode)
        note_provider_quota_exhausted zcode "$n" "$call_output"
        BACKOFF_QUOTA_PROVIDER=zcode
        return $? ;;
    esac
  fi
  [ -n "$n" ] && state_merge "$n" 'del(.last_failure_kind)' || true
  [ "$pause_nonquota" = "1" ] || return 0
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "pause_for_backoff: unclassified model failure has no valid issue; no global PAUSE written" >&2
    return 0
  fi
  now="$(date +%s)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  until_epoch=$((now + 3600))
  reason="unclassified model call failure (exit ${status:-unknown})"
  reason_file="$(jq_arg_file "$reason")" || return 1
  if ! backoff_json="$(jq -cn --rawfile reason "$reason_file" --arg caller "$caller" --arg issue "$n" \
    --arg provider "${provider:-unknown}" --arg model "$model" --arg timestamp "$timestamp" \
    --arg stage "$stage" --arg termination_class "$termination_class" \
    --arg termination_source "$termination_source" --arg termination_evidence "$termination_evidence" \
    --arg log_path "$log_path" --arg transcript_empty "$transcript_empty" \
    --argjson exit_status "$exit_status_json" --argjson until_epoch "$until_epoch" \
    '{reason:$reason,caller:$caller,issue:$issue,stage:$stage,provider:$provider,model:$model,timestamp:$timestamp,exit_status:$exit_status,termination_class:$termination_class,termination_source:$termination_source,termination_evidence:$termination_evidence,log_path:$log_path,transcript_empty:($transcript_empty == "true"),until_epoch:$until_epoch}')"; then
    rm -f -- "$reason_file"
    return 1
  fi
  rm -f -- "$reason_file"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] pause_for_backoff -> issue #$n backoff $backoff_json" >&2
    return 0
  fi
  state_merge "$n" ".model_failure_backoff = $backoff_json" || return 1
  # No maintainer mail: a per-issue backoff is an internal alert (maintainer mail contract; 2026-10-04 the bell
  # flagged "[example] 模型调用暂不可用" as off-contract). A node stalled by it reaches him via the health mail.
  echo "pause_for_backoff: issue #$n backed off for 3600s after $caller failure; no global PAUSE written" >&2
}


# A failed structured model result is exactly where the
# diagnosis lives (.is_error, .subtype, .result, .api_error_status) — the
# 2026-09-12 bug was throwing it away on failure instead of writing it
# anywhere, so a 45-minute run left a human with nothing to look at. Always
# writes (a diagnostic log is not pipeline state, so it is NOT gated by
# AGENT_DRY_RUN — a dry run is exactly when a human most wants this file) and
# echoes the decisive fields to stderr so a human running the script by hand
# sees them immediately without opening the log. Prints the log path on
# stdout so the caller can fold it into a state file or issue comment.
log_model_failure() {
  local tag="$1" output="$2" status="$3" log_file
  log_file="$LOG_DIR/$tag-$(date -u +%Y%m%dT%H%M%SZ).log"
  {
    echo "exit_status=$status"
    echo "--- raw model call output ---"
    echo "$output"
  } > "$log_file"
  {
    echo "$tag: model call failed (exit $status). Full output: $log_file"
    echo "$tag: is_error=$(echo "$output" | jq -r '.is_error' 2>/dev/null || echo '?')" \
      "subtype=$(echo "$output" | jq -r '.subtype' 2>/dev/null || echo '?')" \
      "api_error_status=$(echo "$output" | jq -r '.api_error_status' 2>/dev/null || echo '?')"
    echo "$tag: result=$(echo "$output" | jq -r '.result' 2>/dev/null | head -c 500 || echo '?')"
  } >&2
  echo "$log_file"
}


# premium_call_is_quota_refused <call_output> <exit_status> -- true (0) iff
# the call contains a provider usage-limit error or normalized HTTP
# 429 error. Provider capacity and overload errors use the outage classifier below
# and stay on the same model rung;
# everything else is a real failure -- "a genuine error still fails" is the
# other half of the same 2026-09-15 ruling that removed the local budget
# check, so a schema violation or a crash at whichever rung answered must
# surface as this run's own failure, never get silently retried on a weaker
# or unrelated model as if it were a refusal.
#
# Matches on TEXT, the same discipline as gh_failure_is_transient() above:
# known refusal shapes only, never a bare nonzero exit (a `codex exec`
# timeout or a malformed response is a real failure, not a refusal).
# $call_output is whatever the caller already has on hand -- model call's own
# JSON (`.api_error_status`, `.subtype`, `.result`) from a provider response, or
# run_codex_json()'s normalized `{is_error, result}` (its own `result` field
# already carries the captured codex transcript on failure -- see below) for
# a Codex call. One detector, because both are read the same way once
# normalized.
premium_call_provider_outage_kind() {
  local output="$1" api_status
  if grep -qiE 'failed to connect to websocket|proxy connection failed: HTTP CONNECT failed with status 50[234]|workspace routing discovery failed' <<< "$output"; then
    echo network-egress
    return 0
  fi
  if awk 'tolower($0) ~ /websocket closed by server before response\.completed|stream disconnected/ { closed=1 } closed && tolower($0) ~ /401 unauthorized/ { found=1 } END { exit found ? 0 : 1 }' <<< "$output"; then
    echo websocket-401
    return 0
  fi
  if grep -qi 'websocket closed by server before response.completed' <<< "$output"; then
    echo websocket-closed
    return 0
  fi
  if grep -qi 'stream disconnected' <<< "$output"; then
    echo stream-disconnected
    return 0
  fi
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in 400|401|403|404|422) return 1 ;; esac
  if [[ "$api_status" =~ ^5[0-9][0-9]$ ]] || grep -qiE '(unexpected status|HTTP)[[:space:]:]+5[0-9][0-9]' <<< "$output"; then
    echo provider-5xx
    return 0
  fi
  if grep -qiE 'selected[[:space:]]+model[^[:cntrl:]]*capacity|(^|[^[:alnum:]_])at[[:space:]]+capacity([^[:alnum:]_]|$)|overload(ed)?(_error)?' <<< "$output"; then
    echo provider-capacity
    return 0
  fi
  if grep -qF 'Reconnecting... 5/5' <<< "$output" \
    && ! grep -qiE 'codex-final-output-present=(true|1)|"model_output_present"[[:space:]]*:[[:space:]]*true|response\.output_text\.delta' <<< "$output"; then
    echo reconnect-exhausted
    return 0
  fi
  return 1
}


codex_usage_limit_text_for_matching() {
  local text="$1" apostrophe="'"
  printf '%s' "${text//’/$apostrophe}"
}


premium_call_is_quota_refused() {
  local output="$1" status="${2:-1}" api_status envelope events
  [ "$status" -ne 0 ] && [ "$status" -lt 129 ] || return 1
  # A provider outage must never become the thirty-minute quota circuit.
  [ -z "$(premium_call_provider_outage_kind "$output" || true)" ] || return 1
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  [ "$api_status" = 429 ] && return 0
  envelope="$(jq -r 'select(type == "object" and .is_error == true) | .result | select(type == "string")' 2>/dev/null <<< "$output" || true)"
  [ -z "$envelope" ] || output="$envelope"
  # Only CLI error events, never item.completed agent messages or quoted JSON.
  events="$(jq -Rr 'fromjson? | if .type == "error" then .message elif .type == "turn.failed" then .error.message else empty end | select(type == "string")' 2>/dev/null <<< "$output" || true)"
  [ -z "$events" ] || output="$events"
  # GNU grep's [’] bracket expression does not reliably match under the
  # pipeline's LC_ALL=C. Normalize the CLI's typographic apostrophe first.
  output="$(codex_usage_limit_text_for_matching "$output")"
  # Actual CLI display shapes (openai/codex rust-v0.162.1 protocol/src/error.rs).
  grep -qiE "^(ERROR: )?You've hit your usage limit(\.| for )|^ERROR: unexpected status 429 Too Many Requests: (Rate limit reached|You've hit your usage limit)" <<< "$output"
}


# Session logs mix agent prose and provider diagnostics. Read only bounded,
# anchored CLI errors; codex-error is a broad log label, not provider evidence.
codex_session_error_output() {
  tail -c 16000 -- "$1" 2>/dev/null | jq -Rr '
    if test("^[^ ]+ codex-provider-error ") then sub("^[^ ]+ codex-provider-error "; "ERROR: ")
    else fromjson? | if .type == "error" then .message elif .type == "turn.failed" then .error.message else empty end
      | select(type == "string") | "ERROR: " + . end' 2>/dev/null || true
}


codex_session_error_kind() {
  local output="$1" status="${2:-1}" kind
  kind="$(premium_call_provider_outage_kind "$output" || true)"
  if [ -n "$kind" ]; then
    echo "$kind"
    return 0
  fi
  if premium_call_is_quota_refused "$output" "$status"; then
    echo quota-429
    return 0
  fi
  return 1
}


codex_session_failure() {
  local log_file="$1" status="$2" caller="$3" model="$4" signal="${5:-}" output kind
  [ "$status" -ne 0 ] && [ "$status" -lt 129 ] && [ -z "$signal" ] || return 0
  output="$(codex_session_error_output "$log_file")"
  [ -n "$output" ] || return 0
  kind="$(codex_session_error_kind "$output" "$status" || true)"
  if [ "$kind" != quota-429 ] && [ -n "$kind" ]; then
    note_codex_provider_outage "session:$caller:${log_file##*/}" "$kind" "$caller" "$model"
  elif [ "$kind" = quota-429 ]; then
    if ! [[ "${ZF_HAND_PROVIDER_RETRY:-}" =~ ^[01]$ ]]; then
      note_provider_quota_exhausted codex "" "$output"
    fi
  fi
  return 0
}


# Classify the invocation, not an advisor's semantic verdict. Valid JSON
# zero values remain data; empty/non-object output is not a successful call.
# Missing verdict fields still go through the caller's fail-closed schema path.
model_call_is_configuration_error() {
  local output="$1" status="$2" api_status
  [ "$status" -eq 124 ] && return 1
  [ "$status" -eq 64 ] && return 0
  codex_config_fast_failure "$output" && return 0
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in 400|401|403|404|422) return 0 ;; esac
  grep -qiE '((unexpected status|HTTP|status code)[[:space:]:]+(400|401|403|404|422)([^0-9]|$))|(unrecognized|invalid) model|(unsupported|unexpected|unrecognized|unknown) (model|identity|argument|option|flag)|model slug|may not exist or you may not have access' <<< "$output"
}


model_call_missing_agent_binary() {
  local output="$1" status="${2:-}" provider="${3:-}" model="${4:-unknown}"
  if [[ "$status" == 127 && "$model" != unknown && "$provider" =~ ^(codex|web-advisor-provider)$ ]]; then
    return 0
  fi
  grep -Eiq \
    '(codex|agent[- ]tool).{0,120}(no such file or directory|enoent|command not found)|(no such file or directory|enoent|command not found).{0,120}(codex|agent[- ]tool)|model_call_exit_status=127|codex_exit_status.{0,4}127|agent[- ]tool.{0,120}(exit|status|code).{0,8}127|tool call.{0,120}(exit|status|code).{0,8}127' \
    <<< "$output"
}


model_call_failure_kind() {
  local output="$1" status="$2" api_status provider_kind
  if [ "$status" = 127 ] || model_call_missing_agent_binary "$output" "$status" "" ""; then
    echo transient
    return 0
  fi
  if [ "$status" -eq 124 ]; then
    echo transient
    return 0
  fi
  if [ "$status" -eq 0 ] && jq -e 'type == "object" and .is_error != true and .is_error != "true"' >/dev/null 2>&1 <<< "$output"; then
    echo none
    return 0
  fi
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in
    400|401|403|404|422) echo execution; return 0 ;;
  esac
  provider_kind="$(premium_call_provider_outage_kind "$output" || true)"
  if [ "$provider_kind" = provider-capacity ]; then
    echo transient
    return 0
  fi
  # A structured status outranks incidental words in the error narrative.
  case "$api_status" in
    429) echo quota; return 0 ;;
    500|502|503|504) echo transient; return 0 ;;
  esac
  if model_call_is_configuration_error "$output" "$status"; then
    echo execution
    return 0
  fi
  if premium_call_is_quota_refused "$output" "$status"; then
    echo quota
  elif [ "$status" -eq 124 ] || gh_failure_is_transient "$output"; then
    echo transient
  elif ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    echo malformed
  else
    echo execution
  fi
}


# codex_probe_ok -- true (0) iff a Codex identity is admitted on this box
# right now. Same predicate resolve_guarded_reviewer() applies to a single
# identity, exposed standalone for a caller (run-advisor.sh's ladder) that
# needs to decide UP FRONT whether to include the whole Codex sub-ladder at
# all, not resolve one identity.
codex_probe_ok() { [ -f "$CODEX_PROBE_MARKER" ]; }


# run_codex_json <cwd> <model> <effort> <schema_file> <prompt_file> -- runs
# `codex exec` with the same containment flags probe-codex-sandbox.sh
# measured (--sandbox read-only, --cd, --skip-git-repo-check, --ephemeral),
# constrained to $schema_file via --output-schema, fed $prompt_file on
# stdin, and normalizes its result to the shared {is_error, structured_output}
# envelope consumed by pipeline callers.
# total_cost_usd is never set (Codex reports tokens, not USD -- see
# model_cost_usd above) so that field reads empty for a Codex response,
# exactly like an absent field. This is the pipeline's one Codex runner --
# see run-advisor.sh's own comment on why it lives here instead of being
# built a second time wherever else a `codex:` identity is dispatched.
#
# Model and effort are separate Codex arguments; every caller gets both from
# the persistent role policy.
run_codex_json() {
  local cwd="$1" model="$2" effort="$3" schema_file="$4" prompt_file="$5" service_tier
  local -a service_tier_args=()
  local out_file transcript status=0 body result_text tokens_used timeout_seconds started_at elapsed timeout_detail model_output_present=false
  model_policy_require_implementer_identity "codex:$model:$effort" || { jq -nc '{is_error: true, subtype: "unsupported_model_identity", result: "identity does not match the work role"}'; return 64; }
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  timeout_seconds="${CODEX_JSON_TIMEOUT_SECONDS:-2700}"
  out_file="$(mktemp)"; transcript="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e`: the latter toggles a GLOBAL
  # shell option, which leaks into the caller's own shell for any caller
  # that invokes this as a bare statement (not shielded by a command-
  # substitution subshell) -- 2026-09-15, found while adding run_codex_
  # implement() below (see its own comment): a caller running under
  # `set -e` that calls this function as a bare statement would have its
  # OWN `set -e` silently re-armed by this function's internal `set -e`
  # just before `return`, then killed on the spot the moment that return
  # carries a nonzero status -- no log, no fail_attempt bookkeeping, the
  # exact failure mode this file's own callers already guard against for
  # every model call. `cmd || status=$?` is the exempted-by-`||` bash
  # idiom instead: self-contained, works identically whether or not the
  # caller has `set -e` active, and never mutates shared shell state.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_seconds}s" codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-schema "$schema_file" --output-last-message "$out_file" \
    - < "$prompt_file" > "$transcript" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex exec timed out after ${timeout_seconds}s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$transcript"
    echo "$timeout_detail" >&2
  fi
  body="$(cat "$out_file" 2>/dev/null || true)"
  [ -s "$out_file" ] && model_output_present=true
  tokens_used="$(codex_tokens_used "$transcript")"
  if [ "$status" -eq 0 ] && echo "$body" | jq -e . >/dev/null 2>&1; then
    # $body is codex's own structured output -- unbounded (an advisor
    # ruling, a review report, ...). It's already on disk as $out_file, so
    # --slurpfile reads it straight from there instead of round-tripping
    # through argv via --argjson; --slurpfile always binds an array, hence
    # $so[0] here (see jq_arg_file()'s own comment in lib.sh).
    jq -nc --slurpfile so "$out_file" --arg tokens "$tokens_used" \
      '{is_error: false, structured_output: $so[0], tokens_used: $tokens}'
  else
    # 2026-09-16 P0 fix, measured against
    # $HOME/.zenoforge/logs/advisor-1327-20260917T033841Z.log: this
    # used to be `head -c 2000`, which keeps the START of the transcript --
    # codex's own banner (`model:`, `sandbox:`, `session id:`), the echoed
    # user prompt, and any bubblewrap/skill/`hook:` warnings -- and throws
    # away the END, which is where codex actually writes its error. That
    # log's own `result` field was exactly 1900 chars of banner + echoed
    # prompt with `tokens_used` empty and the words "quota"/"usage limit"
    # nowhere in it, even though the real transcript that run captured ended
    # in `ERROR: You've hit your usage limit ... try again at Sep 19th, 2026
    # 1:10 AM.` -- invisible to premium_call_is_quota_refused() (below)
    # purely because of which end got kept. `tail -c 2000` matches the
    # existing `tail -c 4000` precedent in run-implement.sh's own IMPLEMENT_LOG
    # quota-refusal check, which is exactly why that leg never had this bug
    # and only the implement leg ever wrote CODEX_EXHAUSTED_MARKER_FILE
    # before this fix (GitHub issue #1350). The model identity that failed is
    # already reported separately by the caller's own fail_attempt() message
    # (the candidate/IMPLEMENT_MODEL string is interpolated there), so losing
    # the banner here costs nothing.
    result_text="$(tail -c 2000 "$transcript" 2>/dev/null)"
    jq -nc --arg result "$result_text" --arg status "$status" --arg tokens "$tokens_used" --arg elapsed "$elapsed" \
      --argjson output_present "$model_output_present" \
      '{is_error: true, subtype: "codex_exec_failure", result: $result, codex_exit_status: ($status|tonumber), tokens_used: $tokens, model_output_present: $output_present, codex_elapsed_seconds: ($elapsed|tonumber)}'
  fi
  rm -f "$out_file" "$transcript"
  return "$status"
}


# zcode_extract_json_object <raw reply> -- the last parseable JSON object in
# zcode's final message: a fenced ```json block wins (the prompt asks for
# exactly one), otherwise the last balanced top-level object. No candidate
# prints nothing (caller fails closed).
zcode_extract_json_object() {
  printf '%s' "$1" | node -e '
let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { text += chunk; });
process.stdin.on("end", () => {
  if (text.length > 2000000) text = text.slice(-2000000);
  const fences = [...text.matchAll(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/g)];
  for (let i = fences.length - 1; i >= 0; i--) {
    try {
      const value = JSON.parse(fences[i][1]);
      if (value && typeof value === "object") { process.stdout.write(JSON.stringify(value)); return; }
    } catch {}
  }
  let best = null;
  for (let start = text.indexOf("{"); start >= 0; start = text.indexOf("{", start + 1)) {
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === "\"") inString = false;
        continue;
      }
      if (ch === "\"") inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          try {
            const value = JSON.parse(text.slice(start, i + 1));
            if (value && typeof value === "object") best = value;
          } catch {}
          break;
        }
      }
    }
  }
  if (best) process.stdout.write(JSON.stringify(best));
});
'
}


# run_zcode_json <cwd> <identity> <timeout_minutes> <schema_file> <prompt_file>
# -- the pipeline's one zcode runner for structured JSON-verdict calls (the
# cross-provider review). zcode has no schema-enforced output mode, so the
# JSON contract rides in the prompt itself (the same approach the web advisor
# takes) and the final message is parsed here: a reply without exactly one
# valid object fails CLOSED as is_error, exactly like a codex exec failure,
# so every downstream consumer sees the same {is_error, structured_output}
# envelope. Invocation shape reuses the hand-agent dispatch
# (engine/night/dispatch.sh): prompt through -p, --cwd, --mode yolo,
# NODE_USE_ENV_PROXY=1 for proxied egress. Model and effort come from the
# policy-resolved review identity; nothing here names a model.
run_zcode_json() {
  local cwd="$1" identity="$2" timeout_minutes="$3" schema_file="$4" prompt_file="$5"
  local zcode_id model effort status=0 started_at elapsed timeout_detail out_file transcript reply verdict_json
  model_policy_require_role_identity review "$identity" || {
    jq -nc '{is_error: true, subtype: "unsupported_model_identity", result: "identity does not match the review role"}'
    return 64
  }
  zcode_id="${identity#zcode:}"
  if [[ "$zcode_id" != *:* ]]; then
    jq -nc --arg identity "$identity" '{is_error: true, subtype: "unsupported_model_identity", result: ("zcode identity needs model:effort: " + $identity)}'
    return 64
  fi
  model="${zcode_id%:*}"
  effort="${zcode_id#*:}"
  out_file="$(mktemp)"
  transcript="$(mktemp)"
  # The schema rides in the prompt (fenced, like web_advisor_provider_build_
  # question) because zcode enforces nothing itself.
  {
    echo 'You are this pipeline'"'"'s independent cross-provider reviewer. Reply with EXACTLY one fenced code block, language "json", containing a single JSON object that validates against the JSON Schema given below -- no text before or after that one code block, no other commentary.'
    echo
    echo 'JSON Schema:'
    echo '```json'
    cat "$schema_file"
    echo '```'
    echo
    cat "$prompt_file"
  } > "$transcript"
  started_at="$(date +%s)"
  NODE_USE_ENV_PROXY=1 timeout "${timeout_minutes}m" zcode -p "$(cat "$transcript")" \
    --cwd "$cwd" --mode yolo > "$out_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ "$status" -eq 124 ]; then
    timeout_detail="zcode review timed out after $((timeout_minutes * 60))m (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$out_file"
    echo "$timeout_detail" >&2
  fi
  reply="$(cat "$out_file" 2>/dev/null || true)"
  verdict_json="$(zcode_extract_json_object "$reply")"
  if [ "$status" -eq 0 ] && [ -n "$verdict_json" ] \
    && jq -e 'type == "object" and (.verdict | type) == "string" and (.verdict | IN("READY", "NOT_READY", "INPUT_INCOMPLETE")) and (.report_md | type) == "string"' \
      <<< "$verdict_json" >/dev/null 2>&1; then
    jq -nc --argjson so "$verdict_json" '{is_error: false, structured_output: $so, tokens_used: ""}'
  else
    result_text="$(tail -c 2000 "$out_file" 2>/dev/null)"
    jq -nc --arg result "$result_text" --arg status "$status" --arg elapsed "$elapsed" \
      '{is_error: true, subtype: "zcode_exec_failure", result: $result, zcode_exit_status: ($status|tonumber), zcode_elapsed_seconds: ($elapsed|tonumber)}'
    [ "$status" -ne 0 ] || status=1
  fi
  rm -f "$out_file" "$transcript"
  return "$status"
}


# #1457 dispatch seam for the batch call. Identity selection stays outside
# this helper; it only routes an already-selected provider prefix and refuses
# anything that is not the web advisor transport this batch contract needs.
run_model_advisor_batch_async() {
  local identity="$1" job_id="$2" prompt_file="$3"
  [ "$identity" = "$(model_policy identity advisor)" ] || {
    echo "run_model_advisor_batch_async: identity is not the configured advisor role" >&2
    return 64
  }
  case "$identity" in
    web:*) web_advisor_provider_dispatch_ndjson_async "$job_id" "$prompt_file" ;;
    *)
      echo "run_model_advisor_batch_async: unsupported provider identity '$identity' for batch advisor" >&2
      return 64
      ;;
  esac
}


# run_codex_text <cwd> <model> <effort> <timeout_minutes> <prompt_file>
# <transcript_file> -- same sandboxing as run_codex_json() above (--sandbox
# read-only, --cd, --skip-git-repo-check, --ephemeral), but WITHOUT
# --output-schema and without normalizing to {is_error, structured_output}:
# prints whatever `codex exec` wrote to --output-last-message, verbatim, on
# stdout, and returns codex's own exit status -- unconditionally, on
# success or failure. Combined stdout+stderr goes to <transcript_file>
# (caller-owned: create it, read it for diagnostics if stdout comes back
# empty, clean it up) rather than into a mktemp this function hides, since a
# caller here has nowhere else to route a real error otherwise -- there is
# no {is_error, result} envelope to carry it in.
#
# The one caller (run-advisor-batch.sh) asks the model for NDJSON, one JSON
# object per line, not a single document a schema could validate as a
# whole: --output-schema validates the ENTIRE response as one JSON value, so
# a response a model's own output-token budget cuts off partway would fail
# closed on everything, discarding rulings that were already complete
# before the cutoff -- exactly what that leg's own "never all-or-nothing"
# requirement exists to avoid at a size (dozens of structured rulings out)
# nothing calling run_codex_json() has ever carried. This function does no
# interpretation at all; the caller parses its own NDJSON line by line and
# decides what "failed" means for each line independently -- a complete
# line that happens to arrive after a status!=0 (codex hit its own timeout
# or was killed mid-stream, but had already flushed --output-last-message)
# is still a line worth trying to parse, so this always prints whatever the
# output file holds, never conditioned on `status`.
run_codex_text() {
  local cwd="$1" model="$2" effort="$3" timeout_minutes="$4" prompt_file="$5" transcript_file="$6" service_tier
  local -a service_tier_args=()
  local out_file status=0 started_at elapsed timeout_detail
  model_policy_require_implementer_identity "codex:$model:$effort" || return $?
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  out_file="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e` -- see run_codex_json()'s own
  # comment above for why: this function is always called from inside a
  # `$(...)` capture (its payload IS its stdout), which already shields the
  # caller's shell from this toggle regardless, but matching the sibling
  # function's idiom keeps the two functions safe to read the same way.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_minutes}m" codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$out_file" \
    - < "$prompt_file" > "$transcript_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  [ "$status" -eq 0 ] || printf 'codex-exec-elapsed-seconds=%s\n' "$elapsed" >> "$transcript_file"
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex exec timed out after $((timeout_minutes * 60))s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$transcript_file"
    echo "$timeout_detail" >&2
  fi
  if [ -s "$out_file" ]; then
    printf '\ncodex-final-output-present=true\n' >> "$transcript_file"
  else
    printf '\ncodex-final-output-present=false\n' >> "$transcript_file"
  fi
  cat "$out_file" 2>/dev/null
  rm -f "$out_file"
  return "$status"
}


# run_codex_implement <cwd> <model> <effort> <prompt_file> <log_file> -- runs
# `codex exec` for a FREEFORM code-editing task (the implement/repair role:
# read the brief, write files, run local commands, `git commit`), not a
# structured-JSON decision -- see run_codex_json() above for that shape.
# Runs with `--sandbox "$CODEX_SANDBOX_MODE" --cd <cwd>` (danger-full-access by default since 2026-10-06): Codex should write only
# under <cwd> (matches the model call implement call's own `--add-dir "$WT"`
# plus its cwd -- the one directory the model may write into).
#
# 2026-09-18 (issue #1347, containment follow-up): network access IS on for
# this call -- `-c sandbox_workspace_write.network_access=true` below -- so
# database-backed integration tests (loopback Postgres, testcontainers) can
# run. That grant used to live in ~/.codex/config.toml (global, every codex
# invocation on this box); it is scoped to just this one call site now, so
# the advisor leg, the guarded-review leg, and the maintainer's own interactive
# `codex` sessions stay network-denied by default. Confirmed live (no model
# call spent): `codex exec --strict-config -c
# sandbox_workspace_write.network_access=true` flips the startup banner from
# "sandbox: workspace-write [workdir, /tmp, $TMPDIR]" to "... (network
# access enabled)" with no grant in config.toml at all, so the per-invocation
# `-c` is sufficient on its own -- config.toml does not need the section
# back.
#
# Network denial used to BE this function's whole containment story (the
# comment this replaces said so). It no longer is: with the sandbox open,
# `env -u GH_TOKEN -u GITHUB_TOKEN` strips this pipeline's own GitHub
# credentials from just this child process before exec -- GH_TOKEN reaches
# this shell via the systemd unit's `EnvironmentFile=` (~/.zenoforge/env)
# and would otherwise be reachable from inside an unattended, now
# network-enabled Codex run. The wrapper (run-implement.sh) deliberately
# performs every `gh`/`git push` operation itself outside the sandbox, and
# the prompt text it builds for `codex:*` models says plainly that Codex
# cannot reach `gh` and should not try (see run-implement.sh's
# `case "$IMPLEMENT_MODEL" in codex:*)` block, in the `{ ... } >
# "$PROMPT_FILE"` section) -- that was never conditioned on the
# sandbox denying network, so stripping the credential here changes nothing
# the model is supposed to do, only what an off-script attempt could reach.
# Checked: the wrapper's own environment (systemd unit + ~/.zenoforge/env)
# never sets GH_ENTERPRISE_TOKEN or GITHUB_ENTERPRISE_TOKEN, so there is
# nothing enterprise-flavored to strip here today.
#
# `--sandbox workspace-write` otherwise still applies -- Codex may still
# only write under <cwd>, /tmp, and $TMPDIR, same as before. This is a
# Codex-CLI-enforced filesystem boundary, not a container/VM/restricted OS
# user. It does not create a separate control-surface admission rule.
#
# Combined stdout+stderr goes to <log_file> -- the same capture shape the
# model call implement/repair call sites already use (IMPLEMENT_LOG/
# REPAIR_LOG) -- and this returns codex's own exit status, the same
# contract those call sites already branch on ($STATUS -ne 0 ->
# fail_attempt()). No --output-schema here (there is no structured verdict
# to conform to for a code-writing pass); the caller's own downstream gates
# (git diff --check, run_package_gates, the independent code review) are
# what actually verify the result, exactly as they already do for a
# model call implement pass -- this function does not weaken or replace any
# of them.
run_codex_implement() {
  local cwd="$1" model="$2" effort="$3" prompt_file="$4" log_file="$5" timeout_minutes="${6:-120}" caller="${7:-unknown}" status=0 service_tier
  local -a service_tier_args=()
  local started_at elapsed timeout_detail out_file transcript_empty=true diagnostic signal_name issue stage model_identity
  MODEL_CALL_EXIT_STATUS=""
  MODEL_CALL_EXIT_CLASS=""
  MODEL_CALL_LOG_PATH="$log_file"
  MODEL_CALL_CALLER="$caller"
  MODEL_CALL_STAGE="${caller##*:}"
  MODEL_CALL_TERMINATION_SOURCE=""
  MODEL_CALL_TERMINATION_EVIDENCE=""
  MODEL_CALL_TRANSCRIPT_EMPTY=false
  model_policy_require_implementer_identity "codex:$model:$effort" || { printf 'run_codex_implement: model identity does not match the work role\n' > "$log_file"; return 64; }
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  out_file="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e` -- see run_codex_json()'s own
  # comment above for why: this function is always called as a bare
  # statement (it has no meaningful stdout to capture via command
  # substitution, unlike run_codex_json()), so an internal `set -e` toggle
  # here would leak directly into run-implement.sh's own shell the moment
  # this returns nonzero, killing the whole script before fail_attempt()
  # ever runs -- confirmed live while writing this function's own test in
  # lib.test.sh. `env -u GH_TOKEN -u GITHUB_TOKEN` sits between `timeout` and
  # `codex` (not around the whole pipeline) so it only strips those two vars
  # from codex's own child environment -- this function's caller, and this
  # shell, keep them.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_minutes}m" env -u GH_TOKEN -u GITHUB_TOKEN codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c sandbox_workspace_write.network_access=true \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$out_file" \
    - < "$prompt_file" > "$log_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ -s "$log_file" ] || [ -s "$out_file" ]; then transcript_empty=false; fi
  [ "$status" -eq 0 ] || printf 'codex-exec-elapsed-seconds=%s\n' "$elapsed" >> "$log_file"
  MODEL_CALL_EXIT_STATUS="$status"
  MODEL_CALL_EXIT_CLASS="$(model_call_exit_class "$status")"
  MODEL_CALL_TRANSCRIPT_EMPTY="$transcript_empty"
  issue="${N:-unknown}"
  stage="${caller##*:}"
  [ -n "$stage" ] || stage=unknown
  model_identity="codex:$model:$effort"
  if [ "$status" -eq 124 ]; then
    MODEL_CALL_TERMINATION_SOURCE=timeout_wrapper
    MODEL_CALL_TERMINATION_EVIDENCE="timeout returned exit 124 after ${elapsed}s"
  elif [ "$MODEL_CALL_EXIT_CLASS" = signal_termination ]; then
    signal_name="$(model_call_signal_name "$status")"
    model_call_capture_termination_source "$issue"
    MODEL_CALL_TERMINATION_EVIDENCE="signal=$signal_name; $MODEL_CALL_TERMINATION_EVIDENCE"
  else
    MODEL_CALL_TERMINATION_SOURCE=process_exit
    MODEL_CALL_TERMINATION_EVIDENCE="codex exec returned exit $status"
  fi
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex implement timed out after $((timeout_minutes * 60))s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$log_file"
    echo "$timeout_detail" >&2
  fi
  if [ "$status" -ne 0 ]; then
    signal_name=""
    if [ "$MODEL_CALL_EXIT_CLASS" = signal_termination ]; then
      signal_name=" signal=$(model_call_signal_name "$status")"
    fi
    diagnostic="model_call_exit_status=$status termination_class=$MODEL_CALL_EXIT_CLASS$signal_name issue=$issue stage=$stage caller=$caller provider=codex model=$model_identity timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) termination_source=$MODEL_CALL_TERMINATION_SOURCE termination_evidence=$MODEL_CALL_TERMINATION_EVIDENCE log_path=$log_file transcript_empty=$transcript_empty"
    printf '%s\n' "$diagnostic" >> "$log_file"
    printf '%s\n' "$diagnostic" >&2
  fi
  if [ -s "$out_file" ]; then
    printf '\ncodex-final-output-present=true\ncodex-final-message-begin\n' >> "$log_file"
    jq -Rrs 'if length > 4000 then .[-4000:] else . end' "$out_file" >> "$log_file"
    # Keep bounded check-block markers from the full final message after the
    # display tail, so the caller can route blocked runs before cleanup.
    awk '/^BLOCKED-CHECKS:[[:space:]]*[^[:space:]]/ && count < 10 { print substr($0, 1, 500); count++ }' "$out_file" >> "$log_file"
    printf '\n' >> "$log_file"
  else
    printf '\ncodex-final-output-present=false\n' >> "$log_file"
  fi
  rm -f "$out_file"
  return "$status"
}


# Provider dispatch ----------------------------------------------------------
run_model_json() {
  local cwd="$1" identity="$2" timeout_minutes="$3" schema_file="$4" prompt_file="$5" settings_file="$6" role="${7:-work}"
  local codex_id
  timeout_minutes="$(model_timeout_for_attempt "$timeout_minutes" "${N:-}")"
  model_policy_require_stage_identity "$role" "$identity" || {
    jq -nc --arg role "$role" '{is_error: true, subtype: "unsupported_model_identity", result: ("identity does not match the " + $role + " role")}'
    return 64
  }
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      if [[ "$codex_id" != *:* ]]; then
        jq -nc --arg identity "$identity" '{is_error: true, subtype: "unsupported_model_identity", result: ("codex identity needs model:effort: " + $identity)}'
        return 64
      fi
      ( CODEX_JSON_TIMEOUT_SECONDS=$((timeout_minutes * 60)) run_codex_json "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$schema_file" "$prompt_file" )
      ;;
    zcode:*)
      ( run_zcode_json "$cwd" "$identity" "$timeout_minutes" "$schema_file" "$prompt_file" )
      ;;
    web:*)
      ( WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS=$((timeout_minutes * 60)) run_web_advisor_provider_json "$schema_file" "$prompt_file" )
      ;;
    *)
      jq -nc '{is_error: true, subtype: "unsupported_model_provider", result: "provider is not allowed for this stage"}'
      return 64
      ;;
  esac
}


run_model_text() {
  local cwd="$1" identity="$2" timeout_minutes="$3" prompt_file="$4" transcript_file="$5" settings_file="$6"
  local codex_id
  model_policy_require_implementer_identity "$identity" || return $?
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      [[ "$codex_id" == *:* ]] || { echo "run_model_text: codex identity needs model:effort: $identity" >&2; return 64; }
      run_codex_text "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$timeout_minutes" "$prompt_file" "$transcript_file"
      ;;
    web:*)
      echo "run_model_text: web provider does not support raw text calls" >&2
      return 64
      ;;
    *) echo "run_model_text: unsupported provider identity" >&2; return 64 ;;
  esac
}


run_model_implement() {
  local cwd="$1" identity="$2" timeout_minutes="$3" prompt_file="$4" log_file="$5" settings_file="$6" caller="${7:-unknown}"
  local codex_id
  MODEL_CALL_EXIT_STATUS=""
  MODEL_CALL_EXIT_CLASS=""
  MODEL_CALL_LOG_PATH="$log_file"
  MODEL_CALL_CALLER="$caller"
  MODEL_CALL_STAGE="${caller##*:}"
  MODEL_CALL_TERMINATION_SOURCE=""
  MODEL_CALL_TERMINATION_EVIDENCE=""
  MODEL_CALL_TRANSCRIPT_EMPTY=false
  timeout_minutes="$(model_timeout_for_attempt "$timeout_minutes" "${N:-}")"
  if ! model_policy_require_implementer_identity "$identity"; then
    printf 'run_model_implement: model identity does not match the work role\n' > "$log_file"
    return 64
  fi
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      if [[ "$codex_id" != *:* ]]; then
        printf 'run_model_implement: codex identity needs model:effort: %s\n' "$identity" > "$log_file"
        return 64
      fi
      run_codex_implement "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$prompt_file" "$log_file" "$timeout_minutes" "$caller"
      ;;
    web:*)
      printf 'run_model_implement: web provider cannot perform workspace-write implementation\n' > "$log_file"
      return 64
      ;;
    *) printf 'run_model_implement: unsupported provider identity\n' > "$log_file"; return 64 ;;
  esac
}
