#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# issue_rest_view / issue_rest_state: the REST read keeps the `gh issue view --json` shape, and every unreadable answer is a nonzero exit with no stdout.
source "$SCRIPT_DIR/lib.d/issue-rest.sh"
REPO=test/repo
failures=0
check() { # description expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok - %s\n' "$1"; else printf 'not ok - %s (expected [%s], got [%s])\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
FAKE_ISSUE=''; FAKE_COMMENTS='[[]]'; FAKE_FAIL=''
gh() { # api repos/<repo>/issues/<n>[/comments?...]: FAKE_FAIL=issue|comments|all makes that read fail
  [[ "$1" == api ]] || return 64
  case "${*: -1}" in
    */comments\?*) [[ "$FAKE_FAIL" != comments && "$FAKE_FAIL" != all ]] || return 1; printf '%s\n' "$FAKE_COMMENTS" ;;
    *) [[ "$FAKE_FAIL" != issue && "$FAKE_FAIL" != all ]] || return 1; printf '%s\n' "$FAKE_ISSUE" ;;
  esac
}
rc_of() { local rc=0; "$@" > "$test_env_root/out" 2>/dev/null || rc=$?; printf '%s' "$rc"; }

FAKE_ISSUE='{"number":7,"title":"t","body":null,"state":"open","state_reason":null,"closed_at":null,"labels":[{"name":"on-hold","id":1},{"name":"bug"}]}'
view="$(issue_rest_view 7)"
check "open issue keeps the gh issue view shape" '{"number":7,"title":"t","body":"","state":"OPEN","stateReason":null,"closedAt":null,"labels":[{"name":"on-hold"},{"name":"bug"}]}' "$view"
check "comments are absent unless asked for" false "$(jq 'has("comments")' <<< "$view")"
check "issue_rest_state prints OPEN" OPEN "$(issue_rest_state 7)"

FAKE_ISSUE='{"number":7,"title":"t","body":"b","state":"closed","state_reason":"not_planned","closed_at":"2026-11-01T00:00:00Z","labels":[]}'
check "closed issue upper-cases state and reason" 'CLOSED NOT_PLANNED 2026-11-01T00:00:00Z' "$(issue_rest_view 7 | jq -r '[.state, .stateReason, .closedAt] | join(" ")')"

FAKE_COMMENTS='[[{"node_id":"IC_1","body":"one","created_at":"2026-11-01T00:00:00Z","html_url":"u1","user":{"login":"a"}}],[{"node_id":"IC_2","body":null,"created_at":"2026-11-02T00:00:00Z","html_url":"u2","user":{"login":"b"}}]]'
check "comments from every page, oldest first" 'IC_1 one a|IC_2  b' "$(issue_rest_view 7 test/repo comments | jq -r '[.comments[] | "\(.id) \(.body) \(.author.login)"] | join("|")')"
FAKE_COMMENTS='[[]]'
check "an issue without comments still has the key when asked" '[]' "$(issue_rest_view 7 test/repo comments | jq -c '.comments')"

# Every unreadable answer: nonzero, nothing on stdout.
unreadable() { # description command...
  local description="$1" rc out
  shift
  rc="$(rc_of "$@")"; out="$(cat "$test_env_root/out")"
  check "$description: nonzero, no output" "nonzero|" "$([[ "$rc" != 0 ]] && echo nonzero || echo "rc0")|$out"
}
FAKE_FAIL=issue;    unreadable "failed issue read" issue_rest_view 7
FAKE_FAIL=issue;    unreadable "failed state read" issue_rest_state 7
FAKE_FAIL=comments; unreadable "failed comments read" issue_rest_view 7 test/repo comments
FAKE_FAIL=''
check "a failed comments read is not needed without comments" CLOSED "$(issue_rest_state 7)"
FAKE_ISSUE='{"number":7,"title":"t","body":"","state":"open","pull_request":{"url":"u"},"labels":[]}'
unreadable "a pull request number" issue_rest_view 7
FAKE_ISSUE='{"number":8,"title":"t","body":"","state":"open","labels":[]}'
unreadable "an answer for another number" issue_rest_view 7
FAKE_ISSUE='{"number":7,"title":"t","body":"","state":"weird","labels":[]}'
unreadable "an unknown state" issue_rest_view 7
FAKE_ISSUE='{"number":7,"title":"t","body":"","state":"open","labels":null}'
unreadable "labels that are not a list" issue_rest_view 7
FAKE_ISSUE='not json'
unreadable "a body that is not JSON" issue_rest_view 7
FAKE_ISSUE=''
unreadable "an empty answer" issue_rest_view 7
unreadable "a non-numeric issue" issue_rest_view pr-7
unreadable "a missing repo" env -u REPO bash -c 'source "$1"; issue_rest_view 7' _ "$SCRIPT_DIR/lib.d/issue-rest.sh"
[[ "$failures" == 0 ]] || { echo "issue-rest.test.sh: $failures failed" >&2; exit 1; }
echo 'issue-rest.test.sh: all passed'
