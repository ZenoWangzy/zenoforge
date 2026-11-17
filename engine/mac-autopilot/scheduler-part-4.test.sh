#!/usr/bin/env bash
# Run partition 4 of the scheduler cases with the shared fixtures.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
scheduler_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCHED_TEST_PART=4 bash "$scheduler_dir/scheduler.test.sh"

# Cache helpers must share data across command-substitution subshells and ticks.
fixture="$test_env_root/ci-cache"
rm -rf -- "$fixture"
A="$fixture/autopi" LOG="$fixture/scheduler.log" STAMP=fixture
GH_ETAG_DIR="$fixture/etag" GH_TICK_CACHE_DIR="$fixture/tick-1" GH_TICK_CALLS_FILE=""
GH_PARALLEL=2
mkdir -p "$A" "$GH_ETAG_DIR" "$GH_TICK_CACHE_DIR"
RUN_LIST_CALLS="$fixture/run-list-calls" JOB_CALLS="$fixture/job-calls"
RUNS_CALLS="$fixture/actions-runs-calls"
declare -A CI_RUN_JOBS_CACHE=()
TICK_UNFINISHED_LOADED=false TICK_UNFINISHED="" TICK_UNFINISHED_ALL_OK=false
source "$scheduler_dir/scheduler.d/core.sh"
source "$scheduler_dir/scheduler.d/ci-status.sh"
source "$scheduler_dir/scheduler.d/harvest-station.sh"
jqf() { command jq "$@"; }
gh_rate_limit_api_class() { printf 'rest\n'; }
RATE_LIMIT_CORE='{"remaining":5000,"reset":1790000000}'
FAIL_RUN_LIST=false
gh_timeout() {
  while [[ "${1:-}" == -k || "${1:-}" == --kill-after ]]; do shift 2; done
  shift
  case "${1:-} ${2:-}" in
    'api rate_limit') printf '%s\n' "$RATE_LIMIT_CORE" ;;
    'run list')
      printf '%s\n' "$*" >> "$RUN_LIST_CALLS"
      [[ "$FAIL_RUN_LIST" != true ]] || return 42
      printf '[{"databaseId":901,"conclusion":"failure","event":"push","status":"completed"}]\n'
      ;;
    'run rerun') return 0 ;;
    'api -X') return 0 ;;
    *) return 97 ;;
  esac
}
gh_api_cached() {
  case "$2" in
    runs-*)
      printf '%s\n' "$*" >> "$RUNS_CALLS"
      printf '{"databaseId":902,"status":"queued","event":"pull_request","headBranch":"feature","headSha":"%s"}\n' "$head"
      ;;
    runjobs-*)
      printf '%s\n' "$*" >> "$JOB_CALLS"
      printf '[{"status":"completed","runner_id":null,"conclusion":"failure","steps":[{"name":"test","conclusion":"failure"}]}]\n'
      ;;
    *) return 97 ;;
  esac
}
fail() { echo "not ok - scheduler cache: $*" >&2; exit 1; }

head="0000000000000000000000000000000000000901"
runs="$(gh_run_list_cached --commit "$head")"
runs_again="$(gh_run_list_cached --commit "$head")"
[[ "$runs" == "$runs_again" && "$(wc -l < "$RUN_LIST_CALLS" | tr -d ' ')" == 1 ]] \
  || fail 'run-list readers did not share one per-tick request'

unfinished="$(unfinished_runs)"
unfinished_again="$(unfinished_runs)"
[[ "$unfinished" == "$unfinished_again" && "$(wc -l < "$RUNS_CALLS" | tr -d ' ')" == 4 ]] \
  || fail 'actions/runs readers did not share one request per status in the tick'

ci_jobs_prefetch 901
ci_jobs_status 901 >/dev/null
ci_jobs_active_runner_ids 901 >/dev/null
failed_steps="$(ci_failed_steps "$head")"
[[ "$failed_steps" == test ]] || fail 'completed run failure details were not returned'
[[ -s "$A/.gh-run-jobs/901.json" && "$(wc -l < "$JOB_CALLS" | tr -d ' ')" == 1 ]] \
  || fail 'job readers did not share a completed run snapshot within the tick'

GH_TICK_CACHE_DIR="$fixture/tick-2"
mkdir -p "$GH_TICK_CACHE_DIR"
CI_RUN_JOBS_CACHE=()
ci_jobs_data 901 true >/dev/null
[[ "$(wc -l < "$JOB_CALLS" | tr -d ' ')" == 1 ]] \
  || fail 'completed run jobs were polled again in the next tick'

GH_TICK_CACHE_DIR="$fixture/tick-1"
gh run rerun 901 --failed >/dev/null
[[ ! -e "$A/.gh-run-jobs/901.json" ]] || fail 'successful rerun kept its completed snapshot'
CI_RUN_JOBS_CACHE=()
runs_after_rerun="$(gh_run_list_cached --commit "$head")"
[[ "$runs_after_rerun" == "$runs" ]] || fail 'run-list refresh changed its fixture result'
ci_jobs_data 901 true >/dev/null
[[ "$(wc -l < "$RUN_LIST_CALLS" | tr -d ' ')" == 2 && "$(wc -l < "$JOB_CALLS" | tr -d ' ')" == 2 ]] \
  || fail 'rerun did not invalidate the prior run and job snapshots'
