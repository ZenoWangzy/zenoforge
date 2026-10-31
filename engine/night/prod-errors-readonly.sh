#!/usr/bin/env bash
# Read bounded container, trace and request-experience evidence for configured services.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
night_config=""
night_config_tmp=""
if [[ -n "${ZF_NIGHT_CONFIG_JSON:-}" ]]; then
  night_config_tmp="$(mktemp)" || exit 1
  printf '%s\n' "$ZF_NIGHT_CONFIG_JSON" > "$night_config_tmp"
  night_config="$night_config_tmp"
  trap 'rm -f -- "$night_config_tmp"' EXIT
else
  source "$script_dir/../config.sh"
  night_config="$(zf_config_file night.json || true)"
fi
if [[ -z "$night_config" ]]; then
  echo 'skip: night log monitor has no night.json configuration'
  exit 0
fi
if ! jq -e 'type == "object"' "$night_config" >/dev/null 2>&1; then
  echo 'FAIL: night.json must contain a JSON object' >&2
  exit 2
fi
if ! jq -e '
  (.production.container_names.production | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  and (.production.container_names.shard_pattern | type == "string" and length > 0)
  and (.production.container_names.database | type == "string" and length > 0)
  and (.production.database_user_env | type == "string" and length > 0)
  and (.production.database_name_env | type == "string" and length > 0)
  and (.production.log_sources.trace_table | type == "string" and length > 0)
  and (.production.log_sources.ux_span | type == "string" and length > 0)
  and (.production.log_sources.ux_channel | type == "string" and length > 0)
  and (.anomaly_rules.production_logs.window | type == "string" and length > 0)
  and (.anomaly_rules.production_logs.base_log_line_cap | type == "number")
  and (.anomaly_rules.production_logs.shard_log_line_cap | type == "number")
  and (.anomaly_rules.production_logs.trace_limit | type == "number")
  and (.anomaly_rules.production_logs.ux_limit | type == "number")
  and (.anomaly_rules.production_logs.stuck_after_seconds | type == "number")
  and (.anomaly_rules.production_logs.log_line_error_pattern | type == "string" and length > 0)
  and (.anomaly_rules.production_logs.http_error_pattern | type == "string" and length > 0)
  and (.anomaly_rules.production_logs.stack_trace_pattern | type == "string" and length > 0)
' "$night_config" >/dev/null 2>&1; then
  echo 'skip: night log monitor needs container, log-source and anomaly-rule values in night.json'
  exit 0
fi

mapfile -t production_names < <(jq -r '.production.container_names.production[]' "$night_config")
shard_pattern="$(jq -r '.production.container_names.shard_pattern' "$night_config")"
database_container="$(jq -r '.production.container_names.database' "$night_config")"
database_user_env="$(jq -r '.production.database_user_env' "$night_config")"
database_name_env="$(jq -r '.production.database_name_env' "$night_config")"
trace_table="$(jq -r '.production.log_sources.trace_table' "$night_config")"
ux_span="$(jq -r '.production.log_sources.ux_span' "$night_config")"
ux_channel="$(jq -r '.production.log_sources.ux_channel' "$night_config")"
window="$(jq -r '.anomaly_rules.production_logs.window' "$night_config")"
base_cap="$(jq -r '.anomaly_rules.production_logs.base_log_line_cap' "$night_config")"
shard_cap="$(jq -r '.anomaly_rules.production_logs.shard_log_line_cap' "$night_config")"
trace_limit="$(jq -r '.anomaly_rules.production_logs.trace_limit' "$night_config")"
ux_limit="$(jq -r '.anomaly_rules.production_logs.ux_limit' "$night_config")"
stuck_after_seconds="$(jq -r '.anomaly_rules.production_logs.stuck_after_seconds' "$night_config")"
log_line_error_pattern="$(jq -r '.anomaly_rules.production_logs.log_line_error_pattern' "$night_config")"
http_error_pattern="$(jq -r '.anomaly_rules.production_logs.http_error_pattern' "$night_config")"
stack_trace_pattern="$(jq -r '.anomaly_rules.production_logs.stack_trace_pattern' "$night_config")"
if [[ ! "$window" =~ ^[1-9][0-9]*m$ || ! "$base_cap" =~ ^[1-9][0-9]*$ || ! "$shard_cap" =~ ^[1-9][0-9]*$ \
  || ! "$trace_limit" =~ ^[1-9][0-9]*$ || ! "$ux_limit" =~ ^[1-9][0-9]*$ \
  || ! "$stuck_after_seconds" =~ ^[1-9][0-9]*$ || ! "$database_container" =~ ^[A-Za-z0-9_.-]+$ \
  || ! "$database_user_env" =~ ^[A-Z_][A-Z0-9_]*$ || ! "$database_name_env" =~ ^[A-Z_][A-Z0-9_]*$ \
  || ! "$trace_table" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ || ! "$ux_span" =~ ^[A-Za-z0-9_.:-]+$ \
  || ! "$ux_channel" =~ ^[A-Za-z0-9_.:-]+$ || ! "$shard_pattern" =~ ^[A-Za-z0-9_.?*-]+$ \
  || "$log_line_error_pattern$http_error_pattern$stack_trace_pattern" == *$'\n'* ]]; then
  echo 'FAIL: invalid night log monitor configuration' >&2
  exit 2
fi
database_user="$(printenv "$database_user_env" || true)"
database_name="$(printenv "$database_name_env" || true)"
if [[ -z "$database_user" || -z "$database_name" ]]; then
  missing_env=()
  [[ -n "$database_user" ]] || missing_env+=("$database_user_env")
  [[ -n "$database_name" ]] || missing_env+=("$database_name_env")
  printf 'skip: night log monitor host environment is missing %s\n' "${missing_env[*]}"
  exit 0
fi

if ! inventory="$(timeout 3 docker ps -a --format '{{.ID}}|{{.Names}}')"; then
  printf '__PROD_ERRORS_READ_FAILED__\n'
  exit 1
fi
is_production_container() {
  local name="${1#/}" configured
  for configured in "${production_names[@]}"; do
    [[ "$name" == "$configured" ]] && return 0
  done
  [[ "$name" == $shard_pattern ]]
}

containers=()
ids=()
shards=()
while IFS='|' read -r id name extra; do
  [[ -z "$id$name$extra" ]] && continue
  [[ -z "$extra" && "$id" =~ ^[a-f0-9]{12,64}$ && "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    printf '__PROD_ERRORS_READ_FAILED__\n'
    exit 1
  }
  if is_production_container "$name"; then
    ids+=("$id")
    containers+=("$name")
    if [[ "${name#/}" == $shard_pattern ]]; then shards+=(1); else shards+=(0); fi
  fi
done <<< "$inventory"
printf '__PROD_ERRORS_OK__\n'

if ((${#ids[@]})); then
  if states="$(timeout 4 docker inspect --format '{{.Name}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.State.FinishedAt}}|{{.State.Running}}' "${ids[@]}" 2>/dev/null)" \
    && [[ -n "$states" ]]; then
    while IFS= read -r state; do
      [[ -n "$state" ]] || continue
      IFS='|' read -r name restarts oom exit_code finished running <<< "$state"
      printf '__CONTAINER_STATE__\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name#/}" "$restarts" "$oom" "$exit_code" "$finished" "$running"
    done <<< "$states"
  else
    printf '__CONTAINER_STATE_READ_FAILED__\n'
  fi
fi

trace_sql="COPY (SELECT jsonb_build_object(
  'trace_id',trace_id,'service',service,'event',event,'status',status,'started_at',started_at,
  'route',COALESCE(metadata_json->>'http.route',metadata_json->>'route',metadata_json->>'path',''),
  'container',COALESCE(metadata_json->>'container_name',metadata_json->>'container',''),
  'request_id',COALESCE(metadata_json->>'request_id',''))::text
  FROM $trace_table
  WHERE started_at >= now() - interval '$window'
    AND (lower(COALESCE(event::text,'')) LIKE '%error%' OR lower(COALESCE(event::text,'')) LIKE '%fail%'
      OR lower(COALESCE(status::text,'')) IN ('error','failed') OR error_hash IS NOT NULL)
  ORDER BY started_at DESC LIMIT $trace_limit) TO STDOUT"
trace_rows="$(timeout 4 docker exec -i "$database_container" psql -U "$database_user" \
  -d "$database_name" -At -c "$trace_sql" 2>/dev/null)" || {
  printf '__TRACE_READ_FAILED__\n'
  trace_rows=""
}
while IFS= read -r trace_row; do
  [[ -n "$trace_row" ]] && printf '__TRACE__\t%s\n' "$trace_row"
done <<< "$trace_rows"

ux_sql="COPY (SELECT jsonb_build_object(
  'trace_id',trace_id,'started_at',min(started_at),
  'first_visible_ms',max((metadata_json->>'first_visible_progress_ms')::numeric),
  'silent_gap_ms',max((metadata_json->>'max_silent_gap_ms')::numeric),
  'errored',bool_or(event = 'span_failed' OR lower(COALESCE(status::text,'')) IN ('error','failed')
    OR metadata_json->>'failure_code' IS NOT NULL),
  'stuck',(NOT bool_or(event IN ('span_completed','span_failed') OR lower(COALESCE(status::text,'')) IN ('error','failed')
    OR metadata_json->>'failure_code' IS NOT NULL) AND min(started_at) < now() - interval '$stuck_after_seconds seconds'))::text
  FROM $trace_table
  WHERE span = '$ux_span' AND channel = '$ux_channel' AND started_at >= now() - interval '$window'
  GROUP BY trace_id ORDER BY min(started_at) DESC LIMIT $ux_limit) TO STDOUT"
ux_rows="$(timeout 4 docker exec -i "$database_container" psql -U "$database_user" \
  -d "$database_name" -At -c "$ux_sql" 2>/dev/null)" || {
  printf '__UX_READ_FAILED__\n'
  ux_rows=""
}
while IFS= read -r ux_row; do
  [[ -n "$ux_row" ]] && printf '__UX__\t%s\n' "$ux_row"
done <<< "$ux_rows"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
export PROD_ERRORS_TMP_DIR="$tmp_dir" PROD_ERRORS_WINDOW="$window"
export PROD_ERRORS_BASE_CAP="$base_cap" PROD_ERRORS_SHARD_CAP="$shard_cap"
export PROD_ERRORS_LOG_ERROR_PATTERN="$log_line_error_pattern" PROD_ERRORS_HTTP_ERROR_PATTERN="$http_error_pattern"
export PROD_ERRORS_STACK_TRACE_PATTERN="$stack_trace_pattern"
export PROD_ERRORS_CONTAINER_NAMES="$(printf '%s\n' "${containers[@]}")"
export PROD_ERRORS_SHARDS="$(printf '%s\n' "${shards[@]}")"

prod_errors_read_one() {
  set -euo pipefail
  local index="$1" name="$2" is_shard="$3" cap="$PROD_ERRORS_BASE_CAP" output raw_output
  output="$PROD_ERRORS_TMP_DIR/$index"
  raw_output="$PROD_ERRORS_TMP_DIR/$index.raw"
  [[ "$is_shard" == 1 ]] && cap="$PROD_ERRORS_SHARD_CAP"
  if timeout 5 docker logs --timestamps --since "$PROD_ERRORS_WINDOW" --tail "$cap" "$name" > "$raw_output" 2>&1; then
    if ! awk -v container="$name" -v cap="$cap" -v log_error_pattern="$PROD_ERRORS_LOG_ERROR_PATTERN" \
        -v http_error_pattern="$PROD_ERRORS_HTTP_ERROR_PATTERN" -v stack_trace_pattern="$PROD_ERRORS_STACK_TRACE_PATTERN" '
        { count++;
          upper=toupper($0);
          if (upper ~ log_error_pattern || $0 ~ http_error_pattern || $0 ~ stack_trace_pattern)
            print container "\t" $0;
        }
        END { if (count >= cap) print "__PROD_ERRORS_TRUNCATED__\t" container; }
      ' "$raw_output" > "$output"; then
      printf '__PROD_ERRORS_READ_FAILED__\t%s\n' "$name" >> "$output"
    fi
  else
    printf '__PROD_ERRORS_READ_FAILED__\t%s\n' "$name" > "$output"
  fi
}
export -f prod_errors_read_one

for ((i = 0; i < ${#containers[@]}; i++)); do
  printf '%s\0%s\0%s\0' "$i" "${containers[i]}" "${shards[i]}"
done | xargs -0 -r -n 3 -P 32 bash -c 'prod_errors_read_one "$@"' _

for ((i = 0; i < ${#containers[@]}; i++)); do
  [[ -f "$tmp_dir/$i" ]] && cat -- "$tmp_dir/$i"
done
