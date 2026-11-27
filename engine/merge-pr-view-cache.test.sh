#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh"
REPO=fixture/repo
calls="$test_env_root/gh-calls"
PR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PR_BODY='## prior-art
no external prior art: fixture'
PR_GRAPHQL_DOWN=1

gh() {
  printf '%s\n' "$*" >> "$calls"
  case "$1 $2" in
    'pr view') return 1 ;;
    'api --paginate')
      case "$*" in
        *'pulls/17/files?per_page=100'*) printf '%s\n' '[{"filename":"engine/one.sh"}]' ;;
        *'pulls/17/commits?per_page=100'*) jq -cn --arg sha "$PR_HEAD" '[{sha:$sha,commit:{message:"fixture",committer:{date:"2026-11-26T00:00:00Z"}}}]' ;;
        *) return 1 ;;
      esac
      ;;
    'api repos/{owner}/{repo}/pulls/17')
      jq -cn --arg sha "$PR_HEAD" --arg body "$PR_BODY" '{head:{sha:$sha},body:$body}'
      ;;
    *) return 1 ;;
  esac
}

fail() {
  printf 'merge-pr-view-cache.test.sh: %s\n' "$*" >&2
  exit 1
}

first="$(merge_pr_view 17 body,files,commits)" || fail 'first PR metadata read failed'
second="$(merge_pr_view 17 body,files,commits)" || fail 'repeated PR metadata read failed'
jq -e '.body | contains("no external prior art")' <<<"$first" >/dev/null || fail 'PR body was lost'
jq -e '.files == [{"path":"engine/one.sh"}] and .commits[0].oid == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$second" >/dev/null || fail 'PR immutable data changed'
file_calls="$(awk '/pulls\/17\/files\?per_page=100/ {n++} END {print n+0}' "$calls")"
commit_calls="$(awk '/pulls\/17\/commits\?per_page=100/ {n++} END {print n+0}' "$calls")"
[[ "$file_calls" == 1 && "$commit_calls" == 1 ]] || fail "same head fetched files=$file_calls commits=$commit_calls times"

PR_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
merge_pr_view 17 body,files,commits >/dev/null || fail 'changed PR head could not be read'
file_calls="$(awk '/pulls\/17\/files\?per_page=100/ {n++} END {print n+0}' "$calls")"
commit_calls="$(awk '/pulls\/17\/commits\?per_page=100/ {n++} END {print n+0}' "$calls")"
[[ "$file_calls" == 2 && "$commit_calls" == 2 ]] || fail 'new head reused the previous immutable data'

printf 'merge-pr-view-cache.test.sh: pass\n'
