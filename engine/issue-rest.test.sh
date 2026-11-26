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
FAKE_CALLS="$test_env_root/gh-calls"
FAKE_LIST='[]'
FAKE_LIST_PAGE1=''; FAKE_LIST_PAGE2=''
: > "$FAKE_CALLS"
gh() {
  [[ "$1" == api ]] || return 64
  if [[ "$2" == graphql ]]; then
    printf 'graphql\n' >> "$FAKE_CALLS"
    printf '%s\n' '{"data":{"repository":{"i7":{"number":7,"blockedBy":{"nodes":[]},"subIssues":{"totalCount":0,"nodes":[]},"subIssuesSummary":{"total":0,"completed":0}},"i8":{"number":8,"blockedBy":{"nodes":[{"number":6,"state":"OPEN"}]},"subIssues":{"totalCount":1,"nodes":[{"number":9,"state":"OPEN"}]},"subIssuesSummary":{"total":1,"completed":0}}}}}'
    return
  fi
  case "$2" in
    repos/test/repo/issues\?*)
      local page="${2##*page=}"
      page="${page%%&*}"
      printf 'list %s\n' "$page" >> "$FAKE_CALLS"
      if [[ "$page" == 1 && -n "$FAKE_LIST_PAGE1" ]]; then printf '%s\n' "$FAKE_LIST_PAGE1"
      elif [[ "$page" == 2 && -n "$FAKE_LIST_PAGE2" ]]; then printf '%s\n' "$FAKE_LIST_PAGE2"
      else printf '%s\n' "$FAKE_LIST"; fi ;;
    */comments\?*) [[ "$FAKE_FAIL" != comments && "$FAKE_FAIL" != all ]] || return 1; printf 'comments\n' >> "$FAKE_CALLS"; printf '%s\n' "$2" > "$test_env_root/comment-url"; printf '%s\n' "$*" > "$test_env_root/comment-args"; printf '%s\n' "$FAKE_COMMENTS" ;;
    *) [[ "$FAKE_FAIL" != issue && "$FAKE_FAIL" != all ]] || return 1; printf 'issue\n' >> "$FAKE_CALLS"; FAKE_ISSUE_URL="$2"; printf '%s\n' "$FAKE_ISSUE" ;;
  esac
}
rc_of() { local rc=0; "$@" > "$test_env_root/out" 2>/dev/null || rc=$?; printf '%s' "$rc"; }

FAKE_ISSUE='{"number":7,"title":"t","body":null,"state":"open","state_reason":null,"closed_at":null,"labels":[{"name":"on-hold","id":1},{"name":"bug"}]}'
view="$(issue_rest_view 7)"
check "open issue keeps the gh issue view shape" '{"number":7,"title":"t","body":"","state":"OPEN","stateReason":null,"closedAt":null,"labels":[{"name":"on-hold"},{"name":"bug"}]}' "$view"
check "comments are absent unless asked for" false "$(jq 'has("comments")' <<< "$view")"
check "issue_rest_state prints OPEN" OPEN "$(issue_rest_state 7)"

GH_TICK_CACHE_DIR="$test_env_root/gh-tick-cache"
FAKE_LIST_PAGE1="$(jq -cn '([range(1;100) as $i | {number:$i,title:"pull request",body:"",state:"open",pull_request:{url:"fixture"},labels:[],user:{login:"fixture"}}] + [{number:100,title:"issue",body:"",state:"open",created_at:"2026-11-01T00:00:00Z",updated_at:"2026-11-02T00:00:00Z",labels:[],user:{login:"fixture"}}])')"
FAKE_LIST_PAGE2="$(jq -cn '[range(101;201) as $i | {number:$i,title:"issue",body:"",state:"open",created_at:"2026-11-01T00:00:00Z",updated_at:"2026-11-02T00:00:00Z",labels:[],user:{login:"fixture"}}]')"
: > "$FAKE_CALLS"
paged_list="$(issue_rest_list_fetch gh test/repo open ready-for-agent 100)"
check "REST issue limit fills after dropping pull-request rows" 100 "$(jq 'length' <<< "$paged_list")"
check "REST list keeps paginating until it has enough issues" 'list 1,list 2' "$(paste -sd, "$FAKE_CALLS")"
FAKE_LIST_PAGE1=''; FAKE_LIST_PAGE2=''; : > "$FAKE_CALLS"
FAKE_LIST='[{"number":7,"title":"t","body":"b","state":"open","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","labels":[{"name":"ready-for-agent"}],"user":{"login":"a"}},{"number":8,"title":"pr","body":"","state":"open","pull_request":{"url":"u"},"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","labels":[{"name":"ready-for-agent"}],"user":{"login":"b"}}]'
first_list="$(issue_rest_list test/repo open ready-for-agent)"
second_list="$(issue_rest_list test/repo open ready-for-agent)"
check "REST label snapshots drop pull requests" '[7]' "$(jq -c '[.[].number]' <<< "$first_list")"
check "two reads of one label share one REST request per tick" 1 "$(grep -c '^list ' "$FAKE_CALLS")"
before_graphql="$(grep -c '^graphql$' "$FAKE_CALLS" || true)"
multi_label_rows="$(issue_rest_list_labels_context test/repo open 1000 gh needs-triage ready-for-agent)"
check "two label snapshots merge before one dependency query" '[7]' "$(jq -c '[.[].number]' <<< "$multi_label_rows")"
check "all candidate labels share one batched context request" "$((before_graphql + 1))" "$(grep -c '^graphql$' "$FAKE_CALLS")"
before_graphql="$(grep -c '^graphql$' "$FAKE_CALLS" || true)"
context_rows="$(issue_rest_with_context <<< '[{"number":7},{"number":8}]')"
second_context_rows="$(issue_rest_with_context <<< '[{"number":7},{"number":8}]')"
check "one batched GraphQL read adds dependency fields for all issue candidates" '7,8|6|9' \
  "$(jq -r '[.[].number] | sort | map(tostring) | join(",")' <<< "$context_rows")|$(jq -r '.[1].blockedBy.nodes[0].number' <<< "$context_rows")|$(jq -r '.[1].subIssues.nodes[0].number' <<< "$context_rows")"
