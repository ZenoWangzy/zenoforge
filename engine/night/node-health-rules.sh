#!/usr/bin/env bash
PROD_ERRORS_RULES_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$PROD_ERRORS_RULES_DIR/../config.sh"
PROD_ERRORS_CONFIG_FILE="$(zf_config_file night.json || true)"
PROD_ERRORS_CONFIG_JSON=""
PROD_ERRORS_REMOTE_CONFIG_JSON=""
PROD_ERRORS_WINDOW=""
PROD_ERRORS_MIN_REQUESTS=""
PROD_ERRORS_NON_2XX_PERCENT=""
PROD_ERRORS_SSH_TIMEOUT_SECONDS=""
PROD_ERRORS_REMOTE_TIMEOUT_SECONDS=""
PROD_ERRORS_BASE_LOG_LINE_CAP=""
PROD_ERRORS_SHARD_LOG_LINE_CAP=""
PROD_ERRORS_STATE_FILE_NAME="production-errors-seen-signatures.json"
PROD_ERRORS_LOCK_FILE_NAME="production-errors-monitor.lock"
PROD_ERRORS_CREDENTIALS_WRAPPER=""
PROD_ERRORS_CREDENTIALS_ENV=""
PROD_ERRORS_SSH_HOST=""
PROD_ERRORS_REMOTE_ROOT=""
PROD_ERRORS_TRACE_SCRIPT_PATH=""
PROD_ERRORS_ISSUE_LABEL="production-anomaly"
PROD_ERRORS_ISSUE_LABEL_COLOR="ededed"
PROD_ERRORS_ISSUE_LABEL_DESCRIPTION="Production anomaly"
PROD_ERRORS_SIGNATURE_MARKER_PREFIX="<!-- production-anomaly sig="
PROD_ERRORS_ROLLUP_TITLE="Production anomaly summary"
PROD_ERRORS_ROLLUP_MARKER="<!-- production-anomaly rollup -->"
PROD_ERRORS_ROLLUP_BODY="Several production anomalies were grouped into this issue."
PROD_ERRORS_ISSUE_TITLE_PREFIX="Production anomaly "
PROD_ERRORS_MISSING_TRACE_TITLE_PREFIX="Production error has no trace: "
PROD_ERRORS_MISSING_TRACE_MARKER_PREFIX="<!-- production-missing-trace service="
PROD_ERRORS_MISSING_TRACE_BODY="An error log had no trace or request identifier."
PROD_ERRORS_MISSING_TRACE_HEADING_SERVICE="Service: "
PROD_ERRORS_MISSING_TRACE_HEADING_ROUTE="Route: "
PROD_ERRORS_MISSING_TRACE_HEADING_FIRST="First: "
PROD_ERRORS_MISSING_TRACE_HEADING_EVIDENCE="Evidence: "
PROD_ERRORS_ROLLUP_THRESHOLD=5
PROD_ERRORS_ROLLUP_WINDOW_SECONDS=3600
PROD_ANOMALY_LABEL_READY=0

