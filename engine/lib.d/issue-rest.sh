source "$(dirname -- "${BASH_SOURCE[0]}")/gh-tick-cache.sh"

# REST reads of one issue for the paths that decide a hold, a requeue, a recut or a ruling (#1038).
# `gh issue view --json` goes through GraphQL, whose secondary rate limit refused these reads and
# stalled the scheduler; REST has its own budget. The output keeps the shape `gh issue view --json`
# gave (state OPEN/CLOSED, labels [{name}], comments [{id,body,createdAt,url,author}]) so a caller
# keeps its own comparisons.
#
# issue_rest_view <issue> [repo] [comments]
#   stdout: one JSON object {number,title,body,state,stateReason,closedAt,labels[,comments]}.
#   `comments` is emitted only when asked for: an absent key can never read as "no comments".
#   Nonzero with no stdout when the number is not a positive integer, the repo is unknown, either
#   API call fails, the number is a pull request (gh issue view refused those too), or the answer is
#   not a well-formed issue. A caller must treat that as unreadable and must not pick a branch from it.
issue_rest_view() {
  local n="${1:-}" repo="${2:-${REPO:-}}" want_comments="${3:-}" issue comments='[]' since
  [[ "$n" =~ ^[1-9][0-9]*$ && -n "$repo" ]] || return 2
  issue="$(gh api "repos/$repo/issues/$n" 2>/dev/null)" || return 1
  if [[ "$want_comments" == comments ]]; then
    since="$(jq -r '.created_at // "1970-01-01T00:00:00Z"' <<< "$issue")" || return 1
    comments="$(gh api "repos/$repo/issues/$n/comments?per_page=100&since=$since" 2>/dev/null)" || return 1
  fi
  # Comments are unbounded (every page of a long thread), so they go through a file, not argv (jq-arg-safety.test.sh).
  jq -ce --rawfile comments_raw <(printf '%s' "$comments") --argjson n "$n" --argjson with_comments "$([[ "$want_comments" == comments ]] && echo true || echo false)" '
    ($comments_raw | fromjson) as $comments
    | select(type == "object" and .number == $n and (.pull_request | not)
      and (.state | IN("open", "closed")) and (.labels | type == "array") and all(.labels[]; type == "object" and (.name | type == "string"))
      and ($comments | type == "array") and all($comments[]; type == "array" or type == "object"))
    | {number, title, body: (.body // ""), state: (.state | ascii_upcase),
       stateReason: (.state_reason | if type == "string" then ascii_upcase else null end),
       closedAt: .closed_at, labels: [.labels[] | {name}]}
      + (if $with_comments then {comments: [$comments | flatten[] | {id: .node_id, body: (.body // ""), createdAt: .created_at, url: .html_url, author: {login: .user.login}}]} else {} end)
  ' <<< "$issue"
}

issue_rest_list_fetch() (
  local fetch="$1" repo="$2" state="$3" label="$4" limit="$5" page=1 url label_arg tmp_dir rows_file page_file merged_file rows_count=0 page_count
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$state" =~ ^(open|closed|all)$ && "$limit" =~ ^[1-9][0-9]*$ ]] || return 2
  label_arg="$(jq -rn --arg label "$label" '$label | @uri')" || return 1
  tmp_dir="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$tmp_dir"' EXIT
  rows_file="$tmp_dir/rows.json"; page_file="$tmp_dir/page.json"; merged_file="$tmp_dir/merged.json"
  printf '[]' > "$rows_file" || return 1
  while (( rows_count < limit )); do
    url="repos/$repo/issues?state=$state&per_page=100&page=$page"
    [[ -z "$label" ]] || url+="&labels=$label_arg"
    "$fetch" api "$url" > "$page_file" || return 1
    jq -e 'type == "array"' "$page_file" >/dev/null 2>&1 || return 1
    jq -s '.[0] + .[1]' "$rows_file" "$page_file" > "$merged_file" || return 1
    mv -f -- "$merged_file" "$rows_file" || return 1
    page=$((page + 1))
    rows_count="$(jq -r '[.[] | select(.pull_request == null)] | length' "$rows_file")" || return 1
    (( rows_count < limit )) || break
    page_count="$(jq -r 'length' "$page_file")" || return 1
    [[ "$page_count" == 100 ]] || break
  done
  jq -ce --argjson limit "$limit" '
    [.[] | select(type == "object" and (.pull_request | not))][0:$limit]
    | map({number,title,body:(.body // ""),state:(.state | ascii_upcase),createdAt:.created_at,updatedAt:.updated_at,
        labels:[.labels[]? | {name}],author:{login:(.user.login // "")}})
  ' "$rows_file"
)

issue_rest_list() {
  local repo="${1:-${REPO:-}}" state="${2:-open}" label="${3:-}" limit="${4:-1000}" fetch="${5:-gh}" key rows
  [[ -n "$repo" ]] || return 2
  key="$(printf '%s\0' "$repo" "$state" "$label" "$limit" | sha256sum)" || return 1
  key="${key%% *}"
  rows="$(gh_tick_cache_get "issues-$key.json" issue_rest_list_fetch "$fetch" "$repo" "$state" "$label" "$limit")" || return $?
  printf '%s' "$rows"
}

issue_rest_graphql_context() {
  local rows="$1" fetch="${2:-gh}" numbers number fields="" query
  numbers="$(jq -r '[.[]?.number | select(type == "number" and . > 0)] | unique | .[]' <<< "$rows")" || return 1
  while IFS= read -r number; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    fields+=" i$number: issue(number: $number) { number blockedBy(first: 50) { nodes { number state } } subIssues(first: 100) { totalCount nodes { number state } } subIssuesSummary { total completed } }"
  done <<< "$numbers"
  [[ -n "$fields" ]] || { printf '%s\n' '{"data":{"repository":{}}}'; return 0; }
  query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$fields} }"
  gh_graphql_cached_with "$fetch" api graphql -F owner='{owner}' -F name='{repo}' -f "query=$query"
}

issue_rest_context_merge() {
  jq -ce --slurpfile context <(printf '%s' "$2") '
    [.[] | . as $issue | ($context[0].data.repository["i" + (.number | tostring)] // null) as $context
      | select(($context | type) == "object")
      | $issue + {blockedBy:$context.blockedBy,subIssues:$context.subIssues,subIssuesSummary:$context.subIssuesSummary}]
  ' <<< "$1"
}

issue_rest_with_context() {
  local fetch="${1:-gh}" rows context
  rows="$(cat)" || return 1
  jq -e 'type == "array"' <<< "$rows" >/dev/null 2>&1 || return 1
  if jq -e 'all(.[]; has("blockedBy") and has("subIssues") and has("subIssuesSummary"))' <<< "$rows" >/dev/null 2>&1; then
    printf '%s' "$rows"
    return 0
  fi
  context="$(issue_rest_graphql_context "$rows" "$fetch")" || return 1
  issue_rest_context_merge "$rows" "$context"
}

issue_rest_list_labels_context() (
  local repo="$1" state="$2" limit="$3" fetch="$4" label tmp_dir rows_file list_file filtered_file merged_file
  shift 4
  tmp_dir="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$tmp_dir"' EXIT
  rows_file="$tmp_dir/rows.json"; list_file="$tmp_dir/list.json"; filtered_file="$tmp_dir/filtered.json"; merged_file="$tmp_dir/merged.json"
  printf '[]' > "$rows_file" || return 1
  for label in "$@"; do
    issue_rest_list "$repo" "$state" "$label" "$limit" "$fetch" > "$list_file" || return 1
    jq -ce --arg label "$label" '[.[] | select(any(.labels[]?; .name == $label))]' "$list_file" > "$filtered_file" || return 1
    jq -s '.[0] + .[1] | unique_by(.number)' "$rows_file" "$filtered_file" > "$merged_file" || return 1
    mv -f -- "$merged_file" "$rows_file" || return 1
  done
  issue_rest_with_context "$fetch" < "$rows_file"
)

# issue_rest_state <issue> [repo] -- prints OPEN or CLOSED; nonzero and silent when unreadable.
issue_rest_state() {
  local view
  view="$(issue_rest_view "$@")" || return 1
  jq -r '.state' <<< "$view"
}
