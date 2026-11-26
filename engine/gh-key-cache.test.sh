#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$MODEL_POLICY_TEST_REPO/engine/lib.d/gh-key-cache.sh"
trap 'rm -rf -- "$test_env_root"' EXIT

export AGENT_HOME="$test_env_root/agent" REPO=fixture/repo
calls="$test_env_root/fetch-calls"

fetch_json() {
  printf 'fetch\n' >> "$calls"
  printf '%s\n' '{"items":[1,2]}'
}

valid_json() {
  jq -e 'type == "object" and (.items | type == "array")' >/dev/null
}

fail() {
  printf 'gh-key-cache.test.sh: %s\n' "$*" >&2
  exit 1
}

first="$(gh_key_cache_get items 600 valid_json fetch_json)"
second="$(gh_key_cache_get items 600 valid_json fetch_json)"
[[ "$first" == '{"items":[1,2]}' && "$second" == "$first" ]] || fail 'cached response changed'
[[ "$(wc -l < "$calls")" == 1 ]] || fail 'fresh cache entry made another network call'

cache="$(gh_key_cache_file items)"
sed '1s/.*/0/' "$cache" > "$cache.tmp"
mv "$cache.tmp" "$cache"
third="$(gh_key_cache_get items 600 valid_json fetch_json)"
[[ "$third" == "$first" && "$(wc -l < "$calls")" == 2 ]] || fail 'expired cache entry did not refresh'

gh_key_cache_invalidate items
fourth="$(gh_key_cache_get items 600 valid_json fetch_json)"
[[ "$fourth" == "$first" && "$(wc -l < "$calls")" == 3 ]] || fail 'invalidated cache entry was reused'

GH_KEY_CACHE_DIR="$test_env_root/shared-read-cache"; export GH_KEY_CACHE_DIR
runner_calls="$test_env_root/runner-calls"; subissue_calls="$test_env_root/subissue-calls"
: > "$runner_calls"; : > "$subissue_calls"
gh() {
  case "$*" in
    'api --paginate repos/fixture/repo/actions/runners?per_page=100')
      echo runner >> "$runner_calls"
      printf '%s\n' '{"runners":[{"name":"fixture","status":"online"}]}' ;;
    'api repos/fixture/repo/issues/9/sub_issues?per_page=100 --paginate')
      echo sub-issue >> "$subissue_calls"
      printf '%s\n' '[{"number":10,"state":"open"}]' ;;
    *) return 97 ;;
  esac
}
export -f gh
runner_first="$(gh_runners_cached fixture/repo)"
runner_second="$(bash "$(dirname -- "${BASH_SOURCE[0]}")/bin/gh-key-cache-read" runners fixture/repo)"
[[ "$(wc -l < "$runner_calls")" == 1 ]] || fail 'runner cache wrapper repeated a read inside its TTL'
jq -se 'length == 1 and .[0].runners[0].name == "fixture"' <<<"$runner_first" >/dev/null || fail 'runner cache returned malformed pages'
jq -e '.[0].name == "fixture"' <<<"$runner_second" >/dev/null || fail 'runner reader did not return normalized rows'
children_first="$(gh_issue_subissues_cached fixture/repo 9)"
children_second="$(bash "$(dirname -- "${BASH_SOURCE[0]}")/bin/gh-key-cache-read" sub-issues fixture/repo 9)"
[[ "$(wc -l < "$subissue_calls")" == 1 ]] || fail 'sub-issue cache wrapper repeated a read inside its TTL'
[[ "$children_first" == "$children_second" ]] || fail 'sub-issue reader did not reuse the shared cache'

printf 'gh-key-cache.test.sh: pass\n'
