#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
config_root="$tmp/target/.zenoforge"
pack_dir="$tmp/pack"
mkdir -p "$config_root" "$pack_dir" "$tmp/agent-home"
touch "$tmp/agent-home/env"
export AGENT_HOME="$tmp/agent-home" ZF_NIGHT_DIR="$tmp/agent-home/night"
export TEST_ENV_HOME="$tmp/agent-home" TEST_DB_USER=fixture TEST_DB_NAME=fixture
export TEST_CREDENTIAL_WRAPPER="$tmp/credential-wrapper"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] || { printf 'not ok - %s\n' "$label" >&2; exit 1; }
  printf 'ok - %s\n' "$label"
}

cat > "$config_root/night.json" <<'JSON'
{
  "jobs": {"production_errors": {"enabled": true}},
  "production": {
    "ssh_hosts": {"production_errors": "target-host"},
    "container_names": {"production": ["target-service"], "shard_pattern": "target-*", "database": "target-db"},
    "database_user_env": "TEST_DB_USER",
    "database_name_env": "TEST_DB_NAME",
    "database_user": "target-user",
    "database_name": "target-name",
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
      "missing_trace_body": "Target trace guidance",
      "missing_trace_body_headings": {"service": "Target Service: ", "route": "Target Route: ", "first": "Target First: ", "evidence": "Target Evidence: "},
      "state_file_name": "target-state.json",
      "lock_file_name": "target-monitor.lock"
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
[[ "$PROD_ERRORS_STATE_FILE_NAME" == target-state.json ]]
[[ "$PROD_ERRORS_LOCK_FILE_NAME" == target-monitor.lock ]]
[[ "$PROD_ERRORS_MISSING_TRACE_HEADING_SERVICE" == 'Target Service: ' ]]
[[ "$(jq -r '.production.database_user' <<< "$PROD_ERRORS_REMOTE_CONFIG_JSON")" == target-user ]]
[[ "$(jq -r '.production.database_name' <<< "$PROD_ERRORS_REMOTE_CONFIG_JSON")" == target-name ]]

timeout() { shift; "$@"; } # the monitor wraps its reads in `timeout 20`, which cannot reach the gh stubs
calls="$tmp/writes"
gh() { printf 'gh %s\n' "$*" >> "$calls"; }
guarded_write() { printf 'write %s\n' "$*" >> "$calls"; }
REPO=example/repository
health_prod_errors_ensure_anomaly_label
grep -Fq 'target-anomaly' "$calls"
! grep -Fq 'pack-anomaly' "$calls"

NIGHT="$tmp/night" BOT_DISCLAIMER='Automated test'
mkdir -p "$NIGHT"
source "$script_dir/maintainer-health-mail.sh"
REPO=example/repository
inbox="$tmp/inbox"
issue_calls="$tmp/issues"
incident_mail_calls="$tmp/incident-mails"
outage_ack_calls="$tmp/outage-acks"
touch "$outage_ack_calls"
supervisor_inbox_append_once() { printf '%s\n' "$2" >> "$inbox"; }
health_prod_errors_upsert_issue() {
  printf '%s\t%s\n' "$1" "$2" >> "$issue_calls"
  if [[ -n "${3:-}" && -f "$3" ]]; then cp "$3" "$tmp/last-issue-body"; fi
  printf '%s\n' "${OUTAGE_FIXTURE_ISSUE:-}"
}
notify_maintainer_incident() {
  if [[ "${OUTAGE_MAIL_MODE:-success}" == safe-failure ]]; then
    NOTIFY_LAST_SEND_RETRY_SAFE=1
    return 1
  fi
  jq -cn --arg issue "$1" --arg subject "$2" --arg what "$3" --arg impact "$4" --arg action "$5" \
    --arg next "$6" '{issue:$issue,subject:$subject,what:$what,impact:$impact,action:$action,next:$next}' \
    >> "$incident_mail_calls"
}
prod_errors_ack_alert() { printf '%s\n' "$2" >> "$outage_ack_calls"; }
fixture_key="$(printf 'fixture-redaction-marker' | sha256sum | cut -c1-20)"
alert="$(jq -cn --arg key "$fixture_key" '{alerts:[{key:$key,event_id:"first-seen-1",source:"log",reason:"first-seen",container:"service",service:"service",count:1,first:"2026-10-12T02:13:14Z",route:"/items",sample_request_id:"",trace_id:"",deduplicated_lines:["route=GET /items status=500"]}]}')"
health_prod_errors_route "$alert" BROKEN '' "$tmp/state.json"
grep -Fq "target-signature sig=$fixture_key" "$issue_calls"
grep -Fq "Target anomaly $fixture_key" "$issue_calls"
grep -Fq 'route=/items request_id=none' "$inbox"
# The supervisor inbox alert kind follows the configured anomaly issue label.
grep -Fq "target-anomaly sig=$fixture_key container=service" "$inbox"
! grep -Fq 'production-anomaly sig=' "$inbox"

# (#1038) The router primes the anomaly label once per run in its own shell; the upsert handles issue reads.
# The issue list remains shared by alerts, and the router does not list issues itself.
PROD_ANOMALY_LABEL_READY=0
gh() { printf 'gh %s\n' "$*" >> "$calls"; } # sourcing the mail helper restored the real gh
: > "$calls"
two_alerts="$(jq -cn --arg a "$(printf 'one' | sha256sum | cut -c1-20)" --arg b "$(printf 'two' | sha256sum | cut -c1-20)" \
  '{alerts:[$a,$b] | map({key:.,event_id:("first-seen-" + .),source:"log",reason:"first-seen",container:"service",service:"service",count:1,first:"2026-10-12T02:13:14Z",route:"/items",sample_request_id:"",trace_id:"",deduplicated_lines:["route=GET /items status=500"]})}')"
health_prod_errors_route "$two_alerts" BROKEN '' "$tmp/state.json"
[[ "$(grep -c '^gh api --paginate repos/example/repository/labels?per_page=100' "$calls")" == 1 ]]
[[ -f "$NIGHT/target-monitor.lock" ]]
grep -Fq 'Target Service: service' "$tmp/last-issue-body"
grep -Fq 'Target Route: /items' "$tmp/last-issue-body"
grep -Fq 'Target First: 2026-10-12T02:13:14Z' "$tmp/last-issue-body"
grep -Fq 'Target Evidence: ' "$tmp/last-issue-body"
[[ ! -s "$incident_mail_calls" ]]

outage_issue="$(printf '%s' "$tmp/primary-services-down" | cksum | awk '{print 900000000 + ($1 % 99999999)}')"
export OUTAGE_FIXTURE_ISSUE="$outage_issue"
outage_key="$(printf 'primary-services-down' | sha256sum | cut -c1-20)"
outage_alert="$(jq -cn --arg key "$outage_key" '{production_down:true,alerts:[{
  key:$key,event_id:"production-down",source:"availability",reason:"production-down",
  container:"production",service:"production",count:1,first:"unknown",route:"",
  trace_id:"",sample_request_id:"",deduplicated_lines:["all primary services are stopped"]
}]}')"
OUTAGE_MAIL_MODE=safe-failure
if OUTAGE_MAIL_MODE="$OUTAGE_MAIL_MODE" health_prod_errors_route "$outage_alert" BROKEN 'production-down' "$tmp/state.json"; then
  echo 'not ok - a safely failed urgent mail was acknowledged' >&2
  exit 1
