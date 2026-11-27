#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$script_dir/lib.sh"
REPO=fixture/repo
calls="$test_env_root/gh-calls"
blocked='[]'
subissues_file="$test_env_root/subissues.json"
printf '%s\n' '[]' > "$subissues_file"
source "$script_dir/mac-autopilot/scheduler.d/core.sh"
AUTOPILOT_AUTO_FILED_LABEL_READY=true

gh() {
  printf '%s\n' "$*" >> "$calls"
  case "$*" in
    'api repos/fixture/repo/issues/1/dependencies/blocked_by'*) printf '%s\n' "$blocked" ;;
    'api repos/fixture/repo/issues/3/sub_issues?per_page=100 --paginate') cat "$subissues_file" ;;
    'api repos/fixture/repo/issues/2') printf '%s\n' '{"id":22}' ;;
    'api --method POST repos/fixture/repo/issues/1/dependencies/blocked_by'*)
      blocked='[{"id":22,"number":2,"state":"open"}]'
      ;;
    'issue create '* ) printf '%s\n' '[{"number":31}]' > "$subissues_file"; printf '%s\n' 'https://github.com/fixture/repo/issues/31' ;;
    *) printf 'gh-issue-list-cache.test.sh: unexpected gh call: %s\n' "$*" >&2; return 1 ;;
  esac
}

fail() {
  printf 'gh-issue-list-cache.test.sh: %s\n' "$*" >&2
  exit 1
}

if has_open_blocker 1; then fail 'empty blocker list reported blocked'; fi
if has_open_blocker 1; then fail 'cached empty blocker list reported blocked'; fi
[[ "$(grep -c 'issues/1/dependencies/blocked_by' "$calls")" == 1 ]] || fail 'blocker list TTL made repeated network calls'

add_issue_blocked_by 1 2 || fail 'could not add blocked-by edge'
has_open_blocker 1 || fail 'successful dependency write left the cached list in place'
[[ "$OPEN_BLOCKER_IDS" == 2 ]] || fail "unexpected open blocker IDs: $OPEN_BLOCKER_IDS"
[[ "$(grep -c 'issues/1/dependencies/blocked_by' "$calls")" == 3 ]] || fail 'dependency write did not invalidate the cached list'

gh_issue_subissues_cached fixture/repo 3 >/dev/null || fail 'could not read sub-issues'
gh_issue_subissues_cached fixture/repo 3 >/dev/null || fail 'cached sub-issue read failed'
[[ "$(grep -c 'issues/3/sub_issues?per_page=100' "$calls")" == 1 ]] || fail 'sub-issue TTL made repeated network calls'
scheduler_auto_filed_issue_create --title child --body child --parent 3 >/dev/null || fail 'could not create parented issue'
children="$(gh_issue_subissues_cached fixture/repo 3)" || fail 'sub-issue read after write failed'
[[ "$children" == '[{"number":31}]' ]] || fail "sub-issue write left stale data: $children"
[[ "$(grep -c 'issues/3/sub_issues?per_page=100' "$calls")" == 2 ]] || fail 'parented issue write did not invalidate the cached sub-issue list'

printf 'gh-issue-list-cache.test.sh: pass\n'
