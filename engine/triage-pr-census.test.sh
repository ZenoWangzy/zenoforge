#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$engine_dir/lib.d/triage-pr-census.sh"
jqf() { jq "$@"; }
REPO=fixture/repo
PR_CENSUS_CALLS="$test_env_root/calls"
export PR_CENSUS_CALLS
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh() {
  printf '%s\n' "$*" >> "$PR_CENSUS_CALLS"
  case "$*" in
    'api --paginate --slurp repos/fixture/repo/pulls?state=open&per_page=100')
      jq -cn --arg now "$now" '[[{number:10,state:"open",draft:false,head:{ref:"agent/issue-10",sha:"1111111111111111111111111111111111111111"},base:{ref:"main"},title:"open PR",body:"Refs #77",labels:[],updated_at:$now},
        {number:11,state:"open",draft:false,head:{ref:"agent/issue-11",sha:"1111111111111111111111111111111111111111"},base:{ref:"main"},title:"other issue",body:"Refs #770",labels:[],updated_at:$now},
        {number:12,state:"open",draft:false,head:{ref:"agent/issue-77",sha:"1111111111111111111111111111111111111111"},base:{ref:"main"},title:"branch match",body:"",labels:[],updated_at:$now}]]' ;;
    'api repos/fixture/repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1')
      jq -cn --arg now "$now" '[{number:30,state:"closed",draft:false,head:{ref:"agent/issue-77",sha:"2222222222222222222222222222222222222222"},base:{ref:"main"},title:"merged PR",body:"Refs #77",labels:[],merged_at:$now,merge_commit_sha:"3333333333333333333333333333333333333333",updated_at:$now},
        {number:31,state:"closed",draft:false,head:{ref:"agent/issue-31",sha:"4444444444444444444444444444444444444444"},base:{ref:"main"},title:"closed PR",body:"Refs #77",labels:[],merged_at:null,merge_commit_sha:null,updated_at:$now}]' ;;
    *) return 1 ;;
  esac
}
: > "$PR_CENSUS_CALLS"
triage_pr_census_load "$now" "$REPO" 77 || { printf 'triage-pr-census.test.sh: census load failed\n' >&2; exit 1; }
prs="$(triage_pr_census_for_issue 77)" || { printf 'triage-pr-census.test.sh: issue match failed\n' >&2; exit 1; }
jq -e 'length == 3 and [.[].number] == [10,12,30] and .[0].state == "OPEN" and .[1].headRefName == "agent/issue-77" and .[2].state == "MERGED" and .[2].mergeCommit.oid == "3333333333333333333333333333333333333333"' <<<"$prs" >/dev/null \
  || { printf 'triage-pr-census.test.sh: local issue match was wrong: %s\n' "$prs" >&2; exit 1; }
[[ "$(wc -l < "$PR_CENSUS_CALLS")" == 2 ]] || { printf 'triage-pr-census.test.sh: repeated PR reads: %s\n' "$(cat "$PR_CENSUS_CALLS")" >&2; exit 1; }
snapshot="$TRIAGE_PR_CENSUS"
census_file="$test_env_root/census.json"
printf '%s\n' "$snapshot" > "$census_file"
TRIAGE_PR_CENSUS=''
TRIAGE_PR_CENSUS_FILE="$census_file"
file_prs="$(triage_pr_census_for_issue 77)" || { printf 'triage-pr-census.test.sh: file-backed census read failed\n' >&2; exit 1; }
jq -e '[.[].number] == [10,12,30]' <<<"$file_prs" >/dev/null \
  || { printf 'triage-pr-census.test.sh: file-backed census changed: %s\n' "$file_prs" >&2; exit 1; }
printf 'triage-pr-census.test.sh: ok\n'