fi
assert_eq 'safe urgent-mail failure remains retryable in the shared ledger' 'failed-safe' \
  "$(jq -r --argjson issue "$outage_issue" '.incidents[] | select(.issue == $issue) | .initial_mail_status' \
    "$NIGHT/founder-health-mail.json")"
! grep -qx 'production-down' "$outage_ack_calls"
OUTAGE_MAIL_MODE=success
health_prod_errors_route "$outage_alert" BROKEN 'production-down' "$tmp/state.json"
assert_eq 'only the detected full production outage sends an immediate short mail' '1' \
  "$(wc -l < "$incident_mail_calls" | tr -d '[:space:]')"
assert_eq 'outage alert is recorded in the shared mail ledger' \
  "$outage_issue|sent|true" \
  "$(jq -r --argjson issue "$outage_issue" '.incidents[] | select(.issue == $issue) | [.issue,.initial_mail_status,.urgent] | join("|")' \
    "$NIGHT/founder-health-mail.json")"
assert_eq 'outage email stays in plain Chinese' '线上服务暂时无法使用|用户暂时无法正常使用服务。|工厂正在自动排查并恢复服务。' \
  "$(jq -r '[.subject,.impact,.action] | join("|")' "$incident_mail_calls")"
health_prod_errors_route "$outage_alert" BROKEN 'production-down' "$tmp/state.json"
assert_eq 'a repeated outage alert is deduplicated by the mail ledger' '1' \
  "$(wc -l < "$incident_mail_calls" | tr -d '[:space:]')"