check "batched context uses one GraphQL request" "$((before_graphql + 1))" "$(grep -c '^graphql$' "$FAKE_CALLS")"
check "same GraphQL query hash is reused within the tick" "$context_rows" "$second_context_rows"
check "repeated context query keeps one GraphQL request" "$((before_graphql + 1))" "$(grep -c '^graphql$' "$FAKE_CALLS")"

issue_rest_limited_graphql() {
  [[ "$1" == api && "$2" == graphql ]] || return 64
  local query="" arg numbers count
  for arg in "$@"; do
    [[ "$arg" == query=* ]] && query="${arg#query=}"
  done
  numbers="$(grep -oE 'i[0-9]+: issue' <<< "$query" | sed -E 's/^i([0-9]+):.*/\1/')"
  count="$(wc -l <<< "$numbers" | tr -d ' ')"
  printf '%s\n' "$count" >> "$test_env_root/context-batch-sizes"
  if (( count > 20 )); then
    for _ in $(seq 1 296); do printf '%s\n' 'Resource limits for this query exceeded.' >&2; done
    return 1
  fi
  jq -cn --arg numbers "$numbers" '
    ($numbers | split("\n") | map(select(length > 0) | tonumber)) as $ids
    | {data:{repository:(reduce $ids[] as $number ({};
        .["i\($number)"]={number:$number,blockedBy:{nodes:[]},subIssues:{totalCount:0,nodes:[]},subIssuesSummary:{total:0,completed:0}}))}}
  '
}

large_context_rows="$(jq -cn '[range(1;46) | {number:.,title:"candidate"}]')"
rm -f -- "$test_env_root/context-batch-sizes"
context_rc=0
issue_rest_with_context issue_rest_limited_graphql <<< "$large_context_rows" \
  > "$test_env_root/large-context.json" 2> "$test_env_root/large-context.err" || context_rc=$?
check "large dependency context succeeds when oversized batches are refused" 0 "$context_rc"
check "dependency context requests stay within 20 aliases" '20,20,5' \
  "$(paste -sd, "$test_env_root/context-batch-sizes")"
check "successful dependency batches emit no resource-limit failures" 0 \
  "$(grep -c 'Resource limits for this query exceeded' "$test_env_root/large-context.err" || true)"
check "large dependency context retains every candidate" 45 \
  "$(jq 'length' "$test_env_root/large-context.json" 2>/dev/null || echo 0)"
check "every candidate receives blocker and child context" 45 \
  "$(jq '[.[] | select(has("blockedBy") and has("subIssues") and has("subIssuesSummary"))] | length' "$test_env_root/large-context.json" 2>/dev/null || echo 0)"

FAKE_ISSUE='{"number":7,"title":"t","body":"b","state":"closed","state_reason":"not_planned","closed_at":"2026-11-01T00:00:00Z","labels":[]}'
check "closed issue upper-cases state and reason" 'CLOSED NOT_PLANNED 2026-11-01T00:00:00Z' "$(issue_rest_view 7 | jq -r '[.state, .stateReason, .closedAt] | join(" ")')"

FAKE_ISSUE='{"number":7,"title":"t","body":"b","state":"open","created_at":"2026-11-01T00:00:00Z","labels":[]}'
FAKE_COMMENTS='[{"node_id":"IC_1","body":"one","created_at":"2026-11-01T00:00:00Z","html_url":"u1","user":{"login":"a"}},{"node_id":"IC_2","body":null,"created_at":"2026-11-02T00:00:00Z","html_url":"u2","user":{"login":"b"}}]'
check "comments use the REST since endpoint" 'IC_1 one a|IC_2  b' "$(issue_rest_view 7 test/repo comments | jq -r '[.comments[] | "\(.id) \(.body) \(.author.login)"] | join("|")')"
check "comment GET starts at issue creation for a complete thread" 'repos/test/repo/issues/7/comments?per_page=100&since=2026-11-01T00:00:00Z' "$(cat "$test_env_root/comment-url")"
check "comment GET uses one conditional-capable request" no "$(grep -F -- --paginate "$test_env_root/comment-args" >/dev/null && echo yes || echo no)"
FAKE_COMMENTS='[]'
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
check "a failed comments read is not needed without comments" OPEN "$(issue_rest_state 7)"
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
