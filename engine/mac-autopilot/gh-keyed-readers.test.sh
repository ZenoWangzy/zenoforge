#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$script_dir/lib.d/gh-key-cache.sh"
source "$script_dir/lib.d/gh-tick-cache.sh"
HERE="$script_dir/mac-autopilot"
source "$HERE/scheduler.d/core.sh"
source "$HERE/scheduler.d/ci-status.sh"
REPO=fixture/repo ZF_REPO=fixture/repo GH_REPO=fixture/repo ROOT="$test_env_root/repo"
SHA_RE='^[0-9a-f]{40}$'
mkdir -p "$ROOT"
GH_TICK_CACHE_DIR="$test_env_root/tick-one"
calls="$test_env_root/gh-calls"
response="$test_env_root/check-runs.json"
page_two="$test_env_root/check-runs-page-two.json"
runner_calls="$test_env_root/runner-calls"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

gh() {
  printf '%s\n' "$*" >> "$calls"
  if [[ "$1 $2" == 'api --paginate' && "$3" == 'repos/{owner}/{repo}/actions/runners?per_page=100' ]]; then
    printf 'fetch\n' >> "$runner_calls"
    printf '%s\n' '{"runners":[{"status":"online","busy":false,"labels":[{"name":"cihost-ci"}]}]}'
    return 0
  fi
  [[ "$1" == api && "$2" == "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100"* ]] || return 1
  if [[ "$2" == *'page=2' ]]; then cat "$page_two"; else cat "$response"; fi
}

fail() {
  printf 'gh-keyed-readers.test.sh: %s\n' "$*" >&2
  exit 1
}

printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Required CI gates","status":"completed","conclusion":"failure"}]}' > "$response"
tick_pr_check_runs "$sha" >/dev/null || fail 'tick reader could not read check runs'
GH_TICK_CACHE_DIR="$test_env_root/tick-two"
main_red_failed_checks "$sha" > "$test_env_root/main-red"
[[ "$(cat "$test_env_root/main-red")" == '["Required CI gates"]' ]] || fail 'main-red reader returned the wrong checks'
[[ "$(wc -l < "$calls")" == 1 ]] || fail 'the check-run readers did not share the completed SHA cache'
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Required CI gates","status":"completed","conclusion":"success"}]}' > "$response"
gh_commit_check_runs_invalidate "$sha"
GH_TICK_CACHE_DIR="$test_env_root/tick-after-invalidation"
[[ "$(main_red_failed_checks "$sha")" == '[]' ]] || fail 'main-red reused its normalized cache after check-run invalidation'
[[ "$(wc -l < "$calls")" == 2 ]] || fail 'check-run invalidation did not refetch the SHA'

sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Required CI gates","status":"in_progress","conclusion":null}]}' > "$response"
GH_TICK_CACHE_DIR="$test_env_root/tick-three"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'in-progress check runs were unavailable'
GH_TICK_CACHE_DIR="$test_env_root/tick-four"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'second in-progress read was unavailable'
[[ "$(wc -l < "$calls")" == 4 ]] || fail 'an incomplete check-run set was persisted beyond its tick'

sha=cccccccccccccccccccccccccccccccccccccccc
printf '%s\n' '{"total_count":0,"check_runs":[]}' > "$response"
GH_TICK_CACHE_DIR="$test_env_root/tick-five"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'empty completed check runs were unavailable'
GH_TICK_CACHE_DIR="$test_env_root/tick-six"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'empty completed check runs were not shared'
[[ "$(wc -l < "$calls")" == 5 ]] || fail 'empty completed check runs were not persisted'
gh_commit_check_runs_invalidate "$sha"
GH_TICK_CACHE_DIR="$test_env_root/tick-seven"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'invalidated check runs could not be refreshed'
[[ "$(wc -l < "$calls")" == 6 ]] || fail 'check-run invalidation kept the persistent cache'

sha=dddddddddddddddddddddddddddddddddddddddd
command jq -cn '{total_count:101,check_runs:[range(0;100) | {name:("check-" + tostring),status:"completed",conclusion:"success"}]}' > "$response"
command jq -cn '{total_count:101,check_runs:[{name:"check-100",status:"completed",conclusion:"success"}]}' > "$page_two"
GH_TICK_CACHE_DIR="$test_env_root/tick-eight"
large="$(gh_commit_check_runs_cached "$sha")" || fail 'multi-page check runs were unavailable'
[[ "$(jq -r '.check_runs | length' <<<"$large")" == 101 && "$(wc -l < "$calls")" == 8 ]] || fail 'check-run fetch did not join every page'
GH_TICK_CACHE_DIR="$test_env_root/tick-nine"
gh_commit_check_runs_cached "$sha" >/dev/null || fail 'multi-page check-run cache read failed'
[[ "$(wc -l < "$calls")" == 8 ]] || fail 'complete multi-page check runs were not cached'

gh_runners_cached >/dev/null || fail 'runner read failed'
gh_runners_cached >/dev/null || fail 'cached runner read failed'
[[ "$(wc -l < "$runner_calls")" == 1 ]] || fail 'runner read ignored the five-minute cache'

printf 'gh-keyed-readers.test.sh: pass\n'
