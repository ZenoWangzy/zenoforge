#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fixture="$test_env_root/ci-job-logs"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

A="$MAC_AUTOPILOT_RUNTIME_DIR"
LOG="$A/scheduler.log"
STAMP=2026-11-26T00:00:00Z
GH_PARALLEL=1
api_calls="$fixture/api-calls"
log_calls="$fixture/log-calls"
: > "$api_calls"
: > "$log_calls"
status_101=in_progress
status_102=completed
status_103=completed
status_201=in_progress
declare -A log_failure=([102]=404 [103]=410)
fail() { printf 'ci-job-logs.test.sh: %s\n' "$*" >&2; exit 1; }
gh() {
  if [[ "$1" == api && "$2" == repos/{owner}/{repo}/actions/jobs/* && "$#" == 2 ]]; then
    printf '%s\n' "$2" >> "$api_calls"
    job="${2##*/}"
    status_var="status_$job"
    printf '{"status":"%s"}\n' "${!status_var}"
    return 0
  fi
  if [[ "$1" == api && "$2" == --allow-escape-sequences && "$3" == repos/{owner}/{repo}/actions/jobs/*/logs ]]; then
    printf '%s\n' "$3" >> "$log_calls"
    job="${3##*/actions/jobs/}"
    job="${job%/logs}"
    if [[ -n "${log_failure[$job]:-}" ]]; then
      printf 'gh: HTTP %s: Gone\n' "${log_failure[$job]}" >&2
      return 1
    fi
    printf 'log for %s\n' "$job"
    return 0
  fi
  fail "unexpected gh call: $*"
}
checks() { jqf -cn --arg link "https://github.com/example/repo/actions/runs/1/job/$1" '[{bucket:"fail",name:"fixture",link:$link}]'; }
log_call_count() { grep -c '/logs$' "$log_calls" || true; }
job_log_call_count() { grep -c "/actions/jobs/$1/logs$" "$log_calls" || true; }

ci_test_red_checks "$(checks 101)" >/dev/null
[[ "$(log_call_count)" == 0 ]] || fail 'in-progress job logs were fetched'

status_101=completed
ci_test_red_checks "$(checks 101)" >/dev/null
[[ "$(log_call_count)" == 1 ]] || fail 'completed job logs were not fetched'
api_count="$(wc -l < "$api_calls")"
ci_test_red_checks "$(checks 101)" >/dev/null
[[ "$(wc -l < "$api_calls")" == "$api_count" && "$(log_call_count)" == 1 ]] \
  || fail 'a cached completed job log made another network call'

ci_test_red_checks "$(checks 102)" >/dev/null
[[ -f "$A/.gh-job-logs/102.gone" ]] || fail 'HTTP 404 was not cached as gone'
api_count="$(wc -l < "$api_calls")"
ci_test_red_checks "$(checks 102)" >/dev/null
[[ "$(wc -l < "$api_calls")" == "$api_count" ]] || fail 'a gone job made another network call'

ci_test_red_checks "$(checks 103)" >/dev/null
[[ -f "$A/.gh-job-logs/103.gone" ]] || fail 'HTTP 410 was not cached as gone'
api_count="$(wc -l < "$api_calls")"
ci_test_red_checks "$(checks 103)" >/dev/null
[[ "$(wc -l < "$api_calls")" == "$api_count" ]] || fail 'a 410 gone job made another network call'

STOP_CHECKS=''
repair_check_rows() { printf '%s' "$STOP_CHECKS"; }
incident_labels_match_json() { return 1; }
repair_unit='{"pr":220,"history":[{"stage":"ci-red"}]}'
STOP_CHECKS="$(checks 102)"
api_count="$(wc -l < "$api_calls")"
repair_failure_prompt "$repair_unit" '' >/dev/null
[[ "$(wc -l < "$api_calls")" == "$api_count" ]] || fail 'stop-loss made another network call after logs were gone'

STOP_CHECKS="$(checks 201)"
repair_failure_prompt "$repair_unit" '' >/dev/null
[[ "$(job_log_call_count 201)" == 0 ]] || fail 'stop-loss fetched logs for an in-progress job'
status_201=completed
repair_failure_prompt "$repair_unit" '' >/dev/null
[[ "$(job_log_call_count 201)" == 1 ]] || fail 'stop-loss did not fetch completed job logs'
api_count="$(wc -l < "$api_calls")"
repair_failure_prompt "$repair_unit" '' >/dev/null
[[ "$(wc -l < "$api_calls")" == "$api_count" && "$(job_log_call_count 201)" == 1 ]] \
  || fail 'stop-loss made another network call for cached completed logs'

echo 'ci-job-logs.test.sh: PASS'
