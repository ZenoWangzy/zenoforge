#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
bell="$script_dir/bell.sh"
fixtures="$script_dir/fixtures"
tmp="$(mktemp -d "$TMPDIR/advisor-incident.XXXXXX")"
legacy_bell=""
trap 'rm -rf -- "$tmp"; [[ -z "${legacy_bell:-}" ]] || rm -f -- "$legacy_bell"' EXIT
mkdir -p "$tmp/bin"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$2" == "$3" ]] || fail "$1 (expected '$3', got '$2')"; }

cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -C ]]; then shift 2; fi
[[ "$1" == ls-remote ]] && { printf '%s\trefs/heads/main\n' deadbeef; exit 0; }
exit 2
SH
cat > "$tmp/bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --foreground ]] && exit 0
while [[ "${1:-}" == -k || "${1:-}" == --kill-after ]]; do shift 2; done
[[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && shift
exec "$@"
SH
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == run && "$2" == view ]]; then
  shift 2
  run_id="$1"; shift
  case " $* " in
    *" --json jobs "*) cat "$BELL_TEST_CI_FIXTURE_DIR/jobs.json"; exit 0 ;;
    *" --log-failed "*) cat "$BELL_TEST_CI_FIXTURE_DIR/failed.log"; exit 0 ;;
  esac
fi
exit 2
SH
chmod +x "$tmp/bin/git" "$tmp/bin/timeout" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

new_case() {
  local name="$1"
  CASE="$tmp/$name"
  CASE_REPO="$CASE/repo"
  CASE_ENGINE="$CASE/engine-code"
  CASE_AGENT="$CASE/agent"
  CASE_AUTOPI="$CASE/autopi"
  CASE_JOBS="$CASE/jobs"
  CASE_CI="$CASE/ci"
  mkdir -p "$CASE_REPO/engine" "$CASE_ENGINE/lib.d" "$CASE_AGENT/logs" "$CASE_AUTOPI/alerts" \
    "$CASE_JOBS" "$CASE_CI" "$CASE/supervisor"
  cp "$repo_root/engine/lib.d/transport.sh" "$repo_root/engine/lib.d/ci-checks.sh" "$CASE_ENGINE/lib.d/"
  cat > "$CASE_ENGINE/pipeline-issue-upsert.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
class=""
while (($#)); do
  case "$1" in
    --class) class="$2"; shift 2 ;;
    --body-file) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$class" >> "$BELL_TEST_ISSUES"
cat "$body" >> "$BELL_TEST_BODIES"
SH
  chmod +x "$CASE_ENGINE/pipeline-issue-upsert.sh"
  printf '%s\n' '{"bell":{"enabled":true,"notify":false,"auto_supervisor":false,"dedup_minutes":30},"incident":{"file_min_severity":"medium"}}' > "$CASE_AUTOPI/config.json"
  printf 'window.DASH={};\n' > "$CASE_AUTOPI/dashboard.data.js"
  printf '[%s] tick done units=0 live=0 secs=1\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$CASE_AUTOPI/scheduler.log"
  printf '%s\n' '{"units":[]}' > "$CASE_AUTOPI/units.json"
  printf '%s\n' '{"workers":[]}' > "$CASE_AUTOPI/workers.json"
  jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[],incident_stats:{},incident_filing:{},scheduler_signature_seen:{},network_down:false,main_ci_runs_seen:{}}' \
    > "$CASE_AUTOPI/bell-state.json"
  : > "$CASE/issues.log"
  : > "$CASE/bodies.log"
  export MAC_AUTOPILOT_ROOT="$CASE_REPO" AGENT_HOME="$CASE_AGENT" ZF_HOME="$CASE_AGENT"
  export ZF_ENGINE_DIR="$CASE_ENGINE"
  export ZF_REPO=example-maintainer/example-repo ZF_GH_REPO=example-maintainer/example-repo
  export ZF_WEB_ADVISOR_PROVIDER_JOB_DIR="$CASE_JOBS"
  WEB_ADVISOR_PROVIDER_JOB_DIR="$CASE_JOBS"
  LOG_DIR="$CASE_AGENT/logs"
  export BELL_AUTOPI_DIR="$CASE_AUTOPI" BELL_SUPERVISOR_DIR="$CASE/supervisor"
  export BELL_TEST_ISSUES="$CASE/issues.log" BELL_TEST_BODIES="$CASE/bodies.log"
  export BELL_TEST_CI_FIXTURE_DIR="$CASE_CI" BELL_STALE_CI_DISABLE=1
}