grep -qx 'production-down' "$outage_ack_calls"
issue_count_before_recovery="$(wc -l < "$issue_calls" | tr -d '[:space:]')"
recovery_alert="$(jq -cn --arg key "$outage_key" '{production_down:false,production_up:true,alerts:[{
  key:$key,event_id:"production-recovered",source:"availability",reason:"production-recovered",
  container:"production",service:"production",count:1,first:"unknown",route:"",
  trace_id:"",sample_request_id:"",deduplicated_lines:["all primary services are running"]
}]}')"
health_prod_errors_route "$recovery_alert" OK 'production recovered' "$tmp/state.json"
assert_eq 'verified service recovery closes the production incident without a second immediate email' \
  'resolved|availability|queued' \
  "$(jq -r '.incidents[] | [.status,.resolution_kind,.resolution_mail_status] | join("|")' \
    "$NIGHT/founder-health-mail.json")"
assert_eq 'recovery does not create another issue' "$issue_count_before_recovery" \
  "$(wc -l < "$issue_calls" | tr -d '[:space:]')"
grep -qx 'production-recovered' "$outage_ack_calls"
assert_eq 'recovery does not send an immediate second mail' '1' \
  "$(wc -l < "$incident_mail_calls" | tr -d '[:space:]')"

wrapper_repo="$tmp/repo"
wrapper_root="$tmp/wrapper-config/.zenoforge"
mkdir -p "$wrapper_repo/ops" "$wrapper_root"
: > "$wrapper_repo/ops/with-credentials.sh"
chmod +x "$wrapper_repo/ops/with-credentials.sh"
jq '.credentials.wrapper_script = "ops/with-credentials.sh"' "$config_root/night.json" > "$wrapper_root/night.json"
resolved="$(unset TEST_CREDENTIAL_WRAPPER; ZF_CONFIG_ROOT="$wrapper_root" ZF_PACK_DIR='' ZF_REPO_DIR="$wrapper_repo" \
  bash -c 'source "$1/node-health-rules.sh" >/dev/null 2>&1; printf "%s\n" "$PROD_ERRORS_CREDENTIALS_WRAPPER"' _ "$script_dir")"
[[ "$resolved" == "$wrapper_repo/ops/with-credentials.sh" ]]
env_wins="$(ZF_CONFIG_ROOT="$wrapper_root" ZF_PACK_DIR='' ZF_REPO_DIR="$wrapper_repo" \
  bash -c 'source "$1/node-health-rules.sh" >/dev/null 2>&1; printf "%s\n" "$PROD_ERRORS_CREDENTIALS_WRAPPER"' _ "$script_dir")"
[[ "$env_wins" == "$TEST_CREDENTIAL_WRAPPER" ]]

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

