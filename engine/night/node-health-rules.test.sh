#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
config_root="$tmp/target/.zenoforge"
pack_dir="$tmp/pack"
mkdir -p "$config_root" "$pack_dir" "$tmp/agent-home"
touch "$tmp/agent-home/env"
export TEST_ENV_HOME="$tmp/agent-home" TEST_DB_USER=fixture TEST_DB_NAME=fixture
export TEST_CREDENTIAL_WRAPPER="$tmp/credential-wrapper"

cat > "$config_root/night.json" <<'JSON'
{
  "jobs": {"production_errors": {"enabled": true}},
  "production": {
    "ssh_hosts": {"production_errors": "target-host"},
    "container_names": {"production": ["target-service"], "shard_pattern": "target-*", "database": "target-db"},
    "database_user_env": "TEST_DB_USER",
    "database_name_env": "TEST_DB_NAME",
    "remote_root": "/srv/target",
    "log_sources": {
      "trace_table": "public.target_traces",
      "ux_span": "target.span",
      "ux_channel": "target-channel",
      "trace_diagnose_script": "ops/trace-diagnose.sh"
    }
  },
  "credentials": {
    "wrapper_env_name": "TEST_CREDENTIAL_WRAPPER",
    "environment_home_env_name": "TEST_ENV_HOME",
    "environment_file_name": "env"
  },
  "anomaly_rules": {
    "production_logs": {
      "window": "10m",
      "min_requests": 10,
      "non_2xx_percent": 20,
      "ssh_timeout_seconds": 15,
      "remote_timeout_seconds": 12,
      "base_log_line_cap": 20000,
      "shard_log_line_cap": 5000,
      "trace_limit": 1000,
      "ux_limit": 500,
      "stuck_after_seconds": 420,
      "log_line_error_pattern": "ERROR|FATAL|CRITICAL|TRACEBACK|EXCEPTION",
      "http_error_pattern": "(^|[^0-9])5[0-9][0-9]([^0-9]|$)",
      "stack_trace_pattern": "(^|[[:space:]])at .+:[0-9]+",
      "issue_label": "target-anomaly",
      "issue_label_color": "abcdef",
      "issue_label_description": "Target anomaly label",
      "signature_marker_prefix": "<!-- target-signature sig=",
      "issue_title_prefix": "Target anomaly ",
      "rollup_title": "Target anomaly summary",
      "rollup_marker": "<!-- target-rollup -->",
      "rollup_body": "Target rollup body",
      "rollup_threshold": 5,
      "rollup_window_seconds": 3600,
      "missing_trace_marker_prefix": "<!-- target-missing-trace service=",
      "missing_trace_title_prefix": "Target trace gap: ",
      "missing_trace_body": "Target trace guidance"
    }
  }
}
JSON
jq '.production.ssh_hosts.production_errors = "pack-host"
  | .anomaly_rules.production_logs.issue_label = "pack-anomaly"
  | .anomaly_rules.production_logs.issue_title_prefix = "Pack anomaly "' \
  "$config_root/night.json" > "$pack_dir/night.json"

ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" source "$script_dir/node-health-rules.sh"
[[ "$PROD_ERRORS_SSH_HOST" == target-host ]]
[[ "$PROD_ERRORS_ISSUE_LABEL" == target-anomaly ]]

calls="$tmp/writes"
gh() { printf 'gh %s\n' "$*" >> "$calls"; }
guarded_write() { printf 'write %s\n' "$*" >> "$calls"; }
REPO=example/repository
health_prod_errors_ensure_anomaly_label
grep -Fq 'target-anomaly' "$calls"
! grep -Fq 'pack-anomaly' "$calls"

NIGHT="$tmp/night" BOT_DISCLAIMER='Automated test'
mkdir -p "$NIGHT"
inbox="$tmp/inbox"
issue_calls="$tmp/issues"
supervisor_inbox_append_once() { printf '%s\n' "$2" >> "$inbox"; }
health_prod_errors_upsert_issue() { printf '%s\t%s\n' "$1" "$2" >> "$issue_calls"; }
prod_errors_ack_alert() { return 0; }
fixture_key="$(printf 'fixture-redaction-marker' | sha256sum | cut -c1-20)"
alert="$(jq -cn --arg key "$fixture_key" '{alerts:[{key:$key,event_id:"first-seen-1",source:"log",reason:"first-seen",container:"service",service:"service",count:1,first:"2026-10-12T02:13:14Z",route:"/items",sample_request_id:"request-1",trace_id:"",deduplicated_lines:["route=GET /items status=500"]}]}')"
health_prod_errors_route "$alert" BROKEN '' "$tmp/state.json"
grep -Fq "target-signature sig=$fixture_key" "$issue_calls"
grep -Fq "Target anomaly $fixture_key" "$issue_calls"
grep -Fq 'route=/items request_id=request-1' "$inbox"

disabled_root="$tmp/disabled/.zenoforge"
mkdir -p "$disabled_root"
jq '.jobs.production_errors.enabled = false' "$config_root/night.json" > "$disabled_root/night.json"
set +e
skip_output="$(ZF_CONFIG_ROOT="$disabled_root" ZF_PACK_DIR="$pack_dir" bash "$script_dir/node-health.sh" --prod-anomaly-only 2>&1)"
skip_status=$?
set -e
[[ "$skip_status" == 0 ]]
grep -Fq 'skip: production anomaly monitor is not configured' <<< "$skip_output"

default_root="$tmp/empty/.zenoforge"
mkdir -p "$default_root"
skip_output="$(ZF_CONFIG_ROOT="$default_root" ZF_PACK_DIR='' bash "$script_dir/node-health.sh" --prod-anomaly-only 2>&1)"
grep -Fq 'skip: production anomaly monitor is not configured' <<< "$skip_output"

python3 "$script_dir/prod-errors-assess.test.py"
summary="$(printf '%s\n' \
  'trace_id: 0123456789abcdef0123456789abcdef' \
  'source: database' \
  'employee_id: sensitive-user-id' \
  'slowest_span: user prompt leak' \
  'path_type: generic-api' \
  'present_spans: server.request,service.operation' | prod_errors_trace_summary)"
grep -Fq 'trace_id: 0123456789abcdef0123456789abcdef' <<< "$summary"
grep -Fq 'path_type: generic-api' <<< "$summary"
! grep -Eq 'employee_id|slowest_span|sensitive-user-id|prompt leak' <<< "$summary"

echo 'ok - production monitor uses .zenoforge overrides and skips when unset'