result_file() {
  local name="$1" outcome="$2" job_id="$3" status="${4:-0}" at recorded stamp_pair
  stamp_pair="$(python3 - "${5:-0}" <<'PY'
from datetime import datetime, timezone, timedelta
import sys
stamp = datetime.now(timezone.utc) - timedelta(seconds=int(sys.argv[1]))
print(stamp.strftime('%Y%m%dT%H%M%SZ'), stamp.strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)"
  read -r at recorded <<< "$stamp_pair"
  jq -cn --arg tick "advisor-batch-$at" --arg outcome "$outcome" --arg job "$job_id" \
    --arg recorded "$recorded" \
    --argjson status "$status" \
    '{tick:$tick,recorded_at:$recorded,exit_code:$status,outcome:$outcome,job_id:(if $job=="" then null else $job end)}' \
    > "$AGENT_HOME/logs/advisor-batch-$at-$name.result.json"
}

run_bell() {
  BELL_TEST_NETWORK=green bash "${BELL_SCRIPT_OVERRIDE:-$bell}" >/dev/null 2>&1
}

if [[ "${1:-}" == --plant-old ]]; then
  new_case planted-old-bell
  mkdir -p "$CASE_JOBS/timeout"
  cp "$fixtures/advisor-timeout-prefixed.answer.err" "$CASE_JOBS/timeout/answer.err"
  result_file timeout job-failed timeout 1 20
  mkdir -p "$tmp/legacy-bell"
  cp "$script_dir/runtime-env.sh" "$tmp/legacy-bell/runtime-env.sh"
  legacy_bell="$tmp/legacy-bell/bell.sh"
  sed '/^advisor_incident_scan; main_ci_incident_scan/d' "$bell" > "$legacy_bell"
  chmod +x "$legacy_bell"
  BELL_SCRIPT_OVERRIDE="$legacy_bell" run_bell
  if grep -Fxq 'advisor-error-advisor-answer-timeout' "$CASE/issues.log"; then
    printf '%s\n' 'not ok - planted pre-fix bell unexpectedly filed the timeout incident' >&2
    exit 1
  fi
  printf '%s\n' 'not ok - planted pre-fix bell misses ADVISOR_ANSWER_TIMEOUT' >&2
  exit 1
fi

set +e
bash "$0" --plant-old > "$tmp/planted-old.out" 2>&1
planted_old_status=$?
set -e
assert_eq 'planted pre-fix bell reproduces the missing timeout incident' "$planted_old_status" 1
grep -Fxq 'not ok - planted pre-fix bell misses ADVISOR_ANSWER_TIMEOUT' "$tmp/planted-old.out" \
  || fail 'planted pre-fix bell did not reproduce the expected missed incident'
printf '%s\n' 'ok - planted pre-fix bell misses a real timeout marker'

# The provider retains observed diagnostic codes and reduces the picker fallback to a safe class.
eval "$(sed -n '/^web_advisor_provider_model_fallback_signature() {/,/^}/p' "$repo_root/engine/providers/web-advisor-provider.sh")"
eval "$(sed -n '/^web_advisor_provider_model_fallback() {/,/^}/p' "$repo_root/engine/providers/web-advisor-provider.sh")"
eval "$(sed -n '/^web_advisor_provider_model_fallback_signature_from_log() {/,/^}/p' "$repo_root/engine/providers/web-advisor-provider.sh")"
eval "$(sed -n '/^web_advisor_provider_error_codes() {/,/^}/p' "$repo_root/engine/providers/web-advisor-provider.sh")"
assert_eq 'timeout fixture preserves its real diagnostic code' \
  "$(web_advisor_provider_error_codes "$fixtures/advisor-timeout-prefixed.answer.err" | jq -r '.[]')" 'ADVISOR_ANSWER_TIMEOUT'
assert_eq 'send fixture preserves its real diagnostic code' \
  "$(web_advisor_provider_error_codes "$fixtures/advisor-send-uncertain.answer.err" | jq -r '.[]')" 'ADVISOR_SEND_NOT_CONFIRMED'
