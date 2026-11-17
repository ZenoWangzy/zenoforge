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
jqf() { command jq "$@"; }
gh_rate_limit_api_class() { printf 'rest\n'; }
gh_timeout() {
  while [[ "${1:-}" == -k || "${1:-}" == --kill-after ]]; do shift 2; done
  shift
  case "${1:-} ${2:-}" in
    'run list')
      printf '%s\n' "$*" >> "$RUN_LIST_CALLS"
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
echo 'scheduler-part-4.test.sh: run and job snapshots shared per tick; completed jobs reused across ticks'