# (b, #349) Missing-trace issues carry the filer's own label at creation in
# both roadmap and non-roadmap modes, instead of being filed label-less. The
# harness stub above replaced health_prod_errors_upsert_issue, so re-source
# the filer inside a subshell with recorder stubs for its collaborators.
missing_calls="$tmp/missing-trace-calls"
: >"$missing_calls"
missing_body="$tmp/missing-body"
printf 'Automated test\n<!-- target-missing-trace service=fixture -->\n' >"$missing_body"
run_missing_trace_create() { # roadmap-flag -> call the real upsert once
  local roadmap_mode="$1"
  (
    # `timeout 20 gh ...` must reach the stubs, not the host gh.
    timeout() { shift; "$@"; }
    roadmap_switch_value() { printf '%s\n' "$roadmap_mode"; }
    roadmap_tree_is_valid() { return 0; }
    issue_transition() { printf 'issue_transition %s %s %s\n' "$1" "$2" "$3" >>"$missing_calls"; }
    guarded_write() {
      printf 'guarded_write %s\n' "$*" >>"$missing_calls"
      if [[ "$1 $2 $3" == 'gh issue create' ]]; then
        printf 'https://github.com/example/repository/issues/7701\n'
      fi
    }
    gh() {
      printf 'gh %s\n' "$*" >>"$missing_calls"
      if [[ "$1 $2" == 'api --paginate' && "$3" == */issues\?* ]]; then printf '[]\n'; fi
      if [[ "$1 $2" == 'api -X' ]]; then printf '{"items":[]}\n'; fi
    }
    ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" source "$script_dir/node-health-rules.sh"
    if [[ "$roadmap_mode" == true ]]; then
      : >"$tmp/roadmap-tree.json"
      ZF_ROADMAP_TREE_CACHE_FILE="$tmp/roadmap-tree.json" \
        health_prod_errors_upsert_issue '<!-- target-missing-trace service=fixture' \
        'Target trace gap: service' "$missing_body" >/dev/null
    else
      health_prod_errors_upsert_issue '<!-- target-missing-trace service=fixture' \
        'Target trace gap: service' "$missing_body" >/dev/null
    fi
  )
}
run_missing_trace_create false
grep -Fq 'gh api --paginate repos/example/repository/labels?per_page=100' "$missing_calls"
grep -Fq 'gh label create target-anomaly' "$missing_calls"
grep -Eq 'gh issue create [^#]*--label needs-triage --label target-anomaly' "$missing_calls"
! grep -Fq 'issue_transition' "$missing_calls"

: >"$missing_calls"
run_missing_trace_create true
grep -Fq 'gh label create target-anomaly' "$missing_calls"
grep -Eq 'gh issue create [^#]*--label target-anomaly' "$missing_calls"
! grep -Eq 'gh issue create [^#]*--label needs-triage --label' "$missing_calls"
grep -Fq 'issue_transition 7701 needs-triage prod-anomaly-created' "$missing_calls"