assert_eq 'picker fallback class is stable and redacted' \
  "$(web_advisor_provider_model_fallback_signature 'model picker not found; using configured fallback')" 'picker-not-found'
printf '%s\n' 'model picker not found; continuing with configured fallback' > "$tmp/fallback.answer.err"
assert_eq 'raw picker failure is detected without exposing its line' \
  "$(web_advisor_provider_model_fallback_signature_from_log "$tmp/fallback.answer.err")" 'picker-not-found'

# A still-running provider may already have emitted a diagnostic marker; persist it before job cleanup.
new_case pending-diagnostic-capture
mkdir -p "$CASE_JOBS/pending-timeout"
cp "$fixtures/advisor-timeout-plain.answer.err" "$CASE_JOBS/pending-timeout/answer.err"
eval "$(sed -n '/^advisor_batch_capture_provider_diagnostics() {/,/^}/p' "$repo_root/engine/run-advisor-batch.sh")"
LOG_DIR="$AGENT_HOME/logs" ADVISOR_TICK_ID=advisor-batch-pending BATCH_JOB_ID=pending-timeout
WEB_ADVISOR_PROVIDER_JOB_DIR="$CASE_JOBS"
advisor_batch_capture_provider_diagnostics '{}'
assert_eq 'pending answer.err marker is persisted before provider cleanup' \
  "$(jq -r '.error_codes[0]' "$LOG_DIR/$ADVISOR_TICK_ID.advisor-diagnostics.json")" 'ADVISOR_ANSWER_TIMEOUT'
printf '%s\n' 'ok - pending answer.err diagnostics are persisted before cleanup'

# Three redacted examples retain the real answer.err code shapes and nothing from prompts or URLs.
new_case advisor-codes
for row in 'timeout-a advisor-timeout-prefixed.answer.err' 'timeout-b advisor-timeout-plain.answer.err' 'send advisor-send-uncertain.answer.err'; do
  read -r id fixture <<<"$row"
  mkdir -p "$CASE_JOBS/$id"
  cp "$fixtures/$fixture" "$CASE_JOBS/$id/answer.err"
  result_file "$id" completed "$id" 0 "$(( 180 - RANDOM % 100 ))"
done
mkdir -p "$CASE_JOBS/unverified"
printf '%s\n' 'ADVISOR_MODEL_UNVERIFIED: <synthetic diagnostic>' > "$CASE_JOBS/unverified/answer.err"
result_file unverified completed unverified 0 30
run_bell
assert_eq 'answer.err signatures file one incident per signature' "$(sort -u "$CASE/issues.log" | wc -l | tr -d ' ')" 3
grep -Fxq 'advisor-error-advisor-answer-timeout' "$CASE/issues.log" || fail 'timeout signature was not filed'
grep -Fxq 'advisor-error-advisor-send-not-confirmed' "$CASE/issues.log" || fail 'send confirmation signature was not filed'
grep -Fxq 'advisor-error-advisor-model-unverified' "$CASE/issues.log" || fail 'model verification signature was not filed'
if grep -Eiq 'https?://|prompt|customer|example\.com|#9[0-9]{4}' "$CASE/bodies.log"; then
  fail 'incident evidence copied prompt, URL, or customer-like text'
fi
printf 'ok - redacted answer.err fixtures file one incident per signature\n'

# Two failed jobs in a row file once. A lone failed job followed by a success does not.
new_case consecutive-failures
result_file fail-a job-failed fixture-fail-a 1 120
result_file fail-b job-failed fixture-fail-b 1 60
run_bell
assert_eq 'two consecutive advisor job failures file one incident' "$(wc -l < "$CASE/issues.log" | tr -d ' ')" 1
grep -Fxq 'advisor-batch-consecutive-failures' "$CASE/issues.log" || fail 'consecutive failure signature was not filed'
printf 'ok - two consecutive advisor failures file in one scan\n'

new_case isolated-failure
result_file fail-only job-failed fixture-fail-only 1 120
result_file recover completed fixture-recovered 0 60
run_bell
assert_eq 'isolated advisor failure followed by success files nothing' "$(wc -l < "$CASE/issues.log" | tr -d ' ')" 0
printf 'ok - isolated advisor failure followed by success stays quiet\n'