prod_errors_config_ready() {
  [[ -n "$PROD_ERRORS_CONFIG_FILE" ]] && jq -e '
    (.jobs.production_errors.enabled == true)
    and (.production.ssh_hosts.production_errors | type == "string" and length > 0)
    and (.production.container_names.production | type == "array" and length > 0)
    and (.credentials.wrapper_env_name | type == "string" and length > 0)
    and (.credentials.environment_home_env_name | type == "string" and length > 0)
    and (.credentials.environment_file_name | type == "string" and length > 0)
    and (.anomaly_rules.production_logs.window | type == "string" and length > 0)
    and (.anomaly_rules.production_logs.min_requests | type == "number")
    and (.anomaly_rules.production_logs.non_2xx_percent | type == "number")
    and (.anomaly_rules.production_logs.base_log_line_cap | type == "number")
    and (.anomaly_rules.production_logs.shard_log_line_cap | type == "number")
    and (.anomaly_rules.production_logs.ssh_timeout_seconds | type == "number")
    and (.anomaly_rules.production_logs.remote_timeout_seconds | type == "number")
    and ((.anomaly_rules.production_logs.state_file_name // "production-errors-seen-signatures.json")
      | (type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
    and ((.anomaly_rules.production_logs.lock_file_name // "production-errors-monitor.lock")
      | (type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
  ' "$PROD_ERRORS_CONFIG_FILE" >/dev/null 2>&1
}

prod_errors_load_config() {
  prod_errors_config_ready || return 1
  PROD_ERRORS_CONFIG_JSON="$(cat -- "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_REMOTE_CONFIG_JSON="$(jq -c '{
    production: {
      container_names: {production: .production.container_names.production,
        shard_pattern: .production.container_names.shard_pattern,
        database: .production.container_names.database},
      database_user_env: .production.database_user_env,
      database_name_env: .production.database_name_env,
      database_user: .production.database_user,
      database_name: .production.database_name,
      log_sources: {trace_table: .production.log_sources.trace_table,
        ux_span: .production.log_sources.ux_span, ux_channel: .production.log_sources.ux_channel}
    },
    anomaly_rules: {production_logs: (.anomaly_rules.production_logs | {
      window, base_log_line_cap, shard_log_line_cap, trace_limit, ux_limit,
      stuck_after_seconds, log_line_error_pattern, http_error_pattern, stack_trace_pattern
    })}
  }' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_WINDOW="$(jq -r '.anomaly_rules.production_logs.window' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MIN_REQUESTS="$(jq -r '.anomaly_rules.production_logs.min_requests' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_NON_2XX_PERCENT="$(jq -r '.anomaly_rules.production_logs.non_2xx_percent' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_SSH_TIMEOUT_SECONDS="$(jq -r '.anomaly_rules.production_logs.ssh_timeout_seconds' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_REMOTE_TIMEOUT_SECONDS="$(jq -r '.anomaly_rules.production_logs.remote_timeout_seconds' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_BASE_LOG_LINE_CAP="$(jq -r '.anomaly_rules.production_logs.base_log_line_cap' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_SHARD_LOG_LINE_CAP="$(jq -r '.anomaly_rules.production_logs.shard_log_line_cap' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_SSH_HOST="$(jq -r '.production.ssh_hosts.production_errors' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_REMOTE_ROOT="$(jq -r '.production.remote_root // empty' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_TRACE_SCRIPT_PATH="$(jq -r '.production.log_sources.trace_diagnose_script // empty' "$PROD_ERRORS_CONFIG_FILE")"
  local wrapper_env_name environment_home_env_name environment_file_name environment_home wrapper_script
  wrapper_env_name="$(jq -r '.credentials.wrapper_env_name' "$PROD_ERRORS_CONFIG_FILE")"
  environment_home_env_name="$(jq -r '.credentials.environment_home_env_name' "$PROD_ERRORS_CONFIG_FILE")"
  environment_file_name="$(jq -r '.credentials.environment_file_name' "$PROD_ERRORS_CONFIG_FILE")"
  environment_home="$(printenv "$environment_home_env_name" || true)"
  PROD_ERRORS_CREDENTIALS_WRAPPER="${PROD_ERRORS_CREDENTIALS_WRAPPER:-$(printenv "$wrapper_env_name" || true)}"
  # A deployment whose wrapper is a repo script (credentials.wrapper_script, relative to
  # ZF_REPO_DIR) needs no environment export; the env name still wins when both exist.
  if [[ -z "$PROD_ERRORS_CREDENTIALS_WRAPPER" ]]; then
    wrapper_script="$(jq -r '.credentials.wrapper_script // empty' "$PROD_ERRORS_CONFIG_FILE")"
    if [[ "$wrapper_script" =~ ^[A-Za-z0-9._/-]+$ && "$wrapper_script" != /* && "$wrapper_script" != */../* && "$wrapper_script" != ../* && "$wrapper_script" != */.. && "$wrapper_script" != ./* && "$wrapper_script" != . ]]; then
      PROD_ERRORS_CREDENTIALS_WRAPPER="$ZF_REPO_DIR/$wrapper_script"
    fi
  fi
  PROD_ERRORS_CREDENTIALS_ENV="${PROD_ERRORS_CREDENTIALS_ENV:-${environment_home%/}/$environment_file_name}"
  PROD_ERRORS_ISSUE_LABEL="$(jq -r '.anomaly_rules.production_logs.issue_label // "production-anomaly"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ISSUE_LABEL_COLOR="$(jq -r '.anomaly_rules.production_logs.issue_label_color // "ededed"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ISSUE_LABEL_DESCRIPTION="$(jq -r '.anomaly_rules.production_logs.issue_label_description // "Production anomaly"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_SIGNATURE_MARKER_PREFIX="$(jq -r '.anomaly_rules.production_logs.signature_marker_prefix // "<!-- production-anomaly sig="' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ROLLUP_TITLE="$(jq -r '.anomaly_rules.production_logs.rollup_title // "Production anomaly summary"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ROLLUP_MARKER="$(jq -r '.anomaly_rules.production_logs.rollup_marker // "<!-- production-anomaly rollup -->"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ROLLUP_BODY="$(jq -r '.anomaly_rules.production_logs.rollup_body // "Several production anomalies were grouped into this issue."' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ISSUE_TITLE_PREFIX="$(jq -r '.anomaly_rules.production_logs.issue_title_prefix // "Production anomaly "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_TITLE_PREFIX="$(jq -r '.anomaly_rules.production_logs.missing_trace_title_prefix // "Production error has no trace: "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_MARKER_PREFIX="$(jq -r '.anomaly_rules.production_logs.missing_trace_marker_prefix // "<!-- production-missing-trace service="' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_BODY="$(jq -r '.anomaly_rules.production_logs.missing_trace_body // "An error log had no trace or request identifier."' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_STATE_FILE_NAME="$(jq -r '.anomaly_rules.production_logs.state_file_name // "production-errors-seen-signatures.json"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_LOCK_FILE_NAME="$(jq -r '.anomaly_rules.production_logs.lock_file_name // "production-errors-monitor.lock"' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_HEADING_SERVICE="$(jq -r '.anomaly_rules.production_logs.missing_trace_body_headings.service // "Service: "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_HEADING_ROUTE="$(jq -r '.anomaly_rules.production_logs.missing_trace_body_headings.route // "Route: "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_HEADING_FIRST="$(jq -r '.anomaly_rules.production_logs.missing_trace_body_headings.first // "First: "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_MISSING_TRACE_HEADING_EVIDENCE="$(jq -r '.anomaly_rules.production_logs.missing_trace_body_headings.evidence // "Evidence: "' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ROLLUP_THRESHOLD="$(jq -r '.anomaly_rules.production_logs.rollup_threshold // 5' "$PROD_ERRORS_CONFIG_FILE")"
  PROD_ERRORS_ROLLUP_WINDOW_SECONDS="$(jq -r '.anomaly_rules.production_logs.rollup_window_seconds // 3600' "$PROD_ERRORS_CONFIG_FILE")"
}

prod_errors_load_config >/dev/null 2>&1 || true

prod_errors_probe() {
  local state_file="$1" raw stderr_file started=$SECONDS read_status
  prod_errors_load_config || {
    printf '{"verdict":"UNKNOWN","detail":"production monitor is not configured","alerts":[],"new_signatures":[]}\n'
    return 0
  }
  [[ -x "$PROD_ERRORS_CREDENTIALS_WRAPPER" && -r "$PROD_ERRORS_CREDENTIALS_ENV" ]] || {
    printf '{"verdict":"UNKNOWN","detail":"production monitor host environment is unavailable","alerts":[],"new_signatures":[]}\n'
    return 0
  }
  stderr_file="$(mktemp)" || return 1
  if raw="$(bash "$PROD_ERRORS_CREDENTIALS_WRAPPER" --env "$PROD_ERRORS_CREDENTIALS_ENV" -- \
    timeout "$PROD_ERRORS_SSH_TIMEOUT_SECONDS" ssh -o BatchMode=yes -o ConnectTimeout=4 "$PROD_ERRORS_SSH_HOST" \
    "timeout $PROD_ERRORS_REMOTE_TIMEOUT_SECONDS bash -s" \
    < <(
      printf 'ZF_NIGHT_CONFIG_JSON=%q\nexport ZF_NIGHT_CONFIG_JSON\n' "$PROD_ERRORS_REMOTE_CONFIG_JSON"
      cat "$PROD_ERRORS_RULES_DIR/prod-errors-readonly.sh"
    ) 2>"$stderr_file")"; then
    :
  else
    read_status=$?
    raw="$(printf '__PROD_ERRORS_READ_FAILED__\nexit=%s duration=%ss\n' "$read_status" "$((SECONDS-started))"; head -c 2048 "$stderr_file"; printf '\n%s' "$raw")"
  fi
  rm -f -- "$stderr_file"
  python3 "$PROD_ERRORS_RULES_DIR/prod-errors-assess.py" --config "$PROD_ERRORS_CONFIG_FILE" "$state_file" \
    "$PROD_ERRORS_WINDOW" "$PROD_ERRORS_MIN_REQUESTS" "$PROD_ERRORS_NON_2XX_PERCENT" <<< "$raw" \
    || printf '{"verdict":"UNKNOWN","detail":"production log assessment failed","new_signatures":[]}\n'
}

prod_errors_trace_diagnose() {
  local trace_id="$1"
  [[ "$trace_id" =~ ^[a-fA-F0-9]{32}$ ]] || return 64
  prod_errors_load_config || return 64
  [[ -n "$PROD_ERRORS_REMOTE_ROOT" && -n "$PROD_ERRORS_TRACE_SCRIPT_PATH" ]] || return 64
  local trace_script="$ZF_REPO_DIR/$PROD_ERRORS_TRACE_SCRIPT_PATH"
  [[ -r "$trace_script" ]] || return 64
  bash "$PROD_ERRORS_CREDENTIALS_WRAPPER" --env "$PROD_ERRORS_CREDENTIALS_ENV" -- \
    timeout "$PROD_ERRORS_SSH_TIMEOUT_SECONDS" ssh -o BatchMode=yes -o ConnectTimeout=4 "$PROD_ERRORS_SSH_HOST" \
    "cd '$PROD_ERRORS_REMOTE_ROOT' && TRACE_DIAGNOSE_ROOT='$PROD_ERRORS_REMOTE_ROOT' TRACE_SINCE='$PROD_ERRORS_WINDOW' timeout $PROD_ERRORS_REMOTE_TIMEOUT_SECONDS bash -s -- $trace_id" \
    < "$trace_script" 2>/dev/null
}

prod_errors_trace_summary() {
  python3 -c '
import re, sys
allowed = {"trace_id", "source", "path_type", "trace_scope", "completeness_level", "completeness_status", "tooling_applicability", "summary_status", "observed_duration_ms", "error_events", "present_spans", "expected_spans", "missing_expected_spans", "missing_optional_spans", "matched_events"}
safe_value = re.compile(r"^[A-Za-z0-9._,;:=>*() -]{1,512}$")
for raw in sys.stdin:
    key, sep, value = raw.strip().partition(":")
    value = value.strip()
    if sep and key in allowed and safe_value.fullmatch(value):
        print(f"{key}: {value}")
'
}

prod_errors_ack_alert() {
  local state_file="$1" event_id="$2"
  python3 "$PROD_ERRORS_RULES_DIR/prod-errors-assess.py" --ack "$state_file" "$event_id"
}

health_prod_errors_write_evidence() {
  local alert="$1" path="$2" trace_output="${3:-}" tmp
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  {
    printf '# Production anomaly\n\n'
    printf -- '- Signature: `%s`\n' "$(jq -r '.key' <<< "$alert")"
    printf -- '- Kind: `%s`\n' "$(jq -r '.reason' <<< "$alert")"
    printf -- '- Container: `%s`\n' "$(jq -r '.container' <<< "$alert")"
    printf -- '- Service: `%s`\n' "$(jq -r '.service' <<< "$alert")"
    printf -- '- Count: `%s`\n' "$(jq -r '.count' <<< "$alert")"
    printf -- '- First: `%s`\n' "$(jq -r '.first' <<< "$alert")"
    printf -- '- Route: `%s`\n' "$(jq -r 'if .route == "" then "unknown" else .route end' <<< "$alert")"
    printf -- '- Request ID: `%s`\n' "$(jq -r 'if .sample_request_id == "" then "none" else .sample_request_id // "none" end' <<< "$alert")"
    printf -- '- Trace: `%s`\n\n' "$(jq -r 'if .trace_id == "" then "none" else .trace_id end' <<< "$alert")"
    printf '## Deduplicated log lines\n\n'
    jq -r '.deduplicated_lines[]? | "- `" + . + "`"' <<< "$alert"
    if [[ -n "$trace_output" ]]; then
      printf '\n## Trace diagnosis\n\n%s\n' "$trace_output"
    elif [[ "$(jq -r '.trace_id // ""' <<< "$alert")" =~ ^[a-fA-F0-9]{32}$ ]]; then
      printf '\n## Trace diagnosis\n\nNot available from bounded trace-diagnose read.\n'
    else
      printf '\n## Trace diagnosis\n\nNo matching trace_id.\n'
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f -- "$tmp" "$path"
}

health_prod_errors_ensure_anomaly_label() {
  local existing
  [[ "${PROD_ANOMALY_LABEL_READY:-0}" == 1 ]] && return 0
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
  if ! grep -qx -- "$PROD_ERRORS_ISSUE_LABEL" <<< "$existing"; then
    if ! guarded_write gh label create "$PROD_ERRORS_ISSUE_LABEL" --repo "$REPO" --color "$PROD_ERRORS_ISSUE_LABEL_COLOR" \
        --description "$PROD_ERRORS_ISSUE_LABEL_DESCRIPTION" >/dev/null; then
      existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
      grep -qx -- "$PROD_ERRORS_ISSUE_LABEL" <<< "$existing" || return 1
    fi
  fi
  PROD_ANOMALY_LABEL_READY=1
}

health_prod_errors_create_anomaly_issue() {
  local title="$1" body_file="$2" issue_url issue issue_json
  if [[ "$(roadmap_switch_value)" == true ]]; then
    health_prod_errors_ensure_roadmap_cache || return 1
    issue_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" \
      --label "$PROD_ERRORS_ISSUE_LABEL" --body-file "$body_file")" || return 1
    issue="${issue_url##*/}"
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
    issue_json="$(jq -cn --argjson number "$issue" --arg title "$title" --rawfile body "$body_file" \
      --arg label "$PROD_ERRORS_ISSUE_LABEL" \
      '{number:$number,title:$title,body:$body,state:"OPEN",labels:[{name:$label}]}')" || return 1
    issue_transition "$issue" needs-triage prod-anomaly-created . 0 "$issue_json" >/dev/null || return 1
    printf '%s\n' "$issue"
    return 0
  fi
  issue_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" \
    --label needs-triage --label "$PROD_ERRORS_ISSUE_LABEL" --body-file "$body_file")" || return 1
  issue="${issue_url##*/}"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$issue"
}

health_prod_errors_rollup_issue() {
  local issues="$1" evidence_file="$2" rollup body rollup_body_file
  rollup="$(jq -r --arg title "$PROD_ERRORS_ROLLUP_TITLE" '[.[] | select(.title == $title and ((.state // "") | ascii_downcase) == "open")][0].number // empty' <<< "$issues")" || return 1
  if [[ -z "$rollup" ]]; then
    rollup_body_file="$(mktemp "$NIGHT/prod-anomalies/.rollup-body.XXXXXX")" || return 1
    printf '%s\n%s\n\n%s\n' "$BOT_DISCLAIMER" "$PROD_ERRORS_ROLLUP_MARKER" "$PROD_ERRORS_ROLLUP_BODY" \
      > "$rollup_body_file" || { rm -f -- "$rollup_body_file"; return 1; }
    rollup="$(health_prod_errors_create_anomaly_issue "$PROD_ERRORS_ROLLUP_TITLE" "$rollup_body_file")" || {
      rm -f -- "$rollup_body_file"
      return 1
    }
    rm -f -- "$rollup_body_file"
  fi
  body="$(cat -- "$evidence_file")" || return 1
  guarded_issue_comment "$rollup" "$body" >/dev/null
}

health_prod_errors_upsert_issue() {
  local marker="$1" title="$2" body_file="$3"
  local anomaly=0 results lookup_results issue state issue_json issue_url legacy_results recent_count
  if [[ "$marker" == "$PROD_ERRORS_SIGNATURE_MARKER_PREFIX"* ]]; then
    anomaly=1
    health_prod_errors_ensure_anomaly_label || return 1
    results="$(timeout 20 gh issue list --repo "$REPO" --label "$PROD_ERRORS_ISSUE_LABEL" --state all --limit 1000 \
      --json number,title,body,state,labels,createdAt)" || return 1
  else
    results="$(timeout 20 gh issue list --repo "$REPO" --state all --limit 1000 \
      --search "in:title $title" --json number,title,body,state,labels)" || return 1
  fi
  jq -e 'type == "array"' <<< "$results" >/dev/null || return 1
  lookup_results="$results"
  issue="$(jq -r --arg marker "$marker" '[.[] | select((.body // "") | contains($marker))][0].number // empty' <<< "$results")"
  if [[ -z "$issue" && "$anomaly" == 1 ]]; then
    legacy_results="$(timeout 20 gh issue list --repo "$REPO" --state all --limit 1000 \
      --search "in:title $title" --json number,title,body,state,labels)" || return 1
    jq -e 'type == "array"' <<< "$legacy_results" >/dev/null || return 1
    issue="$(jq -r --arg marker "$marker" '[.[] | select((.body // "") | contains($marker))][0].number // empty' <<< "$legacy_results")"
    [[ -z "$issue" ]] || lookup_results="$legacy_results"
  fi
  if [[ -z "$issue" && "$anomaly" == 1 ]]; then
    recent_count="$(jq -r --arg marker_prefix "$PROD_ERRORS_SIGNATURE_MARKER_PREFIX" \
      --argjson window_seconds "$PROD_ERRORS_ROLLUP_WINDOW_SECONDS" '
      [.[] | select((.body // "") | contains($marker_prefix))] as $signatures
      | if any($signatures[]; (.createdAt | type) != "string") then error("signature issue missing createdAt")
        else [$signatures[] | select((.createdAt | fromdateiso8601) >= (now - $window_seconds))] | length
        end
    ' <<< "$results")" || return 1
    [[ "$recent_count" =~ ^[0-9]+$ ]] || return 1
    if (( recent_count >= PROD_ERRORS_ROLLUP_THRESHOLD )); then
      health_prod_errors_rollup_issue "$results" "$body_file"
      return $?
    fi
    issue_url="$(health_prod_errors_create_anomaly_issue "$title" "$body_file")" || return 1
    [[ "$issue_url" =~ ^[1-9][0-9]*$ ]] || return 1
    return 0
  fi
  if [[ -z "$issue" ]]; then
    if [[ "$(roadmap_switch_value)" == true ]]; then
      health_prod_errors_ensure_roadmap_cache || return 1
      issue_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --body-file "$body_file")" || return 1
      issue="${issue_url##*/}"
      [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
      issue_json="$(jq -cn --argjson number "$issue" --arg title "$title" --rawfile body "$body_file" \
        '{number:$number,title:$title,body:$body,state:"OPEN",labels:[]}')" || return 1
      issue_transition "$issue" needs-triage prod-anomaly-created . 0 "$issue_json"
      return $?
    fi
    guarded_write gh issue create --repo "$REPO" --title "$title" --label needs-triage --body-file "$body_file" >/dev/null
    return $?
  fi
  issue_json="$(jq -c --argjson issue "$issue" '[.[] | select(.number == $issue)][0]' <<< "$lookup_results")" || return 1
  state="$(jq -r --argjson issue "$issue" '[.[] | select(.number == $issue)][0].state // "" | ascii_downcase' <<< "$lookup_results")"
  if [[ "$state" == closed ]]; then
    [[ "$(roadmap_switch_value)" != true ]] || health_prod_errors_ensure_roadmap_cache || return 1
    issue_transition "$issue" needs-triage prod-anomaly-recurred . 0 "$issue_json" "" open || return 1
  fi
  guarded_issue_comment "$issue" "$(cat -- "$body_file")" >/dev/null || return 1
}

health_prod_errors_ensure_roadmap_cache() {
  local cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}"
  [[ "$(roadmap_switch_value)" == true ]] || return 0
  [[ -n "$cache_file" && -r "$cache_file" ]] && roadmap_tree_is_valid "$(cat -- "$cache_file")" && return 0
  [[ "${ROADMAP_TREE_READ_ATTEMPTED:-0}" != 1 ]] || return 1
  ROADMAP_TREE_READ_ATTEMPTED=1
  ZF_OPEN_ISSUES_CACHE_FILE="${ZF_OPEN_ISSUES_CACHE_FILE:-$NIGHT/.open-issues-production-anomaly-$(date -u +%Y%m%dT%H%M%SZ)-$$.json}"
  ZF_ROADMAP_TREE_CACHE_FILE="$(roadmap_cache_path "$ZF_OPEN_ISSUES_CACHE_FILE")"
  export ZF_OPEN_ISSUES_CACHE_FILE ZF_ROADMAP_TREE_CACHE_FILE
  roadmap_fetch_tree "$ZF_ROADMAP_TREE_CACHE_FILE" "$REPO" || {
    rm -f -- "$ZF_ROADMAP_TREE_CACHE_FILE" "$ZF_ROADMAP_TREE_CACHE_FILE.linked"
    return 1
  }
}

health_prod_errors_route() {
  local result="$1" verdict="$2" detail="$3" state_file="$4" failed=0 event_failed
  local alert key event_id container count first trace_id request_id service route evidence body_file marker title trace_output
  local anomaly_dir="$NIGHT/prod-anomalies"
  local -A inbox_ok=()
  mkdir -p -- "$anomaly_dir" || return 1
  while IFS= read -r alert; do
    [[ -n "$alert" ]] || continue
    key="$(jq -r '.key // empty' <<< "$alert")"
    [[ "$key" =~ ^[a-f0-9]{20}$ ]] || { failed=1; continue; }
    event_id="$(jq -r '.event_id // .reason // "first-seen"' <<< "$alert" | tr -cd 'A-Za-z0-9._:-')"
    container="$(jq -r '.container // "unknown"' <<< "$alert" | tr -cd 'A-Za-z0-9_.:-<>')"
    count="$(jq -r '.count // 1' <<< "$alert")"
    first="$(jq -r '.first // "unknown"' <<< "$alert" | tr -cd 'A-Za-z0-9T:+.-')"
    trace_id="$(jq -r '.trace_id // ""' <<< "$alert")"
    request_id="$(jq -r '.sample_request_id // ""' <<< "$alert" | tr -cd 'A-Za-z0-9._:-' | cut -c1-128)"
    service="$(jq -r '.service // .container // "unknown"' <<< "$alert" | tr -cd 'A-Za-z0-9_.:-<>')"
    route="$(jq -r '.route // "unknown"' <<< "$alert" | tr -d '\r\n\t' | cut -c1-120)"
    evidence="$anomaly_dir/$key.md"
    if ! health_prod_errors_write_evidence "$alert" "$evidence"; then failed=1; continue; fi
    if ! supervisor_inbox_append_once "$PROD_ERRORS_ISSUE_LABEL:$key:$event_id" \
      "$PROD_ERRORS_ISSUE_LABEL sig=$key container=$container count=$count first=$first route=${route:-unknown} request_id=${request_id:-none} trace=${trace_id:-none} evidence=$evidence"; then
      failed=1
    else
      inbox_ok["$event_id"]=1
    fi
  done < <(jq -c '.alerts[]?' <<< "$result")

  exec 8>"$NIGHT/prod-errors-issues.lock"
  flock -n 8 || return 0
  while IFS= read -r alert; do
    [[ -n "$alert" ]] || continue
    key="$(jq -r '.key // empty' <<< "$alert")"
    [[ "$key" =~ ^[a-f0-9]{20}$ ]] || continue
    event_id="$(jq -r '.event_id // .reason // "first-seen"' <<< "$alert" | tr -cd 'A-Za-z0-9._:-')"
    event_failed=0
    trace_id="$(jq -r '.trace_id // ""' <<< "$alert")"
    evidence="$anomaly_dir/$key.md"
    trace_output=""
    if [[ "$trace_id" =~ ^[a-fA-F0-9]{32}$ ]]; then
      trace_output="$(prod_errors_trace_diagnose "$trace_id" 2>/dev/null | prod_errors_trace_summary || true)"
    fi
    if ! health_prod_errors_write_evidence "$alert" "$evidence" "$trace_output"; then failed=1; continue; fi

    marker="$PROD_ERRORS_SIGNATURE_MARKER_PREFIX$key -->"
    title="$PROD_ERRORS_ISSUE_TITLE_PREFIX$key"
    body_file="$(mktemp "$anomaly_dir/.issue-body.XXXXXX")" || { failed=1; continue; }
    printf '%s\n%s\n\n' "$BOT_DISCLAIMER" "$marker" > "$body_file"
    cat -- "$evidence" >> "$body_file"
    if ! health_prod_errors_upsert_issue "$marker" "$title" "$body_file"; then failed=1; event_failed=1; fi
    rm -f -- "$body_file"

    if [[ "$(jq -r '.source // "log"' <<< "$alert")" == log && -z "$trace_id" && -z "$request_id" ]]; then
      local service_hash missing_marker missing_title missing_body
      service_hash="$(printf '%s' "$service" | sha256sum | cut -c1-20)"
      missing_marker="$PROD_ERRORS_MISSING_TRACE_MARKER_PREFIX$service_hash -->"
      missing_title="$PROD_ERRORS_MISSING_TRACE_TITLE_PREFIX$service"
      missing_body="$(mktemp "$anomaly_dir/.missing-trace.XXXXXX")" || { failed=1; continue; }
      printf '%s\n%s\n\n%s\n\n%s%s\n%s%s\n%s%s\n%s%s\n' \
        "$BOT_DISCLAIMER" "$missing_marker" "$PROD_ERRORS_MISSING_TRACE_BODY" \
        "$PROD_ERRORS_MISSING_TRACE_HEADING_SERVICE" "$service" \
        "$PROD_ERRORS_MISSING_TRACE_HEADING_ROUTE" "$route" \
        "$PROD_ERRORS_MISSING_TRACE_HEADING_FIRST" "$first" \
        "$PROD_ERRORS_MISSING_TRACE_HEADING_EVIDENCE" "$evidence" > "$missing_body"
      if ! health_prod_errors_upsert_issue "$missing_marker" "$missing_title" "$missing_body"; then failed=1; event_failed=1; fi
      rm -f -- "$missing_body"
    fi
    if [[ "$event_failed" == 0 && "${inbox_ok[$event_id]:-}" == 1 ]]; then
      # Same lock file as the node-health monitor run: an ack must not interleave with a fresh probe writing state.
      exec 7>"$NIGHT/$PROD_ERRORS_LOCK_FILE_NAME"
      if flock -n 7; then
        prod_errors_ack_alert "$state_file" "$event_id" || failed=1
        flock -u 7
      else
        failed=1
      fi
      exec 7>&-
    fi
  done < <(jq -c '.alerts[]?' <<< "$result")
  flock -u 8
  exec 8>&-
  [ "$failed" -eq 0 ] || return 1
}