# (#1038) REST reads: one issue list per run serves every alert, a rate limit skips the run, and a create never works
# from a stale list. gh is a stateful REST stub: `rest_state` holds the labelled issues the "server" has.
rest_state="$tmp/rest-issues.json" rest_calls="$tmp/rest-calls" rest_acks="$tmp/rest-acks"
run_rest_route() { # alerts-json -> real route and real upsert over the stub; GH_MODE=ok|rate-limit|issue-rate-limit|http-500
  (
    timeout() { shift; "$@"; }
    ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" source "$script_dir/node-health-rules.sh"
    roadmap_switch_value() { printf 'false\n'; }
    supervisor_inbox_append_once() { :; }
    prod_errors_ack_alert() { printf '%s\n' "$2" >>"$rest_acks"; }
    guarded_issue_comment() { printf 'comment %s\n' "$1" >>"$rest_calls"; }
    guarded_write() {
      printf 'write %s\n' "$*" >>"$rest_calls"
      if [[ "$1 $2" == 'gh issue' && "$3" == create ]]; then
        local title='' body_file='' n="$((RANDOM + 9000))"
        while (( $# )); do
          case "$1" in --title) title="$2"; shift ;; --body-file) body_file="$2"; shift ;; esac
          shift
        done
        jq --argjson n "$n" --arg t "$title" --rawfile b "$body_file" --arg now "$(date -u +%FT%TZ)" \
          '. + [{number:$n,title:$t,body:$b,state:"open",labels:[{name:"target-anomaly"}],created_at:$now}]' \
          "$rest_state" >"$rest_state.new" && mv -- "$rest_state.new" "$rest_state"
        printf 'https://github.com/example/repository/issues/%s\n' "$n"
      fi
    }
    gh() {
      printf 'gh %s\n' "$*" >>"$rest_calls"
      case "${GH_MODE:-ok}" in
        rate-limit) echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2; return 1 ;;
        issue-rate-limit)
          if [[ "$1 $2" == 'api --paginate' && "$3" == */issues\?* ]]; then
            echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
            return 1
          fi
          ;;
        http-500) echo 'gh: Server Error (HTTP 500)' >&2; return 1 ;;
      esac
      if [[ "$1 $2" == 'api --paginate' && "$3" == */labels\?* ]]; then echo target-anomaly
      elif [[ "$1 $2" == 'api --paginate' && "$3" == */issues\?* ]]; then cat -- "$rest_state"
      elif [[ "$1 $2" == 'api -X' ]]; then printf '{"items":%s}\n' "${SEARCH_ITEMS:-[]}"
      fi
    }
    health_prod_errors_route "$1" BROKEN '' "$tmp/state.json"
  )
}
rest_alerts() { # key... -> log alerts without trace, so each also files a missing-trace issue for service "service"
  printf '%s\n' "$@" | jq -Rcn '{alerts:[inputs | {key:.,event_id:("first-seen-" + .),source:"log",reason:"first-seen",container:"service",service:"service",count:1,first:"2026-10-12T02:13:14Z",route:"/items",sample_request_id:"",trace_id:"",deduplicated_lines:["route=GET /items status=500"]}]}'
}
rest_key_a="$(printf 'rest-a' | sha256sum | cut -c1-20)" rest_key_b="$(printf 'rest-b' | sha256sum | cut -c1-20)"
rest_two="$(rest_alerts "$rest_key_a" "$rest_key_b")"
rest_missing_marker="<!-- target-missing-trace service=$(printf 'service' | sha256sum | cut -c1-20) -->"
rest_issue() { jq -cn --argjson n "$1" --arg b "$2" '{number:$n,title:"t",body:$b,state:"open",labels:[{name:"target-anomaly"}],created_at:"2026-11-12T00:00:00Z"}'; }

# Both lookups of both alerts (signature and missing-trace) are answered by ONE REST issue list; the label is also
# listed once by the router's per-run prime, and nothing is created.
jq -cn --argjson a "$(rest_issue 11 "<!-- target-signature sig=$rest_key_a -->")" --argjson b "$(rest_issue 12 "<!-- target-signature sig=$rest_key_b -->")" \
  --argjson m "$(rest_issue 13 "$rest_missing_marker")" '[$a,$b,$m]' >"$rest_state"
: >"$rest_calls" : >"$rest_acks"
GH_MODE=ok run_rest_route "$rest_two" >"$tmp/rest-out"
assert_eq 'REST: one issue list serves both alerts and both lookups' 1 "$(grep -c '^gh api --paginate repos/example/repository/issues?labels=target-anomaly&state=all&per_page=100$' "$rest_calls")"
assert_eq 'REST: one label list, one issue list, and four comments' 6 "$(grep -c '^gh api \|^comment 1[123]$' "$rest_calls")"
assert_eq 'REST: label list is primed once' 1 "$(grep -c '^gh api --paginate repos/example/repository/labels?per_page=100' "$rest_calls")"
! grep -Eq '^gh (issue|label)|issue create|search/issues' "$rest_calls"
assert_eq 'REST: both events acked' 2 "$(wc -l <"$rest_acks")"