# The batch-result producer writes one safe fallback signal line that this scan consumes.
new_case fallback
mkdir -p "$AGENT_HOME/logs"
eval "$(sed -n '/^advisor_batch_capture_provider_diagnostics() {/,/^}/p' "$repo_root/engine/run-advisor-batch.sh")"
eval "$(sed -n '/^record_batch_result() {/,/^cleanup() {/p' "$repo_root/engine/run-advisor-batch.sh" | sed '$d')"
LOG_DIR="$AGENT_HOME/logs" ADVISOR_TICK_ID=advisor-batch-20261103T000000Z
advisor_batch_capture_provider_diagnostics '{"advisor_error_codes":[],"model_fallback_signature":"picker-not-found"}'
declare -A BATCH_SELECTION_GATES=()
CANDIDATE_ISSUES=(); BATCH_OUTCOME=completed; BATCH_JOB_ID=fixture-fallback; INCLUDED=0
record_batch_result 0 2> "$CASE/fallback.log"
grep -Fq 'ADVISOR_MODEL_FALLBACK picker-not-found' "$CASE/fallback.log" || fail 'fallback did not log its one-line signal'
run_bell
fallback_issue_count="$(wc -l < "$CASE/issues.log" | tr -d ' ')"
if [[ "$fallback_issue_count" != 1 ]]; then
  cat "$CASE/issues.log" >&2
  fail "logged model-picker fallback files one incident (expected '1', got '$fallback_issue_count')"
fi
grep -Fxq 'advisor-model-fallback-picker-not-found' "$CASE/issues.log" || fail 'fallback signature was not filed'
printf 'ok - picker fallback logs and files through the bell intake\n'

# A red post-merge main CI run is identified by workflow status, check name and first failing test.
new_case main-ci-red
cp "$fixtures/main-ci-red-jobs.json" "$CASE_CI/jobs.json"
cp "$fixtures/main-ci-red-failed.log" "$CASE_CI/failed.log"
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq --arg now "$now" '.workflow_runs[0].created_at=$now' "$fixtures/main-ci-red-runs.json" > "$CASE_AUTOPI/main-runs.json"
jq -n --arg now "$now" --slurpfile red "$CASE_AUTOPI/main-runs.json" \
  '{schema:1,tick:$now,main_runs:{CI:[$red[0].workflow_runs[0] | {databaseId:.id,headSha:.head_sha,status,conclusion,createdAt:.created_at,attempt:.run_attempt}],"Pipeline suites":[]}}' \
  > "$CASE_AUTOPI/pr-run-snapshot.json"
run_bell
assert_eq 'red main CI run files exactly one incident' "$(wc -l < "$CASE/issues.log" | tr -d ' ')" 1
grep -Fq 'main-ci-engine-tests-isolated-regression-marker' "$CASE/issues.log" || fail 'red CI signature did not include check and first failing test'
grep -Fq 'commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$CASE/bodies.log" || fail 'red CI incident omitted commit'
grep -Fq 'check=Engine tests' "$CASE/bodies.log" || fail 'red CI incident omitted check name'
grep -Fq 'first_failure=isolated regression marker' "$CASE/bodies.log" || fail 'red CI incident did not preserve the first failing test'
printf 'ok - red main CI fixture files one check-and-test incident\n'

new_case main-ci-green
cp "$fixtures/main-ci-red-jobs.json" "$CASE_CI/jobs.json"
cp "$fixtures/main-ci-red-failed.log" "$CASE_CI/failed.log"
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq --arg now "$now" '.workflow_runs[0].created_at=$now' "$fixtures/main-ci-green-runs.json" > "$CASE_AUTOPI/main-runs.json"
jq -n --arg now "$now" --slurpfile green "$CASE_AUTOPI/main-runs.json" \
  '{schema:1,tick:$now,main_runs:{CI:[$green[0].workflow_runs[0] | {databaseId:.id,headSha:.head_sha,status,conclusion,createdAt:.created_at,attempt:.run_attempt}],"Pipeline suites":[]}}' \
  > "$CASE_AUTOPI/pr-run-snapshot.json"
run_bell
assert_eq 'green main CI run files nothing' "$(wc -l < "$CASE/issues.log" | tr -d ' ')" 0
printf 'ok - green main CI fixture files nothing\n'

ZF_ENGINE_DIR="$repo_root/engine" node "$repo_root/engine/lesson-guard-schema.mjs" "$repo_root"
printf 'advisor-incident.test.sh: PASS\n'
