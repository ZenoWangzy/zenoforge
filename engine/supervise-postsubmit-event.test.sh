#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib.sh"
eval "$(sed -n '/^postsubmit_green_for_sha() {/,/^}/p' "$script_dir/supervise-pipeline.sh")"
REPO=fixture/repo
sha=88e59d2734c8059e38d47c819ff977a9df316666
run_id=501
response=''
jobs_response='{"jobs":[{"id":501,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
api_status=0
job_api_status=0
gh() {
  case "$*" in
    *"api repos/$REPO/actions/runs?head_sha=$sha&per_page=100&page=1&created="*)
      [[ "$api_status" == 0 ]] || return 1
      printf '%s\n' "$response"
      ;;
    *"api repos/$REPO/actions/runs/$run_id/jobs?per_page=100&page=1"*)
      [[ "$job_api_status" == 0 ]] || return 1
      printf '%s\n' "$jobs_response"
      ;;
    *) return 2 ;;
  esac
}
for event in push workflow_dispatch; do
  response="$(jq -cn --arg sha "$sha" --arg event "$event" \
    --argjson id "$run_id" \
    '{workflow_runs:[{id:$id,head_sha:$sha,head_branch:"main",event:$event,path:".github/workflows/ci.yml",status:"completed",conclusion:"success"}]}')"
  if ! postsubmit_green_for_sha "$sha"; then
    echo "not ok - exact-SHA green $event must admit build" >&2
    exit 1
  fi
  echo "ok - exact-SHA green $event admits build"
done
valid_response="$response"
for mutation in \
  '.workflow_runs[0].event="pull_request"' \
  '.workflow_runs[0].head_sha="wrong-sha"' \
  '.workflow_runs[0].head_branch="topic"' \
  '.workflow_runs[0].path=".github/workflows/pipeline-suites.yml"' \
  '.workflow_runs[0].status="in_progress"' \
  '.workflow_runs[0].conclusion="failure"' \
  '.workflow_runs=[]'; do
  response="$(jq -c "$mutation" <<< "$valid_response")"
  if postsubmit_green_for_sha "$sha"; then
    echo "not ok - build accepted invalid evidence: $mutation" >&2
    exit 1
  fi
done
jobs_response='{"jobs":[{"id":501,"name":"Postsubmit validate","status":"completed","conclusion":"skipped"}]}'
if postsubmit_green_for_sha "$sha"; then
  echo 'not ok - a skipped Postsubmit job cannot admit build' >&2
  exit 1
fi
jobs_response='{"jobs":[{"id":501,"name":"Postsubmit validate","status":"completed","conclusion":"failure"}]}'
if postsubmit_green_for_sha "$sha"; then
  echo 'not ok - a failed Postsubmit job cannot admit build' >&2
  exit 1
fi
jobs_response='{"jobs":[{"id":501,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
job_api_status=1
if postsubmit_green_for_sha "$sha"; then
  echo 'not ok - an unreadable Postsubmit job cannot admit build' >&2
  exit 1
fi
job_api_status=0
api_status=1
if postsubmit_green_for_sha "$sha"; then exit 1; fi
api_status=0
response='{invalid'
if postsubmit_green_for_sha "$sha"; then exit 1; fi
echo 'ok - unrelated, non-green, absent and unreadable evidence blocks build'