# An existing issue found only by title search (legacy, no label) is commented, never duplicated.
echo '[]' >"$rest_state"
: >"$rest_calls" : >"$rest_acks"
GH_MODE=ok SEARCH_ITEMS="[$(jq -cn --arg b "<!-- target-signature sig=$rest_key_a -->" '{number:21,title:"Target anomaly x",body:$b,state:"open",labels:[]}')]" \
  run_rest_route "$(rest_alerts "$rest_key_a")" >"$tmp/rest-out"
grep -Fxq 'comment 21' "$rest_calls"
! grep -Fq "sig=$rest_key_a" "$rest_state" # no second signature issue

# Nothing exists: each issue is created once. The second alert sees the first alert's missing-trace issue because the
# create dropped the cached list, so the service gets one missing-trace issue, not two.
echo '[]' >"$rest_state"
: >"$rest_calls" : >"$rest_acks"
GH_MODE=ok run_rest_route "$rest_two" >"$tmp/rest-out"
assert_eq 'REST: two signature issues and one missing-trace issue created' 3 "$(grep -c '^write gh issue create' "$rest_calls")"
assert_eq 'REST: one missing-trace issue for the service' 1 "$(jq --arg m "$rest_missing_marker" '[.[] | select(.body | contains($m))] | length' "$rest_state")"
[[ "$(grep -c '^gh api --paginate repos/example/repository/issues' "$rest_calls")" -ge 2 ]] # refetched after a create

# Rate limit on the label prime: "skipped: rate-limited", rc 0, no create or ack, and stop at the first read.
echo '[]' >"$rest_state"
: >"$rest_calls" : >"$rest_acks"
rc=0
GH_MODE=rate-limit run_rest_route "$rest_two" >"$tmp/rest-out" 2>"$tmp/rest-err" || rc=$?
assert_eq 'REST: rate limit exits 0' 0 "$rc"
grep -Fxq 'skipped: rate-limited' "$tmp/rest-out"
! grep -Fq 'issue create' "$rest_calls"
[[ ! -s "$rest_acks" ]]
assert_eq 'REST: rate limit stops after one read' 1 "$(grep -c '^gh ' "$rest_calls")"

# Rate limit on the issue list is also skipped, with one label prime and one issue read.
: >"$rest_calls" : >"$rest_acks"
rc=0
GH_MODE=issue-rate-limit run_rest_route "$rest_two" >"$tmp/rest-out" 2>"$tmp/rest-err" || rc=$?
assert_eq 'REST issue-list rate limit exits 0' 0 "$rc"
grep -Fxq 'skipped: rate-limited' "$tmp/rest-out"
! grep -Fq 'issue create' "$rest_calls"
[[ ! -s "$rest_acks" ]]
assert_eq 'REST: issue-list rate limit stops after the failed list' 1 "$(grep -c '^gh api --paginate repos/example/repository/issues?' "$rest_calls")"
assert_eq 'REST: label prime and issue-list rate limit use two reads' 2 "$(grep -c '^gh api ' "$rest_calls")"

# Any other read error still fails the run and creates nothing.
: >"$rest_calls" : >"$rest_acks"
rc=0
GH_MODE=http-500 run_rest_route "$rest_two" >"$tmp/rest-out" 2>"$tmp/rest-err" || rc=$?
assert_eq 'REST: other read error exits 1' 1 "$rc"
! grep -Fq 'skipped' "$tmp/rest-out"
! grep -Fq 'issue create' "$rest_calls"
[[ ! -s "$rest_acks" ]]

echo 'ok - production monitor uses .zenoforge overrides and skips when unset'