ci_jobs_data 901 true >/dev/null
gh api -X POST repos/test/repo/actions/runs/901/rerun >/dev/null
[[ ! -e "$A/.gh-run-jobs/901.json" ]] || fail 'REST rerun kept its completed snapshot'
ci_jobs_data 901 true >/dev/null
[[ "$(wc -l < "$JOB_CALLS" | tr -d ' ')" == 3 ]] || fail 'REST rerun did not refresh the job snapshot'
RATE_LIMIT_CORE='{"remaining":5000,"reset":1790000000}'
tick_rest_usage_begin
RATE_LIMIT_CORE='{"remaining":4993,"reset":1790000000}'
[[ "$(tick_rest_usage_summary)" == 'rest_used=7' ]] || fail 'REST delta did not report remaining-before minus remaining-after'
tick_rest_usage_begin
RATE_LIMIT_CORE='{"remaining":4990,"reset":1790000001}'
[[ "$(tick_rest_usage_summary)" == 'rest_used=reset' ]] || fail 'REST delta did not report a changed reset time'

cleanup_fixture="$fixture/lifecycle"
cleanup_a="$cleanup_fixture/autopi"
mkdir -p "$cleanup_a/deployment-status.stale" "$cleanup_a/.gh-run-jobs"
printf '{}\n' > "$cleanup_a/.gh-run-jobs/old.json"
printf '{}\n' > "$cleanup_a/.gh-run-jobs/new.json"
touch -d '2 hours ago' "$cleanup_a/deployment-status.stale"
touch -d '8 days ago' "$cleanup_a/.gh-run-jobs/old.json"
touch -d '1 minute ago' "$cleanup_a/.gh-run-jobs/new.json"
cleanup_probe="$cleanup_fixture/probe.sh"
cat > "$cleanup_probe" <<'EOF'
set -euo pipefail
A="$CACHE_A" LOG="$CACHE_LOG" STAMP=fixture GH_ETAG_DIR="$CACHE_A/.gh-etag"
source "$SCHEDULER_DIR/scheduler.d/core.sh"
jqf() { command jq "$@"; }
gh_timeout() { shift; [[ "$1 $2" == 'api rate_limit' ]] && printf '%s\n' '{"remaining":5000,"reset":1790000000}'; }
trap 'touch "$PRIOR_MARKER"' EXIT
tick_gh_calls_begin
printf '%s\n' "$ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR" > "$CURRENT_DIR_FILE"
EOF
SCHEDULER_DIR="$scheduler_dir" CACHE_A="$cleanup_a" CACHE_LOG="$cleanup_fixture/scheduler.log" \
  PRIOR_MARKER="$cleanup_fixture/prior-exit-ran" CURRENT_DIR_FILE="$cleanup_fixture/current-dir" bash "$cleanup_probe"
[[ ! -e "$cleanup_a/deployment-status.stale" ]] || fail 'deployment cache older than one hour was retained'
[[ ! -e "$cleanup_a/.gh-run-jobs/old.json" && -f "$cleanup_a/.gh-run-jobs/new.json" ]] \
  || fail 'completed-run job snapshots were not pruned by seven-day age'
current_cache_dir="$(cat "$cleanup_fixture/current-dir")"
[[ ! -e "$current_cache_dir" && -e "$cleanup_fixture/prior-exit-ran" ]] \
  || fail 'per-run deployment cache cleanup lost its chained exit trap'

failure_head="0000000000000000000000000000000000000902"
failure_unit=cache-failure
failure_units="$fixture/failure-units.json"
cat > "$failure_units" <<EOF
{"units":[{"id":"$failure_unit","pr":71,"ci_rerun_sha":null,"history":[{"stage":"supervisor-requeue","result":"report-only requeue"},{"stage":"write-start","work_type":"implement","at":"fixture-start"}]}]}
EOF
UNITS="$failure_units" TICK_PRS="[{\"number\":71,\"headRefOid\":\"$failure_head\"}]" SUP="$fixture/supervisor"
mkdir -p "$SUP"
GH_TICK_CACHE_DIR="$fixture/tick-failure"
mkdir -p "$GH_TICK_CACHE_DIR"
FAIL_RUN_LIST=true
SUPERVISOR_MESSAGE=""
unit_field() {
  case "$2" in
    '.pr // empty') printf '71\n' ;;
    '.ci_rerun_sha // empty') printf '\n' ;;
    *) return 1 ;;
  esac
}
set_unit() { :; }
to_supervisor() { SUPERVISOR_MESSAGE="$2"; }
decision_log_gate_reason() { :; }
how_why_gate_reason() { :; }
incident_report_gate_reason() { :; }
report_only_pr_requeue_harvest "$failure_unit" \
  "{\"pr_head\":\"$failure_head\",\"started\":\"fixture-start\",\"incident_report_resume\":false}" \
  report.md "$fixture/report.md" implement
[[ "$SUPERVISOR_MESSAGE" == *'could not list failed or cancelled CI runs'* ]] \
  || fail 'cached gh run-list failure did not take the could-not-list supervisor branch'
echo 'scheduler-part-4.test.sh: snapshots, REST accounting, cache cleanup, and cached run-list errors passed'
